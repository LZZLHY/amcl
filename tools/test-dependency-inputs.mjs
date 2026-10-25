#!/usr/bin/env node
/**
 * 第三方身份汇总回归：用小型输入证明 pin、补丁顺序、旧包边界、无代码执行及稳定输出。
 * CLI 测试使用本轮亲建的真实 Git 小仓；成功后保存一份小收据并回收夹具，失败保留。
 * 工作区运行必须显式给 AMCL_RUN_DIR，独立公开克隆和 CI 可使用仓库外系统临时目录。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { collectDependencyInputs, isDependencyMetadata } from './dependency-inputs.mjs';

const sourceCommit = 'a'.repeat(40), commit = 'b'.repeat(40), checksum = 'c'.repeat(64);
const asBuffer = value => Buffer.from(typeof value === 'string' ? value : JSON.stringify(value));
const files = new Map();
const add = (relative, value) => files.set(relative, asBuffer(value));
const dependencies = ['prebuilt/mobilegl/src', 'prebuilt/mobileglues/mg_src',
  'prebuilt/lwjgl3/lwjgl3_src', 'prebuilt/hdc/muka-rust-hdc'].map((relative, index) => ({ path: relative, baseCommit: String(index + 1).repeat(40), dirty: false }));

add('deps.lock', `[mobilegl]\nrepo = https://github.com/example/graphics.git\ncommit = ${dependencies[0].baseCommit}\nlib_sha256 = ${checksum} # declared native input\n[openjdk]\ncommit = PENDING # historical lock is incomplete\n[quoted]\nurl = "https://example.invalid/source#fragment"\n`);
add('.gitmodules', dependencies.map(item => `[submodule "MyApplication/${item.path}"]\npath = MyApplication/${item.path}\nurl = https://github.com/example/${path.posix.basename(item.path)}.git\n`).join(''));
add('prebuilt/jdk/build-inputs.json', { schema: 1, runtimes: Object.fromEntries(['8', '17', '21', '25'].map(major => [major, { repository: `https://github.com/openjdk/jdk${major}u.git`, commit }])) });
add('prebuilt/jdk/source-provenance.json', { schemaVersion: 1, description: 'Historical mixed runtime inputs remain independent', evidence: 'PRIVATE-HISTORY-NOT-FOR-REPORT', runtimes: [{ major: 17, wholeRuntimeSourceCommit: null }] });
add('prebuilt/sample/patches/series', '# exact order\n0002-second.patch\n0001-first.patch # despite numeric prefix\n');
add('prebuilt/sample/patches/0001-first.patch', 'first patch\n');
add('prebuilt/sample/patches/0002-second.patch', 'second patch\n');
add('prebuilt/signer/pin.json', { revision: commit, sha256: checksum, license: 'Apache-2.0', url: `https://example.invalid/${commit}/tool.jar` });
add('prebuilt/runtime-compat/lib/sources.json', { files: [{ file: 'helper.jar', url: 'https://example.invalid/helper.jar', sha256: checksum, size: 123 }] });
add('oh-package-lock.json5', `// parsed as data\n{ "lockfileVersion":3, "packages": {"@example/a@1": {"name":"@example/a", "version":"1", "resolved":"https://example.invalid/a.har", "integrity":"sha512-AAAA",},},}`);
add('entry/src/main/cpp/hdc/core/Cargo.lock', `version = 4\n[[package]]\nname = "sample"\nversion = "1.2.3"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\nchecksum = "${checksum}"\n[[package]]\nname = "local"\nversion = "0.1.0"\n`);
add('toolchain.lock', { schemaVersion: 2, products: { default: { compileSdkVersion: '26.0.0.105', compiler: { sha256: checksum } } } });
// 源文件 Map 可以包括非元数据；汇总不会读取或执行这里的脚本。
add('scripts/unused.mjs', 'throw new Error("MUST NOT EXECUTE");');

const report = collectDependencyInputs({ files, dependencyWorktrees: dependencies, sourceCommit });
const component = id => report.components.find(item => item.id === id);
assert.equal(report.schemaVersion, 1);
assert.equal(report.sourceCommit, sourceCommit);
assert.equal(report.components.filter(item => item.kind === 'gitlink').length, 4);
assert.deepEqual(report.components.filter(item => item.kind === 'jdk-build-input').map(item => item.id).sort(), ['jdk:17', 'jdk:21', 'jdk:25', 'jdk:8']);
assert.equal(component('deps-lock:quoted').declared.url, 'https://example.invalid/source#fragment');
assert.equal(component('jdk:17').scope, 'new-runtime-build-input-only');
assert.equal(component('jdk:17').historicalReleaseMapping, 'not-proven-by-build-pin');
assert(report.limitations.some(item => item.component === 'deps-lock:openjdk' && item.code === 'unresolved-declaration'));
assert(report.limitations.some(item => item.code === 'historical-runtime-boundary'));
assert(!JSON.stringify(report).includes('PRIVATE-HISTORY-NOT-FOR-REPORT'));
assert.equal(report.qualification.allThirdPartySourceRebuild, 'not-performed');
assert.equal(report.qualification.applicationBuild, 'not-performed');
assert.deepEqual(component('metadata:prebuilt/sample/patches/series').steps.map(item => item.path),
  ['prebuilt/sample/patches/0002-second.patch', 'prebuilt/sample/patches/0001-first.patch']);
assert.equal(component('metadata:prebuilt/sample/patches/series').steps[0].sha256,
  createHash('sha256').update(files.get('prebuilt/sample/patches/0002-second.patch')).digest('hex'));
assert.equal(component('metadata:entry/src/main/cpp/hdc/core/Cargo.lock').packages.find(item => item.name === 'sample').identity, 'registry-checksum');
assert.equal(component('metadata:entry/src/main/cpp/hdc/core/Cargo.lock').packages.find(item => item.name === 'local').identity, 'workspace-or-path');
assert.equal(component('metadata:oh-package-lock.json5').packages[0].resolved, 'https://example.invalid/a.har');
assert.equal(component('metadata:prebuilt/signer/pin.json').declarations.sha256, checksum);
assert.deepEqual(collectDependencyInputs({ files: new Map([...files].reverse()), dependencyWorktrees: [...dependencies].reverse(), sourceCommit }), report);

// 缺失材料只提供可定位限制，不把缺少的补丁或源码地址补成猜测值。
const incomplete = new Map(files);
incomplete.delete('prebuilt/sample/patches/0002-second.patch');
incomplete.delete('.gitmodules');
const partial = collectDependencyInputs({ files: incomplete, dependencyWorktrees: dependencies });
assert(partial.limitations.some(item => item.code === 'missing-patch'));
assert(partial.limitations.some(item => item.code === 'missing-source-url'));
assert(partial.limitations.some(item => item.code === 'missing-source-commit'));
assert.equal(partial.sourceCommit, null);

// 补丁声明有摘要时核对实际原字节；漂移保持显式，而非覆盖原声明。
const patched = [{ ...dependencies[0], patch: 'prebuilt/sample/patches/0001-first.patch', patchSha256: '0'.repeat(64) }];
assert(collectDependencyInputs({ files, dependencyWorktrees: patched, sourceCommit }).limitations.some(item => item.code === 'missing-or-drifted-patch'));
assert.throws(() => collectDependencyInputs({ files, sourceCommit: 'main' }), /complete immutable commit/);
assert.throws(() => collectDependencyInputs({ files: new Map([['../private.json', Buffer.from('{}')]]) }), /Invalid application-relative/);
assert.throws(() => collectDependencyInputs({ files: new Map([['deps.lock', Buffer.from('[a]\ncommit = one\ncommit = two')]]) }), /Duplicate field/);
assert.throws(() => collectDependencyInputs({ files: new Map([['prebuilt/sample/patches/series', Buffer.from('../outside.patch')]]) }), /Invalid application-relative/);
assert.throws(() => collectDependencyInputs({ files: new Map([['oh-package-lock.json5', Buffer.from('{"packages": (() => { globalThis.__dependencyInputExecuted = true; })()}')]]) }), /Invalid JSON metadata/);
assert.equal(globalThis.__dependencyInputExecuted, undefined);
assert(isDependencyMetadata('entry/src/main/cpp/hdc/core/Cargo.lock'));
assert(isDependencyMetadata('prebuilt/signer/pin.json'));
assert(!isDependencyMetadata('build-dependencies.local.json'));
assert(!isDependencyMetadata('prebuilt/mobilegl/src/huge.c'));

const parent = process.env.AMCL_RUN_DIR || os.tmpdir();
fs.mkdirSync(parent, { recursive: true });
const fixture = fs.mkdtempSync(path.join(parent, 'dependency-inputs-test-'));
const repository = path.join(fixture, 'public');
const application = path.join(repository, 'MyApplication');
fs.mkdirSync(application, { recursive: true });
const script = fileURLToPath(new URL('./dependency-inputs.mjs', import.meta.url));

/** 仅运行真实 Git 和当前 Node；参数独立传递，失败保留本轮最小夹具。 */
function run(program, args, cwd = repository) {
  return spawnSync(program, args, { cwd, encoding: 'utf8' });
}
function git(...args) {
  const result = run('git', args);
  assert.equal(result.status, 0, result.stderr);
}
function cli(...args) { return run(process.execPath, [script, '--root', application, ...args]); }

git('init');
for (const [relative, bytes] of files) {
  const filename = path.join(application, relative);
  fs.mkdirSync(path.dirname(filename), { recursive: true });
  fs.writeFileSync(filename, bytes);
}
fs.writeFileSync(path.join(repository, '.gitmodules'), files.get('.gitmodules'));
fs.writeFileSync(path.join(application, 'SOURCE_SNAPSHOT.json'), JSON.stringify({ sourceCommit, dependencyWorktrees: dependencies }));
git('add', '.');
const output = path.join(fixture, 'report.json');
let result = cli('--json', '--out', output);
assert.equal(result.status, 0, result.stderr);
const cliReport = JSON.parse(result.stdout);
assert.deepEqual(cliReport, report);
assert.deepEqual(JSON.parse(fs.readFileSync(output, 'utf8')), report);
result = cli('--check', '--json');
assert.equal(result.status, 0, result.stderr);
assert.equal(JSON.parse(result.stdout).check, 'legacy-report-absent');
fs.writeFileSync(path.join(application, 'DEPENDENCY_INPUTS.json'), JSON.stringify(report));
assert.equal(JSON.parse(cli('--check', '--json').stdout).check, 'match');
fs.writeFileSync(path.join(application, 'DEPENDENCY_INPUTS.json'), JSON.stringify({ ...report, sourceCommit: 'd'.repeat(40) }));
result = cli('--check');
assert.equal(result.status, 1);
assert.match(result.stdout, /check=drift/);
result = cli('--out', path.join(repository, 'forbidden-report.json'));
assert.notEqual(result.status, 0);
assert.match(result.stderr, /outside the source repository/);
assert.equal(fs.existsSync(path.join(repository, 'forbidden-report.json')), false);
const redirected = path.join(fixture, 'redirected-output');
fs.symlinkSync(repository, redirected, process.platform === 'win32' ? 'junction' : 'dir');
result = cli('--out', path.join(redirected, 'must-not-create', 'report.json'));
assert.notEqual(result.status, 0);
assert.match(result.stderr, /resolves inside the source repository/);
assert.equal(fs.existsSync(path.join(repository, 'must-not-create')), false);

// 输出生命周期只回收亲建且已解析确认在本轮父目录下的夹具，成功收据留在夹具外。
const receipt = { test: 'dependency-inputs', result: 'passed', sourceCommit, completedAt: new Date().toISOString(),
  coverage: ['immutable pins', 'patch order', 'legacy boundary', 'stable output', 'data-only parsing', 'CLI and lifecycle'],
  qualification: 'metadata parsing and CLI only; no SDK, HAP, download, or third-party rebuild',
  fixtureRemoved: true };
const resolved = fs.realpathSync(fixture), allowedParent = fs.realpathSync(parent);
assert(resolved.startsWith(allowedParent + path.sep));
assert(path.basename(resolved).startsWith('dependency-inputs-test-'));
fs.writeFileSync(path.join(parent, 'dependency-inputs-test-receipt.json'), JSON.stringify(receipt, null, 2) + '\n');
fs.rmSync(resolved, { recursive: true });
console.log('PASS dependency inputs: immutable pins, patch order, PENDING/historical boundaries, stable output, data-only parsing and CLI lifecycle');
