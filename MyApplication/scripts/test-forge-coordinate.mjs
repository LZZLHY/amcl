/**
 * Forge 发布坐标专项：直接转译生产解析器、Maven metadata 合并和 ForgeService。
 * 文本/文件传输、平台解压与最终 JVM 引擎是可控边界；新版捕获真实 profile并执行取消
 * 前置链，旧版既捕获真实下载规格也执行外置文件上的完整复制、JSON发布、摘要绑定和
 * Maven批量接线，证明URL与强check真实到达消费入口。宿主传输替身不证明Native预检。
 * 本测试不写手机、不执行 Forge installer、不创建或删除用户实例，也不以基础版本
 * 替身的成功作为 Forge 安装已通过的证据。产物/真机完整安装由项目交付流程验证。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { loader } from './mod-install-test-runtime.mjs';
import { workspaceTempRoot } from './lib/workspace-paths.mjs';

const cases = [];
const log = { info() {}, warn() {}, error() {}, debug() {} };
const bmclBase = 'https://bmclapi2.bangbang93.com';
const officialMetadata = 'https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml';
const mirrorMetadata = bmclBase + '/maven/net/minecraftforge/forge/maven-metadata.xml';
const fixtureStop = 'fixture stopped after observing the real installer DownloadTaskSpec';

/** 仅构造仓库文本夹具；版本解析、跨来源合并与裁决必须继续执行生产实现。 */
function metadata(versions) {
  return '<metadata><groupId>net.minecraftforge</groupId><artifactId>forge</artifactId><versioning><versions>'
    + versions.map(version => '<version>' + version + '</version>').join('')
    + '</versions></versioning></metadata>';
}

/** 用显式释放的 Promise 固定 metadata 等待窗口，不依赖睡眠或真实网络时延。 */
function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

/**
 * 生成带正确 CRC、本地条目、中央目录和 EOCD 的 stored ZIP/JAR。生产的 JAR 完整性
 * 检查和分块摘要会读取这些实际字节；不能用只有 PK 魔数的伪文件掩盖截断反例。
 */
function fixtureZip(entries) {
  const locals = [], central = [];
  let offset = 0;
  for (const [name, value] of Object.entries(entries)) {
    const filename = Buffer.from(name), body = Buffer.from(value);
    let crc = 0xffffffff;
    for (const byte of body) {
      crc ^= byte;
      for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    }
    crc = (crc ^ 0xffffffff) >>> 0;
    const local = Buffer.alloc(30), record = Buffer.alloc(46);
    local.writeUInt32LE(0x04034b50); local.writeUInt16LE(20, 4); local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(body.length, 18); local.writeUInt32LE(body.length, 22); local.writeUInt16LE(filename.length, 26);
    record.writeUInt32LE(0x02014b50); record.writeUInt16LE(20, 4); record.writeUInt16LE(20, 6);
    record.writeUInt32LE(crc, 16); record.writeUInt32LE(body.length, 20); record.writeUInt32LE(body.length, 24);
    record.writeUInt16LE(filename.length, 28); record.writeUInt32LE(offset, 42);
    locals.push(local, filename, body); central.push(record, filename);
    offset += local.length + filename.length + body.length;
  }
  const directory = Buffer.concat(central), end = Buffer.alloc(22), count = Object.keys(entries).length;
  end.writeUInt32LE(0x06054b50); end.writeUInt16LE(count, 8); end.writeUInt16LE(count, 10);
  end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, directory, end]);
}

/**
 * 完整 legacy 服务夹具：只替换设备文件 API、平台解压及传输，实际复制、JSON 发布、
 * 提取依赖、JAR结构校验、逐块SHA、内嵌库身份绑定和Maven规格构造均执行生产代码。
 * 文件只位于本次新建的外置宿主目录；每个删除和写入先检查绝对边界，不接触用户实例。
 */
function legacyHarness(options = {}) {
  const fixture = fs.mkdtempSync(path.join(workspaceTempRoot(), 'forge-legacy-'));
  const mcDir = path.join(fixture, 'mc').replaceAll('\\', '/');
  const filesDir = path.join(fixture, 'files').replaceAll('\\', '/');
  const downloads = [], transferFiles = [], copied = [], phases = [];
  const artifact = '1.7.10-10.13.4.1614-1.7.10';
  const ownName = 'net.minecraftforge:forge:' + artifact;
  const ownRelative = 'net/minecraftforge/forge/' + artifact + '/forge-' + artifact + '.jar';
  const target = mcDir + '/libraries/' + ownRelative;
  const body = fixtureZip({ 'fixture.txt': 'verified installer payload\n'.repeat(600) });
  const sha = bytes => createHash('sha1').update(bytes).digest('hex');
  const ownLib = { name: ownName, url: 'https://maven.minecraftforge.net/' };
  if (options.shaConflict) ownLib.downloads = { artifact: { sha1: 'f'.repeat(40) } };
  if (options.sizeConflict) ownLib.downloads = { artifact: { size: body.length + 1 } };
  const version = { id: 'author-version', mainClass: 'net.minecraft.launchwrapper.Launch',
    inheritsFrom: '1.7.10', libraries: [ownLib, { name: 'org.example:ordinary:1.0', url: 'https://repo.example.invalid/' }] };
  const fileRef = 'forge-' + artifact + '-universal.jar';
  const profile = options.method === 1 ? { json: '/version.json' }
    : { install: { path: ownName, filePath: options.unsafeSource ? '../outside.jar' : fileRef }, versionInfo: version };
  const entries = { 'install_profile.json': JSON.stringify(profile) };
  if (options.method === 1) entries['version.json'] = JSON.stringify(version);
  if (!options.missingSource) {
    entries[options.method === 1 ? 'maven/' + ownRelative : fileRef] = options.badSource ? body.subarray(0, body.length - 22) : body;
  }
  // 缺源反例仍让installer本体超过最低体积，失败必须来自内嵌源契约而不是小包判据。
  entries['installer-padding.txt'] = 'controlled installer padding\n'.repeat(600);
  const installerBytes = fixtureZip(entries);
  const inside = name => {
    const resolved = path.resolve(name), root = path.resolve(fixture);
    assert.ok(resolved.startsWith(root + path.sep), 'fixture path escapes its external owner: ' + name);
    return resolved;
  };
  const mkdir = name => fs.mkdirSync(inside(name), { recursive: true });
  const put = (name, bytes) => { mkdir(path.dirname(name)); fs.writeFileSync(inside(name), bytes); };
  mkdir(mcDir); mkdir(filesDir);
  const io = {
    OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, CREATE: fs.constants.O_CREAT, TRUNC: fs.constants.O_TRUNC },
    statSync: name => fs.statSync(inside(name)), lstatSync: name => fs.lstatSync(inside(name)),
    listFileSync: name => fs.readdirSync(inside(name)), readTextSync: name => fs.readFileSync(inside(name), 'utf8'),
    openSync: (name, flags) => ({ fd: fs.openSync(inside(name), flags) }),
    closeSync: file => fs.closeSync(typeof file === 'number' ? file : file.fd),
    readSync: (fd, buffer, opt = {}) => fs.readSync(fd, new Uint8Array(buffer), 0, opt.length ?? buffer.byteLength, opt.offset ?? null),
    writeSync: (fd, bytes) => fs.writeSync(fd, typeof bytes === 'string' ? bytes : new Uint8Array(bytes)),
    mkdirSync: mkdir, unlinkSync: name => fs.unlinkSync(inside(name)),
    copyFileSync(source, destination) {
      fs.copyFileSync(inside(source), inside(destination)); copied.push({ source, destination });
      if (destination === target && options.corruptCopy) {
        const changed = fs.readFileSync(inside(destination));
        if (options.corruptCopy === 'truncate') fs.writeFileSync(inside(destination), changed.subarray(0, changed.length - 22));
        else { changed[60] ^= 1; fs.writeFileSync(inside(destination), changed); }
      }
    },
  };
  const dm = {
    isCaBundleInitialized: () => true,
    async fetchText(url) {
      if (url.endsWith('maven-metadata.xml')) return metadata([artifact]);
      if (url.endsWith('-installer.jar.sha1')) return sha(installerBytes);
      throw new Error('Unexpected full legacy URL: ' + url);
    },
    async createAndWait(spec, progress) {
      downloads.push(spec);
      for (const file of spec.files) {
        if (file.localPath.endsWith('/forge-installer.jar')) {
          put(file.localPath, installerBytes); transferFiles.push(file);
        } else if (file.localPath === target) {
          // Native引擎不是此宿主边界的被测实现：必须看到生产给出的强check，再核对
          // 实际复制字节；没有check就让夹具按普通未发布JAR的404行为失败，防止假绿。
          assert.equal(file.check?.sha1, sha(body), 'bundled Forge spec must carry its verified source SHA-1');
          assert.equal(file.check?.size, body.length, 'bundled Forge spec must carry its verified source size');
          assert.equal(sha(fs.readFileSync(inside(target))), file.check.sha1);
        } else {
          put(file.localPath, body); transferFiles.push(file);
        }
      }
      const view = { success: true, finished: true, aborted: false, failedFiles: [],
        filesDone: spec.files.length, filesTotal: spec.files.length, bytesDone: body.length, bytesTotal: body.length,
        currentFiles: [], currentFile: '', durationMs: 1, speedBps: 0 };
      progress?.(view);
      return view;
    },
  };
  const extra = {
    '@kit.CoreFileKit': { fileIo: io }, '@kit.NetworkKit': { http: {} },
    '@kit.BasicServicesKit': { zlib: { decompressFile(archive, destination, callback) {
      assert.deepEqual(fs.readFileSync(inside(archive)), installerBytes);
      mkdir(destination);
      for (const [name, bytes] of Object.entries(entries)) put(destination + '/' + name, bytes);
      callback(null);
    } } },
    '@kit.CryptoArchitectureKit': { cryptoFramework: { createMd(algorithm) {
      const state = createHash(algorithm.toLowerCase());
      return { updateSync: blob => state.update(blob.data), digestSync: () => ({ data: new Uint8Array(state.digest()) }) };
    } } },
    '../download/DownloadManager': { DownloadManager: { instance: () => dm } },
    './ForgelikeInstaller': {},
    commons: { BMCLAPI_BASE: bmclBase, BMCLAPI_HOST: 'bmclapi2.bangbang93.com', MOJANG_META: 'https://piston-meta.mojang.com',
      DiagnosticPolicy: { isDeveloperBuild: () => false }, AppLogger: log, LogTags: {}, LOG_DOMAIN_MODLOADER: 0,
      fileExistsAndNonEmpty(name) { try { return fs.statSync(inside(name)).size > 0; } catch { return false; } },
      removeDirRecursive(name) { fs.rmSync(inside(name), { recursive: true, force: true }); },
      formatSpeed: () => '', formatError: error => String(error) },
  };
  const load = loader(extra), utils = load('feature_core/src/main/ets/modloader/ForgeInstallerUtils.ets');
  const Service = load('feature_core/src/main/ets/modloader/ForgeService.ets').ForgeService;
  const versionJson = mcDir + '/versions/1.7.10-forge-10.13.4.1614-1.7.10/1.7.10-forge-10.13.4.1614-1.7.10.json';
  return { downloads, transferFiles, copied, phases, utils, target, body, ownName,
    versionJsonPresent: () => fs.existsSync(inside(versionJson)),
    async install() { return new Service().install('1.7.10', '10.13.4.1614', mcDir, value => phases.push(value), filesDir); },
    dispose() { const root = path.resolve(workspaceTempRoot()); assert.ok(path.resolve(fixture).startsWith(root + path.sep)); fs.rmSync(fixture, { recursive: true, force: true }); },
  };
}

/**
 * 每组创建独立服务和模块缓存，避免上一组的正缓存掩盖下一组缺项/刷新行为。
 * snapshots 为各来源连续请求的返回值：数组表示版本列表，Error 表示文本传输故障；
 * 最后一个样本可重复，既保证有界重试可观察，也防止跑进真实网络。
 */
function harness(options = {}) {
  const reads = [], downloads = [], profiles = [], phases = [], logs = [];
  const inspectedPaths = [], mutations = [];
  const files = new Map(Object.entries(options.files ?? {}));
  const directories = new Map(Object.entries(options.directories ?? {}));
  const counts = new Map();
  const snapshots = new Map([
    [officialMetadata, options.official ?? [[]]],
    [mirrorMetadata, options.mirror ?? [[]]],
  ]);
  const dm = {
    async fetchText(url, mirrors, timeoutSeconds) {
      if (snapshots.has(url)) {
        const values = snapshots.get(url);
        const count = counts.get(url) ?? 0;
        counts.set(url, count + 1);
        reads.push({ url, mirrors, timeoutSeconds });
        // 两个来源都已发起后，测试才能取消父任务；释放后继续同一生产 Promise 链。
        if (options.metadataGates?.has(url)) await options.metadataGates.get(url).promise;
        const value = values[Math.min(count, values.length - 1)];
        if (value instanceof Error) throw value;
        return metadata(value);
      }
      // 真实 probeInstallerSha1 同样走此边界；侧车对应传给引擎的完整工件身份。
      if (url.endsWith('-installer.jar.sha1')) {
        reads.push({ url, mirrors, timeoutSeconds });
        return 'a'.repeat(40);
      }
      throw new Error('Unexpected test URL: ' + url);
    },
    async createAndWait(spec) {
      downloads.push(spec);
      // 旧版安装停在可观测下载边界；不能用伪造成功绕开 ZIP/摘要校验后宣称全安装通过。
      throw new Error(fixtureStop);
    },
  };
  const missingFile = () => { throw new Error('fixture path does not exist'); };
  const mutation = operation => (...args) => {
    mutations.push({ operation, args });
    return missingFile();
  };
  const io = {
    OpenMode: { READ_ONLY: 0 },
    statSync(name) {
      inspectedPaths.push(name);
      if (!files.has(name)) return missingFile();
      return { size: Buffer.byteLength(files.get(name)) };
    },
    listFileSync(name) {
      inspectedPaths.push(name);
      if (!directories.has(name)) return missingFile();
      return directories.get(name);
    },
    readTextSync(name) {
      inspectedPaths.push(name);
      if (!files.has(name)) return missingFile();
      return String(files.get(name));
    },
    lstatSync: missingFile, openSync: missingFile,
    unlinkSync: mutation('unlink'), mkdirSync: mutation('mkdir'), copyFileSync: mutation('copy'),
    renameSync: mutation('rename'), writeSync: mutation('write'),
  };
  const appLog = {};
  for (const level of ['info', 'warn', 'error', 'debug']) {
    appLog[level] = (tag, message) => logs.push({ level, tag, message });
  }
  const extra = {
    '@kit.CoreFileKit': { fileIo: io },
    '@kit.NetworkKit': { http: {} },
    '@kit.CryptoArchitectureKit': { cryptoFramework: {} },
    '../download/DownloadManager': { DownloadManager: { instance: () => dm } },
    './ForgelikeInstaller': { ForgelikeInstaller: { async install(profile) {
      profiles.push(profile);
      return { success: true, versionId: profile.versionId };
    } } },
    commons: {
      BMCLAPI_BASE: bmclBase,
      BMCLAPI_HOST: 'bmclapi2.bangbang93.com', MOJANG_META: 'https://piston-meta.mojang.com',
      DiagnosticPolicy: { isDeveloperBuild: () => false },
      AppLogger: appLog, LogTags: { MOD_MAVEN: 'Maven', MOD_FORGE_INSTALLER: 'Installer' },
      LOG_DOMAIN_MODLOADER: 0,
      // JDK纪元查询不决定发布坐标；完整引擎和实际运行时另由其既有测试验证。
      requiredJdkMajorForMc: () => 17,
      fileExistsAndNonEmpty: name => files.has(name) && Buffer.byteLength(files.get(name)) > 0,
      removeDirRecursive: mutation('remove-directory'), formatSpeed: () => '',
      pickInstalledJdkMajor: (required, installed) => installed.find(major => major >= required) ?? 0,
      formatError: error => String(error),
    },
  };
  if (options.realModern) {
    // 取消回归执行共享安装器生产代码。只替换设备能力和最终 processor 边界，首个
    // 生产进度回调前的运行时检查仍使用内存IO，不能由引擎成功替身伪造取消响应。
    delete extra['./ForgelikeInstaller'];
    extra['./ForgelikeNative'] = { forgeNative: () => ({ getRecommendedXmx: () => 2048 }) };
    extra['./ForgelikeProcessorRunner'] = { ForgelikeProcessorRunner: {} };
  }
  const load = loader(extra);
  const parser = load('feature_core/src/main/ets/modloader/ForgeArtifactResolver.ets');
  const Service = load('feature_core/src/main/ets/modloader/ForgeService.ets').ForgeService;
  const service = new Service();
  return {
    load, parser, service, reads, downloads, profiles, phases, logs, inspectedPaths, mutations,
    metadataReads: () => reads.filter(read => snapshots.has(read.url)),
    async install(game, forge) {
      return service.install(game, forge, '/fixture/mc', progress => phases.push(progress), '/fixture/files');
    },
  };
}

/** 从真实消费边界校验三来源、目录与工件名，避免只断言解析器返回值而漏掉旧接线。 */
function assertInstallerUrls(urls, artifactVersion) {
  const relative = '/net/minecraftforge/forge/' + artifactVersion
    + '/forge-' + artifactVersion + '-installer.jar';
  assert.deepEqual(Array.from(urls), [
    bmclBase + '/maven' + relative, bmclBase + '/libraries' + relative,
    'https://maven.minecraftforge.net' + relative,
  ]);
}

/** 每例在断言全部通过后记录成功；失败立即以非零退出交给总门禁。 */
async function test(name, body) {
  await body();
  cases.push(name);
  console.log('PASS: ' + name);
}

// 回放同一份正式 ArkTS 测试体；宿主断言适配只替换 Hypium API，不复制解析算法。
let unitCases = 0;
const unitHarness = harness();
const unitLoad = loader({ feature_core: unitHarness.parser, '@ohos/hypium': {
  describe: (_name, body) => body(),
  it: (_name, _level, body) => { body(); unitCases++; },
  expect: actual => ({ assertEqual: expected => assert.equal(actual, expected),
    assertTrue: () => assert.equal(actual, true), assertFalse: () => assert.equal(actual, false) }),
} });
unitLoad('entry/src/test/ForgeArtifactResolver.test.ets').default();
console.log('PASS: 正式 ForgeArtifactResolver Hypium 测试体宿主回放 ' + unitCases + ' 项');

await test('Mercury Landing 短版本经真实 legacy 入口下载完整分支坐标', async () => {
  const h = harness({ official: [[]], mirror: [['1.7.10-10.13.4.1614-1.7.10']] });
  const result = await h.install('1.7.10', '10.13.4.1614');
  assert.equal(h.downloads.length, 1);
  assert.equal(h.profiles.length, 0);
  assertInstallerUrls(h.downloads[0].files[0].urls, '1.7.10-10.13.4.1614-1.7.10');
  assert.match(h.downloads[0].name, /1\.7\.10-10\.13\.4\.1614-1\.7\.10/);
  assert.equal(h.downloads[0].files[0].check.sha1, 'a'.repeat(40));
  assert.equal(result.versionId, '1.7.10-forge-10.13.4.1614-1.7.10');
  assert.equal(result.success, false);
  assert.match(result.error, /fixture stopped/);
  assert.equal(h.metadataReads().length, 2, '正常唯一匹配不应反复刷新 metadata');
  assert.equal(h.reads.filter(read => read.url.endsWith('-installer.jar.sha1')).length, 3);
});

await test('mc172 分支经实际 legacy 下载规格保留，与游戏版本后缀不同', async () => {
  const h = harness({ official: [['1.7.2-10.12.2.1161-mc172']] });
  await h.install('1.7.2', '10.12.2.1161');
  assertInstallerUrls(h.downloads[0].files[0].urls, '1.7.2-10.12.2.1161-mc172');
});

await test('无分支 legacy 控制仍传原有有效工件地址', async () => {
  const h = harness({ official: [['1.12.2-14.23.5.2864']] });
  await h.install('1.12.2', '14.23.5.2864');
  assertInstallerUrls(h.downloads[0].files[0].urls, '1.12.2-14.23.5.2864');
});

await test('现代完整 artifact 输入归一化后走共享引擎，并贯穿 profile 所有身份字段', async () => {
  const h = harness({ official: [['1.20.1-47.4.26']] });
  const result = await h.install('1.20.1', '1.20.1-47.4.26');
  assert.equal(h.profiles.length, 1);
  assert.equal(h.downloads.length, 0);
  const profile = h.profiles[0];
  assert.equal(profile.loaderVersion, '47.4.26');
  assert.equal(profile.artifactVersion, '1.20.1-47.4.26');
  assert.equal(profile.loaderCoordPrefix, 'net.minecraftforge:forge:1.20.1-47.4.26:client');
  assert.equal(profile.versionId, '1.20.1-forge-47.4.26');
  assertInstallerUrls(profile.installerUrls, '1.20.1-47.4.26');
  assert.equal(result.versionId, profile.versionId);
});

await test('当前预发布 MC 完整 artifact 正确剥前缀后走现代共享引擎', async () => {
  const h = harness({ official: [['1.20.2-pre4-48.0.0']] });
  const result = await h.install('1.20.2-pre4', '1.20.2-pre4-48.0.0');
  assert.equal(result.success, true);
  assert.equal(h.profiles.length, 1);
  assert.equal(h.downloads.length, 0);
  const profile = h.profiles[0];
  assert.equal(profile.loaderVersion, '48.0.0');
  assert.equal(profile.artifactVersion, '1.20.2-pre4-48.0.0');
  assert.equal(profile.versionId, '1.20.2-pre4-forge-48.0.0');
  assertInstallerUrls(profile.installerUrls, '1.20.2-pre4-48.0.0');
});

await test('现代 metadata 带发布分支时，安装器与生成库坐标都消费完整身份', async () => {
  const h = harness({ official: [['1.20.1-47.4.26-fixture']] });
  await h.install('1.20.1', '47.4.26');
  assert.equal(h.profiles.length, 1);
  const profile = h.profiles[0];
  assert.equal(profile.loaderVersion, '47.4.26-fixture');
  assert.equal(profile.artifactVersion, '1.20.1-47.4.26-fixture');
  assert.equal(profile.loaderCoordPrefix, 'net.minecraftforge:forge:1.20.1-47.4.26-fixture:client');
  assert.equal(profile.versionId, '1.20.1-forge-47.4.26-fixture');
  assertInstallerUrls(profile.installerUrls, '1.20.1-47.4.26-fixture');
});

await test('legacy 已装完整库按真实发布目录检查，短请求不会导致重复下载', async () => {
  const versionId = '1.7.10-forge-10.13.4.1614-1.7.10';
  const jsonPath = '/fixture/mc/versions/' + versionId + '/' + versionId + '.json';
  const libDir = '/fixture/mc/libraries/net/minecraftforge/forge/1.7.10-10.13.4.1614-1.7.10';
  const jarName = 'forge-1.7.10-10.13.4.1614-1.7.10-universal.jar';
  const h = harness({ official: [['1.7.10-10.13.4.1614-1.7.10']],
    files: { [jsonPath]: JSON.stringify({ id: versionId, mainClass: 'net.minecraft.launchwrapper.Launch',
      inheritsFrom: '1.7.10', libraries: [] }), [libDir + '/' + jarName]: Buffer.alloc(10001) },
    directories: { [libDir]: [jarName] } });
  const result = await h.install('1.7.10', '10.13.4.1614');
  assert.equal(result.success, true);
  assert.equal(result.versionId, versionId);
  assert.equal(h.downloads.length, 0);
  assert.ok(h.inspectedPaths.includes(libDir));
  assert.ok(h.inspectedPaths.includes(libDir + '/' + jarName));
});

await test('legacy 只有旧短坐标库目录时不能把正确分支版本误判为已完整安装', async () => {
  const versionId = '1.7.10-forge-10.13.4.1614-1.7.10';
  const jsonPath = '/fixture/mc/versions/' + versionId + '/' + versionId + '.json';
  const wrongLibDir = '/fixture/mc/libraries/net/minecraftforge/forge/1.7.10-10.13.4.1614';
  const wrongJarName = 'forge-1.7.10-10.13.4.1614-universal.jar';
  const h = harness({ official: [['1.7.10-10.13.4.1614-1.7.10']],
    files: { [jsonPath]: JSON.stringify({ id: versionId, mainClass: 'net.minecraft.launchwrapper.Launch',
      inheritsFrom: '1.7.10', libraries: [] }), [wrongLibDir + '/' + wrongJarName]: Buffer.alloc(10001) },
    directories: { [wrongLibDir]: [wrongJarName] } });
  const result = await h.install('1.7.10', '10.13.4.1614');
  assert.equal(result.success, false);
  assert.equal(h.downloads.length, 1);
  assertInstallerUrls(h.downloads[0].files[0].urls, '1.7.10-10.13.4.1614-1.7.10');
});

await test('显式分支安装跳过列表网络查询并保持 canonical 身份', async () => {
  const h = harness();
  const result = await h.install('1.7.10', '1.7.10-10.13.4.1614-1.7.10');
  assert.equal(h.metadataReads().length, 0);
  assertInstallerUrls(h.downloads[0].files[0].urls, '1.7.10-10.13.4.1614-1.7.10');
  assert.equal(result.versionId, '1.7.10-forge-10.13.4.1614-1.7.10');
});

await test('列表官方与落后镜像合并，已有正向缓存供安装复用', async () => {
  const h = harness({ official: [['1.20.1-47.4.26']], mirror: [['1.7.10-10.13.4.1614-1.7.10']] });
  const modern = await h.service.getLoaderVersions('1.20.1');
  const legacy = await h.service.getLoaderVersions('1.7.10');
  assert.equal(modern.length, 1);
  assert.equal(modern[0].loaderVersion, '47.4.26');
  assert.equal(legacy[0].loaderVersion, '10.13.4.1614-1.7.10');
  await h.install('1.7.10', '10.13.4.1614');
  assert.equal(h.metadataReads().length, 2, '已有唯一正缓存不应额外联网');
  assertInstallerUrls(h.downloads[0].files[0].urls, '1.7.10-10.13.4.1614-1.7.10');
});

await test('列表缓存缺项时有限刷新取得发布分支，不永久缓存缺失', async () => {
  const h = harness({ official: [['1.12.2-14.23.5.2864'], ['1.7.10-10.13.4.1614-1.7.10']],
    mirror: [[], []] });
  await h.service.getLoaderVersions('1.7.10');
  await h.install('1.7.10', '10.13.4.1614');
  assert.equal(h.metadataReads().length, 4);
  assertInstallerUrls(h.downloads[0].files[0].urls, '1.7.10-10.13.4.1614-1.7.10');
});

await test('缓存歧义有限刷新发现精确无分支项后，用明确身份进入下载', async () => {
  const h = harness({ official: [['1.7.2-10.12.2.1161-mc172', '1.7.2-10.12.2.1161-other'],
    ['1.7.2-10.12.2.1161']], mirror: [[], []] });
  await h.service.getLoaderVersions('1.7.2');
  await h.install('1.7.2', '10.12.2.1161');
  assert.equal(h.metadataReads().length, 4);
  assertInstallerUrls(h.downloads[0].files[0].urls, '1.7.2-10.12.2.1161');
});

await test('刷新列表缺少旧正分支不能证明其撤销，仍保留歧义并阻止误选', async () => {
  const h = harness({ official: [['1.7.2-10.12.2.1161-mc172', '1.7.2-10.12.2.1161-other'],
    ['1.7.2-10.12.2.1161-mc172']], mirror: [[], []] });
  await h.service.getLoaderVersions('1.7.2');
  const result = await h.install('1.7.2', '10.12.2.1161');
  assert.equal(h.metadataReads().length, 4);
  assert.equal(result.success, false);
  assert.match(result.error, /分支|歧义|多个/);
  assert.equal(h.downloads.length, 0);
  assert.equal(h.profiles.length, 0);
});

await test('刷新后仍多分支时返回可解释错误并阻止下载安装器', async () => {
  const h = harness({ official: [['1.7.2-10.12.2.1161-mc172', '1.7.2-10.12.2.1161-other']] });
  const result = await h.install('1.7.2', '10.12.2.1161');
  assert.equal(result.success, false);
  assert.match(result.error, /分支|歧义|多个/);
  assert.equal(h.downloads.length, 0);
  assert.equal(h.profiles.length, 0);
  assert.ok(h.metadataReads().length <= 4, '失败必须有界，不能循环刷新');
});

await test('两来源失败或缺项仍仅使用精确请求坐标并明确标注缺乏 metadata 匹配', async () => {
  const h = harness({ official: [new Error('fixture DNS failure')], mirror: [[]] });
  const result = await h.install('1.20.1', '47.4.26');
  assert.equal(h.profiles.length, 1);
  assert.equal(h.profiles[0].artifactVersion, '1.20.1-47.4.26');
  assertInstallerUrls(h.profiles[0].installerUrls, '1.20.1-47.4.26');
  assert.equal(result.success, true, '这里只表示调用了共享引擎边界，完整安装不在本测试范围');
  assert.ok(h.logs.some(entry => /metadata|元数据|匹配/.test(entry.message)
    && /fallback|回退|未|false|unmatched|exact/.test(entry.message)), '兼容直接指定工件需可辨认日志');
  assert.ok(h.metadataReads().length <= 4);
});

await test('单源查询设10秒上限，失败来源不阻止另一来源发现真正发布项', async () => {
  const h = harness({ official: [new Error('fixture timed out')], mirror: [['1.8.9-11.15.1.2318-1.8.9']] });
  await h.install('1.8.9', '11.15.1.2318');
  assertInstallerUrls(h.downloads[0].files[0].urls, '1.8.9-11.15.1.2318-1.8.9');
  assert.ok(h.metadataReads().length > 0);
  assert.ok(h.metadataReads().every(read => read.timeoutSeconds === 10));
});

await test('网络失败不会负缓存：同一服务稍后取得 metadata 后改用正确分支', async () => {
  const h = harness({ official: [new Error('fixture offline'), ['1.7.10-10.13.4.1614-1.7.10']],
    mirror: [new Error('fixture offline'), []] });
  await h.install('1.7.10', '10.13.4.1614');
  const before = h.metadataReads().length;
  await h.install('1.7.10', '10.13.4.1614');
  assert.ok(h.metadataReads().length > before);
  assertInstallerUrls(h.downloads.at(-1).files[0].urls, '1.7.10-10.13.4.1614-1.7.10');
});

await test('非法请求在查询和下载前失败，避免跨路径身份污染', async () => {
  const h = harness();
  const result = await h.install('1.7.10', '../10.13.4.1614');
  assert.equal(result.success, false);
  assert.equal(h.metadataReads().length, 0);
  assert.equal(h.downloads.length, 0);
  assert.equal(h.profiles.length, 0);
});

await test('跨 MC 预发布完整 artifact 在网络及两条安装分支之前被拒绝', async () => {
  for (const artifact of ['1.20.2-pre4-48.0.0', '1.20.2-rc1-48.0.0', '1.20.2-snapshot-48.0.0']) {
    const h = harness();
    const result = await h.install('1.20.1', artifact);
    assert.equal(result.success, false, artifact);
    assert.equal(h.reads.length, 0, artifact + ' 不得查询 metadata 或校验侧车');
    assert.equal(h.downloads.length, 0, artifact + ' 不得送旧版下载');
    assert.equal(h.profiles.length, 0, artifact + ' 不得送现代引擎');
  }
});

/**
 * 模拟 ModloaderPhase 的取消检查：两来源文本都在等待时取消，待 metadata 真正
 * 返回后，由已有生产进度回调抛出生产 CancelledError；必须观察同一安装 Promise
 * 真实拒绝收敛，并证明取消之后没有侧车探测、文件下载或写入。
 */
async function cancellationDuringMetadata(realModern) {
  const gates = new Map([[officialMetadata, deferred()], [mirrorMetadata, deferred()]]);
  const game = realModern ? '1.20.1' : '1.7.10';
  const forge = realModern ? '47.4.26' : '10.13.4.1614';
  const artifact = realModern ? '1.20.1-47.4.26' : '1.7.10-10.13.4.1614-1.7.10';
  const h = harness({ official: [[artifact]], metadataGates: gates, realModern,
    files: realModern ? {
      '/fixture/files/jdk/17/release': 'JAVA_VERSION="17"',
      '/fixture/files/jdk/17/lib/server/libjvm.so': 'fixture runtime',
      '/fixture/files/jdk/17/lib/modules': 'fixture modules',
    } : {} });
  const CancelledError = h.load('commons/src/main/ets/common/Errors.ets').CancelledError;
  let cancelled = false, settled = false;
  const progressPhases = [];
  const operation = h.service.install(game, forge, '/fixture/mc', progress => {
    progressPhases.push(progress.phase);
    if (cancelled) throw new CancelledError();
  }, '/fixture/files');
  const outcome = operation.then(value => { settled = true; return { value }; },
    error => { settled = true; return { error }; });
  await Promise.resolve();
  assert.equal(h.metadataReads().length, 2, '两个生产fetchText都已发起才进入取消窗口');
  assert.equal(settled, false, 'metadata仍被挂起，安装Promise必须尚未收敛');
  assert.equal(progressPhases.length, 0, '取消点确实位于新增metadata等待窗口');
  cancelled = true;
  for (const gate of gates.values()) gate.resolve();
  const result = await outcome;
  assert.equal(settled, true, '释放真实metadata后安装Promise必须完成收敛');
  assert.ok(result.error instanceof CancelledError, '同一Promise必须以生产CancelledError拒绝');
  assert.ok(progressPhases.includes('downloading_installer'), '实际安装分支的生产回调消费了取消状态');
  assert.equal(h.reads.filter(read => read.url.endsWith('-installer.jar.sha1')).length, 0);
  assert.equal(h.downloads.length, 0);
  assert.equal(h.mutations.length, 0, '取消后不得删除、创建、复制或写入任何实例文件');
  if (realModern) {
    assert.ok(h.inspectedPaths.includes('/fixture/files/jdk/17/lib/modules'),
      '现代取消回归必须真实经过共享引擎前置检查，不能使用profile成功替身');
  }
}

await test('legacy metadata 等待中取消，真实Promise拒绝且不探测侧车、不下载或写文件',
  () => cancellationDuringMetadata(false));
await test('modern metadata 等待中取消，经真实共享引擎回调拒绝且不探测侧车、不下载或写文件',
  () => cancellationDuringMetadata(true));

await test('完整 legacy 方式2实际复制内嵌 Forge，并将源SHA与size贯穿真实Maven下载规格', async () => {
  const h = legacyHarness();
  try {
    const result = await h.install();
    assert.equal(result.success, true, result.error);
    assert.equal(h.versionJsonPresent(), true);
    assert.equal(h.copied.filter(copy => copy.destination === h.target).length, 1);
    const batch = h.downloads.find(spec => spec.name.startsWith('Maven libraries'));
    assert.ok(batch, '必须执行生产提库及Maven批量规格，不从测试绕过统一下载链');
    const ownSpec = batch.files.find(file => file.localPath === h.target);
    assert.equal(ownSpec.check.sha1, createHash('sha1').update(h.body).digest('hex'));
    assert.equal(ownSpec.check.size, h.body.length);
    assert.equal(h.transferFiles.filter(file => file.localPath === h.target).length, 0);
    assert.equal(h.transferFiles.length, 2, 'installer及未捆绑普通依赖仍经过传输边界');
    const ordinary = batch.files.find(file => file.localPath.endsWith('/ordinary-1.0.jar'));
    assert.ok(ordinary);
    assert.equal(ordinary.check, undefined, '未提供来源证据的普通依赖不能继承Forge强check');
  } finally { h.dispose(); }
});

await test('完整 legacy 方式1实际复制maven同声明库，附加check且保留其他普通依赖远程下载', async () => {
  const h = legacyHarness({ method: 1 });
  try {
    const result = await h.install();
    assert.equal(result.success, true, result.error);
    assert.equal(h.copied.filter(copy => copy.destination === h.target).length, 1);
    const batch = h.downloads.find(spec => spec.name.startsWith('Maven libraries'));
    assert.ok(batch.files.find(file => file.localPath === h.target)?.check?.sha1);
    assert.equal(h.transferFiles.filter(file => file.localPath === h.target).length, 0);
    assert.ok(h.transferFiles.some(file => file.localPath.endsWith('/ordinary-1.0.jar')));
  } finally { h.dispose(); }
});

await test('方式2承诺内嵌源缺失或来源路径非法时不写version JSON，不伪装安装成功', async () => {
  for (const options of [{ missingSource: true }, { unsafeSource: true }]) {
    const h = legacyHarness(options);
    try {
      const result = await h.install();
      assert.equal(result.success, false);
      assert.equal(h.versionJsonPresent(), false);
      assert.equal(h.downloads.length, 1, '仅完成已验证installer传输，不进入Maven依赖下载');
    } finally { h.dispose(); }
  }
});

await test('本次installer内部JAR缺失EOCD时拒绝建立可信内嵌库身份', async () => {
  const h = legacyHarness({ badSource: true });
  try {
    const result = await h.install();
    assert.equal(result.success, false);
    assert.match(result.error, /内嵌库校验失败|JAR 不完整/);
    assert.equal(h.downloads.length, 1);
  } finally { h.dispose(); }
});

await test('实际复制dst截断或同大小改写时拒绝，从结构及真实SHA差异识别坏副本', async () => {
  for (const corruptCopy of ['truncate', 'rewrite']) {
    const h = legacyHarness({ corruptCopy });
    try {
      const result = await h.install();
      assert.equal(result.success, false, corruptCopy);
      assert.match(result.error, /内嵌库校验失败/);
      assert.equal(h.downloads.length, 1, '不把坏副本转为可信check或送入后续下载');
    } finally { h.dispose(); }
  }
});

await test('发布metadata摘要或大小与实际内嵌JAR冲突时拒绝，不能静默覆写声明', async () => {
  for (const options of [{ shaConflict: true }, { sizeConflict: true }]) {
    const h = legacyHarness(options);
    try {
      const result = await h.install();
      assert.equal(result.success, false);
      assert.match(result.error, /摘要或大小.*冲突/);
      assert.equal(h.downloads.length, 1);
    } finally { h.dispose(); }
  }
});

await test('现代Forge universal仍由生产提库和Maven规格保留远程URL，不套用legacy绑定', async () => {
  const artifact = '1.20.1-47.4.26';
  const name = 'net.minecraftforge:forge:' + artifact + ':universal';
  const relative = 'net/minecraftforge/forge/' + artifact + '/forge-' + artifact + '-universal.jar';
  const directUrl = 'https://maven.minecraftforge.net/' + relative;
  const h = harness({ files: { '/fixture/profile.json': JSON.stringify({ libraries: [
    { name, downloads: { artifact: { url: directUrl, path: relative, sha1: 'b'.repeat(40), size: 12345 } } }
  ] }), '/fixture/version.json': '{}' } });
  const utils = h.load('feature_core/src/main/ets/modloader/ForgeInstallerUtils.ets');
  const builder = h.load('feature_core/src/main/ets/modloader/MavenSpecBuilder.ets');
  const libs = utils.extractLibrariesFromInstallerJson('/fixture/profile.json', '/fixture/version.json', artifact,
    'net.minecraftforge:forge:' + artifact + ':client');
  assert.equal(libs.length, 1);
  assert.equal(libs[0].name, name);
  const specs = builder.buildSpecsForLibs(libs, '/fixture/libraries').specs;
  assert.equal(specs.length, 1);
  assert.ok(specs[0].urls.includes(directUrl));
  assert.equal(specs[0].check.sha1, 'b'.repeat(40));
  assert.equal(specs[0].check.size, 12345);
});

console.log('Forge 发布身份与安装接线回归通过：' + unitCases + ' 项正式 ArkTS 断言组，'
  + cases.length + ' 组生产 Forge 安装及接线。');
