import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { parseLockSection } from './check-mobilegl-pin.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
function requireEvidence(condition, message) { if (!condition) throw new Error(message); }

export function probeEvidence(text, commit) {
  // A prior PASS must never conceal the current attempt's failure.
  const start = text.lastIndexOf('MobileGL DirectVulkan 出帧探针');
  requireEvidence(start >= 0, 'probe start missing');
  const run = text.slice(start);
  requireEvidence(!run.includes('[X]') && !run.includes('FAIL:'), 'latest probe failed');
  requireEvidence(run.includes('✅ PASS') && run.includes('eglTerminate OK'), 'probe did not complete teardown');
  requireEvidence(run.includes(`GIT@${commit.slice(0, 7)}`), 'probe source identity mismatch');
  const addresses = [...run.matchAll(/provider (gl\w+) direct=(0x\w+) proc=(0x\w+) image=([^\r\n]+)/g)];
  for (const name of ['glGetString', 'glGetIntegerv', 'glGetError']) {
    const row = addresses.find(item => item[1] === name);
    requireEvidence(row && row[2] === row[3] && row[4].endsWith('/libmobilegl.so'), `provider split: ${name}`);
  }
  requireEvidence(run.includes('GPU texture content survived pbuffer -> window') &&
    run.includes('GPU texture content survived window -> pbuffer'), 'GPU resource continuity not proved');
  const presents = [...run.matchAll(/AMCL_MOBILEGL_PRESENT successful=(\d+)/g)].map(m => Number(m[1]));
  requireEvidence(presents.length >= 5 && presents.every((v, i) => v > (i ? presents[i - 1] : 0)),
    'successful present counter did not advance through both rounds');
  return { presents: presents.length, lastPresent: presents.at(-1), providerIdentity: 'local', gpuContent: 'preserved' };
}

export function launchEvidence(text, commit) {
  const rows = text.split(/\r?\n/);
  const identity = rows.filter(line => line.includes('Using graphics backend ')).at(-1);
  requireEvidence(identity?.includes('MobileGL') && identity.includes(`GIT@${commit.slice(0, 7)}`),
    'Minecraft did not report the expected MobileGL build');
  const pid = identity.trim().split(/\s+/)[2];
  const run = rows.filter(line => line.trim().split(/\s+/)[2] === pid).join('\n');
  requireEvidence(run.includes('event=create role=presented'), 'Minecraft presented window missing');
  return { pid, backend: identity.slice(identity.indexOf('Using graphics backend')) };
}

export function exitEvidence(text) {
  const rows = text.split(/\r?\n/);
  const summary = rows.filter(line => line.includes('OPENHARMONY_WINDOW schema=1 event=summary')).at(-1);
  requireEvidence(summary, 'SDL final lifecycle summary missing');
  const fields = Object.fromEntries([...summary.matchAll(/\b(\w+)=(\d+)/g)].map(m => [m[1], Number(m[2])]));
  const pid = summary.trim().split(/\s+/)[2];
  requireEvidence(rows.some(line => line.trim().split(/\s+/)[2] === pid && line.includes('Stopping!')),
    'same-process normal Minecraft shutdown missing');
  for (const field of ['swap_fail', 'makecurrent_fail', 'config_mismatch', 'input_to_auxiliary']) {
    requireEvidence(fields[field] === 0, `${field} is nonzero or missing`);
  }
  requireEvidence(fields.swap_ok > 0 && fields.presented_notify === fields.swap_ok &&
    fields.presented_swap_success === fields.swap_ok, 'successful presentation accounting mismatch');
  requireEvidence(fields.balanced === 1 && fields.lease_acquire === fields.lease_release &&
    fields.aux_create_ok === fields.aux_destroy && fields.presented_create_ok === fields.presented_destroy,
    'window or lease lifetime unbalanced');
  return { pid, ...fields };
}

export function swapchainEvidence(text) {
  const transforms = new Map();
  const images = [];
  for (const line of text.split(/\r?\n/)) {
    const prefix = line.trim().split(/\s+/);
    const key = `${prefix[2]}:${prefix[3]}`;
    const transform = line.match(/Swapchain currentTransform = (\S+)/);
    if (transform) transforms.set(key, transform[1]);
    const extent = line.match(/Swapchain created, extent = (\d+)x(\d+)/);
    if (extent) images.push({ pid: prefix[2], key, transform: transforms.get(key), width: +extent[1], height: +extent[2] });
  }
  requireEvidence(images.length > 0, 'swapchain creation evidence missing');
  const pid = images.at(-1).pid;
  const current = images.filter(row => row.pid === pid);
  let oscillations = 0;
  for (let i = 1; i < current.length; i++) {
    const a = current[i - 1], b = current[i];
    const transposed = a.key === b.key && a.transform && a.transform === b.transform &&
      a.width !== a.height && a.width === b.height && a.height === b.width;
    oscillations = transposed ? oscillations + 1 : 0;
    requireEvidence(oscillations < 3, 'swapchain repeatedly transposes extent without a surface transform change');
  }
  return { pid, creations: current.length, extents: current.map(row => `${row.width}x${row.height}`), oscillation: false };
}

function main() {
  const args = process.argv.slice(2);
  const { fields } = parseLockSection(fs.readFileSync(path.join(root, 'deps.lock'), 'utf8'));
  const evidence = [];
  let output;
  for (let i = 0; i < args.length; i += 2) {
    const type = args[i];
    const file = args[i + 1];
    if (type === '--write') { output = file; continue; }
    const check = { '--probe': probeEvidence, '--launch': launchEvidence, '--exit': exitEvidence,
      '--swapchain': swapchainEvidence }[type];
    requireEvidence(check && file, `unknown/incomplete evidence argument: ${type}`);
    const bytes = fs.readFileSync(file);
    evidence.push({ type: type.slice(2), file, sha256: createHash('sha256').update(bytes).digest('hex'),
      result: check(bytes.toString('utf8'), fields.commit) });
  }
  requireEvidence(evidence.length > 0, 'no device evidence supplied');
  const result = { schema: 1, sourceCommit: fields.commit, evidence };
  if (output) fs.writeFileSync(output, JSON.stringify(result, null, 2) + '\n');
  console.log(`MobileGL device evidence PASS (${evidence.length} records, commit=${fields.commit.slice(0, 8)})`);
}
if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  try { main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
