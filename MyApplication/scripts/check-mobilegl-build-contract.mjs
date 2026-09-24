import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { readZipEntries } from './check-mg-build-contract.mjs';
import { analyze } from './check-mobilegl-pin.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const DIST = 'prebuilt/mobilegl/dist';
const LIB = 'libmobilegl.so';

// Hvigor strips non-runtime sections again. Compare every allocated ELF section,
// including dynamic symbols/relocations, rather than comparing whole-file hashes.
export function runtimeIdentity(bytes) {
  if (bytes.length < 64 || bytes.toString('hex', 0, 6) !== '7f454c460201' || bytes.readUInt16LE(18) !== 183) {
    throw new Error('MobileGL must be a little-endian ELF64 AArch64 image');
  }
  const offset = Number(bytes.readBigUInt64LE(40));
  const size = bytes.readUInt16LE(58);
  const count = bytes.readUInt16LE(60);
  const namesIndex = bytes.readUInt16LE(62);
  if (size !== 64 || !count || namesIndex >= count || offset + size * count > bytes.length) {
    throw new Error('invalid ELF section table');
  }
  const namesHeader = offset + namesIndex * size;
  const namesStart = Number(bytes.readBigUInt64LE(namesHeader + 24));
  const namesSize = Number(bytes.readBigUInt64LE(namesHeader + 32));
  if (namesStart + namesSize > bytes.length) throw new Error('invalid ELF section names');
  const names = bytes.subarray(namesStart, namesStart + namesSize);
  const result = [];
  for (let i = 0; i < count; i++) {
    const at = offset + i * size;
    const flags = bytes.readBigUInt64LE(at + 8);
    if (!(flags & 2n)) continue;
    const nameAt = bytes.readUInt32LE(at);
    const nameEnd = names.indexOf(0, nameAt);
    if (nameEnd < nameAt) throw new Error('invalid ELF section name');
    const name = names.toString('utf8', nameAt, nameEnd);
    const type = bytes.readUInt32LE(at + 4);
    const start = Number(bytes.readBigUInt64LE(at + 24));
    const length = Number(bytes.readBigUInt64LE(at + 32));
    if (type !== 8 && start + length > bytes.length) throw new Error('truncated ELF section');
    result.push({ name, type, flags: String(flags), address: String(bytes.readBigUInt64LE(at + 16)),
      size: length, sha256: type === 8 ? null : sha(bytes.subarray(start, start + length)) });
  }
  if (!result.some(s => s.name === '.text') || !result.some(s => s.name === '.dynamic')) {
    throw new Error('ELF runtime sections missing');
  }
  return sha(JSON.stringify(result.sort((a, b) => a.name.localeCompare(b.name))));
}

export function policy({ enabled, product, release = false }) {
  if (!['default', 'sideload', 'store', 'desktop'].includes(product)) {
    throw new Error('Unknown or retired graphics product: ' + product);
  }
}

function read(root, relative) { return fs.readFileSync(path.join(root, relative)); }

export function verifyDist(root = ROOT) {
  const source = analyze({ root, offline: true });
  if (!source.ok) throw new Error(source.problems.join('\n'));
  const fields = source.fields;
  const provenance = JSON.parse(read(root, `${DIST}/build-provenance.json`));
  if (provenance.schema !== 1 || provenance.commit !== fields.commit || provenance.sourceTree !== fields.source_tree) {
    throw new Error('MobileGL build provenance does not match source pin');
  }
  for (const [name, field] of [[LIB, 'libmobilegl_stripped_sha256'], ['libmobilegl.unstripped.so', 'libmobilegl_unstripped_sha256']]) {
    const bytes = read(root, `${DIST}/${name}`);
    if (sha(bytes) !== fields[field] || sha(bytes) !== provenance.files[name]) throw new Error(`MobileGL ${name} hash does not match lock/build provenance`);
    if (runtimeIdentity(bytes) !== provenance.runtimeIdentity) throw new Error(`MobileGL runtime image differs: ${name}`);
    if (!bytes.includes(Buffer.from(`GIT@${fields.commit.slice(0, 7)}`))) throw new Error('MobileGL embedded source identity missing');
  }
  return provenance;
}

export function verifyHap(entries, enabled, expectedIdentity) {
  const libs = entries.filter(e => /(?:^|\/)libmobilegl\.so$/i.test(e.name));
  if (!enabled) {
    if (libs.length) throw new Error('non-validation HAP contains MobileGL');
    return;
  }
  if (libs.length !== 1 || libs[0].name !== `libs/arm64-v8a/${LIB}`) throw new Error('validation HAP must contain one arm64 MobileGL image');
  if (runtimeIdentity(libs[0].data) !== expectedIdentity) throw new Error('HAP MobileGL runtime image differs from audited dist');
}

function recordBuild(root, buildDir) {
  const source = analyze({ root, offline: true });
  if (!source.ok) throw new Error(source.problems.join('\n'));
  const cache = fs.readFileSync(path.join(buildDir, 'CMakeCache.txt'), 'utf8');
  for (const pattern of [/^OHOS_STL:.*=c\+\+_static$/m, /^CMAKE_BUILD_TYPE:.*=Release$/m, /^MOBILEGL_ENABLE_LTO:.*=OFF$/m]) {
    if (!pattern.test(cache)) throw new Error(`unexpected MobileGL build configuration: ${pattern}`);
  }
  const files = {};
  const ninja = fs.readFileSync(path.join(buildDir, 'build.ninja'), 'utf8');
  const linkBlock = ninja.match(/^build libMobileGL\.so:[\s\S]*?(?=\r?\n\r?\n)/m)?.[0] ?? '';
  const linkFlags = linkBlock.match(/^\s+LINK_FLAGS = (.*)$/m)?.[1] ?? '';
  if (!linkFlags.includes('-Bsymbolic-functions') ||
      !/(?:-Wl,--exclude-libs,ALL|-Xlinker --exclude-libs -Xlinker ALL)/.test(linkFlags)) {
    throw new Error('MobileGL effective linker flags must bind provider functions and hide static dependencies');
  }
  for (const name of [LIB, 'libmobilegl.unstripped.so']) files[name] = sha(read(root, `${DIST}/${name}`));
  const runtime = runtimeIdentity(read(root, `${DIST}/${LIB}`));
  if (runtime !== runtimeIdentity(read(root, `${DIST}/libmobilegl.unstripped.so`))) throw new Error('strip changed MobileGL runtime image');
  const record = { schema: 1, commit: source.fields.commit, sourceTree: source.fields.source_tree,
    files, runtimeIdentity: runtime, cmakeCacheSha256: sha(Buffer.from(cache)),
    ninjaSha256: sha(Buffer.from(ninja)), linkFlags };
  fs.writeFileSync(path.join(root, DIST, 'build-provenance.json'), JSON.stringify(record, null, 2) + '\n');
  console.log(JSON.stringify(record, null, 2));
}

function main() {
  const args = process.argv.slice(2);
  const value = flag => args[args.indexOf(flag) + 1];
  const product = args.includes('--product') ? value('--product') : 'default';
  // The complete artifact policy is shared by every supported product.
  const enabled = args.includes('--enabled') || process.env.AMCL_MOBILEGL_VALIDATION === '1'
    || ['default', 'sideload', 'store', 'desktop'].includes(product);
  policy({ enabled, product, release: args.includes('--release') });
  if (args.includes('--record-build')) { recordBuild(ROOT, path.resolve(value('--build-dir'))); return; }
  const provenance = enabled ? verifyDist() : null;
  if (args.includes('--prepare')) {
    const deployed = path.join(ROOT, 'entry/libs/arm64-v8a', LIB);
    if (enabled) fs.copyFileSync(path.join(ROOT, DIST, LIB), deployed);
    else fs.rmSync(deployed, { force: true }); // exact regenerated artifact, never a directory
  }
  if (args.includes('--hap')) verifyHap(readZipEntries(fs.readFileSync(value('--hap'))), enabled, provenance?.runtimeIdentity);
  console.log(`check-mobilegl-build-contract PASS (validation=${enabled}, product=${product})`);
}
if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  try { main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
