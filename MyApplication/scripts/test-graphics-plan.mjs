import { existsSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import process from 'node:process';
import { workspaceTempRoot } from './lib/workspace-paths.mjs';

const root = path.resolve(import.meta.dirname, '..');
const src = path.join(root, 'entry/src/main/cpp/platform');
const testSource = path.join(root, 'entry/src/main/cpp/tests/host/graphics_plan_host_test.cpp');
const launcher = readFileSync(path.join(root, 'entry/src/main/cpp/jvm/mc_launcher.cpp'), 'utf8');
if (!launcher.includes('options_preference_preserved=1') || launcher.includes('corrected options.txt preferredGraphicsBackend vulkan->default')) {
  throw new Error('options Vulkan preference must be preserved and never rewritten');
}
const compiler = process.env.CXX || 'g++';
// 每个宿主进程使用独立名称，避免并发测试覆写；目录由共享策略保证在源码仓之外。
const out = path.join(workspaceTempRoot(), `amcl-graphics-plan-${process.pid}${process.platform === 'win32' ? '.exe' : ''}`);
if (!existsSync(path.join(src, 'graphics_plan.cpp')) || !existsSync(testSource)) throw new Error('graphics plan host sources missing');
const r = spawnSync(compiler, ['-std=c++17', '-I', src, path.join(src, 'graphics_plan.cpp'), testSource, '-o', out], { encoding: 'utf8' });
if (r.error && r.error.code === 'ENOENT') {
  console.error('graphics_plan_host_test: compiler unavailable; refusing to report PASS');
  process.exit(2);
}
if (r.status !== 0) { process.stderr.write(r.stderr || 'compile failed\n'); process.exit(r.status || 1); }
const run = spawnSync(out, [], { encoding: 'utf8' });
process.stdout.write(run.stdout || '');
if (run.status !== 0) { process.stderr.write(run.stderr || 'test failed\n'); process.exit(run.status || 1); }
