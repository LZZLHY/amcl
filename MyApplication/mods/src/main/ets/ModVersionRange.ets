/** Version constraints for package manifests; see download-system.md §4.11. */
export interface ModRangeResult {
  supported: boolean;
  matches: boolean;
}

interface NumericModVersion {
  parts: number[];
  pre: string[];
  hasPre: boolean;
}

function numericVersion(value: string): NumericModVersion | undefined {
  const base = value.split('+')[0];
  const dash = base.indexOf('-');
  const core = dash < 0 ? base : base.substring(0, dash);
  if (!new RegExp('^[0-9]+(?:\\.[0-9]+)*$').test(core)) return undefined;
  const parts: number[] = [];
  for (const p of core.split('.')) {
    const n = Number(p);
    if (!Number.isSafeInteger(n)) return undefined;
    parts.push(n);
  }
  const pre = dash < 0 ? [] : base.substring(dash + 1).split('.');
  return { parts: parts, pre: pre, hasPre: dash >= 0 };
}

function compareNumeric(a: NumericModVersion, b: NumericModVersion): number {
  for (let i = 0; i < Math.max(a.parts.length, b.parts.length); i++) {
    const x = a.parts[i] ?? 0;
    const y = b.parts[i] ?? 0;
    if (x !== y) return x < y ? -1 : 1;
  }
  if (a.hasPre !== b.hasPre) return a.hasPre ? -1 : 1;
  if (!a.hasPre) return 0;
  for (let i = 0; i < Math.max(a.pre.length, b.pre.length); i++) {
    if (i >= a.pre.length) return -1;
    if (i >= b.pre.length) return 1;
    const x = a.pre[i];
    const y = b.pre[i];
    if (x === y) continue;
    if (x.length === 0 || y.length === 0) return x.length === 0 ? -1 : 1;
    const xn = new RegExp('^[0-9]+$').test(x);
    const yn = new RegExp('^[0-9]+$').test(y);
    if (xn && yn) return Number(x) < Number(y) ? -1 : 1;
    if (xn !== yn) return xn ? -1 : 1;
    return x < y ? -1 : 1;
  }
  return 0;
}

/** undefined means that ordering an opaque version would be a guess. */
export function compareManifestVersions(a: string, b: string): number | undefined {
  if (a === b) return 0;
  const x = numericVersion(a);
  const y = numericVersion(b);
  if (x === undefined || y === undefined) return undefined;
  return compareNumeric(x, y);
}

function result(supported: boolean, matches: boolean): ModRangeResult {
  return { supported: supported, matches: matches };
}

function comparison(value: string, target: string, op: string): ModRangeResult {
  const c = compareManifestVersions(value, target);
  if (c === undefined) {
    if (op === '=' || op.length === 0) return result(true, value === target);
    return result(false, false);
  }
  if (op === '>=') return result(true, c >= 0);
  if (op === '<=') return result(true, c <= 0);
  if (op === '>') return result(true, c > 0);
  if (op === '<') return result(true, c < 0);
  return result(true, c === 0);
}

function fabricTerm(value: string, term: string): ModRangeResult {
  if (term === '*' || term === 'x' || term === 'X') return result(true, true);
  const m = new RegExp('^(>=|<=|>|<|=|\\^|~)?(.+)$').exec(term);
  if (m === null) return result(false, false);
  const op = m[1] ?? '';
  const target = m[2];
  const wildcard = new RegExp('^(\\d+(?:\\.\\d+)*)(?:\\.[xX*])+$').exec(target);
  if (wildcard !== null) {
    if (op.length > 0 && op !== '=') return result(false, false);
    const low = wildcard[1];
    const parts = low.split('.').map((p: string): number => Number(p));
    parts[parts.length - 1] += 1;
    const lo = comparison(value, low + '-', '>=');
    const hi = comparison(value, parts.join('.') + '-', '<');
    return result(lo.supported && hi.supported, lo.matches && hi.matches);
  }
  if (op === '^' || op === '~') {
    const v = numericVersion(target);
    if (v === undefined) return result(false, false);
    const pos = op === '^' ? 0 : Math.min(1, v.parts.length - 1);
    const upper: number[] = v.parts.slice(0, pos + 1);
    upper[pos] += 1;
    const lo = comparison(value, target, '>=');
    const hi = comparison(value, upper.join('.') + '-', '<');
    return result(lo.supported && hi.supported, lo.matches && hi.matches);
  }
  return comparison(value, target, op);
}

function fabricRange(value: string, expression: string): ModRangeResult {
  const text = expression.trim();
  if (text.length === 0) return result(false, false);
  let supported = true;
  for (const alternative of text.split('||')) {
    let matches = true;
    let branchSupported = true;
    for (const term of alternative.trim().split(new RegExp('\\s+'))) {
      const checked = fabricTerm(value, term);
      matches = matches && checked.matches;
      branchSupported = branchSupported && checked.supported;
    }
    if (branchSupported && matches) return result(true, true);
    supported = supported && branchSupported;
  }
  return result(supported, false);
}

/** Maven interval unions; opaque bounds are reported, never silently accepted. */
function mavenRange(value: string, expression: string): ModRangeResult {
  const text = expression.trim();
  if (text === '*' || text.length === 0) return result(true, true);
  if (!text.startsWith('[') && !text.startsWith('(')) return comparison(value, text, '=');
  let remaining = text;
  let supported = true;
  while (remaining.length > 0) {
    const m = new RegExp('^([\\[(])([^\\]\\)]*)([\\])])').exec(remaining);
    if (m === null) return result(false, false);
    const bounds = m[2].split(',');
    let check: ModRangeResult;
    if (bounds.length === 1) {
      if (m[1] !== '[' || m[3] !== ']') return result(false, false);
      check = comparison(value, bounds[0].trim(), '=');
    } else if (bounds.length === 2) {
      const lo = bounds[0].trim().length === 0 ? result(true, true)
        : comparison(value, bounds[0].trim(), m[1] === '[' ? '>=' : '>');
      const hi = bounds[1].trim().length === 0 ? result(true, true)
        : comparison(value, bounds[1].trim(), m[3] === ']' ? '<=' : '<');
      check = result(lo.supported && hi.supported, lo.matches && hi.matches);
    } else return result(false, false);
    if (check.supported && check.matches) return result(true, true);
    supported = supported && check.supported;
    remaining = remaining.substring(m[0].length).trim();
    if (remaining.startsWith(',')) remaining = remaining.substring(1).trim();
    else if (remaining.length > 0) return result(false, false);
  }
  return result(supported, false);
}

export function matchesModVersion(value: string, ranges: string[], syntax: string = 'fabric'): ModRangeResult {
  if (ranges.length === 0) return result(false, false);
  let supported = true;
  for (const range of ranges) {
    const r = syntax === 'maven' ? mavenRange(value, range) : fabricRange(value, range);
    if (r.supported && r.matches) return r;
    supported = supported && r.supported;
  }
  return result(supported, false);
}
