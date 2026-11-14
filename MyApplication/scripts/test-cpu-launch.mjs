/** 执行生产 ArkTS 的采集与启动桥，只替换系统文件/设备边界，覆盖坏输入和协议所有权。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

let api = 26, model = 'KirinT92', modelReads = 0;
const device = { get sdkApiVersion() { return api; }, get chipType() { modelReads++; return model; }, abiList: 'arm64-v8a' };
const files = new Map([
  ['/sys/devices/system/cpu/online', '0-3,8-9'],
]);
for (const id of [0, 1, 2, 3, 8, 9]) {
  files.set(`/sys/devices/system/cpu/cpu${id}/topology/core_id`, String(Math.floor(id / 2)));
  files.set(`/sys/devices/system/cpu/cpu${id}/topology/physical_package_id`, '0');
}
const reads = [];
const load = makePureEtsLoader({
  '@ohos.deviceInfo': { default: device },
  '@kit.CoreFileKit': { fileIo: { readTextSync(path) {
    reads.push(path);
    if (!files.has(path)) throw new Error('EACCES');
    return files.get(path);
  } } },
});
const { collectHostCpuInfo, parseOnlineCpuIds } = load('commons/src/main/ets/common/device/HostCpuInfo.ets');
const { applyCpuCompatibility, cpuCompatibilityPath } = load('launch/src/main/ets/CpuCompatibility.ets');
for (const invalid of ['', '1-', '-1', '3-1', '0-1024', '0,0', '0-2,2', 'NaN', '65536', '1.5', '1, 2']) {
  assert.throws(() => parseOnlineCpuIds(invalid), /CPU/);
}
let cpu = collectHostCpuInfo();
assert.equal(cpu.model, 'KirinT92');
assert.deepEqual(cpu.logicalIds, [0, 1, 2, 3, 8, 9]);
assert.equal(cpu.physicalCount, 3); assert.equal(cpu.packageCount, 1);
assert.equal(cpu.topology, '0,0,0;1,0,0;2,1,0;3,1,0;8,4,0;9,4,0');
assert(reads.every(path => path === '/sys/devices/system/cpu/online' || /\/cpu\d+\/topology\//.test(path)));
// 拒绝某个精确文件后保留型号/逻辑数，整份物理拓扑都必须回到未知。
files.delete('/sys/devices/system/cpu/cpu8/topology/core_id');
cpu = collectHostCpuInfo();
assert.equal(cpu.topology, ''); assert.equal(cpu.physicalCount, 0); assert.equal(cpu.logicalIds.length, 6);
api = 20; const before = modelReads;
assert.equal(collectHostCpuInfo().model, ''); assert.equal(modelReads, before, 'API20 must not touch chipType');
api = 26; model = '';
assert.equal(collectHostCpuInfo().model, '');
files.delete('/sys/devices/system/cpu/online');
assert.equal(collectHostCpuInfo().logicalIds.length, 0, 'JVM fallback is chosen at premain, not fabricated by ArkTS');
model = 'KirinT92'; cpu = collectHostCpuInfo();
const original = ['-Xmx1024M', '-javaagent:/user/auth.jar=one'];
const args = applyCpuCompatibility(original, '/app', cpu);
assert.deepEqual(original, ['-Xmx1024M', '-javaagent:/user/auth.jar=one']);
assert(args.includes('-Damcl.cpu.model=KirinT92'));
assert(args.includes('-Damcl.cpu.online='));
assert.equal(args.filter(arg => arg.startsWith('-javaagent:/app/')).length, 1);
assert.equal(args.at(-1), '-javaagent:' + cpuCompatibilityPath('/app'));
for (const forbidden of ['-Damcl.cpu.model=fake', '-Damcl.cpu.schema=2', '-javaagent:/app/runtime-compat/amcl-cpu-agent-old.jar']) {
  assert.throws(() => applyCpuCompatibility([forbidden], '/app', cpu), /CPU/);
}
// 直接执行生产 builder 的 CPU 接线 try 块，覆盖真实预检的 activityId=0，避免复发账本身份错误。
const builderSource = fs.readFileSync(new URL('../launch/src/main/ets/LaunchProfileBuilder.ets', import.meta.url), 'utf8');
const ast = compiler.createSourceFile('LaunchProfileBuilder.ets', builderSource, compiler.ScriptTarget.Latest, true);
let wiring;
const visit = node => {
  if (node.kind === compiler.SyntaxKind.TryStatement && node.tryBlock.getText(ast).includes('applyCpuCompatibility(parsed.jvmArgs')) wiring = node.getText(ast);
  compiler.forEachChild(node, visit);
};
visit(ast); assert.ok(wiring, 'production CPU wiring must be found');
const code = compiler.transpileModule('function run(parsed) {' + wiring + '\nreturn parsed;}',
  {compilerOptions: {target: compiler.ScriptTarget.ES2020}}).outputText;
let ledgerWrites = 0;
const invoke = new Function('collectHostCpuInfo', 'applyCpuCompatibility', 'updateSessionEnvironment', 'sessionEnvironmentFact',
  code + '\nreturn run;')(collectHostCpuInfo, applyCpuCompatibility, () => {ledgerWrites++;}, (...values) => values);
for (const id of [0, 123]) {
  ledgerWrites = 0;
  const result = invoke.call({filesDir: '/app', alog: {id: () => id}, lastBuildError: ''}, {jvmArgs: []});
  assert(result.jvmArgs.some(arg => arg.startsWith('-javaagent:/app/')));
  assert.equal(ledgerWrites, id > 0 ? 1 : 0, 'preflight cannot write a non-existent session');
}
console.log('CPU_LAUNCH_PASS API20/26, exact sysfs reads, missing facts, argument ownership and agent delivery');
