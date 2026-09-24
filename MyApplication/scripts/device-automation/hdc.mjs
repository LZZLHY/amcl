#!/usr/bin/env node
// hdc 调用封装 —— P0 宿主编排器与设备之间的唯一出口。
//
// 文档：docs/guides/test-automation-contract.md §6.2（通道无关的硬约束）
//
// 四条约束全部来自 AGENTS.md §三，每条都曾让人得出过错误结论：
//   1. `hdc` 不在 PATH，且本机另有 DevEco 与各 API 版本 SDK 里的副本、版本行为不同
//      ⇒ 只认权威副本，并把版本写进 manifest。用错副本会把"工具版本差异"误当成"设备行为"。
//   2. `hdc shell` 不接受管道组合 ⇒ 整条命令作为一个参数传入。出现 `|` 时这里直接抛，
//      而不是让它静默返回一份被截断的输出 —— 后者会被读成"设备上没有这个东西"。
//   3. hilog 单条 4096 B ⇒ 大输出一律落文件，不经日志通道回传。
//   4. `/data/local/tmp` 不可执行 ⇒ 不提供任何"推二进制上去跑"的辅助。
//
// ⚠️ 刻意不用退出码判成败：实测 hdc 对设备侧的错误（例如
// `Mutlti commands can't be used in combination`）仍然 exit 0 并把错误文本写到 stdout。
// ⇒ 本模块只负责把原始文本交出去，判定一律由 parse.mjs 的纯函数做（契约 §8.2：
// 不得只凭退出码判 PASS）。

import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';

/** AGENTS.md §三 指定的权威副本（2026-09-07 实测 Ver: 3.2.0f）。 */
export const AUTHORITATIVE_HDC =
  'D:\\Huawei\\command-line-tools\\sdk\\default\\openharmony\\toolchains\\hdc.exe';

export const DEFAULT_BUNDLE = 'com.amcl.launcher';

const DEFAULT_TIMEOUT_MS = 30_000;
/** 单次命令的输出上限。`bm dump` 约 26 KB、`hilog -x` 可达上百 MB ⇒ 给足余量。 */
const MAX_BUFFER_BYTES = 256 * 1024 * 1024;

export class HdcError extends Error {
  constructor(message, detail = {}) {
    super(message);
    this.name = 'HdcError';
    Object.assign(this, detail);
  }
}

/**
 * 定位 hdc。override 只接受显式传入的绝对路径（命令行 --hdc）。
 *
 * ⚠️ 刻意不读环境变量：契约 §5.2 禁止用环境变量当开关，这里保持同一口径 ——
 * 宿主侧也不给"某台机器上悄悄换了 hdc"留后门，否则报告里的 hdcVersion 与实际不符。
 */
export function resolveHdcPath(override) {
  const candidate = override ?? AUTHORITATIVE_HDC;
  if (!existsSync(candidate)) {
    throw new HdcError(
      `hdc not found at ${candidate}. AGENTS.md §三 requires the authoritative copy; ` +
      'pass --hdc <absolute path> if it moved.',
      { path: candidate });
  }
  return candidate;
}

/** `hdc shell` 的命令串里不允许出现管道/串联 —— 见文件头第 2 条。 */
export function assertSingleShellCommand(command) {
  if (typeof command !== 'string' || command.trim() === '') {
    throw new HdcError('shell command must be a non-empty string', { command });
  }
  const forbidden = ['|', '&&', ';', '>', '<'];
  for (const token of forbidden) {
    if (command.includes(token)) {
      throw new HdcError(
        `shell command contains '${token}'. hdc shell does not accept composition ` +
        '(AGENTS.md §三.6); filter/redirect on the host side instead.',
        { command, token });
    }
  }
}

export class Hdc {
  /**
   * @param {object} options
   * @param {string} [options.path]      hdc 绝对路径（默认权威副本）
   * @param {string} [options.sn]        设备序列号；给了就每条命令都带 `-t`
   * @param {number} [options.timeoutMs] 单条命令超时
   * @param {(entry: object) => void} [options.onCommand] 命令留痕回调（写 raw/commands.jsonl）
   */
  constructor(options = {}) {
    this.path = options.path ?? resolveHdcPath();
    this.sn = options.sn ?? null;
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.onCommand = options.onCommand ?? null;
  }

  /** 带 `-t <sn>` 的完整参数表；未指定 SN 时不加（仅用于 `list targets`）。 */
  argsWithTarget(args) {
    return this.sn ? ['-t', this.sn, ...args] : [...args];
  }

  /**
   * 执行一条 hdc 命令并返回原始文本。不抛（除了工具本身启动失败）。
   * @returns {{stdout: string, stderr: string, status: number|null, timedOut: boolean, ms: number}}
   */
  raw(args, options = {}) {
    const finalArgs = options.noTarget ? [...args] : this.argsWithTarget(args);
    const startedAt = Date.now();
    const result = spawnSync(this.path, finalArgs, {
      encoding: 'utf8',
      timeout: options.timeoutMs ?? this.timeoutMs,
      maxBuffer: MAX_BUFFER_BYTES,
      windowsHide: true,
    });
    const entry = {
      args: finalArgs,
      status: result.status,
      timedOut: result.error?.code === 'ETIMEDOUT',
      ms: Date.now() - startedAt,
      stdout: result.stdout ?? '',
      stderr: result.stderr ?? '',
    };
    if (result.error && !entry.timedOut) {
      throw new HdcError(`failed to spawn hdc: ${result.error.message}`,
        { args: finalArgs, cause: result.error });
    }
    if (this.onCommand) this.onCommand(entry);
    return entry;
  }

  /** `hdc shell "<one command>"`。 */
  shell(command, options = {}) {
    assertSingleShellCommand(command);
    return this.raw(['shell', command], options);
  }

  /** `hdc -v` → 原始文本（形如 `Ver: 3.2.0f`）。解析交给 parse.mjs。 */
  versionText() {
    return this.raw(['-v'], { noTarget: true }).stdout;
  }

  /** `hdc list targets` → 原始文本。 */
  targetsText() {
    return this.raw(['list', 'targets'], { noTarget: true }).stdout;
  }

  /**
   * 把设备上的文件取回宿主。用物理路径（AGENTS.md §三.1：取回可以直接用物理路径）。
   * 返回原始命令结果，成功与否由调用方按落地文件判定 —— hdc 的退出码在这里同样不可信。
   */
  fileRecv(devicePath, localPath) {
    return this.raw(['file', 'recv', devicePath, localPath]);
  }

  /** `hdc fport ls` → 原始文本（收尾时用来断言无残留）。 */
  fportListText() {
    return this.raw(['fport', 'ls'], { noTarget: true }).stdout;
  }
}
