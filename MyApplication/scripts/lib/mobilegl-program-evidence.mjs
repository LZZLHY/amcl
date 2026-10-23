/** 共享MGL场景的证据薄门；只核固定输入、原始读回和完整性，不复制编译/绘制实现。 */
import fs from 'node:fs';
import { createHash } from 'node:crypto';

export function loadMobileGlProgramContract() {
  const root = new URL('../../', import.meta.url);
  const bytes = fs.readFileSync(new URL('tests/graphics-semantics/mobilegl_program_cases.json', root));
  const contract = JSON.parse(bytes);
  if (contract.schema !== 'amcl-mobilegl-program-case-contract/v1' || contract.sceneVersion !== 1 ||
      contract.loaderMacro !== 'P_LOAD' || !Array.isArray(contract.commonCases)) throw new Error('Invalid shared MGL contract');
  const source = fs.readFileSync(new URL(contract.loaderSource, root));
  const functions = [...source.toString().matchAll(/\bP_LOAD\((\w+)\)/g)]
    .map(row => row[1]).filter(name => name !== 'member').map(name => 'gl' + name);
  if (functions.length !== 59 || new Set(functions).size !== functions.length) throw new Error('MGL loader source incomplete');
  return { ...contract, functions, contractSha256: createHash('sha256').update(bytes).digest('hex'),
    loaderSha256: createHash('sha256').update(source).digest('hex') };
}

/** expectation来自caller独立driver事实；禁止从producer自己选的branch获得预期。 */
export function auditMobileGlProgramRows(rows, expectation, contract = loadMobileGlProgramContract()) {
  const issues = [];
  const reject = value => issues.push(value);
  const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
  const integer = value => Number.isInteger(value) && value >= 0;
  const branch = contract.branches[expectation];
  if (!branch || !Array.isArray(rows) || rows.some(row => !object(row))) return { ok: false, issues: ['MGL rows/independent expectation missing'] };
  const checks = rows.filter(row => Object.hasOwn(row, 'pass'));
  const required = [...contract.commonCases, ...branch.requiredCases, ...contract.cleanupCases];
  if (checks.length !== required.length || checks.some(row => row.pass !== true) ||
      checks.some((row, index) => row.kind !== required[index]?.[0] || row.case !== required[index]?.[1]))
    reject('MGL case missing/duplicated/reordered/failing');
  if (rows.length !== required.length + contract.metadataKinds.length + 1) reject('MGL original row count mismatch');
  const end = rows.filter(row => row.kind === contract.terminalKind);
  if (end.length !== 1 || rows.at(-1) !== end[0] || end[0].completed !== true) reject('MGL terminal missing/not final');
  for (const kind of contract.metadataKinds) if (rows.filter(row => row.kind === kind && !Object.hasOwn(row, 'pass')).length !== 1)
    reject('MGL metadata missing/duplicated: ' + kind);
  const old = rows[0], config = rows[1], disposition = rows.at(-2);
  if (old?.kind !== 'preexisting-errors' || !integer(old.count) || old.count > 32) reject('MGL preexisting error metadata invalid');
  if (config?.kind !== 'program-scene-config' || config.sceneVersion !== contract.sceneVersion ||
      config.float64Expectation !== expectation || contract.notRunDomains.some(name => config[name] !== 'NOT_RUN')) reject('MGL caller/scene config mismatch');
  if (disposition?.kind !== 'float64-disposition' || disposition.expectation !== expectation ||
      disposition.disposition !== branch.disposition || disposition.fullCoreQualified !== false ||
      disposition.coreFP64Qualified !== (expectation === 'Supported') || disposition.qualificationScope !== 'fixed-dynamic-uint-pair')
    reject('MGL precision disposition incorrectly expands qualification');
  const known = new Set([...required.map(item => item[0]), ...contract.metadataKinds, contract.terminalKind]);
  if (rows.some(row => !known.has(row.kind))) reject('MGL unknown record kind');
  const counts = { checks: checks.length, queryChecks: checks.filter(row => contract.queryKinds.includes(row.kind)).length,
    pixelChecks: checks.filter(row => row.kind === 'pixels').length, failures: checks.filter(row => row.pass !== true).length };
  for (const [key, value] of Object.entries(branch.counts)) if (counts[key] !== value) reject('MGL required count mismatch: ' + key);
  if (end.length === 1) for (const [key, value] of Object.entries(counts)) if (end[0][key] !== value) reject('MGL terminal count mismatch: ' + key);
  const at = name => checks.find(row => row.case === name);
  const fourErrors = new Set(['program-old-location-error', 'program-named-setter-error', 'program-failed-location-error', 'program-failed-reuse-error']);
  const failedShaders = new Set(['program-invalid-compile', 'program-failed-link', 'program-repeat-invalid-compile', 'program-repeat-failed-link']);
  const verdict = row => {
    if (typeof row.log !== 'string' || !integer(row.declaredLogLength) || !integer(row.returnedLogLength) ||
        !integer(row.logBytes) || row.logBytes !== Buffer.byteLength(row.log, 'utf8') || row.logBytes !== row.returnedLogLength ||
        row.logBytes >= 8192 || (row.logBytes > 0 ? row.declaredLogLength !== row.returnedLogLength + 1 :
          ![0, 1].includes(row.declaredLogLength)) || row.logComplete !== true) reject('MGL incomplete original shader log: ' + row.case);
  };
  // 首错不是完整error证据。同种flag会合并，另以真实freshLink判据验证空旧错下
  // 不引入新错；不信任pass/errorDrainComplete而省略count/status/log字段。
  const exactError = (row, error) => {
    if (row.error !== error || row.errorCount !== (error ? 1 : 0) || row.errorDrainComplete !== true)
      reject('MGL error tail incomplete/unexpected: ' + row.case);
  };
  for (const row of checks) {
    if (row.kind === 'shader') {
      verdict(row);
      const expectedStatus = failedShaders.has(row.case) ? 0 : row.case === 'float64-link' && expectation === 'Unsupported' ? 0 : 1;
      if (row.status !== expectedStatus) reject('MGL compile/link status mismatch: ' + row.case);
      exactError(row, row.case === 'float64-link' ? 1280 : 0);
      if (expectedStatus === 0 && !row.log.length) reject('MGL failure omitted compiler/link log: ' + row.case);
    } else if (fourErrors.has(row.case)) {
      exactError(row, 1282);
      if (row.expectedError !== 1282) reject('MGL error golden mismatch: ' + row.case);
    } else if (row.kind !== 'pixels' && row.error !== 0) reject('MGL unexpected API/query/setup error: ' + row.case);
    if (row.kind === 'pixels') {
      const expected = contract.fixedPixels[row.case];
      if (!expected || JSON.stringify(row.expectedRgba) !== JSON.stringify(expected) || row.sampledPixels !== contract.pixelsPerCheck ||
          row.matchingPixels !== contract.pixelsPerCheck || row.channelTolerance !== contract.channelTolerance ||
          [row.clearError, row.drawError, row.readError].some(value => value !== 0) || typeof row.rgba8x8Hex !== 'string' ||
          !/^[0-9a-f]{512}$/i.test(row.rgba8x8Hex)) reject('MGL pixel evidence incomplete: ' + row.case);
      else {
        // 独立核原RGBA8字节和预先固定颜色；不从query/pass/matchingPixels反算期望。
        const pixels = Buffer.from(row.rgba8x8Hex, 'hex');
        if ([...pixels].some((value, index) => Math.abs(value - expected[index % 4]) > contract.channelTolerance)) reject('MGL original pixels disagree with fixed golden: ' + row.case);
      }
    }
    if (contract.inputQueries[row.case]) {
      const input = contract.inputQueries[row.case];
      if (JSON.stringify(row.expected) !== JSON.stringify(input.expected) || JSON.stringify(row.actual) !== JSON.stringify(input.expected) ||
          row.guardsIntact !== true || row.queryComponents !== 3) reject('MGL uint input query incomplete: ' + row.case);
    }
  }
  for (const [name, expected] of [['program-gain-query', 1], ['program-sampler-query', 3]]) {
    const row = at(name);
    if (!row || row.actual !== expected || row.expected !== expected || JSON.stringify(row.guards) !== '[73,74]') reject('MGL managed resource query incomplete: ' + name);
  }
  const setup = at('program-resource-setup');
  if (!setup || !integer(setup.gainLocation) || !integer(setup.samplerLocation) || !integer(setup.blockIndex) ||
      setup.blockIndex === 0xffffffff || setup.samplerUnit !== 3 || setup.uboBinding !== 2) reject('MGL managed resource input identity missing');
  for (const name of ['program-failed-current', ...(expectation === 'Unsupported' ? ['float64-rejected-current'] : [])]) {
    const row = at(name); if (!row || !integer(row.expected) || row.expected === 0 || row.actual !== row.expected) reject('MGL current executable identity lost: ' + name);
  }
  const location = at('program-failed-location-error');
  if (!location || location.actual !== -1 || location.expected !== -1) reject('MGL failed public location lookup was reopened');
  const fp = at('float64-link'), fresh = at(expectation === 'Unsupported' ? 'float64-rejected-empty-error' : 'float64-use');
  if (!fp || !fresh || fp.expectedLink !== (expectation === 'Supported' ? 1 : 0) || fp.expectedError !== 1280) reject('MGL FP64 pending error golden missing');
  if (fresh) {
    verdict(fresh); exactError(fresh, 0);
    if (fresh.freshLink !== true || fresh.status !== (expectation === 'Supported' ? 1 : 0) || fresh.expectedLink !== fresh.status ||
        fresh.expectedError !== 0) reject('MGL empty-old-error relink evidence missing');
    if (expectation === 'Supported' && (fresh.useError !== 0 || fresh.useErrorCount !== 0 || fresh.useErrorDrainComplete !== true)) reject('MGL fresh linked program use error missing');
    if (expectation === 'Unsupported' && (!/Float64/.test(fresh.log) || !/GL_FRAGMENT_SHADER/.test(fresh.log) || !/Float64/.test(fp?.log ?? '') ||
        !/GL_FRAGMENT_SHADER/.test(fp?.log ?? ''))) reject('MGL legal FP64 rejection lacks precise diagnostic');
  }
  return { ok: issues.length === 0, issues, counts, expectation, qualificationScope: 'fixed-monolithic-error/current-and-dynamic-uint-pair',
    fullCoreQualified: false, coreFP64Qualified: expectation === 'Supported' && issues.length === 0,
    contractSha256: contract.contractSha256, loaderSha256: contract.loaderSha256 };
}
