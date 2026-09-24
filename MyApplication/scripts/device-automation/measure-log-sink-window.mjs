#!/usr/bin/env node
// 量 `onCreate` 那个"只进 hilog、不落盘"的窗口（探针 §2.5 的 E4，D9-0 的前置）。
//
// 文档：docs/refactor/测试自动化施工记录.md §S03.3（窗口的发现）
//       docs/refactor/测试自动化方案.md §三.9（⛔ D9-0 未完成前不得进入 D9-1）
//
// 为什么要它：D9 至今**严重度未定级**，因为只知道"窗口存在"，不知道"它吃掉了什么"。
// `AGENTS.md` §二.2：给一条推断出来的缺口定优先级之前，先让它变成一个可以数的数。
//
// ⭐ 判据是**行数差**，不是"有没有日志"（后者恒为真，量不出严重度）：
//   窗口 = 冷启动后 AMCL domain 的 hilog 行里，排在
//   `AMCL Log system initialized` 之前的那些 —— 那一行是 `setNativeLogSink` 之后的第一条，
//   即落盘能力建立的时刻。再用文件日志反证这些行确实没落盘。
//
// 纯只读：force-stop + 冷启动 + 读日志，不执行任何业务动作、不写设备文件。

import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Hdc, resolveHdcPath, DEFAULT_BUNDLE } from './hdc.mjs';
import { HilogCollector, Teardown } from './collector.mjs';
import {
  countAmclLines, findBorrowedConsumerHits, findSessionStarts, isAmclLine, parseHilogLine,
  parseTargets,
} from './parse.mjs';
import { RAW_DIR } from './artifacts.mjs';

const REPO_ROOT = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const SANDBOX_FILES = `/data/app/el2/100/base/${DEFAULT_BUNDLE}/haps/entry/files`;
/** `setNativeLogSink` 之后的第一条日志。窗口以它为界。 */
const SINK_READY_MARKER = 'AMCL Log system initialized';
const SETTLE_MS = 4000;

function localIso(date = new Date()) {
  const pad = (n) => String(n).padStart(2, '0');
  const off = -date.getTimezoneOffset();
  const sign = off >= 0 ? '+' : '-';
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
    `T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}` +
    `${sign}${pad(Math.trunc(Math.abs(off) / 60))}:${pad(Math.abs(off) % 60)}`;
}

async function main() {
  const hdcPath = resolveHdcPath();
  const probe = new Hdc({ path: hdcPath });
  const targets = parseTargets(probe.targetsText());
  if (targets.length !== 1) throw new Error(`expected exactly 1 device, found ${targets.length}`);
  const hdc = new Hdc({ path: hdcPath, sn: targets[0] });

  const runId = `e4-${localIso().replace(/[-:+]/g, '').slice(0, 15)}`;
  const rawDir = join(REPO_ROOT, RAW_DIR, runId, 'raw');
  mkdirSync(rawDir, { recursive: true });

  const teardown = new Teardown(m => console.log(`teardown: ${m}`));
  teardown.installProcessHandlers();
  let collector = null;
  try {
    hdc.shell(`aa force-stop ${DEFAULT_BUNDLE}`);
    teardown.register('force-stop', () => { hdc.shell(`aa force-stop ${DEFAULT_BUNDLE}`); });

    collector = new HilogCollector(hdc, {
      rawPath: join(rawDir, 'hilog-stream.log'),
      logger: m => console.log(`collector: ${m}`),
    });
    teardown.register('stop collector', () => { collector.stop(); });
    const ready = await collector.start();
    if (!ready.ready) throw new Error('hilog collector produced no bytes; cannot measure');

    const key = 1000 + Math.floor(Math.random() * 8999);
    hdc.shell(`aa start -a EntryAbility -b ${DEFAULT_BUNDLE} --ps amclSessionKey ${key}`);
    await new Promise(r => setTimeout(r, SETTLE_MS));
    await collector.stop();

    const stream = readFileSync(join(rawDir, 'hilog-stream.log'), 'utf8');
    const amcl = [];
    for (const line of stream.split(/\r?\n/)) {
      const parsed = parseHilogLine(line);
      if (parsed !== null && isAmclLine(parsed)) amcl.push(parsed);
    }
    const sinkAt = amcl.findIndex(p => p.message.includes(SINK_READY_MARKER));

    // 文件日志：取回后只看本次冷启动那一段（最后一个 Session Start 之后）。
    const localLog = join(rawDir, 'amcl_launcher.log');
    hdc.fileRecv(`${SANDBOX_FILES}/logs/amcl_launcher.log`, localLog);
    const fileText = existsSync(localLog) ? readFileSync(localLog, 'utf8') : '';
    const starts = findSessionStarts(fileText);
    const lastStartAt = starts.length > 0
      ? fileText.lastIndexOf(`AMCL Session Start: ${starts[starts.length - 1]}`) : -1;
    const sessionTail = lastStartAt >= 0 ? fileText.slice(lastStartAt) : '';

    const windowLines = sinkAt < 0 ? amcl : amcl.slice(0, sinkAt);
    // 反证：窗口内的行是否真的没落盘。按 message 子串在本次会话段里找。
    const leaked = windowLines.filter(p => p.message.length > 8 && sessionTail.includes(p.message));

    const result = {
      schema: 1,
      runId,
      measuredAt: localIso(),
      sinkMarkerFound: sinkAt >= 0,
      amclHilogLinesThisBoot: amcl.length,
      windowLineCount: windowLines.length,
      afterSinkLineCount: sinkAt < 0 ? 0 : amcl.length - sinkAt,
      windowLinesAlsoInFileLog: leaked.length,
      consumerHitsInHilog: findBorrowedConsumerHits(stream, key).length,
      consumerHitsInFileLog: findBorrowedConsumerHits(sessionTail, key).length,
      byDomain: countAmclLines(stream).byDomain,
      windowMessages: windowLines.map(p => `[${p.level}][${p.tag}] ${p.message}`),
    };
    writeFileSync(join(rawDir, 'e4-result.json'), `${JSON.stringify(result, null, 2)}\n`, 'utf8');

    console.log(`\n=== E4 落盘窗口的量（runId=${runId}）===`);
    console.log(`本次冷启动 AMCL hilog 行数      : ${result.amclHilogLinesThisBoot}`);
    console.log(`窗口内（sink 之前）行数         : ${result.windowLineCount}`);
    console.log(`sink 之后行数                   : ${result.afterSinkLineCount}`);
    console.log(`窗口内又出现在文件日志里的行数  : ${result.windowLinesAlsoInFileLog}（应为 0）`);
    console.log(`消费者行 hilog/文件            : ${result.consumerHitsInHilog}/${result.consumerHitsInFileLog}`);
    console.log('--- 窗口内被吞掉的行 ---');
    for (const m of result.windowMessages) console.log(`  ${m}`);
    console.log(`\nraw → ${rawDir}`);
  } finally {
    teardown.runAllSync('finally');
  }
}

main().catch((error) => {
  console.error(`[measure-log-sink-window] ${error?.stack ?? error}`);
  process.exitCode = 1;
});
