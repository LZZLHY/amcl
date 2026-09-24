/**
 * 验证目录整理保留的历史证据字节。只检查可提交的相对清单，不要求维护者的私有原始归档。
 * 这样新克隆可以确认样本没有丢失或被换行转换，而不是只信“已经移动”的描述。
 */
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PREFIX = 'docs/testing/evidence/';

/** 返回全部失败原因；非法/重复路径拒绝读取，缺文件或字节变化均不能被忽略。 */
export function checkEvidenceArchive(root = ROOT) {
  const manifest = JSON.parse(fs.readFileSync(path.join(root, PREFIX, 'migration-manifest.json'), 'utf8'));
  const issues = [];
  if (fs.existsSync(path.join(root, 'diagnostics'))) {
    issues.push('legacy project diagnostics directory reappeared; use external run output or versioned evidence');
  }
  if (manifest.schema !== 1 || !Array.isArray(manifest.files) || manifest.files.length !== manifest.count) {
    return ['invalid evidence migration manifest schema/count'];
  }
  const seen = new Set();
  for (const item of manifest.files) {
    if (typeof item.path !== 'string' || !item.path.startsWith(PREFIX) || item.path.includes('\\') ||
        item.path.split('/').includes('..') || seen.has(item.path)) {
      issues.push(`invalid or duplicate evidence path: ${item.path}`);
      continue;
    }
    seen.add(item.path);
    const file = path.join(root, item.path);
    if (!fs.existsSync(file) || !fs.statSync(file).isFile()) {
      issues.push(`missing evidence: ${item.path}`);
      continue;
    }
    const bytes = fs.readFileSync(file);
    if (bytes.length !== item.bytes || createHash('sha256').update(bytes).digest('hex') !== item.sha256) {
      issues.push(`evidence bytes changed: ${item.path}`);
    }
  }
  return issues;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const issues = checkEvidenceArchive();
  if (issues.length) {
    console.error(issues.join('\n'));
    process.exitCode = 1;
  } else {
    console.log('Historical evidence migration: all manifest paths preserve their exact bytes');
  }
}
