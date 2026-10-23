/** 共享initializer场景的完整性薄层；数值/绘制算法仍只有生产共享C++场景一份。 */
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

/** 机器case与真实U_LOAD清单来自同一场景目录，避免另一套函数或计数发生漂移。 */
export function loadUniformInitializerContract() {
  const directory = new URL('../../tests/graphics-semantics/', import.meta.url);
  const bytes = fs.readFileSync(new URL('uniform_initializer_cases.json', directory));
  const contract = JSON.parse(bytes);
  if (contract.schema !== 'amcl-uniform-initializer-case-contract/v1' || contract.sceneVersion !== 1 ||
      contract.loaderSource !== 'depth_range_scene.cpp' || contract.loaderMacro !== 'U_LOAD' || !contract.cases.length)
    throw new Error('Invalid shared initializer contract');
  const source = fs.readFileSync(new URL(contract.loaderSource, directory));
  const functions = [...source.toString().matchAll(/\bU_LOAD\((\w+)\)/g)]
    .map(row => row[1]).filter(name => name !== 'member').map(name => 'gl' + name);
  if (!functions.length || new Set(functions).size !== functions.length) throw new Error('Initializer function list missing or duplicated');
  return { ...contract, functions, sha256: createHash('sha256').update(bytes).digest('hex'),
    loaderSha256: createHash('sha256').update(source).digest('hex'), manifestPath: fileURLToPath(new URL('uniform_initializer_cases.json', directory)) };
}

/** 只检查必需原始条目/固定case期望/形状/数量/顺序/末尾，不重算shader或量化算法。 */
export function auditUniformInitializerRows(rows, contract = loadUniformInitializerContract()) {
  const issues = [];
  const reject = reason => issues.push(reason);
  const object = row => row !== null && typeof row === 'object' && !Array.isArray(row);
  if (!Array.isArray(rows) || rows.some(row => !object(row))) return { ok: false, issues: ['Initializer rows are incomplete'] };
  const checks = rows.filter(row => Object.hasOwn(row, 'pass'));
  const terminal = rows.filter(row => row.kind === contract.terminalKind);
  const metadata = rows.filter(row => row.kind === 'preexisting-errors');
  if (terminal.length !== 1 || rows.at(-1) !== terminal[0] || terminal[0].completed !== true) reject('Initializer terminal is absent, duplicated or not last');
  if (metadata.length !== 1 || rows[0] !== metadata[0] || !Number.isInteger(metadata[0].count) || metadata[0].count < 0 || metadata[0].count > 32) reject('Initializer initial error metadata incomplete');
  const allowed = new Set(contract.requiredChecks.map(row => row.kind + '/' + row.case));
  for (const test of contract.cases) for (const kind of [...contract.queryKinds, 'pixels']) allowed.add(kind + '/' + test.id);
  if (checks.some(row => row.pass !== true || !allowed.has(row.kind + '/' + row.case))) reject('Initializer has a failing/unknown check');
  if (rows.some(row => !Object.hasOwn(row, 'pass') && ![...contract.metadataKinds, contract.terminalKind].includes(row.kind))) reject('Unknown initializer metadata');
  if (rows.length !== contract.counts.checks + contract.metadataKinds.length + 1) reject('Initializer raw row count differs from contract');
  const counts = { checks: checks.length, queryChecks: checks.filter(row => contract.queryKinds.includes(row.kind)).length,
    pixelChecks: checks.filter(row => row.kind === 'pixels').length, failures: checks.filter(row => row.pass !== true).length };
  for (const [key, value] of Object.entries(contract.counts)) if (counts[key] !== value) reject('Initializer required count mismatch: ' + key);
  if (terminal.length === 1) for (const [key, value] of Object.entries(counts)) if (terminal[0][key] !== value) reject('Initializer terminal count mismatch: ' + key);
  for (const item of contract.requiredChecks) {
    const matching = checks.filter(row => row.kind === item.kind && row.case === item.case);
    if (matching.length !== item.count) reject('Initializer required check missing/duplicate: ' + item.case);
    if (item.kind === 'gl-error' && matching.some(row => row.error !== 0)) reject('Initializer GL error: ' + item.case);
  }
  const order = [];
  for (const test of contract.cases) {
    const query = checks.filter(row => row.kind === 'uniform-query' && row.case === test.id);
    if (query.length !== 1 || query.some(row => !Array.isArray(row.actual) || row.actual.length !== contract.queryComponents ||
        row.actual.some(value => !Number.isFinite(value)) || JSON.stringify(row.expected) !== JSON.stringify(test.expectedUniform) ||
        JSON.stringify(row.guards) !== '[73,74]' || row.tolerance !== contract.queryTolerance)) reject('Initializer query evidence incomplete: ' + test.id);
    const pixels = checks.filter(row => row.kind === 'pixels' && row.case === test.id);
    if (pixels.length !== test.pixelChecks || pixels.some(row => row.sampledPixels !== contract.pixelsPerCheck || row.matchingPixels !== contract.pixelsPerCheck ||
        row.channelTolerance !== contract.channelTolerance || JSON.stringify(row.expectedRgba) !== JSON.stringify(test.expectedRgba) ||
        typeof row.rgba8x8Hex !== 'string' || !new RegExp('^[0-9a-f]{' + contract.pixelsPerCheck * 8 + '}$', 'i').test(row.rgba8x8Hex))) reject('Initializer raw pixel evidence incomplete: ' + test.id);
    order.push(rows.indexOf(query[0]), rows.indexOf(pixels[0]));
  }
  if (order.some((index, i) => index < 0 || (i > 0 && index <= order[i - 1])) ||
      rows.findIndex(row => row.case === 'initializer-program') >= order[0] ||
      rows.findIndex(row => row.case === 'initializer-owner-retire') <= order.at(-1)) reject('Initializer link/query/draw/setter/retire order violated');
  return { ok: issues.length === 0, issues, counts: contract.counts, sceneVersion: contract.sceneVersion,
    contractSha256: contract.sha256, loaderSha256: contract.loaderSha256 };
}
