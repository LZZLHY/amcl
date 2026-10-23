#!/usr/bin/env node
/**
 * 从已经按锁恢复的公开依赖复制上游许可正文，并记录 Git 提交和原路径。
 * 本工具不修改第三方源码、不联网，不把来源索引解释为全部二进制的许可审查。
 * 先运行 prepare-public-deps.mjs，再在仓库根运行本文件；正文按 LF 保存以便跨平台验收。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const sourceIndex = args.indexOf('--source');
const onlyIndex = args.indexOf('--only');
// 公开候选不必再物化一套大型依赖；可只读已经验明身份的冻结源树。
// 输出仍固定在本公开仓，不能由外部输入改变许可证的发布落点。
const app = sourceIndex >= 0 ? fs.realpathSync(args[sourceIndex + 1]) : path.join(root, 'MyApplication');
const output = path.join(root, 'MyApplication/third-party-notices');
const components = {
  lwjgl3: 'prebuilt/lwjgl3/lwjgl3_src',
  mobileglues: 'prebuilt/mobileglues/mg_src',
  mobilegl: 'prebuilt/mobilegl/src',
  openal: 'entry/src/main/cpp/openal/openal-soft',
  fmt: 'entry/src/main/cpp/openal/openal-soft/fmt-11.1.1',
  sdl3: 'prebuilt/sdl3/sdl3_src',
  asio: 'prebuilt/mobilegl/src/3rdparty/asio',
  glslang: 'prebuilt/mobilegl/src/3rdparty/glslang',
  'spirv-cross': 'prebuilt/mobilegl/src/3rdparty/SPIRV-Cross',
  'spirv-reflect': 'prebuilt/mobilegl/src/3rdparty/SPIRV-Reflect',
  'spirv-tools': 'prebuilt/mobilegl/src/3rdparty/glslang/External/spirv-tools',
  'spirv-headers': 'prebuilt/mobilegl/src/3rdparty/glslang/External/spirv-tools/external/spirv-headers',
  vma: 'prebuilt/mobilegl/src/3rdparty/VulkanMemoryAllocator',
  'vulkan-headers': 'prebuilt/mobilegl/src/3rdparty/Vulkan-Headers',
  'vulkan-utility': 'prebuilt/mobilegl/src/3rdparty/Vulkan-Utility-Libraries',
  xxhash: 'prebuilt/mobilegl/src/3rdparty/xxHash',
  'tl-expected': 'prebuilt/mobilegl/src/include/tl',
  'ska-flat-hash-map': 'prebuilt/mobilegl/src/include/ska',
  hdc: 'prebuilt/hdc/muka-rust-hdc',
};
const selected = onlyIndex >= 0 ? args[onlyIndex + 1]?.split(',').filter(Boolean) : Object.keys(components);
if (!selected?.length || selected.some(component => !Object.hasOwn(components, component))) {
  throw new Error('Unknown or empty component selection');
}
// 增量更新只保留内容摘要已核实的旧条目；其余组件的来源变化须另行检查，
// 不能用本命令的局部成功宣称整个第三方许可审查已经完成。
const records = onlyIndex >= 0 ? JSON.parse(fs.readFileSync(path.join(output, 'manifest.json'), 'utf8')).files
  .filter(record => !selected.includes(record.component)) : [];
for (const record of records) {
  const bytes = fs.readFileSync(path.join(output, record.file), 'utf8').replace(/\r\n/g, '\n');
  if (createHash('sha256').update(bytes).digest('hex') !== record.sha256) throw new Error(`Retained notice changed: ${record.file}`);
}
for (const [component, relative] of Object.entries(components)) {
  if (!selected.includes(component)) continue;
  const directory = path.join(app, relative);
  const git = (...args) => execFileSync('git', ['-C', directory, ...args], { encoding: 'utf8' }).trim();
  const repository = git('rev-parse', '--show-toplevel');
  const commit = git('rev-parse', 'HEAD');
  const origin = git('remote', 'get-url', 'origin');
  if (!/^https:\/\/github\.com\/[\w.-]+\/[\w.-]+(?:\.git)?$/.test(origin)) throw new Error(`Non-public origin needs review: ${component}`);
  const files = fs.readdirSync(directory, { withFileTypes: true }).filter(entry =>
    entry.isFile() && /^(?:LICENSE|COPYING|NOTICE)(?:[._-].*)?$/i.test(entry.name));
  if (!files.length) throw new Error(`No top-level license found: ${component}`);
  for (const file of files) {
    const input = path.join(directory, file.name);
    const text = fs.readFileSync(input, 'utf8').replace(/\r\n/g, '\n');
    const destination = path.posix.join(component, file.name);
    fs.mkdirSync(path.dirname(path.join(output, destination)), { recursive: true });
    fs.writeFileSync(path.join(output, destination), text);
    const upstreamPath = path.relative(repository, input).replace(/\\/g, '/');
    records.push({ component, file: destination, sha256: createHash('sha256').update(text).digest('hex'),
      origin, commit, upstreamPath, source: `${origin.replace(/\.git$/, '')}/blob/${commit}/${upstreamPath}` });
  }
}
fs.writeFileSync(path.join(output, 'manifest.json'), JSON.stringify({ schema: 1, files: records }, null, 2) + '\n');
console.log(`Verified ${records.length} upstream license/notice files; refreshed ${selected.length} source locations`);
