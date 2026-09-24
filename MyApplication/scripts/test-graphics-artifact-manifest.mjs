import assert from 'node:assert/strict';
import { graphicsArtifactManifest, auditGraphicsManifest } from './graphics-artifact-manifest.mjs';

function archive(entries) {
  const blocks = [], records = [];
  let offset = 0;
  for (const [name, value] of entries) {
    const n = Buffer.from(name), bytes = Buffer.from(value), l = Buffer.alloc(30), c = Buffer.alloc(46);
    l.writeUInt32LE(0x04034b50); l.writeUInt32LE(bytes.length, 18); l.writeUInt32LE(bytes.length, 22); l.writeUInt16LE(n.length, 26);
    c.writeUInt32LE(0x02014b50); c.writeUInt32LE(bytes.length, 20); c.writeUInt32LE(bytes.length, 24);
    c.writeUInt16LE(n.length, 28); c.writeUInt32LE(offset, 42);
    blocks.push(l, n, bytes); records.push(c, n); offset += l.length + n.length + bytes.length;
  }
  const directory = Buffer.concat(records), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...blocks, directory, end]);
}
const manifest = graphicsArtifactManifest('default');
const elf = Buffer.alloc(64);
Buffer.from('7f454c460201', 'hex').copy(elf); elf.writeUInt16LE(183, 18);
const names = [...new Set(manifest.profiles.flatMap(p => p.artifactIds))];
const entries = [['resources/rawfile/graphics-manifest.json', JSON.stringify(manifest)],
  ...names.map(n => ['libs/arm64-v8a/' + n, elf])];
for (const product of ['default', 'sideload', 'store', 'desktop']) {
  assert.deepEqual(graphicsArtifactManifest(product), manifest, product + ' artifact parity');
  assert.deepEqual(auditGraphicsManifest(archive(entries), product), []);
  for (const name of names) assert.match(auditGraphicsManifest(archive(entries.filter(e => !e[0].endsWith('/' + name))), product).join(), /artifact-missing/);
}
const wrongAbi = Buffer.from(elf); wrongAbi.writeUInt16LE(62, 18);
assert.match(auditGraphicsManifest(archive(entries.map((e, i) => i === 1 ? [e[0], wrongAbi] : e)), 'default').join(), /ELF64 AArch64/);
const lie = structuredClone(manifest); lie.availableProfileIds = ['nativegl'];
assert.match(auditGraphicsManifest(archive([[entries[0][0], JSON.stringify(lie)], ...entries.slice(1)]), 'desktop').join(), /differs/);
assert.throws(() => graphicsArtifactManifest('desktopLegacy'), /Unknown product/);
assert.throws(() => auditGraphicsManifest(archive([entries[0], ...entries]), 'default'), /exactly once/);
console.log('Graphics manifest: four-product parity, missing DSO, wrong ABI, false declaration and duplicate controls PASS');
