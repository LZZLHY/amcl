#!/usr/bin/env node
// 产出物写入 —— 契约 §8.5 的三份文件与三条硬约束。
//
//   ① 应用侧逐动作 JSONL  → 属 L1a/L1b，P0 没有（应用零改动），本轮不产出。
//   ② 宿主侧运行清单 manifest.json + ③ 机器摘要 summary.json / 人类报告 report.md
//
// 三条硬约束在这里各有一段实现：
//   1. 原始证据只读归档、绝不原地改写 ⇒ 归档时把 raw 文件置为只读并记 sha256。
//   2. `missing[]` 在 INCONCLUSIVE 时必须非空 ⇒ 由 verdict.mjs 断言，写入前跑一遍。
//   3. 提交进仓库的只有三份摘要，且不得含 token / 完整 SN / 账号 / 用户内容
//      ⇒ assertNoSecrets() 在**写盘前**扫一遍，而不是靠"记得脱敏"这条约定。

import { chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync }
  from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join, relative as relative_, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { validateSummary } from './verdict.mjs';

/** 提交进仓库的摘要目录（契约 §8.5 硬约束 3）。 */
export const COMMITTED_DIR = 'diagnostics/device-automation';
/** 大件原始输出目录（`.gitignore` 已有 `/.logs/` ⇒ 本就不入库）。 */
export const RAW_DIR = '.logs/device-automation';

/**
 * SN 脱敏：留首四位与末四位，够用来在多设备场景里区分，又不是完整序列号。
 * 完整 SN 只出现在被忽略的 raw 目录里（命令留痕需要它才能复跑）。
 */
export function redactSn(sn) {
  const value = String(sn ?? '');
  if (value.length <= 8) return '****';
  return `${value.slice(0, 4)}****${value.slice(-4)}`;
}

export function sha256Of(buffer) {
  return createHash('sha256').update(buffer).digest('hex');
}

export function sha256File(path) {
  return sha256Of(readFileSync(path));
}

/**
 * 在**写盘前**扫描将要入库的文本，确认没有不该进仓库的东西。
 *
 * 为什么要机械扫描而不是靠约定：脱敏漏一处的失败形态是"报告看起来很正常"，
 * 没有任何信号。⇒ 把它变成一条会失败的断言。
 *
 * @param {Array<{name: string, text: string}>} files
 * @param {object} options
 * @param {string[]} options.secrets 明文机密（完整 SN、token…）
 */
export function assertNoSecrets(files, options = {}) {
  const issues = [];
  const secrets = (options.secrets ?? []).filter(s => typeof s === 'string' && s.length >= 6);
  for (const file of files) {
    for (const secret of secrets) {
      if (file.text.includes(secret)) {
        issues.push(`${file.name} contains a secret literal (${redactSn(secret)})`);
      }
    }
    // token 形状：契约 §5 的 G4 令牌"永不进日志"。P0 没有 token，但把断言先立住，
    // 以免 P2 接 L1b 时才想起来（那时摘要格式已经固化）。
    const tokenLike = /\b(?:token|bearer|authorization)\b\s*[:=]\s*["']?[A-Za-z0-9._-]{12,}/i;
    if (tokenLike.test(file.text)) {
      issues.push(`${file.name} looks like it embeds a token`);
    }
  }
  return issues;
}

/**
 * git 状态 —— 契约 §8.5 manifest 的 `git` 字段。
 *
 * ⭐ **脏树的身份是内容哈希，不是文件计数**（契约 §8.5，2026-09-07 实测教训）：
 * 同一棵树在半天内被两个会话各自新增文件后，"未提交文件数"从 286 变成 297 ——
 * 那是个**会漂的数**，回答不了"这次跑的是哪份源码"。⇒ 身份用 `git diff HEAD` 全文的
 * SHA-256：对同一份改动稳定、对任何一处改动都变；计数只作人读的规模提示。
 * 这与 §1.2.1（量必须有固定采样时点）同源：会漂的量比没有量更糟。
 *
 * ⚠️ 已知边界：`git diff HEAD` **不含未跟踪文件** ⇒ `trackedDiffSha256` 不覆盖
 * 新增但未 `git add` 的内容。本编排器自身在首次提交前就属于这一类。
 * ⇒ 这里额外记 `untrackedFiles` 作为提示，但它同样只是提示、不是身份。
 */
export function collectGitState(repoRoot) {
  const run = (args) => {
    const result = spawnSync('git', ['-C', repoRoot, ...args],
      { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, windowsHide: true });
    return result.stdout ?? '';
  };
  const commit = run(['rev-parse', 'HEAD']).trim();
  const trackedDiff = run(['diff', 'HEAD']);
  const trackedNames = run(['diff', '--name-only', 'HEAD']).trim();
  const untrackedNames = run(['ls-files', '--others', '--exclude-standard']).trim();
  const countLines = (text) => (text.length === 0 ? 0 : text.split(/\r?\n/).filter(Boolean).length);
  const dirtyTrackedFiles = countLines(trackedNames);
  const untrackedFiles = countLines(untrackedNames);
  return {
    commit: commit.length > 0 ? commit : null,
    dirty: dirtyTrackedFiles > 0 || untrackedFiles > 0,
    // 干净树也算：空 diff 的哈希是常量，身份因此永远是良定义的。
    trackedDiffSha256: sha256Of(Buffer.from(trackedDiff, 'utf8')),
    dirtyTrackedFiles,
    untrackedFiles,
  };
}

/**
 * 运行自闭包（契约 §10.5.0）：**跑这一轮的编排器自身**是否全部入库。
 *
 * ⚠️ 它**不回答**"某个施工批次能不能提交" —— 那是批次闭包，落在文档里、由施工者声明。
 * 两者共用一个字段名正是契约初稿的缺陷，所以这里的 `note` 必须写死那句免责。
 *
 * 机械计算：从入口文件出发递归解析相对 import，逐个问 `git cat-file -e HEAD:<path>`。
 * ⇒ 不接受任何人工输入 —— 人手填、无从校验的字段一定会漂（§10.5.0 已否决 `--blocked-by`）。
 *
 * ⭐ 它顺带闭合 §8.5 那个自指缺口：`trackedDiffSha256` 覆盖不到未跟踪文件，
 * 而"编排器自己是不是其中之一"正是那条边界最要紧的实例。
 */
export function collectSelfClosure(repoRoot, entryAbsolutePath) {
  const visited = new Set();
  const untracked = [];
  const isTracked = (relative) => {
    const result = spawnSync('git', ['-C', repoRoot, 'cat-file', '-e', `HEAD:${relative}`],
      { encoding: 'utf8', windowsHide: true });
    return result.status === 0;
  };

  const walk = (absolute) => {
    if (visited.has(absolute)) return;
    visited.add(absolute);
    if (!existsSync(absolute)) return;
    const relativePath = relative_(repoRoot, absolute).replace(/\\/g, '/');
    if (!isTracked(relativePath)) untracked.push(relativePath);
    const text = readFileSync(absolute, 'utf8');
    // 只跟相对 import：node 内置模块与第三方不属"编排器自身"。
    for (const match of text.matchAll(/from\s+'(\.[^']+)'/g)) {
      walk(resolve(dirname(absolute), match[1]));
    }
  };
  walk(entryAbsolutePath);

  return {
    committable: untracked.length === 0,
    untrackedImports: untracked,
    note: '编排器自身的可提交性；不描述任何施工批次（契约 §10.5.0）',
  };
}

/**
 * 归档 raw 目录：逐文件 sha256 + 置只读。
 * 返回 `{ '<相对路径>': { bytes, sha256 } }`，写进 summary.artifacts.hashes。
 */
export function archiveRawDir(rawDirAbsolute, repoRoot) {
  const hashes = {};
  if (!existsSync(rawDirAbsolute)) return hashes;
  for (const name of readdirSync(rawDirAbsolute)) {
    const absolute = join(rawDirAbsolute, name);
    const info = statSync(absolute);
    if (!info.isFile()) continue;
    hashes[relative_(repoRoot, absolute).replace(/\\/g, '/')] = {
      bytes: info.size,
      sha256: sha256File(absolute),
    };
    // 契约 §8.5 硬约束 1：只读归档。置只读之后本轮不可能再往里写，
    // "原地改写原始证据"从此需要显式解除只读，不会顺手发生。
    try { chmodSync(absolute, 0o444); } catch { /* 只读失败不影响哈希已记录 */ }
  }
  return hashes;
}

function renderTable(rows, headers) {
  const lines = [`| ${headers.join(' | ')} |`, `|${headers.map(() => '---').join('|')}|`];
  for (const row of rows) lines.push(`| ${row.join(' | ')} |`);
  return lines.join('\n');
}

/** 人类报告。机器判定只读 manifest/summary，这份给人看（契约 §8.5）。 */
export function renderReportMd({ manifest, summary, notes = [], blockedNotes = [] }) {
  const scenarioRows = summary.scenarios.map(s => [
    `\`${s.id}\``,
    s.verdict,
    s.tier ?? '—',
    s.blockedBy ? `阻塞于 **${s.blockedBy}**` : (s.missing?.length ? `缺 ${s.missing.join(', ')}` : '—'),
    s.note ?? '',
  ]);

  const evidenceRows = summary.scenarios.map(s => [
    `\`${s.id}\``,
    ['E1', 'E2', 'E3', 'E4'].map(k => (s.evidence?.[k] === true ? k : '·')).join(' '),
    Object.entries(s.counters ?? {})
      .map(([name, value]) => `${name}=${typeof value === 'object' ? JSON.stringify(value) : value}`)
      .join(' ') || '—',
  ]);

  return `# 设备自动化运行报告 — ${summary.runId}

> 本文给人看。**机器判定只读 \`manifest.json\` 与 \`summary.json\`**（契约 §8.5）。
> 判决五值含义见契约 §8.4；\`BLOCKED\` 表示前置批次未落地，**不是** \`FAIL\`。

## 总判决：\`${summary.verdict}\`

${summary.verdict === 'BLOCKED'
    ? '⚠️ `BLOCKED` 是本轮的**正确结果**：多数冒烟格子依赖尚未落地的批次（见下表 `阻塞于`）。\n把它写成 `FAIL` 会把"工具还没做"读成"功能坏了"（契约 §8.4）。'
    : ''}

## 运行环境

${renderTable([
    ['hdc', `\`${manifest.host.hdcPath}\` (${manifest.host.hdcVersion})`],
    ['设备', `${manifest.device.sn} / ${manifest.device.model} / ${manifest.device.osFullName} / API ${manifest.device.apiVersion}`],
    ['应用', `${manifest.app.bundle} versionCode=${manifest.app.versionCode} versionName=${manifest.app.versionName} provision=${manifest.app.provisionType}`],
    ['产品轨', `\`${manifest.app.productTrack}\`${manifest.app.productTrack === 'unknown' ? '（D8 之前的**预期降级值**，契约 §8.5）' : ''}`],
    // 身份是 trackedDiffSha256；两个计数只作规模提示（契约 §8.5）。
    ['git', `${manifest.git.commit?.slice(0, 12) ?? 'n/a'}` +
      `${manifest.git.dirty ? ' **dirty**' : ' clean'}` +
      `　trackedDiffSha256=\`${manifest.git.trackedDiffSha256.slice(0, 16)}…\`` +
      `（已跟踪改动 ${manifest.git.dirtyTrackedFiles} 个文件、未跟踪 ${manifest.git.untrackedFiles} 个，` +
      '计数仅供人读，身份看哈希）'],
    ['通道', manifest.channel],
    ['时间锚点', `\`${manifest.timeAnchor.method}\`${manifest.timeAnchor.method === 'borrowed-consumer' ? '（L1a 之前的**预期降级值**）' : ''} host=${manifest.timeAnchor.hostTime} device=${manifest.timeAnchor.deviceTime}`],
    ['结束方式', `\`${manifest.endMethod}\`${manifest.endMethod === 'force-stop' ? ' —— **不等于正常退出**（契约 §9.3）' : ''}`],
  ], ['项', '值'])}

## 逐格判决

${renderTable(scenarioRows, ['场景', '判决', 'tier', '阻塞 / 缺失', '说明'])}

## 证据与计数

${renderTable(evidenceRows, ['场景', '证据通道', '单调量'])}

${blockedNotes.length > 0 ? `## 阻塞说明\n\n${blockedNotes.map(n => `- ${n}`).join('\n')}\n` : ''}
${notes.length > 0 ? `## 本轮记录\n\n${notes.map(n => `- ${n}`).join('\n')}\n` : ''}
## 原始证据

原始输出不入库，以 sha256 定身份（契约 §8.5 硬约束 1/3）：

${renderTable(
    Object.entries(summary.artifacts.hashes).map(([path, info]) =>
      [`\`${path}\``, `${info.bytes} B`, `\`${info.sha256.slice(0, 16)}…\``]),
    ['文件', '大小', 'sha256（前 16 位）'])}
`;
}

/**
 * 写三份产出物。写盘前跑 summary 自洽校验 + 机密扫描，任一不过就**不写**并抛。
 * 理由：一份已经落盘的报告会被下一个人当结论读；宁可不产出，也不产出一份不自洽的。
 */
export function writeArtifacts({ repoRoot, runId, manifest, summary, notes, blockedNotes, secrets }) {
  const summaryIssues = validateSummary(summary);
  if (summaryIssues.length > 0) {
    const error = new Error(`summary is not self-consistent:\n  ${summaryIssues.join('\n  ')}`);
    error.issues = summaryIssues;
    throw error;
  }

  const reportMd = renderReportMd({ manifest, summary, notes, blockedNotes });
  const files = [
    { name: 'manifest.json', text: `${JSON.stringify(manifest, null, 2)}\n` },
    { name: 'summary.json', text: `${JSON.stringify(summary, null, 2)}\n` },
    { name: 'report.md', text: reportMd },
  ];

  const secretIssues = assertNoSecrets(files, { secrets });
  if (secretIssues.length > 0) {
    const error = new Error(`refusing to write artifacts:\n  ${secretIssues.join('\n  ')}`);
    error.issues = secretIssues;
    throw error;
  }

  const outDir = join(repoRoot, COMMITTED_DIR, runId);
  mkdirSync(outDir, { recursive: true });
  for (const file of files) writeFileSync(join(outDir, file.name), file.text, 'utf8');
  return { outDir, files: files.map(f => f.name) };
}
