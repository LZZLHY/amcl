// Standalone logic verification for McVersionUtils.ets epoch-aware routing.
// This is a faithful JS port of the ArkTS logic (ArkTS hypium tests need DevEco
// which isn't available here). Validates the YY.D era routing against real
// Mojang manifest IDs. Run: node docker/tests/mcversion_logic_check.mjs
//
// NOTE: this file lives under docker/tests/ only as a dev-time logic checker;
// it is NOT shipped and NOT part of the ArkTS test suite.

const McEra = { CLASSIC: 'classic', YEARLY: 'yearly', UNKNOWN: 'unknown' };
const YEARLY_ERA_MIN_FIRST_SEGMENT = 22;

function parseMcVersionParts(v) {
  if (!v || v.length === 0) return null;
  const dashIdx = v.indexOf('-');
  const core = dashIdx >= 0 ? v.substring(0, dashIdx) : v;
  if (core.indexOf('w') >= 0) return null;
  const parts = core.split('.');
  const out = [];
  for (const p of parts) {
    if (p.length === 0) return null;
    const x = parseInt(p, 10);
    if (isNaN(x)) return null;
    out.push(x);
  }
  return out;
}

function detectMcEra(v) {
  const parts = parseMcVersionParts(v);
  if (parts === null || parts.length === 0) return McEra.UNKNOWN;
  const first = parts[0];
  if (first === 1) return McEra.CLASSIC;
  if (first >= YEARLY_ERA_MIN_FIRST_SEGMENT) return McEra.YEARLY;
  return McEra.UNKNOWN;
}

function compareMcVersion(a, b) {
  const eraA = detectMcEra(a);
  const eraB = detectMcEra(b);
  if (eraA === McEra.UNKNOWN || eraB === McEra.UNKNOWN) return 0;
  if (eraA !== eraB) return eraA === McEra.YEARLY ? 1 : -1;
  const pa = parseMcVersionParts(a);
  const pb = parseMcVersionParts(b);
  if (pa === null || pb === null) return 0;
  const n = Math.max(pa.length, pb.length);
  for (let i = 0; i < n; i++) {
    const va = i < pa.length ? pa[i] : 0;
    const vb = i < pb.length ? pb[i] : 0;
    if (va > vb) return 1;
    if (va < vb) return -1;
  }
  return 0;
}

function isMcVersionAtLeast(version, threshold) {
  const cmp = compareMcVersion(version, threshold);
  if (cmp === 0) {
    const ev = detectMcEra(version);
    const et = detectMcEra(threshold);
    if (ev === McEra.UNKNOWN || et === McEra.UNKNOWN) return false;
    return true;
  }
  return cmp > 0;
}

// Mirror of JdkManager.autoSelectVersion three-way routing (as shipped, JDK 25 available).
const JDK21_MIN_MC_VERSION = '1.20.5';
const AVAILABLE = { '17': true, '21': true, '25': true };
function autoSelectVersion(mcVersion) {
  const era = detectMcEra(mcVersion);
  let chosen;
  if (era === McEra.YEARLY) chosen = '25';
  else if (era === McEra.CLASSIC) chosen = isMcVersionAtLeast(mcVersion, JDK21_MIN_MC_VERSION) ? '21' : '17';
  else chosen = '17';
  // availability safety net (mirrors JdkManager)
  if (!AVAILABLE[chosen]) chosen = '17';
  return chosen;
}

let pass = 0, fail = 0;
function eq(actual, expected, label) {
  const ok = actual === expected;
  if (ok) pass++; else fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'} | ${label} | got=${JSON.stringify(actual)} want=${JSON.stringify(expected)}`);
}

console.log('=== detectMcEra ===');
eq(detectMcEra('1.20.4'), McEra.CLASSIC, "era 1.20.4");
eq(detectMcEra('1.20.5'), McEra.CLASSIC, "era 1.20.5");
eq(detectMcEra('1.21'), McEra.CLASSIC, "era 1.21");
eq(detectMcEra('26.1'), McEra.YEARLY, "era 26.1");
eq(detectMcEra('26.1.2'), McEra.YEARLY, "era 26.1.2");
eq(detectMcEra('26.2'), McEra.YEARLY, "era 26.2");
eq(detectMcEra('26.2-pre-2'), McEra.YEARLY, "era 26.2-pre-2");
eq(detectMcEra('26.2-snapshot-8'), McEra.YEARLY, "era 26.2-snapshot-8");
eq(detectMcEra('26.1.2-rc-1'), McEra.YEARLY, "era 26.1.2-rc-1");
eq(detectMcEra('26w14a'), McEra.UNKNOWN, "era 26w14a (week snapshot)");
eq(detectMcEra('23w14a'), McEra.UNKNOWN, "era 23w14a (old week snapshot)");
eq(detectMcEra(''), McEra.UNKNOWN, "era empty");

console.log('\n=== compareMcVersion (regression: existing behavior preserved) ===');
eq(compareMcVersion('1.20.5', '1.20.5'), 0, "1.20.5 == 1.20.5");
eq(compareMcVersion('1.20.4', '1.20.5'), -1, "1.20.4 < 1.20.5");
eq(compareMcVersion('1.21', '1.20.5'), 1, "1.21 > 1.20.5");
eq(compareMcVersion('23w14a', '1.20.5'), 0, "23w14a not comparable");

console.log('\n=== compareMcVersion (new cross-era) ===');
eq(compareMcVersion('26.1', '1.20.5'), 1, "26.1 > 1.20.5 (yearly > classic)");
eq(compareMcVersion('1.20.5', '26.1'), -1, "1.20.5 < 26.1");
eq(compareMcVersion('26.1', '26.1'), 0, "26.1 == 26.1");
eq(compareMcVersion('26.2', '26.1'), 1, "26.2 > 26.1");
eq(compareMcVersion('26.1.2', '26.1'), 1, "26.1.2 > 26.1");
eq(compareMcVersion('26.1', '26.1.2'), -1, "26.1 < 26.1.2");

console.log('\n=== isMcVersionAtLeast (regression) ===');
eq(isMcVersionAtLeast('1.20.5', '1.20.5'), true, ">= 1.20.5 : 1.20.5");
eq(isMcVersionAtLeast('1.20.4', '1.20.5'), false, ">= 1.20.5 : 1.20.4");
eq(isMcVersionAtLeast('23w14a', '1.20.5'), false, ">= 1.20.5 : 23w14a");
eq(isMcVersionAtLeast('1.21', '1.20.5'), true, ">= 1.20.5 : 1.21");

console.log('\n=== isMcVersionAtLeast (new) ===');
eq(isMcVersionAtLeast('26.1', '1.20.5'), true, ">= 1.20.5 : 26.1 (yearly)");

console.log('\n=== autoSelectVersion (THE logic bomb fix) ===');
eq(autoSelectVersion('1.20.4'), '17', "1.20.4 -> 17");
eq(autoSelectVersion('1.16.5'), '17', "1.16.5 -> 17");
eq(autoSelectVersion('1.20.5'), '21', "1.20.5 -> 21");
eq(autoSelectVersion('1.21'), '21', "1.21 -> 21");
eq(autoSelectVersion('1.21.4'), '21', "1.21.4 -> 21");
eq(autoSelectVersion('26.1'), '25', "26.1 -> 25 (was wrongly 21 before fix!)");
eq(autoSelectVersion('26.1.2'), '25', "26.1.2 -> 25");
eq(autoSelectVersion('26.2'), '25', "26.2 -> 25");
eq(autoSelectVersion('26.2-pre-2'), '25', "26.2-pre-2 -> 25");
eq(autoSelectVersion('26.2-snapshot-8'), '25', "26.2-snapshot-8 -> 25");
eq(autoSelectVersion('26w14a'), '17', "26w14a (week snapshot) -> 17 fallback");

console.log(`\n=== ${fail === 0 ? 'ALL GREEN' : fail + ' FAILED'} : ${pass} passed, ${fail} failed ===`);
process.exit(fail > 0 ? 1 : 0);
