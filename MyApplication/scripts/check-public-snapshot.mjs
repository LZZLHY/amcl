#!/usr/bin/env node
/**
 * 验证公开快照里从主工程复制的文件是否完整。清单记录同步时的工作树内容，
 * 独立于私有源仓运行，不要求私有仓访问权限。公开说明和本脚本不冒充主仓文件。
 * 文本按清单统一 LF 后计算 SHA-256，二进制始终按原始字节计算。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'SOURCE_SNAPSHOT.json'), 'utf8'));
const failures = [];
for (const entry of manifest.entries) {
  const file = path.resolve(root, entry.path);
  if (!file.startsWith(root + path.sep) || !fs.existsSync(file)) {
    failures.push(`missing or invalid path: ${entry.path}`);
    continue;
  }
  const bytes = fs.readFileSync(file);
  const content = entry.normalization === 'lf' ? Buffer.from(bytes.toString('utf8').replace(/\r\n/g, '\n')) : bytes;
  if (createHash('sha256').update(content).digest('hex') !== entry.sha256) failures.push(`changed: ${entry.path}`);
}
// 新导出器同时固定公开根子模块定义和可执行mode。旧发行没有这些字段，
// 保持原验证范围；不能为了升级工具而改写历史SOURCE_SNAPSHOT。
if (manifest.publicGitmodulesSha256) {
  const modules = path.join(root, '..', '.gitmodules');
  const text = fs.existsSync(modules) ? fs.readFileSync(modules, 'utf8').replace(/\r\n/g, '\n') : '';
  if (createHash('sha256').update(text).digest('hex') !== manifest.publicGitmodulesSha256) failures.push('missing or changed public .gitmodules');
}
if (manifest.exporter?.schemaVersion >= 2) {
  const indexed = execFileSync('git', ['-C', root, 'ls-files', '--stage', '-z'], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  const modes = new Map(indexed.split('\0').filter(Boolean).map(row => {
    const match = row.match(/^(\d+) [a-f0-9]{40} 0\t([\s\S]+)$/);
    return match ? [match[2], match[1]] : ['', 'unmerged'];
  }));
  for (const entry of manifest.entries) if (entry.mode && modes.get(entry.path) !== entry.mode) {
    failures.push(`changed Git mode: ${entry.path}; expected=${entry.mode}, actual=${modes.get(entry.path) ?? 'missing'}`);
  }
}
// 第三方工作树补丁也是快照的一部分；它与锁定子模块分开保存，不自动应用。
for (const dependency of manifest.dependencyWorktrees ?? []) {
  if (!dependency.patch) continue;
  const patch = path.resolve(root, dependency.patch);
  if (!patch.startsWith(root + path.sep) || !fs.existsSync(patch)
      || createHash('sha256').update(fs.readFileSync(patch)).digest('hex') !== dependency.patchSha256) {
    failures.push(`missing or changed dependency patch: ${dependency.patch}`);
  }
}
// 脱敏证据具有独立身份，不与源仓的原始文件哈希混淆。
const evidenceFiles = [...(manifest.publicEvidence ?? []).map(item => [item.path, item.publicSha256]),
  ...(manifest.publicEvidenceLockSha256 ? [['gate0-evidence.lock', manifest.publicEvidenceLockSha256]] : [])];
for (const [relative, expected] of evidenceFiles) {
  const file = path.resolve(root, relative);
  const content = fs.existsSync(file) && file.startsWith(root + path.sep)
    ? fs.readFileSync(file).toString('utf8').replace(/\r\n/g, '\n') : '';
  if (createHash('sha256').update(content).digest('hex') !== expected) {
    failures.push(`missing or changed public evidence: ${relative}`);
  }
}
for (const failure of failures) console.error(failure);
console.log(`Public snapshot: ${manifest.entries.length} files, ${failures.length} failures; base=${manifest.sourceCommit}, sourceDirty=${manifest.sourceDirty}`);
process.exitCode = failures.length ? 1 : 0;
