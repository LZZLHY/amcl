/**
 * 真实 Mojang 1.8.9 完整性回归：运行整个生产 VersionFileVerifier，而非复制其筛选逻辑。
 * 只把 OHOS 文件/摘要 API 映射到宿主真实 fs/crypto；使用调用方提供的官方 JSON、
 * 实际客户端 JAR、依赖及 assets。输入始终只读，缺失/损坏只作用于本轮独占夹具。
 * 成功保留小型结果后回收自建硬链接/副本；失败保留现场。正式 ArkTS/SDK 编译另行执行。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { environment } from './lib/ets-runtime-fixture.mjs';
import { createHostTestScope } from './lib/host-test-lifecycle.mjs';
import { assertExternalOutputPath } from './lib/workspace-paths.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const verifierPath = 'feature_core/src/main/ets/version/VersionFileVerifier.ets';

/** 显式参数只定位只读真实输入与仓外输出；不猜维护者工作区，也不修改全局临时目录。 */
function argument(name, required = true) {
  const index = process.argv.indexOf(name), value = index >= 0 ? process.argv[index + 1] : undefined;
  if (required && !value) throw new Error('需要显式参数 ' + name);
  return value;
}
const output = assertExternalOutputPath(argument('--output-dir'));
const manifestPath = path.resolve(argument('--manifest'));
const sourceRoot = path.resolve(argument('--source-dir'));
const sourceClient = path.resolve(argument('--client-path'));
const baselineRef = argument('--baseline-ref', false);
if (baselineRef !== undefined && !/^[0-9a-f]{7,40}$/i.test(baselineRef)) throw new Error('baseline-ref必须是精确Git提交');
fs.mkdirSync(output, { recursive: true });

const manifestBytes = fs.readFileSync(manifestPath), manifest = JSON.parse(manifestBytes.toString('utf8'));
assert.equal(manifest.id, '1.8.9', '本定向回归使用真实Mojang 1.8.9清单');
assert.equal(manifest.downloads.client.sha1, '3870888a6c3d349d3771a3e9d16c9bf5e076b908');
assert.equal(manifest.downloads.client.size, 8461484);
const scope = createHostTestScope('version-verifier-', { parent: output, automatic: false });
const mcDir = path.join(scope.directory, '.minecraft');
const version = manifest.id;
const openDescriptors = new Set();
const counters = { readBytes: 0, sha1Inputs: 0, sha256Inputs: 0, digests: 0 };
const result = {
  recordedAt: new Date().toISOString(), manifestSha256: createHash('sha256').update(manifestBytes).digest('hex'),
  manifestPath, sourceRoot, sourceClient, baselineRef: baselineRef ?? null,
  verifierSha256: createHash('sha256').update(fs.readFileSync(path.join(repo, verifierPath))).digest('hex'),
  boundary: '真实fs/crypto替代OHOS Kit边缘；未替换Verifier业务方法；不等同SDK或手机验收', cases: [],
};

/** 只允许清单内的规范相对路径进入独占夹具，防止任何测试删除/覆盖只读来源或共享父目录。 */
function fixturePath(relative) {
  assert.ok(typeof relative === 'string' && !path.isAbsolute(relative) && !relative.includes('\\'));
  assert.ok(relative.split('/').every(part => part.length > 0 && part !== '.' && part !== '..'));
  const target = path.resolve(mcDir, relative);
  assert.ok(target.startsWith(mcDir + path.sep));
  return target;
}

/** 大体积真实输入优先只建硬链接。控制用例写入前必须先unlink夹具，绝不写共享inode。 */
function linkInput(source, target) {
  const stat = fs.lstatSync(source);
  assert.ok(stat.isFile() && !stat.isSymbolicLink(), '真实输入必须为普通文件: ' + source);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  if (fs.existsSync(target)) return;
  try { fs.linkSync(source, target); }
  catch (error) {
    if (!['EXDEV', 'EPERM', 'ENOTSUP', 'EACCES'].includes(error.code)) throw error;
    fs.copyFileSync(source, target);
  }
}

/** 这里只适配官方API的同步文件语义；readSync的offset是文件偏移，未指定时推进真实fd。 */
const fileIo = {
  OpenMode: { READ_ONLY: 0 },
  statSync: target => fs.statSync(target),
  readTextSync: target => fs.readFileSync(target, 'utf8'),
  openSync: target => { const fd = fs.openSync(target, 'r'); openDescriptors.add(fd); return { fd }; },
  closeSync: file => { const fd = typeof file === 'number' ? file : file.fd; fs.closeSync(fd); openDescriptors.delete(fd); },
  readSync: (fd, buffer, options = {}) => {
    const data = Buffer.from(buffer), length = options.length ?? data.length;
    const count = fs.readSync(fd, data, 0, length, options.offset ?? null);
    counters.readBytes += count; return count;
  },
};

/** 使用OpenSSL真实流式摘要；不返回预置hash，不拦截生产的size/SHA判断与报告。 */
const cryptoFramework = {
  createMd: algorithm => {
    assert.ok(algorithm === 'SHA1' || algorithm === 'SHA256');
    const hash = createHash(algorithm.toLowerCase());
    return {
      updateSync: blob => {
        hash.update(blob.data);
        if (algorithm === 'SHA1') counters.sha1Inputs += blob.data.length;
        else counters.sha256Inputs += blob.data.length;
      },
      digestSync: () => { counters.digests++; return { data: new Uint8Array(hash.digest()) }; },
    };
  },
};

/** 固定Git旧源码只用于行为负控；生产类的所有方法都原样装载，平台边缘保持完全相同。 */
function loadVerifier(source) {
  return environment({
    imports: { '@kit.CoreFileKit': { fileIo }, '@kit.CryptoArchitectureKit': { cryptoFramework } },
    commons: { formatError: error => error?.message ?? String(error) },
    sourceOverrides: source === undefined ? {} : { [verifierPath]: () => source },
  }).load(verifierPath).VersionFileVerifier;
}

/** 保存每次真实verifyAll输出与读/hash计数，证明用例经过完整实现及实际字节。 */
async function observe(name, verifier) {
  const before = { ...counters }, progress = [];
  const report = await verifier.verifyAll(mcDir, version, (done, total, label) => progress.push({ done, total, label }));
  assert.equal(openDescriptors.size, 0, 'Verifier必须关闭其打开的全部文件');
  const observation = { name, report, progress,
    io: Object.fromEntries(Object.keys(counters).map(key => [key, counters[key] - before[key]])) };
  result.cases.push(observation); console.log('OBSERVED: ' + name + ' ' + JSON.stringify(report));
  return report;
}

/** 用例结束总把自身目标恢复为只读来源链接；失败报告也不改动用户/QA原输入。 */
async function missingCase(relative, verifier, name) {
  const target = fixturePath(relative), source = path.join(sourceRoot, relative);
  fs.unlinkSync(target);
  try { return await observe(name, verifier); }
  finally { linkInput(source, target); }
}

/** 等长破坏一个真实JAR字节：先unlink夹具再写副本，强制测试SHA而非仅靠size发现错误。 */
async function corruptCase(relative, source, verifier, name) {
  const target = fixturePath(relative), bytes = fs.readFileSync(target);
  assert.ok(bytes.length > 0); bytes[bytes.length - 1] ^= 1;
  fs.unlinkSync(target); fs.writeFileSync(target, bytes);
  try { return await observe(name, verifier); }
  finally { fs.unlinkSync(target); linkInput(source, target); }
}

let success = false;
try {
  // 这五个精确工件来自真实device误报，刻意不放入夹具；不是复制产品的字符串筛选谓词。
  const omitted = new Set([
    'net/java/jinput/jinput/2.0.5/jinput-2.0.5.jar',
    'net/java/jutils/jutils/1.0.0/jutils-1.0.0.jar',
    'org/lwjgl/lwjgl/lwjgl/2.9.4-nightly-20150209/lwjgl-2.9.4-nightly-20150209.jar',
    'org/lwjgl/lwjgl/lwjgl_util/2.9.4-nightly-20150209/lwjgl_util-2.9.4-nightly-20150209.jar',
    'org/lwjgl/lwjgl/lwjgl-platform/2.9.4-nightly-20150209/lwjgl-platform-2.9.4-nightly-20150209.jar',
  ]);
  const versionJson = fixturePath('versions/' + version + '/' + version + '.json');
  fs.mkdirSync(path.dirname(versionJson), { recursive: true }); fs.writeFileSync(versionJson, manifestBytes);
  const clientRelative = 'versions/' + version + '/' + version + '.jar';
  linkInput(sourceClient, fixturePath(clientRelative));
  for (const library of manifest.libraries) {
    const artifact = library.downloads?.artifact;
    if (artifact && !omitted.has(artifact.path)) linkInput(path.join(sourceRoot, 'libraries', artifact.path), fixturePath('libraries/' + artifact.path));
  }
  const indexRelative = 'assets/indexes/' + manifest.assetIndex.id + '.json';
  linkInput(path.join(sourceRoot, indexRelative), fixturePath(indexRelative));
  const assetIndex = JSON.parse(fs.readFileSync(fixturePath(indexRelative), 'utf8'));
  for (const object of Object.values(assetIndex.objects)) {
    assert.match(object.hash, /^[a-f0-9]{40}$/);
    const relative = 'assets/objects/' + object.hash.slice(0, 2) + '/' + object.hash;
    linkInput(path.join(sourceRoot, relative), fixturePath(relative));
  }
  assert.equal(Object.keys(assetIndex.objects).length, 734);
  const verifier = loadVerifier();
  if (baselineRef !== undefined) {
    const source = execFileSync('git', ['-C', repo, 'show', baselineRef + ':' + verifierPath], { encoding: 'utf8' });
    const baseline = loadVerifier(source);
    const report = await observe('fixed-git-baseline-reproduces-five-PC-missing', baseline);
    assert.deepEqual([...report.missing].sort(), [...omitted].map(value => path.posix.basename(value)).sort());
    assert.deepEqual(report.corrupted, []); assert.equal(report.assetsMissing, 0);
    // 校验的普通库集合精确不变；不是把整个libraries完整性检查关闭来取得绿色结果。
    assert.deepEqual(verifier.readMeta(mcDir, version).libs,
      baseline.readMeta(mcDir, version).libs.filter(library => !omitted.has(library.path)));
  }
  const complete = await observe('OHOS-runtime-replacement-keeps-ordinary-libraries-and-real-assets', verifier);
  assert.deepEqual(complete.missing, []); assert.deepEqual(complete.corrupted, []);
  assert.equal(complete.hadMeta, true); assert.equal(complete.assetsTotal, 734); assert.equal(complete.assetsMissing, 0);
  assert.ok(result.cases.at(-1).io.sha1Inputs > manifest.downloads.client.size, '必须实际hash客户端及普通库');

  const soundPath = 'com/paulscode/librarylwjglopenal/20100824/librarylwjglopenal-20100824.jar';
  const missing = await missingCase('libraries/' + soundPath, verifier, 'ordinary-library-with-lwjgl-in-name-still-missing');
  assert.deepEqual(missing.missing, [path.posix.basename(soundPath)]); assert.deepEqual(missing.corrupted, []);

  const ordinary = 'libraries/commons-io/commons-io/2.4/commons-io-2.4.jar';
  const broken = await corruptCase(ordinary, path.join(sourceRoot, ordinary), verifier, 'ordinary-same-size-corruption-still-reported');
  assert.deepEqual(broken.missing, []); assert.deepEqual(broken.corrupted, ['commons-io-2.4.jar']);

  const client = await corruptCase(clientRelative, sourceClient, verifier, 'real-client-same-size-corruption-still-reported');
  assert.deepEqual(client.missing, []); assert.deepEqual(client.corrupted, [version + '.jar']);

  const firstObject = Object.values(assetIndex.objects)[0];
  const assetRelative = 'assets/objects/' + firstObject.hash.slice(0, 2) + '/' + firstObject.hash;
  const assets = await missingCase(assetRelative, verifier, 'real-asset-missing-still-reported');
  // 同一内容对象可被多个资源名称引用；报告按索引条目计数，不能把一个inode假定为一条资源。
  const affectedReferences = Object.values(assetIndex.objects).filter(object => object.hash === firstObject.hash).length;
  result.assetRemoval = { hash: firstObject.hash, affectedReferences };
  assert.equal(assets.assetsMissing, affectedReferences); assert.deepEqual(assets.corrupted, []);

  result.status = 'passed'; result.count = result.cases.length; result.counters = counters;
  fs.writeFileSync(path.join(output, 'verifier-result.json'), JSON.stringify(result, null, 2));
  console.log('PASS actual VersionFileVerifier: ' + result.count + ' cases'); success = true;
} catch (error) {
  result.status = 'failed'; result.error = error.stack ?? String(error); result.counters = counters;
  fs.writeFileSync(path.join(output, 'verifier-result.json'), JSON.stringify(result, null, 2));
  throw error;
} finally {
  assert.equal(openDescriptors.size, 0, '运行结束仍有Verifier文件句柄');
  await scope.close({ success });
}
