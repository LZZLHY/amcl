/**
 * preflight 的严格选择、依赖计划与执行收据。只负责调度已注册的原检查函数，
 * 不实现业务门禁、不复用旧 PASS、不选择产品，也不自行创建输出目录。
 */
import { performance } from 'node:perf_hooks';

export class PreflightConfigurationError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = 'PreflightConfigurationError';
    this.code = code;
    this.details = details;
  }
}

function configurationError(code, message, details) {
  throw new PreflightConfigurationError(code, message, details);
}

/** 参数缺值、重复或拼错都拒绝，防止不认识的选择项退化为零检查成功。 */
export function parsePreflightArguments(argv) {
  const options = { only: null, skip: [], report: null, json: false, plan: false, help: false };
  const seen = new Set();
  for (let index = 0; index < argv.length; index++) {
    const token = argv[index];
    const match = /^--([a-z-]+)(?:=(.*))?$/.exec(token);
    if (!match) configurationError('UNKNOWN_ARGUMENT', `Unknown argument: ${token}`);
    const [, name, inline] = match;
    if (!['only', 'skip', 'report', 'json', 'plan', 'help'].includes(name)) {
      configurationError('UNKNOWN_ARGUMENT', `Unknown option: --${name}`);
    }
    if (seen.has(name)) configurationError('DUPLICATE_OPTION', `Option repeated: --${name}`);
    seen.add(name);
    if (['json', 'plan', 'help'].includes(name)) {
      if (inline !== undefined) configurationError('UNEXPECTED_VALUE', `--${name} does not accept a value`);
      options[name] = true;
      continue;
    }
    let value = inline;
    if (value === undefined && index + 1 < argv.length && !argv[index + 1].startsWith('--')) value = argv[++index];
    if (typeof value !== 'string' || value.trim() === '') {
      configurationError('MISSING_VALUE', `--${name} requires a non-empty value`);
    }
    if (name === 'report') {
      options.report = value;
      continue;
    }
    const ids = value.split(',').map(id => id.trim());
    if (ids.some(id => !id)) configurationError('EMPTY_SELECTOR', `--${name} contains an empty gate name`);
    if (new Set(ids).size !== ids.length) configurationError('DUPLICATE_SELECTOR', `--${name} contains repeated gate names`);
    options[name] = ids;
  }
  if (options.only !== null && seen.has('skip')) {
    configurationError('CONFLICTING_SELECTORS', '--only and --skip cannot be combined');
  }
  return options;
}

/** 先验证整个注册表，再按原注册顺序构造稳定拓扑序；未选门也不能隐藏坏依赖。 */
export function planPreflightChecks(checks, options = {}) {
  if (!Array.isArray(checks) || checks.length === 0) configurationError('EMPTY_REGISTRY', 'No preflight gates registered');
  const byId = new Map();
  for (const check of checks) {
    if (!check || typeof check.id !== 'string' || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(check.id)) {
      configurationError('INVALID_GATE', 'Each gate requires a stable lower-case id');
    }
    if (byId.has(check.id)) configurationError('DUPLICATE_GATE', `Gate registered twice: ${check.id}`);
    if (typeof check.fn !== 'function') configurationError('MISSING_EXECUTOR', `Gate has no executor: ${check.id}`);
    const dependencies = check.dependencies ?? [];
    if (!Array.isArray(dependencies) || dependencies.some(id => typeof id !== 'string') || new Set(dependencies).size !== dependencies.length) {
      configurationError('INVALID_DEPENDENCIES', `Invalid dependencies for gate: ${check.id}`);
    }
    byId.set(check.id, { ...check, dependencies: [...dependencies] });
  }
  for (const check of byId.values()) {
    for (const dependency of check.dependencies) {
      if (!byId.has(dependency)) configurationError('MISSING_DEPENDENCY', `Gate ${check.id} depends on unknown gate ${dependency}`);
    }
  }
  const visited = new Set();
  const visiting = new Set();
  function validateAcyclic(id, chain) {
    if (visiting.has(id)) configurationError('DEPENDENCY_CYCLE', `Dependency cycle: ${[...chain, id].join(' -> ')}`);
    if (visited.has(id)) return;
    visiting.add(id);
    for (const dependency of byId.get(id).dependencies) validateAcyclic(dependency, [...chain, id]);
    visiting.delete(id);
    visited.add(id);
  }
  for (const id of byId.keys()) validateAcyclic(id, []);

  const only = options.only ?? null;
  const skip = options.skip ?? [];
  if ((only !== null && (!Array.isArray(only) || only.length === 0)) || !Array.isArray(skip)) {
    configurationError('EMPTY_SELECTOR', 'An explicit --only selection cannot be empty');
  }
  if (only !== null && skip.length > 0) configurationError('CONFLICTING_SELECTORS', '--only and --skip cannot be combined');
  for (const [name, ids] of [['only', only ?? []], ['skip', skip]]) {
    if (new Set(ids).size !== ids.length) configurationError('DUPLICATE_SELECTOR', `--${name} contains repeated gate names`);
    for (const id of ids) {
      if (!byId.has(id)) configurationError('UNKNOWN_GATE', `Unknown --${name} gate: ${id}`, { option: name, gate: id });
    }
  }
  const skipped = new Set(skip);
  const requestedIds = [...byId.keys()].filter(id => only !== null ? only.includes(id) : !skipped.has(id));
  if (requestedIds.length === 0) configurationError('EMPTY_SELECTION', 'Selection contains no executable preflight gates');
  const selectedIds = [];
  const selected = new Set();
  function include(id, dependent) {
    if (skipped.has(id)) configurationError('SKIPPED_DEPENDENCY', `Gate ${dependent} requires explicitly skipped gate ${id}`);
    if (selected.has(id)) return;
    for (const dependency of byId.get(id).dependencies) include(dependency, id);
    selected.add(id);
    selectedIds.push(id);
  }
  for (const id of requestedIds) include(id, id);
  const requested = new Set(requestedIds);
  return {
    checks: [...byId.values()],
    registeredIds: [...byId.keys()],
    requestedIds,
    selectedIds,
    dependencyAddedIds: selectedIds.filter(id => !requested.has(id)),
    deferredIds: [...byId.keys()].filter(id => !selected.has(id)),
    selectionReasons: Object.fromEntries([...byId.keys()].map(id => [id,
      selected.has(id) ? (requested.has(id) ? 'requested' : 'dependency') : (skipped.has(id) ? 'explicit-skip' : 'outside-only')])),
    scope: only !== null || skip.length > 0 ? 'selection' : 'full',
  };
}

function initialRows(plan, selectedStatus) {
  const selected = new Set(plan.selectedIds);
  return plan.checks.map(check => ({
    id: check.id,
    dependencies: [...check.dependencies],
    selected: selected.has(check.id),
    selectionReason: plan.selectionReasons[check.id],
    status: selected.has(check.id) ? selectedStatus : 'DEFERRED',
    attempted: false,
    executed: false,
    startedAt: null,
    finishedAt: null,
    durationMs: 0,
  }));
}

function coverage(plan, rows) {
  const idsWithStatus = status => rows.filter(row => row.status === status).map(row => row.id);
  return {
    registeredIds: [...plan.registeredIds],
    requestedIds: [...plan.requestedIds],
    selectedIds: [...plan.selectedIds],
    dependencyAddedIds: [...plan.dependencyAddedIds],
    deferredIds: [...plan.deferredIds],
    attemptedIds: rows.filter(row => row.attempted).map(row => row.id),
    executedIds: rows.filter(row => row.executed).map(row => row.id),
    passedIds: idsWithStatus('PASS'),
    failedIds: idsWithStatus('FAIL'),
    skippedIds: idsWithStatus('SKIPPED'),
    blockedIds: idsWithStatus('BLOCKED'),
    complete: rows.every(row => row.status === 'PASS'),
  };
}

/** 只产生计划数据，不调用任何检查函数，不创建目录或宣称已经通过。 */
export function preflightPlanReceipt(plan, { now = () => new Date().toISOString() } = {}) {
  const timestamp = now();
  const rows = initialRows(plan, 'PLANNED');
  return { schemaVersion: 1, kind: 'amcl-preflight', status: 'PLANNED', ok: null,
    scope: plan.scope, startedAt: timestamp, finishedAt: timestamp, durationMs: 0,
    executionOrder: [...plan.selectedIds], coverage: coverage(plan, rows), checks: rows };
}

function normalizedResult(result) {
  if (!result || typeof result !== 'object') return { status: 'FAIL', summary: 'Gate returned no structured result', reason: 'INVALID_RESULT' };
  const status = result.status ?? (result.ok === true ? 'PASS' : 'FAIL');
  if (!['PASS', 'FAIL', 'SKIPPED'].includes(status) || (status === 'PASS' && result.ok !== true)) {
    return { status: 'FAIL', summary: 'Gate returned an invalid or contradictory status', reason: 'INVALID_RESULT' };
  }
  return { status, summary: typeof result.summary === 'string' ? result.summary : '',
    ...(result.detail != null ? { detail: String(result.detail) } : {}),
    ...(result.reason != null ? { reason: String(result.reason) } : {}),
    ...(Array.isArray(result.missingTools) ? { missingTools: result.missingTools.map(String) } : {}) };
}

/** 顺序执行依赖闭包；失败门的依赖方只记 BLOCKED，其他独立检查继续保留证据。 */
export async function executePreflightPlan(plan, {
  now = () => new Date().toISOString(), clock = () => performance.now(),
  onStart = () => {}, onResult = () => {},
} = {}) {
  const startedAt = now();
  const start = clock();
  const rows = initialRows(plan, 'PENDING');
  const rowById = new Map(rows.map(row => [row.id, row]));
  const byId = new Map(plan.checks.map(check => [check.id, check]));
  for (const id of plan.selectedIds) {
    const check = byId.get(id);
    const row = rowById.get(id);
    const blockedBy = check.dependencies.filter(dependency => rowById.get(dependency).status !== 'PASS');
    if (blockedBy.length > 0) {
      Object.assign(row, { status: 'BLOCKED', blockedBy, summary: `Dependencies did not pass: ${blockedBy.join(', ')}` });
      onResult(row);
      continue;
    }
    row.startedAt = now();
    row.attempted = true;
    const gateStart = clock();
    onStart(row);
    try {
      Object.assign(row, normalizedResult(await check.fn()));
    } catch (error) {
      Object.assign(row, { status: 'FAIL', reason: 'EXCEPTION', summary: `EXCEPTION: ${error?.message ?? String(error)}`,
        detail: error?.stack ?? String(error) });
    }
    // 缺工具时只尝试了前置能力检查，真正门禁没有执行；与异常失败分别表述。
    row.executed = row.status !== 'SKIPPED';
    row.finishedAt = now();
    row.durationMs = Math.max(0, clock() - gateStart);
    onResult(row);
  }
  const selectedRows = rows.filter(row => row.selected);
  const ok = selectedRows.every(row => row.status === 'PASS');
  const receiptCoverage = coverage(plan, rows);
  return { schemaVersion: 1, kind: 'amcl-preflight', status: !ok ? 'FAILED' : receiptCoverage.complete ? 'PASS' : 'PARTIAL_PASS',
    ok, scope: plan.scope, startedAt, finishedAt: now(), durationMs: Math.max(0, clock() - start),
    executionOrder: [...plan.selectedIds], coverage: receiptCoverage, checks: rows };
}
