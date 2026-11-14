/** 下载普通页与资源类别稳定性回归；运行生产Builder和Prop观察函数，不模拟真机布局或IME。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { loadActionComponent, actionUiReceiver } from './lib/unified-actions-fixture.mjs';
import { assertExternalOutputPath } from './lib/workspace-paths.mjs';

const at = process.argv.indexOf('--output');
assert.ok(at >= 0, '需要外置--output目录');
const out = assertExternalOutputPath(process.argv[at + 1]);
fs.mkdirSync(out, { recursive: true });
const cancelled = [];
const resourceKind = { MOD: 'mod', RESOURCE_PACK: 'resourcepack', SHADER: 'shader', MODPACK: 'modpack' };
const Page = loadActionComponent('entry/src/main/ets/pages/ModBrowsePage.ets', 'ModBrowsePage', {
  methods: ['externalKindChanged_', 'syncDefaultResourceTarget_', 'currentBrowseKind_', 'closeModpackRecovery_',
    'retireModpackRecoveryScan_'], globals: { clearTimeout: id => cancelled.push(id) },
  dependencies: { feature_system: { GameStorage: { externalMcDir: () => '/external' } },
    mods: { ResourceKind: resourceKind, resolveInstalledMcVersion: () => '1.20.1', resolveInstalledLoader: () => 'forge' },
    '../services/ModFileSave': { supportsCustomResourceSave: kind => ['mod', 'resourcepack', 'shader'].includes(kind) } },
});
const page = new Page();
let applied = 0, searched = 0, closed = 0, geometryResets = 0;
page.applyFiltersToController = () => applied++;
page.triggerSearch = first => { assert.equal(first, true); searched++; };
page.closeDetail = () => closed++;
// 此处隔离层级布局细节，只要求每次实际类别切换都使旧测量/动画上下文失效。
page.resetRetreatGeometry_ = () => geometryResets++;
Object.assign(page, { inited_: false, initialSearchDone_: false, defaultKindIdx: 2, kindIdx_: 0,
  queryInput_: 'sodium', loaderInput_: 'forge', sortInput_: 'relevance', targetVersionId_: '1.20.1-forge',
  instanceTargetPicked_: true, customSaveKindIndices_: [],
  headerCollapsed_: true, debounceTimer_: 17 });
page.externalKindChanged_();
assert.equal(applied, 0, '首次挂载前由aboutToAppear读取初值');
page.inited_ = true;
page.externalKindChanged_();
assert.equal(page.kindIdx_, 2); assert.equal(applied, 1); assert.equal(searched, 0);
assert.deepEqual(cancelled, [17]); assert.equal(page.debounceTimer_, 0);
page.initialSearchDone_ = true;
for (const kind of [3, 1, 0, 2, 3, 0]) {
  page.defaultKindIdx = kind; page.externalKindChanged_();
  assert.equal(page.kindIdx_, kind);
  assert.equal(page.queryInput_, 'sodium'); assert.equal(page.loaderInput_, 'forge');
  assert.equal(page.targetVersionId_, '1.20.1-forge'); assert.equal(page.headerCollapsed_, true);
}
assert.equal(searched, 6); assert.equal(closed, 7);
assert.equal(geometryResets, 7);
for (const invalid of [0, -1, 4, NaN, Infinity, 1.5]) {
  page.defaultKindIdx = invalid; page.externalKindChanged_();
}
assert.equal(searched, 6, '相同或非法类别不重复搜索');

// 首页列表可能在浏览器挂载后才返回。默认目标应随版本库存补齐，手动保存模式保持用户选择。
const defaultTargetPage = Object.assign(new Page(), { kindIdx_: 1, mcDir: '/external', currentMcVersion: '1.20.1-forge',
  availableVersions: [], targetValid_: false, instanceTargetPicked_: false, customSaveKindIndices_: [],
  invalidateLocalScanCache() {} });
assert.equal(defaultTargetPage.syncDefaultResourceTarget_(), false);
defaultTargetPage.availableVersions = ['1.20.1-forge'];
assert.equal(defaultTargetPage.syncDefaultResourceTarget_(), true);
assert.equal(defaultTargetPage.targetVersionId_, '1.20.1-forge'); assert.equal(defaultTargetPage.targetLocation_, 'external');
assert.equal(defaultTargetPage.syncDefaultResourceTarget_(), false, '相同库存不重复刷新');
defaultTargetPage.customSaveKindIndices_ = [1];
defaultTargetPage.currentMcVersion = 'another'; defaultTargetPage.availableVersions = ['another'];
assert.equal(defaultTargetPage.syncDefaultResourceTarget_(), false);
assert.equal(defaultTargetPage.targetVersionId_, '1.20.1-forge');
defaultTargetPage.kindIdx_ = 2;
assert.equal(defaultTargetPage.syncDefaultResourceTarget_(), true, '资源包的明确另存不拦截光影的默认实例更新');
assert.equal(defaultTargetPage.targetVersionId_, 'another');

// 声明接收器只核对真实布局接线：横竖切换调用同一正文入口，四类资源落在同一条件分支。
const ui = actionUiReceiver(), received = [];
const Tab = loadActionComponent('entry/src/main/ets/pages/tabs/DownloadTab.ets', 'DownloadTab', {
  methods: ['build', 'DlTabContent', 'DlModBrowseTab'], render: true, globals: ui.globals,
  dependencies: { '../ModBrowsePage': { ModBrowsePage: options => { received.push(options); return ui.globals.Column(); } } },
});
const tab = new Tab();
tab.PortraitHeader_ = () => {}; tab.DownloadSidebar_ = () => {};
tab.DlVersionTab = () => {}; tab.DlJdkTab = () => {};
for (const landscape of [false, true, false]) {
  tab.isLandscape = landscape; tab.topSafeHeight = 32;
  for (const [capsule, kind] of [[1, 0], [2, 2], [3, 1], [4, 3]]) {
    tab.dlSubTab = capsule; tab.build(); assert.equal(received.at(-1).defaultKindIdx, kind);
  }
}
assert.equal(received.length, 12);
fs.writeFileSync(path.join(out, 'result.json'), JSON.stringify({ status: 'passed',
  groups: ['controlled-kind-and-retained-query', 'default-resource-target-sync-without-overriding-user-choice', 'one-body-path-and-category-mapping'],
  scope: 'production host behavior; device pixel/focus acceptance separate' }, null, 2));
console.log('PASS controlled resource switching and stable portrait/landscape body wiring');
