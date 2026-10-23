/** 执行真实面板生命周期/导航；动画和统计只替换系统边界，不模拟挂载算法。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
const source = fs.readFileSync(new URL('../entry/src/main/ets/components/VersionManagerSheet.ets', import.meta.url), 'utf8');
const ast = compiler.createSourceFile('VersionManagerSheet.ets', source, compiler.ScriptTarget.Latest, true);
const component = ast.statements.find(node => node.name?.text === 'VersionManagerSheet');
// 除原导航方法外，同样执行生产任务投影及销毁逻辑；不能用空方法规避新增订阅依赖。
const names = ['aboutToAppear', 'aboutToDisappear', 'refreshDetailExportTask_', 'openGameExport_',
  'mountStep_', 'gotoDetail', 'backToList', 'gotoResources', 'backToDetail', 'gotoSaves', 'gotoFiles'];
const snippets = names.map(name => { const node = component.members.find(node => node.name?.text === name);
  assert.ok(node?.body, name); return source.slice(node.getStart(ast), node.end); }).join('\n');
const code = compiler.transpileModule('class VersionManagerSheet {' + snippets + '}\nmodule.exports=VersionManagerSheet;',
  { compilerOptions: { target: compiler.ScriptTarget.ES2022 } }).outputText;

// 动效状态本身执行生产源码；帧完成/动画完成才是可控系统边界。
const motionSource = fs.readFileSync(new URL('../entry/src/main/ets/components/SheetPageMotion.ets', import.meta.url), 'utf8');
const motionCode = compiler.transpileModule(motionSource.replace(/^import[^;]*;\r?\n/gm, '').replace('@Observed', ''),
  {compilerOptions:{target:compiler.ScriptTarget.ES2022,module:compiler.ModuleKind.CommonJS}}).outputText;
const motionExports = {};
new Function('exports', 'FrameCallback', 'Curve', motionCode)(motionExports, class {}, {FastOutSlowIn:0});
const {SheetPageMotion} = motionExports;

/**
 * initialStep指定首开列表或深链目标，默认list；返回已执行生产aboutToAppear的独立面板Probe。
 * 实际mountStep/导航方法决定已访问状态，统计读取与Animator仅为系统替身，animateTo同步调用其生产回调。
 * 本用例不加载磁盘、版本管理器或UI组件树，不能把挂载字段断言当真机动画/构建耗时证据。
 * 每次新实例隔离挂载标志与协调器订阅集合；协调器只提供内存任务和通知，不扫描或写文件。
 * 取消定时器也是可控系统边界，便于断言生产销毁方法确实释放资源，避免宿主真实计时器悬挂。
 */
function fixture(initialStep = 'list', initialTask = null) {
  const listeners = new Set();
  const probe = { task: initialTask, subscriptions: 0, unsubscriptions: 0, cancelledTimers: [], dismissRegistrations: [] };
  const coordinator = {
    getTask() { return probe.task; },
    subscribe(listener) {
      probe.subscriptions++;
      listeners.add(listener);
      return () => { probe.unsubscriptions++; listeners.delete(listener); };
    },
  };
  // 发布走真实订阅回调，再进入生产 refreshDetailExportTask_，不在测试里复制匹配算法。
  probe.publish = (task) => { probe.task = task; for (const listener of listeners) listener(); };
  const module = { exports: {} };
  new Function('module', 'Curve', 'getGameExportCoordinator', 'clearTimeout', code)(module,
    { FastOutSlowIn: 0 }, () => coordinator, (timer) => { probe.cancelledTimers.push(timer); });
  const subject = new module.exports();
  Object.assign(subject, { initialStep, initialResourceVersion: 'fixture-ver', initialResourceKind: 'mod', currentVersion: 'current',
    mcDir: '/fixture/.minecraft', versionIsolation: true, detailVersion: '',
    detailExportActive_: false, detailExportMessage_: '', exportTaskUnsubscribe_: null, switchedHintTimer: 0,
    storeRuntimeExpanded_: false, storeManagementExpanded_: false,
    pageMotion_: new SheetPageMotion(), exportMounted_: false,
    onRegisterExportDismiss(handler) { probe.dismissRegistrations.push(handler); },
    availableVersions: ['a', 'b'], listMounted_: false, detailMounted_: false, resourcesMounted_: false, savesMounted_: false,
    filesMounted_: false, refreshVersionRows_() {}, resetDetailCounts() {}, refreshDetailResStat() {},
    loadVersionJvmArgsState() {}, loadModpackSnapshot_() {}, getUIContext: () => ({ postFrameCallback(frame) { frame.onIdle(2000000); },
      animateTo(options, callback) { callback(); options.onFinish?.(); } }) });
  subject.exportProbe_ = probe;
  subject.aboutToAppear(); return subject;
}

test('首开列表不挂载其他页面；深链只创建目标，返回和再次进入保留已访问状态', () => {
  const list = fixture(); assert.equal(list.listMounted_, true);
  assert.equal(list.detailMounted_ || list.resourcesMounted_ || list.savesMounted_ || list.filesMounted_, false);
  const resources = fixture('resources'); assert.equal(resources.resourcesMounted_, true);
  assert.equal(resources.listMounted_ || resources.detailMounted_ || resources.savesMounted_ || resources.filesMounted_, false);
  resources.backToDetail(); resources.backToList(); resources.gotoDetail('another'); resources.gotoSaves(); resources.gotoFiles();
  assert.equal(resources.listMounted_ && resources.detailMounted_ && resources.savesMounted_ && resources.filesMounted_, true);
  assert.equal(resources.resourcesMounted_, true); assert.equal(resources.detailVersion, 'another');
  resources.gotoResources('shader'); assert.equal(resources.resourceKind, 'shader'); assert.equal(resources.pageMotion_.position, 2);
  const detail = fixture('detail'); assert.equal(detail.detailMounted_, true); assert.equal(detail.listMounted_, false);
  list.aboutToDisappear(); resources.aboutToDisappear(); detail.aboutToDisappear();
});

test('无版本不能进入资源/存档/文件，不意外挂载空目标；筛选/拖动业务顺序未被导航改写', () => {
  const subject = fixture(); const originalOrder = subject.orderVersions.slice(); subject.detailVersion = '';
  subject.gotoResources('mod'); subject.gotoSaves(); subject.gotoFiles();
  assert.equal(subject.resourcesMounted_ || subject.savesMounted_ || subject.filesMounted_, false);
  assert.equal(subject.currentStep, 'list'); assert.deepEqual(subject.orderVersions, originalOrder);
  subject.aboutToDisappear();
});

/** 只构造投影所消费的公开字段，不把 SDK、文件 I/O 或任务执行塞进面板挂载夹具。 */
function exportTask(mcRoot, versionId, state = 'running', stage = '打包') {
  return { id: 'fixture-export', request: { mcRoot, versionId }, state, stage };
}

test('详情任务条按真实根目录和详情版本匹配，活动切换与终态通过订阅实时投影', () => {
  const subject = fixture('detail', exportTask('/fixture/.minecraft', 'fixture-ver'));
  const probe = subject.exportProbe_;
  assert.equal(probe.subscriptions, 1);
  assert.equal(subject.detailExportActive_, true); assert.equal(subject.detailExportMessage_, '打包');

  // 首页当前选版相同不能掩盖“详情版本不同”；另一游戏根的同名版本也不能误匹配。
  probe.publish(exportTask('/fixture/.minecraft', 'current'));
  assert.equal(subject.detailExportActive_, false); assert.equal(subject.detailExportMessage_, '');
  probe.publish(exportTask('/another/.minecraft', 'fixture-ver'));
  assert.equal(subject.detailExportActive_, false);

  probe.publish(exportTask('/fixture/.minecraft', 'fixture-ver', 'running', '写入目标'));
  assert.equal(subject.detailExportActive_, true); assert.equal(subject.detailExportMessage_, '写入目标');
  probe.publish(exportTask('/fixture/.minecraft', 'fixture-ver', 'cancelling'));
  assert.equal(subject.detailExportActive_, true);
  assert.equal(subject.detailExportMessage_, '正在取消，等待当前操作结束');
  for (const state of ['succeeded', 'failed', 'cancelled']) {
    probe.publish(exportTask('/fixture/.minecraft', 'fixture-ver', state));
    assert.equal(subject.detailExportActive_, false); assert.equal(subject.detailExportMessage_, '');
  }
  probe.publish(null);
  assert.equal(subject.detailExportActive_, false); assert.equal(subject.detailExportMessage_, '');

  // 用户切换详情也必须立即重新匹配，不能等协调器下一次阶段回调才纠正旧任务条。
  probe.publish(exportTask('/fixture/.minecraft', 'next-ver'));
  subject.gotoDetail('next-ver');
  assert.equal(subject.detailExportActive_, true);
  subject.gotoDetail('fixture-ver');
  assert.equal(subject.detailExportActive_, false);
  subject.aboutToDisappear();
});

test('销毁执行真实unsubscribe、解除宿主dismiss并清理提示计时器，之后发布不再回调已离开的面板', () => {
  const subject = fixture('detail', exportTask('/fixture/.minecraft', 'fixture-ver'));
  const probe = subject.exportProbe_;
  assert.equal(subject.detailExportActive_, true);
  subject.switchedHintTimer = 42;
  subject.aboutToDisappear();
  assert.equal(probe.unsubscriptions, 1); assert.equal(subject.exportTaskUnsubscribe_, null);
  assert.deepEqual(probe.dismissRegistrations, [undefined]);
  assert.deepEqual(probe.cancelledTimers, [42]); assert.equal(subject.switchedHintTimer, 0);
  probe.publish(null);
  assert.equal(subject.detailExportActive_, true, '销毁后不应继续改写旧面板投影');
  subject.aboutToDisappear();
  assert.equal(probe.unsubscriptions, 1); assert.deepEqual(probe.cancelledTimers, [42]);
});

test('同Sheet导出冻结入口三元组，返回详情解除dismiss且不切换首页当前版本', () => {
  const subject = fixture('detail'); const probe = subject.exportProbe_;
  subject.versionIsolation = false;
  subject.openGameExport_();
  assert.equal(subject.currentStep, 'export'); assert.equal(subject.currentVersion, 'current');
  assert.equal(subject.exportMcRoot_, '/fixture/.minecraft');
  assert.equal(subject.exportVersionId_, 'fixture-ver'); assert.equal(subject.exportVersionIsolation_, false);
  subject.mcDir = '/later/.minecraft'; subject.versionIsolation = true;
  assert.equal(subject.exportMcRoot_, '/fixture/.minecraft'); assert.equal(subject.exportVersionIsolation_, false);
  subject.backToDetail();
  assert.equal(subject.currentStep, 'detail'); assert.equal(subject.pageMotion_.position, 1);
  assert.equal(subject.detailVersion, 'fixture-ver'); assert.equal(subject.currentVersion, 'current');
  assert.deepEqual(probe.dismissRegistrations, [undefined]);
  subject.aboutToDisappear();
});


test('首次导出先保留前后页的初始帧，真实帧完成才开始位移，返回动画结束才卸载', () => {
  const subject = fixture('detail'); const frames = [], animations = [];
  subject.pageMotion_.resize(600);
  subject.getUIContext = () => ({postFrameCallback(frame) { frames.push(frame); },
    animateTo(options, update) { animations.push({options, update}); }});
  subject.openGameExport_();
  assert.equal(subject.exportMounted_, true); assert.equal(subject.currentStep, 'export');
  assert.equal(subject.pageMotion_.moving, true); assert.equal(animations.length, 0);
  assert.equal(subject.pageMotion_.offset(1), 0); assert.equal(subject.pageMotion_.offset(2), 600);
  subject.backToDetail(); assert.equal(subject.currentStep, 'export', '等初始帧期间不能重复返回');
  frames.shift().onIdle(2000000); assert.equal(animations.length, 1);
  animations[0].update(); assert.equal(subject.pageMotion_.position, 2);
  animations.shift().options.onFinish();
  subject.backToDetail(); assert.equal(subject.exportMounted_, true);
  assert.equal(subject.pageMotion_.offset(1), -600); assert.equal(subject.pageMotion_.offset(2), 0);
  frames.shift().onIdle(2000000); animations[0].update();
  assert.equal(subject.exportMounted_, true, '离场页不能在位移动画前卸载');
  animations.shift().options.onFinish(); assert.equal(subject.exportMounted_, false);
  assert.equal(subject.pageMotion_.offset(1), 0); subject.aboutToDisappear();
});

test('销毁撤销待开始帧和进行中动画的续体，旧回调不能卸载新页或重改位移', () => {
  for (const afterFrame of [false, true]) {
    const motion = new SheetPageMotion(); const frames = [], animations = []; let finishes = 0;
    const context = {postFrameCallback(f) { frames.push(f); }, animateTo(options, update) { animations.push({options, update}); }};
    motion.resize(600); motion.move(context, 1, () => finishes++);
    if (afterFrame) { frames[0].onIdle(2000000); animations[0].update(); }
    motion.dispose(); const position = motion.position;
    if (afterFrame) animations[0].options.onFinish(); else frames[0].onIdle(2000000);
    assert.equal(finishes, 0); assert.equal(motion.position, position); assert.equal(motion.moving, false);
    if (!afterFrame) assert.equal(animations.length, 0);
  }
});
