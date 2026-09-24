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
for (const failure of failures) console.error(failure);
// 第三方工作树补丁也是快照的一部分；它与锁定子模块分开保存，不自动应用。
for (const dependency of manifest.dependencyWorktrees ?? []) {
  if (!dependency.patch) continue;
  const patch = path.resolve(root, dependency.patch);
  if (!patch.startsWith(root + path.sep) || !fs.existsSync(patch)
      || createHash('sha256').update(fs.readFileSync(patch)).digest('hex') !== dependency.patchSha256) {
    failures.push(`missing or changed dependency patch: ${dependency.patch}`);
    console.error(failures.at(-1));
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
    console.error(failures.at(-1));
  }
}
console.log(`Public snapshot: ${manifest.entries.length} files, ${failures.length} failures; base=${manifest.sourceCommit}, sourceDirty=${manifest.sourceDirty}`);
process.exitCode = failures.length ? 1 : 0;
