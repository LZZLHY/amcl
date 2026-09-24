#!/usr/bin/env node
// P0 冒烟九格的判决逻辑 —— 纯函数，输入一份观测、输出 scenarios[]。
//
// 为什么单独成文件（而不是写在 run-p0.mjs 里）：判决逻辑写在编排器内联位置时**无法自测**，
// 只能靠每次真机跑一遍去发现问题。而它的失败形态恰恰是静默的 ——
// 见下面 `observe.session-outcome` 的交叉校验：进程匹配规则坏掉时，
// 内联版本会安静地报 `processRows.after = 0` 然后照样 PASS。
//
// 对应方案 §4.1 的 P0 冒烟表。九格里今天只有三格可达，其余六格阻塞于尚未落地的批次；
// 它们报 `BLOCKED` 而不是 `FAIL`（契约 §8.4）。

/**
 * 今天不可达的冒烟格子。每条都必须写清阻塞于哪一批 —— 否则下一轮无法判断它是否已解锁。
 * ⚠️ 这不是"预期失败白名单"：它们照常进聚合、照常让总判决非零，只是判决值不同。
 */
export const BLOCKED_CELLS = [
  ['smoke.product-policy', 'D8',
    '产品身份不进日志 ⇒ 无法从日志反查产品轨与能力位（探针 A7）'],
  ['smoke.log-mark', 'L1a',
    '`log.mark` 是 T1 动作，能力门面尚不存在（契约 §8.5 连带结论）'],
  ['smoke.version-list', 'D1',
    '`CAP-VER-LOCAL` 仍在 `Index.scanVersions()` 里；宿主已采基准目录集合待 D1 后对账'],
  ['smoke.net-diag', 'L1a',
    '`net.diag` 需要能力门面转发 `runNetworkDiagnostics`'],
  ['smoke.download-engine', 'D4',
    '探针分派仍在 `DevToolsPage.runTool` 的 switch 里'],
  ['smoke.game-launch', 'D3',
    '`CAP-LAUNCH-GO` 在 `McGamePage` 页面内；hdc 无法在不点 UI 的前提下拉起游戏'],
];

/**
 * @typedef {object} P0Observation
 * @property {number}   sessionKey        本轮 `--ps amclSessionKey` 用的 key
 * @property {boolean}  streamReady       hilog 采集流是否收到过字节
 * @property {number}   counterSettleMs   计数的固定采样延迟（契约 §1.2.1）
 * @property {number}   amclLinesBefore   动作前的 AMCL domain 行数
 * @property {number}   amclLinesAfter    动作后（固定延迟采样）的 AMCL domain 行数
 * @property {number}   consumerHits      hilog 里精确 key 命中的消费者行数
 * @property {number}   streamBytes       采集流字节数
 * @property {number}   fileLogHits       **文件日志**里同一 key 的命中数
 * @property {number}   fileLogChars      文件日志字符数
 * @property {number}   sessionStarts     文件日志里的会话边界数
 * @property {number}   preProcessCount   动作前匹配到的 AMCL 进程数
 * @property {number}   postProcessCount  动作后匹配到的 AMCL 进程数
 * @property {string[]} postProcessRules  命中用的匹配规则（exact / truncated-suffix）
 * @property {boolean}  postRunningFlag   `mc_running.flag` 是否存在
 * @property {number}   ledgerEntries     活动账本条目数
 */

/**
 * @param {P0Observation} o
 * @returns {object[]} scenarios（可直接进 summary.json）
 */
export function buildScenarios(o) {
  const scenarios = [];
  const amclLinesGrew = o.amclLinesAfter > o.amclLinesBefore;

  // ── 1. C1 want 参数通道（冷启动路径）
  scenarios.push({
    id: 'smoke.cold-start',
    tier: 'T1',
    verdict: !o.streamReady
      ? 'INCONCLUSIVE'
      : (o.consumerHits > 0 && amclLinesGrew ? 'PASS' : 'FAIL'),
    missing: o.streamReady ? [] : ['E2:hilog-stream'],
    evidence: {
      E1: false,
      E2: o.streamReady && o.consumerHits > 0,
      E3: o.sessionStarts > 0,
      E4: false,
    },
    counters: {
      amclHilogLines: { before: o.amclLinesBefore, after: o.amclLinesAfter },
      consumerHits: { before: 0, after: o.consumerHits },
      streamBytes: o.streamBytes,
      counterSettleMs: o.counterSettleMs,
    },
    endMethod: 'force-stop',
    claims: ['c1-want-parameter-delivered-on-cold-start'],
    note: `key=${o.sessionKey}；判据是精确 key 命中 + AMCL domain 行数增长；` +
      `计数在命中后固定 ${o.counterSettleMs} ms 取样（契约 §1.2.1）`,
  });

  // ── 2. 落盘窗口（§S03.3）的当前形态
  //
  // 刻意**不把"缺陷存在"当成通过条件**：若把"文件日志里没有那行"写成 PASS 判据，
  // D9 收口窗口之后这一格会变红 —— 而那是修复，不是回归。
  // ⇒ 只在证据自相矛盾（文件有、hilog 没有）时报 INVALID，其余把形态记成事实。
  const windowPresent = o.consumerHits > 0 && o.fileLogHits === 0;
  scenarios.push({
    id: 'observe.log-sink-window',
    tier: 'T1',
    verdict: !o.streamReady
      ? 'INCONCLUSIVE'
      : (o.fileLogHits > 0 && o.consumerHits === 0 ? 'INVALID' : 'PASS'),
    missing: o.streamReady ? [] : ['E2:hilog-stream'],
    evidence: { E1: false, E2: o.consumerHits > 0, E3: o.fileLogChars > 0, E4: false },
    counters: {
      hilogConsumerHits: o.consumerHits,
      fileLogConsumerHits: o.fileLogHits,
      windowPresent: windowPresent ? 1 : 0,
    },
    note: windowPresent
      ? '复现施工记录 §S03.3：该行进了 hilog 但没落盘（D9 未量，严重度未定级）'
      : '本轮未复现落盘窗口 —— 若 D9 已落地这是预期变化，否则需要复核',
  });

  // ── 3. 会话结局基线 + ⭐ 进程匹配规则的交叉校验
  //
  // ⭐ 这一格承载一条**只有跨通道才能发现**的失效：`ps -A` 的 CMD 列截断到 15 字符
  // （契约 §6.3 第 3 条），任何"按包名前 15 字符匹配"之类的错误修法都会永远命中 0 个进程，
  // 而它看起来完全正常 —— 报告只会写"进程数 0"，没有任何一格会变红。
  //
  // 交叉校验：应用刚在 hilog 里打过一行（consumerHits > 0）⇒ 它在那一刻必定活着。
  // 此时 ps 匹配到 0 个进程只有两种解释：应用在这几百毫秒内死了，或者**匹配规则坏了**。
  // 两者都不该判 PASS ⇒ 报 INVALID（证据自相矛盾），并把两侧原始值都留在计数里。
  const contradictsMarker = o.postRunningFlag && o.postProcessCount === 0;
  const contradictsHilog = o.consumerHits > 0 && o.postProcessCount === 0;
  scenarios.push({
    id: 'observe.session-outcome',
    tier: 'T1',
    verdict: (contradictsMarker || contradictsHilog)
      ? 'INVALID'
      // 没有 hilog 通道就做不了上面那条交叉校验，而 `ps` 恰恰是被怀疑的一方
      // ⇒ 此时"没匹配到进程"不可判定，不得当成"应用不在跑"。
      : (o.streamReady ? 'PASS' : 'INCONCLUSIVE'),
    missing: o.streamReady ? [] : ['E2:hilog-stream（进程匹配规则的交叉校验依赖它）'],
    evidence: { E1: false, E2: o.consumerHits > 0, E3: true, E4: false },
    counters: {
      processRows: { before: o.preProcessCount, after: o.postProcessCount },
      ledgerEntries: o.ledgerEntries,
      mcRunningFlag: o.postRunningFlag ? 1 : 0,
    },
    endMethod: 'force-stop',
    // 刻意不声称 normal_exit：本轮结束方式是 force-stop（契约 §9.3 第 3 条）。
    claims: [],
    note: contradictsHilog
      ? '⚠️ 应用刚在 hilog 里打过行却匹配不到进程 —— 进程匹配规则可能已失效（契约 §6.3 第 3 条）'
      : `进程匹配规则=${o.postProcessRules.join(',') || 'none'}（ps 的 CMD 列截断到 15 字符，保留尾部）`,
  });

  for (const [id, blockedBy, why] of BLOCKED_CELLS) {
    scenarios.push({
      id,
      tier: 'T1',
      verdict: 'BLOCKED',
      blockedBy,
      missing: [],
      evidence: { E1: false, E2: false, E3: false, E4: false },
      counters: {},
      note: why,
    });
  }

  return scenarios;
}
