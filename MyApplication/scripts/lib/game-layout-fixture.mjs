/** 父/子分别加载真实模块，共享的只有隔离临时目录；验证布局不经 child XML 回写。 */
import fs from 'node:fs';
import { randomUUID } from 'node:crypto';
import { evidenceRuntime } from './evidence-test-runtime.mjs';
import { makePureEtsLoader } from './load-pure-ets.mjs';

const SNAPSHOT = '12345678-1234-4234-8234-123456789abc';
const ROOT_JOURNAL = 'entry/src/main/ets/runtime/GameLayoutJournal.ets';
const ROOT_SNAPSHOT = 'entry/src/main/ets/runtime/DesktopLaunchSnapshot.ets';

export function fixture() {
  const disk = evidenceRuntime();
  // 只在测试边界将宿主 ENOENT 对应到 OHOS 明确的 13900002，其它 IO 错误不得吞掉。
  const originalList = disk.kitFs.listFileSync;
  disk.kitFs.listFileSync = directory => {
    try { return originalList(directory); }
    catch (error) { if (error.code === 'ENOENT') error.code = 13900002; throw error; }
  };
  const io = disk.load('commons/src/main/ets/utils/EvidenceIo.ets');
  const state = { lock: 0, failOwnerFlush: false, failOwnerFlushCount: 0, failOwnerMarkerPut: false };
  const ownerData = new Map();
  // 缓存与已 flush 数据分开，冷启动 fixture 不能把未成功持久化的内存冒充磁盘内容。
  const ownerDurable = new Map();
  const prefs = name => {
    if (!ownerData.has(name)) ownerData.set(name, new Map());
    const data = ownerData.get(name);
    return { getSync: (key, fallback) => data.get(key) ?? fallback,
      get: async (key, fallback) => data.get(key) ?? fallback,
      putSync: (key, value) => data.set(key, value), put: async (key, value) => {
        if (name === 'control_layout' && key.startsWith('game_layout_applied_') && state.failOwnerMarkerPut) {
          throw new Error('owner marker put failure');
        }
        data.set(key, value);
      },
      deleteSync: key => data.delete(key), getAllSync: () => Object.fromEntries(data),
      flush: async () => {
        if (name === 'control_layout' && (state.failOwnerFlush || state.failOwnerFlushCount > 0)) {
          if (state.failOwnerFlushCount > 0) state.failOwnerFlushCount--;
          throw new Error('owner disk failure');
        }
        ownerDurable.set(name, new Map(data));
      } };
  };
  function role(pid) {
    let xmlOpens = 0;
    let installedSink;
    const common = { AppLogger: { info() {}, warn() {}, error() {} }, LOG_DOMAIN_LAUNCH: 1,
      ensureDirSync: path => fs.mkdirSync(path, { recursive: true }), ...io };
    const gamecontrol = {};
    const account = { id: 'offline', type: 'offline', refresh: async () => {} };
    const dependencies = { 'commons': common, 'gamecontrol': gamecontrol,
      // 私有快照的输入契约版本直接加载生产纯模块；不复制版本常量制造恒真判据。
      'launch': makePureEtsLoader()('launch/src/main/ets/ResolvedInputPlan.ets'),
      './EvidenceIo': io, './FileUtils': { ensureDirSync: path => fs.mkdirSync(path, { recursive: true }) },
      'libentry.so': { default: { desktopProcessId: () => pid, desktopGameProcessState: () => state.lock } },
      '@kit.CoreFileKit': { fileIo: disk.kitFs }, '@kit.AbilityKit': {},
      '@kit.ArkTS': { util: { generateRandomUUID: randomUUID } },
      '@kit.ArkData': { preferences: { getPreferencesSync: (_context, options) => { xmlOpens++; return prefs(options.name); } } },
      '@kit.ArkUI': { display: { getDefaultDisplaySync: () => ({ width: 2400, height: 1600, densityPixels: 2 }) } },
      '@kit.BasicServicesKit': { deviceInfo: { marketName: 'host-test' } },
      '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {}, warn() {} } },
      'feature_system': { PreferenceManager: class { resolveLaunch() {} } },
      'account': { AccountType: { OFFLINE: 'offline' }, getAccountManager: () => ({ init: async () => {},
        getSelected: () => account, findById: () => account, persistOne: async () => {} }) },
      './DesktopFileDrop': { DesktopFileDrop: { clearPrevious: async () => {} } },
      // default布局运输不启用store门控；真实Snapshot仍执行prepare/consume及票据身份检查。
      './GameRunAdmission': { GameRunAdmission: { capture: () => '', assertToken() {}, installTicket() {} } },
    };
    const load = makePureEtsLoader(dependencies);
    Object.assign(common, load('commons/src/main/ets/utils/PreferenceSnapshot.ets'),
      load('commons/src/main/ets/utils/ProcessPreferences.ets'), load('commons/src/main/ets/utils/OwnerLayoutSourceRepository.ets'));
    // 保留生产安装器，只捕获实际注入的 sink，供直接输入越权反例验证边界而不修改生产导出。
    const installSink = common.ProcessPreferences.installGameLayoutCommitSink;
    common.ProcessPreferences.installGameLayoutCommitSink = sink => { installedSink = sink; installSink(sink); };
    Object.assign(gamecontrol, load('gamecontrol/src/main/ets/ControlLayout.ets'),
      load('gamecontrol/src/main/ets/LayoutStore.ets'), load('gamecontrol/src/main/ets/LayoutMerge.ets'),
      load('gamecontrol/src/main/ets/GameSessionLayoutRepository.ets'), load('gamecontrol/src/main/ets/LayoutBudget.ets'),
      load('gamecontrol/src/main/ets/LayoutSourceNormalization.ets'));
    return { load, store: gamecontrol.getLayoutStore(), process: common.ProcessPreferences,
      journal: load(ROOT_JOURNAL).GameLayoutJournal, snapshot: load(ROOT_SNAPSHOT).DesktopLaunchSnapshot,
      xmlOpens: () => xmlOpens, sink: () => installedSink };
  }
  const owner = role(100), child = role(200);
  const activity = Date.now() - 1000;
  return { disk, state, ownerData, owner, child, activity,
    path: disk.directory + '/game-layout-journal/' + SNAPSHOT + '.json',
    async launchV2() {
      const ref = await owner.snapshot.prepare(disk.context, 100, '1.16.5', activity);
      this.v2Id = ref.id;
      state.lock = 1;
      child.snapshot.consume(disk.context, ref.id, ref.account, 100, activity, 200, '1.16.5');
      await child.store.init(disk.context);
      return ref;
    },
    // V1既有反例保留生产journal路径，显式构造历史已授权consume；新默认ticket由launchV2覆盖。
    async launch() {
      await owner.store.init(disk.context);
      const base = await owner.store.captureLaunchPreferences();
      owner.journal.prepare(disk.context, SNAPSHOT, activity, 100, base);
      state.lock = 1;
      child.process.installGameSnapshots([base, { name: 'amcl_settings', values: {} }, { name: 'amcl_accounts', values: {} }]);
      child.journal.installGame(disk.context, SNAPSHOT, activity, 100, 200, base);
      await child.store.init(disk.context);
      return { id: SNAPSHOT };
    },
    async launchLegacy() {
      // 历史版本可能传入全量 control_layout。直接经过同一个 prepare/installGame 边界，
      // 而 owner 当前的常规 capture 已只输出两键；不可为构造旧数据反例而放宽常规快照。
      await owner.store.init(disk.context);
      ownerData.get('control_layout').set('legacy_touch_hint', '保留的旧值');
      ownerData.get('control_layout').set('legacy_scale', 1.5);
      const base = await owner.process.captureOwner(disk.context, 'control_layout');
      owner.journal.prepare(disk.context, SNAPSHOT, activity, 100, base);
      state.lock = 1;
      child.process.installGameSnapshots([base, { name: 'amcl_settings', values: {} },
        { name: 'amcl_accounts', values: {} }]);
      child.journal.installGame(disk.context, SNAPSHOT, activity, 100, 200, base);
      await child.store.init(disk.context);
      return base;
    },
    restartOwner() {
      ownerData.clear();
      for (const [name, values] of ownerDurable) ownerData.set(name, new Map(values));
      return role(300);
    } };
}
