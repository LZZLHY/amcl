/**
 * 游戏导出真实业务闭环：POSIX沙箱映射到外置宿主夹具，执行生产coordinator/inspector、
 * 全部纯计划模块、AtomicFileWriter、ZIP64 writer与独立校验器。只替换SDK边界及可控Native下载端。
 * 通过独立Python zipfile检查最终URI文件；任务成功、取消、失败均核对源树及owner收敛。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { crc32, deflateRawSync, inflateRawSync } from 'node:zlib';
import compiler from './lib/ets-compiler.mjs';
import { PROJECT_ROOT, resolveWorkspacePath } from './lib/workspace-paths.mjs';

const digest = (bytes, kind = 'sha1') => crypto.createHash(kind).update(bytes).digest('hex');

/** 处理器/安装器夹具使用独立Node压缩器构造经典ZIP；不调用被测归档writer生成输入。 */
function lifecycleJar(entries) {
  const localParts = [], centralParts = []; let offset = 0;
  for (const [name, value] of Object.entries(entries)) {
    const filename = Buffer.from(name), data = Buffer.from(value), compressed = deflateRawSync(data), crc = crc32(data);
    const local = Buffer.alloc(30), central = Buffer.alloc(46);
    local.writeUInt32LE(0x04034b50); local.writeUInt16LE(20, 4); local.writeUInt16LE(2048, 6); local.writeUInt16LE(8, 8);
    local.writeUInt32LE(crc, 14); local.writeUInt32LE(compressed.length, 18); local.writeUInt32LE(data.length, 22); local.writeUInt16LE(filename.length, 26);
    central.writeUInt32LE(0x02014b50); central.writeUInt16LE(20, 4); central.writeUInt16LE(20, 6); central.writeUInt16LE(2048, 8); central.writeUInt16LE(8, 10);
    central.writeUInt32LE(crc, 16); central.writeUInt32LE(compressed.length, 20); central.writeUInt32LE(data.length, 24); central.writeUInt16LE(filename.length, 28); central.writeUInt32LE(offset, 42);
    localParts.push(local, filename, compressed); centralParts.push(central, filename); offset += local.length + filename.length + compressed.length;
  }
  const central = Buffer.concat(centralParts), end = Buffer.alloc(22), count = Object.keys(entries).length;
  end.writeUInt32LE(0x06054b50); end.writeUInt16LE(count, 8); end.writeUInt16LE(count, 10); end.writeUInt32LE(central.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...localParts, central, end]);
}

/** SDK只替换解压动作；随后仍由生产JarVerifier读回CRC，替身不授予文件可信身份。 */
function lifecycleExtract(bytes, output) {
  const count = bytes.readUInt16LE(bytes.length - 12); let cursor = bytes.readUInt32LE(bytes.length - 6);
  for (let index = 0; index < count; index++) {
    const size = bytes.readUInt32LE(cursor + 20), local = bytes.readUInt32LE(cursor + 42), nameSize = bytes.readUInt16LE(cursor + 28);
    const extra = bytes.readUInt16LE(cursor + 30), comment = bytes.readUInt16LE(cursor + 32), method = bytes.readUInt16LE(cursor + 10);
    const name = bytes.subarray(cursor + 46, cursor + 46 + nameSize).toString('utf8'), target = path.resolve(output, name);
    assert(target.startsWith(output + path.sep));
    if (name.endsWith('/')) fs.mkdirSync(target, { recursive: true });
    else { const start = local + 30 + bytes.readUInt16LE(local + 26) + bytes.readUInt16LE(local + 28), content = bytes.subarray(start, start + size);
      fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, method === 8 ? inflateRawSync(content) : content); }
    cursor += 46 + nameSize + extra + comment;
  }
}

/** 下载和活动队列由可控端口提供；源树、JSON、选择、哈希、快照和归档始终执行真实业务。 */
function fixture({ fabric = false, missingLibrary = false, nativeHashes = false } = {}) {
  const parent = resolveWorkspacePath('run', 'export-lifecycle-tests'); fs.mkdirSync(parent, { recursive: true });
  const directory = fs.mkdtempSync(path.join(parent, 'amcl-export-life-'));
  const modules = new Map(), openFiles = new Map(), directoryFiles = new Map(); let nextDirectoryFd = -100;
  const state = { gameRunning: false, desktopState: 0, registryTasks: [], downloads: [], registryLease: 0, versionLease: 0,
    pickerCancel: false, pickerCalls: 0, downloadCalls: 0, downloadPlans: [], purges: 0, cancelledDownloads: new Set(),
    purgeBlockedIds: new Set(), beforeSidecar: null, beforeOwnerRelease: null,
    // FileIO仍是平台端口；可控等待只用于确定性复现，不能在这里复制目录helper判断。
    beforeDirectoryLstat: null, beforeDirectoryMkdir: null, directoryStatOverrides: new Map(), mkdirCalls: [], mkdirConflicts: [],
    // 宿主Windows不能创建C:ghost等真实POSIX名称，只在SDK枚举端口补充返回值；
    // 选择/发现/检查仍完整执行生产实现，不由fixture决定错误范围是否被选中。
    listFileAdditions: new Map(),
    // 默认保持既有端口夹具；来源排序专项另接生产Maven builder和真实偏好状态。
    // 显式映射用于逐工件脏候选/空候选反例，不能用同一个URL掩盖串件或顺序覆盖。
    mavenCandidates: new Map(), useProductionMavenCandidates: false, mavenCalls: [], sidecarCalls: [],
    selectedUri: 'content://picker/new-file', targetWriteFailure: false, targetWritten: 0, stages: [], onRead: null, onWrite: null,
    beforeAsyncWrite: null, beforeAsyncFsync: null,
    // 仅快照收敛专项开启真实wrapper端口；独立job/release门不能用完成Promise替代owner退出。
    nativeHashJobs: new Map(), nativeHashReleased: new Set(), nativeHashCalls: [], nativeHashReleaseGate: null,
    errors: [], history: [], purgeAllowed: true, recordFailure: '', recordFailureUsed: false,
    processorCalls: 0, processor: null, jit: true, badInstallerSha: false,
    // 历史的提交边界可延迟到Sheet关闭后；只在提交成功后发布LRU，模拟Preferences的耐久语义。
    historyInitGate: null, historyAddGate: null, historyInitStarted: false, historyAddStarted: false, historyWriteFailure: '',
    // FileUri只作为SDK显示元数据边界；未知content URI必须由生产代码保守保持空名。
    fileUriCalls: [], fileUriFailure: false, fileUriName: '用户改名的导出文件.mrpack' };
  function physical(p) {
    if (p.startsWith('content://')) return path.join(directory, 'picked', p.substring('content://'.length).replaceAll('/', '_'));
    if (p.startsWith('file://docs/storage/Users/currentUser/')) return path.join(directory, 'picked', 'document-picker-output');
    assert(p.startsWith('/'), 'production must use a canonical sandbox path: ' + p);
    const mapped = path.resolve(directory, '.' + p); assert(mapped.startsWith(directory + path.sep) || mapped === directory); return mapped;
  }
  function call(p, fn) { try { return fn(physical(p)); } catch (e) { if (e.code === 'ENOENT') e.code = 13900002; throw e; } }
  function stat(p, link = false) {
    const s = typeof p === 'number' ? directoryFiles.has(p) ? fs.statSync(physical(directoryFiles.get(p))) : fs.fstatSync(p)
      : call(p, name => link ? fs.lstatSync(name) : fs.statSync(name));
    // SDK Stat.ino确实为bigint；单独取宿主的无损inode，不能用number端口令强身份
    // 复用在宿主悄悄失效，也不能先经过Number舍入再把失真的值补成bigint。
    const inode = typeof p === 'number' ? directoryFiles.has(p)
      ? fs.statSync(physical(directoryFiles.get(p)), { bigint: true }).ino : fs.fstatSync(p, { bigint: true }).ino
      : call(p, name => link ? fs.lstatSync(name, { bigint: true }).ino : fs.statSync(name, { bigint: true }).ino);
    return { size: s.size, ino: inode, mtime: s.mtimeMs, ctime: s.ctimeMs,
      mtimeNs: BigInt(Math.round(s.mtimeMs * 1e6)), ctimeNs: BigInt(Math.round(s.ctimeMs * 1e6)),
      isFile: () => s.isFile(), isDirectory: () => s.isDirectory(), isSymbolicLink: () => s.isSymbolicLink() };
  }
  /**
   * HarmonyOS递归mkdir仍声明末端存在可抛13900015；先按lstat保留文件/悬空链接占位，
   * 不让Node recursive=true自动吞掉这项平台错误。父层递归操作仍交宿主文件系统。
   */
  function platformMkdir(p, recursive) {
    call(p, value => {
      try {
        fs.lstatSync(value);
        state.mkdirConflicts.push(p);
        throw Object.assign(new Error('File exists'), { code: 13900015 });
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
      fs.mkdirSync(value, { recursive });
    });
  }
  const fileIo = {
    OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, READ_WRITE: 2, CREATE: 64, NOFOLLOW: 131072 },
    async access(p) { return fs.existsSync(physical(p)); }, accessSync(p) { return fs.existsSync(physical(p)); },
    async stat(p) { return stat(p); }, statSync(p) { return stat(p); },
    async lstat(p) {
      if (state.beforeDirectoryLstat) await state.beforeDirectoryLstat(p);
      if (state.directoryStatOverrides.has(p)) return state.directoryStatOverrides.get(p);
      return stat(p, true);
    }, lstatSync(p) { return stat(p, true); },
    async readText(p) { if (state.beforeReadText) await state.beforeReadText(p); return call(p, value => fs.readFileSync(value, 'utf8')); }, readTextSync(p) { return call(p, value => fs.readFileSync(value, 'utf8')); },
    async copyFile(source, target) { await fs.promises.copyFile(physical(source), physical(target)); },
    async listFile(p) { return call(p, value => fs.readdirSync(value)).concat(state.listFileAdditions.get(p) ?? []); },
    listFileSync(p) { return call(p, value => fs.readdirSync(value)).concat(state.listFileAdditions.get(p) ?? []); },
    async mkdir(p, recursive = false) {
      state.mkdirCalls.push(p);
      if (state.beforeDirectoryMkdir) await state.beforeDirectoryMkdir(p);
      platformMkdir(p, recursive);
    }, mkdirSync(p, recursive = false) { platformMkdir(p, recursive); },
    async copyFile(a, b) { fs.copyFileSync(physical(a), physical(b)); },
    async unlink(p) { call(p, fs.unlinkSync); }, unlinkSync(p) { call(p, fs.unlinkSync); },
    async rmdir(p) { call(p, fs.rmdirSync); }, rmdirSync(p) { call(p, fs.rmdirSync); },
    renameSync(a, b) { fs.renameSync(physical(a), physical(b)); },
    openSync(p, flags = 0) {
      if (fs.existsSync(physical(p)) && fs.statSync(physical(p)).isDirectory()) {
        const fd = nextDirectoryFd--; directoryFiles.set(fd, p); openFiles.set(fd, p); return { fd };
      }
      if ((flags & 131072) && fs.existsSync(physical(p)) && fs.lstatSync(physical(p)).isSymbolicLink()) throw new Error('ELOOP');
      const fd = call(p, value => fs.openSync(value, flags & 64 ? 'w' : flags & 2 ? 'r+' : flags & 1 ? 'w' : 'r'));
      openFiles.set(fd, p); return { fd };
    },
    async open(p, flags = 0) { return fileIo.openSync(p, flags); },
    closeSync(value) { const fd = typeof value === 'number' ? value : value.fd;
      if (!directoryFiles.delete(fd)) fs.closeSync(fd); openFiles.delete(fd); },
    async close(value) { fileIo.closeSync(value); },
    readSync(fd, buffer, options = {}) {
      if (state.onRead) state.onRead(openFiles.get(fd));
      return fs.readSync(fd, Buffer.from(buffer), 0, options.length ?? buffer.byteLength, options.offset ?? null);
    },
    async read(fd, buffer, options = {}) { return fileIo.readSync(fd, buffer, options); },
    writeSync(fd, buffer) {
      const p = openFiles.get(fd); if (state.onWrite) state.onWrite(p);
      if (p.startsWith('/app/game-export/records/') && !state.recordFailureUsed &&
        (state.recordFailure === 'initial' || state.recordFailure === 'terminal' && Buffer.from(buffer).includes(Buffer.from('"state":"succeeded"')))) {
        state.recordFailureUsed = true; throw new Error('ENOSPC private record');
      }
      if (p.startsWith('content://') && state.targetWriteFailure && state.targetWritten > 0) throw new Error('ENOSPC target');
      const bytes = Buffer.from(buffer); const written = fs.writeSync(fd, bytes, 0, Math.min(bytes.length, 4093));
      if (p.startsWith('content://')) state.targetWritten += written; return written;
    },
    async write(fd, buffer) {
      // SDK异步写入端口可受控等待，放行后仍执行原真实宿主写入和短写逻辑。
      if (state.beforeAsyncWrite) await state.beforeAsyncWrite(openFiles.get(fd));
      return fileIo.writeSync(fd, buffer);
    },
    fsyncSync(fd) {
      if (state.failDraftBackupFsync && openFiles.get(fd)?.includes('/game-export/quarantine/')) throw new Error('EIO draft backup sync');
      if (!directoryFiles.has(fd)) fs.fsyncSync(fd);
    }, async fsync(fd) { if (state.beforeAsyncFsync) await state.beforeAsyncFsync(openFiles.get(fd)); fileIo.fsyncSync(fd); },
  };
  const cryptoFramework = { createMd(algorithm) { const md = crypto.createHash(algorithm.toLowerCase()); return {
    async update({ data }) { md.update(data); }, async digest() { return { data: new Uint8Array(md.digest()) }; } }; } };
  const picker = { DocumentSaveOptions: class {}, DocumentViewPicker: class {
    async save(options) { state.pickerCalls++; state.suggestedName = options.newFileNames[0];
      if (state.beforePicker) await state.beforePicker();
      if (state.pickerCancel) return [];
      fs.mkdirSync(path.dirname(physical(state.selectedUri)), { recursive: true }); fs.writeFileSync(physical(state.selectedUri), ''); return [state.selectedUri]; }
  } };
  const fileUri = { FileUri: class {
    constructor(uri) { state.fileUriCalls.push(uri); if (state.fileUriFailure) throw new Error('FileUri provider unavailable'); }
    get name() { return state.fileUriName; }
  } };
  const network = new Map();
  const manager = { getTasks: () => state.downloads, cancel: id => { state.cancelledDownloads.add(id); },
    purgeTask(id) { state.purges++; if (!state.purgeAllowed || state.purgeBlockedIds.has(id)) return false; state.downloads = state.downloads.filter(item => item.taskId !== id); return true; },
    async awaitTaskReleased(id, retainOwner) {
      assert.equal(retainOwner, true, '执行action不得按有限超时释放租约');
      if (state.beforeOwnerRelease) await state.beforeOwnerRelease(id);
      assert(manager.purgeTask(id), 'fixture release gate must provide actual owner convergence');
    },
    async fetchText(url, mirrors = [], timeoutSeconds) {
      state.sidecarCalls.push({ url, mirrors: [...mirrors], timeoutSeconds });
      if (state.beforeSidecar) await state.beforeSidecar(url); const bytes = network.get(url.replace(/\.sha1$/, '')); assert(bytes, 'unexpected sidecar URL');
      return state.badInstallerSha && url.endsWith('-installer.jar.sha1') ? '0'.repeat(40) : digest(bytes); },
    async createAndWait(task, onProgress) {
      state.downloadPlans.push(structuredClone(task));
      state.downloadCalls++; const view = { taskId: state.downloadCalls, state: 'Running', bytesDone: 0, progress: 0, speedBps: 64 }; state.downloads.push(view); onProgress(view);
      await new Promise(resolve => setImmediate(resolve));
      if (state.cancelledDownloads.has(view.taskId)) throw new Error('Native download cancelled');
      for (const spec of task.files) {
        assert(spec.localPath.startsWith(spec.allowedRoot + '/')); assert(spec.allowedRoot.startsWith('/app/game-export/work/'));
        const bytes = network.get(spec.urls[0]); assert(bytes, 'unexpected network URL: ' + spec.urls[0]);
        assert.equal(digest(bytes), spec.check.sha1); if (spec.check.size) assert.equal(bytes.length, spec.check.size);
        fs.mkdirSync(path.dirname(physical(spec.localPath)), { recursive: true }); fs.writeFileSync(physical(spec.localPath), bytes);
        view.bytesDone += bytes.length;
      }
      view.state = 'Finished'; view.progress = 1; onProgress(view); return view;
    } };
  // 使用生产Registry的真实FIFO、取消与槽位释放；只在其外层记录文件租约，不能用即刻成功桩掩盖自锁。
  let registry;
  const runtime = { mcIsRunning: () => state.gameRunning, desktopGameProcessState: () => state.desktopState };
  if (nativeHashes) {
    let nextHashId = 0;
    Object.assign(runtime, {
      exportArchiveStart() { throw new Error('fixture Native writer must not start before snapshot drain'); },
      exportArchiveVerifyStart() { throw new Error('fixture Native verifier must not start before snapshot drain'); },
      exportFileHashStart(spec) {
        const jobId = ++nextHashId, source = openFiles.get(spec.fd), bytes = Buffer.alloc(spec.size); let offset = 0;
        while (offset < bytes.length) { const read = fs.readSync(spec.fd, bytes, offset, bytes.length - offset, offset); assert(read > 0); offset += read; }
        state.nativeHashCalls.push(source); state.nativeHashJobs.set(jobId, source);
        return { jobId, completion: Promise.resolve({ jobId, operation: 'hash', files: 1, size: spec.size,
          sha1: spec.sha1 === false ? '' : digest(bytes), sha256: spec.sha256 === false ? '' : digest(bytes, 'sha256') }) };
      },
      exportJobQuery(jobId) { return { jobId, exists: state.nativeHashJobs.has(jobId), released: state.nativeHashReleased.has(jobId),
        filesDone: 1, bytesDone: 0, settled: true, errorCode: '', errorMessage: '' }; },
      exportJobCancel() { return false; },
      exportJobRelease(jobId) {
        if (state.nativeHashReleaseGate && !state.nativeHashReleaseGate(state.nativeHashJobs.get(jobId))) return false;
        assert(state.nativeHashJobs.delete(jobId)); state.nativeHashReleased.add(jobId); return true;
      },
    });
  }
  const appStorage = { get: key => key === 'uiAbilityContext' ? { filesDir: '/app' } : undefined };

  /** 只抽取已有安全函数的真实声明，避免加载与本用例无关的整个下载网络模块。 */
  function selected(relative, names) {
    const source = fs.readFileSync(path.join(PROJECT_ROOT, relative), 'utf8');
    const ast = compiler.createSourceFile(relative, source, compiler.ScriptTarget.Latest, true);
    return ast.statements.filter(node => names.includes(node.name?.text) || node.declarationList?.declarations.some(item => names.includes(item.name.text)))
      .map(node => node.getFullText(ast)).join('\n');
  }
  function load(relative, sourceOverride) {
    if (modules.has(relative)) return modules.get(relative);
    let source = sourceOverride ?? fs.readFileSync(path.join(PROJECT_ROOT, relative), 'utf8');
    // @Observed是ArkUI运行时边界；保留生产view字段与所有普通方法，不在Node伪造UI渲染。
    if (relative.endsWith('/UnifiedDownloadTask.ets')) source = source.replace(/^@Observed\s*$/m, '');
    const js = compiler.transpileModule(source, { compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 } }).outputText;
    const exports = {}; modules.set(relative, exports);
    const require = name => {
      if (name === '@kit.CoreFileKit') return { fileIo, fileUri, picker, statfs: { async getFreeSize() { return 10 ** 12; } } };
      if (name === '@kit.CryptoArchitectureKit') return { cryptoFramework };
      if (name === '@kit.AbilityKit') return {};
      if (name === '@kit.BasicServicesKit') return { zlib: { async decompressFile(input, output) { lifecycleExtract(fs.readFileSync(physical(input)), physical(output)); } } };
      if (name === '@kit.ArkTS') return { util: { generateRandomUUID: crypto.randomUUID, TextEncoder: class { encodeInto(text) { return new Uint8Array(Buffer.from(text)); } } } };
      if (name === 'libentry.so') return { default: runtime };
      if (name === 'commons') return { ...load('commons/src/main/ets/utils/Base64Util.ets'), ...load('commons/src/main/ets/utils/AtomicFileWriter.ets'),
        ...load('commons/src/main/ets/utils/InstancePaths.ets'), AppLogger: { error: (...args) => state.errors.push(args.join(' ')), warn() {}, info() {} } };
      if (name === 'feature_core') {
        const core = {};
        for (const file of ['ExportTypes', 'ExportPath', 'ExportContentSelection', 'ExportVersionResolver', 'ForgelikeExportPlanner', 'DesktopDependencyPlanner', 'StandardPackWriter', 'ExportFilePlan', 'ExportZipFormat']) {
          Object.assign(core, load('feature_core/src/main/ets/export/' + file + '.ets'));
        }
        Object.assign(core, load('selected-maven', selected('feature_core/src/main/ets/modloader/MavenUtils.ets',
          ['MAX_SAFE_SEGMENT_LENGTH', 'MAX_SAFE_RELATIVE_PATH_LENGTH', 'containsControlCharacter', 'safeBaseName', 'safeRelPath', 'parseMavenName', 'mavenToRelativePath'])));
        // 使用真实计划编译函数；只替换来源偏好/网络执行端，不在fixture里复制去重、
        // 约束冲突或可选字段规则。Maven候选映射另由其生产绑定专项验证。
        Object.assign(core, load('selected-download-plan', selected('feature_core/src/main/ets/download/DownloadManager.ets',
          ['copyDownloadFileSpec', 'downloadPathComparisonKey', 'compileDownloadFiles'])));
        Object.assign(core, load('selected-sidecar', selected('feature_core/src/main/ets/modloader/MavenSpecBuilder.ets', ['artifactSidecarUrl'])));
        Object.assign(core, load('feature_core/src/main/ets/download/UnifiedDownloadTask.ets'));
        // 进程准入必须执行同一个生产协调器，不能在导出fixture里用“永远允许”替身。
        Object.assign(core, load('feature_core/src/main/ets/download/ProcessActivityCoordinator.ets'));
        return { ...core, ActivityCategory: { GAME_EXPORT: 'game_export' }, getDownloadHistoryStore: () => ({
          async init() {
            state.historyInitStarted = true;
            if (state.historyInitGate) await state.historyInitGate;
            if (state.historyWriteFailure === 'init') throw new Error('history init failed');
          },
          async add(record) {
            state.historyAddStarted = true;
            if (state.historyAddGate) await state.historyAddGate;
            if (state.historyWriteFailure === 'add') throw new Error('history add failed');
            state.history.push(record);
          },
        }),
          installedJdkMajors: filesDir => [8, 17, 21, 25].filter(major => fs.existsSync(physical(filesDir + '/jdk/' + major + '/release')) && fs.existsSync(physical(filesDir + '/jdk/' + major + '/lib/server/libjvm.so'))),
          // 生产builder只负责等价来源及顺序；网络仍由独立bytes映射替换。显式映射优先，
          // 使[]、重复及非HTTPS输入能真实经过Coordinator过滤，不在端口复制其处理算法。
          buildMavenUrls: (coordinate, repository, preferRealSource, direct) => {
            state.mavenCalls.push({ coordinate, repository, preferRealSource, direct });
            if (state.mavenCandidates.has(direct)) return state.mavenCandidates.get(direct);
            return state.useProductionMavenCandidates
              ? candidateBuilder.buildMavenUrls(coordinate, repository, preferRealSource, direct) : [direct];
          },
          buildMavenArtifactUrls: (url, preferRealSource) => state.useProductionMavenCandidates
            ? candidateBuilder.buildMavenArtifactUrls(url, preferRealSource) : [url],
          shouldUseBmclapiFirst: () => sourcePolicy.shouldUseBmclapiFirst(),
          forgeNative: () => ({ checkJitAvailable: () => state.jit, getRecommendedXmx: () => 1024 }),
          ForgelikeProcessorRunner: { async run(...args) { state.processorCalls++; assert(state.processor, 'unexpected processor invocation'); return state.processor(...args); } },
          DownloadManager: { instance: () => manager }, DownloadTaskRegistry: { instance: () => registry }, claimVersionInstall() {
          assert.equal(state.versionLease, 0); state.versionLease++; return () => { state.versionLease--; };
        } };
      }
      if (name.startsWith('.')) return load(path.relative(PROJECT_ROOT, path.resolve(PROJECT_ROOT, path.dirname(relative), name + '.ets')).replaceAll('\\', '/'));
      throw new Error('Unmocked dependency: ' + name);
    };
    new Function('exports', 'require', 'AppStorage', js)(exports, require, appStorage); return exports;
  }
  // 用原声明组装纯模块，不加载HTTP/NAPI。排序专项执行真正的用户偏好setter、
  // shouldUseBmclapiFirst和Maven候选规则；未配置专项的老用例维持官方优先端口基线。
  const sourcePolicy = load('selected-source-policy', 'const TAG = "source-policy-fixture"; const AppLogger = { info() {} };\n'
    + selected('feature_core/src/main/ets/download/SourceProber.ets',
      ['PROBE_MAX_AGE_MS', 'cachedRanking', 'probeGeneration', 'sourcePreference', 'normalizeMode',
        'setMcSourcePreference', 'getMcSourcePreference', 'getCachedRanking', 'shouldUseBmclapiFirst']));
  sourcePolicy.setMcSourcePreference('official');
  const candidateBuilder = load('selected-real-maven-builder',
    selected('commons/src/main/ets/common/Constants.ets', ['BMCLAPI_HOST', 'BMCLAPI_BASE'])
    + selected('feature_core/src/main/ets/modloader/MavenUtils.ets',
      ['MAX_SAFE_SEGMENT_LENGTH', 'MAX_SAFE_RELATIVE_PATH_LENGTH', 'MAX_SAFE_URL_LENGTH', 'containsControlCharacter',
        'safeBaseName', 'safeRelPath', 'parseMavenName', 'mavenToRelativePath', 'isSafeHttpUrl',
        'DEFAULT_MAVEN_REPOS', 'BMCLAPI_MAVEN', 'BMCLAPI_LIBRARIES'])
    + selected('feature_core/src/main/ets/modloader/MavenSpecBuilder.ets',
      ['pushSafeUrl', 'knownMavenRepoBases_', 'knownMavenRepoBases', 'LOADER_OWNED_GROUP_PREFIXES', 'LOADER_OWNED_GROUP_REPOS',
        'loaderOwnedRepo', 'stripKnownRepoBase', 'relPathFromUrl', 'buildArtifactCandidates', 'buildMavenUrls', 'buildMavenArtifactUrls']));
  const Registry = load('feature_core/src/main/ets/download/DownloadTaskRegistry.ets').DownloadTaskRegistry;
  registry = new Registry();
  const list = registry.listAll.bind(registry);
  registry.listAll = () => [...state.registryTasks, ...list()];
  const acquire = registry.acquireReplacementLease.bind(registry);
  registry.acquireReplacementLease = () => {
    // 准备队列自己的action/Native/Registry runningIds均退出后才能冻结；终态卡片可保留。
    const release = acquire(); assert.equal(registry.runningIds_.length, 0);
    assert.equal(state.registryLease, 0); state.registryLease++;
    return () => { release(); state.registryLease--; };
  };
  function put(relative, bytes) { const target = physical(relative); fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, bytes); }
  function artifact(relative, bytes) { const url = 'https://example.invalid/' + relative; network.set(url, Buffer.from(bytes));
    return { path: relative.replace(/^libraries\//, ''), url, sha1: digest(bytes), size: Buffer.byteLength(bytes) }; }
  put('/app/.fixture', 'context');
  const client = artifact('versions/1.20.1/1.20.1.jar', 'client jar bytes'); put('/mc/versions/1.20.1/1.20.1.jar', 'client jar bytes');
  const asset = Buffer.from('language bytes'); const assetHash = digest(asset); put('/mc/assets/objects/' + assetHash.slice(0, 2) + '/' + assetHash, asset);
  const index = JSON.stringify({ objects: { 'minecraft/lang/en_us.json': { hash: assetHash, size: asset.length } } });
  const assetIndex = { ...artifact('assets/indexes/test.json', index), id: 'test' }; put('/mc/assets/indexes/test.json', index);
  const library = artifact('libraries/example/core/1/core-1.jar', 'common library bytes'); put('/mc/libraries/example/core/1/core-1.jar', 'common library bytes');
  const desktopLibrary = artifact('libraries/org/lwjgl/lwjgl/3.3.1/lwjgl-3.3.1.jar', 'desktop lwjgl bytes');
  if (!missingLibrary) put('/mc/libraries/org/lwjgl/lwjgl/3.3.1/lwjgl-3.3.1.jar', 'desktop lwjgl bytes');
  const vanilla = { id: '1.20.1', type: 'release', mainClass: 'net.minecraft.client.main.Main', downloads: { client }, assetIndex,
    libraries: [{ name: 'example:core:1', downloads: { artifact: library } }, { name: 'org.lwjgl:lwjgl:3.3.1', downloads: { artifact: desktopLibrary } }],
    arguments: { game: ['--username', '${auth_player_name}'], jvm: ['-Xmx2G'] } };
  put('/mc/versions/1.20.1/1.20.1.json', JSON.stringify(vanilla));
  const versionId = fabric ? 'fabric-test' : '1.20.1';
  if (fabric) {
    const loader = artifact('libraries/net/fabricmc/fabric-loader/0.16.10/fabric-loader-0.16.10.jar', 'fabric loader bytes');
    put('/mc/libraries/net/fabricmc/fabric-loader/0.16.10/fabric-loader-0.16.10.jar', 'fabric loader bytes');
    put('/mc/versions/fabric-test/fabric-test.json', JSON.stringify({ id: versionId, inheritsFrom: '1.20.1', mainClass: 'net.fabricmc.loader.impl.launch.knot.KnotClient',
      libraries: [{ name: 'net.fabricmc:fabric-loader:0.16.10', downloads: { artifact: loader } }] }));
  }
  put('/mc/versions/' + versionId + '/mods/local.jar.disabled', 'disabled local mod');
  put('/mc/versions/' + versionId + '/config/settings.json', '{"portable":true}');
  put('/mc/versions/' + versionId + '/options.txt', 'music:0.5\n');
  put('/mc/versions/' + versionId + '/saves/世界/level.dat', 'selected world');
  put('/mc/versions/' + versionId + '/saves/其他世界/level.dat', 'not selected');
  fs.mkdirSync(physical('/mc/versions/' + versionId + '/config/空目录'), { recursive: true });
  const { GameExportCoordinator } = load('entry/src/main/ets/export/GameExportCoordinator.ets'); const coordinator = new GameExportCoordinator();
  coordinator.subscribe(() => { const task = coordinator.getTask(); if (task) state.stages.push(task.stage); });
  async function request(format = 'full') {
    const source = await coordinator.inspectSource('/mc', versionId, true);
    assert(!source.issues.some(issue => issue.severity === 'error'), JSON.stringify(source.issues));
    return { ...source.request, format, selectedWorlds: ['世界'] };
  }
  async function terminal() {
    for (let count = 0; count < 1000; count++) {
      const task = coordinator.getTask();
      if (task && ['succeeded', 'failed', 'cancelled'].includes(task.state)) {
        await new Promise(resolve => setImmediate(resolve));
        assert.equal(openFiles.size, 0); assert.equal(state.registryLease, 0); assert.equal(state.versionLease, 0); return task;
      }
      await new Promise(resolve => setTimeout(resolve, 5));
    }
    throw new Error('Export owner did not settle: ' + JSON.stringify(coordinator.getTask()));
  }
  function sourceIdentity() {
    const out = [];
    function visit(root, prefix = '') { for (const name of fs.readdirSync(root).sort()) { const full = path.join(root, name), relative = prefix + name;
      if (fs.statSync(full).isDirectory()) { out.push([relative + '/', 'directory']); visit(full, relative + '/'); }
      else out.push([relative, digest(fs.readFileSync(full), 'sha256')]); } }
    visit(physical('/mc')); return out;
  }
  function readZip() {
    const result = spawnSync(process.env.PYTHON ?? 'python', ['-B', '-c',
      'import zipfile,json,sys,base64; z=zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; print(json.dumps({i.filename:base64.b64encode(z.read(i)).decode() for i in z.infolist()},ensure_ascii=False))', physical(state.selectedUri)], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr); return Object.fromEntries(Object.entries(JSON.parse(result.stdout)).map(([key, value]) => [key, Buffer.from(value, 'base64')]));
  }
  return { state, directory, physical, put, network, coordinator, registry, sourcePolicy, load, selected, request, terminal, sourceIdentity, readZip, versionId,
    close() { assert.equal(openFiles.size, 0); assert.equal(state.nativeHashJobs.size, 0); assert.equal(state.registryLease, 0); assert.equal(state.versionLease, 0);
      const actual = fs.realpathSync(directory), base = fs.realpathSync(parent); assert.equal(path.dirname(actual), base);
      assert(path.basename(actual).startsWith('amcl-export-life-')); fs.rmSync(actual, { recursive: true, force: true }); },
  };
}

/**
 * 迟到历史提交的跨层回归执行真实Index订阅、最近活动投影、隐藏方法及版本Sheet关闭回调。
 * 只把已耐久历史和UI宿主端口接到同一个真实coordinator夹具；不另写页面刷新算法。
 */
const activityIndexSource = fs.readFileSync(path.join(PROJECT_ROOT, 'entry/src/main/ets/pages/Index.ets'), 'utf8');
const activityIndexAst = compiler.createSourceFile('Index.ets', activityIndexSource, compiler.ScriptTarget.Latest, true);
const activityIndex = activityIndexAst.statements.find(node => node.members?.some(member => member.name?.getText(activityIndexAst) === 'observeExportActivities_'));
assert(activityIndex, '真实Index必须接入共用导出活动订阅');
const activityIndexMethods = ['observeExportActivities_', 'refreshStoreManager_', 'refreshRecentActivities_',
  'finishErrorSheetWait_', 'onPageHide'].map(name => {
  const member = activityIndex.members.find(value => value.name?.getText(activityIndexAst) === name);
  assert(member?.body, name); return member.getText(activityIndexAst);
});
const versionSheetCloseCallbacks = [];
function findVersionSheetClose(node) {
  if (compiler.isPropertyAssignment(node) && node.name?.getText(activityIndexAst) === 'onRegisterExportDismiss') {
    const callback = node.parent.properties.find(value => value.name?.getText(activityIndexAst) === 'onClose');
    assert(compiler.isArrowFunction(callback?.initializer)); versionSheetCloseCallbacks.push(callback.initializer.getText(activityIndexAst));
  }
  compiler.forEachChild(node, findVersionSheetClose);
}
findVersionSheetClose(activityIndex);
assert.equal(versionSheetCloseCallbacks.length, 1, '必须执行版本Sheet真正的宿主关闭回调');
const activityIndexJs = compiler.transpileModule('class IndexProjection {\n' + activityIndexMethods.join('\n') +
  '\ncloseVersionSheet() { const callback = ' + versionSheetCloseCallbacks[0] + '; callback(); }\n}\nexports.IndexProjection=IndexProjection;', {
  compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2022 },
}).outputText;
function activityIndexProjection(f) {
  const exported = {}, observations = { historyWaits: 0, nonTerminalHistoryWaits: 0, sourceReads: 0 };
  // 这里default若越过产品guard，真实refreshStoreManager后续依赖会立即失败；绝不空实现扫描。
  const coordinator = {
    getTask: () => f.coordinator.getTask(), subscribe: listener => f.coordinator.subscribe(listener),
    inspectSource() { observations.sourceReads++; assert.fail('default activity subscription must never inspect source'); },
  };
  new Function('exports', 'DistributionPolicy', 'getGameExportCoordinator', 'getDownloadHistoryStore', 'AppStorage',
    'setTimeout', 'clearTimeout', 'AppLogger', 'TAG', 'LOG_DOMAIN_DOWNLOAD', activityIndexJs)(exported, { isStore: () => false }, () => coordinator,
      () => ({ async waitReady() {
        observations.historyWaits++;
        const task = f.coordinator.getTask();
        if (task && ['running', 'cancelling'].includes(task.state)) observations.nonTerminalHistoryWaits++;
        if (f.state.historyInitGate) await f.state.historyInitGate;
      }, listStored() { return f.state.history.slice().reverse(); } }),
      { setOrCreate() {} }, callback => callback(), clearTimeout, { warn() {} }, 'Index', 1);
  const page = new exported.IndexProjection();
  Object.assign(page, { launcherWorkVisible_: true, storeExportUnsubscribe_: null, recentActivities: [], showVersionManager: true,
    storeCheckGeneration_: 0, storeCheckSignature_: '', recoveryPresentationEpoch_: 0,
    // 此夹具模拟已挂载并能导出的首页；真实隐藏方法先收口错误Sheet等待，再解除导出订阅。
    // 直接提取finishErrorSheetWait_并设置生产初值，不能用空实现吞掉生命周期异常。
    launcherInitialized_: true, errorSheetWaitTimer_: -1, errorSheetWait_: null, errorSheetWaitTask_: null,
    onLauncherWorkVisibilityChanged_() {}, exitUpdateForRoute_() {},
  });
  page.refreshStoreManager_();
  return { page, observations };
}

for (const boundary of ['init', 'add']) test(`same-Sheet close before delayed history.${boundary} still refreshes actual Index recent activities`, async () => {
  const f = fixture(); let release;
  const gate = new Promise(resolve => { release = resolve; });
  f.state[boundary === 'init' ? 'historyInitGate' : 'historyAddGate'] = gate;
  const p = activityIndexProjection(f);
  try {
    const preview = await f.coordinator.checkPlan(await f.request('modrinth'));
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
    const execution = f.coordinator.execution_;
    const task = await f.terminal();
    assert.equal(task.state, 'succeeded'); assert.equal(f.state.history.length, 0);
    assert(f.state[boundary === 'init' ? 'historyInitStarted' : 'historyAddStarted']);
    const processOwner = f.load('feature_core/src/main/ets/download/ProcessActivityCoordinator.ets').ProcessActivityCoordinator.instance();
    assert.equal(f.coordinator.execution_, execution, '可见succeeded不能冒充整个owner已经结算');
    assert.throws(() => processOwner.acquireSharedGame(), /导出|文件任务|尚未结束/,
      '历史耐久提交仍在等待时，共享游戏不能结束同一进程');
    p.page.closeVersionSheet();
    assert.equal(p.page.showVersionManager, false); assert.equal(p.page.launcherWorkVisible_, true, '同Sheet关闭不触发onPageHide/onPageShow');
    assert.equal(p.page.recentActivities.length, 0);
    release(); await execution; await new Promise(resolve => setImmediate(resolve));
    assert.equal(f.state.history.length, 1);
    assert.equal(p.page.recentActivities[0].exportTaskId, task.id, 'history耐久后必须再次通知相同终态');
    assert.equal(p.observations.sourceReads, 0); assert.equal(p.observations.nonTerminalHistoryWaits, 0);
    assert.equal(f.coordinator.execution_, undefined);
    const lease = processOwner.acquireSharedGame(); lease.releasePreparation();
  } finally {
    release(); if (f.coordinator.execution_) await f.coordinator.execution_;
    p.page.onPageHide(); f.close();
  }
});

test('hidden Index unsubscribes before delayed history commit and receives no late LRU refresh', async () => {
  const f = fixture(); let release;
  f.state.historyAddGate = new Promise(resolve => { release = resolve; });
  const listenersBefore = f.coordinator.listeners_.length;
  const p = activityIndexProjection(f);
  try {
    assert.equal(f.coordinator.listeners_.length, listenersBefore + 1);
    const preview = await f.coordinator.checkPlan(await f.request('modrinth'));
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview); const execution = f.coordinator.execution_;
    await f.terminal(); await new Promise(resolve => setImmediate(resolve));
    p.page.onPageHide();
    const waitsBefore = p.observations.historyWaits;
    assert.equal(p.page.storeExportUnsubscribe_, null); assert.equal(f.coordinator.listeners_.length, listenersBefore);
    release(); await execution; await new Promise(resolve => setImmediate(resolve));
    assert.equal(f.state.history.length, 1); assert.equal(p.observations.historyWaits, waitsBefore);
    assert.equal(p.observations.sourceReads, 0);
  } finally { release(); if (f.coordinator.execution_) await f.coordinator.execution_; f.close(); }
});

test('history persistence failure retains warning notification without replacing successful export outcome', async () => {
  const f = fixture(); const notices = [];
  const unsubscribe = f.coordinator.subscribe(() => { const task = f.coordinator.getTask(); if (task) notices.push(task.message); });
  try {
    f.state.historyWriteFailure = 'add';
    const preview = await f.coordinator.checkPlan(await f.request('curseforge'));
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview); const execution = f.coordinator.execution_;
    const task = await f.terminal(); await execution;
    assert.equal(task.state, 'succeeded'); assert.equal(task.readbackVerified, true); assert.equal(f.state.history.length, 0);
    assert.match(task.message, /活动摘要暂未保存/); assert(notices.some(value => /活动摘要暂未保存/.test(value)));
    assert.equal(f.coordinator.execution_, undefined);
    const owner = f.load('feature_core/src/main/ets/download/ProcessActivityCoordinator.ets').ProcessActivityCoordinator.instance();
    const lease = owner.acquireSharedGame(); lease.releasePreparation();
  } finally { unsubscribe(); f.close(); }
});

test('export process owner stays held during actual URI write after source leases release, until execution settles', async () => {
  const f = fixture(); let release;
  try {
    const before = f.sourceIdentity(), gate = new Promise(resolve => { release = resolve; }); let writeStarted = false;
    f.state.beforeAsyncWrite = async target => {
      if (target === f.state.selectedUri) { writeStarted = true; await gate; }
    };
    const processOwner = f.load('feature_core/src/main/ets/download/ProcessActivityCoordinator.ets').ProcessActivityCoordinator.instance();
    const preview = await f.coordinator.checkPlan(await f.request('modrinth'));
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview); const execution = f.coordinator.execution_;
    await waitForExportCondition(() => writeStarted);
    assert.equal(f.coordinator.getTask().stage, '写入目标');
    assert.equal(f.state.registryLease, 0); assert.equal(f.state.versionLease, 0);
    assert.equal(f.coordinator.execution_, execution);
    assert.throws(() => processOwner.acquireSharedGame(), /导出|文件任务|尚未结束/,
      'ZIP已结束、冻结租约已释放，也必须等目标写入/读回和业务finally真实结束');
    release(); await execution; await new Promise(resolve => setImmediate(resolve));
    assert.equal((await f.terminal()).state, 'succeeded'); assert.equal(f.coordinator.execution_, undefined);
    const lease = processOwner.acquireSharedGame(); lease.releasePreparation();
    assert.deepEqual(f.sourceIdentity(), before); assert.equal(f.coordinator.downloadIds_.size, 0);
  } finally { release?.(); if (f.coordinator.execution_) await f.coordinator.execution_; f.close(); }
});

test('export reserves the process before initial record IO even while execution_ is not published yet', async () => {
  const f = fixture(); let release, starting;
  try {
    const before = f.sourceIdentity(), gate = new Promise(resolve => { release = resolve; }); let recordStarted = false;
    f.state.beforeDirectoryMkdir = async target => {
      if (target === '/app/game-export/records') { recordStarted = true; await gate; }
    };
    const processOwner = f.load('feature_core/src/main/ets/download/ProcessActivityCoordinator.ets').ProcessActivityCoordinator.instance();
    const preview = await f.coordinator.checkPlan(await f.request('modrinth'));
    starting = f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
    await waitForExportCondition(() => recordStarted);
    assert.equal(f.coordinator.getTask().state, 'running'); assert.equal(f.coordinator.execution_, undefined);
    assert.throws(() => processOwner.acquireSharedGame(), /导出|文件任务|尚未结束/,
      'Picker已取得目标后，初始记录持久化也属于同一个持续owner');
    release(); assert(await starting); const execution = f.coordinator.execution_; assert(execution);
    await execution; await new Promise(resolve => setImmediate(resolve));
    assert.equal((await f.terminal()).state, 'succeeded'); assert.equal(f.coordinator.execution_, undefined);
    const lease = processOwner.acquireSharedGame(); lease.releasePreparation();
    assert.deepEqual(f.sourceIdentity(), before);
  } finally {
    release?.(); if (starting) { try { await starting; } catch (_) { /* 原断言保留失败原因，先等所有IO收尾。 */ } }
    if (f.coordinator.execution_) await f.coordinator.execution_; f.close();
  }
});

/** 真实Picker请求仍使用建议名，实际名称只来自经文档确认支持的FileUri SDK边界。 */
for (const sample of [
  { name: 'user rename', uri: 'file://docs/storage/Users/currentUser/Download/renamed%20%E4%B8%AD%E6%96%87.mrpack', actual: 'renamed 中文.mrpack', expected: 'renamed 中文.mrpack', calls: 1 },
  { name: 'opaque content URI', uri: 'content://picker/938175', actual: '938175', expected: '', calls: 0 },
  { name: 'provider unavailable', uri: 'file://docs/storage/Users/currentUser/Download/output.mrpack', failure: true, actual: 'output.mrpack', expected: '', calls: 1 },
  { name: 'empty SDK name', uri: 'file://docs/storage/Users/currentUser/Download/output.mrpack', actual: '', expected: '', calls: 1 },
  { name: 'invalid SDK segment', uri: 'file://docs/storage/Users/currentUser/Download/output.mrpack', actual: '../wrong.mrpack', expected: '', calls: 1 },
]) test(`Picker metadata ${sample.name} preserves actual name or explicitly unknown without persisting URI capability`, async () => {
  const f = fixture();
  try {
    f.state.selectedUri = sample.uri; f.state.fileUriName = sample.actual; f.state.fileUriFailure = sample.failure === true;
    const preview = await f.coordinator.checkPlan(await f.request('modrinth'));
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview); const task = await f.terminal();
    assert.equal(task.state, 'succeeded'); assert.equal(task.readbackVerified, true);
    assert.equal(f.state.suggestedName, '1.20.1-modrinth.mrpack', 'newFileNames仍只是建议，不改变目标策略');
    assert.equal(task.filename, sample.expected); assert.equal(f.state.fileUriCalls.length, sample.calls);
    const persisted = fs.readFileSync(f.physical('/app/game-export/records/' + task.id + '.json'), 'utf8');
    assert.equal(JSON.parse(persisted).view.filename, sample.expected);
    assert(!persisted.includes(sample.uri), '私有任务不能持久化系统目标URI授权');
  } finally { f.close(); }
});

/**
 * UI 的接收端兼容提示必须消费真实解析身份。Forge 夹具故意沿用原版目录名，
 * 可检出从实例名称或摘要文案猜加载器的回归；只读盘点不允许下载、跑处理器或改源。
 * 每个用例独占宿主沙箱，并在失败时同样检查句柄/租约收敛后清理自身夹具。
 */
for (const loader of ['vanilla', 'fabric', 'forge', 'neoforge']) {
  test(`源界面提供结构化 ${loader} 身份，盘点保持只读`, async () => {
    const f = fixture({ fabric: loader === 'fabric' });
    try {
      if (loader === 'forge' || loader === 'neoforge') configureForgelike(f, loader === 'neoforge');
      const before = f.sourceIdentity();
      const source = await f.coordinator.inspectSource('/mc', f.versionId, true);
      assert.equal(source.request.versionId, f.versionId);
      assert.equal(source.loaderKind, loader);
      assert.equal(f.state.downloadCalls, 0);
      assert.equal(f.state.processorCalls, 0);
      assert.deepEqual(f.sourceIdentity(), before);
    } finally { f.close(); }
  });
}

/**
 * 绕过UI直接调用生产checkPlan仍必须发现本轮未能表示的选中范围。SDK仅模拟枚举名，
 * 不mock发现树或纯helper；明确改选已确认的单包后，错误兄弟不得阻断合法的精确子集。
 */
for (const format of ['full', 'modrinth', 'curseforge']) {
  test(`${format} real checkPlan blocks selected discovery error before Picker and permits explicit safe subset`, async () => {
    const f = fixture();
    try {
      f.put('/mc/versions/' + f.versionId + '/resourcepacks/A.zip', 'safe pack bytes');
      const request = await f.request(format);
      f.state.listFileAdditions.set(request.gameDir + '/resourcepacks', ['C:ghost']);
      const blocked = await f.coordinator.checkPlan(request);
      assert(blocked.issues.some(issue => issue.code === 'CONTENT_SELECTION_UNREADABLE' && issue.severity === 'error'), JSON.stringify(blocked.issues));
      // 公共preview即使被调用者改写，也不能删除owner保存的错误事实取得另存资格。
      await assert.rejects(f.coordinator.pickAndStart({ filesDir: '/app' }, { ...blocked, issues: [] }), /预览中的问题/);
      assert.equal(f.state.pickerCalls, 0); assert.equal(f.state.downloadCalls, 0);
      const precise = { ...request, selectionVersion: 2, includeDirectories: [],
        includeFiles: ['resourcepacks/A.zip'], selectedWorlds: [], excludePaths: [] };
      const ready = await f.coordinator.checkPlan(precise);
      assert(!ready.issues.some(issue => issue.severity === 'error'), JSON.stringify(ready.issues));
      await f.coordinator.pickAndStart({ filesDir: '/app' }, ready);
      const task = await f.terminal(); assert.equal(task.state, 'succeeded', task.message); assert.equal(task.readbackVerified, true);
      const prefix = format === 'full' ? '.minecraft/versions/' + request.exportId + '/' : 'overrides/';
      const entries = f.readZip(); assert.equal(entries[prefix + 'resourcepacks/A.zip'].toString(), 'safe pack bytes');
      assert(!Object.keys(entries).some(name => name.includes('C:ghost')));
    } finally { f.close(); }
  });
}

for (const fabric of [false, true]) for (const format of ['full', 'modrinth', 'curseforge']) {
  test(`${fabric ? 'Fabric' : 'vanilla'} ${format} runs inspect→preview→picker→snapshot→ZIP→URI without source mutation`, async () => {
    const f = fixture({ fabric, missingLibrary: format === 'full' });
    try {
      const identity = f.sourceIdentity(); const request = await f.request(format); const preview = await f.coordinator.checkPlan(request);
      assert(!preview.issues.some(issue => issue.severity === 'error'), JSON.stringify(preview.issues));
      assert.equal(preview.downloads, format === 'full' ? 1 : 0);
      assert(await f.coordinator.pickAndStart({ filesDir: '/app' }, preview)); const task = await f.terminal(); assert.equal(task.state, 'succeeded', task.message);
      assert.equal(task.readbackVerified, true); assert.equal(task.size, fs.statSync(f.physical(f.state.selectedUri)).size);
      assert.equal(task.sha256, digest(fs.readFileSync(f.physical(f.state.selectedUri)), 'sha256'));
      assert.deepEqual(f.sourceIdentity(), identity); const entries = f.readZip();
      const prefix = format === 'full' ? '.minecraft/versions/' + request.exportId + '/' : 'overrides/';
      assert.equal(entries[prefix + 'mods/local.jar.disabled'].toString(), 'disabled local mod');
      assert.equal(entries[prefix + 'saves/世界/level.dat'].toString(), 'selected world');
      assert(!Object.keys(entries).some(name => name.includes('其他世界'))); assert(entries[prefix + 'config/空目录/']);
      if (format === 'full') {
        assert(entries['.minecraft/libraries/example/core/1/core-1.jar']); assert(entries[prefix + 'PCL/Setup.ini']);
        const version = JSON.parse(entries[prefix + request.exportId + '.json']); assert.equal(version.id, request.exportId); assert(!version.inheritsFrom);
        assert.equal(f.state.downloadCalls, 1); assert.equal(f.state.purges, 1);
      } else if (format === 'modrinth') {
        const index = JSON.parse(entries['modrinth.index.json']); assert.equal(index.dependencies.minecraft, '1.20.1'); assert.deepEqual(index.files, []);
        if (fabric) assert.equal(index.dependencies['fabric-loader'], '0.16.10'); assert(!entries['manifest.json']);
      } else {
        const index = JSON.parse(entries['manifest.json']); assert.equal(index.minecraft.version, '1.20.1'); assert.equal(index.overrides, 'overrides');
        if (fabric) assert.equal(index.minecraft.modLoaders[0].id, 'fabric-0.16.10'); assert(!entries['modrinth.index.json']);
      }
      assert(f.state.stages.includes('校验归档')); assert(f.state.stages.includes('写入目标'));
      assert.equal(f.state.history.length, 1); assert.equal(f.state.history[0].exportTaskId, task.id);
      assert.equal(await f.coordinator.restoreTask(task.id), true); assert.equal(f.coordinator.getTask().state, 'succeeded');
    } finally { f.close(); }
  });
}

test('busy running, unknown desktop state, waiting/paused downloads and persistent pending all block export', async () => {
  const f = fixture();
  try {
    const request = await f.request();
    for (const change of [() => { f.state.gameRunning = true; }, () => { f.state.desktopState = -1; },
      () => { f.state.registryTasks = [{ state: 'waiting' }]; }, () => { f.state.registryTasks = [{ state: 'paused' }]; },
      () => { f.state.downloads = [{ taskId: 9, state: 'Waiting' }]; }]) {
      change(); await assert.rejects(f.coordinator.checkPlan(request), /会话|下载/);
      f.state.gameRunning = false; f.state.desktopState = 0; f.state.registryTasks = []; f.state.downloads = [];
    }
    f.put('/mc/versions/1.20.1/.amcl-mc-pending.json', '{}'); await assert.rejects(f.coordinator.checkPlan(request), /安装意图/);
    assert.equal(f.state.pickerCalls, 0); assert.equal(f.state.downloadCalls, 0);
  } finally { f.close(); }
});

/** 历史恢复在读盘边界停住；它不得接管随后预约/执行的owner，也不能回写错误的任务记录。 */
for (const phase of ['running', 'picker', 'finished']) test(`late historical restoration cannot replace a new export during ${phase}`, async () => {
  const f = fixture();
  try {
    const request = await f.request('modrinth'); const preview = await f.coordinator.checkPlan(request);
    const oldId = '1234567890123-old-export';
    const old = JSON.stringify({ schemaVersion: 1, updatedAt: 1, view: { id: oldId, request, state: 'succeeded', stage: '导出完成' } });
    const record = '/app/game-export/records/' + oldId + '.json'; f.put(record, old);
    let announceRead, releaseRead;
    const reading = new Promise(resolve => { announceRead = resolve; });
    const gate = new Promise(resolve => { releaseRead = resolve; });
    f.state.beforeReadText = async p => { if (p === record) { announceRead(); await gate; } };
    const restoring = f.coordinator.restoreTask(oldId); await reading;
    let releasePicker, announcePicker;
    const picking = new Promise(resolve => { announcePicker = resolve; });
    if (phase === 'picker') f.state.beforePicker = async () => {
      announcePicker(); await new Promise(resolve => { releasePicker = resolve; });
    };
    const starting = f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
    if (phase === 'picker') {
      await picking; releaseRead(); assert.equal(await restoring, false); assert.equal(f.coordinator.getTask(), null); releasePicker();
    }
    const id = await starting;
    if (phase === 'finished') { assert.equal((await f.terminal()).state, 'succeeded'); releaseRead(); }
    else if (phase === 'running') releaseRead();
    assert.equal(await restoring, false); assert.equal(f.coordinator.getTask().id, id);
    if (phase !== 'finished') {
      f.coordinator.cancelTask(); assert.equal(f.coordinator.cancelRequested_, true);
      assert.equal((await f.terminal()).state, 'cancelled');
    }
    assert.equal(fs.readFileSync(f.physical(record), 'utf8'), old, '历史记录不能被新任务阶段污染');
    const saved = JSON.parse(fs.readFileSync(f.physical('/app/game-export/records/' + id + '.json'), 'utf8')).view;
    assert.equal(saved.id, id); assert.equal(saved.state, phase === 'finished' ? 'succeeded' : 'cancelled');
  } finally { f.close(); }
});

/** 可选草稿损坏不能阻断有效源；新保存先保留原始字节，再建立可用于实际导出的合法草稿。 */
for (const body of ['{broken-json', '{}', '[null]']) test(`invalid draft is optional and quarantined before fresh export: ${body}`, async () => {
  const f = fixture();
  try {
    const request = await f.request('modrinth'); const raw = Buffer.from(body);
    const draft = '/app/game-export/drafts.json'; f.put(draft, raw);
    assert.equal(await f.coordinator.loadDraft('/mc', f.versionId), null);
    assert.deepEqual(fs.readFileSync(f.physical(draft)), raw, '只读加载不改写损坏草稿');
    const source = await f.coordinator.inspectSource('/mc', f.versionId, true);
    assert(!source.issues.some(issue => issue.severity === 'error'));
    await f.coordinator.saveDraft(request);
    assert.deepEqual(await f.coordinator.loadDraft('/mc', f.versionId), request);
    const backups = fs.readdirSync(f.physical('/app/game-export/quarantine'));
    assert.equal(backups.length, 1);
    assert.deepEqual(fs.readFileSync(f.physical('/app/game-export/quarantine/' + backups[0])), raw);
    const preview = await f.coordinator.checkPlan(request); await f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
    assert.equal((await f.terminal()).state, 'succeeded');
  } finally { f.close(); }
});

test('stale isolation draft and rejected previous save do not block fresh source choices', async () => {
  const f = fixture();
  try {
    const request = await f.request('modrinth'); const draft = '/app/game-export/drafts.json';
    const old = JSON.stringify([{ key: '/mc\n' + f.versionId, request: { ...request, gameDir: '/mc', sharedGameDir: true } }]);
    f.put(draft, old); f.put('/mc/versions/' + f.versionId + '/.amcl-modpack.json', '{}');
    assert.equal(await f.coordinator.loadDraft('/mc', f.versionId), null);
    assert.equal(fs.readFileSync(f.physical(draft), 'utf8'), old);
    await assert.rejects(f.coordinator.saveDraft({ ...request, gameDir: '/no-longer-available' }));
    assert.equal(await f.coordinator.loadDraft('/mc', f.versionId), null);
    await f.coordinator.saveDraft(request); assert.deepEqual(await f.coordinator.loadDraft('/mc', f.versionId), request);
    assert(!fs.existsSync(f.physical('/app/game-export/quarantine')), '格式合法的过期条目按正常新选择替换');
  } finally { f.close(); }
});

test('unconfirmed draft quarantine cannot overwrite the original malformed bytes', async () => {
  const f = fixture();
  try {
    const request = await f.request('modrinth'); const draft = '/app/game-export/drafts.json';
    const raw = Buffer.from([0xff, 0xfe, 0x7b, 0x22]); f.put(draft, raw);
    f.state.failDraftBackupFsync = true;
    await assert.rejects(f.coordinator.saveDraft(request), /backup sync/);
    assert.deepEqual(fs.readFileSync(f.physical(draft)), raw);
    f.state.failDraftBackupFsync = false; await f.coordinator.saveDraft(request);
    assert.deepEqual(await f.coordinator.loadDraft('/mc', f.versionId), request);
    for (const name of fs.readdirSync(f.physical('/app/game-export/quarantine'))) {
      assert.deepEqual(fs.readFileSync(f.physical('/app/game-export/quarantine/' + name)), raw);
    }
  } finally { f.close(); }
});

/** 首页只读资格检查不能使另一个向导中已确认的计划失效，也不能自行取得执行资格。 */
test('nonretained eligibility checks preserve the existing wizard preview', async () => {
  const f = fixture();
  try {
    const request = await f.request('modrinth'); const preview = await f.coordinator.checkPlan(request);
    const eligibility = await f.coordinator.checkPlan({ ...request, format: 'curseforge' }, false);
    assert.equal(f.coordinator.previews_.size, 1); assert(f.coordinator.previews_.has(preview.id));
    await assert.rejects(f.coordinator.pickAndStart({ filesDir: '/app' }, eligibility), /计划已失效/);
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
    assert.equal((await f.terminal()).state, 'succeeded');
    f.state.gameRunning = true;
    await assert.rejects(f.coordinator.checkPlan(request, false), /会话/);
  } finally { f.close(); }
});

/** 旧资源输入来源与电脑目标路径分开；候选必须按可信摘要选择，不能只根据exists选首项。 */
for (const layout of ['amcl-legacy', 'official-virtual', 'objects-only', 'corrupt-first']) {
  test(`legacy assets select and freeze the verified source for ${layout}`, async () => {
    const f = fixture();
    try {
      const versionPath = '/mc/versions/1.20.1/1.20.1.json';
      const version = JSON.parse(fs.readFileSync(f.physical(versionPath), 'utf8'));
      const indexPath = '/mc/assets/indexes/test.json';
      const index = JSON.parse(fs.readFileSync(f.physical(indexPath), 'utf8'));
      const [name, object] = Object.entries(index.objects)[0];
      const objectPath = '/mc/assets/objects/' + object.hash.slice(0, 2) + '/' + object.hash;
      const bytes = fs.readFileSync(f.physical(objectPath));
      let expectedSource = objectPath.substring('/mc/'.length);
      if (layout === 'amcl-legacy') {
        expectedSource = 'assets/virtual/legacy/' + name; f.put('/mc/' + expectedSource, bytes); fs.unlinkSync(f.physical(objectPath));
      } else if (layout === 'official-virtual') {
        expectedSource = 'assets/virtual/test/' + name; f.put('/mc/' + expectedSource, bytes); fs.unlinkSync(f.physical(objectPath));
      } else if (layout === 'corrupt-first') f.put('/mc/assets/virtual/legacy/' + name, Buffer.alloc(bytes.length));
      index.virtual = true; index.map_to_resources = true;
      const text = JSON.stringify(index); f.put(indexPath, text);
      version.assetIndex.sha1 = digest(Buffer.from(text)); version.assetIndex.size = Buffer.byteLength(text);
      f.put(versionPath, JSON.stringify(version));
      const sourceIdentity = f.sourceIdentity(); const preview = await f.coordinator.checkPlan(await f.request('full'));
      assert(!preview.issues.some(issue => issue.severity === 'error'), JSON.stringify(preview.issues));
      const dependencies = f.coordinator.previews_.get(preview.id).dependencies.filter(item => item.kind === 'asset');
      assert.equal(dependencies.length, 3); assert(dependencies.every(item => item.sourcePath === expectedSource));
      await f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
      const task = await f.terminal(); assert.equal(task.state, 'succeeded', task.message);
      const entries = f.readZip();
      for (const relative of ['assets/objects/' + object.hash.slice(0, 2) + '/' + object.hash,
        'assets/virtual/test/' + name]) assert.deepEqual(entries['.minecraft/' + relative], bytes);
      assert.deepEqual(entries['.minecraft/versions/' + f.versionId + '/resources/' + name], bytes);
      assert.deepEqual(f.sourceIdentity(), sourceIdentity);
    } finally { f.close(); }
  });
}

for (const kind of ['metadata', 'inventory']) test(`preview→start rejects ${kind} mutation and preserves changed source`, async () => {
  const f = fixture();
  try {
    const request = await f.request(); const preview = await f.coordinator.checkPlan(request);
    if (kind === 'metadata') f.put('/mc/versions/1.20.1/1.20.1.json', fs.readFileSync(f.physical('/mc/versions/1.20.1/1.20.1.json'), 'utf8') + ' ');
    else f.put('/mc/versions/1.20.1/mods/new.jar', 'new user file');
    const current = f.sourceIdentity(); await f.coordinator.pickAndStart({ filesDir: '/app' }, preview); const task = await f.terminal();
    assert.equal(task.state, 'failed'); assert.match(task.message, /变化/); assert.deepEqual(f.sourceIdentity(), current);
    assert.equal(fs.statSync(f.physical(f.state.selectedUri)).size, 0);
  } finally { f.close(); }
});

test('picker cancel creates no heavy task or download and is not failure', async () => {
  const f = fixture({ missingLibrary: true });
  try {
    const source = f.sourceIdentity(); const preview = await f.coordinator.checkPlan(await f.request()); f.state.pickerCancel = true;
    assert.equal(await f.coordinator.pickAndStart({ filesDir: '/app' }, preview), ''); assert.equal(f.coordinator.getTask(), null);
    assert.equal(f.state.downloadCalls, 0); assert.deepEqual(f.sourceIdentity(), source);
  } finally { f.close(); }
});

test('cancel waits for fake Native owner purge and releases source protection', async () => {
  const f = fixture({ missingLibrary: true });
  try {
    const source = f.sourceIdentity(); const preview = await f.coordinator.checkPlan(await f.request());
    const unsubscribe = f.coordinator.subscribe(() => { const view = f.coordinator.getTask();
      if (view?.state === 'running' && view.message.startsWith('准备电脑依赖')) f.coordinator.cancelTask(); });
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview); const task = await f.terminal(); unsubscribe();
    assert.equal(task.state, 'cancelled', task.message); assert.equal(f.state.purges, 1); assert.deepEqual(f.sourceIdentity(), source);
  } finally { f.close(); }
});

test('target ENOSPC fails with partial-file explanation and unchanged source', async () => {
  const f = fixture();
  try {
    f.put('/mc/versions/1.20.1/mods/large.jar', crypto.randomBytes(140001));
    const source = f.sourceIdentity(); const preview = await f.coordinator.checkPlan(await f.request()); f.state.targetWriteFailure = true;
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview); const task = await f.terminal();
    assert.equal(task.state, 'failed'); assert.match(task.message, /半成品|未完成文件/); assert.deepEqual(f.sourceIdentity(), source);
    assert(fs.statSync(f.physical(f.state.selectedUri)).size > 0); assert(fs.statSync(f.physical(f.state.selectedUri)).size < preview.totalBytes);
  } finally { f.close(); }
});

test('snapshot-phase inventory addition invalidates the export without deleting the new source data', async () => {
  const f = fixture();
  try {
    const preview = await f.coordinator.checkPlan(await f.request()); let injected = false;
    const unsubscribe = f.coordinator.subscribe(() => {
      if (!injected && f.coordinator.getTask()?.stage === '冻结输入') {
        injected = true; f.put('/mc/versions/1.20.1/mods/new-during-snapshot.jar', 'external addition');
      }
    });
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview); const task = await f.terminal(); unsubscribe();
    assert.equal(task.state, 'failed'); assert.match(task.message, /变化/);
    assert.equal(fs.readFileSync(f.physical('/mc/versions/1.20.1/mods/new-during-snapshot.jar'), 'utf8'), 'external addition');
    assert.equal(fs.statSync(f.physical(f.state.selectedUri)).size, 0);
  } finally { f.close(); }
});

/** 标准包没有本地运行库前置；缺的PC字节不应被读取或下载到无关的覆盖目录。 */
for (const format of ['modrinth', 'curseforge']) test(`${format} exports selected content without local game payload`, async () => {
  const f = fixture();
  try {
    const request = await f.request(format);
    for (const directory of ['assets', 'libraries']) fs.rmSync(f.physical('/mc/' + directory), { recursive: true, force: true });
    fs.unlinkSync(f.physical('/mc/versions/1.20.1/1.20.1.jar'));
    const payloadReads = [];
    f.state.onRead = name => { if (name.startsWith('/mc/assets/') || name.startsWith('/mc/libraries/') || name.endsWith('/1.20.1.jar')) payloadReads.push(name); };
    const preview = await f.coordinator.checkPlan(request);
    assert(!preview.issues.some(issue => issue.severity === 'error'), JSON.stringify(preview.issues));
    assert.equal(preview.downloads, 0);
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
    const task = await f.terminal(); assert.equal(task.state, 'succeeded', task.message);
    assert.equal(task.readbackVerified, true); assert.equal(f.state.downloadCalls, 0); assert.deepEqual(payloadReads, []);
    const entries = f.readZip();
    assert(!Object.keys(entries).some(name => name.startsWith('.minecraft/') || name.startsWith('assets/') || name.startsWith('libraries/')));
    assert.deepEqual(entries['overrides/options.txt'], Buffer.from('music:0.5\n'));
  } finally { f.close(); }
});

/** 标准包仍依赖可确认的版本/加载器身份及实际选中内容，不可退化为任意目录打包。 */
for (const format of ['modrinth', 'curseforge']) for (const kind of ['missing-main', 'unknown-loader', 'missing-parent', 'selected-content-change']) {
  test(`${format} still rejects invalid identity or selected source: ${kind}`, async () => {
    const f = fixture();
    try {
      const request = await f.request(format);
      const versionPath = '/mc/versions/1.20.1/1.20.1.json';
      if (kind === 'selected-content-change') {
        const preview = await f.coordinator.checkPlan(request);
        f.put('/mc/versions/1.20.1/options.txt', 'changed after check');
        await f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
        assert.equal((await f.terminal()).state, 'failed');
      } else {
        const version = JSON.parse(fs.readFileSync(f.physical(versionPath), 'utf8'));
        if (kind === 'missing-main') delete version.mainClass;
        else if (kind === 'unknown-loader') version.mainClass = 'unknown.loader.Bootstrap';
        else version.inheritsFrom = 'missing-parent';
        f.put(versionPath, JSON.stringify(version));
        if (kind === 'missing-parent') await assert.rejects(f.coordinator.checkPlan(request));
        else {
          const preview = await f.coordinator.checkPlan(request);
          assert(preview.issues.some(issue => issue.severity === 'error'));
          await assert.rejects(f.coordinator.pickAndStart({ filesDir: '/app' }, preview), /预览/);
          assert.equal(f.state.pickerCalls, 0);
        }
      }
      assert.equal(f.state.downloadCalls, 0);
    } finally { f.close(); }
  });
}

/** 相同缺件对完整包仍是错误，不能用标准包合同放松本地运行闭包。 */
test('full pack still rejects a missing common Java library', async () => {
  const f = fixture();
  try {
    const request = await f.request('full'); fs.unlinkSync(f.physical('/mc/libraries/example/core/1/core-1.jar'));
    const preview = await f.coordinator.checkPlan(request);
    assert(preview.issues.some(issue => issue.code === 'SOURCE_FILE_INVALID' && issue.path.includes('example/core')));
    await assert.rejects(f.coordinator.pickAndStart({ filesDir: '/app' }, preview), /预览/); assert.equal(f.state.pickerCalls, 0);
  } finally { f.close(); }
});

test('recovery marks interrupted work as failed and never starts background output', async () => {
  const f = fixture();
  try {
    const request = await f.request(); const id = '1234567890123-test';
    f.put('/app/game-export/records/' + id + '.json', JSON.stringify({ schemaVersion: 1, updatedAt: 1,
      view: { id, request, state: 'running', stage: '写入目标', message: '', filename: 'old.zip' } }));
    await f.coordinator.recover({ filesDir: '/app' }); const task = f.coordinator.getTask();
    assert.equal(task.id, id); assert.equal(task.state, 'failed'); assert.match(task.message, /进程已结束|中断/);
    assert.equal(f.state.pickerCalls, 0); assert.equal(f.state.downloadCalls, 0);
  } finally { f.close(); }
});

/**
 * 完整包必须有可枚举、可核验的运行闭包。这些负例防止planner拒绝生成dependency后，
 * 上层漏掉错误而误判无缺失；标准包另测不读取、不下载未输出的PC字节。
 */
for (const format of ['full']) for (const kind of [
  'missing-client-and-jar', 'client-sha1', 'client-size', 'asset-index-sha1', 'asset-index-size', 'logging-file', 'common-artifact',
]) {
  test(`${format} blocks invalid source metadata: ${kind}`, async () => {
    const f = fixture();
    try {
      const request = await f.request(format);
      const version = JSON.parse(fs.readFileSync(f.physical('/mc/versions/1.20.1/1.20.1.json'), 'utf8'));
      if (kind === 'missing-client-and-jar') {
        delete version.downloads.client; fs.unlinkSync(f.physical('/mc/versions/1.20.1/1.20.1.jar'));
      } else if (kind === 'client-sha1') version.downloads.client.sha1 = 'not-a-digest';
      else if (kind === 'client-size') version.downloads.client.size = 0;
      else if (kind === 'asset-index-sha1') version.assetIndex.sha1 = 'bad';
      else if (kind === 'asset-index-size') version.assetIndex.size = 0;
      else if (kind === 'logging-file') version.logging = { client: { file: { id: 'client.xml', url: 'https://example.invalid/client.xml', sha1: 'invalid', size: 0 } } };
      else version.libraries[0].downloads.artifact.sha1 = 'broken';
      f.put('/mc/versions/1.20.1/1.20.1.json', JSON.stringify(version));
      const preview = await f.coordinator.checkPlan(request);
      assert(preview.issues.some(issue => issue.severity === 'error'), JSON.stringify(preview.issues));
      await assert.rejects(f.coordinator.pickAndStart({ filesDir: '/app' }, preview), /预览/);
      assert.equal(f.state.pickerCalls, 0); assert.equal(f.state.downloadCalls, 0);
    } finally { f.close(); }
  });
}

/** 合法电脑版native由标准包接收端安装；缺它不能反向要求手机事先安装Windows native。 */
for (const format of ['modrinth', 'curseforge']) test(`${format} permits missing valid PC-only native artifacts`, async () => {
  const f = fixture();
  try {
    const request = await f.request(format); const version = JSON.parse(fs.readFileSync(f.physical('/mc/versions/1.20.1/1.20.1.json'), 'utf8'));
    version.libraries.push({ name: 'example:native:1', natives: { windows: 'natives-windows' }, downloads: {
      classifiers: { 'natives-windows': { path: 'example/native/1/native-1-natives-windows.jar',
        url: 'https://example.invalid/native-1-windows.jar', sha1: digest(Buffer.from('pc native bytes')), size: 15 } } } });
    f.put('/mc/versions/1.20.1/1.20.1.json', JSON.stringify(version));
    const preview = await f.coordinator.checkPlan(request);
    assert(!preview.issues.some(issue => issue.severity === 'error'), JSON.stringify(preview.issues));
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview); const task = await f.terminal();
    assert.equal(task.state, 'succeeded', task.message); assert.equal(f.state.downloadCalls, 0);
  } finally { f.close(); }
});

test('unreleased previous Native owner blocks a second export until actual purge succeeds', async () => {
  const f = fixture();
  try {
    const preview = await f.coordinator.checkPlan(await f.request('modrinth'));
    // 模拟前一下载终态已展示、真实worker仍持有旧目录的状态，避免测试机械等待30秒超时。
    f.coordinator.downloadIds_.add(777); f.state.downloads = [{ taskId: 777, state: 'Finished' }]; f.state.purgeAllowed = false;
    await assert.rejects(f.coordinator.pickAndStart({ filesDir: '/app' }, preview), /owner.*释放/);
    assert.equal(f.state.pickerCalls, 0); assert.equal(f.state.downloadCalls, 0); assert.deepEqual([...f.coordinator.downloadIds_], [777]);
    f.state.purgeAllowed = true; assert(await f.coordinator.pickAndStart({ filesDir: '/app' }, preview));
    assert.equal((await f.terminal()).state, 'succeeded'); assert.equal(f.coordinator.downloadIds_.size, 0);
  } finally { f.close(); }
});

test('initial private record write failure closes the reservation and permits an explicit retry', async () => {
  const f = fixture();
  try {
    const source = f.sourceIdentity(); const preview = await f.coordinator.checkPlan(await f.request()); f.state.recordFailure = 'initial';
    await assert.rejects(f.coordinator.pickAndStart({ filesDir: '/app' }, preview), /记录保存失败/);
    assert.equal(f.coordinator.getTask().state, 'failed'); assert.equal(f.state.downloadCalls, 0); assert.equal(f.coordinator.execution_, undefined);
    const owner = f.load('feature_core/src/main/ets/download/ProcessActivityCoordinator.ets').ProcessActivityCoordinator.instance();
    const lease = owner.acquireSharedGame(); lease.releasePreparation();
    assert.equal(fs.statSync(f.physical(f.state.selectedUri)).size, 0); assert.deepEqual(f.sourceIdentity(), source);
    assert(await f.coordinator.pickAndStart({ filesDir: '/app' }, preview)); assert.equal((await f.terminal()).state, 'succeeded');
  } finally { f.close(); }
});

test('terminal private record failure still publishes completion and releases all task owners', async () => {
  const f = fixture();
  try {
    const source = f.sourceIdentity(); const preview = await f.coordinator.checkPlan(await f.request('curseforge')); f.state.recordFailure = 'terminal';
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview); const task = await f.terminal();
    assert.equal(task.state, 'succeeded'); assert.equal(task.readbackVerified, true); assert(f.state.recordFailureUsed);
    assert.match(task.message, /记录|保存/); assert.equal(f.coordinator.execution_, undefined);
    assert.equal(f.state.registryLease, 0); assert.equal(f.state.versionLease, 0); assert.deepEqual(f.sourceIdentity(), source);
    assert(!fs.existsSync(f.physical('/app/game-export/work/' + task.id)), 'settled owner must clean its own completed work');
  } finally { f.close(); }
});

/** 普通库不能因规则或旧坐标解析失败而从源完整性闭包静默消失。 */
for (const kind of ['invalid-rules', 'invalid-legacy-path']) test(`full pack rejects ordinary library ${kind}`, async () => {
  const f = fixture();
  try {
    const request = await f.request('full');
    const version = JSON.parse(fs.readFileSync(f.physical('/mc/versions/1.20.1/1.20.1.json'), 'utf8'));
    if (kind === 'invalid-rules') version.libraries[0].rules = 'not-an-array';
    else version.libraries[0] = { name: '../invalid:maven:coordinate' };
    f.put('/mc/versions/1.20.1/1.20.1.json', JSON.stringify(version));
    const preview = await f.coordinator.checkPlan(request);
    assert(preview.issues.some(issue => issue.severity === 'error' && issue.code ===
      (kind === 'invalid-rules' ? 'LIBRARY_RULES' : 'LEGACY_LIBRARY_PATH')), JSON.stringify(preview.issues));
    await assert.rejects(f.coordinator.pickAndStart({ filesDir: '/app' }, preview), /预览/);
    assert.equal(f.state.pickerCalls, 0); assert.equal(f.state.downloadCalls, 0);
  } finally { f.close(); }
});

/**
 * 固定发布身份与官方profile形态的合成小样本。安装器与产物内容在夹具内生成，绝不把它们
 * 当成真实Minecraft发行件；URL、侧车摘要、内嵌来源、private processor和最终归档走生产链路。
 */
function configureForgelike(f, modern = false) {
  const minecraft = modern ? '1.21.1' : '1.12.2', loader = modern ? '21.1.9' : '14.23.5.2864';
  const artifactVersion = modern ? loader : minecraft + '-' + loader;
  const group = modern ? 'net.neoforged' : 'net.minecraftforge', product = modern ? 'neoforge' : 'forge';
  const coordinate = group + ':' + product + ':' + artifactVersion;
  const relative = group.replaceAll('.', '/') + '/' + product + '/' + artifactVersion + '/' + product + '-' + artifactVersion;
  const baseUrl = modern ? 'https://maven.neoforged.net/releases/' : 'https://maven.minecraftforge.net/';
  const installerUrl = baseUrl + relative + '-installer.jar';
  const loaderJar = lifecycleJar({ 'net/minecraftforge/common/MinecraftForge.class': Buffer.from([0xca, 0xfe, 0xba, 0xbe, 0, 1]) });
  const universalJar = lifecycleJar({ 'META-INF/neoforge.mods.toml': 'modLoader="javafml"\n', 'net/neoforged/neoforge/common/NeoForge.class': 'fixture class' });
  const toolJar = lifecycleJar({ 'META-INF/MANIFEST.MF': 'Manifest-Version: 1.0\nMain-Class: example.Processor\n', 'example/Processor.class': 'fixture processor' });
  const plain = JSON.parse(fs.readFileSync(f.physical('/mc/versions/1.20.1/1.20.1.json'), 'utf8'));
  plain.clientVersion = minecraft; plain.javaVersion = { majorVersion: modern ? 21 : 8 };
  let profile, installerVersion, bundle;
  const outputs = {
    srg: 'libraries/net/minecraft/client/1.21.1-20240808.144430/client-1.21.1-20240808.144430-srg.jar',
    extra: 'libraries/net/minecraft/client/1.21.1-20240808.144430/client-1.21.1-20240808.144430-extra.jar',
    patched: 'libraries/' + relative + '-client.jar',
  };
  if (modern) {
    plain.mainClass = 'cpw.mods.bootstraplauncher.BootstrapLauncher';
    plain.arguments.game.push('--fml.neoForgeVersion', loader, '--fml.mcVersion', minecraft, '--fml.neoFormVersion', '20240808.144430');
    const universalPath = relative + '-universal.jar', toolPath = 'net/neoforged/installertools/binarypatcher/2.1.2/binarypatcher-2.1.2.jar';
    const universal = { name: coordinate + ':universal', downloads: { artifact: { path: universalPath, url: baseUrl + universalPath, sha1: digest(universalJar), size: universalJar.length } } };
    const tool = { name: 'net.neoforged.installertools:binarypatcher:2.1.2', downloads: { artifact: {
      path: toolPath, url: baseUrl + toolPath, sha1: digest(toolJar), size: toolJar.length } } };
    installerVersion = { id: 'neoforge-' + loader, inheritsFrom: minecraft, mainClass: plain.mainClass,
      arguments: { game: plain.arguments.game.filter(value => !['--username', '${auth_player_name}'].includes(value)), jvm: [] }, libraries: [], javaVersion: { majorVersion: 21 } };
    profile = { spec: 1, version: installerVersion.id, minecraft, json: '/version.json', data: {
      PATCHED: { client: '[' + coordinate + ':client]' }, MC_SRG: { client: '[net.minecraft:client:1.21.1-20240808.144430:srg]' },
      MC_EXTRA: { client: '[net.minecraft:client:1.21.1-20240808.144430:extra]' },
    }, processors: [{ sides: ['client'], jar: tool.name, classpath: [], args: ['--output', '{PATCHED}'] }], libraries: [tool, universal] };
    bundle = { 'install_profile.json': JSON.stringify(profile), 'version.json': JSON.stringify(installerVersion) };
    f.network.set(baseUrl + universalPath, universalJar); f.network.set(baseUrl + toolPath, toolJar);
    // 即使源里放了同名坏生成件，缺官方hash的现代管线仍须在私有root重新生成，不能只验存在。
    for (const target of Object.values(outputs)) f.put('/mc/' + target, 'untrusted existing generated bytes');
    for (const entry of ['release', 'lib/server/libjvm.so', 'lib/modules']) f.put('/app/jdk/21/' + entry, 'fixture installed JDK input');
    f.state.processor = async (_profile, _unpacked, runtimeRoot, libRoot, _filesDir, gameVersion, jdk, _xmx, _kind, callback) => {
      assert(runtimeRoot.startsWith('/app/game-export/work/') && runtimeRoot.endsWith('/forgelike/runtime'));
      assert.equal(libRoot, runtimeRoot + '/libraries'); assert.equal(gameVersion, minecraft); assert.equal(jdk, '21');
      assert.deepEqual(fs.readFileSync(f.physical(runtimeRoot + '/versions/' + minecraft + '/' + minecraft + '.jar')),
        fs.readFileSync(f.physical('/mc/versions/1.20.1/1.20.1.jar')));
      assert.equal(digest(fs.readFileSync(f.physical(libRoot + '/' + toolPath))), digest(toolJar));
      callback({ message: 'fixture Native processor executing' });
      if (f.state.processorStarted) f.state.processorStarted(); if (f.state.processorGate) await f.state.processorGate;
      f.put(runtimeRoot + '/' + outputs.srg, lifecycleJar({ 'net/minecraft/client/Minecraft.class': 'verified fixture SRG class' }));
      f.put(runtimeRoot + '/' + outputs.extra, lifecycleJar({ 'assets/minecraft/lang/en_us.json': '{"fixture":true}' }));
      f.put(runtimeRoot + '/' + outputs.patched, lifecycleJar({ 'net/minecraft/client/ForgePatched.class': 'verified fixture patch' }));
      return { success: true, ranCount: 1, patchedClientPath: runtimeRoot + '/' + outputs.patched };
    };
  } else {
    const loaderArtifact = { path: relative + '.jar', url: '', sha1: digest(loaderJar), size: loaderJar.length };
    plain.mainClass = 'net.minecraft.launchwrapper.Launch'; plain.minecraftArguments = '--tweakClass net.minecraftforge.fml.common.launcher.FMLTweaker';
    plain.libraries.push({ name: coordinate, downloads: { artifact: loaderArtifact } });
    installerVersion = { id: minecraft + '-forge-' + loader, inheritsFrom: minecraft, mainClass: plain.mainClass,
      minecraftArguments: plain.minecraftArguments, libraries: [{ name: coordinate, downloads: { artifact: loaderArtifact } }] };
    const embedded = 'forge-' + artifactVersion + '-universal.jar';
    profile = { install: { minecraft, path: coordinate, filePath: embedded }, versionInfo: installerVersion };
    bundle = { 'install_profile.json': JSON.stringify(profile), [embedded]: loaderJar };
  }
  f.put('/mc/versions/1.20.1/1.20.1.json', JSON.stringify(plain)); f.network.set(installerUrl, lifecycleJar(bundle));
  // 用例可按真实profile/版本字段重生安装器ZIP，修改后的侧车和SHA仍由生产下载链核验。
  return { minecraft, loader, installerUrl, relative, outputs, loaderJar, universalJar, toolJar,
    profile, installerVersion, bundle, plain, baseUrl };
}

for (const modern of [false, true]) test(`complete export ${modern ? 'NeoForge processor rebuild' : 'legacy embedded Forge'} runs actual preparation and preserves source`, async () => {
  const f = fixture();
  try {
    const setup = configureForgelike(f, modern), before = f.sourceIdentity(); const preview = await f.coordinator.checkPlan(await f.request());
    assert(!preview.issues.some(issue => issue.severity === 'error'), JSON.stringify(preview.issues));
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview); const task = await f.terminal(); assert.equal(task.state, 'succeeded', task.message);
    const entries = f.readZip(); assert.deepEqual(f.sourceIdentity(), before); assert.equal(f.state.processorCalls, modern ? 1 : 0);
    const report = JSON.parse(entries['amcl-export.json']); assert.equal(report.minecraft, setup.minecraft);
    if (modern) {
      for (const target of Object.values(setup.outputs)) assert(entries['.minecraft/' + target]);
      assert(!Object.keys(entries).some(name => name.includes('binarypatcher') || name.includes('installer.jar')));
      const generated = report.files.filter(file => file.provenance?.preparation === 'verified-processor-rebuild'); assert.equal(generated.length, 3);
    } else assert.deepEqual(entries['.minecraft/libraries/' + setup.relative + '.jar'], setup.loaderJar);
  } finally { f.close(); }
});

/**
 * 真实偏好状态与真实Maven候选builder贯穿installer/processor到实际Native计划。
 * mirror与official是方向相反的对照：任一层固定true，或Coordinator把直链塞回队首，
 * 至少mirror断言会失败；全部来源bytes另行映射，成功导出仍须校验完整安装器及ZIP。
 */
for (const modern of [false, true]) for (const mode of ['mirror', 'official']) {
  test(`complete ${modern ? 'NeoForge processor' : 'legacy Forge'} export preserves ${mode}-first source setting in real plans`, async () => {
    const f = fixture();
    try {
      const setup = configureForgelike(f, modern), mirrorBase = 'https://bmclapi2.bangbang93.com/';
      f.state.useProductionMavenCandidates = true;
      f.sourcePolicy.setMcSourcePreference(mode);
      assert.equal(f.sourcePolicy.getMcSourcePreference(), mode);
      // 预期次序直接来自政策和独立工件路径，不能用被测builder生成期望再与自己比较。
      const expectedUrls = (relative, direct) => {
        const mirrors = [mirrorBase + 'maven/' + relative, mirrorBase + 'libraries/' + relative];
        return mode === 'mirror' ? [...mirrors, direct] : [direct, ...mirrors];
      };
      const artifacts = [{ path: setup.relative + '-installer.jar', url: setup.installerUrl },
        ...(modern ? setup.profile.libraries.map(library => library.downloads.artifact) : [])];
      for (const artifact of artifacts) {
        const bytes = f.network.get(artifact.url); assert(bytes);
        for (const url of expectedUrls(artifact.path, artifact.url)) f.network.set(url, bytes);
      }
      const before = f.sourceIdentity(), preview = await f.coordinator.checkPlan(await f.request());
      assert(!preview.issues.some(issue => issue.severity === 'error'), JSON.stringify(preview.issues));
      await f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
      const task = await f.terminal(); assert.equal(task.state, 'succeeded', task.message);
      for (const artifact of artifacts) {
        const file = f.state.downloadPlans.flatMap(plan => plan.files)
          .find(file => file.localPath.endsWith('/' + artifact.path));
        assert(file, '工件必须进入真实提交的Native计划：' + artifact.path);
        assert.deepEqual(file.urls, expectedUrls(artifact.path, artifact.url));
      }
      const installerUrls = expectedUrls(artifacts[0].path, setup.installerUrl);
      assert.deepEqual(f.state.sidecarCalls[0], { url: installerUrls[0] + '.sha1',
        mirrors: installerUrls.slice(1).map(url => url + '.sha1'), timeoutSeconds: 30 });
      assert.equal(f.state.mavenCalls.length, artifacts.length);
      assert(f.state.mavenCalls.every(call => call.preferRealSource === (mode === 'official')),
        'installer和processor两层都必须读到现有用户源偏好');
      assert.equal(f.state.processorCalls, modern ? 1 : 0);
      assert.deepEqual(f.sourceIdentity(), before);
      const zip = f.readZip();
      if (modern) for (const target of Object.values(setup.outputs)) assert(zip['.minecraft/' + target]);
      else assert.deepEqual(zip['.minecraft/libraries/' + setup.relative + '.jar'], setup.loaderJar);
      assert.equal(f.coordinator.downloadIds_.size, 0);
    } finally { f.close(); }
  });
}

/** 两个平台计划重复引用真实公共库时只读一次；独立检查永远新建作用域。 */
test('checkPlan shares one digest across source and desktop loops but never across independent checks', async () => {
  const f = fixture();
  try {
    const target = '/mc/libraries/example/core/1/core-1.jar'; let reads = 0;
    f.state.onRead = source => { if (source === target) reads++; };
    const request = await f.request();
    const first = await f.coordinator.checkPlan(request);
    assert(!first.issues.some(issue => issue.severity === 'error')); assert.equal(reads, 1);
    const eligibility = await f.coordinator.checkPlan(request, false);
    assert(!eligibility.issues.some(issue => issue.severity === 'error')); assert.equal(reads, 2);
    await f.coordinator.checkPlan(request); assert.equal(reads, 3);
    assert.equal(f.state.downloadCalls, 0);
  } finally { f.close(); }
});

/** 最终冻结实际复制仍执行源摘要、复制读取、源再摘要，检查memo不进入交付链。 */
test('snapshot freeze keeps fresh source reads after checkPlan digest reuse', async () => {
  const f = fixture();
  try {
    const target = '/mc/libraries/example/core/1/core-1.jar'; let freezeReads = 0;
    f.state.onRead = source => { if (source === target && f.state.registryLease === 1 && f.state.versionLease === 1) freezeReads++; };
    const before = f.sourceIdentity(), preview = await f.coordinator.checkPlan(await f.request());
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
    const task = await f.terminal(); assert.equal(task.state, 'succeeded', task.message);
    assert(freezeReads >= 3, '冻结后仍须fresh源hash、复制和源再hash，不能沿用检查memo');
    assert.deepEqual(f.readZip()['.minecraft/libraries/example/core/1/core-1.jar'], Buffer.from('common library bytes'));
    assert.deepEqual(f.sourceIdentity(), before);
  } finally { f.close(); }
});

test('equal-length source mutation during freeze is detected despite a previously valid check memo', async () => {
  const f = fixture();
  try {
    const target = '/mc/libraries/example/core/1/core-1.jar', changed = Buffer.from('changed library byte'); let mutated = false;
    assert.equal(changed.length, Buffer.byteLength('common library bytes'));
    const preview = await f.coordinator.checkPlan(await f.request());
    f.state.onRead = source => {
      if (source === target && f.state.registryLease === 1 && f.state.versionLease === 1 && !mutated) {
        mutated = true; f.put(target, changed);
      }
    };
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
    const task = await f.terminal(); assert.equal(task.state, 'failed'); assert(mutated);
    assert.match(task.message, /源文件已变化|文件发生变化/);
    assert.deepEqual(fs.readFileSync(f.physical(target)), changed, '失败不得删除测试期间新写入的源资料');
    assert.equal(task.readbackVerified, false);
  } finally { f.close(); }
});

test('legacy Forge exports two missing independent runtime libraries in one real Native plan and ZIP bytes', async () => {
  const f = fixture();
  try {
    const setup = configureForgelike(f, false);
    const artifacts = ['first', 'second'].map((name, index) => {
      const bytes = lifecycleJar({ ['example/' + name + '.class']: 'distinct runtime fixture ' + index });
      const path = 'org/lwjgl/export-' + name + '/1/export-' + name + '-1.jar';
      const url = 'https://runtime-' + name + '.invalid/' + path;
      const library = { name: 'org.lwjgl:export-' + name + ':1', rules: [{ action: 'allow', os: { name: 'windows' } }],
        downloads: { artifact: { path, url, sha1: digest(bytes), size: bytes.length } } };
      setup.plain.libraries.push(library); setup.installerVersion.libraries.push(library); f.network.set(url, bytes);
      return { ...library.downloads.artifact, bytes };
    });
    // 源实例保持完整，新增缺件只面向Windows。profile.versionInfo及实际installer字节
    // 一起更新，不能绕过安装器/侧车校验或直接把预期内容塞入导出缓存。
    setup.bundle['install_profile.json'] = JSON.stringify(setup.profile);
    f.network.set(setup.installerUrl, lifecycleJar(setup.bundle));
    f.put('/mc/versions/1.20.1/1.20.1.json', JSON.stringify(setup.plain));
    const before = f.sourceIdentity(), preview = await f.coordinator.checkPlan(await f.request());
    assert(!preview.issues.some(issue => issue.severity === 'error'), JSON.stringify(preview.issues));
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
    const task = await f.terminal(); assert.equal(task.state, 'succeeded', task.message);
    const batch = f.state.downloadPlans.find(plan => artifacts.every(item => plan.files.some(file => file.localPath.endsWith('/libraries/' + item.path))));
    assert(batch, '同一运行闭包必须经过一个实际提交的Native批次'); assert.equal(batch.files.length, 2);
    const zip = f.readZip();
    for (const item of artifacts) {
      const file = batch.files.find(file => file.localPath.endsWith('/libraries/' + item.path));
      assert.equal(file.check.sha1, item.sha1); assert.equal(file.check.size, item.size);
      assert.deepEqual(file.urls, [item.url]);
      assert.deepEqual(zip['.minecraft/libraries/' + item.path], item.bytes);
    }
    assert.deepEqual(f.sourceIdentity(), before); assert.equal(f.coordinator.downloadIds_.size, 0);
    assert.equal(f.state.processorCalls, 0);
  } finally { f.close(); }
});

test('modern Forge-like batches remote processor libraries with MOJMAPS and keeps per-path candidates and verified bytes', async () => {
  const f = fixture();
  try {
    const setup = configureForgelike(f, true);
    const mappingBytes = Buffer.from('fixture mappings with exact SHA and size\n');
    const mappingPath = 'net/minecraft/client/1.21.1/client-1.21.1-mappings.txt';
    const mappingUrl = 'https://mapping-fixture.invalid/client-mappings.txt?revision=fixture';
    setup.plain.downloads.client_mappings = { url: mappingUrl, sha1: digest(mappingBytes), size: mappingBytes.length };
    setup.profile.data.MOJMAPS = { client: '[net.minecraft:client:1.21.1:mappings@txt]' };
    f.network.set(mappingUrl, mappingBytes);
    const remote = setup.profile.libraries.map((library, index) => {
      const artifact = library.downloads.artifact;
      const mirror = 'https://processor-mirror-' + index + '.invalid/' + artifact.path;
      // 与原来的direct-first用例方向相反；重复/非HTTPS必须被过滤，首件故意缺原URL，
      // 证明Coordinator只在末尾补回合法直链，而且不能修改输入数组或借用兄弟候选。
      const declared = index === 0 ? [mirror, mirror, 'http://insecure.invalid/' + artifact.path]
        : [mirror, artifact.url, mirror, 'file:///unexpected.jar'];
      const bytes = f.network.get(artifact.url); f.network.set(mirror, bytes);
      f.state.mavenCandidates.set(artifact.url, declared);
      return { ...artifact, candidates: [mirror, artifact.url], declared: [...declared], bytes };
    });
    setup.bundle['install_profile.json'] = JSON.stringify(setup.profile);
    f.network.set(setup.installerUrl, lifecycleJar(setup.bundle));
    f.put('/mc/versions/1.20.1/1.20.1.json', JSON.stringify(setup.plain));
    const originalProcessor = f.state.processor; let verifiedBeforeProcessor = false;
    f.state.processor = async (...args) => {
      const runtimeRoot = args[2];
      // Native processor端口收到控制之前必须已有真实、完整、独立校验后的输入字节。
      for (const item of remote) assert.deepEqual(fs.readFileSync(f.physical(runtimeRoot + '/libraries/' + item.path)), item.bytes);
      assert.deepEqual(fs.readFileSync(f.physical(runtimeRoot + '/libraries/' + mappingPath)), mappingBytes);
      const batch = f.state.downloadPlans.find(plan => plan.files.some(file => file.localPath === runtimeRoot + '/libraries/' + mappingPath));
      assert(batch); assert.equal(batch.files.length, remote.length + 1);
      for (const item of remote) {
        const file = batch.files.find(file => file.localPath === runtimeRoot + '/libraries/' + item.path);
        assert(file); assert.deepEqual(file.urls, item.candidates, '候选必须随工件path进入批次，不能丢失或借用另一文件候选');
        assert.equal(file.check.sha1, item.sha1); assert.equal(file.check.size, item.size);
      }
      const mapping = batch.files.find(file => file.localPath === runtimeRoot + '/libraries/' + mappingPath);
      assert.deepEqual(mapping.urls, [mappingUrl]); assert.equal(mapping.check.sha1, digest(mappingBytes));
      assert.equal(mapping.check.size, mappingBytes.length); assert.equal(f.coordinator.downloadIds_.size, 0);
      verifiedBeforeProcessor = true; return originalProcessor(...args);
    };
    const before = f.sourceIdentity(), preview = await f.coordinator.checkPlan(await f.request());
    assert(!preview.issues.some(issue => issue.severity === 'error'), JSON.stringify(preview.issues));
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
    const task = await f.terminal(); assert.equal(task.state, 'succeeded', task.message);
    assert(verifiedBeforeProcessor); assert.equal(f.state.processorCalls, 1);
    for (const item of remote) assert.deepEqual(f.state.mavenCandidates.get(item.url), item.declared,
      '候选清洗不得原位改写调用方数组');
    const zip = f.readZip(); for (const target of Object.values(setup.outputs)) assert(zip['.minecraft/' + target]);
    assert.deepEqual(f.sourceIdentity(), before); assert.equal(f.coordinator.downloadIds_.size, 0);
  } finally { f.close(); }
});

test('modern processor artifact with an explicit path and URL retains that URL when its missing name yields no Maven candidates', async () => {
  const f = fixture();
  try {
    const setup = configureForgelike(f, true);
    const bytes = lifecycleJar({ 'example/PathOnlyInput.class': 'processor input without a Maven name' });
    const artifact = { path: 'private/path-only/1/path-only-1.jar',
      url: 'https://explicit-artifact.invalid/path-only.jar?revision=fixture', sha1: digest(bytes), size: bytes.length };
    // 真实profile中只有显式artifact身份，没有name。空候选来自生产builder的非法坐标
    // 分支；AST只抽取原声明并绑定真实parseMavenName，不在fixture复制其返回判断。
    const emptyBuilder = f.load('selected-empty-name-builder', 'import { parseMavenName } from "feature_core";\n'
      + f.selected('feature_core/src/main/ets/modloader/MavenSpecBuilder.ets', ['buildMavenUrls']));
    const candidates = emptyBuilder.buildMavenUrls('', undefined, true, artifact.url);
    assert.deepEqual(candidates, []); f.state.mavenCandidates.set(artifact.url, candidates);
    setup.profile.libraries.push({ downloads: { artifact } }); f.network.set(artifact.url, bytes);
    setup.bundle['install_profile.json'] = JSON.stringify(setup.profile);
    f.network.set(setup.installerUrl, lifecycleJar(setup.bundle));
    const originalProcessor = f.state.processor; let received = false;
    f.state.processor = async (...args) => {
      const target = args[2] + '/libraries/' + artifact.path;
      assert.deepEqual(fs.readFileSync(f.physical(target)), bytes);
      const batch = f.state.downloadPlans.find(plan => plan.files.some(file => file.localPath === target));
      const file = batch?.files.find(file => file.localPath === target); assert(file);
      assert.deepEqual(file.urls, [artifact.url], '空扩展候选不能抹掉可信artifact原URL');
      assert.equal(file.check.sha1, artifact.sha1); assert.equal(file.check.size, artifact.size);
      received = true; return originalProcessor(...args);
    };
    const before = f.sourceIdentity(), preview = await f.coordinator.checkPlan(await f.request());
    assert(!preview.issues.some(issue => issue.severity === 'error'), JSON.stringify(preview.issues));
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
    const task = await f.terminal(); assert.equal(task.state, 'succeeded', task.message);
    assert(received); assert.equal(f.state.processorCalls, 1); assert.equal(f.coordinator.downloadIds_.size, 0);
    assert.deepEqual(f.sourceIdentity(), before);
  } finally { f.close(); }
});

test('modern NeoForge rebuild reports missing installed JDK without touching source', async () => {
  const f = fixture();
  try {
    configureForgelike(f, true); fs.rmSync(f.physical('/app/jdk'), { recursive: true }); const before = f.sourceIdentity();
    const preview = await f.coordinator.checkPlan(await f.request()); await f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
    const task = await f.terminal(); assert.equal(task.state, 'failed'); assert.match(task.message, /JDK/); assert.equal(f.state.processorCalls, 0); assert.deepEqual(f.sourceIdentity(), before);
  } finally { f.close(); }
});

test('installer sidecar mismatch blocks both extraction and Native processors', async () => {
  const f = fixture();
  try {
    configureForgelike(f, true); const before = f.sourceIdentity(), preview = await f.coordinator.checkPlan(await f.request()); f.state.badInstallerSha = true;
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview); const task = await f.terminal();
    assert.equal(task.state, 'failed'); assert.equal(f.state.processorCalls, 0); assert.deepEqual(f.sourceIdentity(), before);
  } finally { f.close(); }
});

test('cancellation during NeoForge processor waits for its real completion before private work cleanup', async () => {
  const f = fixture(); let release;
  try {
    configureForgelike(f, true); const before = f.sourceIdentity(); f.state.processorGate = new Promise(resolve => { release = resolve; });
    const started = new Promise(resolve => { f.state.processorStarted = resolve; }); const preview = await f.coordinator.checkPlan(await f.request());
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview); await started; const id = f.coordinator.getTask().id;
    f.coordinator.cancelTask(); await new Promise(resolve => setImmediate(resolve)); assert.equal(f.coordinator.getTask().state, 'cancelling');
    assert(fs.existsSync(f.physical('/app/game-export/work/' + id + '/forgelike/runtime')));
    release(); const task = await f.terminal(); assert.equal(task.state, 'cancelled'); assert.deepEqual(f.sourceIdentity(), before);
    assert(!fs.existsSync(f.physical('/app/game-export/work/' + id)));
  } finally { if (release) release(); f.close(); }
});

/** R5统一任务接线：运行生产Registry，不用立即resolve的enqueue桩掩盖槽位/取消竞态。 */
async function waitForExportCondition(predicate) {
  for (let n = 0; n < 1000; n++) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  throw new Error('统一导出任务条件未到达');
}
function foreignDownload(f) {
  const U = f.load('feature_core/src/main/ets/download/UnifiedDownloadTask.ets');
  const view = new U.UnifiedTaskView(); view.id = 'unrelated'; view.title = 'other download'; view.category = U.TaskCategory.MOD;
  let release; const gate = new Promise(resolve => { release = resolve; }); const probe = { cancels: 0 };
  const task = { view, async start() { await gate; view.state = U.UnifiedTaskState.DONE; },
    async cancel() { probe.cancels++; }, async retry() {}, async pause() {}, async resume() {}, dispose() {} };
  return { task, release, probe };
}

test('export preparation is a real Registry task; own-only idle exclusion and slot release precede freezing', async () => {
  const f = fixture({ missingLibrary: true }); let idle, capturedRun;
  try {
    const preview = await f.coordinator.checkPlan(await f.request());
    const unsub = f.coordinator.subscribe(() => {
      const task = f.coordinator.getTask();
      if (task?.message.startsWith('准备电脑依赖') && !idle) {
        const rows = f.registry.listAll(); assert.equal(rows.length, 1);
        assert.equal(rows[0].category, 'game_export'); assert.equal(rows[0].exportTaskId, task.id);
        assert.equal(rows[0].state, 'downloading'); assert.equal(rows[0].canCancel, true);
        assert.equal(rows[0].speedBps, 64); assert(Number.isFinite(rows[0].progress));
        capturedRun = f.registry.getAdapter(rows[0].id).run_;
        idle = f.coordinator.assertSourceIdle(task.request);
      }
    });
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
    assert.equal((await f.terminal()).state, 'succeeded'); await idle; unsub();
    const view = f.registry.listAll()[0]; assert.equal(view.state, 'done'); assert(view.bytesDone > 0);
    assert.equal(f.registry.runningIds_.length, 0); assert.equal(f.state.downloads.length, 0);
    assert.match(view.currentLabel, /依赖已校验/); assert.equal(view.canRetry, false);
    assert.equal(view.exportMcRoot, '/mc'); assert.equal(view.exportVersionId, f.versionId);
    assert.notEqual(f.registry.getAdapter(view.id).run_, capturedRun, '终态卡片不继续持有大计划的执行闭包');
  } finally { f.close(); }
});

test('queued export cancellation never starts Native and leaves unrelated running owner untouched', async () => {
  const f = fixture({ missingLibrary: true }); const foreign = foreignDownload(f); let other;
  try {
    const preview = await f.coordinator.checkPlan(await f.request()); f.registry.maxConcurrent = 1;
    const unsub = f.coordinator.subscribe(() => {
      if (f.coordinator.getTask()?.stage === '准备电脑文件' && !other) other = f.registry.enqueue(foreign.task);
    });
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
    await waitForExportCondition(() => f.registry.listAll().some(v => v.category === 'game_export' && v.state === 'waiting'));
    const view = f.registry.listAll().find(v => v.category === 'game_export');
    await f.registry.cancel(view.id, false); assert.equal((await f.terminal()).state, 'cancelled'); unsub();
    assert.equal(f.state.downloadCalls, 0); assert.equal(f.state.processorCalls, 0); assert.equal(foreign.probe.cancels, 0);
    assert(f.registry.runningIds_.includes('unrelated')); assert.equal(view.canRecoverExternally, true);
    assert.equal(view.canRetry, false); assert.equal(f.state.registryLease, 0);
  } finally { foreign.release(); if (other) await other; f.close(); }
});

test('unified running cancel converges only its Native id and preserves simultaneous unrelated download', async () => {
  const f = fixture({ missingLibrary: true }); const foreign = foreignDownload(f); let other;
  try {
    const preview = await f.coordinator.checkPlan(await f.request());
    const unsub = f.coordinator.subscribe(() => {
      if (f.coordinator.getTask()?.message.startsWith('准备电脑依赖') && !other) {
        other = f.registry.enqueue(foreign.task);
        const view = f.registry.listAll().find(v => v.category === 'game_export');
        f.registry.cancel(view.id, false);
      }
    });
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview); assert.equal((await f.terminal()).state, 'cancelled'); unsub();
    assert.equal(foreign.probe.cancels, 0); assert(f.registry.runningIds_.includes('unrelated'));
    assert.deepEqual([...f.state.cancelledDownloads], [1]); assert.equal(f.state.downloads.length, 0);
    assert.equal(f.registry.listAll().find(v => v.category === 'game_export').state, 'aborted');
  } finally { foreign.release(); if (other) await other; f.close(); }
});

test('preparation failure is ERROR with external export recovery; registry retry cannot reuse old Picker authorization', async () => {
  const f = fixture({ missingLibrary: true });
  try {
    const preview = await f.coordinator.checkPlan(await f.request()); f.network.clear();
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview); assert.equal((await f.terminal()).state, 'failed');
    const view = f.registry.listAll()[0]; assert.equal(view.state, 'error'); assert.equal(view.canRetry, false);
    assert.equal(view.canRecoverExternally, true); await assert.rejects(f.registry.retry(view.id), /原业务入口/);
    assert.equal(f.state.pickerCalls, 1); assert.equal(f.state.targetWritten, 0);
    assert.equal(f.state.history.at(-1).status, 'failed'); assert.equal(f.registry.runningIds_.length, 0);
  } finally { f.close(); }
});

test('prepared dependencies DONE does not claim final export success when target writing later fails', async () => {
  const f = fixture({ missingLibrary: true });
  try {
    const preview = await f.coordinator.checkPlan(await f.request()); f.state.targetWriteFailure = true;
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview); assert.equal((await f.terminal()).state, 'failed');
    assert.equal(f.registry.listAll()[0].state, 'done'); assert.match(f.registry.listAll()[0].currentLabel, /仍由导出任务/);
    assert.equal(f.state.history.at(-1).status, 'failed');
  } finally { f.close(); }
});

test('idle guard excludes exactly own preparation ID, never every GAME_EXPORT category', async () => {
  const f = fixture();
  try {
    const request = await f.request(); f.coordinator.preparation_ = { view: { id: 'own' } };
    f.state.registryTasks = [{ id: 'own', state: 'downloading', category: 'game_export' }];
    await f.coordinator.assertSourceIdle(request);
    f.state.registryTasks.push({ id: 'other-export', state: 'downloading', category: 'game_export' });
    await assert.rejects(f.coordinator.assertSourceIdle(request), /尚未结束/);
  } finally { f.close(); }
});

test('independent missing dependencies share one Native batch with intact SHA1/size and source tree', async () => {
  const f = fixture({ missingLibrary: true });
  try {
    // 第二项也必须是仅电脑端缺失的依赖。普通源实例库缺失会被只读资格检查正确
    // 拒绝，不能以删坏源实例来制造下载批次，更不能为此放宽生产预检。
    const version = JSON.parse(fs.readFileSync(f.physical('/mc/versions/1.20.1/1.20.1.json'), 'utf8'));
    const nativeBytes = Buffer.from('pc native bytes');
    const nativeUrl = 'https://example.invalid/native-batch-windows.jar';
    f.network.set(nativeUrl, nativeBytes);
    version.libraries.push({ name: 'example:native:1', natives: { windows: 'natives-windows' }, downloads: {
      classifiers: { 'natives-windows': { path: 'example/native/1/native-1-natives-windows.jar',
        url: nativeUrl, sha1: digest(nativeBytes), size: nativeBytes.length } } } });
    f.put('/mc/versions/1.20.1/1.20.1.json', JSON.stringify(version));
    const before = f.sourceIdentity();
    const preview = await f.coordinator.checkPlan(await f.request());
    assert(!preview.issues.some(issue => issue.severity === 'error'), JSON.stringify(preview.issues));
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
    assert.equal((await f.terminal()).state, 'succeeded');
    assert.equal(f.state.downloadCalls, 1);
    assert.equal(f.state.downloadPlans[0].files.length, 2);
    for (const spec of f.state.downloadPlans[0].files) {
      assert.match(spec.check.sha1, /^[a-f0-9]{40}$/); assert(spec.check.size > 0);
      assert(spec.localPath.startsWith(spec.allowedRoot + '/'));
      assert(!Object.hasOwn(spec, 'maxConnections'), '业务不能为提速盲设连接数');
    }
    assert.deepEqual(f.sourceIdentity(), before); assert.equal(f.coordinator.downloadIds_.size, 0);
    assert.equal(f.registry.listAll()[0].filesDone, 2);
  } finally { f.close(); }
});

test('all-ID barrier retains a late Native owner after earlier IDs release and blocks new Picker', async () => {
  const f = fixture();
  try {
    const preview = await f.coordinator.checkPlan(await f.request());
    f.coordinator.downloadIds_.add(777); f.coordinator.downloadIds_.add(778);
    f.state.downloads = [{ taskId: 777, state: 'Finished' }, { taskId: 778, state: 'Finished' }];
    f.state.purgeBlockedIds.add(778);
    await assert.rejects(f.coordinator.pickAndStart({ filesDir: '/app' }, preview), /owner/);
    assert.deepEqual([...f.coordinator.downloadIds_], [778]); assert.equal(f.state.pickerCalls, 0);
    f.state.purgeBlockedIds.clear(); await f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
    assert.equal((await f.terminal()).state, 'succeeded'); assert.equal(f.coordinator.downloadIds_.size, 0);
  } finally { f.close(); }
});

test('metadata cancellation awaits every started sidecar and never starts a body batch', async () => {
  const f = fixture(); let release;
  try {
    const gate = new Promise(resolve => { release = resolve; }); let started = 0;
    f.state.beforeSidecar = async () => { started++; await gate; };
    const dependencies = Array.from({ length: 3 }, (_, index) => {
      const url = `https://example.invalid/libraries/parallel-${index}.jar`;
      f.network.set(url, Buffer.from('metadata body ' + index));
      return { path: `libraries/parallel-${index}.jar`, url, sha1: '', size: 0, kind: 'library', generated: false };
    });
    let settled = false;
    const pending = f.coordinator.prepareDependencies({ preview: { request: { versionId: 'fixture' } } },
      '/app/game-export/work/metadata/dependencies', dependencies).finally(() => { settled = true; });
    const rejected = assert.rejects(pending, /取消/);
    await waitForExportCondition(() => started === 3);
    f.coordinator.cancelRequested_ = true;
    await new Promise(resolve => setImmediate(resolve)); assert.equal(settled, false);
    release(); await rejected; assert.equal(f.state.downloadCalls, 0); assert.equal(f.coordinator.downloadIds_.size, 0);
  } finally { release?.(); f.close(); }
});

test('export execution keeps Registry slot and file lease until the shared retainOwner release completes', async () => {
  const f = fixture({ missingLibrary: true }); let release;
  try {
    const gate = new Promise(resolve => { release = resolve; }); let releaseStarted = false;
    f.state.beforeOwnerRelease = async () => { releaseStarted = true; await gate; };
    const preview = await f.coordinator.checkPlan(await f.request());
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
    await waitForExportCondition(() => releaseStarted);
    const view = f.registry.listAll().find(item => item.category === 'game_export');
    assert(f.registry.runningIds_.includes(view.id)); assert.equal(f.coordinator.downloadIds_.size, 1);
    assert.notEqual(f.coordinator.getTask().state, 'succeeded');
    assert.throws(() => f.registry.acquireReplacementLease(), /忙|任务|idle|active|空闲/i);
    // 公共Manager的可控时钟用例另证超过30秒仍等待；此处只验证真实业务action确实
    // 持有这项等待，而不在fixture复制计时/下载策略或等待实际30秒。
    await new Promise(resolve => setImmediate(resolve)); assert(f.registry.runningIds_.includes(view.id));
    release(); assert.equal((await f.terminal()).state, 'succeeded');
    assert.equal(f.coordinator.downloadIds_.size, 0); assert.equal(f.registry.runningIds_.length, 0);
  } finally { release?.(); f.close(); }
});

test('export directory shares in-flight creation and rechecks after the Promise has completed', async () => {
  const f = fixture(); let release;
  try {
    const target = '/app/game-export/work/directory-shared';
    const gate = new Promise(resolve => { release = resolve; }); let started = false, settled = 0;
    f.state.beforeDirectoryMkdir = async p => { if (p === target) { started = true; await gate; } };
    const { ensureExportDirectory } = f.load('entry/src/main/ets/export/ExportDirectory.ets');
    const first = ensureExportDirectory(target, '/app').then(() => { settled++; });
    const second = ensureExportDirectory(target, '/app').then(() => { settled++; });
    await waitForExportCondition(() => started);
    assert.equal(f.state.mkdirCalls.filter(p => p === target).length, 1);
    assert.equal(settled, 0, '所有调用者必须等待同一真实FileIO结束');
    release(); await Promise.all([first, second]); assert.equal(settled, 2);
    // 已完成的Promise不能充当永久目录可信缓存；目录被移走后再次调用必须真正重建。
    fs.rmdirSync(f.physical(target));
    await ensureExportDirectory(target, '/app');
    assert.equal(f.state.mkdirCalls.filter(p => p === target).length, 2);
  } finally { release?.(); f.close(); }
});

test('export directory accepts EEXIST only after a competing creator leaves a plain directory', async () => {
  const f = fixture();
  try {
    const target = '/app/game-export/work/directory-competing';
    // 原生产lstat已确认不存在，但在平台mkdir真正执行前，另一个创建者赢得竞争。
    // 严格FileIO端口随后确实抛13900015；生产helper必须重新lstat才可返回。
    f.state.beforeDirectoryMkdir = async p => { if (p === target) fs.mkdirSync(f.physical(p), { recursive: true }); };
    const { ensureExportDirectory } = f.load('entry/src/main/ets/export/ExportDirectory.ets');
    await Promise.all([ensureExportDirectory(target, '/app'), ensureExportDirectory(target, '/app')]);
    assert.equal(f.state.mkdirCalls.filter(p => p === target).length, 1);
    assert.equal(f.state.mkdirConflicts.filter(p => p === target).length, 1, '平台端口确实返回EEXIST后才允许复核成功');
    assert(fs.lstatSync(f.physical(target)).isDirectory());
  } finally { f.close(); }
});

test('export directory keeps file and link occupants intact, including occupants winning the mkdir race', async () => {
  const f = fixture();
  try {
    const { ensureExportDirectory } = f.load('entry/src/main/ets/export/ExportDirectory.ets');
    const file = '/app/game-export/work/directory-file'; f.put(file, 'keep occupant bytes');
    await assert.rejects(ensureExportDirectory(file, '/app'), /verify.*directory-file/);
    assert.equal(fs.readFileSync(f.physical(file), 'utf8'), 'keep occupant bytes');
    const link = '/app/game-export/work/directory-link';
    // 只替换平台Stat，不依赖宿主是否允许创建Windows symlink；实际拒绝逻辑在生产helper。
    f.state.directoryStatOverrides.set(link, { isDirectory: () => true, isSymbolicLink: () => true });
    await assert.rejects(ensureExportDirectory(link, '/app'), /verify.*directory-link/);
    const racedFile = '/app/game-export/work/directory-raced-file';
    f.state.beforeDirectoryMkdir = async p => { if (p === racedFile) f.put(p, 'race occupant'); };
    await assert.rejects(ensureExportDirectory(racedFile, '/app'), /verify.*directory-raced-file/);
    assert.equal(fs.readFileSync(f.physical(racedFile), 'utf8'), 'race occupant');
    assert.equal(f.state.mkdirCalls.filter(p => p === file || p === link).length, 0);
  } finally { f.close(); }
});

for (const code of [13900012, 13900025]) test(`export directory preserves mkdir error ${code} and permits a later retry`, async () => {
  const f = fixture();
  try {
    const target = '/app/game-export/work/directory-fault-' + code;
    const { ensureExportDirectory } = f.load('entry/src/main/ets/export/ExportDirectory.ets');
    f.state.beforeDirectoryMkdir = async p => { if (p === target) throw Object.assign(new Error('platform mkdir rejected'), { code }); };
    await assert.rejects(ensureExportDirectory(target, '/app'), error => {
      assert.equal(error.code, code); assert.equal(error.operation, 'mkdir'); assert.equal(error.directory, target); return true;
    });
    assert(!fs.existsSync(f.physical(target)));
    f.state.beforeDirectoryMkdir = null; await ensureExportDirectory(target, '/app');
    assert(fs.lstatSync(f.physical(target)).isDirectory(), '失败后必须移除在途登记，不能永久拒绝重试');
  } finally { f.close(); }
});

test('export directory does not reinterpret an unreadable path as ENOENT or create it', async () => {
  const f = fixture();
  try {
    const target = '/app/game-export/work/directory-unreadable';
    const { ensureExportDirectory } = f.load('entry/src/main/ets/export/ExportDirectory.ets');
    f.state.beforeDirectoryLstat = async p => { if (p === target) throw Object.assign(new Error('Permission denied'), { code: 13900012 }); };
    await assert.rejects(ensureExportDirectory(target, '/app'), error => {
      assert.equal(error.code, 13900012); assert.equal(error.operation, 'lstat'); return true;
    });
    assert.equal(f.state.mkdirCalls.filter(p => p === target).length, 0);
  } finally { f.close(); }
});

test('export directory merges a shared missing ancestor for different target leaves', async () => {
  const f = fixture(); let release;
  try {
    const common = '/app/shared-prefix';
    const gate = new Promise(resolve => { release = resolve; }); let started = false;
    f.state.beforeDirectoryMkdir = async p => { if (p === common) { started = true; await gate; } };
    const { ensureExportDirectory } = f.load('entry/src/main/ets/export/ExportDirectory.ets');
    const pending = Promise.all([ensureExportDirectory(common + '/left/leaf', '/app'),
      ensureExportDirectory(common + '/right/leaf', '/app')]);
    await waitForExportCondition(() => started);
    assert.equal(f.state.mkdirCalls.filter(p => p === common).length, 1);
    release(); await pending;
    assert(fs.lstatSync(f.physical(common + '/left/leaf')).isDirectory());
    assert(fs.lstatSync(f.physical(common + '/right/leaf')).isDirectory());
    assert.equal(f.state.mkdirConflicts.length, 0, '共同祖先应归集，不靠递归mkdir碰撞后侥幸成功');
  } finally { release?.(); f.close(); }
});

for (const existingLeaf of [true, false]) test(`export directory rejects a real ancestor symlink with ${existingLeaf ? 'existing' : 'missing'} leaf`, async () => {
  const f = fixture();
  try {
    const trusted = '/app/trusted-directory-root', alias = trusted + '/alias', outside = '/outside-directory-target';
    fs.mkdirSync(f.physical(trusted), { recursive: true }); fs.mkdirSync(f.physical(outside), { recursive: true });
    if (existingLeaf) fs.mkdirSync(f.physical(outside + '/leaf'));
    // Windows使用真正的目录junction，无需将平台Stat伪造成链接；POSIX使用目录symlink。
    fs.symlinkSync(f.physical(outside), f.physical(alias), process.platform === 'win32' ? 'junction' : 'dir');
    const { ensureExportDirectory } = f.load('entry/src/main/ets/export/ExportDirectory.ets');
    await assert.rejects(ensureExportDirectory(alias + '/leaf', trusted), error => {
      assert.equal(error.operation, 'verify'); assert.equal(error.directory, alias); return true;
    });
    assert.equal(f.state.mkdirCalls.length, 0, '稳定祖先链接必须在任何mkdir前拒绝');
    assert.equal(fs.existsSync(f.physical(outside + '/leaf')), existingLeaf);
    assert.deepEqual(fs.readdirSync(f.physical(outside)), existingLeaf ? ['leaf'] : []);
  } finally { f.close(); }
});

test('export directory rejects invalid boundaries and an absent, occupied or linked trusted root', async () => {
  const f = fixture();
  try {
    const { ensureExportDirectory } = f.load('entry/src/main/ets/export/ExportDirectory.ets');
    for (const [target, trusted] of [['/app-elsewhere/leaf', '/app'], ['/app/../escape', '/app'],
      ['relative/leaf', '/app'], ['/app//leaf', '/app'], ['/app/leaf', '/']]) {
      await assert.rejects(ensureExportDirectory(target, trusted), error => { assert.equal(error.operation, 'boundary'); return true; });
    }
    await assert.rejects(ensureExportDirectory('/app/absent-root/leaf', '/app/absent-root'),
      error => { assert.equal(error.operation, 'root'); return true; });
    f.put('/app/occupied-root', 'preserve root occupant');
    await assert.rejects(ensureExportDirectory('/app/occupied-root/leaf', '/app/occupied-root'), /verify/);
    fs.mkdirSync(f.physical('/outside-root'), { recursive: true });
    fs.symlinkSync(f.physical('/outside-root'), f.physical('/app/linked-root'), process.platform === 'win32' ? 'junction' : 'dir');
    await assert.rejects(ensureExportDirectory('/app/linked-root/leaf', '/app/linked-root'), /verify/);
    assert.equal(f.state.mkdirCalls.length, 0); assert.equal(fs.readFileSync(f.physical('/app/occupied-root'), 'utf8'), 'preserve root occupant');
    assert.deepEqual(fs.readdirSync(f.physical('/outside-root')), []);
  } finally { f.close(); }
});

test('export directory accepts an explicit trusted root below a platform mapping ancestor', async () => {
  const f = fixture();
  try {
    f.put('/mapped-private-target/files/identity', 'trusted caller context');
    fs.symlinkSync(f.physical('/mapped-private-target'), f.physical('/sandbox-mapping'), process.platform === 'win32' ? 'junction' : 'dir');
    const trusted = '/sandbox-mapping/files';
    const { ensureExportDirectory } = f.load('entry/src/main/ets/export/ExportDirectory.ets');
    await ensureExportDirectory(trusted + '/export/leaf', trusted);
    assert(fs.lstatSync(f.physical('/mapped-private-target/files/export/leaf')).isDirectory());
  } finally { f.close(); }
});

test('export cancellation waits for in-flight directory FileIO before releasing its Registry action', async () => {
  const f = fixture({ missingLibrary: true }); let release;
  try {
    const before = f.sourceIdentity(); const gate = new Promise(resolve => { release = resolve; }); let started = false;
    f.state.beforeDirectoryMkdir = async p => {
      if (p.includes('/dependencies/libraries/')) { started = true; await gate; }
    };
    const preview = await f.coordinator.checkPlan(await f.request());
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
    await waitForExportCondition(() => started); f.coordinator.cancelTask();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(f.coordinator.getTask().state, 'cancelling'); assert.equal(f.state.downloadCalls, 0);
    assert.equal(f.registry.runningIds_.length, 1, 'FileIO未返回时父action不能先退出');
    release(); assert.equal((await f.terminal()).state, 'cancelled');
    assert.equal(f.registry.runningIds_.length, 0); assert.equal(f.coordinator.downloadIds_.size, 0);
    assert.deepEqual(f.sourceIdentity(), before);
  } finally { release?.(); f.close(); }
});

/** 创建足够多的真实资产，让生产两轮依赖检查都经过小型worker池，而非单文件偶然通过。 */
function fullCheckAssets(f, count = 9) {
  const objects = {}, paths = [];
  for (let index = 0; index < count; index++) {
    const bytes = Buffer.from('bounded full-check asset ' + index), hash = digest(bytes);
    const relative = 'assets/objects/' + hash.slice(0, 2) + '/' + hash;
    objects['minecraft/batch/' + index + '.txt'] = { hash, size: bytes.length };
    paths.push('/mc/' + relative); f.put('/mc/' + relative, bytes);
  }
  const text = JSON.stringify({ objects }), versionPath = '/mc/versions/1.20.1/1.20.1.json';
  const version = JSON.parse(fs.readFileSync(f.physical(versionPath), 'utf8'));
  version.assetIndex.sha1 = digest(text); version.assetIndex.size = Buffer.byteLength(text);
  f.put('/mc/assets/indexes/test.json', text); f.put(versionPath, JSON.stringify(version));
  return { paths, text };
}

test('full source and PC plans use four bounded checks with stable plan order and fresh-to-memo phases', async () => {
  const f = fixture(); const gates = new Map(); let inflight = 0, peak = 0;
  try {
    const assets = fullCheckAssets(f), reads = new Map(), entered = new Set();
    const request = await f.request('full');
    const { readExportVersions } = f.load('entry/src/main/ets/export/ExportSourceInspector.ets');
    const resolver = f.load('feature_core/src/main/ets/export/ExportVersionResolver.ets').ExportVersionResolver;
    const planner = f.load('feature_core/src/main/ets/export/DesktopDependencyPlanner.ets').DesktopDependencyPlanner;
    const resolved = resolver.resolve(request.versionId, await readExportVersions('/mc', request.versionId));
    const expected = planner.plan(resolved, request.platform, assets.text).dependencies.map(dep => dep.path);
    f.state.onRead = p => { if (assets.paths.includes(p)) reads.set(p, (reads.get(p) ?? 0) + 1); };
    f.state.beforeDirectoryLstat = async p => {
      if (!assets.paths.includes(p) || entered.has(p)) return;
      entered.add(p); peak = Math.max(peak, ++inflight); let released = false;
      await new Promise(resolve => gates.set(p, () => { if (!released) { released = true; inflight--; resolve(); } }));
    };
    const pending = f.coordinator.checkPlan(request);
    await waitForExportCondition(() => gates.size === 4); assert.equal(peak, 4);
    for (const release of [...gates.values()].reverse()) release();
    await waitForExportCondition(() => gates.size === 8); assert.equal(peak, 4);
    for (const release of [...gates.values()].reverse()) release();
    await waitForExportCondition(() => gates.size === 9); for (const release of gates.values()) release();
    const preview = await pending; assert(!preview.issues.some(issue => issue.severity === 'error'), JSON.stringify(preview.issues));
    const checked = f.coordinator.previews_.get(preview.id);
    assert.deepEqual(checked.dependencies.map(dep => dep.path), expected, '完成顺序不能改变PC闭包原顺序');
    assert.equal(peak, 4); assert.equal(inflight, 0);
    for (const p of assets.paths) assert.equal(reads.get(p), 1, 'source轮结束后PC轮应复用强身份摘要，不重复正文读取');
    assert.equal(f.state.downloadCalls, 0);
  } finally { for (const release of gates.values()) release(); f.close(); }
});

test('full precheck cancellation stops new dependencies and drains admitted FileIO before returning without preview', async () => {
  const f = fixture(); const gates = new Map(); let cancelled = false, returned = false;
  try {
    const assets = fullCheckAssets(f); const request = await f.request('full');
    f.state.beforeDirectoryLstat = async p => {
      if (!assets.paths.includes(p) || gates.has(p)) return;
      await new Promise(resolve => gates.set(p, resolve));
    };
    const pending = f.coordinator.checkPlan(request, true, () => cancelled);
    const rejection = assert.rejects(pending, /取消/).then(() => { returned = true; });
    await waitForExportCondition(() => gates.size === 4); cancelled = true;
    await new Promise(resolve => setImmediate(resolve)); assert.equal(returned, false); assert.equal(gates.size, 4);
    for (const release of gates.values()) release(); await rejection;
    assert.equal(gates.size, 4); assert.equal(f.coordinator.previews_.size, 0); assert.equal(f.state.downloadCalls, 0);
    assert(!fs.existsSync(f.physical('/app/game-export/work')), '检查取消不能派发执行或创建归档工作树');
  } finally { for (const release of gates.values()) release(); f.close(); }
});

for (const format of ['modrinth', 'curseforge']) test(`${format} standard check still avoids all client assets despite full-check pool`, async () => {
  const f = fixture();
  try {
    const request = await f.request(format); let assetVisits = 0;
    const rejectAssets = p => { if (p === '/mc/assets' || p.startsWith('/mc/assets/')) { assetVisits++; throw new Error('unexpected standard asset IO'); } };
    f.state.beforeDirectoryLstat = rejectAssets; f.state.beforeReadText = rejectAssets; f.state.onRead = rejectAssets;
    const preview = await f.coordinator.checkPlan(request);
    assert(!preview.issues.some(issue => issue.severity === 'error'), JSON.stringify(preview.issues));
    assert.equal(assetVisits, 0); assert.equal(preview.downloads, 0); assert.equal(f.state.downloadCalls, 0);
  } finally { f.close(); }
});

/** 精确三文件选择使快照入场顺序可核对，生成元数据仍由生产FilePlan提供。 */
async function snapshotPoolRequest(f) {
  const files = ['config/0-fail.txt', 'config/1-held.txt', 'config/2-late.txt'];
  for (const relative of files) f.put('/mc/versions/1.20.1/' + relative, 'snapshot bytes ' + relative);
  return { ...(await f.request('modrinth')), includeDirectories: [], includeFiles: files, selectedWorlds: [], selectionVersion: 2, excludePaths: [] };
}

for (const boundary of ['write', 'fsync', 'hash']) test(`snapshot peer failure retains Version Registry process and work until ${boundary} owner drains`, async () => {
  const f = fixture({ nativeHashes: true }); let releaseHeld, held = false, faultObserved = false, allowHash = false;
  try {
    const request = await snapshotPoolRequest(f), preview = await f.coordinator.checkPlan(request);
    const gate = new Promise(resolve => { releaseHeld = resolve; });
    const snapshot = p => p?.includes('/snapshot/');
    const heldTarget = p => snapshot(p) && p.endsWith('/1-held.txt');
    f.state.beforeAsyncWrite = async p => {
      if (heldTarget(p) && boundary === 'write') { held = true; await gate; }
      if (snapshot(p) && p.endsWith('/0-fail.txt')) { await waitForExportCondition(() => held); faultObserved = true; throw new Error('EIO primary snapshot write'); }
    };
    f.state.beforeAsyncFsync = async p => { if (heldTarget(p) && boundary === 'fsync') { held = true; await gate; } };
    if (boundary === 'hash') f.state.nativeHashReleaseGate = p => {
      if (f.coordinator.getTask()?.stage !== '冻结输入' || !p?.endsWith('/config/1-held.txt')) return true;
      held = true; return allowHash;
    };
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview); const execution = f.coordinator.execution_;
    let returned = false; execution.then(() => { returned = true; });
    await waitForExportCondition(() => faultObserved); await new Promise(resolve => setImmediate(resolve));
    const task = f.coordinator.getTask(), work = '/app/game-export/work/' + task.id;
    assert.equal(returned, false); assert.equal(task.state, 'running', 'peer失败不能把用户cancelRequested_或可见终态提前发布');
    assert.equal(f.state.registryLease, 1); assert.equal(f.state.versionLease, 1); assert(fs.existsSync(f.physical(work)));
    assert(!f.state.stages.includes('打包')); assert(!fs.existsSync(f.physical(work + '/snapshot/modrinth.index.json')));
    assert(!fs.existsSync(f.physical(work + '/snapshot/overrides/config/2-late.txt')), '失败后不得派发第三项');
    const processOwner = f.load('feature_core/src/main/ets/download/ProcessActivityCoordinator.ets').ProcessActivityCoordinator.instance();
    assert.throws(() => processOwner.acquireSharedGame(), /导出|文件任务|尚未结束/);
    allowHash = true; releaseHeld(); await execution;
    assert.equal(f.coordinator.getTask().state, 'failed'); assert.match(f.coordinator.getTask().message, /EIO primary snapshot write/);
    assert.equal(f.state.registryLease, 0); assert.equal(f.state.versionLease, 0); assert.equal(f.state.nativeHashJobs.size, 0);
    assert(fs.existsSync(f.physical(work)), '普通失败保留自有现场，不因批次局部取消误当用户取消清掉');
  } finally { allowHash = true; releaseHeld?.(); if (f.coordinator.execution_) await f.coordinator.execution_; f.close(); }
});

test('snapshot user cancellation waits for both in-flight copies before leases cleanup or writer', async () => {
  const f = fixture(); const gates = new Map();
  try {
    const request = await snapshotPoolRequest(f), preview = await f.coordinator.checkPlan(request);
    f.state.beforeAsyncWrite = async p => {
      if (!p.includes('/snapshot/overrides/config/') || gates.has(p)) return;
      await new Promise(resolve => gates.set(p, resolve));
    };
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview); const execution = f.coordinator.execution_;
    await waitForExportCondition(() => gates.size === 2); const work = '/app/game-export/work/' + f.coordinator.getTask().id;
    f.coordinator.cancelTask(); await new Promise(resolve => setImmediate(resolve));
    assert.equal(f.coordinator.getTask().state, 'cancelling'); assert.equal(f.state.registryLease, 1); assert.equal(f.state.versionLease, 1);
    assert(fs.existsSync(f.physical(work))); assert(!f.state.stages.includes('打包')); assert.equal(gates.size, 2);
    for (const release of gates.values()) release(); await execution;
    assert.equal(f.coordinator.getTask().state, 'cancelled'); assert.equal(f.state.registryLease, 0); assert.equal(f.state.versionLease, 0);
    assert(!fs.existsSync(f.physical(work)), '用户取消只在两项都实际收口后清理自有目录');
    assert.equal(gates.size, 2);
  } finally { for (const release of gates.values()) release(); if (f.coordinator.execution_) await f.coordinator.execution_; f.close(); }
});

test('snapshot two-copy window keeps counters monotone and generates metadata then final manifest after all files', async () => {
  const f = fixture(); const gates = new Map(), writes = [], progress = [];
  const unsubscribe = f.coordinator.subscribe(() => {
    const task = f.coordinator.getTask(); if (task?.stage === '冻结输入' && task.state === 'running') progress.push([task.processedFiles, task.processedBytes]);
  });
  try {
    const request = await snapshotPoolRequest(f), preview = await f.coordinator.checkPlan(request);
    f.state.beforeAsyncWrite = async p => {
      if (!p.includes('/snapshot/')) return; writes.push(p);
      if (p.includes('/overrides/config/') && !gates.has(p)) await new Promise(resolve => gates.set(p, resolve));
      else if (p.endsWith('/modrinth.index.json') || p.endsWith('/amcl-export.json')) assert(f.coordinator.getTask().processedFiles >= 3);
    };
    await f.coordinator.pickAndStart({ filesDir: '/app' }, preview);
    await waitForExportCondition(() => gates.size === 2); assert.equal(writes.filter(p => p.includes('/overrides/config/')).length, 2);
    assert(!writes.some(p => p.endsWith('/modrinth.index.json')));
    for (const release of [...gates.values()].reverse()) release();
    await waitForExportCondition(() => gates.size === 3); for (const release of gates.values()) release();
    assert.equal((await f.terminal()).state, 'succeeded');
    for (let index = 1; index < progress.length; index++) { assert(progress[index][0] >= progress[index - 1][0]); assert(progress[index][1] >= progress[index - 1][1]); }
    const metadata = writes.findIndex(p => p.endsWith('/modrinth.index.json')), report = writes.findIndex(p => p.endsWith('/amcl-export.json'));
    assert(metadata >= 0 && report > metadata); assert(!writes.slice(metadata).some(p => p.includes('/overrides/config/')));
    const archive = f.readZip(); const manifest = JSON.parse(archive['amcl-export.json']);
    for (const file of manifest.files) if (!file.directory) assert.equal(file.sha256, digest(archive[file.path], 'sha256'));
  } finally { for (const release of gates.values()) release(); if (f.coordinator.execution_) await f.coordinator.execution_; unsubscribe(); f.close(); }
});
