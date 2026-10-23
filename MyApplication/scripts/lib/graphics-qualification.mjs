/**
 * 图形离线资格记录的结构、身份及结果校验。
 *
 * 本模块只解释某次 runner 已取得的证据；不会查询 GPU、生成支持状态、修改注册表，
 * 也不会把离线 PASS 转换为运行时 GraphicsAdmission。调用方必须传入独立取得的本次
 * 预期身份及必需用例集合，避免以报告自己的字段验证自己。profile/provider/API 必须
 * 来自现有 GraphicsProfileRegistry 的解析结果，不能建立第二张名称或优先级表。
 */
import { isDeepStrictEqual } from 'node:util';

const RESULTS = new Set(['PASS', 'FAIL', 'NOT_RUN', 'UNSUPPORTED', 'NOT_APPLICABLE']);
const STAGES = new Set(['source', 'host', 'software-graphics', 'target-gpu', 'game', 'lifecycle', 'performance']);
const HEX64 = /^[0-9a-f]{64}$/;
const HEX40 = /^[0-9a-f]{40}$/;

/** JSON对象检查拒绝数组/null；后续只访问自有字段，避免将继承字段当成正式证据。 */
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const text = value => typeof value === 'string' && value.trim().length > 0;
const own = (value, key) => object(value) && Object.hasOwn(value, key);
const stamp = value => text(value) && /(?:Z|[+-]\d\d:\d\d)$/.test(value) && Number.isFinite(Date.parse(value));

/**
 * 未参与本阶段的身份字段必须显式写明原因，不能用空值抹掉 JDK、包或驱动边界。
 * 例如宿主 C++ TU 的 JDK 可写 { notApplicable: true, reason: 'No JVM is created' }。
 */
function identityOrReason(value) {
  return object(value) && ((value.notApplicable === true && text(value.reason)) ||
    (text(value.identity) && !own(value, 'notApplicable')));
}

/**
 * 解析及裁决一份完整记录。input 为 JSON文本或对象；expected 是独立采集的本次绑定，
 * profiles 为权威注册表解析数组。返回 issues 保留所有缺口，valid 只表示结构/身份闭合，
 * qualified 表示该精确范围的全部必需行为通过，verdict 不会用总通过率隐藏失败。
 */
export function auditGraphicsQualification(input, expected, profiles) {
  const issues = [];
  const issue = (path, reason) => issues.push({ path, reason });
  let record;
  try { record = typeof input === 'string' ? JSON.parse(input) : input; }
  catch (error) { return { valid: false, qualified: false, verdict: 'FAIL', issues: [{ path: '$', reason: 'Invalid/truncated JSON: ' + error.message }] }; }
  if (!object(record)) return { valid: false, qualified: false, verdict: 'FAIL', issues: [{ path: '$', reason: 'Record must be an object' }] };
  // 预期输入同样可能来自损坏报告，先限定必需case为字符串集合，再供后续比较使用。
  const requiredCases = Array.isArray(expected?.requiredCases) ? expected.requiredCases : [];
  const requireText = (value, path) => { if (!text(value)) issue(path, 'Non-empty evidence identity required'); };
  const requireHash = (value, path) => { if (!text(value) || !HEX64.test(value)) issue(path, 'SHA256 required'); };
  const requireGroup = key => { if (!own(record, key) || !object(record[key])) { issue(key, 'Evidence group required'); return {}; } return record[key]; };
  if (record.schemaVersion !== 1) issue('schemaVersion', 'Unsupported qualification schema');
  requireText(record.id, 'id');
  if (!stamp(record.capturedAt)) issue('capturedAt', 'Full timestamp with timezone required');
  if (!STAGES.has(record.stage)) issue('stage', 'Explicit verification stage required');
  // 实现状态与验证结果分开；present 也不等于行为已经正确。
  if (!['present', 'missing', 'limited', 'unknown'].includes(record.implementationState))
    issue('implementationState', 'Implementation status required independently of results');

  const implementation = requireGroup('implementation');
  if (!Array.isArray(implementation.sources) || implementation.sources.length === 0) issue('implementation.sources', 'Source identities required');
  else for (const [index, source] of implementation.sources.entries()) {
    if (!object(source)) { issue(`implementation.sources[${index}]`, 'Source object required'); continue; }
    requireText(source.repository, `implementation.sources[${index}].repository`);
    if (!text(source.commit) || !HEX40.test(source.commit)) issue(`implementation.sources[${index}].commit`, 'Full source commit required');
    requireHash(source.treeSha256, `implementation.sources[${index}].treeSha256`);
  }
  // 无patch时保留显式空数组；有patch时顺序及摘要均是构建输入身份。
  if (!Array.isArray(implementation.patches)) issue('implementation.patches', 'Ordered patch array required');
  else for (const [index, patch] of implementation.patches.entries()) {
    requireText(patch?.name, `implementation.patches[${index}].name`);
    requireHash(patch?.sha256, `implementation.patches[${index}].sha256`);
  }
  requireHash(implementation.buildOptionsSha256, 'implementation.buildOptionsSha256');
  requireHash(implementation.toolchainSha256, 'implementation.toolchainSha256');

  const payload = requireGroup('payload');
  if (!Array.isArray(payload.libraries) || payload.libraries.length === 0) issue('payload.libraries', 'Actually tested libraries required');
  else for (const [index, library] of payload.libraries.entries()) {
    requireText(library?.name, `payload.libraries[${index}].name`);
    requireHash(library?.sha256, `payload.libraries[${index}].sha256`);
    requireText(library?.buildId, `payload.libraries[${index}].buildId`);
  }
  if (!identityOrReason(payload.package)) issue('payload.package', 'Final package identity or explicit non-applicability required');

  const call = requireGroup('call');
  const profile = Array.isArray(profiles) ? profiles.find(item => object(item) && item.id === call.profileId) : undefined;
  if (!profile) issue('call.profileId', 'Profile must exist in canonical registry');
  else {
    if (profile.lifecycle === 'retired') issue('call.profileId', 'Retired profile cannot gain qualification');
    if (call.api !== profile.api) issue('call.api', 'API differs from canonical profile');
    if (!Array.isArray(profile.windowProviders) || !profile.windowProviders.includes(call.provider))
      issue('call.provider', 'Provider differs from canonical profile');
  }
  for (const key of ['jdk', 'lwjglSlot', 'classloader']) if (!identityOrReason(call[key]))
    issue(`call.${key}`, 'Actual identity or explicit non-applicability required');

  const platform = requireGroup('platform');
  for (const key of ['os', 'apiLevel', 'gpu', 'driver', 'surface', 'context']) if (!identityOrReason(platform[key]))
    issue(`platform.${key}`, 'Actual platform identity or explicit non-applicability required');
  requireHash(platform.optionsSha256, 'platform.optionsSha256');
  // 软件执行不能伪装为目标GPU；stage和平台字段共同保留证据层级。
  if (['target-gpu', 'game', 'lifecycle', 'performance'].includes(record.stage))
    for (const key of ['gpu', 'driver', 'context']) if (platform[key]?.notApplicable === true)
      issue(`platform.${key}`, 'Target stage requires actual target evidence');

  const test = requireGroup('test');
  requireText(test.runner, 'test.runner');
  requireText(test.version, 'test.version');
  requireHash(test.sourceSha256, 'test.sourceSha256');
  requireHash(test.caseListSha256, 'test.caseListSha256');
  requireText(test.oracle, 'test.oracle');
  // trace未使用时显式记录原因；规范oracle或参考实现必须独立于被测翻译器golden。
  if (!identityOrReason(test.trace)) issue('test.trace', 'Trace identity or non-applicability required');
  if (!object(test.tolerance) || !text(test.tolerance.definition)) issue('test.tolerance', 'Fixed numerical/image tolerance definition required');

  const execution = requireGroup('execution');
  requireText(execution.runId, 'execution.runId');
  if (!Number.isInteger(execution.pid) || execution.pid <= 0) issue('execution.pid', 'Fresh positive process identity required');
  if (!stamp(execution.startedAt) || !stamp(execution.finishedAt) || Date.parse(execution.finishedAt) < Date.parse(execution.startedAt))
    issue('execution', 'Real ordered start/end timestamps with timezone required');
  if (execution.completed !== true) issue('execution.completed', 'Incomplete execution cannot qualify');
  if (execution.termination !== 'normal' || execution.exitCode !== 0) issue('execution.termination', 'Forced/abnormal exit cannot qualify as normal completion');
  requireHash(execution.logSha256, 'execution.logSha256');

  // 预期记录必须来自调用方的实际快照；没有独立绑定时只能解析，绝不获得资格。
  if (!object(expected) || requiredCases.length === 0 || requiredCases.some(id => !text(id)) ||
      new Set(requiredCases).size !== requiredCases.length) {
    issue('expected', 'Independent expected identity and non-empty mandatory case list required');
  } else {
    // 明显的同对象自校验也拒绝。深复制不能证明独立来源，因此调用方仍须从runner和
    // 被测文件实取expected；本模块的PASS只证明其传入身份一致，不是物理取证替代品。
    if (record === expected) issue('expected', 'A report cannot serve as its own independent expectation');
    if (record.stage !== expected.stage) issue('stage', 'Verification stage differs from independent expectation');
    for (const key of ['implementation', 'payload', 'call', 'platform', 'test']) {
      if (record[key] === expected[key]) issue('expected.' + key, 'Shared report object is not an independent expected capture');
      if (!own(expected, key) || !isDeepStrictEqual(record[key], expected[key])) issue(key, 'Evidence identity mismatch with independently captured expectation');
    }
    // PID本身会被复用，因此同时绑定新runId、真实时间窗和日志字节；只有格式正确的
    // SHA不能证明报告引用的是本轮日志，不能允许同PID但旧日志或错误证据借用。
    for (const key of ['runId', 'pid', 'startedAt', 'finishedAt', 'logSha256']) if (!own(expected.execution, key) || execution[key] !== expected.execution[key])
      issue(`execution.${key}`, 'Execution identity mismatch');
  }
  // limited只对明确定义的局部能力域成立。范围依据和已覆盖case必须独立绑定，不能
  // 仅将实现状态改成limited就隐去已宣告范围中的缺陷，也不能用报告自己的白名单资格化。
  if (record.implementationState === 'limited') {
    const scope = record.implementationScope;
    if (!object(scope) || !text(scope.basis) || !text(scope.limitations) || !Array.isArray(scope.coveredCases) ||
        requiredCases.some(id => !scope.coveredCases.includes(id)))
      issue('implementationScope', 'Limited implementation needs a justified scope covering every mandatory case');
    if (!object(expected?.implementationScope) || scope === expected.implementationScope ||
        !isDeepStrictEqual(scope, expected.implementationScope))
      issue('implementationScope', 'Limited scope must match independent qualification scope');
  }

  const cases = record.cases;
  const caseIds = new Set();
  if (!Array.isArray(cases) || cases.length === 0) issue('cases', 'Completed case records required');
  else for (const [index, item] of cases.entries()) {
    if (!object(item) || !text(item.id) || caseIds.has(item.id)) { issue(`cases[${index}]`, 'Unique case identity required'); continue; }
    caseIds.add(item.id);
    if (!RESULTS.has(item.result)) issue(`cases[${index}].result`, 'Explicit case verdict required');
    requireText(item.evidence, `cases[${index}].evidence`);
    if (item.result !== 'PASS') requireText(item.reason, `cases[${index}].reason`);
    if (item.result === 'NOT_APPLICABLE' && requiredCases.includes(item.id))
      issue(`cases[${index}]`, 'Mandatory advertised behavior cannot be excluded');
  }
  for (const id of requiredCases) if (!caseIds.has(id)) issue('cases', 'Missing mandatory case: ' + id);
  const valid = issues.length === 0;
  if (!valid) return { valid, qualified: false, verdict: 'FAIL', issues };
  // 必需UNSUPPORTED/NOT_RUN如实保留，但qualified始终为false；任一失败不得被通过率吞掉。
  const required = cases.filter(item => requiredCases.includes(item.id));
  const verdict = cases.some(item => item.result === 'FAIL') ? 'FAIL'
    : record.implementationState === 'missing' ? 'UNSUPPORTED'
    : record.implementationState === 'unknown' ? 'NOT_RUN'
    : required.some(item => item.result === 'NOT_RUN') ? 'NOT_RUN'
    : required.some(item => item.result === 'UNSUPPORTED') ? 'UNSUPPORTED' : 'PASS';
  return { valid, qualified: verdict === 'PASS', verdict, issues };
}
