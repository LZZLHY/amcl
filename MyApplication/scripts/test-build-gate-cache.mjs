/**
 * 通用 gate 缓存的真实子进程正负回归。夹具计数可区分重新执行与复用；故障注入
 * 验证实际 exit、超时、取消、输入漂移和损坏对象均无法冒充 PASS。所有现场外置保留。
 * 夹具 control 文件只用于人为故障注入，不示范生产 gate 省略动态输入的用法。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {createGateIdentity, runGate} from './lib/build-gate-cache.mjs';
import {assertExternalOutputPath, resolveWorkspacePath} from './lib/workspace-paths.mjs';

const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outputIndex = process.argv.indexOf('--out');
if (outputIndex >= 0 && !process.argv[outputIndex + 1]) throw new Error('Missing --out directory');
const defaultParent = outputIndex < 0 ? resolveWorkspacePath('run', 'gate-cache-regression') : null;
if (defaultParent) fs.mkdirSync(defaultParent, {recursive: true});
const output = assertExternalOutputPath(outputIndex < 0 ? fs.mkdtempSync(path.join(defaultParent, 'case-')) : path.resolve(process.argv[outputIndex + 1]));
if (outputIndex >= 0) {
  if (fs.existsSync(output)) throw new Error('Test evidence directory must be new');
  fs.mkdirSync(output, {recursive: true});
}
const cases = [];
const policy = {schema: 1, gates: [{id: 'fixture-static', script: 'gate.mjs', kind: 'static', deterministic: true, cachePolicy: 'pass',
  outputOnlyEnvironment: ['AMCL_RUN_DIR', 'TEMP', 'TMP']}]};
const fixtureSource = `import fs from 'node:fs';
if (process.env.AMCL_GATE_CACHE_UNDECLARED_SECRET) throw new Error('uncontrolled parent environment leaked');
const [counter, control, input, output] = process.argv.slice(2);
const state = JSON.parse(fs.readFileSync(control, 'utf8'));
const count = fs.existsSync(counter) ? Number(fs.readFileSync(counter, 'utf8')) : 0;
fs.writeFileSync(counter, String(count + 1));
if (state.mode === 'delay') await new Promise(resolve => setTimeout(resolve, 300));
if (state.mode === 'wait') await new Promise(resolve => setTimeout(resolve, 3000));
if (state.mode === 'drift') fs.appendFileSync(input, 'changed-during-execution');
fs.writeFileSync(output, 'stable output\\n');
if (state.mode !== 'empty') console.log('PASS real fixture');
if (state.mode === 'fail') process.exitCode = 13;
`;

/** 为各个故障场景创建独占源码、共享缓存和多轮执行证据，绝不碰工程或旧任务。 */
function fixture(name) {
  const root = path.join(output, name), source = path.join(root, 'source');
  fs.mkdirSync(path.join(source, 'headers', 'nested'), {recursive: true});
  const input = path.join(source, 'input.txt'), tool = path.join(source, 'extra-tool.bin');
  const counter = path.join(root, 'counter.txt'), control = path.join(root, 'control.json'), artifact = path.join(root, 'output.txt');
  fs.writeFileSync(path.join(source, 'gate.mjs'), fixtureSource);
  fs.writeFileSync(input, 'original source'); fs.writeFileSync(tool, 'tool-v1');
  fs.writeFileSync(path.join(source, 'headers', 'nested', 'contract.h'), 'header-v1');
  fs.writeFileSync(control, JSON.stringify({mode: 'pass'}));
  const spec = {schema: 1, gateId: 'fixture-static', kind: 'static', profile: 'quick', cwd: source,
    command: {executable: process.execPath, args: ['gate.mjs', counter, control, input, artifact]},
    inputs: {files: ['gate.mjs', 'input.txt'], directories: ['headers']}, tools: [tool], config: {feature: 1},
    environment: {AMCL_RUN_DIR: '{runRoot}', TEMP: '{runRoot}/temp', TMP: '{runRoot}/temp'},
    outputs: [artifact], timeoutMs: 5000, expectation: {stdoutIncludes: ['PASS real fixture']}};
  let serial = 0;
  const options = () => ({cacheRoot: path.join(root, 'cache'), runRoot: path.join(root, 'runs', String(++serial)), trustedPolicy: policy});
  return {root, source, input, tool, spec, options, artifact,
    mode: (value) => fs.writeFileSync(control, JSON.stringify({mode: value})),
    count: () => fs.existsSync(counter) ? Number(fs.readFileSync(counter, 'utf8')) : 0,
    run: (extra = {}, changedSpec = spec) => runGate(changedSpec, {...options(), ...extra})};
}

async function check(name, test) {
  const startedAt = new Date().toISOString();
  try {
    await test(); cases.push({name, state: 'PASS', startedAt, completedAt: new Date().toISOString()});
    console.log('PASS gate cache: ' + name);
  } catch (error) {
    cases.push({name, state: 'FAIL', startedAt, completedAt: new Date().toISOString(), error: error.stack});
    throw error;
  }
}

try {
  await check('exact PASS reuses original execution, controlled output routing stays per-run', async () => {
    const item = fixture('exact-hit');
    const first = await item.run(), second = await item.run();
    assert.equal(first.state, 'PASS'); assert.equal(second.state, 'REUSED_PASS'); assert.equal(item.count(), 1);
    assert.equal(second.originalExecution.startedAt, first.startedAt);
    assert.equal(second.originalExecution.completedAt, first.completedAt);
    assert.ok(second.reusedAt); assert.equal(second.beforeIdentity, second.afterIdentity);
    assert.ok(fs.existsSync(path.join(first.publishedObject, 'command.json')));
  });

  await check('raw bytes, directory members, tools, arguments, config and environment invalidate', async () => {
    const item = fixture('identity-closure');
    const identity = (spec = item.spec) => createGateIdentity(spec, {trustedPolicy: policy}).key;
    const initial = identity(), stamp = fs.statSync(item.input).mtime;
    fs.writeFileSync(item.input, 'different source'); fs.utimesSync(item.input, stamp, stamp);
    assert.notEqual(identity(), initial);
    fs.writeFileSync(item.input, 'original source'); assert.equal(identity(), initial);
    const header = path.join(item.source, 'headers', 'nested', 'contract.h');
    fs.unlinkSync(header); assert.notEqual(identity(), initial); fs.writeFileSync(header, 'header-v1');
    fs.mkdirSync(path.join(item.source, 'headers', 'empty')); assert.notEqual(identity(), initial);
    fs.rmdirSync(path.join(item.source, 'headers', 'empty')); assert.equal(identity(), initial);
    fs.writeFileSync(item.tool, 'tool-v2'); assert.notEqual(identity(), initial); fs.writeFileSync(item.tool, 'tool-v1');
    assert.notEqual(identity({...item.spec, config: {feature: 2}}), initial);
    assert.notEqual(identity({...item.spec, environment: {...item.spec.environment, PATH: 'different-search-path'}}), initial);
    assert.notEqual(identity({...item.spec, command: {...item.spec.command, args: [...item.spec.command.args, 'extra']}}), initial);
  });

  await check('undeclared paths and escaping links cannot be hashed as ordinary input', async () => {
    const item = fixture('path-boundaries');
    assert.throws(() => createGateIdentity({...item.spec, inputs: {files: ['../control.json']}}, {trustedPolicy: policy}), /escapes/);
    const outside = path.join(item.root, 'outside'); fs.mkdirSync(outside); fs.writeFileSync(path.join(outside, 'secret.txt'), 'do not follow');
    fs.symlinkSync(outside, path.join(item.source, 'headers', 'outside-link'), process.platform === 'win32' ? 'junction' : 'dir');
    assert.throws(() => createGateIdentity(item.spec, {trustedPolicy: policy}), /link/i);
  });

  await check('spec cannot self-authorize result reuse or spoof catalog script', async () => {
    const item = fixture('policy');
    const never = {schema: 1, gates: [{...policy.gates[0], cachePolicy: 'never'}]};
    assert.equal((await item.run({trustedPolicy: never})).state, 'PASS');
    assert.equal((await item.run({trustedPolicy: never})).state, 'PASS'); assert.equal(item.count(), 2);
    await assert.rejects(() => item.run({trustedPolicy: {schema: 1, gates: []}}), /absent/);
    assert.throws(() => createGateIdentity({...item.spec, command: {...item.spec.command, args: ['other.mjs', 'gate.mjs']}}, {trustedPolicy: policy}), /entry script/);
    assert.throws(() => createGateIdentity({...item.spec, environment: {PATH: '{runRoot}'}}, {trustedPolicy: policy}), /output-only/);
    assert.throws(() => createGateIdentity({...item.spec, kind: 'behavior'}, {trustedPolicy: policy}), /kind disagrees/);
  });

  await check('undeclared parent environment is not inherited by a trusted static checker', async () => {
    const item = fixture('controlled-environment');
    const original = process.env.AMCL_GATE_CACHE_UNDECLARED_SECRET;
    process.env.AMCL_GATE_CACHE_UNDECLARED_SECRET = 'must-not-enter-child';
    try { assert.equal((await item.run()).state, 'PASS'); }
    finally {
      if (original === undefined) delete process.env.AMCL_GATE_CACHE_UNDECLARED_SECRET;
      else process.env.AMCL_GATE_CACHE_UNDECLARED_SECRET = original;
    }
  });

  await check('behavior cannot reuse even if catalog mistakenly asks for PASS caching', async () => {
    const item = fixture('behavior'); const behavior = {schema: 1, gates: [{...policy.gates[0], kind: 'behavior'}]};
    const full = {...item.spec, profile: 'full', kind: 'behavior'};
    assert.equal((await item.run({trustedPolicy: behavior}, full)).state, 'PASS');
    assert.equal((await item.run({trustedPolicy: behavior}, full)).state, 'PASS'); assert.equal(item.count(), 2);
  });

  await check('missing logs, corrupted published bytes and current output drift force actual execution', async () => {
    const item = fixture('corruption');
    let previous = await item.run();
    fs.unlinkSync(path.join(previous.publishedObject, 'stdout.log'));
    assert.equal((await item.run()).state, 'PASS'); assert.equal(item.count(), 2);
    previous = await item.run(); assert.equal(previous.state, 'REUSED_PASS');
    fs.writeFileSync(path.join(previous.publishedObject, 'stderr.log'), 'corrupted bytes');
    assert.equal((await item.run()).state, 'PASS'); assert.equal(item.count(), 3);
    fs.writeFileSync(item.artifact, 'changed output');
    assert.equal((await item.run()).state, 'PASS'); assert.equal(item.count(), 4);
    fs.unlinkSync(item.artifact);
    assert.equal((await item.run()).state, 'PASS'); assert.equal(item.count(), 5);
  });

  await check('incomplete completion state and malicious manifest member are rejected', async () => {
    const item = fixture('manifest'); let previous = await item.run();
    let filename = path.join(previous.publishedObject, 'manifest.json');
    let manifest = JSON.parse(fs.readFileSync(filename, 'utf8')); manifest.state = 'RUNNING'; fs.writeFileSync(filename, JSON.stringify(manifest));
    assert.equal((await item.run()).state, 'PASS'); assert.equal(item.count(), 2);
    previous = await item.run(); filename = path.join(previous.publishedObject, 'manifest.json');
    manifest = JSON.parse(fs.readFileSync(filename, 'utf8')); manifest.artifacts[0].name = '../control.json'; fs.writeFileSync(filename, JSON.stringify(manifest));
    assert.equal((await item.run()).state, 'PASS'); assert.equal(item.count(), 3);
  });

  await check('input drift after a zero exit cannot publish PASS', async () => {
    const item = fixture('drift'); item.mode('drift');
    const result = await item.run(); assert.equal(result.state, 'FAIL'); assert.match(result.error, /drift/);
    assert.notEqual(result.beforeIdentity, result.afterIdentity);
    assert.equal(fs.readdirSync(path.join(item.root, 'cache', 'objects')).length, 0);
  });

  await check('Fresh executes and a same-key cold failure quarantines old PASS', async () => {
    const item = fixture('cold-failure'); await item.run();
    assert.equal((await item.run({fresh: true})).state, 'PASS'); assert.equal(item.count(), 2);
    item.mode('fail'); const failed = await item.run({fresh: true});
    assert.equal(failed.state, 'FAIL'); assert.equal(failed.exitCode, 13);
    assert.equal(fs.readdirSync(path.join(item.root, 'cache', 'objects')).length, 0);
    item.mode('pass'); assert.equal((await item.run()).state, 'PASS'); assert.equal(item.count(), 4);
  });

  await check('empty output requires explicit expectation but command and exit evidence always exist', async () => {
    const item = fixture('empty-output'); item.mode('empty');
    assert.equal((await item.run()).state, 'FAIL');
    const silent = {...item.spec, expectation: {allowEmptyOutput: true}};
    const success = await item.run({}, silent); assert.equal(success.state, 'PASS');
    assert.equal((await item.run({}, silent)).state, 'REUSED_PASS');
    assert.ok(fs.existsSync(path.join(success.publishedObject, 'command.json')));
  });

  await check('timeout and cancellation retain evidence without publishing success', async () => {
    const item = fixture('termination'); item.mode('wait');
    const timeout = await item.run({}, {...item.spec, timeoutMs: 75});
    assert.equal(timeout.state, 'FAIL'); assert.equal(timeout.execution.timedOut, true);
    const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), 100);
    const cancelled = await item.run({signal: controller.signal}); clearTimeout(timer);
    assert.equal(cancelled.state, 'ABORTED'); assert.equal(cancelled.execution.aborted, true);
    assert.equal(fs.readdirSync(path.join(item.root, 'cache', 'objects')).length, 0);
  });

  await check('same-key concurrent callers publish once and the waiter revalidates the object', async () => {
    const item = fixture('concurrent'); item.mode('delay');
    const results = await Promise.all([item.run(), item.run()]);
    assert.deepEqual(results.map((row) => row.state).sort(), ['PASS', 'REUSED_PASS']); assert.equal(item.count(), 1);
    assert.equal(fs.readdirSync(path.join(item.root, 'cache', 'locks')).length, 0);
  });

  await check('a timed-out lock waiter cannot mutate or steal another live writer lease', async () => {
    const item = fixture('lock-timeout'); item.mode('delay');
    const first = item.run();
    while (item.count() === 0) await new Promise((resolve) => setTimeout(resolve, 10));
    const second = await item.run({lockTimeoutMs: 30});
    assert.equal(second.state, 'FAIL'); assert.match(second.error, /lock timeout/);
    assert.equal((await first).state, 'PASS'); assert.equal(item.count(), 1);
    assert.equal((await item.run()).state, 'REUSED_PASS');
  });

  await check('CLI uses a real catalog; passthrough emits no result JSON into child stdout', async () => {
    const item = fixture('cli'); const specPath = path.join(item.root, 'spec.json'), catalog = path.join(item.root, 'catalog.json');
    fs.writeFileSync(specPath, JSON.stringify(item.spec)); fs.writeFileSync(catalog, JSON.stringify(policy));
    const report = path.join(item.root, 'cli-report.json'); const options = item.options();
    const cli = spawnSync(process.execPath, [path.join(project, 'scripts/lib/build-gate-cache.mjs'), 'run', '--spec', specPath,
      '--catalog', catalog, '--cache-root', options.cacheRoot, '--run-root', options.runRoot, '--passthrough', '--report', report], {encoding: 'utf8'});
    assert.equal(cli.status, 0, cli.stderr); assert.equal(cli.stdout, 'PASS real fixture\n');
    assert.equal(JSON.parse(fs.readFileSync(report, 'utf8')).state, 'PASS');
    const reusedReport=path.join(item.root,'cli-reused.json'), reusedOptions=item.options();
    const reused=spawnSync(process.execPath,[path.join(project,'scripts/lib/build-gate-cache.mjs'),'run','--spec',specPath,
      '--catalog',catalog,'--cache-root',reusedOptions.cacheRoot,'--run-root',reusedOptions.runRoot,'--passthrough','--report',reusedReport],{encoding:'utf8'});
    assert.equal(reused.status,0,reused.stderr);assert.equal(reused.stdout,cli.stdout);
    assert.equal(JSON.parse(fs.readFileSync(reusedReport,'utf8')).state,'REUSED_PASS');assert.equal(item.count(),1);
    fs.writeFileSync(catalog, JSON.stringify({schema: 1, gates: []}));
    const invalid = spawnSync(process.execPath, [path.join(project, 'scripts/lib/build-gate-cache.mjs'), 'run', '--spec', specPath,
      '--catalog', catalog, '--cache-root', options.cacheRoot, '--run-root', options.runRoot + '-reject'], {encoding: 'utf8'});
    assert.notEqual(invalid.status, 0); assert.match(invalid.stderr, /absent/);
  });
} finally {
  // 用实际执行记录决定统一结论，避免用例增加后汇总与进程退出码互相矛盾。
  const state=cases.length>0&&cases.every(row=>row.state==='PASS')?'PASS':'FAIL';
  fs.writeFileSync(path.join(output, 'summary.json'), JSON.stringify({completedAt: new Date().toISOString(), cases,state}, null, 2) + '\n');
  if(state!=='PASS')process.exitCode=1;
}
