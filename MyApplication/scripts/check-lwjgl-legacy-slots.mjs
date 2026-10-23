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
import { readElfIdentity } from './check-mg-build-contract.mjs';

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
  // Java末级消费者也需要源码身份，不能只因Native未变就继续交付旧的按键聚合类。
  for (const [file, expected] of Object.entries(declared.javaSourceSha256Lf ?? {})) {
    assert.equal(hash(Buffer.from(readFileSync(path.join(root, file), 'utf8').replace(/\r\n/g, '\n'))),
      expected, declared.id + ' Java rebuild required after ' + file);
  }
  assert.ok(declared.id !== 'legacy2' || declared.nativeArtifact, 'legacy2 requires its paired Native identity');
  // Native 制品与其自有桥接源码同步锁定。只比较源码而不检查 SO 会让JNI修复留在
  // 工作树外；源码正文按 LF 归一化，避免正常 Windows checkout 产生伪漂移。
  if (declared.nativeArtifact) {
    const native = declared.nativeArtifact;
    const bytes = readFileSync(path.join(root, native.file));
    assert.equal(bytes.length, native.size, declared.id + ' Native size');
    assert.equal(hash(bytes), native.sha256, declared.id + ' Native sha256');
    const identity = readElfIdentity(bytes);
    assert.equal(identity.machine, 183, declared.id + ' Native AArch64');
    assert.equal(identity.soname, path.basename(native.file), declared.id + ' Native SONAME');
    for (const [file, expected] of Object.entries(native.sourceSha256Lf)) {
      assert.equal(hash(Buffer.from(readFileSync(path.join(root, file), 'utf8').replace(/\r\n/g, '\n'))),
        expected, declared.id + ' Native rebuild required after ' + file);
    }
    for (const name of native.requiredStrings) {
      assert.ok(bytes.includes(Buffer.from(name + '\0')), declared.id + ' Native dispatch entry: ' + name);
    }
    if (hap !== null) {
      const embedded = readUniqueZipEntry(hap, 'libs/arm64-v8a/' + path.basename(native.file));
      assert.equal(hash(embedded), native.sha256, declared.id + ' HAP Native sha256');
    }
  }
  const sorted = [...declared.jars].sort((a, b) => a.name.localeCompare(b.name));
  const payload = sorted.map((jar) => `${jar.name}|${jar.size}|${jar.sha256}`).join('\n') + '\n';
  assert.equal(hash(payload), declared.manifestEntrySha256, declared.id + ' 清单摘要');
  const runtime = lwjglRuntimeSlot(declared.deploymentDirectory);
  for (const field of ['id', 'version', 'deploymentDirectory', 'resourceDirectory']) {
    assert.equal(runtime[field], declared[field], declared.id + ' ' + field);
  }
  assert.equal(runtime.marker, `amcl.lwjgl.legacy-slot\nversion=${declared.version}\nmanifest=${declared.manifestEntrySha256}\n`);
  // 派生视图新增独立资源路径，旧槽的最终字节身份仍必须逐项与旧锁定清单相同。
  // 单独核对资源定位，不能把新增字段简单忽略后漏掉跨槽读取。
  assert.deepEqual(runtime.jars.map(({ name, size, sha256 }) => ({ name, size, sha256 })),
    sorted, declared.id + ' ArkTS 内容镜像');
  for (const jar of runtime.jars) {
    assert.equal(jar.resourcePath, declared.resourceDirectory + '/' + jar.name, declared.id + ' rawfile 定位');
  }
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
