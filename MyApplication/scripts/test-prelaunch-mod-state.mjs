/**
 * 启动前模组文件事务回归：直接执行生产 PreLaunchValidator、目录锁与事务恢复，
 * 以及 Sheet 的 input/setCheck/setRunning/runAll 方法。只替换 HarmonyOS 文件系统、
 * 日志和其他基础校验边界，不复制模组恢复或启动编排算法，不需要游戏或用户模组。
 *
 * 内存文件系统模拟中断安装的 journal/backup；所有输入均在宿主内存，不改用户目录。
 * 这项验证不等同于 ArkUI 布局或 HarmonyOS 真机启动验收。
 */
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { loader, productionPathPolicy, root, ts } from './mod-install-test-runtime.mjs';

const files = new Map();
const directories = new Set(['/virtual', '/virtual/game', '/virtual/game/mods']);
const descriptors = new Map();
const operations = [];
const logEntries = [];
const results = [];
let nextFd = 1;
let cleanupBlocked = false;
const dir = '/virtual/game/mods';
const journalPath = dir + '/.amcl-mod-transaction.json';
const staging = '/virtual/game/.amcl-mod-install-fixture';
const sha1 = bytes => crypto.createHash('sha1').update(bytes).digest('hex');
const put = (name, bytes) => files.set(name, Buffer.from(bytes));

/** 只允许恢复模块需要的文件操作；若预检读取任意模组正文，断言立即失败。 */
const io = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
  lstatSync(name) {
    operations.push(['stat', name]);
    if (!files.has(name) && !directories.has(name)) throw new Error('ENOENT ' + name);
    return { isDirectory: () => directories.has(name), isFile: () => files.has(name), isSymbolicLink: () => false };
  },
  readTextSync(name) {
    operations.push(['read', name]);
    assert.equal(name, journalPath, '启动前只能读取安装恢复记录，不能解析 JAR 元数据');
    return files.get(name).toString();
  },
  openSync(name) {
    operations.push(['write', name]);
    put(name, '');
    const fd = nextFd++;
    descriptors.set(fd, name);
    return { fd };
  },
  writeSync(fd, text) { put(descriptors.get(fd), text); },
  fsyncSync() {},
  closeSync(file) { descriptors.delete(file.fd); },
  renameSync(from, to) {
    if (!files.has(from)) throw new Error('ENOENT ' + from);
    operations.push(['rename', from, to]);
    files.set(to, files.get(from));
    files.delete(from);
  },
  unlinkSync(name) { operations.push(['unlink', name]); files.delete(name); },
};

/** 终态清理可故障注入，验证“恢复完成但清理待重试”仍按生产事务语义放行。 */
function removeDirectory(name) {
  if (cleanupBlocked) return;
  for (const file of files.keys()) if (file === name || file.startsWith(name + '/')) files.delete(file);
  for (const directory of directories) if (directory === name || directory.startsWith(name + '/')) directories.delete(directory);
}

const transaction = loader({
  '@kit.CoreFileKit': { fileIo: io },
  feature_core: { ...productionPathPolicy(), computeFileSha1: async name => sha1(files.get(name)) },
  commons: { removeDirRecursive: removeDirectory, AppLogger: { warn() {} }, LOG_DOMAIN_DOWNLOAD: 0 },
})('mods/src/main/ets/ModInstallTransaction.ets');

let semanticCalls = 0;
const forbiddenSemanticCheck = () => {
  semanticCalls++;
  throw new Error('启动链不得再调用模组环境解析或兼容性扫描');
};
const preLaunch = loader({
  '@kit.CoreFileKit': { fileIo: {} },
  '@kit.PerformanceAnalysisKit': { hilog: {} },
  './LaunchNativeBridge': {}, './LaunchProfileBuilder': {},
  './LwjglSlotIntegrity': {}, './RuntimeSlotGenerations': {},
  './GraphicsGameFacts': {}, './LaunchContractPreflight': {}, './LaunchJdkPolicy': {},
  feature_core: {},
  mods: { ...transaction, installedModEnvironment: forbiddenSemanticCheck, inspectInstalledModSet: forbiddenSemanticCheck },
})('launch/src/main/ets/PreLaunchValidator.ets').PreLaunchValidator;

const input = { gameDir: '/virtual/game', filesDir: '/app', mcDir: '/mc', version: 'custom-pack', jdkVersion: '17', xmxMb: 2048 };

/** 复位可变夹具；生产目录锁自行在 finally 释放，不通过测试清空其内部状态。 */
function reset() {
  files.clear();
  directories.clear();
  for (const name of ['/virtual', '/virtual/game', dir]) directories.add(name);
  operations.length = 0;
  logEntries.length = 0;
  cleanupBlocked = false;
}

/** 建立真实事务格式的中断提交：新文件已提升，旧文件仍留在 backup，尚未写 committed。 */
function interruptedInstall(committed = false) {
  directories.add(staging);
  directories.add(staging + '/download');
  directories.add(staging + '/backup');
  put(dir + '/example.jar', 'new mod bytes');
  put(staging + '/backup/0-example.jar', 'old mod bytes');
  put(journalPath, JSON.stringify({
    schema: 1, stagingName: '.amcl-mod-install-fixture', committed,
    changes: [{ newName: 'example.jar', oldNames: ['example.jar'], stagedRelative: 'download/example.jar', sha1: sha1('new mod bytes') }],
    backups: [{ name: 'example.jar', saved: 'backup/0-example.jar' }],
  }));
}

/** 生产函数结果统一校验稳定身份；只有具体文件事务错误能够得到 fail。 */
async function checkState(name, expected, value = input) {
  const result = await preLaunch.runModInstallState(value);
  assert.equal(result.id, 'mod_install_state');
  assert.equal(result.title, '模组安装状态');
  assert.equal(result.status, expected);
  assert.equal(result.fixActionKey, '');
  assert.equal(semanticCalls, 0);
  results.push({ name, status: result.status });
  return result;
}

reset();
assert.equal(typeof preLaunch.runMods, 'undefined', '旧的强制语义检查入口必须移除');
assert.deepEqual(Array.from(preLaunch.pendingChecks(), value => value.id), ['jit', 'jdk', 'runtime', 'files', 'contract', 'assets', 'mod_install_state']);
put(dir + '/unparseable.jar', 'not a supported metadata document');
// mcDir/version/jdkVersion 仅语义解析需要；访问即抛错，保证这条生产路径只依赖 gameDir。
const environmentUnavailable = { gameDir: input.gameDir };
for (const key of ['mcDir', 'version', 'jdkVersion']) {
  Object.defineProperty(environmentUnavailable, key, { get: forbiddenSemanticCheck });
}
await checkState('无法解析的已有模组及不可读环境不阻止启动', 'pass', environmentUnavailable);
assert.deepEqual(operations, [['stat', journalPath]], '无恢复记录时不扫描、不读写任何模组');

reset();
directories.delete(dir);
await checkState('原版没有 mods 目录时不创建目录或触发扫描', 'pass');
assert.equal(directories.has(dir), false);

reset();
let releaseInstall;
const installWait = new Promise(resolve => { releaseInstall = resolve; });
const activeInstall = transaction.withModDirectoryLock(dir, async () => installWait);
try {
  const activeResult = await checkState('活动安装必须拒启且规范化路径不能绕过锁', 'fail', { ...input, gameDir: '/virtual//game/' });
  assert.match(activeResult.detail, /正在安装或更新/);
  assert.equal(operations.length, 0, '安装进行中不能提前恢复同一事务');
} finally {
  releaseInstall();
  await activeInstall;
}
await checkState('安装结束释放目录锁后可重试启动', 'pass');

for (const version of ['custom-pack', 'vanilla']) {
  reset();
  interruptedInstall();
  await checkState(version + ' 使用相同真实恢复函数还原中断安装', 'pass', { ...input, version });
  assert.equal(files.get(dir + '/example.jar').toString(), 'old mod bytes');
  assert.equal(files.has(journalPath), false);
  assert.equal(transaction.modInstallationActive(dir), false);
}

reset();
interruptedInstall();
put(dir + '/example.jar', 'user changed these bytes after interruption');
const recoveryFailed = await checkState('恢复失败保留用户文件、备份和 journal 并拒启', 'fail');
assert.match(recoveryFailed.detail, /模组恢复尚未完成/);
assert.match(recoveryFailed.detail, /文件在提交后被修改/);
assert.equal(files.get(dir + '/example.jar').toString(), 'user changed these bytes after interruption');
assert.equal(files.get(staging + '/backup/0-example.jar').toString(), 'old mod bytes');
assert.equal(files.has(journalPath), true);
assert.equal(transaction.modInstallationActive(dir), false, '恢复异常也必须释放目录锁');

reset();
put(journalPath, '{corrupt journal');
const malformed = await checkState('损坏恢复记录必须拒启并保留原始证据', 'fail');
assert.ok(malformed.detail.length > 0);
assert.equal(files.get(journalPath).toString(), '{corrupt journal');

reset();
interruptedInstall(true);
cleanupBlocked = true;
await checkState('提交已完成且只有暂存清理失败时允许启动', 'pass');
assert.equal(files.get(dir + '/example.jar').toString(), 'new mod bytes');
assert.equal(files.has(journalPath), true);

/**
 * 只抽取生产 Sheet 中不含 ArkUI DSL 的四个方法。方法正文由 TypeScript AST 获取，
 * 缺失即失败，避免测试复制一份过时编排。UI 元素渲染不由 Node 解释。
 */
const sheetPath = path.join(root, 'entry/src/main/ets/components/PreLaunchCheckSheet.ets');
const sheetText = fs.readFileSync(sheetPath, 'utf8');
const sheetPrefix = sheetText.slice(0, sheetText.indexOf('  private firstFailed()')).replace('export struct PreLaunchCheckSheet', 'export class PreLaunchCheckSheet') + '\n}';
const syntaxTree = ts.createSourceFile(sheetPath, sheetPrefix, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
const sheetClass = syntaxTree.statements.find(node => ts.isClassDeclaration(node) && node.name?.text === 'PreLaunchCheckSheet');
const methodNames = ['input', 'setCheck', 'setRunning', 'runAll'];
const methods = methodNames.map(name => {
  const method = sheetClass.members.find(node => ts.isMethodDeclaration(node) && node.name.getText(syntaxTree) === name);
  assert.ok(method, '生产 Sheet 方法缺失：' + name);
  return method.getText(syntaxTree);
});
const output = ts.transpileModule('export class SheetHarness {\n' + methods.join('\n') + '\n}', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true,
});
assert.equal((output.diagnostics ?? []).filter(diagnostic => diagnostic.category === ts.DiagnosticCategory.Error).length, 0);

const check = (id, status = 'pass') => ({ id, title: id, status, detail: id + ':' + status, fixActionKey: '' });
let statuses = {};
let stageCalls = [];
let afterInstallState;
const sheetValidator = {
  pendingChecks: () => preLaunch.pendingChecks(),
  runJit() { stageCalls.push('jit'); return check('jit', statuses.jit); },
  runJdk() { stageCalls.push('jdk'); return check('jdk', statuses.jdk); },
  async runRuntime() { stageCalls.push('runtime'); return check('runtime', statuses.runtime); },
  async runProfileChecks() { stageCalls.push('profile'); return { files: check('files', statuses.files), contract: check('contract', statuses.contract) }; },
  runAssets() { stageCalls.push('assets'); return check('assets', statuses.assets); },
  async runModInstallState(value) {
    stageCalls.push('mod_install_state');
    const result = await preLaunch.runModInstallState(value);
    if (afterInstallState) afterInstallState();
    return result;
  },
};
const module = { exports: {} };
vm.runInNewContext(output.outputText, {
  module, exports: module.exports, PreLaunchValidator: sheetValidator, LOG_DOMAIN_LAUNCH: 1,
  AppLogger: { error: (...args) => logEntries.push(['error', ...args]), flush: () => logEntries.push(['flush']) },
}, { filename: sheetPath });

/** 每次使用全新的组件状态；sleep 只取消展示延迟，不改变 await 边界和销毁检查。 */
async function runSheet(name, expectedPhase, expectedProceed, options = {}) {
  const sheet = new module.exports.SheetHarness();
  let proceeded = 0;
  stageCalls = [];
  statuses = options.statuses ?? {};
  afterInstallState = options.abortAfterRecovery ? () => { sheet.aborted = true; } : undefined;
  Object.assign(sheet, input, { currentJdk: input.jdkVersion, aborted: false, jdkWarnAccepted: options.acceptJdkWarning ?? false,
    checks: [], sleep: async () => {}, jdkRange: {}, checkJdkInstalled: () => true, onProceed: () => { proceeded++; } });
  await sheet.runAll();
  assert.equal(sheet.phase, expectedPhase);
  assert.equal(proceeded, expectedProceed);
  assert.equal(semanticCalls, 0);
  results.push({ name, phase: sheet.phase, proceeded, stages: [...stageCalls] });
  return sheet;
}

reset();
put(dir + '/unknown-metadata.jar', 'unsupported by the removed checker');
await runSheet('Sheet 已有模组直接交给真实加载器启动', 'passed', 1);
assert.deepEqual(stageCalls, ['jit', 'jdk', 'runtime', 'profile', 'assets', 'mod_install_state']);

reset();
interruptedInstall();
// 恢复前修改文件，模拟真实回滚拒绝覆盖用户修改。
put(dir + '/example.jar', 'changed');
const sheetFailed = await runSheet('Sheet 恢复失败完整显示并记录且不调用 onProceed', 'failed', 0);
assert.equal(sheetFailed.checks[6].status, 'fail');
const logged = logEntries.find(entry => entry[0] === 'error');
assert.ok(logged[2].includes(sheetFailed.checks[6].detail), '完整恢复失败原因必须写入日志');
assert.deepEqual(logEntries.at(-1), ['flush']);

reset();
const multiline = Array.from({ length: 12 }, (_, index) => '恢复失败文件 ' + index).join('\n');
sheetFailed.setCheck(6, { ...check('mod_install_state', 'fail'), detail: multiline });
assert.ok(logEntries[0][2].endsWith(multiline), '长诊断内容不能被截断后再写入日志');
assert.doesNotMatch(sheetText.match(/Text\(c\.detail\)[\s\S]*?\n      }/)[0], /maxLines|textOverflow/, '滚动区域必须完整显示失败详情');

reset();
const sheetInstallWait = new Promise(resolve => { releaseInstall = resolve; });
const sheetActiveInstall = transaction.withModDirectoryLock(dir, async () => sheetInstallWait);
try {
  await runSheet('Sheet 活动安装不能派发游戏或恢复同一事务', 'failed', 0);
  assert.equal(operations.length, 0);
} finally {
  releaseInstall();
  await sheetActiveInstall;
}

for (const id of ['jit', 'jdk', 'runtime', 'files', 'contract', 'assets']) {
  reset();
  await runSheet('Sheet 保留基础失败阻断：' + id, 'failed', 0, { statuses: { [id]: 'fail' } });
  assert.equal(stageCalls.includes('mod_install_state'), false, '基础失败不能继续恢复或派发游戏');
}
reset();
await runSheet('Sheet 未接受 JDK 警告时继续等待用户', 'jdkWarn', 0, { statuses: { jdk: 'warn' } });
await runSheet('Sheet 已接受 JDK 警告及未知世代警告仍能继续', 'passed', 1, { statuses: { jdk: 'warn', contract: 'warn' }, acceptJdkWarning: true });
await runSheet('Sheet 恢复结束时已关闭不能派发游戏', 'running', 0, { abortAfterRecovery: true });

console.log(JSON.stringify({ test: 'prelaunch-mod-install-state', total: results.length, semanticCalls, results }, null, 2));
