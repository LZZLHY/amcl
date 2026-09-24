#!/usr/bin/env node
/**
 * 主项目的物理目录门禁：Agent 配置与自建运行资料必须在 AMCL 工作区根外置。
 * 只检查工程顶层的明确禁止名称及 docker/output，不遍历第三方仓库或正常源码。
 * Git ignore 不影响本门禁；lstat 同样识别普通文件、空目录、失效链接和目录联接。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FORBIDDEN = new Set([
  '.vscode', '.cursor', '.codex', '.claude', '.kiro', '.codegenie', '.logs', '.ua',
  'diagnostics', 'artifacts', 'validation-packages', 'semantic-review', 'tmp_hypium', 'meta-inf',
]);

/** 仅本项目明确外置的名字；大小写统一，避免 Windows/macOS 与 Linux CI 判据不同。 */
function forbiddenTopLevel(name) {
  const lower = name.toLowerCase();
  return FORBIDDEN.has(lower) || lower.startsWith('.tmp') || lower.startsWith('.codex-');
}

/** lstat 不跟随链接；只有不存在允许返回 null，权限/IO 错误必须让检查失败。 */
function inspectEntry(file) {
  try { return fs.lstatSync(file); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

/** 返回违规项，不移动、删除或创建目录；root 参数也供独占临时工程的负向测试使用。 */
export function checkWorkspaceLayout(root = ROOT) {
  root = path.resolve(root);
  const findings = [];
  const entries = fs.readdirSync(root);
  const report = (relative, stat, reason) => findings.push({
    path: relative,
    kind: stat.isSymbolicLink() ? 'link/junction' : stat.isDirectory() ? 'directory' : 'file',
    reason,
  });
  for (const entry of entries) {
    const absolute = path.join(root, entry);
    if (forbiddenTopLevel(entry)) {
      const stat = inspectEntry(absolute);
      if (stat) report(entry, stat, 'Agent 配置或自建临时/运行资料须外置到工作区根');
    }
    if (entry.toLowerCase() !== 'docker') continue;
    const docker = inspectEntry(absolute);
    if (!docker) continue;
    // 不通过指向工程外的 docker 链接检查外部内容，避免路径别名绕过物理布局边界。
    if (docker.isSymbolicLink()) { report(entry, docker, 'docker 配方目录不能以链接隐藏外部输出'); continue; }
    if (!docker.isDirectory()) continue;
    for (const child of fs.readdirSync(absolute)) {
      if (child.toLowerCase() !== 'output') continue;
      const stat = inspectEntry(path.join(absolute, child));
      if (stat) report(`${entry}/${child}`, stat, 'Docker 输出须写入工作区 .workspace/build/<任务>/out');
    }
  }
  return findings.sort((a, b) => a.path.localeCompare(b.path));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    if (args.length && (args.length !== 2 || args[0] !== '--root')) throw new Error('Usage: check-workspace-layout.mjs [--root <project>]');
    const findings = checkWorkspaceLayout(args[1] || ROOT);
    if (findings.length) {
      for (const item of findings) console.error(`[workspace-layout] FAIL ${item.path} (${item.kind}): ${item.reason}`);
      process.exitCode = 1;
    } else {
      console.log('[workspace-layout] PASS: project root and docker/output contain no forbidden Agent/temporary entries');
    }
  } catch (error) {
    console.error(`[workspace-layout] ERROR: ${error.message}`);
    process.exitCode = 1;
  }
}
