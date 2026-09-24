#!/usr/bin/env node
/**
 * 将私有开发工程的当前文件同步为公开快照。这里只读取 Git 已跟踪文件和明确的
 * 业务目录中的未忽略文件，不遍历缓存、凭据、设备证据或第三方工作树。
 * 公开说明、许可证及经过公开化的说明文件由本仓维护，不被开发仓覆盖。
 * 用法：node tools/sync-source-snapshot.mjs --source <MyApplication> [--write]
 * 默认只报告差异；--write 写入文件但不删除目标文件，不提交也不推送仓库。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const publicRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const destination = path.join(publicRoot, 'MyApplication');
const args = process.argv.slice(2);
const sourceIndex = args.indexOf('--source');
if (sourceIndex < 0 || !args[sourceIndex + 1]) throw new Error('--source <MyApplication> is required');
const source = fs.realpathSync(args[sourceIndex + 1]);
if (source === fs.realpathSync(destination)) throw new Error('Source and destination must differ');
const write = args.includes('--write');
const folders = new Set(['account', 'AppScope', 'commons', 'config', 'docker', 'entry',
  'feature_core', 'feature_system', 'gamecontrol', 'hvigor', 'JavaApp', 'launch',
  'mods', 'prebuilt', 'scripts', 'tests', 'tools', 'update']);
const rootFiles = new Set(['.gitattributes', '.clang-tidy', 'amcl-build-menu.bat',
  'build-app.ps1', 'build-hap.ps1', 'code-linter.json5', 'deps.lock', 'deps.versions',
  'hvigorfile.ts', 'oh-package.json5', 'oh-package-lock.json5', 'setup_deps.sh', 'toolchain.lock']);
const preserved = new Set(['scripts/run-host-tests-docker.sh']);
// 已确认由 Hvigor 根据本次产品重新生成的旧快照输入，只解除清单管理；保留本地文件。
const generated = new Set(['entry/src/main/resources/rawfile/graphics-manifest.json']);

/** 只允许源码、构建配置和现役补丁；历史归档和开发环境输出没有发布用途。 */
function selected(relative) {
  if (!folders.has(relative.split('/')[0]) && !rootFiles.has(relative)) return false;
  if (generated.has(relative)) return false;
  if (preserved.has(relative) || /(?:^|\/)(?:README[^/]*|AGENTS\.md)$/i.test(relative)) return false;
  if (/(?:^|\/)(?:build|out|__pycache__|node_modules|oh_modules|\.secrets|\.git)(?:\/|$)/.test(relative)) return false;
  if (/\/(?:fork-archive|integration-archive|archive-plan-a)\//.test(relative)) return false;
  if (/\.(?:p12|p7b|jks|keystore|key|cer|csr|hap|app|log|obj|pyc)$/i.test(relative)) return false;
  return true;
}
const git = (...gitArgs) => execFileSync('git', ['-C', source, ...gitArgs], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
// 主工程将 MobileGL dist 视作本机输出；公开快照需要一并交付被 deps.lock 严格
// 锁定的这三个输入，否则换目录重编产生不同字节时连普通 HAP 都无法准备。
const lockedBinaryInputs = ['prebuilt/mobilegl/dist/libmobilegl.so',
  'prebuilt/mobilegl/dist/libmobilegl.unstripped.so', 'prebuilt/mobilegl/dist/build-provenance.json'];
// 复用主工程现有产物门禁，确认来源与锁哈希后才能发布，拒绝复制任意同名库。
execFileSync(process.execPath, ['--input-type=module', '-e',
  "import {verifyDist} from './scripts/check-mobilegl-build-contract.mjs'; verifyDist();"], { cwd: source, stdio: 'inherit' });
const candidates = [...new Set([...git('ls-files', '-z', '--cached', '--others', '--exclude-standard').split('\0'),
  ...lockedBinaryInputs])].filter(Boolean).sort();
const copied = [], changed = [], exported = [];
for (const relative of candidates) {
  if (!selected(relative)) continue;
  const input = path.join(source, relative);
  if (!fs.existsSync(input) || !fs.lstatSync(input).isFile()) continue;
  const output = path.join(destination, relative);
  const bytes = fs.readFileSync(input);
  exported.push(relative);
  if (!fs.existsSync(output) || !bytes.equals(fs.readFileSync(output))) {
    (fs.existsSync(output) ? changed : copied).push(relative);
    if (write) {
      fs.mkdirSync(path.dirname(output), { recursive: true });
      fs.writeFileSync(output, bytes);
    }
  }
}
// 上次管理过的源码若已删除，不能在目标静默残留并被 CMake/ArkTS 再次编译。
// 只报告这些精确路径；删除需要维护者核对，因此同步不会自动清理用户文件。
const manifestPath = path.join(destination, 'SOURCE_SNAPSHOT.json');
const previous = fs.existsSync(manifestPath) ? JSON.parse(fs.readFileSync(manifestPath, 'utf8')) : null;
const stale = (previous?.entries ?? []).map(entry => entry.path)
  .filter(relative => !generated.has(relative) && !exported.includes(relative) && fs.existsSync(path.join(destination, relative)));
if (stale.length) throw new Error(`Stale snapshot files require explicit review before synchronization: ${stale.join(', ')}`);

const dependencyWorktrees = [];
for (const relative of ['prebuilt/lwjgl3/lwjgl3_src', 'prebuilt/mobileglues/mg_src', 'prebuilt/mobilegl/src']) {
  const dependency = path.join(source, relative);
  const depGit = (...params) => execFileSync('git', ['-C', dependency, ...params], { maxBuffer: 16 * 1024 * 1024 });
  const baseCommit = depGit('rev-parse', 'HEAD').toString('utf8').trim();
  // 未跟踪第三方文件可能是新增源码，也可能是私有实验，不能自动公开或默默丢失。
  if (depGit('ls-files', '--others', '--exclude-standard', '-z').length) {
    throw new Error(`Untracked dependency files need review before snapshot export: ${relative}`);
  }
  const patch = depGit('diff', '--binary', 'HEAD', '--');
  if (/^\+Subproject commit .*dirty$/m.test(patch.toString('utf8'))) {
    throw new Error(`Nested dependency changes need a committed/published pin: ${relative}`);
  }
  const record = { path: relative, baseCommit, dirty: patch.length > 0 };
  const patchPath = path.posix.join(path.posix.dirname(relative), 'local-worktree.patch');
  const output = path.join(destination, patchPath);
  if (patch.length) {
    record.patch = patchPath;
    record.patchSha256 = createHash('sha256').update(patch).digest('hex');
    if (!fs.existsSync(output) || !patch.equals(fs.readFileSync(output))) {
      (fs.existsSync(output) ? changed : copied).push(patchPath);
      if (write) fs.writeFileSync(output, patch);
    }
  } else if (exported.includes(patchPath)) {
    // 工作树已恢复为干净子模块时，源仓正式跟踪的适配补丁仍是需要发布的输入。
    // 它与“刚从脏依赖导出的差异”分开标记，不能因子模块干净就误删历史适配。
    record.patch = patchPath;
    record.patchOrigin = 'tracked-source';
    record.patchSha256 = createHash('sha256').update(fs.readFileSync(path.join(source, patchPath))).digest('hex');
  } else if (fs.existsSync(output)) {
    throw new Error(`Obsolete dependency patch needs review: ${patchPath}`);
  }
  dependencyWorktrees.push(record);
}
// 默认输入产品需要既有 Gate 0 记录才能配置 CMake。公开副本仅脱敏设备序号，
// 保留原批准值、批准日期和未闭合缺口，不把原有风险接受改写成新验收结论。
// 在改写前验证原文的已锁定哈希；另记公开副本哈希，保证二者来源可区分。
const sourceGate = fs.readFileSync(path.join(source, 'gate0-evidence.lock'));
const gate = JSON.parse(sourceGate.toString('utf8'));
const serials = Object.values(gate.capabilities).flatMap(capability => capability.deviceMatrix ?? [])
  .flatMap(device => [...device.matchAll(/\b[A-Z0-9]{12,20}\b/g)].map(match => match[0]));
const redact = text => serials.reduce((result, serial, index) => result.split(serial).join(`REDACTED-DEVICE-${index + 1}`), text);
const publicEvidence = [];
const derived = [];
for (const [name, capability] of Object.entries(gate.capabilities)) {
  if (!capability.approved) continue;
  const relative = capability.evidenceDocument;
  if (relative !== 'docs/testing/gate0-raw-relative-evidence.md') throw new Error(`Review newly required public evidence before export: ${relative}`);
  const original = fs.readFileSync(path.join(source, relative));
  const originalSha = createHash('sha256').update(original).digest('hex');
  if (originalSha !== capability.evidenceSha256) throw new Error(`Original Gate 0 evidence drift: ${name}`);
  const header = `> 公开快照脱敏副本：原文 SHA-256 为 \`${originalSha}\`。仅替换设备序号；原批准条件、已知缺口和风险接受事实均保留。本副本不构成新的设备验收。\n\n`;
  const content = Buffer.from(header + redact(original.toString('utf8')).replace(/\r\n/g, '\n'));
  capability.sourceEvidenceSha256 = originalSha;
  capability.evidenceSha256 = createHash('sha256').update(content).digest('hex');
  derived.push([relative, content]);
  publicEvidence.push({ path: relative, originalSha256: originalSha, publicSha256: capability.evidenceSha256 });
}
gate.publicSnapshotNote = 'Device serials are redacted. Original approvals, dates and known evidence gaps are unchanged. See sourceEvidenceSha256 for the original document identity.';
derived.push(['gate0-evidence.lock', Buffer.from(redact(JSON.stringify(gate, null, 2)) + '\n')]);
for (const [relative, content] of derived) {
  const output = path.join(destination, relative);
  if (!fs.existsSync(output) || !content.equals(fs.readFileSync(output))) {
    (fs.existsSync(output) ? changed : copied).push(relative);
    if (write) {
      fs.mkdirSync(path.dirname(output), { recursive: true });
      fs.writeFileSync(output, content);
    }
  }
}
// 清单记录的是当前工作树，不能将未提交修改冒充成 sourceCommit 的内容。
// 文本哈希统一 LF，使 Git for Windows 的 autocrlf 不会造成内容一致却校验失败。
if (write) {
  // 子模块中的未提交 C/C++ 适配不能隐式消失，也不能伪装成上游锁提交。
  // 单独导出可审阅补丁，并在清单标明基线；普通 HAP 仍消费已锁定的 native 制品。
  const entries = exported.map(relative => {
    const bytes = fs.readFileSync(path.join(destination, relative));
    // 按内容识别 UTF-8 文本，覆盖 .version、SVG、PEM、Dockerfile 等无固定后缀输入。
    // NUL 或非法 UTF-8 均视为二进制，避免宽松解码替换字节后丢失完整性信息。
    let text = !bytes.includes(0);
    try { new TextDecoder('utf-8', { fatal: true }).decode(bytes); } catch { text = false; }
    const content = text ? Buffer.from(bytes.toString('utf8').replace(/\r\n/g, '\n')) : bytes;
    return { path: relative, sha256: createHash('sha256').update(content).digest('hex'), normalization: text ? 'lf' : 'none' };
  });
  const manifest = {
    schema: 1,
    sourceCommit: git('rev-parse', 'HEAD').trim(),
    sourceBranch: git('branch', '--show-current').trim(),
    sourceDirty: git('status', '--porcelain', '--untracked-files=normal').trim().length > 0,
    note: 'Current working-tree snapshot; sourceCommit is its base, not an assertion of identical committed content. Public docs, licenses and bootstrap tools are maintained separately.',
    dependencyWorktrees,
    lockedBinaryInputs,
    publicEvidence,
    publicEvidenceLockSha256: createHash('sha256').update(derived.at(-1)[1]).digest('hex'),
    entries,
  };
  fs.writeFileSync(path.join(destination, 'SOURCE_SNAPSHOT.json'), JSON.stringify(manifest, null, 2) + '\n');
}
console.log(JSON.stringify({ mode: write ? 'write' : 'check', exported: exported.length, added: copied, changed }, null, 2));
if (!write && (copied.length || changed.length)) process.exitCode = 1;
