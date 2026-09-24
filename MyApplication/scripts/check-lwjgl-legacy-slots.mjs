#!/usr/bin/env node
/**
 * 兼容槽交付门禁：核对权威清单、ArkTS 镜像、rawfile 及仍保有独立副本的 prebuilt。
 * 只读现有文件，不重新打包、不改写 deps.lock；摘要针对完成 OHOS 修补的最终 JAR。
 */
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const manifest = JSON.parse(readFileSync(path.join(root, 'prebuilt/lwjgl3/legacy-slots.manifest.json'), 'utf8'));
const load = makePureEtsLoader();
const { lwjglRuntimeSlot } = load('launch/src/main/ets/LwjglRuntimeSlots.ets');
const { lwjglSlotJarNames } = load('launch/src/main/ets/RuntimeSlotClasspath.ets');
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
// 可选产物输入必须显式提供；读取唯一 ZIP 成员，防止只校验源码副本却漏掉实际交付字节。
const args = process.argv.slice(2);
assert.ok(args.length === 0 || (args.length === 2 && args[0] === '--hap'), '用法: check-lwjgl-legacy-slots.mjs [--hap path]');
const hap = args.length === 2 ? readFileSync(path.resolve(args[1])) : null;

assert.equal(manifest.schema, 1);
assert.deepEqual(manifest.slots.map((slot) => slot.id).sort(), ['legacy2', 'legacy322']);
for (const declared of manifest.slots) {
  const sorted = [...declared.jars].sort((a, b) => a.name.localeCompare(b.name));
  const payload = sorted.map((jar) => `${jar.name}|${jar.size}|${jar.sha256}`).join('\n') + '\n';
  assert.equal(hash(payload), declared.manifestEntrySha256, declared.id + ' 清单摘要');
  const runtime = lwjglRuntimeSlot(declared.deploymentDirectory);
  for (const field of ['id', 'version', 'deploymentDirectory', 'resourceDirectory']) {
    assert.equal(runtime[field], declared[field], declared.id + ' ' + field);
  }
  assert.equal(runtime.marker, `amcl.lwjgl.legacy-slot\nversion=${declared.version}\nmanifest=${declared.manifestEntrySha256}\n`);
  assert.deepEqual(runtime.jars, sorted, declared.id + ' ArkTS 内容镜像');
  assert.deepEqual(lwjglSlotJarNames(declared.deploymentDirectory), sorted.map((jar) => jar.name), 'classpath 与内容许可一致');
  if (hap !== null) {
    for (const jar of sorted) {
      const member = 'resources/rawfile/' + declared.resourceDirectory + '/' + jar.name;
      const bytes = readUniqueZipEntry(hap, member);
      assert.equal(bytes.length, jar.size, 'HAP ' + member + ' size');
      assert.equal(hash(bytes), jar.sha256, 'HAP ' + member + ' sha256');
    }
  }
  const directories = ['entry/src/main/resources/rawfile/' + declared.resourceDirectory];
  if (declared.prebuiltDirectory) directories.push(declared.prebuiltDirectory);
  for (const relative of directories) {
    const directory = path.join(root, relative);
    assert.deepEqual(readdirSync(directory).filter((name) => name.endsWith('.jar')).sort(), sorted.map((jar) => jar.name));
    for (const jar of sorted) {
      const file = path.join(directory, jar.name);
      assert.equal(statSync(file).size, jar.size, relative + '/' + jar.name + ' size');
      assert.equal(hash(readFileSync(file)), jar.sha256, relative + '/' + jar.name + ' sha256');
    }
  }
}
console.log('[lwjgl-legacy-slots] PASS: 两兼容槽清单摘要、ArkTS/classpath 镜像与最终 JAR 字节一致'
  + (hap !== null ? '；受检 HAP SHA256=' + hash(hap) : ''));
