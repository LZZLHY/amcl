/** 完整HDC交叉编译入口。缓存显式外置，源码/Cargo.lock固定；store不调用此脚本。 */
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { assertExternalOutputPath, resolveWorkspacePath } from './lib/workspace-paths.mjs';
import { existsSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const core = join(root, 'entry/src/main/cpp/hdc/core');
const sdk = process.env.DEVECO_SDK_HOME;
if (!sdk) throw new Error('DEVECO_SDK_HOME is required for HDC build');
const native = join(sdk, 'default/openharmony/native');
const targetDir = process.env.AMCL_HDC_TARGET_DIR ? assertExternalOutputPath(process.env.AMCL_HDC_TARGET_DIR) : resolveWorkspacePath('build','hdc-core');
mkdirSync(targetDir, { recursive: true });
const suffix = process.platform === 'win32' ? '.exe' : '';
const result = spawnSync(process.env.CARGO ?? 'cargo', ['build', '--manifest-path', join(core, 'Cargo.toml'),
  '--target', 'aarch64-unknown-linux-ohos', '--release', '--lib', '--locked'], {
  stdio: ['ignore', 'inherit', 'inherit'], env: { ...process.env, CARGO_TARGET_DIR: targetDir,
    // cc-rs按shell转义解析环境中的CFLAGS，路径统一用正斜杠，避免Windows把引号传给clang。
    CC_SHELL_ESCAPED_FLAGS: '1',
    CC_aarch64_unknown_linux_ohos: join(native, 'llvm/bin/clang' + suffix),
    AR_aarch64_unknown_linux_ohos: join(native, 'llvm/bin/llvm-ar' + suffix),
    CFLAGS_aarch64_unknown_linux_ohos: `--target=aarch64-linux-ohos --sysroot="${join(native, 'sysroot').replace(/\\/g, '/')}" -include "${join(core, 'ohos_socket_compat.h').replace(/\\/g, '/')}"`
  }
});
if (result.status !== 0) throw new Error('HDC build failed: ' + result.status);
const archive = join(targetDir, 'aarch64-unknown-linux-ohos/release/libamcl_hdc_core.a');
if (!existsSync(archive)) throw new Error('HDC archive missing');
// 最后一行是调用方唯一消费的产物路径，其余编译输出由进程继承并前台展示。
console.log(archive);
