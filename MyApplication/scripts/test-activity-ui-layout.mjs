/**
 * 原生 UI 行为回归：SDK AST 提取实际组件方法执行，不重写方法体。
 * 覆盖动画取消、减少动效、胶囊终点及 sheet 边界；像素观感仍需真机验收。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import ts from './lib/ets-compiler.mjs';

const root = path.resolve(import.meta.dirname, '..');
const read = file => fs.readFileSync(path.join(root, 'entry/src/main/ets', file), 'utf8');
function methods(file, names, bindings = {}) {
  const source = read(file);
  const ast = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true);
  const declaration = ast.statements.find(node => node.members?.some(member => member.name?.getText(ast) === names[0]));
  const body = names.map(name => {
    const node = declaration.members.find(member => member.name?.getText(ast) === name);
    assert(node, name); return node.getText(ast);
  }).join('\n');
  const output = ts.transpileModule('export class Target {\n' + body + '\n}', {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  }).outputText;
  const exports = {};
  new Function(...Object.keys(bindings), 'exports', output)(...Object.values(bindings), exports);
  return exports.Target;
}

test('motion respects disabled animation preferences and bounds stagger latency', () => {
  let value = '1', context = {}, unreadable = false;
  const Motion = methods('components/UiMotion.ets', ['stagger', 'reduced'], {
    AppStorage: { get: () => context }, settings: { display: {}, getValueSync: () => {
      if (unreadable) throw new Error('unsupported'); return value;
    } },
  });
  assert.equal(Motion.stagger(-2), 0); assert.equal(Motion.stagger(2), 80); assert.equal(Motion.stagger(200), 200);
  assert.equal(Motion.reduced(), false); value = '0'; assert.equal(Motion.reduced(), true);
  value = ''; assert.equal(Motion.reduced(), false, '未知设置不能误判为用户关闭动画');
  context = undefined; assert.equal(Motion.reduced(), false);
  context = {}; unreadable = true; assert.equal(Motion.reduced(), false);
});

test('entrance timer is cancelled on unmount and reduced motion presents content immediately', () => {
  const pending = new Map(), animations = []; let serial = 0, reduced = false;
  const Section = methods('components/MotionSection.ets', ['aboutToAppear', 'enter_', 'aboutToDisappear'], {
    UiMotion: { reduced: () => reduced, ENTER_MS: 340, stagger: index => Math.min(index, 5) * 40 },
    Curve: { EaseOut: 'easeOut' }, setTimeout: fn => { pending.set(++serial, fn); return serial; },
    clearTimeout: id => pending.delete(id),
  });
  const component = new Section();
  Object.assign(component, { alive: false, frameTimer: -1, enterAlpha: 0, enterY: 12, animateEntrance: true, order: 2,
    getUIContext: () => ({ animateTo: (options, update) => { animations.push(options); update(); } }) });
  component.aboutToAppear(); component.enter_(); component.enter_(); assert.equal(pending.size, 1);
  component.aboutToDisappear(); assert.equal(pending.size, 0); assert.equal(animations.length, 0);
  component.aboutToAppear(); component.enter_(); pending.get(component.frameTimer)();
  assert.equal(component.enterAlpha, 1); assert.equal(component.enterY, 0); assert.equal(animations[0].delay, 80);
  reduced = true; component.enterAlpha = 0; component.enterY = 12; component.aboutToAppear();
  assert.equal(component.enterAlpha, 1); assert.equal(component.enterY, 0);
});

test('pill indicator has a single clamped destination, with direct resize and reduced-motion positioning', () => {
  let reduced = false; const calls = [];
  const Pill = methods('components/AnimatedPillBar.ets', ['itemWidth_', 'targetX_', 'selectionChanged_'], {
    UiMotion: { reduced: () => reduced }, curves: { springMotion: (response, damping) => ({ response, damping }) },
  });
  const bar = new Pill(); Object.assign(bar, { labels: ['一', '二', '三', '四'], trackWidth: 320, selectedIndex: 2, highlightX: 0,
    getUIContext: () => ({ animateTo: (options, change) => { calls.push(options); change(); } }) });
  bar.selectionChanged_(); assert.equal(bar.highlightX, 156);
  bar.selectedIndex = 3; bar.selectionChanged_(); assert.equal(bar.highlightX, 234); assert.equal(calls.length, 2);
  reduced = true; bar.selectedIndex = 0; bar.selectionChanged_(); assert.equal(bar.highlightX, 0); assert.equal(calls.length, 2);
  bar.selectedIndex = 99; assert.equal(bar.targetX_(), 234);
  bar.trackWidth = 0; assert.equal(bar.targetX_(), 0);
});

test('pane motion cancels superseded and hidden callbacks and respects reduced motion', () => {
  // 执行实际组件生命周期，验证快速点击只留一个首帧任务，销毁后不会再写 UI 状态。
  const pending=new Map(), animations=[]; let serial=0, reduced=false;
  const Pane=methods('components/ActivityPaneMotion.ets',['aboutToAppear','aboutToDisappear','cancel_','visibility_','reveal_'],{
    UiMotion:{reduced:()=>reduced},Curve:{EaseOut:'easeOut'},
    setTimeout:fn=>{pending.set(++serial,fn);return serial;},clearTimeout:id=>pending.delete(id),
  });
  const pane=new Pane(); Object.assign(pane,{alive:false,active:true,frame:-1,alpha:1,paneY:0,
    getUIContext:()=>({animateTo:(o,update)=>{animations.push(o);update();}})});
  pane.aboutToAppear(); pane.reveal_(); const stale=pane.frame; pane.reveal_();
  assert.equal(pending.size,1); assert(!pending.has(stale));
  pane.active=false; pane.visibility_(); assert.equal(pending.size,0); assert.equal(pane.alpha,1); assert.equal(pane.paneY,0);
  pane.active=true; pane.reveal_(); const callback=pending.get(pane.frame); pane.aboutToDisappear(); callback();
  assert.equal(animations.length,0); assert.equal(pending.size,0);
  reduced=true; pane.aboutToAppear(); pane.reveal_(); assert.equal(pending.size,0); assert.equal(pane.alpha,1);
});

test('workspace underline clamps in compact and wide layouts without moving touch targets',()=>{
  let reduced=false; const animations=[];
  const Tabs=methods('components/ActivityViewTabs.ets',['itemWidth_','target_','move_'],{
    UiMotion:{reduced:()=>reduced},curves:{springMotion:()=>({})},
  });
  const tabs=new Tabs();Object.assign(tabs,{labels:['概览','日志','环境'],trackWidth:900,selectedIndex:2,indicatorX:0,
    getUIContext:()=>({animateTo:(o,fn)=>{animations.push(o);fn();}})});
  tabs.move_(); assert.equal(tabs.itemWidth_(),144);assert.equal(tabs.indicatorX,288);
  reduced=true;tabs.trackWidth=300;tabs.move_();assert.equal(tabs.indicatorX,200);assert.equal(animations.length,1);
  tabs.selectedIndex=50;assert.equal(tabs.target_(),200);tabs.trackWidth=0;assert.equal(tabs.target_(),0);
});

test('opening share is local only and closing AI reading does not start or cancel analysis', () => {
  let analysis = 0;
  const Workspace = methods('pages/ActivityLogPage.ets', ['openShareComposer_', 'aiSheetOptions_'], { SheetType: { BOTTOM: 0 } });
  const workspace = new Workspace(); Object.assign(workspace, { loading: false, sharing: false, exportingEvidence: false,
    theme: {}, sharedLog: { id: 'old' }, showShareOptions: false, showAiResult: true, analyzeAfterReading: false,
    requestAnalysis_: () => { analysis++; } });
  workspace.openShareComposer_(); assert.equal(workspace.showShareOptions, true); assert.equal(workspace.sharedLog.id, 'old');
  assert.equal(workspace.shareMode, 'quick'); assert.equal(workspace.shareDestination, 'logshare'); assert.equal(workspace.requestAi, false);
  workspace.aiSheetOptions_().onDisappear(); assert.equal(workspace.showAiResult, false); assert.equal(analysis, 0);
  workspace.analyzeAfterReading = true; workspace.aiSheetOptions_().onDisappear(); assert.equal(analysis, 1);
  workspace.aiSheetOptions_().onDisappear(); assert.equal(analysis, 1, '同一次显式分析操作不能重复触发');
  workspace.showShareOptions = false; workspace.sharing = true; workspace.openShareComposer_(); assert.equal(workspace.showShareOptions, false);
});

test('viewport keeps its height; local ZIP is directly available and AI empty state stays compact', () => {
  const settings = read('pages/tabs/SettingsTab.ets'), home = read('pages/tabs/HomeTab.ets');
  assert.doesNotMatch(settings, /\.margin\(\{\s*bottom:\s*floatingDockReserveHeight/);
  assert.match(home, /bottom:\s*this\.isLandscape\s*\?\s*floatingDockReserveHeight\(this\.bottomSafeHeight\)\s*:\s*0/);
  const workspace = read('pages/ActivityLogPage.ets');
  assert.doesNotMatch(workspace, /ShareActions_|WorkspaceTab_\('share'/);
  assert.equal((workspace.match(/\.onClick\(\(\) => \{ this\.exportAllEvidence_\(\) \}\)/g) || []).length, 0);
  const composer = read('components/ActivityShareSheet.ets');
  assert.match(composer, /text: '导出全部可分享日志（脱敏 ZIP）'/);
  assert.doesNotMatch(composer, /Button\('不上传，导出完整 ZIP'\)/);
  assert.match(workspace, /expanded:\s*false, hideWhenEmpty:\s*true/);
  assert.match(workspace, /text: '导出完整日志包（脱敏 ZIP）'/);
  assert.match(workspace, /bindSheet\(this\.showAiResult/);
  assert.match(workspace, /bindSheet\(this\.showShareOptions/);
});

/** 执行真实导航方法，覆盖概览底部进入二级、二级互切及搜索结果跳转，不改动设置值。 */
test('every settings section and search change resets content to the top without smooth carry-over', () => {
  const offsets = []; let saves = 0;
  const Settings = methods('pages/tabs/SettingsTab.ets', ['selectSection_', 'changeSearch_']);
  const page = new Settings(); Object.assign(page, { jvmArgsExpanded: true, mcXmx: 4096, settingsQuery: '日志',
    saveCustomJvmArgs: () => { saves++; }, contentScroller: { scrollTo: options => offsets.push(options) } });
  for (const section of ['logs', 'performance', 'controls', 'download', 'overview']) {
    page.selectSection_(section);
    assert.equal(page.activeSection, section); assert.equal(page.settingsQuery, '');
    assert.equal(page.xmxDraft, '4096'); assert.equal(page.memoryError, '');
  }
  assert.equal(saves, 1); assert.equal(page.mcXmx, 4096);
  page.changeSearch_('Java'); assert.equal(page.settingsQuery, 'Java');
  page.changeSearch_(''); assert.equal(offsets.length, 7);
  assert(offsets.every(options => options.xOffset === 0 && options.yOffset === 0 && options.animation === false));
});

test('settings search is a fixed sibling before the content Scroll, not inside it', () => {
  const source = read('pages/tabs/SettingsTab.ets');
  const ast = ts.createSourceFile('SettingsTab.ets', source, ts.ScriptTarget.Latest, true);
  const component = ast.statements.find(node => node.members?.some(member => member.name?.getText(ast) === 'build'));
  const build = component.members.find(member => member.name?.getText(ast) === 'build').getText(ast);
  const scroll = build.indexOf('Scroll(this.contentScroller)');
  assert(scroll > 0); assert(build.indexOf("id('settings-fixed-search')") < scroll);
  assert(!build.slice(scroll).includes("placeholder: '搜索设置或功能'"));
  assert.match(build.slice(scroll), /layoutWeight\(1\)/);
});

test('ledger storage and remote-share management live in the menu without a persistent footer', async () => {
  const menus = [];
  let bytes = 1761608;
  const Ledger = methods('pages/DownloadHistoryPage.ets', ['manage_'], { formatLogBytes: () => '1.68 MB', ledgerTotalBytes: () => bytes });
  const page = new Ledger(); Object.assign(page, { ledgerBytes: 1761608, theme: {}, context: { filesDir: '/fixture' },
    getUIContext: () => ({ getPromptAction: () => ({ showActionMenu: options => {
      menus.push(options); return Promise.reject(new Error('cancel')); } }) }), safeToast_() {} });
  page.manage_(); await new Promise(resolve => setImmediate(resolve));
  assert.match(menus[0].title, /日志占用 1\.68 MB/);
  assert.equal(menus[0].buttons[0].text, '分享记录与撤回');
  const source = read('pages/DownloadHistoryPage.ets');
  assert.doesNotMatch(source, /Button\('分享记录与撤回'\)/);
  assert.match(source, /id\('activity-records-scroll'\)/);
  bytes = -1; page.manage_(); await new Promise(resolve => setImmediate(resolve));
  assert.match(menus[1].title, /占用暂不可读/);
});
