// Dev-time check: verify JDK 25 SSOT triple (deps.lock / Constants / JdkManager) is consistent.
import fs from 'node:fs';
function lock(sec, key) {
  const t = fs.readFileSync('deps.lock', 'utf8').split(/\r?\n/);
  let inSec = false;
  for (const l of t) {
    const s = l.trim();
    if (s === '[' + sec + ']') { inSec = true; continue; }
    if (inSec && s.startsWith('[')) break;
    if (inSec && s.startsWith(key) && s.includes('=')) {
      return s.split('=')[1].trim().split('#')[0].trim();
    }
  }
  return null;
}
const tag = lock('mc-ohos-resources-25', 'tag');
const asset = lock('mc-ohos-resources-25', 'asset');
const sha = lock('mc-ohos-resources-25', 'sha256');
const sz = lock('mc-ohos-resources-25', 'sizeBytes');
const c = fs.readFileSync('entry/src/main/ets/common/Constants.ets', 'utf8');
const j = fs.readFileSync('entry/src/main/ets/services/JdkManager.ets', 'utf8');

const checks = [
  ['deps.lock-25 tag', tag],
  ['deps.lock-25 asset', asset],
  ['deps.lock-25 sha256', sha ? sha.slice(0, 16) + '…' : sha],
  ['deps.lock-25 sizeBytes', sz],
  ['Constants JDK25_RELEASE_TAG', c.includes("JDK25_RELEASE_TAG = '" + tag + "'")],
  ['Constants JDK25_RELEASE_ASSET', c.includes("JDK25_RELEASE_ASSET = '" + asset + "'")],
  ['Constants SUPPORTED has 25', /SUPPORTED_JDK_VERSIONS[^=]*=[^;\n]*'25'/.test(c)],
  ['JdkManager sha256', j.includes("sha256: '" + sha + "'")],
  ['JdkManager sizeBytes', j.includes('sizeBytes: ' + sz)],
  ['JdkManager 25 available:true', /'25':\s*\{[\s\S]*?available:\s*true/.test(j)],
];
let bad = 0;
for (const [k, v] of checks) {
  const ok = (typeof v === 'boolean') ? v : (v != null && v !== 'PENDING' && v !== '');
  if (!ok) bad++;
  console.log(`${ok ? 'OK  ' : 'FAIL'} | ${k} = ${v}`);
}
console.log(bad === 0 ? '\n=== JDK25 SSOT consistent ===' : `\n=== ${bad} MISMATCH ===`);
process.exit(bad ? 1 : 0);
