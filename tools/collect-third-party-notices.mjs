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
const app = path.join(root, 'MyApplication');
const output = path.join(app, 'third-party-notices');
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
};
const records = [];
for (const [component, relative] of Object.entries(components)) {
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
console.log(`Copied ${records.length} upstream license/notice files from ${Object.keys(components).length} source locations`);
