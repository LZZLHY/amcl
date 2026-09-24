#!/usr/bin/env node
// scripts/device-automation/* 的定向自测（正向 + **反向**）。
//
// 为什么需要它（AGENTS.md §二.8 / 方案 §7 风险 5）：判定工具写错时的失败形态是
// **静默放行** —— 正则永远匹配不到 ⇒ 判据永远不失败 ⇒ 报告永远是绿的。
// 因此这里对每条判据都跑两侧：
//   ① 已知**含有**目标的样本上必须命中；
//   ② 已知**不含**目标的样本上必须不命中。
//
// ⭐ 两个"已知样本"是 2026-09-07 第一轮真机探针留下的真实日志（探针 README §6 记了
// sha256）：`amcl_launcher_b1c.log` 含 `key=777` 那行、`amcl_launcher_after_ps.log`
// 不含（那正是落盘窗口 §S03.3 的证据）。⇒ 天然是一对正/负样本。
// 它们在 `.logs/`（被 .gitignore 忽略）⇒ CI 上取不到，此时样本组显式 SKIP，
// 合成 fixture 组仍然全跑（不能因为样本缺失就让整组静默通过）。

import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { assertSingleShellCommand, HdcError } from './device-automation/hdc.mjs';
import {
  countAmclLines, findBorrowedConsumerHits, findBundleProcesses, findSessionStarts,
  isAmclLine, isPersistentSentinel, parseBmDump, parseDeviceDate, parseFileLogLine,
  parseFportRules, parseHdcVersion, parseHilogLine, parseLsNames, parseParamValue,
  parseTargets, parseUitestVersion, validateTimeAnchor, PERSISTENT_SENTINEL,
} from './device-automation/parse.mjs';
import {
  aggregateVerdict, exitCodeFor, validateScenario, validateSummary,
} from './device-automation/verdict.mjs';
import { buildScenarios, BLOCKED_CELLS } from './device-automation/scenarios.mjs';
import { assertNoSecrets, collectSelfClosure, redactSn } from './device-automation/artifacts.mjs';

const repoRoot = resolve(fileURLToPath(new URL('..', import.meta.url)));

let failures = 0;
let checks = 0;
function check(name, fn) {
  checks += 1;
  try {
    fn();
  } catch (error) {
    failures += 1;
    console.error(`  FAIL  ${name}\n        ${error?.message ?? error}`);
  }
}
function assert(condition, message) {
  if (!condition) throw new Error(message);
}
function assertEqual(actual, expected, message) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message}: expected ${e}, got ${a}`);
}
/** 断言 issues 里有某一条（按子串）。 */
function assertIssue(issues, needle, message) {
  assert(issues.some(issue => issue.includes(needle)),
    `${message}: no issue matching '${needle}' in ${JSON.stringify(issues)}`);
}

// ============================================================
//  ① 工具与设备身份解析
// ============================================================

check('parseHdcVersion 正向', () => {
  assertEqual(parseHdcVersion('Ver: 3.2.0f\n'), '3.2.0f', 'version');
});
check('parseHdcVersion 反向（无版本行）', () => {
  assertEqual(parseHdcVersion('nothing here'), null, 'version');
});

check('parseTargets 正向', () => {
  assertEqual(parseTargets('59JYD25815201311\n'), ['59JYD25815201311'], 'targets');
});
check('parseTargets 反向：[Empty] 不是一台设备', () => {
  assertEqual(parseTargets('[Empty]\n\n'), [], 'targets');
});

check('parseParamValue 去掉实测存在的尾随空格', () => {
  assertEqual(parseParamValue('MRDI-W10 \n'), 'MRDI-W10', 'param');
  assertEqual(parseParamValue('  \n'), null, 'empty param');
});

check('parseUitestVersion 反向：非版本串不接受', () => {
  assertEqual(parseUitestVersion('6.0.2.3'), '6.0.2.3', 'version');
  assertEqual(parseUitestVersion('command not found'), null, 'garbage');
});

check('parseBmDump 能吃下 metaData/metadata 大小写重复键', () => {
  // 这份最小 fixture 复刻真机 `bm dump` 的两个特征：前缀行 + 大小写重复键。
  // PowerShell 的 ConvertFrom-Json 在这里会直接拒收（实测），Node 不会。
  const text = 'com.amcl.launcher:\n' + JSON.stringify({
    name: 'com.amcl.launcher',
    versionCode: 1000591,
    versionName: '1.0.3',
    metaData: {}, metadata: {},
    applicationInfo: { appProvisionType: 'debug', debug: true, apiTargetVersion: 60100023 },
  });
  const parsed = parseBmDump(text);
  assert(parsed.ok, 'should parse');
  assertEqual(parsed.versionCode, 1000591, 'versionCode');
  assertEqual(parsed.provisionType, 'debug', 'provisionType');
  assertEqual(parsed.debug, true, 'debug');
});
check('parseBmDump 反向：没有 JSON 时不假装成功', () => {
  assert(parseBmDump('error: bundle not found').ok === false, 'should not be ok');
  assert(parseBmDump('com.x:\n{ broken').ok === false, 'broken JSON must not be ok');
});

// ============================================================
//  ② 进程匹配 —— 实测的 15 字符截断陷阱
// ============================================================

const PS_TEXT = [
  '   PID TTY          TIME CMD            ',
  '     1 ?        00:01:47 init',
  ' 57925 ?        00:00:11 m.amcl.launcher',
  ' 12345 ?        00:00:01 com.other.app',
].join('\n');

check('findBundleProcesses 命中被截断到 15 字符的进程名', () => {
  const hits = findBundleProcesses(PS_TEXT, 'com.amcl.launcher');
  assertEqual(hits.length, 1, 'hit count');
  assertEqual(hits[0].pid, 57925, 'pid');
  assertEqual(hits[0].rule, 'truncated-suffix', 'match rule must be reported');
});
check('findBundleProcesses 反向：别的应用不得命中', () => {
  assertEqual(findBundleProcesses(PS_TEXT, 'com.someone.else').length, 0, 'must not match');
});
check('findBundleProcesses 反向：过短后缀不得命中（避免 `r` 之类误伤）', () => {
  const text = '   PID TTY          TIME CMD\n  4242 ?        00:00:01 r';
  assertEqual(findBundleProcesses(text, 'com.amcl.launcher').length, 0, 'must not match');
});
check('findBundleProcesses 正向：完整名也能命中', () => {
  const text = '   PID TTY          TIME CMD\n  4242 ?        00:00:01 com.amcl.launcher';
  const hits = findBundleProcesses(text, 'com.amcl.launcher');
  assertEqual(hits[0].rule, 'exact', 'rule');
});

// ============================================================
//  ③ hilog 两种时间戳格式
// ============================================================

const HILOG_DEFAULT = '09-07 17:00:58.975 10467 10467 W C02C02/PARAM: SystemReadParam failed!';
const HILOG_ZONED =
  'CST 2026-09-07 13:21:29.123 41120 51741 I A0A003/com.amcl.launcher/EntryAbility: Ability onCreate';

check('parseHilogLine 解析默认格式（无年份/时区）', () => {
  const parsed = parseHilogLine(HILOG_DEFAULT);
  assert(parsed !== null, 'should parse');
  assertEqual(parsed.year, null, 'year absent');
  assertEqual(parsed.pid, 10467, 'pid');
  assertEqual(parsed.level, 'W', 'level');
  assertEqual(parsed.tag, 'PARAM', 'tag');
  assertEqual(isAmclLine(parsed), false, 'PARAM is not an AMCL domain');
});
check('parseHilogLine 解析 -v year -v zone -v msec 格式', () => {
  const parsed = parseHilogLine(HILOG_ZONED);
  assert(parsed !== null, 'should parse');
  assertEqual(parsed.year, 2026, 'year');
  assertEqual(parsed.zone, 'CST', 'zone');
  assertEqual(parsed.domain, 0xa003, 'domain (launch)');
  assertEqual(parsed.tag, 'EntryAbility', 'tag is last path segment');
  assertEqual(isAmclLine(parsed), true, 'A0A003 is AMCL launch domain');
});
check('parseHilogLine 反向：非日志行返回 null（不得瞎猜）', () => {
  assertEqual(parseHilogLine('Mutlti commands can\'t be used in combination'), null, 'garbage');
  assertEqual(parseHilogLine(''), null, 'empty');
});

check('countAmclLines 只数 AMCL domain，并统计未解析行', () => {
  const text = [HILOG_ZONED, HILOG_DEFAULT, 'garbage line', HILOG_ZONED].join('\n');
  const counts = countAmclLines(text);
  assertEqual(counts.total, 2, 'amcl lines');
  assertEqual(counts.byDomain.launch, 2, 'launch domain count');
  assertEqual(counts.unparsed, 1, 'unparsed');
});

check('isPersistentSentinel 认出那条清不掉的哨兵行', () => {
  assertEqual(
    isPersistentSentinel(`09-03 02:32:44.571 0 0 I I00000/HiLog: ${PERSISTENT_SENTINEL}`),
    true, 'sentinel');
  assertEqual(isPersistentSentinel(HILOG_ZONED), false, 'normal line');
});

// ============================================================
//  ④ 借既有消费者的判据（合成 fixture）
// ============================================================

check('findBorrowedConsumerHits 不依赖箭头字符', () => {
  // 三种可能的编码结果都必须命中：原样 UTF-8、被转成 `?`、被丢掉。
  for (const arrow of ['→', '?', '']) {
    const line = `[2026-09-07 13:22:51][I][EntryAbility] notification tap ${arrow} open error sheet key=777`;
    assertEqual(findBorrowedConsumerHits(line, 777).length, 1, `arrow=${JSON.stringify(arrow)}`);
  }
});
check('findBorrowedConsumerHits 反向：key 不同不得命中（防止把上一轮的行算进来）', () => {
  const line = 'notification tap → open error sheet key=4242';
  assertEqual(findBorrowedConsumerHits(line, 777).length, 0, 'different key');
  assertEqual(findBorrowedConsumerHits(line, 4242).length, 1, 'same key');
  assertEqual(findBorrowedConsumerHits(line).length, 1, 'no key filter');
});
check('findBorrowedConsumerHits 反向：不含该行的文本必须 0 命中', () => {
  assertEqual(findBorrowedConsumerHits('Ability onCreate\nSucceeded in loading the content.').length,
    0, 'unrelated log');
});

check('findSessionStarts 正向 + 反向', () => {
  const text = [
    '========== AMCL Session Start: 2026-09-07 13:21:29 ==========',
    '[2026-09-07 13:21:29][I][EntryAbility] hello',
    '========== AMCL Session Start: 2026-09-07 14:00:00 ==========',
  ].join('\n');
  assertEqual(findSessionStarts(text).length, 2, 'two sessions');
  assertEqual(findSessionStarts('no banner here').length, 0, 'none');
});

check('parseFileLogLine 实测形状', () => {
  const parsed = parseFileLogLine('[2026-09-07 13:22:51][I][EntryAbility] notification tap');
  assertEqual(parsed.level, 'I', 'level');
  assertEqual(parsed.tag, 'EntryAbility', 'tag');
  assertEqual(parseFileLogLine('plain line'), null, 'non-matching');
});

// ============================================================
//  ⑤ 时间锚点 —— 本组是承重项
// ============================================================

check('validateTimeAnchor 拒绝"缓冲区最早一行"', () => {
  const issues = validateTimeAnchor({
    method: 'earliest-buffer-line', deviceTime: 'x', hostTime: 'y',
  });
  assertIssue(issues, 'not allowed', 'earliest-buffer-line must be rejected');
});
check('validateTimeAnchor 接受 borrowed-consumer 并要求两侧时间', () => {
  assertEqual(
    validateTimeAnchor({ method: 'borrowed-consumer', deviceTime: 'd', hostTime: 'h' }),
    [], 'valid anchor');
  assertIssue(validateTimeAnchor({ method: 'borrowed-consumer', deviceTime: 'd' }),
    'hostTime', 'missing hostTime must be reported');
});

check('parseDeviceDate 正向 + 反向', () => {
  assertEqual(parseDeviceDate('2026-09-07T16:52:46+0800\n'), '2026-09-07T16:52:46+0800', 'date');
  assertEqual(parseDeviceDate('date: invalid option'), null, 'garbage');
});

// ============================================================
//  ⑥ ls / fport
// ============================================================

check('parseLsNames 反向：目录不存在时返回空数组而不是 6 个"条目"', () => {
  assertEqual(parseLsNames('ls: /x/y: No such file or directory'), [], 'missing dir');
});
check('parseLsNames 正向', () => {
  assertEqual(parseLsNames('1.16.5  26.2\nfabric-loader-0.19.3-1.20.1\n').length, 3, 'three dirs');
});
check('parseFportRules 反向：[Empty] 不是一条规则', () => {
  assertEqual(parseFportRules('[Empty]'), [], 'no rules');
  assertEqual(parseFportRules('tcp:18500 tcp:18500').length, 1, 'one rule');
});

// ============================================================
//  ⑦ hdc shell 单命令约束
// ============================================================

check('assertSingleShellCommand 拒绝管道与串联', () => {
  for (const bad of ['ps -A | grep amcl', 'a && b', 'a; b', 'ls > x']) {
    let threw = false;
    try { assertSingleShellCommand(bad); } catch (error) {
      threw = error instanceof HdcError;
    }
    assert(threw, `must reject ${JSON.stringify(bad)}`);
  }
  assertSingleShellCommand('ps -A');
});

// ============================================================
//  ⑧ 判决模型 —— 每条断言都跑反向
// ============================================================

const goodScenario = {
  id: 'smoke.cold-start',
  verdict: 'PASS',
  missing: [],
  evidence: { E1: false, E2: true, E3: true, E4: false },
  counters: { amclHilogLines: { before: 0, after: 12 } },
  endMethod: 'force-stop',
  claims: [],
};

check('validateScenario 正向：自洽的 PASS 无 issue', () => {
  assertEqual(validateScenario(goodScenario), [], 'valid scenario');
});
check('validateScenario 反向：INCONCLUSIVE 必须有 missing[]', () => {
  assertIssue(validateScenario({ ...goodScenario, verdict: 'INCONCLUSIVE', missing: [] }),
    'non-empty missing', 'INCONCLUSIVE without missing[]');
});
check('validateScenario 反向：PASS 不得带 missing[]', () => {
  assertIssue(validateScenario({ ...goodScenario, missing: ['E2'] }),
    'must not carry missing', 'PASS with missing[]');
});
check('validateScenario 反向：PASS 不得只靠 E1 应用自述', () => {
  assertIssue(
    validateScenario({ ...goodScenario, evidence: { E1: true, E2: false, E3: false, E4: false } }),
    'app self-report', 'PASS on E1 only');
});
check('validateScenario 反向：PASS 必须有单调量', () => {
  assertIssue(validateScenario({ ...goodScenario, counters: {} }),
    'at least one counter', 'PASS without counters');
});
check('validateScenario 反向：BLOCKED 必须写 blockedBy', () => {
  assertIssue(validateScenario({ ...goodScenario, verdict: 'BLOCKED', blockedBy: '' }),
    'requires blockedBy', 'BLOCKED without blockedBy');
  assertEqual(
    validateScenario({ ...goodScenario, verdict: 'BLOCKED', blockedBy: 'D1', counters: {} }),
    [], 'BLOCKED with blockedBy is fine');
});
check('validateScenario 反向：force-stop 的会话不得声称 normal_exit', () => {
  assertIssue(
    validateScenario({ ...goodScenario, claims: ['normal_exit'], endMethod: 'force-stop' }),
    'only in-game-quit', 'normal_exit claim under force-stop');
  assertEqual(
    validateScenario({ ...goodScenario, claims: ['normal_exit'], endMethod: 'in-game-quit' }),
    [], 'normal_exit under in-game-quit is allowed');
});
check('validateScenario 反向：endMethod 取值受限', () => {
  assertIssue(validateScenario({ ...goodScenario, endMethod: 'killed-somehow' }),
    'is not one of', 'unknown endMethod');
});

// ⭐ 这两条在 P0 里永不触发（P0 没有 T2 动作）。若不在这里主动打一次，
// 它们就是"声称存在但从不生效"的规则（AGENTS.md §二.6）。
check('validateScenario 反向：T2 必须声明 mustNotProve（P0 不触发，此处强制打一次）', () => {
  assertIssue(validateScenario({ ...goodScenario, tier: 'T2', mustNotProve: [] }),
    'requires a non-empty mustNotProve', 'T2 without mustNotProve');
});
check('validateScenario 反向：T2 不得声称自己列为禁止的命题', () => {
  assertIssue(
    validateScenario({
      ...goodScenario,
      tier: 'T2',
      mustNotProve: ['platform-delivers-raw-delta'],
      claims: ['platform-delivers-raw-delta'],
    }),
    'mustNotProve forbids', 'T2 proving a forbidden proposition');
});

check('aggregateVerdict 取最重的一格', () => {
  const s = v => ({ ...goodScenario, verdict: v, missing: v === 'INCONCLUSIVE' ? ['x'] : [] });
  assertEqual(aggregateVerdict([s('PASS'), s('PASS')]), 'PASS', 'all pass');
  assertEqual(aggregateVerdict([s('PASS'), s('BLOCKED')]), 'BLOCKED', 'blocked wins over pass');
  assertEqual(aggregateVerdict([s('BLOCKED'), s('INCONCLUSIVE')]), 'INCONCLUSIVE', 'inconclusive > blocked');
  assertEqual(aggregateVerdict([s('FAIL'), s('INCONCLUSIVE')]), 'FAIL', 'fail > inconclusive');
  assertEqual(aggregateVerdict([s('FAIL'), s('INVALID')]), 'INVALID', 'invalid is worst');
  assertEqual(aggregateVerdict([]), 'INCONCLUSIVE', 'empty run cannot be PASS');
});
check('exitCodeFor：只有 PASS 是 0', () => {
  assertEqual(exitCodeFor('PASS'), 0, 'pass');
  for (const v of ['FAIL', 'INCONCLUSIVE', 'INVALID', 'BLOCKED']) {
    assertEqual(exitCodeFor(v), 1, v);
  }
});

check('validateSummary 反向：总判决与聚合不一致必须报出来', () => {
  const summary = {
    schema: 1, runId: 'p0-x', verdict: 'PASS',
    scenarios: [{ ...goodScenario, verdict: 'BLOCKED', blockedBy: 'D1', counters: {} }],
    unknownsTouched: [], artifacts: { rawDir: 'x', hashes: {} },
  };
  assertIssue(validateSummary(summary), 'disagrees with aggregate', 'verdict mismatch');
  assertEqual(validateSummary({ ...summary, verdict: 'BLOCKED' }), [], 'consistent summary');
});
check('validateSummary 反向：重复的场景 id 必须报出来', () => {
  const summary = {
    schema: 1, runId: 'p0-x', verdict: 'PASS',
    scenarios: [goodScenario, goodScenario],
    unknownsTouched: [], artifacts: { rawDir: 'x', hashes: {} },
  };
  assertIssue(validateSummary(summary), 'duplicate scenario id', 'duplicate ids');
});

// ============================================================
//  ⑨ P0 九格判决 —— 承载"进程匹配规则坏掉"这条只能跨通道发现的失效
// ============================================================

/** 一次健康的 P0 观测（应用被拉起、消费者行命中、进程匹配到）。 */
const healthyObservation = {
  sessionKey: 5489,
  streamReady: true,
  counterSettleMs: 2000,
  amclLinesBefore: 0,
  amclLinesAfter: 27,
  consumerHits: 1,
  streamBytes: 393067,
  fileLogHits: 0,
  fileLogChars: 1033036,
  sessionStarts: 15,
  preProcessCount: 0,
  postProcessCount: 1,
  postProcessRules: ['truncated-suffix'],
  postRunningFlag: false,
  ledgerEntries: 51,
};

const byId = (scenarios, id) => scenarios.find(s => s.id === id);

check('buildScenarios 正向：健康观测下三格 PASS、六格 BLOCKED，且全部自洽', () => {
  const scenarios = buildScenarios(healthyObservation);
  assertEqual(scenarios.length, 3 + BLOCKED_CELLS.length, 'scenario count');
  for (const scenario of scenarios) {
    assertEqual(validateScenario(scenario), [], `scenario ${scenario.id} self-consistency`);
  }
  assertEqual(byId(scenarios, 'smoke.cold-start').verdict, 'PASS', 'cold-start');
  assertEqual(byId(scenarios, 'observe.log-sink-window').verdict, 'PASS', 'log-sink-window');
  assertEqual(byId(scenarios, 'observe.session-outcome').verdict, 'PASS', 'session-outcome');
  assertEqual(aggregateVerdict(scenarios), 'BLOCKED', 'aggregate is BLOCKED, never PASS today');
});

// ⭐ 本组的承重项。`ps -A` 的 CMD 列截断到 15 字符（契约 §6.3 第 3 条），
// 任何"按包名前 15 字符匹配"之类的错误修法都会永远命中 0 个进程 —— 而如果判决不做
// 交叉校验，报告只会安静地写"进程数 0"，没有任何一格会变红。
check('buildScenarios 反向：应用刚打过日志却匹配到 0 个进程 ⇒ INVALID（不得 PASS）', () => {
  const scenarios = buildScenarios({
    ...healthyObservation, consumerHits: 1, postProcessCount: 0, postProcessRules: [],
  });
  const outcome = byId(scenarios, 'observe.session-outcome');
  assertEqual(outcome.verdict, 'INVALID', 'contradiction between hilog and ps');
  assert(outcome.note.includes('进程匹配规则'), 'note must point at the matcher');
});
check('buildScenarios 反向：S1 标记说 RUNNING 但进程不在 ⇒ INVALID', () => {
  const scenarios = buildScenarios({
    ...healthyObservation, postRunningFlag: true, postProcessCount: 0, postProcessRules: [],
  });
  assertEqual(byId(scenarios, 'observe.session-outcome').verdict, 'INVALID', 'marker contradiction');
});
check('buildScenarios 反向：无 hilog 通道时 session-outcome 不得 PASS（交叉校验做不了）', () => {
  const scenarios = buildScenarios({ ...healthyObservation, streamReady: false, consumerHits: 0 });
  const outcome = byId(scenarios, 'observe.session-outcome');
  assertEqual(outcome.verdict, 'INCONCLUSIVE', 'no cross-check channel');
  assert(outcome.missing.length > 0, 'INCONCLUSIVE must say what is missing');
});
check('buildScenarios 反向：采集流没起来 ⇒ cold-start 判 INCONCLUSIVE 而不是 FAIL', () => {
  const scenarios = buildScenarios({ ...healthyObservation, streamReady: false, consumerHits: 0 });
  const cell = byId(scenarios, 'smoke.cold-start');
  assertEqual(cell.verdict, 'INCONCLUSIVE', 'missing evidence channel is not a product failure');
  assertEqual(cell.missing, ['E2:hilog-stream'], 'missing[]');
});
check('buildScenarios 反向：通道就绪但消费者行没出现 ⇒ FAIL（这才是真回归）', () => {
  const scenarios = buildScenarios({
    ...healthyObservation, consumerHits: 0, amclLinesAfter: 27, postProcessCount: 1,
  });
  assertEqual(byId(scenarios, 'smoke.cold-start').verdict, 'FAIL', 'genuine channel regression');
});
check('buildScenarios 反向：文件日志有、hilog 没有 ⇒ 落盘窗口格报 INVALID', () => {
  const scenarios = buildScenarios({ ...healthyObservation, consumerHits: 0, fileLogHits: 1 });
  assertEqual(byId(scenarios, 'observe.log-sink-window').verdict, 'INVALID', 'contradiction');
});
check('buildScenarios：D9 收口窗口后该格仍 PASS（修复不得伪装成回归）', () => {
  // 窗口被收口 ⇒ 两侧都有那行。这不是回归，判决必须仍是 PASS，只是 windowPresent 变 0。
  const scenarios = buildScenarios({ ...healthyObservation, consumerHits: 1, fileLogHits: 1 });
  const cell = byId(scenarios, 'observe.log-sink-window');
  assertEqual(cell.verdict, 'PASS', 'fixed window is not a regression');
  assertEqual(cell.counters.windowPresent, 0, 'windowPresent flips to 0');
});
check('BLOCKED_CELLS 每条都写清阻塞于哪一批', () => {
  assert(BLOCKED_CELLS.length > 0, 'must not be empty');
  for (const [id, blockedBy, why] of BLOCKED_CELLS) {
    assert(typeof id === 'string' && id.length > 0, 'id');
    assert(typeof blockedBy === 'string' && blockedBy.trim().length > 0, `${id}: blockedBy`);
    assert(typeof why === 'string' && why.length > 10, `${id}: reason`);
  }
});

// ============================================================
//  ⑩ 脱敏 —— 反向必须能抓到泄漏
// ============================================================

check('redactSn 保留首末四位', () => {
  assertEqual(redactSn('59JYD25815201311'), '59JY****1311', 'redacted');
  assertEqual(redactSn('short'), '****', 'too short to redact meaningfully');
});
check('assertNoSecrets 反向：完整 SN 出现在待入库文本里必须被抓到', () => {
  const issues = assertNoSecrets(
    [{ name: 'summary.json', text: '{"sn":"59JYD25815201311"}' }],
    { secrets: ['59JYD25815201311'] });
  assertIssue(issues, 'contains a secret literal', 'full SN leak');
});
check('assertNoSecrets 正向：脱敏后的文本干净', () => {
  assertEqual(
    assertNoSecrets([{ name: 'summary.json', text: '{"sn":"59JY****1311"}' }],
      { secrets: ['59JYD25815201311'] }),
    [], 'redacted text is clean');
});
// ⭐ selfClosure（契约 §10.5.0）：它回答"编排器自身是否全部入库"。
// 反向必须能抓到未跟踪的 import —— 否则它就是一条恒为 true 的规则，
// 而那正是它被创造出来要防的形状。
check('collectSelfClosure 反向：未跟踪的 import 必须被列出且 committable=false', () => {
  const root = mkdtempSync(join(tmpdir(), 'amcl-closure-'));
  try {
    // 临时目录不是 git 仓库 ⇒ 每个文件都"不在 HEAD 里"，正是要模拟的状态。
    writeFileSync(join(root, 'dep.mjs'), 'export const x = 1;\n', 'utf8');
    writeFileSync(join(root, 'entry.mjs'), "import { x } from './dep.mjs';\nexport default x;\n", 'utf8');
    const closure = collectSelfClosure(root, join(root, 'entry.mjs'));
    assertEqual(closure.committable, false, 'untracked imports must make it uncommittable');
    assert(closure.untrackedImports.length === 2,
      `both files should be listed, got ${JSON.stringify(closure.untrackedImports)}`);
    assert(closure.note.includes('不描述任何施工批次'),
      'note must disclaim batch-level meaning (contract §10.5.0)');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
check('collectSelfClosure 正向：本仓编排器自身已全部入库', () => {
  const closure = collectSelfClosure(repoRoot, join(repoRoot, 'scripts/device-automation/run-p0.mjs'));
  assertEqual(closure.untrackedImports, [], 'orchestrator must be fully tracked');
  assertEqual(closure.committable, true, 'committable');
});

check('assertNoSecrets 反向：token 形状必须被抓到', () => {
  assertIssue(
    assertNoSecrets([{ name: 'report.md', text: 'token: abcdef0123456789' }], { secrets: [] }),
    'embeds a token', 'token leak');
});

// ============================================================
//  ⑪ 真实样本组（探针 §6 的三份日志；CI 上会 SKIP）
// ============================================================

const SAMPLE_DIR = join(repoRoot, '.logs/device-automation/test-automation-probe-20260907/raw');
/** 探针 README §6 记录的 sha256 —— 先验证同一性，再拿它当判据样本。 */
const SAMPLE_HASHES = {
  'amcl_launcher.log': '1b3167794d7583d9ae52ebdc2004e0049ed35d8d41f759a1a1de643252d093ab',
  'amcl_launcher_after_ps.log': 'fbb6bc577351f9afe85d5389a7ee393ddbd076dd641ac962797501ef5723bdf1',
  'amcl_launcher_b1c.log': '504360947e4eb80d869f7f76bc38cf17723b5fc8536626697f05d81610348cdb',
};

const samplesPresent = Object.keys(SAMPLE_HASHES).every(
  name => existsSync(join(SAMPLE_DIR, name)));

if (!samplesPresent) {
  // 显式说明，不静默跳过 —— 静默跳过会让这一组变成"声称存在但从不生效"的规则。
  console.log(
    '  SKIP  真实样本组：`.logs/device-automation/test-automation-probe-20260907/raw/` 不存在。\n' +
    '        这在 CI 上是预期的（`.gitignore` 有 `/.logs/`，原始日志不入库）。\n' +
    '        样本身份与取回方式见 diagnostics/test-automation-probe-20260907/README.md §6。');
} else {
  check('样本同一性：三份日志的 sha256 与探针 README §6 一致', () => {
    for (const [name, expected] of Object.entries(SAMPLE_HASHES)) {
      const actual = createHash('sha256')
        .update(readFileSync(join(SAMPLE_DIR, name))).digest('hex');
      assertEqual(actual, expected, `sha256 of ${name}`);
    }
  });

  const b1c = readFileSync(join(SAMPLE_DIR, 'amcl_launcher_b1c.log'), 'utf8');
  const afterPs = readFileSync(join(SAMPLE_DIR, 'amcl_launcher_after_ps.log'), 'utf8');

  check('已知含目标的样本（b1c，热启动）：消费者行必须命中 key=777', () => {
    const hits = findBorrowedConsumerHits(b1c, 777);
    assertEqual(hits.length, 1, 'hits in b1c');
    assert(hits[0].line.includes('EntryAbility'), 'hit line should be the EntryAbility one');
  });
  check('已知不含目标的样本（after_ps，冷启动）：必须 0 命中', () => {
    // ⚠️ 0 命中在这里**不是**"通道不通"。冷启动那行只进了 hilog，没落盘
    // （施工记录 §S03.3 的落盘窗口）。§S03.2 记着有人差点用这个 0 去否证 want 通道。
    assertEqual(findBorrowedConsumerHits(afterPs).length, 0, 'hits in after_ps');
  });
  check('两份样本的会话边界都能解析（12 条，轮转文件）', () => {
    assertEqual(findSessionStarts(b1c).length, 12, 'sessions in b1c');
    assertEqual(findSessionStarts(afterPs).length, 12, 'sessions in after_ps');
  });
  check('样本差异：b1c 比 after_ps 恰好多那一行消费者记录', () => {
    const delta = findBorrowedConsumerHits(b1c).length - findBorrowedConsumerHits(afterPs).length;
    assertEqual(delta, 1, 'consumer line delta');
  });
}

// ============================================================

console.log(`\n[test-device-automation] ${checks - failures}/${checks} checks passed`);
if (failures > 0) {
  console.error(`[test-device-automation] ${failures} FAILED`);
  process.exitCode = 1;
} else {
  console.log('[test-device-automation] PASS');
  console.log('  covered: 解析器（工具/设备/进程/hilog 双格式/文件日志）、时间锚点禁用项、');
  console.log('           判决五值与自洽断言（含 P0 不触发的 T2 两条）、P0 九格判决');
  console.log('           （含"刚打过日志却匹配不到进程 ⇒ INVALID"交叉校验）、脱敏泄漏、');
  console.log('           真实样本正负对照');
}
