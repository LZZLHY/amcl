#!/usr/bin/env node
// 宿主侧证据采集 —— 契约 §1.3（宿主观测）的实现。
//
// 两条纪律直接决定了本文件的形状：
//   1. **采集必须在动作之前开始。** 被测应用可能被 `System.exit` → `SIGABRT` 打死、
//      可能 ANR，届时它没有任何代码在跑 ⇒ 由应用自己记录的"我怎么结束的"不存在。
//   2. **就绪必须由流动的数据证明，不是由"我起好了"声明。** 契约 §1.2：
//      "通道建起来了但一个事件都没流过"与"工作正常"在日志里长得一模一样。
//      ⇒ start() 只在**收到第一批字节**之后才返回就绪（字节数是单调量）。
//      同型陷阱在传输层也出现过一次：fport 的本地端口 connect 会成功，
//      即使设备侧没有任何监听（施工记录 §S03.6）。
//
// ⚠️ 实测（2026-09-07，hdc 3.2.0f）：`hdc hilog` 会**先把整个缓冲区倒出来再跟流**，
// 3 秒内产出 116822 行、且还没倒完。⇒ 采集前必须先 `hilog -r` 清缓冲，否则第一分钟
// 全是与本轮无关的历史行（方案 §7 风险 9 的具体形态），且体积失控。

import { spawn, execFileSync } from 'node:child_process';
import { createWriteStream } from 'node:fs';

/** 默认体积预算：清过缓冲之后一轮 P0 远小于此；超了就截断并记录。 */
const DEFAULT_BYTE_BUDGET = 64 * 1024 * 1024;
/** 就绪窗口：设备实测每秒数千行，1 秒内必然有字节；给 15 秒余量。 */
const DEFAULT_READY_TIMEOUT_MS = 15_000;
/**
 * 内存尾窗大小。判据匹配一律打在这块尾窗上，**不**去读正在写的落盘文件 ——
 * 后者要跟 write stream 的缓冲赛跑，"还没 flush"会被读成"这行不存在"，
 * 那正是一条会产生错误结论的竞态。
 */
const DEFAULT_TAIL_BYTES = 4 * 1024 * 1024;

/**
 * 无条件收尾登记表。
 *
 * P0 的验收判据之一是"异常路径无残留 fport / 采集进程"⇒ 收尾不能写在 happy path 上。
 * 这里把清理动作登记下来，由 runAll() 在 finally 与进程信号两处调用，且**逐条独立
 * try/catch**：一条清理失败不得让后面的清理不执行（否则第一次异常就会留下残留）。
 */
export class Teardown {
  constructor(logger = null) {
    this.entries = [];
    this.logger = logger;
    this.done = false;
    this.installed = false;
  }

  register(label, fn) {
    this.entries.push({ label, fn });
  }

  /** 挂进程级信号：Ctrl-C / 未捕获异常同样要清理。 */
  installProcessHandlers() {
    if (this.installed) return;
    this.installed = true;
    const bail = (reason) => {
      this.runAllSync(reason);
      process.exit(1);
    };
    process.on('SIGINT', () => bail('SIGINT'));
    process.on('SIGTERM', () => bail('SIGTERM'));
    process.on('uncaughtException', (error) => {
      if (this.logger) this.logger(`uncaught: ${error?.stack ?? error}`);
      bail('uncaughtException');
    });
  }

  /** 同步收尾（信号路径用）；失败只记录，不中断其余条目。 */
  runAllSync(reason = 'normal') {
    if (this.done) return [];
    this.done = true;
    const results = [];
    for (const entry of [...this.entries].reverse()) {
      try {
        entry.fn();
        results.push({ label: entry.label, ok: true });
      } catch (error) {
        results.push({ label: entry.label, ok: false, error: String(error?.message ?? error) });
        if (this.logger) this.logger(`teardown '${entry.label}' failed: ${error?.message ?? error}`);
      }
    }
    if (this.logger) this.logger(`teardown finished (${reason}): ${results.length} entries`);
    return results;
  }
}

/** Windows 上 child.kill() 不保证带走子孙进程 ⇒ 兜底用 taskkill /T。 */
function killTree(child) {
  if (!child || child.exitCode !== null || child.killed) return;
  try {
    child.kill();
  } catch { /* 已退出 */ }
  if (process.platform !== 'win32') return;
  try {
    execFileSync('taskkill', ['/pid', String(child.pid), '/T', '/F'],
      { stdio: 'ignore', windowsHide: true });
  } catch { /* 已经没了就是我们要的结果 */ }
}

export class HilogCollector {
  /**
   * @param {import('./hdc.mjs').Hdc} hdc
   * @param {object} options
   * @param {string} options.rawPath      流式落盘路径（原始证据，只读归档）
   * @param {number} [options.byteBudget]
   * @param {(msg: string) => void} [options.logger]
   */
  constructor(hdc, options) {
    this.hdc = hdc;
    this.rawPath = options.rawPath;
    this.byteBudget = options.byteBudget ?? DEFAULT_BYTE_BUDGET;
    this.logger = options.logger ?? (() => {});
    this.tailBytes = options.tailBytes ?? DEFAULT_TAIL_BYTES;
    this.child = null;
    this.sink = null;
    this.bytes = 0;
    this.lines = 0;
    this.truncated = false;
    this.formatFallback = false;
    this.clearOutput = null;
    this.startedAtMs = null;
    this.readyMs = null;
    this.tailChunks = [];
    this.tailLength = 0;
  }

  /** 采集期的内存尾窗文本，供判据匹配（见 DEFAULT_TAIL_BYTES 的理由）。 */
  tail() {
    return Buffer.concat(this.tailChunks).toString('utf8');
  }

  #pushTail(chunk) {
    this.tailChunks.push(chunk);
    this.tailLength += chunk.length;
    while (this.tailLength > this.tailBytes && this.tailChunks.length > 1) {
      this.tailLength -= this.tailChunks.shift().length;
    }
  }

  /**
   * 清缓冲 → 起流 → 等到第一批字节。
   * @returns {Promise<{ready: boolean, readyMs: number|null, bytes: number}>}
   */
  async start() {
    // ① 清缓冲。之后缓冲区里仍会留下那条设备启动时刻的持久哨兵行 ——
    //    所以时间锚点不能用"最早一行"（契约 §8.5，parse.mjs 的 validateTimeAnchor 强制）。
    this.clearOutput = this.hdc.shell('hilog -r').stdout.trim();
    this.logger(`hilog -r → ${JSON.stringify(this.clearOutput)}`);

    // ② 起流。`-v year -v zone -v msec` 让每行带完整日期与时区（默认格式两者都没有，
    //    时间轴对账会退化成"猜年份"）。实测这些是格式选项、可与流模式共存；
    //    但 `-x` 与 `-z` 之类的**命令**不能组合（设备返回
    //    `Mutlti commands can't be used in combination`）⇒ 这里只加格式选项。
    const ready = await this.#spawnStream(['-v', 'year', '-v', 'zone', '-v', 'msec']);
    if (ready.ready) return ready;

    // ③ 兜底：格式选项在别的固件上若不被接受，退回默认格式（parse.mjs 两种都能解析）。
    this.logger('hilog stream produced no bytes with format flags; retrying plain');
    this.formatFallback = true;
    return this.#spawnStream([]);
  }

  async #spawnStream(extraArgs) {
    const command = ['hilog', ...extraArgs].join(' ');
    const args = this.hdc.argsWithTarget(['shell', command]);
    this.startedAtMs = Date.now();
    this.sink = createWriteStream(this.rawPath, { flags: 'a' });
    this.child = spawn(this.hdc.path, args, {
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
    });

    this.child.stdout.on('data', (chunk) => {
      this.bytes += chunk.length;
      for (let i = 0; i < chunk.length; i += 1) if (chunk[i] === 0x0a) this.lines += 1;
      this.#pushTail(chunk);
      if (this.bytes > this.byteBudget) {
        if (!this.truncated) {
          this.truncated = true;
          this.logger(`hilog stream hit byte budget ${this.byteBudget}; truncating`);
          killTree(this.child);
        }
        return;
      }
      this.sink.write(chunk);
    });
    this.child.stderr.on('data', (chunk) => {
      this.logger(`hilog stream stderr: ${chunk.toString('utf8').trim().slice(0, 300)}`);
    });

    const readyMs = await this.#waitForFirstBytes(DEFAULT_READY_TIMEOUT_MS);
    if (readyMs === null) {
      killTree(this.child);
      return { ready: false, readyMs: null, bytes: this.bytes };
    }
    this.readyMs = readyMs;
    this.logger(`hilog stream ready after ${readyMs} ms (${this.bytes} bytes)`);
    return { ready: true, readyMs, bytes: this.bytes };
  }

  /** 就绪 = 观察到第一批字节（单调量），不是"spawn 返回了"。 */
  #waitForFirstBytes(timeoutMs) {
    return new Promise((resolve) => {
      const deadline = Date.now() + timeoutMs;
      const tick = () => {
        if (this.bytes > 0) { resolve(Date.now() - this.startedAtMs); return; }
        if (this.child?.exitCode !== null && this.child?.exitCode !== undefined) {
          resolve(null); return;
        }
        if (Date.now() >= deadline) { resolve(null); return; }
        setTimeout(tick, 50);
      };
      tick();
    });
  }

  /** 采集期内的计数快照 —— §1.2 要求的单调量。 */
  counters() {
    return { bytes: this.bytes, lines: this.lines, truncated: this.truncated };
  }

  /** 停止采集并把 sink 关干净。可重复调用（收尾登记表会再调一次）。 */
  async stop() {
    killTree(this.child);
    await new Promise((resolve) => {
      if (!this.sink || this.sink.closed) { resolve(); return; }
      this.sink.end(resolve);
    });
    return this.counters();
  }
}
