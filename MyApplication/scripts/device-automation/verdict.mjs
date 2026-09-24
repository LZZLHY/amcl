#!/usr/bin/env node
// 判决模型 —— 契约 §8.4（五值）与 §8.5（三份文件）的机械化部分。
//
// 这里的每条断言都对应一种"把工具问题误报成产品问题"或"把没观察到写成 PASS"的路径。
// 全部是纯函数，供 scripts/test-device-automation.mjs 正反向验证。

/** 契约 §8.4 的五个值，缺一不可。 */
export const VERDICTS = ['PASS', 'FAIL', 'INCONCLUSIVE', 'INVALID', 'BLOCKED'];

/**
 * 由轻到重。聚合取"最重的那个"。
 * INVALID 最重：证据自相矛盾意味着这一轮的其它结论也不可信。
 */
export const SEVERITY_ORDER = ['PASS', 'BLOCKED', 'INCONCLUSIVE', 'FAIL', 'INVALID'];

/** 契约 §9.3 / 方案 G8：结束方式必须记录，且取值受限。 */
export const END_METHODS = ['force-stop', 'mcForceExit', 'in-game-quit', 'crash', 'system-kill'];

/** 只有游戏内退出菜单能产生真正的正常退出（契约 §9.3 第 2 条）。 */
export const NORMAL_EXIT_END_METHOD = 'in-game-quit';

/** 四类证据（契约 §8.1）。E1 是应用自述，可信度最低。 */
export const EVIDENCE_KINDS = ['E1', 'E2', 'E3', 'E4'];
const SELF_REPORT_ONLY = 'E1';

export function severityOf(verdict) {
  const index = SEVERITY_ORDER.indexOf(verdict);
  return index < 0 ? SEVERITY_ORDER.length : index;
}

/**
 * 聚合多格判决。
 *
 * ⚠️ 刻意**不做**"预期阻塞白名单"：一旦允许某些格子不进聚合，那份白名单就会长期
 * 存在并逐渐盖住真失败（`AGENTS.md` §二.6 的形状）。⇒ 有 BLOCKED 就聚合成 BLOCKED、
 * 退出码非零，报告里写明阻塞于哪一批。P0 首轮**本来就应该**是 BLOCKED，那是正确结果。
 */
export function aggregateVerdict(scenarios) {
  if (!Array.isArray(scenarios) || scenarios.length === 0) {
    return 'INCONCLUSIVE';
  }
  let worst = 'PASS';
  for (const scenario of scenarios) {
    if (severityOf(scenario?.verdict) > severityOf(worst)) worst = scenario.verdict;
  }
  return worst;
}

/** 契约 §8.4：PASS 为 0，其余非 0。 */
export function exitCodeFor(verdict) {
  return verdict === 'PASS' ? 0 : 1;
}

/**
 * 校验一格判决的自洽性。返回 issues 数组（空 = 自洽）。
 *
 * 违反其中任何一条都不是"风格问题"：它们各自堵掉一条已知的错误结论路径。
 */
export function validateScenario(scenario) {
  const issues = [];
  const id = scenario?.id ?? '<no id>';

  if (!scenario || typeof scenario !== 'object') return [`${id}: scenario must be an object`];
  if (typeof scenario.id !== 'string' || scenario.id.trim() === '') {
    issues.push(`${id}: id must be a non-empty string`);
  }
  if (!VERDICTS.includes(scenario.verdict)) {
    issues.push(`${id}: verdict '${scenario.verdict}' is not one of ${VERDICTS.join('/')}`);
    return issues;
  }

  const missing = Array.isArray(scenario.missing) ? scenario.missing : null;
  if (missing === null) {
    issues.push(`${id}: missing[] must be an array (empty is fine when nothing is missing)`);
  }

  // 契约 §8.5 硬约束 2：把"未观察到"写成 PASS 的路堵死。
  if (scenario.verdict === 'INCONCLUSIVE' && (missing?.length ?? 0) === 0) {
    issues.push(`${id}: INCONCLUSIVE requires a non-empty missing[] (contract §8.5)`);
  }
  if (scenario.verdict === 'PASS' && (missing?.length ?? 0) > 0) {
    issues.push(`${id}: PASS must not carry missing[] entries (${missing.join(', ')})`);
  }

  // BLOCKED 必须说清阻塞在哪一批，否则下一轮无法判断它是否已经解锁。
  if (scenario.verdict === 'BLOCKED') {
    if (typeof scenario.blockedBy !== 'string' || scenario.blockedBy.trim() === '') {
      issues.push(`${id}: BLOCKED requires blockedBy (which batch unblocks it)`);
    }
  }

  const evidence = scenario.evidence ?? {};
  const present = EVIDENCE_KINDS.filter(kind => evidence[kind] === true);
  if (scenario.verdict === 'PASS') {
    // 契约 §8.1/§8.2：应用自述可信度最低，不得单凭它判 PASS。
    if (present.length === 0) {
      issues.push(`${id}: PASS requires at least one evidence channel to be true`);
    } else if (present.length === 1 && present[0] === SELF_REPORT_ONLY) {
      issues.push(
        `${id}: PASS relies on ${SELF_REPORT_ONLY} (app self-report) only; ` +
        'contract §8.1 ranks it lowest — need at least one host-side channel');
    }
    // §1.2：判据必须是可以数的量，不是一次性声明。
    const counters = scenario.counters ?? {};
    if (Object.keys(counters).length === 0) {
      issues.push(`${id}: PASS requires at least one counter (contract §1.2 monotonic evidence)`);
    }
  }

  if (scenario.endMethod !== undefined && scenario.endMethod !== null) {
    if (!END_METHODS.includes(scenario.endMethod)) {
      issues.push(`${id}: endMethod '${scenario.endMethod}' is not one of ${END_METHODS.join('/')}`);
    }
  }

  // 契约 §9.3 第 3 条：结束方式不是 in-game-quit 的会话，不得声称验证了正常退出。
  const claims = Array.isArray(scenario.claims) ? scenario.claims : [];
  if (claims.includes('normal_exit') && scenario.endMethod !== NORMAL_EXIT_END_METHOD) {
    issues.push(
      `${id}: claims normal_exit but endMethod is '${scenario.endMethod}'; ` +
      `only ${NORMAL_EXIT_END_METHOD} can produce it (contract §9.3)`);
  }

  // 契约 §7.5 第 7/13 条的场景侧投影：T2 从平台层下游注入 ⇒ 必须声明它不能证明什么，
  // 且判据不得引用被禁类别。
  //
  // ⚠️ P0 一格 T2 都没有 ⇒ 这两条在本轮永不触发。这正是 `AGENTS.md` §二.6 警告的
  // "声称存在但从不生效"形状，因此反向自测里有一条合成 T2 场景专门把它打出来。
  if (scenario.tier === 'T2') {
    const mustNotProve = Array.isArray(scenario.mustNotProve) ? scenario.mustNotProve : [];
    if (mustNotProve.length === 0) {
      issues.push(`${id}: tier T2 requires a non-empty mustNotProve (contract §7.5 #7)`);
    }
    for (const forbidden of mustNotProve) {
      if (claims.includes(forbidden)) {
        issues.push(
          `${id}: claims '${forbidden}' which its own mustNotProve forbids ` +
          '(contract §7.5 #13)');
      }
    }
  }

  return issues;
}

/** 校验整份 summary。 */
export function validateSummary(summary) {
  const issues = [];
  if (summary?.schema !== 1) issues.push(`summary.schema must be 1; got ${summary?.schema}`);
  if (typeof summary?.runId !== 'string' || summary.runId.trim() === '') {
    issues.push('summary.runId must be a non-empty string');
  }
  if (!Array.isArray(summary?.scenarios) || summary.scenarios.length === 0) {
    issues.push('summary.scenarios must be a non-empty array');
    return issues;
  }
  const seen = new Set();
  for (const scenario of summary.scenarios) {
    if (seen.has(scenario?.id)) issues.push(`duplicate scenario id ${scenario.id}`);
    seen.add(scenario?.id);
    issues.push(...validateScenario(scenario));
  }
  const expected = aggregateVerdict(summary.scenarios);
  if (summary.verdict !== expected) {
    issues.push(`summary.verdict '${summary.verdict}' disagrees with aggregate '${expected}'`);
  }
  if (!Array.isArray(summary?.unknownsTouched)) {
    issues.push('summary.unknownsTouched must be an array (empty is fine)');
  }
  return issues;
}
