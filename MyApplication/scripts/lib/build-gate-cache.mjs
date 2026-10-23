/**
 * 确定性静态检查的本机结果缓存；Native 编译树和应用产物不归本模块管理。
 * 身份由显式输入闭包、实际工具、命令、配置和受控环境组成。只有受信 catalog
 * 明确授权的静态 gate 才能复用 PASS；调用方仍负责完整列出间接输入并冻结源。
 * 发布对象只读消费，同 key 写租约覆盖复核/执行/发布；失败与中断绝不发布 PASS。
 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {assertExternalOutputPath} from './workspace-paths.mjs';

const MODULE_PATH = fileURLToPath(import.meta.url);
const SCHEMA = 1;
const OUTPUT_ENVIRONMENT = new Set(['AMCL_RUN_DIR', 'TEMP', 'TMP']);
const hash = (value) => crypto.createHash('sha256').update(value).digest('hex');
const now = () => new Date().toISOString();
const token = () => crypto.randomUUID();

/** 稳定对象序列化；数组保留顺序，拒绝 JSON 无法可靠表达的身份字段。 */
export function stableJson(value) {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return JSON.stringify(value);
  if (typeof value === 'number' && Number.isFinite(value)) return JSON.stringify(value);
  if (Array.isArray(value)) return '[' + value.map(stableJson).join(',') + ']';
  if (value && Object.getPrototypeOf(value) === Object.prototype) {
    return '{' + Object.keys(value).sort().map((key) => JSON.stringify(key) + ':' + stableJson(value[key])).join(',') + '}';
  }
  throw new Error('Unsupported identity value');
}

function contained(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === '' || (!path.isAbsolute(relative) && relative !== '..' && !relative.startsWith('..' + path.sep));
}

/** 从文件系统根逐段 lstat；源码、缓存和证据均不跟随符号链接/junction。 */
function noLinks(filename, {missing = false} = {}) {
  const absolute = path.resolve(filename);
  let current = path.parse(absolute).root;
  for (const part of absolute.slice(current.length).split(path.sep).filter(Boolean)) {
    current = path.join(current, part);
    let stat;
    try { stat = fs.lstatSync(current); }
    catch (error) { if (missing && error.code === 'ENOENT') return absolute; throw error; }
    if (stat.isSymbolicLink()) throw new Error('Links are not accepted in gate evidence: ' + current);
  }
  return absolute;
}

function fileIdentity(filename) {
  noLinks(filename);
  const stat = fs.lstatSync(filename, {bigint: true});
  if (!stat.isFile()) throw new Error('Expected regular file: ' + filename);
  const fd = fs.openSync(filename, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
  try {
    const opened = fs.fstatSync(fd, {bigint: true});
    if (!opened.isFile() || opened.dev !== stat.dev || opened.ino !== stat.ino) throw new Error('Input file identity changed while opening: ' + filename);
    const bytes = fs.readFileSync(fd);
    noLinks(filename);
    const after = fs.lstatSync(filename, {bigint: true});
    if (after.dev !== opened.dev || after.ino !== opened.ino) throw new Error('Input file was replaced while reading: ' + filename);
    return {path: path.resolve(filename), bytes: bytes.length, sha256: hash(bytes)};
  } finally { fs.closeSync(fd); }
}

/** 目录身份包括空目录和所有成员名；新增、移除或同名头遮蔽都会改变身份。 */
function directoryIdentity(directory) {
  noLinks(directory);
  if (!fs.statSync(directory).isDirectory()) throw new Error('Expected directory: ' + directory);
  const entries = [];
  function visit(current) {
    noLinks(current);
    for (const name of fs.readdirSync(current).sort()) {
      const child = path.join(current, name);
      const relative = path.relative(directory, child).split(path.sep).join('/');
      const stat = fs.lstatSync(child);
      if (stat.isSymbolicLink()) throw new Error('Input directory contains a link: ' + child);
      if (stat.isDirectory()) { entries.push({path: relative, kind: 'directory'}); visit(child); }
      else if (stat.isFile()) {
        const identity = fileIdentity(child);
        entries.push({path: relative, kind: 'file', bytes: identity.bytes, sha256: identity.sha256});
      } else throw new Error('Unsupported input directory member: ' + child);
    }
  }
  visit(directory);
  return {path: path.resolve(directory), entries};
}

function normalizedSpec(spec) {
  if (spec.schema !== SCHEMA || !/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,95}$/.test(spec.gateId ?? '')) throw new Error('Invalid gate spec/schema');
  if (!['quick', 'full'].includes(spec.profile)) throw new Error('Invalid validation profile');
  const cwd = noLinks(spec.cwd);
  if (!fs.statSync(cwd).isDirectory()) throw new Error('Gate cwd is not a directory');
  if (!path.isAbsolute(spec.command?.executable ?? '') || !Array.isArray(spec.command?.args) || spec.command.args.some((arg) => typeof arg !== 'string')) {
    throw new Error('Gate command requires an absolute executable and string args');
  }
  const executable = noLinks(spec.command.executable);
  const roots = [cwd, ...(spec.inputRoots ?? []).map((root) => noLinks(path.resolve(cwd, root)))];
  const inputPath = (entry) => {
    const absolute = path.resolve(cwd, entry);
    if (!roots.some((root) => contained(root, absolute))) throw new Error('Input escapes declared roots: ' + entry);
    return absolute;
  };
  const files = [...new Set((spec.inputs?.files ?? []).map(inputPath))].sort();
  const directories = [...new Set((spec.inputs?.directories ?? []).map(inputPath))].sort();
  if (files.length + directories.length === 0) throw new Error('Gate requires explicit input closure');
  const outputs = [...new Set((spec.outputs ?? []).map((entry) => path.resolve(cwd, entry)))].sort();
  for (const output of outputs) {
    if (files.includes(output) || directories.some((directory) => contained(directory, output))) throw new Error('Outputs must not overlap input closure: ' + output);
  }
  const timeoutMs = spec.timeoutMs ?? 180000;
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1) throw new Error('Invalid gate timeout');
  const expectation = {allowEmptyOutput: false, stdoutIncludes: [], stderrExcludes: [], ...(spec.expectation ?? {})};
  if (typeof expectation.allowEmptyOutput !== 'boolean' || !['stdoutIncludes', 'stderrExcludes'].every((name) =>
    Array.isArray(expectation[name]) && expectation[name].every((item) => typeof item === 'string'))) throw new Error('Invalid gate expectation');
  return {...spec, cwd, command: {executable, args: [...spec.command.args]}, files, directories, outputs, timeoutMs, expectation};
}

/** catalog 是仓内受信规则；spec 自报 deterministic 不授予资格。测试可显式注入同等规则。 */
function policyFor(spec, options) {
  const catalog = options.trustedPolicy ?? JSON.parse(fs.readFileSync(noLinks(options.catalogPath ?? path.join(spec.cwd, 'config/build-gates.json')), 'utf8'));
  const records = Array.isArray(catalog.gates) ? catalog.gates : Object.entries(catalog.gates ?? {}).map(([id, row]) => ({id, ...row}));
  const rows = records.filter((row) => (row.id ?? row.gateId) === spec.gateId);
  if (rows.length !== 1) throw new Error('Gate is absent or duplicated in trusted catalog: ' + spec.gateId);
  const policy = rows[0];
  if (spec.kind !== undefined && spec.kind !== policy.kind) throw new Error('Spec gate kind disagrees with catalog');
  if (typeof policy.script !== 'string') throw new Error('Catalog gate requires an exact script');
  const script = noLinks(path.resolve(spec.cwd, policy.script));
  const actualScript = spec.command.args.find((arg) => !arg.startsWith('-'));
  if (!actualScript || path.resolve(spec.cwd, actualScript) !== script) throw new Error('Gate command does not name the catalog entry script');
  return {policy, script, catalogSchema: catalog.schema ?? catalog.schemaVersion ?? 1};
}

/** 不继承父进程任意环境；系统最小运行环境也按实际值入身份，日志只记录值摘要。 */
function controlledEnvironment(spec, policy, runRoot) {
  const environment = {};
  if (process.platform === 'win32') for (const key of ['SystemRoot', 'WINDIR', 'COMSPEC', 'PATHEXT']) {
    const entry = Object.entries(process.env).find(([name]) => name.toLowerCase() === key.toLowerCase());
    if (entry) environment[entry[0]] = entry[1];
  }
  const outputOnly = new Set(policy.outputOnlyEnvironment ?? []);
  for (const [name, value] of Object.entries(spec.environment ?? {})) {
    if (typeof value !== 'string' || !/^[a-zA-Z_][a-zA-Z0-9_()]*$/.test(name)) throw new Error('Invalid controlled environment value');
    if (value.includes('{runRoot}') && (!OUTPUT_ENVIRONMENT.has(name) || !outputOnly.has(name))) {
      throw new Error('Run-root placeholder requires an output-only catalog declaration: ' + name);
    }
    const key = process.platform === 'win32' ? name.toUpperCase() : name;
    for (const existing of Object.keys(environment)) if (process.platform === 'win32' && existing.toUpperCase() === key) delete environment[existing];
    environment[key] = value;
  }
  const identity = Object.fromEntries(Object.keys(environment).sort().map((name) => [name, hash(environment[name])]));
  const effective = Object.fromEntries(Object.entries(environment).map(([name, value]) => [name, value.replaceAll('{runRoot}', runRoot ?? '{runRoot}')]));
  return {identity, effective};
}

/** 返回完整 before/after 身份；工具和库自身变更也会失效，不能只依赖源码 HEAD。 */
export function createGateIdentity(rawSpec, options = {}) {
  const spec = normalizedSpec(rawSpec);
  const {policy, script, catalogSchema} = policyFor(spec, options);
  const environment = controlledEnvironment(spec, policy);
  const identity = {
    schema: SCHEMA, gateId: spec.gateId, cwd: spec.cwd, platform: process.platform, arch: process.arch,
    implementation: [fileIdentity(MODULE_PATH), fileIdentity(fileURLToPath(new URL('./workspace-paths.mjs', import.meta.url)))],
    policy: {catalogSchema, ...policy}, command: spec.command, config: spec.config ?? {}, timeoutMs: spec.timeoutMs,
    expectation: spec.expectation, environment: environment.identity,
    files: [...new Set([...spec.files, script])].sort().map(fileIdentity), directories: spec.directories.map(directoryIdentity),
    tools: [...new Set([spec.command.executable, ...(spec.tools ?? []).map((entry) => path.resolve(spec.cwd, entry))])].sort().map(fileIdentity),
    outputs: spec.outputs,
  };
  return {key: hash(stableJson(identity)), identity, spec, policy};
}

function writeJson(filename, value) { fs.writeFileSync(filename, JSON.stringify(value, null, 2) + '\n', {flag: 'wx'}); }
function ensureDirectory(directory) { noLinks(directory, {missing: true}); fs.mkdirSync(directory, {recursive: true}); noLinks(directory); }

/** 同 key 锁不自动抢占：崩溃遗留锁必须人工核实，PID 复用或年龄不能证明写者已停止。 */
async function acquireLock(directory, key, {lockTimeoutMs = 30000, signal} = {}) {
  const filename = path.join(directory, key + '.lock');
  const owner = token();
  const deadline = Date.now() + lockTimeoutMs;
  while (true) {
    if (signal?.aborted) throw new Error('Gate aborted while waiting for cache lock');
    try {
      fs.writeFileSync(filename, stableJson({owner, pid: process.pid, startedAt: now()}), {flag: 'wx'});
      return () => {
        noLinks(filename);
        if (JSON.parse(fs.readFileSync(filename, 'utf8')).owner !== owner) throw new Error('Cache lock ownership changed');
        fs.unlinkSync(filename);
      };
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      if (Date.now() >= deadline) throw new Error('Cache lock timeout; existing writer/evidence retained: ' + filename);
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
  }
}

function objectFile(directory, name) {
  if (!/^(stdout\.log|stderr\.log|command\.json|output-[0-9]+)$/.test(name)) throw new Error('Invalid published object member');
  return noLinks(path.join(directory, name));
}

/** 每次命中都回读完成态及真实输出；损坏/缺日志/目录替换不能借旧摘要通过。 */
function readPublished(directory, expected) {
  noLinks(directory);
  const manifest = JSON.parse(fs.readFileSync(noLinks(path.join(directory, 'manifest.json')), 'utf8'));
  if (manifest.schema !== SCHEMA || manifest.state !== 'PASS' || manifest.exitCode !== 0 || manifest.key !== expected.key ||
      hash(stableJson(manifest.identity)) !== expected.key || !Number.isFinite(Date.parse(manifest.completedAt)) ||
      !Number.isFinite(Date.parse(manifest.startedAt)) || manifest.artifacts.length !== 3 + expected.spec.outputs.length) throw new Error('Incomplete or mismatched cache manifest');
  const expectedNames = ['command.json', 'stdout.log', 'stderr.log', ...expected.spec.outputs.map((_, index) => 'output-' + index)].sort();
  if (stableJson(manifest.artifacts.map((row) => row.name).sort()) !== stableJson(expectedNames)) throw new Error('Cache artifact set mismatch');
  for (const row of manifest.artifacts) {
    const actual = fileIdentity(objectFile(directory, row.name));
    if (actual.sha256 !== row.sha256 || actual.bytes !== row.bytes) throw new Error('Cache artifact corrupted: ' + row.name);
  }
  if (manifest.outputs.length !== expected.spec.outputs.length) throw new Error('Cache output set mismatch');
  for (let index = 0; index < expected.spec.outputs.length; index++) {
    const actual = fileIdentity(expected.spec.outputs[index]);
    if (stableJson(actual) !== stableJson(manifest.outputs[index])) throw new Error('Current gate output differs from published proof');
    const stored = manifest.artifacts.find((row) => row.name === 'output-' + index);
    if (stored.sha256 !== actual.sha256 || stored.bytes !== actual.bytes) throw new Error('Stored output is not bound to the original output');
  }
  return manifest;
}

function quarantine(cacheRoot, key, reason) {
  const object = path.join(cacheRoot, 'objects', key);
  if (!fs.existsSync(object)) return;
  noLinks(object);
  const destination = path.join(cacheRoot, 'quarantine', key + '-' + token());
  fs.renameSync(object, destination);
  writeJson(path.join(destination, 'quarantine.json'), {reason, recordedAt: now()});
}

/** 子命令无 shell 执行；stdout/stderr 实时落盘，超时/取消和真实 exit 单独记录。 */
async function execute(spec, environment, runRoot, options) {
  const stdoutPath = path.join(runRoot, 'stdout.log'), stderrPath = path.join(runRoot, 'stderr.log');
  const stdoutFd = fs.openSync(stdoutPath, 'wx'), stderrFd = fs.openSync(stderrPath, 'wx');
  writeJson(path.join(runRoot, 'command.json'), {executable: spec.command.executable, args: spec.command.args, cwd: spec.cwd,
    environmentKeys: Object.keys(environment).sort(), startedAt: now()});
  let timedOut = false, aborted = false, spawnError = null;
  let child, deadline;
  const cancel = () => { aborted = true; child?.kill(); };
  let exit;
  try {
    exit = await new Promise((resolve) => {
      child = spawn(spec.command.executable, spec.command.args, {cwd: spec.cwd, env: environment, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true});
      deadline = setTimeout(() => { timedOut = true; child.kill(); }, spec.timeoutMs);
      child.stdout.on('data', (bytes) => { fs.writeFileSync(stdoutFd, bytes); if (options.passthrough) process.stdout.write(bytes); });
      child.stderr.on('data', (bytes) => { fs.writeFileSync(stderrFd, bytes); if (options.passthrough) process.stderr.write(bytes); });
      child.once('error', (error) => { spawnError = error.message; });
      child.once('close', (exitCode, signal) => resolve({exitCode, signal}));
      options.signal?.addEventListener('abort', cancel, {once: true});
      if (options.signal?.aborted) cancel();
    });
  } finally {
    clearTimeout(deadline);
    options.signal?.removeEventListener('abort', cancel);
    fs.closeSync(stdoutFd); fs.closeSync(stderrFd);
  }
  return {...exit, timedOut, aborted, spawnError};
}

function verifyExpectation(spec, runRoot) {
  const stdout = fs.readFileSync(path.join(runRoot, 'stdout.log'), 'utf8');
  const stderr = fs.readFileSync(path.join(runRoot, 'stderr.log'), 'utf8');
  if (!spec.expectation.allowEmptyOutput && stdout.length + stderr.length === 0) throw new Error('Gate produced no required log output');
  for (const text of spec.expectation.stdoutIncludes) if (!stdout.includes(text)) throw new Error('Required stdout evidence missing: ' + text);
  for (const text of spec.expectation.stderrExcludes) if (stderr.includes(text)) throw new Error('Forbidden stderr evidence: ' + text);
}

/**
 * 执行一个受信静态 gate；返回本轮报告，不将旧执行时间改写成新运行。
 * full 行为门永不命中；本期所有 behavior gate 都不发布结果缓存。
 * Fresh 绕过读缓存，成功后可发布新证明；同逻辑 key 冷失败会隔离旧 PASS。
 */
export async function runGate(rawSpec, options = {}) {
  const current = createGateIdentity(rawSpec, options);
  const {spec, policy, key} = current;
  const cacheRoot = assertExternalOutputPath(path.resolve(options.cacheRoot), {root: spec.cwd});
  const runRoot = assertExternalOutputPath(path.resolve(options.runRoot), {root: spec.cwd});
  if (contained(cacheRoot, runRoot) || contained(runRoot, cacheRoot)) throw new Error('Run evidence and shared cache roots must be disjoint');
  ensureDirectory(path.dirname(runRoot)); noLinks(runRoot, {missing: true}); fs.mkdirSync(runRoot);
  for (const name of ['', 'locks', 'objects', 'pending', 'quarantine']) ensureDirectory(path.join(cacheRoot, name));
  const cacheable = policy.kind === 'static' && policy.deterministic === true && policy.cachePolicy === 'pass';
  const startedAt = now();
  let release = null, result;
  const object = path.join(cacheRoot, 'objects', key);
  try {
    if (cacheable) release = await acquireLock(path.join(cacheRoot, 'locks'), key, options);
    if (createGateIdentity(rawSpec, options).key !== key) throw new Error('Gate inputs changed while acquiring cache lease');
    if (cacheable && !options.fresh && fs.existsSync(object)) {
      let published;
      try { published = readPublished(object, current); }
      catch (error) { quarantine(cacheRoot, key, error.message); }
      if (published) {
        if (createGateIdentity(rawSpec, options).key !== key) throw new Error('Gate inputs changed during cached proof verification');
        // 调用者可能捕获 stdout 的机器可读结果；复用时回放经复核的原字节，保持同一接口。
        if(options.passthrough) {
          process.stdout.write(fs.readFileSync(objectFile(object,'stdout.log')));
          process.stderr.write(fs.readFileSync(objectFile(object,'stderr.log')));
        }
        result = {schema: SCHEMA, gateId: spec.gateId, key, state: 'REUSED_PASS', exitCode: 0, startedAt, completedAt: now(),
          beforeIdentity: key, afterIdentity: key, originalExecution: {startedAt: published.startedAt, completedAt: published.completedAt,
            manifestSha256: hash(fs.readFileSync(path.join(object, 'manifest.json')))}, reusedAt: now(), publishedObject: object};
        return result;
      }
    }
    const environment = controlledEnvironment(spec, policy, runRoot).effective;
    for (const [name, value] of Object.entries(spec.environment ?? {})) if (value.includes('{runRoot}')) {
      const key = process.platform === 'win32' ? name.toUpperCase() : name;
      const directory = path.resolve(environment[key]);
      if (!contained(runRoot, directory)) throw new Error('Output-only environment escapes this run: ' + name);
      ensureDirectory(directory);
    }
    const execution = await execute(spec, environment, runRoot, options);
    result = {schema: SCHEMA, gateId: spec.gateId, key, state: execution.aborted ? 'ABORTED' : 'FAIL', exitCode: execution.exitCode ?? 1,
      startedAt, completedAt: now(), beforeIdentity: key, afterIdentity: null, execution, cacheEligible: cacheable};
    const after = createGateIdentity(rawSpec, options); result.afterIdentity = after.key;
    if (after.key !== key) throw new Error('Gate input drift detected');
    if (execution.exitCode !== 0 || execution.timedOut || execution.aborted || execution.spawnError) throw new Error('Gate command did not complete successfully');
    verifyExpectation(spec, runRoot);
    const outputs = spec.outputs.map(fileIdentity);
    result.state = 'PASS'; result.exitCode = 0;
    if (cacheable) {
      // 仅在顶层所有判据通过后复制完成对象；新对象不得覆盖既有不可变成功对象。
      const pending = path.join(cacheRoot, 'pending', key + '-' + token()); fs.mkdirSync(pending);
      const artifactNames = ['command.json', 'stdout.log', 'stderr.log'];
      for (const name of artifactNames) fs.copyFileSync(path.join(runRoot, name), path.join(pending, name), fs.constants.COPYFILE_EXCL);
      for (let index = 0; index < outputs.length; index++) {
        const name = 'output-' + index; artifactNames.push(name);
        fs.copyFileSync(outputs[index].path, path.join(pending, name), fs.constants.COPYFILE_EXCL);
        const copied = fileIdentity(path.join(pending, name));
        if (copied.sha256 !== outputs[index].sha256 || copied.bytes !== outputs[index].bytes) throw new Error('Output changed while publishing: ' + outputs[index].path);
      }
      const manifest = {...result, identity: current.identity, outputs, artifacts: artifactNames.map((name) => {
        const row = fileIdentity(path.join(pending, name)); return {name, bytes: row.bytes, sha256: row.sha256};
      })};
      writeJson(path.join(pending, 'manifest.json'), manifest);
      if (fs.existsSync(object)) quarantine(cacheRoot, key, options.fresh ? 'Replaced by successful explicit Fresh execution' : 'Newly executed proof superseded old object');
      fs.renameSync(pending, object);
      result.publishedObject = object;
    }
    return result;
  } catch (error) {
    if (cacheable && release) quarantine(cacheRoot, key, 'Execution/proof failed: ' + error.message);
    result = {...result, schema: SCHEMA, gateId: spec.gateId, key, state: result?.state === 'ABORTED' || options.signal?.aborted ? 'ABORTED' : 'FAIL',
      exitCode: result?.exitCode > 0 ? result.exitCode : 1, startedAt, completedAt: now(), error: error.message, beforeIdentity: key,
      afterIdentity: result?.afterIdentity ?? null};
    return result;
  } finally {
    if (result) writeJson(path.join(runRoot, 'receipt.json'), result);
    release?.();
  }
}

/** PowerShell CLI：passthrough 不向 stdout 注入 JSON，最终结果只写显式 --report。 */
async function main() {
  const argv = process.argv.slice(2);
  if (argv.shift() !== 'run') throw new Error('Usage: build-gate-cache.mjs run --spec FILE --cache-root DIR --run-root NEW-DIR [--catalog FILE] [--report FILE] [--fresh] [--passthrough]');
  const args = {};
  for (let index = 0; index < argv.length; index++) {
    const flag = argv[index];
    if (['--fresh', '--passthrough'].includes(flag)) args[flag] = true;
    else if (['--spec', '--cache-root', '--run-root', '--catalog', '--report'].includes(flag) && argv[index + 1] && !argv[index + 1].startsWith('--')) args[flag] = argv[++index];
    else throw new Error('Unknown or incomplete argument: ' + flag);
  }
  if (!args['--spec'] || !args['--cache-root'] || !args['--run-root'] || (args['--passthrough'] && !args['--report'])) throw new Error('Missing required gate CLI paths');
  const controller = new AbortController();
  const cancel = () => controller.abort();
  process.once('SIGINT', cancel); process.once('SIGTERM', cancel);
  try {
    const spec = JSON.parse(fs.readFileSync(noLinks(args['--spec']), 'utf8'));
    const result = await runGate(spec, {cacheRoot: args['--cache-root'], runRoot: args['--run-root'], catalogPath: args['--catalog'],
      fresh: args['--fresh'], passthrough: args['--passthrough'], signal: controller.signal});
    if (args['--report']) {
      const report = assertExternalOutputPath(path.resolve(args['--report']), {root: spec.cwd});
      ensureDirectory(path.dirname(report)); noLinks(report, {missing: true});
      // receipt.json 已由本轮 finally 独占写入；允许调用者把同一位置作为 report，拒绝覆盖其他旧证据。
      if (report !== path.join(path.resolve(args['--run-root']), 'receipt.json')) writeJson(report, result);
    }
    if (!args['--passthrough']) console.log(JSON.stringify(result, null, 2));
    if (!['PASS', 'REUSED_PASS'].includes(result.state)) process.exitCode = result.exitCode || 1;
  } finally { process.removeListener('SIGINT', cancel); process.removeListener('SIGTERM', cancel); }
}

if (process.argv[1] && path.resolve(process.argv[1]) === MODULE_PATH) {
  main().catch((error) => { console.error('Build gate cache rejected: ' + error.message); process.exitCode = 2; });
}
