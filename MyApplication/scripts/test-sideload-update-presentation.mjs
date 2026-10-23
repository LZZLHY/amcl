/**
 * R3 自更新展示命令回归：执行真实 Content 的普通方法，平台边界复用现役协调器 fixture。
 * 本测试只验证展示层选择了哪个既有 VM 命令，不模拟授权成功、安装终态或持久执行权。
 * ArkUI 布局和 Sheet 动画仍由 SDK 与设备验证，不能以本测试替代视觉验收。
 */
import assert from 'node:assert/strict';
import { fixture } from './lib/sideload-coordinator-fixture.mjs';

const environment = await fixture();
const { SideloadUpdateContent: Content } = environment.load('entry/src/main/ets/components/SideloadUpdateContent.ets');
const { SideloadUpdateViewModel: ViewModel } = environment.load('entry/src/main/ets/sideload/SideloadUpdateViewModel.ets');
const { SideloadUpdatePhase: Phase } = environment.load('update/src/main/ets/SideloadUpdateModels.ets');

/**
 * 每组使用新的真实组件与 VM 默认值，只替换命令出口为调用记录。
 * 不挂载展示面、不调用 onShown，因此这些展示用快照不会向真实 Coordinator 授予更新许可。
 */
function presentation(values = {}) {
  const component = new Content();
  component.viewModel = Object.assign(new ViewModel(), {
    phase: Phase.Downloading, working: true, accountReady: true, connectionReady: true,
    downloadTaskId: 'presentation-download', downloadState: 'running', progress: 42.8,
  }, values);
  const commands = [];
  for (const method of ['cancel', 'closeLogin', 'reconcile', 'start', 'login', 'checkAccount',
    'renewMaterial', 'importMaterial', 'openDebugSettings', 'retryConnection']) {
    component.viewModel[method] = (...args) => { commands.push({ method, args }); };
  }
  component.onDismiss = () => { commands.push({ method: 'dismiss', args: [] }); };
  component.getUIContext = () => ({ getRouter: () => ({
    back: value => { commands.push({ method: 'back', args: [value] }); },
    pushUrl: value => { commands.push({ method: 'pushUrl', args: [value] }); },
  }) });
  return { component, commands };
}

/**
 * 枚举覆盖与独立的产品动作预期一起核对；新增 phase 必须显式归类，不能落入无人审核的缺省。
 * 下载/准备阶段禁止添加人工“开始安装”，派发和等待核实也不允许借按钮重派安装。
 */
const cases = [
  [Phase.Idle, { working: false, downloadTaskId: '' }, '重试更新', true, 'start'],
  [Phase.Resolving, { downloadTaskId: '' }, '准备中', false],
  [Phase.Queued, { downloadState: 'waiting' }, '下载中', false],
  [Phase.Downloading, {}, '下载中', false],
  [Phase.Verifying, {}, '下载中', false],
  [Phase.Downloaded, { downloadState: 'done' }, '准备中', false],
  [Phase.PreparingMaterial, { downloadState: 'done', finishing: true }, '准备中', false],
  [Phase.Signing, { downloadState: 'done', finishing: true }, '签名中', false],
  [Phase.Ready, { downloadState: 'done', finishing: true }, '准备中', false],
  [Phase.Transferring, { downloadState: 'done', finishing: true }, '准备中', false],
  [Phase.DispatchIntent, { downloadState: 'done' }, '安装中', false],
  [Phase.Installing, { downloadState: 'done' }, '安装中', false],
  [Phase.AwaitingRestart, { downloadState: 'done' }, '关闭界面', true, 'cancel,dismiss'],
  [Phase.Verified, { working: false, downloadState: 'done' }, '完成', true, 'cancel,dismiss'],
  [Phase.Failed, { working: false }, '重试更新', true, 'start'],
  [Phase.Cancelled, { working: false }, '重试更新', true, 'start'],
  [Phase.ConfirmationPending, { working: false }, '重新检查', true, 'reconcile'],
  [Phase.StorageBlocked, { working: false }, '重试读取', true, 'reconcile'],
];
assert.deepEqual(cases.map(([phase]) => phase).sort(), Object.values(Phase).sort(), '所有真实 phase 均有独立动作预期');
for (const [phase, values, label, enabled, command = ''] of cases) {
  const { component, commands } = presentation({ phase, ...values });
  assert.equal(component.primaryLabel(), label, phase + ' 主动作文案');
  assert.equal(component.primaryEnabled(), enabled, phase + ' 主动作可用性');
  component.runPrimary();
  assert.equal(commands.map(value => value.method).join(','), command, phase + ' 只能调用预期命令');
}

/** 初次缺省连接事实还未采样时只显示准备；签名器明确要求重启时必须保留真实恢复指导。 */
for (const phase of [Phase.Idle, Phase.Resolving]) {
  const { component } = presentation({ phase, connectionReady: false, message: '正在核实更新版本' });
  assert.equal(component.statusTitle(), '正在准备更新');
  assert.equal(component.statusHint(), '正在核实更新版本');
}
{
  const { component } = presentation({ phase: Phase.AwaitingRestart, working: false,
    downloadState: 'done', message: '请重新打开 AMCL 后继续签名' });
  assert.equal(component.statusTitle(), '请重新打开 AMCL');
  assert.equal(component.statusHint(), '请重新打开 AMCL 后继续签名');
}

/** 关闭登录只撤销当前授权，不关闭原模态、不取消下载；派发后退出只卸载观察面。 */
{
  const { component, commands } = presentation({ loginVisible: true });
  assert.equal(component.prepareExit(), false);
  assert.deepEqual(commands.map(value => value.method), ['closeLogin']);
}
for (const phase of [Phase.DispatchIntent, Phase.Installing, Phase.ConfirmationPending]) {
  const { component, commands } = presentation({ phase });
  component.close();
  assert.deepEqual(commands.map(value => value.method), ['dismiss'], phase + ' 关闭不能调用取消');
}
{
  const { component, commands } = presentation();
  component.close();
  assert.deepEqual(commands.map(value => value.method), ['cancel', 'dismiss']);
}
{
  const { component, commands } = presentation({ runtimeRetired: true, loginVisible: true });
  component.close();
  assert.deepEqual(commands.map(value => value.method), ['dismiss'], '退役展示不能驱动新 owner 的授权或取消');
}

/** 账号、材料、手填端口均复用既有 VM 命令；同时阻塞时授权优先，不产生第二轮更新。 */
for (const [values, label, method] of [
  [{ needsLogin: true }, '登录华为账号', 'login'],
  [{ accountRetry: true }, '重新检查登录', 'checkAccount'],
  [{ needsImport: true, materialReady: false }, '导入签名配置', 'importMaterial'],
  [{ needsImport: true, materialReady: true }, '重新获取配置', 'renewMaterial'],
  [{ needsLogin: true, needsImport: true }, '登录华为账号', 'login'],
  [{ accountRetry: true, needsImport: true }, '重新检查登录', 'checkAccount'],
  [{ connectionReady: false }, '打开设置', 'openDebugSettings'],
]) {
  const { component, commands } = presentation(values);
  assert.equal(component.primaryLabel(), label);
  assert.equal(component.primaryEnabled(), true);
  component.runPrimary();
  assert.deepEqual(commands.map(value => value.method), [method]);
}
{
  const { component, commands } = presentation({ connectionReady: false });
  component.manualPort = true;
  assert.equal(component.primaryLabel(), '连接并继续');
  component.runPrimary();
  assert.deepEqual(commands.map(value => value.method), ['retryConnection']);
  assert.deepEqual(commands[0].args, [false], '未挂载真实窗口时不能强制提交前台事实');
  component.aboutToDisappear();
}

/** 存储/安装核实优先于快照残留的恢复标签，不能误跳设置或启动新安装。 */
for (const phase of [Phase.StorageBlocked, Phase.ConfirmationPending]) {
  const { component, commands } = presentation({ phase, working: false, recoveryAction: 'runtime', needsImport: true });
  component.runPrimary();
  assert.deepEqual(commands.map(value => value.method), ['reconcile']);
}
for (const [recoveryAction, key] of [['runtime', 'amclUpdateOpenSettings'], ['package', 'amclUpdateRecoveryRequested']]) {
  const { component, commands } = presentation({ phase: Phase.Failed, working: false, recoveryAction });
  component.runPrimary();
  assert.deepEqual(commands.map(value => value.method), ['cancel', 'dismiss', 'back']);
  assert.equal(typeof environment.storage.get(key), 'number');
}

/** 下载数值不代表安装终态；保护阶段、失败、取消、退役面均不能继续显示下载主视图。 */
{
  const { component } = presentation({ progress: 100.5, transfer: '42 MB / 42 MB · 2 MB/s' });
  assert.equal(component.progressLabel(), '100%');
  assert.equal(component.transferSize(), '42 MB / 42 MB');
  assert.equal(component.transferSpeed(), '↓ 2 MB/s');
  assert.equal(component.statusTitle(), '正在下载安装包');
  assert.equal(component.showDownload(), true);
}
for (const phase of [Phase.DispatchIntent, Phase.Installing, Phase.ConfirmationPending, Phase.StorageBlocked,
  Phase.Verified, Phase.Failed, Phase.Cancelled]) {
  const { component } = presentation({ phase });
  assert.equal(component.showDownload(), false, phase + ' 不显示遗留下载进度作为主状态');
}
console.log('PASS R3 presentation: all 18 phases, auth-only dismissal, protected installation close, recovery commands and real download projection.');
