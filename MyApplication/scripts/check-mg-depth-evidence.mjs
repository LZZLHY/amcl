/**
 * 冷诊断进程MG深度范围结果的薄宿主验收层。
 * 共享C++场景负责数值/像素判定；本层从同一机器契约读取必需case和计数，只核对完整性、
 * 函数映像与外部HDC/最终HAP身份。PROBE_RETURN来自宿主独立日志，表示函数完成并成功
 * 关闭/回读证据，不表示应用自然退出；测试后force-stop只能作为清理。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';
import { assertExternalOutputPath } from './lib/workspace-paths.mjs';
import { auditUniformInitializerRows, loadUniformInitializerContract } from './lib/uniform-initializer-evidence.mjs';

const sceneDirectory = fileURLToPath(new URL('../tests/graphics-semantics/', import.meta.url));
const libraryMember = 'libs/arm64-v8a/libamcl_gl_host.so';
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);

/** 从共享场景的机器契约及真实LOAD宏取得清单，不复制另一套case或函数表。 */
export function loadDepthEvidenceContract() {
  const bytes = fs.readFileSync(path.join(sceneDirectory, 'depth_range_cases.json'));
  const contract = JSON.parse(bytes);
  if (contract.schema !== 'amcl-depth-range-case-contract/v1' || !Array.isArray(contract.cases) ||
      !object(contract.counts) || !/^[A-Za-z_]+$/.test(contract.loaderMacro)) throw new Error('Invalid shared scene contract');
  const sourcePath = path.resolve(sceneDirectory, contract.loaderSource);
  if (path.dirname(sourcePath) !== path.resolve(sceneDirectory)) throw new Error('Shared loader source escaped scene directory');
  const source = fs.readFileSync(sourcePath, 'utf8');
  const names = [...source.matchAll(new RegExp('\\b' + contract.loaderMacro + '\\((\\w+)\\)', 'g'))]
    .map(match => match[1]).filter(name => name !== 'member').map(name => 'gl' + name);
  const functions = [...contract.extraProbeResolutions, ...names];
  if (functions.length < 1) throw new Error('Shared function resolver list is empty');
  return { ...contract, functions, sha256: sha(bytes), loaderSha256: sha(Buffer.from(source)) };
}

/** 只解释稳定key=value元数据；重复字段拒绝，避免前值通过后值表示失败。 */
function fields(line, prefix) {
  if (!line.startsWith(prefix + ' ')) throw new Error('Missing record ' + prefix);
  const result = {};
  for (const match of line.slice(prefix.length + 1).matchAll(/(?:^|\s)([A-Za-z][A-Za-z0-9]*)=([^\s]*)/g)) {
    if (Object.hasOwn(result, match[1])) throw new Error('Duplicate metadata key: ' + match[1]);
    result[match[1]] = match[2];
  }
  return result;
}

/**
 * report和returnLog为宿主实际收取的原始字节，hap为最终实际包。expected来自独立HDC
 * 进程观测/运行调用/安装库核对。解析失败以issues返回，不抛异常把截断报告漏作成功。
 */
export function auditMgDepthEvidence(report, returnLog, hap, expected, contract = loadDepthEvidenceContract()) {
  const issues = [];
  const reject = reason => issues.push(reason);
  const result = { ok: false, verdict: 'FAIL', issues, reportSha256: sha(report), reportBytes: report.length,
    returnLogSha256: sha(returnLog), hapSha256: sha(hap), contractSha256: contract.sha256 };
  try {
    if (!object(expected) || !Number.isSafeInteger(expected.pid) || expected.pid <= 0 ||
        typeof expected.runId !== 'string' || !/^\d+-\d+$/.test(expected.runId) ||
        typeof expected.librarySha256 !== 'string' || !/^[0-9a-f]{64}$/.test(expected.librarySha256))
      throw new Error('Independent expected PID/runId/library SHA required');
    const library = readUniqueZipEntry(hap, libraryMember);
    result.librarySha256 = sha(library);
    if (library.length < 64 || library.toString('hex', 0, 6) !== '7f454c460201' || library.readUInt16LE(18) !== 183)
      reject('Final MG payload is not ELF64 AArch64');
    if (result.librarySha256 !== expected.librarySha256) reject('HAP MG payload differs from independently observed installed-library identity');
    const text = Buffer.from(report).toString('utf8');
    if (!Buffer.from(text).equals(Buffer.from(report)) || !text.endsWith('\n')) reject('Truncated/invalid UTF8 report');
    const lines = text.split(/\r?\n/); if (lines.at(-1) === '') lines.pop();
    // result.txt只能含生产探针的已知记录；未识别的kill/错误或额外状态不能被忽略成PASS。
    const allowed = /^(?:PROBE_RUN |PROBE_END |BEGIN MG_DEPTH_RANGE |BEGIN MG_UNIFORM_INITIALIZER |PROVIDER |IMAGE_COPY |FUNCTION |PASS legal-current-thread |PASS context-owner-destroy |GL_VERSION=|GL_VENDOR=|GL_RENDERER=|GL_INTEGER_VERSION=|MG_DEPTH_RANGE_RESULT |MG_UNIFORM_INITIALIZER_RESULT |\{)/;
    if (lines.some(line => !allowed.test(line))) reject('Unknown/failing record in production report');
    const one = prefix => {
      const found = lines.filter(line => line.startsWith(prefix + ' '));
      if (found.length !== 1) throw new Error('Record must occur exactly once: ' + prefix);
      return fields(found[0], prefix);
    };
    const run = one('PROBE_RUN'), end = one('PROBE_END');
    if (!lines[0]?.startsWith('PROBE_RUN ') || !lines.at(-1)?.startsWith('PROBE_END ')) reject('Run header/trailer is not a complete cold-process report');
    for (const entry of [run, end]) if (entry.runId !== expected.runId || entry.processPid !== String(expected.pid)) reject('Report PID/runId differs from independent observation');
    if (run.runId !== run.processPid + '-' + run.startSteadyNs || !/^\d+$/.test(run.startUnixNs ?? '') || !/^\d+$/.test(run.startSteadyNs ?? '')) reject('Run timestamp identity is malformed');
    if (end.completed !== '1' || end.exitCode !== '0' || end.restartRequired !== '1' || end.verdict !== 'PASS') reject('Incomplete/failed diagnostic function; restartRequired must be one');
    if (lines.filter(line => line === 'BEGIN MG_DEPTH_RANGE production-profile=mobileglues api=OPENGL').length !== 1) reject('Production MG/API begin identity missing');
    if (lines.some(line => /^(?:FAIL|NOT_RUN)\b/.test(line))) reject('Report contains failure, not-run or evidence I/O error');
    const provider = one('PROVIDER');
    if (!provider.image || path.posix.basename(provider.image) !== 'libamcl_gl_host.so' || !provider.implementation) reject('Production provider image identity missing');
    if (expected.imagePath && provider.image !== expected.imagePath) reject('Loaded provider path differs from independently observed installed image');
    const copy = one('IMAGE_COPY');
    if (copy.library !== 'libamcl_gl_host.so' || copy.bytes !== String(library.length) ||
        copy.path !== '/data/storage/el2/base/haps/entry/files/mg-depth-range-probe/loaded-libamcl_gl_host.so')
      reject('Actual loaded-image copy is absent, wrong-sized or outside the fixed probe location');
    const counts = new Map();
    // 第二批历史depth报告可按旧范围复核；第三批调用方显式要求initializer，不能
    // 借一份仍完整的旧83/26/24报告通过新shader资格。若新段存在则无条件完整审核。
    const initializerStarts = lines.map((line, index) => line.startsWith('BEGIN MG_UNIFORM_INITIALIZER ') ? index : -1).filter(index => index >= 0);
    const hasInitializer = initializerStarts.length > 0 || lines.some(line => line.startsWith('MG_UNIFORM_INITIALIZER_RESULT '));
    if (expected.requireInitializer && !hasInitializer) reject('Required initializer scene is absent');
    let initializerContract = null;
    if (hasInitializer) {
      if (initializerStarts.length !== 1 || lines[initializerStarts[0]] !== 'BEGIN MG_UNIFORM_INITIALIZER sceneVersion=1 shader=desktop330') throw new Error('Initializer begin/version must occur once');
      initializerContract = loadUniformInitializerContract();
      const initializerRows = lines.slice(initializerStarts[0] + 1).filter(line => line.startsWith('{')).map(line => JSON.parse(line));
      result.initializer = auditUniformInitializerRows(initializerRows, initializerContract);
      for (const issue of result.initializer.issues) reject(issue);
      const summary = one('MG_UNIFORM_INITIALIZER_RESULT');
      for (const [key, value] of Object.entries(initializerContract.counts)) if (summary[key] !== String(value)) reject('Initializer native summary count mismatch: ' + key);
      for (const [key, value] of Object.entries({ sceneVersion: '1', completed: '1', failures: '0', rejected: '0', evidenceComplete: '1', retired: '1', verdict: 'PASS', resolved: String(initializerContract.functions.length) }))
        if (summary[key] !== value) reject('Initializer native summary failed/incomplete: ' + key);
    }
    const functions = lines.filter(line => line.startsWith('FUNCTION ')).map(line => fields(line, 'FUNCTION'));
    for (const fn of functions) {
      counts.set(fn.name, (counts.get(fn.name) ?? 0) + 1);
      if (!/^0x[0-9a-f]+$/i.test(fn.address ?? '') || BigInt(fn.address) === 0n || fn.owned !== '1' || fn.image !== provider.image)
        reject('Missing/foreign function address or image: ' + fn.name);
    }
    const expectedFunctions = new Map();
    for (const name of [...contract.functions, ...(initializerContract?.functions ?? [])]) expectedFunctions.set(name, (expectedFunctions.get(name) ?? 0) + 1);
    for (const [name, count] of expectedFunctions) if (counts.get(name) !== count) reject('Function resolution completeness mismatch: ' + name);
    for (const name of counts.keys()) if (!expectedFunctions.has(name)) reject('Unexpected function identity: ' + name);
    if (hasInitializer) {
      // 相同函数可能由两个场景分别解析；总次数正确还不足以证明各段清单完整。
      // 逐段核对multiplicity，不能把depth旧解析行挪到initializer充数。
      for (const [records, required, phase] of [
        [lines.slice(0, initializerStarts[0]), contract.functions, 'depth'],
        [lines.slice(initializerStarts[0] + 1), initializerContract.functions, 'initializer']]) {
        const actual = new Map(), wanted = new Map();
        for (const name of required) wanted.set(name, (wanted.get(name) ?? 0) + 1);
        for (const row of records.filter(line => line.startsWith('FUNCTION '))) {
          const name = fields(row, 'FUNCTION').name;
          actual.set(name, (actual.get(name) ?? 0) + 1);
        }
        if (actual.size !== wanted.size || [...wanted].some(([name, value]) => actual.get(name) !== value)) reject('Function phase completeness mismatch: ' + phase);
      }
    }
    const current = lines.filter(line => line.startsWith('PASS legal-current-thread '));
    if (current.length !== 1 || lines.filter(line => /^PASS context-owner-destroy\b/.test(line)).length !== 1) reject('Current-thread/context-owner retirement evidence missing');
    if (current.length === 1 && !/^PASS legal-current-thread tid=[1-9]\d* actualMajor=\d+ actualMinor=\d+$/.test(current[0])) reject('Malformed actual current-thread/context identity');
    for (const name of ['GL_VERSION', 'GL_VENDOR', 'GL_RENDERER', 'GL_INTEGER_VERSION'])
      if (lines.filter(line => line.startsWith(name + '=') && !line.endsWith('=UNKNOWN')).length !== 1) reject('Actual GL query identity missing: ' + name);

    // 这里只统计共享场景已判断过的完整记录，绝不重新计算depth或像素oracle。
    const rows = lines.slice(0, hasInitializer ? initializerStarts[0] : lines.length).filter(line => line.startsWith('{')).map(line => JSON.parse(line));
    if (rows.some(row => !object(row))) throw new Error('Malformed scene JSONL object');
    const checks = rows.filter(row => Object.hasOwn(row, 'pass'));
    if (checks.some(row => row.pass !== true)) reject('Shared scene reported semantic/environment failure');
    if (checks.some(row => typeof row.kind !== 'string' || typeof row.case !== 'string' || !row.case)) reject('Malformed shared check identity');
    if (rows.some(row => (row.verdict && row.verdict !== 'PASS') || (row.result && row.result !== 'PASS'))) reject('JSONL contains failure or not-run verdict');
    if (rows.some(row => row.kind !== contract.terminalKind && !Object.hasOwn(row, 'pass') && !contract.metadataKinds?.includes(row.kind))) reject('Unknown scene record without a shared verdict');
    for (const kind of contract.metadataKinds ?? []) {
      const metadata = rows.filter(row => row.kind === kind);
      if (metadata.length !== 1 || !Number.isSafeInteger(metadata[0].count) || metadata[0].count < 0)
        reject('Shared metadata record missing/duplicated/malformed: ' + kind);
    }
    const sceneEnd = rows.filter(row => row.kind === contract.terminalKind);
    if (sceneEnd.length !== 1 || rows.at(-1) !== sceneEnd[0] || sceneEnd[0].completed !== true || sceneEnd[0].failures !== 0) reject('Shared scene terminal is missing, duplicated or incomplete');
    for (const [key, count] of Object.entries(contract.counts)) if (sceneEnd[0]?.[key] !== count) reject('Shared scene terminal count mismatch: ' + key);
    if (checks.length !== contract.counts.checks) reject('Raw check record count is incomplete');
    for (const test of contract.cases) {
      for (const kind of contract.queryKinds) if (rows.filter(row => row.kind === kind && row.case === test.id).length !== 1) reject('Missing/duplicate query: ' + test.id + '/' + kind);
      const queries = rows.filter(row => contract.queryKinds.includes(row.kind) && row.case === test.id);
      if (queries.some(row => !['actual', 'expected', 'guards'].every(key => Array.isArray(row[key]) && row[key].length === 2 && row[key].every(Number.isFinite)) || row.tolerance !== contract.queryTolerance))
        reject('Incomplete raw query evidence: ' + test.id);
      const pixels = rows.filter(row => row.kind === 'pixels' && row.case === test.id);
      if (pixels.length !== test.pixelChecks || pixels.some(row => row.sampledPixels !== contract.pixelsPerCheck || row.matchingPixels !== contract.pixelsPerCheck ||
          row.channelTolerance !== contract.channelTolerance || typeof row.expectedRed !== 'boolean' || !Number.isFinite(row.clearDepth) ||
          typeof row.rgba8x8Hex !== 'string' || !new RegExp('^[0-9a-f]{' + contract.pixelsPerCheck * 8 + '}$', 'i').test(row.rgba8x8Hex)))
        reject('Missing/duplicate/partial raw pixel evidence: ' + test.id);
    }
    for (const required of contract.requiredChecks) if (rows.filter(row => row.kind === required.kind && row.case === required.case).length !== required.count) reject('Required shared check missing: ' + required.case);
    const summary = one('MG_DEPTH_RANGE_RESULT');
    for (const [key, value] of Object.entries(contract.counts)) if (summary[key] !== String(value)) reject('Native summary count mismatch: ' + key);
    for (const [key, value] of Object.entries({ completed: '1', failures: '0', rejected: '0', evidenceComplete: '1', retired: '1', verdict: 'PASS', resolved: String(contract.functions.length) }))
      if (summary[key] !== value) reject('Native summary failed/incomplete: ' + key);
    // 只有成功关闭/回读以后才出现在返回值/hilog的marker；独立宿主日志不能用文件自述替代。
    const markers = [...Buffer.from(returnLog).toString('utf8').matchAll(/PROBE_RETURN\s+runId=([^\s]+)\s+processPid=(\d+)\s+reportBytes=(\d+)\s+returned=(\d+)\s+verdict=([^\s]+)/g)]
      .filter(match => match[1] === expected.runId && match[2] === String(expected.pid));
    if (markers.length !== 1 || markers[0][3] !== String(report.length) || markers[0][4] !== '1' || markers[0][5] !== 'PASS') reject('Independent function-return marker missing, failed or wrong report byte count');
    result.runId = run.runId; result.pid = expected.pid; result.provider = provider; result.counts = contract.counts;
    result.ok = issues.length === 0; result.verdict = result.ok ? 'PASS' : 'FAIL';
  } catch (error) { reject(error.message); }
  return result;
}

/** CLI只读取明确文件；输出必须仓外。PID、runId和安装库摘要不允许从报告自动补齐。 */
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2), known = new Set(['--report', '--return-marker-file', '--expected-pid', '--expected-run-id', '--expected-library-sha', '--expected-image', '--hap', '--require-initializer', '--out']);
    const flags = {};
    for (let i = 0; i < args.length; i += 2) {
      if (!known.has(args[i]) || !args[i + 1] || Object.hasOwn(flags, args[i])) throw new Error('Invalid/duplicate argument: ' + args[i]);
      flags[args[i]] = args[i + 1];
    }
    for (const flag of ['--report', '--return-marker-file', '--expected-pid', '--expected-run-id', '--expected-library-sha', '--hap']) if (!flags[flag]) throw new Error('Required independent input: ' + flag);
    if (flags['--require-initializer'] && flags['--require-initializer'] !== '1') throw new Error('--require-initializer must be explicit 1');
    const result = auditMgDepthEvidence(fs.readFileSync(flags['--report']), fs.readFileSync(flags['--return-marker-file']), fs.readFileSync(flags['--hap']),
      { pid: Number(flags['--expected-pid']), runId: flags['--expected-run-id'], librarySha256: flags['--expected-library-sha'].toLowerCase(), imagePath: flags['--expected-image'], requireInitializer: flags['--require-initializer'] === '1' });
    const serialized = JSON.stringify(result, null, 2) + '\n';
    if (flags['--out']) { const target = assertExternalOutputPath(flags['--out']); fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, serialized); }
    process.stdout.write(serialized); process.exitCode = result.ok ? 0 : 1;
  } catch (error) { console.error('MG depth evidence FAIL: ' + error.message); process.exitCode = 1; }
}
