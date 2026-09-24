#!/usr/bin/env node
// P0 宿主编排器 —— 零应用改动的一轮冒烟。
//
// 文档：docs/refactor/测试自动化方案.md §5（P0）/ §4.1（P0 冒烟表）
//       docs/guides/test-automation-contract.md §1.3 / §6 / §8
//
// 用法：
//   node scripts/device-automation/run-p0.mjs [--sn <序列号>] [--hdc <绝对路径>]
//
// 本编排器**不做**的事（刻意，别顺手加）：
//   - 不驱动任何业务动作（下载 / 安装 / 删版本 / 启动游戏）。在 L1a 能力门面存在之前，
//     用 hdc 驱动业务只能靠点 UI，那既不稳定、也会违反契约 §1.1（同路径）。
//   - 不模拟或补偿被测行为（契约 §2.2：L3 禁止对被测行为的任何模拟）。
//   - 不执行 `bm clean`（破坏性；复位是另一条显式命令）。
//
// ⭐ 本轮的总判决**预期是 `BLOCKED`**：方案 §4.1 冒烟表里七格中的多数依赖尚未落地的
// 批次（D1/D3/D4/D8/L1a）。把它们写成 `FAIL` 会把"工具还没做"读成"功能坏了"
// （契约 §8.4）。⇒ 退出码非零是本轮的正确结果，不是失败。

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Hdc, resolveHdcPath, DEFAULT_BUNDLE } from './hdc.mjs';
import { HilogCollector, Teardown } from './collector.mjs';
import {
  countAmclLines, findBorrowedConsumerHits, findBundleProcesses, findSessionStarts,
  looksMissing, parseBmDump, parseDeviceDate, parseFportRules, parseHdcVersion,
  parseLsNames, parseParamValue, parseTargets, parseUitestVersion, validateTimeAnchor,
} from './parse.mjs';
import { buildScenarios } from './scenarios.mjs';
import { aggregateVerdict, exitCodeFor } from './verdict.mjs';
import {
  archiveRawDir, collectGitState, collectSelfClosure, redactSn, writeArtifacts, RAW_DIR,
} from './artifacts.mjs';

const REPO_ROOT = resolve(fileURLToPath(new URL('../..', import.meta.url)));

/** 沙箱物理路径（AGENTS.md §三.1：取回可以直接用物理路径）。 */
const SANDBOX_FILES = `/data/app/el2/100/base/${DEFAULT_BUNDLE}/haps/entry/files`;

const CONSUMER_WAIT_MS = 30_000;
const PROCESS_SETTLE_MS = 10_000;
/**
 * 命中消费者行之后再等一段固定窗口才取计数。
 *
 * ⚠️ 这是第二轮真机跑出来的修正：一命中就取样时，`amclHilogLines.after` 在两轮里
 * 分别是 21 与 7 —— 差异全部来自消费者行到达的快慢（514 ms vs 251 ms），
 * 与产品行为无关。那种数会被下一轮读成"启动期日志变少了"。
 * ⇒ 判据的采样时点必须是**固定的**，否则计数在跨轮比较里没有意义。
 */
const COUNTER_SETTLE_MS = 2_000;

function parseArgs(argv) {
  const args = { sn: null, hdc: null };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--sn') { args.sn = argv[i + 1]; i += 1; continue; }
    if (argv[i] === '--hdc') { args.hdc = argv[i + 1]; i += 1; continue; }
    throw new Error(`unknown argument: ${argv[i]}`);
  }
  return args;
}

/** 本地时间 + 偏移（与本仓文档里的 `Get-Date -Format "... zzz"` 同口径）。 */
function localIso(date = new Date()) {
  const pad = (n, width = 2) => String(Math.abs(n)).padStart(width, '0');
  const offsetMinutes = -date.getTimezoneOffset();
  const sign = offsetMinutes >= 0 ? '+' : '-';
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
    `T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}` +
    `${sign}${pad(Math.trunc(Math.abs(offsetMinutes) / 60))}:${pad(Math.abs(offsetMinutes) % 60)}`;
}

function runStamp(date = new Date()) {
  const pad = (n) => String(n).padStart(2, '0');
  return `p0-${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}` +
    `-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`;
}

const logLines = [];
function log(message) {
  const line = `[${localIso()}] ${message}`;
  logLines.push(line);
  console.log(line);
}

/** 轮询直到 predicate 为真或超时。返回耗时 ms 或 null。 */
async function waitUntil(predicate, timeoutMs, intervalMs = 250) {
  const deadline = Date.now() + timeoutMs;
  const startedAt = Date.now();
  for (;;) {
    if (await predicate()) return Date.now() - startedAt;
    if (Date.now() >= deadline) return null;
    await new Promise(r => setTimeout(r, intervalMs));
  }
}

/**
 * 唯一设备预检。
 * 0 台或多台且未指定 SN ⇒ 立即停（契约 §8.4 的 `BLOCKED`），不猜一台。
 */
function pickDevice(hdc, requestedSn) {
  const targets = parseTargets(hdc.targetsText());
  if (requestedSn) {
    if (!targets.includes(requestedSn)) {
      throw new Error(
        `requested device ${requestedSn} is not online; online: ${targets.join(', ') || '(none)'}`);
    }
    return { sn: requestedSn, targets };
  }
  if (targets.length !== 1) {
    throw new Error(
      `expected exactly 1 online device, found ${targets.length} ` +
      `(${targets.join(', ') || 'none'}); pass --sn to disambiguate`);
  }
  return { sn: targets[0], targets };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const hdcPath = resolveHdcPath(args.hdc);

  // ① 工具与设备身份（环境取证）。
  const probe = new Hdc({ path: hdcPath });
  const hdcVersion = parseHdcVersion(probe.versionText());
  const { sn } = pickDevice(probe, args.sn);

  const runId = runStamp();
  const startedAt = localIso();
  const rawDir = join(RAW_DIR, runId, 'raw');
  mkdirSync(rawDir, { recursive: true });

  // 命令留痕（含完整 SN，落在被忽略的 raw 目录里；入库摘要一律脱敏）。
  const commandTrace = [];
  const hdc = new Hdc({
    path: hdcPath,
    sn,
    onCommand: (entry) => {
      commandTrace.push({
        at: localIso(),
        args: entry.args,
        status: entry.status,
        ms: entry.ms,
        timedOut: entry.timedOut,
        stdoutBytes: entry.stdout.length,
        stderr: entry.stderr.trim().slice(0, 500),
      });
    },
  });

  log(`runId=${runId} device=${redactSn(sn)} hdc=${hdcVersion}`);

  const teardown = new Teardown(msg => log(`teardown: ${msg}`));
  teardown.installProcessHandlers();

  const notes = [];
  const blockedNotes = [];
  const scenarios = [];
  let collector = null;

  try {
    const model = parseParamValue(hdc.shell('param get const.product.model').stdout);
    const brand = parseParamValue(hdc.shell('param get const.product.brand').stdout);
    const osFullName = parseParamValue(hdc.shell('param get const.ohos.fullname').stdout);
    const apiVersion = Number(parseParamValue(hdc.shell('param get const.ohos.apiversion').stdout));
    const uitest = parseUitestVersion(hdc.shell('uitest --version').stdout);
    const spDaemon = !looksMissing(hdc.shell('ls -l /bin/SP_daemon').stdout);
    const app = parseBmDump(hdc.shell(`bm dump -n ${DEFAULT_BUNDLE}`).stdout);
    if (!app.ok) throw new Error(`bm dump unusable: ${app.reason}`);

    // ② 起始状态（动作之前的对照点）。
    const preFport = parseFportRules(probe.fportListText());
    const preProcesses = findBundleProcesses(hdc.shell('ps -A').stdout, DEFAULT_BUNDLE);
    const versionDirs = parseLsNames(hdc.shell(`ls ${SANDBOX_FILES}/.minecraft/versions`).stdout);
    const ledgerDirs = parseLsNames(hdc.shell(`ls ${SANDBOX_FILES}/logs/ledger`).stdout);
    const preRunningFlag = !looksMissing(hdc.shell(`ls -la ${SANDBOX_FILES}/mc_running.flag`).stdout);
    const preWindowFlag =
      !looksMissing(hdc.shell(`ls -la ${SANDBOX_FILES}/.mc_window_destroyed`).stdout);
    log(`pre-state: processes=${preProcesses.length} fport=${preFport.length} ` +
        `versions=${versionDirs.length} ledger=${ledgerDirs.length} ` +
        `mc_running.flag=${preRunningFlag} .mc_window_destroyed=${preWindowFlag}`);

    // ③ 保证冷启动：先 force-stop 并等进程真的消失。
    //    ⚠️ force-stop 是 hdc 唯一可达的结束方式，**不等于正常退出**（契约 §9.3）。
    //    本轮 endMethod 因此恒为 force-stop，任何"验证了正常退出"的说法都无效。
    hdc.shell(`aa force-stop ${DEFAULT_BUNDLE}`);
    teardown.register('force-stop app', () => { hdc.shell(`aa force-stop ${DEFAULT_BUNDLE}`); });
    const goneMs = await waitUntil(
      () => findBundleProcesses(hdc.shell('ps -A').stdout, DEFAULT_BUNDLE).length === 0,
      PROCESS_SETTLE_MS);
    log(`app stopped for cold start after ${goneMs ?? '>timeout'} ms`);

    // ④ **采集先于动作**（契约 §1.3）。就绪由第一批字节证明，不是由 spawn 返回证明。
    collector = new HilogCollector(hdc, {
      rawPath: join(rawDir, 'hilog-stream.log'),
      logger: msg => log(`collector: ${msg}`),
    });
    teardown.register('stop hilog collector', () => { collector.stop(); });
    const ready = await collector.start();
    if (!ready.ready) {
      notes.push('hilog 采集流在就绪窗口内没有产出任何字节 ⇒ E2 通道缺失，本轮相关格子判 INCONCLUSIVE。');
    }

    // ⑤ 时间锚点：借既有消费者 + 壁钟。**不得**用"缓冲区最早一行"（契约 §8.5）。
    const deviceTime = parseDeviceDate(hdc.shell('date +%Y-%m-%dT%H:%M:%S%z').stdout);
    const timeAnchor = {
      method: 'borrowed-consumer',
      deviceTime,
      hostTime: localIso(),
      note: 'L1a 之前的预期降级值（契约 §8.5）；log.mark 属 T1 动作，尚不存在。',
    };
    const anchorIssues = validateTimeAnchor(timeAnchor);
    if (anchorIssues.length > 0) throw new Error(`time anchor invalid: ${anchorIssues.join('; ')}`);

    const beforeCounts = countAmclLines(collector.tail());
    const sessionKey = 1000 + Math.floor(Math.random() * 8999);

    // ⑥ 动作：C1 want 参数通道（冷启动路径）。
    //    ⚠️ 副作用：消费者会把 key 写进 AppStorage，Index 会为一个不存在的会话打开
    //    错误 Sheet。这不是无副作用探针，报告里要写明（下面 notes 有一条）。
    log(`action: aa start --ps amclSessionKey ${sessionKey}`);
    const startResult =
      hdc.shell(`aa start -a EntryAbility -b ${DEFAULT_BUNDLE} --ps amclSessionKey ${sessionKey}`);
    writeFileSync(join(rawDir, 'aa-start.txt'),
      `${startResult.stdout}\n---stderr---\n${startResult.stderr}\n`, 'utf8');

    // ⑦ 取证：等消费者那行出现在 hilog 流里（判据是精确 key，不是"有没有类似的行"）。
    const consumerWaitMs = await waitUntil(
      () => findBorrowedConsumerHits(collector.tail(), sessionKey).length > 0,
      CONSUMER_WAIT_MS);
    await new Promise(r => setTimeout(r, COUNTER_SETTLE_MS));
    const consumerHits = findBorrowedConsumerHits(collector.tail(), sessionKey);
    const afterCounts = countAmclLines(collector.tail());
    log(`consumer line: hits=${consumerHits.length} after ${consumerWaitMs ?? '>timeout'} ms; ` +
        `amcl hilog lines ${beforeCounts.total} → ${afterCounts.total} ` +
        `(sampled ${COUNTER_SETTLE_MS} ms after detection)`);

    const postProcesses = findBundleProcesses(hdc.shell('ps -A').stdout, DEFAULT_BUNDLE);
    const postRunningFlag =
      !looksMissing(hdc.shell(`ls -la ${SANDBOX_FILES}/mc_running.flag`).stdout);

    // 文件日志取回（E3）。落盘窗口的交叉验证要用它。
    const fileLogLocal = join(rawDir, 'amcl_launcher.log');
    hdc.fileRecv(`${SANDBOX_FILES}/logs/amcl_launcher.log`, fileLogLocal);
    const fileLogText = existsSync(fileLogLocal) ? readFileSync(fileLogLocal, 'utf8') : '';
    const fileLogHits = findBorrowedConsumerHits(fileLogText, sessionKey);
    const sessionStarts = findSessionStarts(fileLogText);
    // 记的是解码后的字符数，与归档表里的**字节数**不相等（中文与箭头是多字节）。
    // 写清单位，免得下一轮把这两个数的差异读成"文件被改过"。
    log(`file log: ${fileLogText.length} chars, sessionStarts=${sessionStarts.length}, ` +
        `consumerHits=${fileLogHits.length}`);

    // ⑧ 判决。判决逻辑全部在 scenarios.mjs 的纯函数里 —— 编排器只负责把观测喂进去。
    //    这样那批规则才能被 test-device-automation.mjs 正反向打一遍（内联版本不可测）。
    const observation = {
      sessionKey,
      streamReady: ready.ready,
      counterSettleMs: COUNTER_SETTLE_MS,
      amclLinesBefore: beforeCounts.total,
      amclLinesAfter: afterCounts.total,
      consumerHits: consumerHits.length,
      streamBytes: collector.counters().bytes,
      fileLogHits: fileLogHits.length,
      fileLogChars: fileLogText.length,
      sessionStarts: sessionStarts.length,
      preProcessCount: preProcesses.length,
      postProcessCount: postProcesses.length,
      postProcessRules: postProcesses.map(p => p.rule),
      postRunningFlag,
      ledgerEntries: ledgerDirs.length,
    };
    scenarios.push(...buildScenarios(observation));
    for (const scenario of scenarios) {
      if (scenario.verdict === 'BLOCKED') {
        blockedNotes.push(`\`${scenario.id}\` 阻塞于 **${scenario.blockedBy}** —— ${scenario.note}`);
      }
    }

    notes.push(
      '借既有消费者做时间锚点有一处副作用：`amclSessionKey` 会让 `Index` 为一个不存在的会话' +
      '打开错误 Sheet。本轮接受它（UI 状态，不改设备数据），但它不是零副作用探针。');
    notes.push(
      `宿主侧版本目录基准：${versionDirs.length} 个。D1 落地后的对账口径是` +
      '`installed[] ∪ orphans[] == 本集合`，**不是** `installed[] == 本集合`（探针 §4）。');
    if (collector.formatFallback) {
      notes.push('hilog 流退回默认格式（无年份/时区）⇒ 时间轴对账精度下降，已在解析层兼容。');
    }
    if (collector.counters().truncated) {
      notes.push('hilog 流触到体积预算被截断 ⇒ 计数是下界，不是全量。');
    }

    const verdict = aggregateVerdict(scenarios);
    const git = collectGitState(REPO_ROOT);
    if (git.dirty) {
      notes.push(
        `工作树不干净 ⇒ 本轮测的是"树 + 未提交改动"，不是 HEAD。` +
        `身份是 \`trackedDiffSha256=${git.trackedDiffSha256.slice(0, 16)}…\`` +
        `（已跟踪 ${git.dirtyTrackedFiles} 个、未跟踪 ${git.untrackedFiles} 个，` +
        '计数会漂、只作规模提示，契约 §8.5）。⚠️ 该哈希**不含未跟踪文件** ⇒ ' +
        '本编排器自身在首次提交前不在这份身份里。' +
        `设备上运行的是已装包 versionCode=${app.versionCode}，与本树无因果关系（P0 零应用改动）。`);
    }

    const manifest = {
      schema: 1,
      runId,
      startedAt,
      finishedAt: localIso(),
      host: { hdcPath, hdcVersion },
      device: { sn: redactSn(sn), model, brand, osFullName, apiVersion },
      app: {
        bundle: app.bundle,
        versionCode: app.versionCode,
        versionName: app.versionName,
        // 契约 §8.5「预期降级值」：D8 之前只能是 unknown，填一个猜的值比 unknown 更糟。
        productTrack: 'unknown',
        provisionType: app.provisionType,
        debug: app.debug,
        hapSha256: null,
      },
      git,
      channel: 'C1',
      toolchain: { hypium: null, uitest, spDaemon },
      timeAnchor,
      endMethod: 'force-stop',
      // 工具自证轮次必填（契约 §8.5.1）。常规轮次为 null —— 未标注的 INVALID/FAIL
      // 一律按真实设备结论对待，所以这里不能省略字段本身。
      toolMutation: null,
      selfClosure: collectSelfClosure(REPO_ROOT, fileURLToPath(import.meta.url)),
    };

    const summary = {
      schema: 1,
      runId,
      verdict,
      scenarios,
      unknownsTouched: [],
      artifacts: {
        rawDir: relative(REPO_ROOT, rawDir).replaceAll('\\', '/'),
        hashes: {},
      },
    };

    // 收尾必须在归档之前跑完，且要**等采集流真的关掉**：
    // 采集子进程还活着、write stream 还没 flush 时，hilog-stream.log 的 sha256 是个移动靶。
    await collector.stop();
    const teardownResults = teardown.runAllSync('normal');
    const residualFport = parseFportRules(probe.fportListText());
    const residualProcesses = findBundleProcesses(hdc.shell('ps -A').stdout, DEFAULT_BUNDLE);
    log(`residue check: fport=${residualFport.length} processes=${residualProcesses.length}`);
    notes.push(
      `收尾：${teardownResults.filter(r => r.ok).length}/${teardownResults.length} 条清理成功；` +
      `残留 fport=${residualFport.length}、AMCL 进程=${residualProcesses.length}。`);

    writeFileSync(join(rawDir, 'commands.jsonl'),
      `${commandTrace.map(e => JSON.stringify(e)).join('\n')}\n`, 'utf8');
    writeFileSync(join(rawDir, 'orchestrator.log'), `${logLines.join('\n')}\n`, 'utf8');
    writeFileSync(join(rawDir, 'state.json'), `${JSON.stringify({
      pre: { fport: preFport, processes: preProcesses, versionDirs, ledgerDirs, preRunningFlag, preWindowFlag },
      post: { processes: postProcesses, postRunningFlag, residualFport, residualProcesses },
      collector: collector.counters(),
      observation,
      sessionKey,
      consumerHits,
      fileLogHits,
      sessionStarts,
    }, null, 2)}\n`, 'utf8');

    summary.artifacts.hashes = archiveRawDir(rawDir, REPO_ROOT);

    const written = writeArtifacts({
      repoRoot: REPO_ROOT, runId, manifest, summary, notes, blockedNotes,
      secrets: [sn],
    });
    log(`artifacts → ${written.outDir} (${written.files.join(', ')})`);
    log(`verdict = ${verdict}`);
    console.log(
      verdict === 'BLOCKED'
        ? '\n[run-p0] BLOCKED 是本轮的预期结果：多数冒烟格子阻塞于 D1/D3/D4/D8/L1a。\n' +
          '         非零退出码表示"还没做到"，不表示"产品坏了"（契约 §8.4）。'
        : `\n[run-p0] verdict=${verdict}`);
    process.exitCode = exitCodeFor(verdict);
  } finally {
    // 无条件收尾：happy path 上已经跑过一次（runAllSync 幂等），异常路径靠这里。
    teardown.runAllSync('finally');
  }
}

main().catch((error) => {
  console.error(`[run-p0] ${error?.stack ?? error}`);
  // 编排器自身失败 ⇒ 环境/工具问题，对应契约 §8.4 的 BLOCKED，不是产品 FAIL。
  process.exitCode = 1;
});
