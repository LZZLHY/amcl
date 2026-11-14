/**
 * 读取已追溯的旧 v1 目录：旧协议回归必须使用固定历史输入，不能跟着随包 v2 目录改变前提。
 * 身份按 Git 文本的 LF 字节核对，兼容 Windows 正常检出换行；不修改夹具，也不参与应用运行。
 */
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';

export function legacyRuntimeCatalogText() {
  const location = new URL('../fixtures/runtime-catalog/legacy-v1.json', import.meta.url);
  const origin = JSON.parse(fs.readFileSync(new URL('../fixtures/runtime-catalog/legacy-v1.origin.json', import.meta.url), 'utf8'));
  const text = fs.readFileSync(location, 'utf8').replace(/\r\n/g, '\n');
  assert.equal(createHash('sha256').update(text).digest('hex'), origin.sha256, '历史目录夹具必须与登记的 Git 原件相同');
  assert.equal(JSON.parse(text).schemaVersion, 1, '旧协议测试不能暗中变成当前 v2 输入');
  return text;
}
