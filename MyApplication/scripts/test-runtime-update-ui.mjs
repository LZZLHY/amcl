/** 执行 Index 的真实业务方法/通道回调，验证排队顺序；不把宿主测试当作 ArkUI 视觉或设备验收。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import compiler from './lib/ets-compiler.mjs';
const source=fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets',import.meta.url),'utf8');
// 偏好和JDK管理器已由生产getter惰性持有。按SDK AST同时提取getter，
// 夹具只提供其缓存字段，不另写同名返回函数绕过真实访问协议。
const indexAst=compiler.createSourceFile('Index.ets',source,compiler.ScriptTarget.Latest,true);
const indexComponent=indexAst.statements.find(node=>node.name?.getText(indexAst)==='Index');
function productionGetter(name){
  const member=indexComponent?.members?.find(value=>value.name?.getText(indexAst)===name);
  assert.ok(member,'缺少真实getter：'+name);return member.getText(indexAst);
}
function method(name){
  // 用SDK AST界定真实方法，不能把下一个注释的位置当函数结束而误执行后续@Builder布局。
  const identifier=name.replace(/^async\s+/,'').replace(/\($/,'');
  const member=indexComponent?.members?.find(value=>value.name?.getText(indexAst)===identifier);
  assert(member,name+' missing');return member.getText(indexAst);
}
/** 提取生产组件传给设置页的真实回调，测试不复制偏好切换后的调度逻辑。 */
function callback(signature,name,argument){
  const start=source.indexOf(signature),bodyStart=source.indexOf('{',start)+1;
  const bodyEnd=source.indexOf('\n              },',bodyStart);assert(start>0&&bodyEnd>bodyStart);
  return name+'('+argument+'): void {'+source.slice(bodyStart,bodyEnd)+'\n}';
}
// 这些既有更新场景都从正常可交互首页开始；开屏/恢复排队由专门来源回归执行。
const text='class Harness {\njdkVersions=[]; startupFinished_=true; recoveringSessions_=false; recoveryPresentationDeferred_=false; showMcErrorSheet=false;\n'+[
  productionGetter('getPrefManager_'),productionGetter('getJdkManager_'),
  method('initRuntimeUpdateCheck_'),method('async checkRuntimeUpdates_'),method('drainUpdateDialogs_'),
  method('showRuntimeHostRequirement_'),method('async resumeRuntimeDependency_'),
  method('showRuntimeUpdateDialog_'),method('showUpdateDialog('),
  method('configureConfirmedJdkSource_'),method('async importLocalJdk_'),method('async chooseAndImportLocalJdk_'),
  callback('onJdkChannelChange: (channel: string): Promise<boolean> => {','onChannelChange','channel: string'),
  callback('onJdkWebChange: (enabled: boolean): Promise<boolean> => {','onWebChange','enabled: boolean'),
  callback('onJdkSourceChange: (value: string): Promise<boolean> => {','onSourceChange','value: string'),
  callback('onJdkDelete: (version: string, identity: string) => {','onDelete','version: string, identity: string')].join('\n')+'\n}';
const js=compiler.transpileModule(text,{compilerOptions:{target:compiler.ScriptTarget.ES2020}}).outputText;
/** 实际提示队列保留快照及手动检查意图，宿主替身只提供窗口。 */
function loadPromptModule(file,deps={}){
  const code=compiler.transpileModule(fs.readFileSync(new URL(file,import.meta.url),'utf8'),{
    compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
  const exports={};vm.runInNewContext(code,{exports,require:name=>{
    if(!(name in deps))throw new Error('Unmocked prompt dependency: '+name);return deps[name];
  },Object,Number,JSON,Array,RegExp,Map});return exports;
}
const prompt=loadPromptModule('../entry/src/main/ets/sideload/SideloadUpdatePromptPolicy.ets');
const presenter=loadPromptModule('../entry/src/main/ets/components/UpdatePromptPresenter.ets').UpdatePromptPresenter;
// 此套件隔离持久化边缘，事务失败和原值恢复由 frozen-settings-save 验证。
function saveLauncherChange_(values,publish) {
  if(values.jdkWebEnabled===false && this.jdkSource==='web') this.prefManager_.jdkSource='auto';
  if(!Object.hasOwn(this.prefManager_,'jdkWebEnabled')) this.prefManager_.jdkWebEnabled=this.jdkWebEnabled;
  if(!Object.hasOwn(this.prefManager_,'jdkSource')) this.prefManager_.jdkSource=this.jdkSource;
  Object.assign(this.prefManager_,values);publish();return Promise.resolve(true);
}
let resolveFirst;let requests=0;const configured=[],configurations=[],timers=[];
const repository={hostUpgradeReason:()=>'',configure:async(channel,source,web)=>{configured.push(channel);configurations.push({channel,source,web});},refresh:()=>{
  requests++;return requests===1?new Promise(resolve=>{resolveFirst=resolve;}):Promise.resolve({ok:true,error:''});
}};
const scheduling=loadPromptModule('../launch/src/main/ets/RuntimeUpdatePolicy.ets');
let dialogFailure=false,hostVisible=true;
const importSlots=[];
const Harness=new Function('RuntimeAppDependency','RuntimeCatalogRepository','AppStorage','setTimeout',
  'SideloadUpdatePromptPolicy','UpdatePromptPresenter','runtimePromptDue','formatBytes',
  'CustomDialogController','UpdateDialog','DialogAlignment','UpdateReminderLevel','setJdkDownloadSource','setJdkWebEnabled',
  'AppLogger','TAG','LOG_DOMAIN_LAUNCH','SUPPORTED_JDK_VERSIONS','GameArchiveIO','JdkImporter','fs',
  'getTaskActivityOwner','ActivityCategory','ActivityStatus','DistributionPolicy','GameRunAdmission','runtimeCheckDue',js+'\nreturn Harness;')(
  {legacyIntent:()=>null,unconfirmedIntent:()=>null,hasVerifiedIntent:()=>false,requirements:()=>[]},{instance:()=>repository},{get:()=>hostVisible},fn=>{timers.push(fn);return timers.length;},
  prompt.SideloadUpdatePromptPolicy,presenter,
  scheduling.runtimePromptDue,String,
  class { constructor(options){this.options=options;} open(){if(dialogFailure)throw Error('controlled dialog open failure');} },
  options=>options,{Center:'center'},loadPromptModule('../entry/src/main/ets/components/UpdateReminderPolicy.ets').UpdateReminderLevel,()=>{},()=>{},{info(){},warn(){}},'test',0,
  importSlots,{importResourceFile:async()=>({cancelled:true})},{},{unlinkSync(){}},
  () => ({ async recordSummary() {} }), { JDK: 'jdk' }, { SUCCESS: 'success', FAILED: 'failed' },{isStore:()=>false},{isAllowed:()=>true},scheduling.runtimeCheckDue);
Harness.prototype.saveLauncherChange_ = saveLauncherChange_;
const page=new Harness();
Object.assign(page,{context:{},jdkChannel:'stable',jdkSource:'github',jdkWebEnabled:false,jdkChecking:false,
  jdkHasUpdate:false,pendingRuntimeCheck_:false,pendingRuntimePrompt_:false,pendingRuntimePromptManual_:false,
  pendingAppUpdate_:null,prefManager_:{jdkLastCheck:0},updateJdkReadyState:()=>{}});
const first=page.checkRuntimeUpdates_(false);await Promise.resolve();
assert.equal(requests,1);
page.onChannelChange('preview');await Promise.resolve();await Promise.resolve();
assert.equal(page.jdkChannel,'preview');assert.equal(page.pendingRuntimeCheck_,true);
assert.deepEqual(configured,['stable','preview'],'检查仍在运行时也必须先失效旧通道');
resolveFirst({ok:true,error:''});await first;
assert.equal(page.prefManager_.jdkLastCheck,0,'旧通道结果不能写最新成功时间');
assert.equal(timers.length,1);await timers.shift()();await Promise.resolve();await Promise.resolve();
assert.equal(requests,2);assert.equal(configured.at(-1),'preview');assert(page.prefManager_.jdkLastCheck>0);

// 同一个面板席位保留手动意图；手动检查不因“本会话开过游戏”被当作自动提示丢弃。
const queue=new Harness();Object.assign(queue,{updateDialogCtrl_:{},gameLaunchedThisSession:true,showPrivacy:false,
  pendingRuntimePrompt_:false,pendingRuntimePromptManual_:false,pendingAppUpdate_:null,updatePresenterOwner:'runtime-update-test',
  // 原App弹窗方法会先核当前通道；本场景固定default稳定通道，只验证已有手动排队意图。
  prefManager_:{appUpdateChannel:'stable'}});
queue.showRuntimeUpdateDialog_(true);assert.equal(queue.pendingRuntimePromptManual_,true);
queue.updateDialogCtrl_=null;let displayed=false;
queue.showRuntimeUpdateDialog_=manual=>{displayed=manual;};queue.drainUpdateDialogs_();assert.equal(displayed,true);
queue.updateDialogCtrl_={};Harness.prototype.showUpdateDialog.call(queue,{versionCode:1},true);
Harness.prototype.showUpdateDialog.call(queue,{versionCode:2},false);assert.equal(queue.pendingAppUpdate_.manual,true);
queue.updateDialogCtrl_=null;queue.showUpdateDialog=(_manifest,manual)=>{displayed=manual;};
displayed=false;queue.drainUpdateDialogs_();assert.equal(displayed,true);assert.equal(queue.pendingAppUpdate_,null);
// 本场景退出自己的席位，下一场景不能继承前一个模拟 controller 的展示所有者。
presenter.forget(queue.updatePresenterOwner);

// 自动提示在开过游戏后直接返回，不能调用未提供的 renderer/manager。
const automatic=new Harness();Object.assign(automatic,{updateDialogCtrl_:null,gameLaunchedThisSession:true,
  showPrivacy:false,pendingRuntimePrompt_:true,pendingRuntimePromptManual_:false,pendingAppUpdate_:null,
  updatePresenterOwner:'runtime-automatic-test'});
automatic.drainUpdateDialogs_();assert.equal(automatic.pendingRuntimePrompt_,false);
presenter.forget(automatic.updatePresenterOwner);

const failures=[];
/** 每个反例隔离网络等待和全局席位，让失败证据能同时展示来源/web/弹窗三个边界。 */
async function auditCase(name,run){
  try { await run(); console.log('PASS '+name); }
  catch(error){failures.push({name,error:error.message});console.error('FAIL '+name+': '+error.message);}
}
for(const kind of ['source','web','rapid'])await auditCase(kind+' preference invalidates check and schedules latest recheck',async()=>{
  requests=0;timers.length=0;configured.length=0;configurations.length=0;
  const changing=new Harness();Object.assign(changing,{context:{},jdkChannel:'preview',jdkSource:'web',
    jdkWebEnabled:true,jdkChecking:false,jdkHasUpdate:false,pendingRuntimeCheck_:false,
    prefManager_:{jdkLastCheck:0},updateJdkReadyState:()=>{}});
  const inFlight=changing.checkRuntimeUpdates_(true);await Promise.resolve();
  if(kind==='source')changing.onSourceChange('mirror');
  else if(kind==='web')changing.onWebChange(false);
  else {changing.onSourceChange('mirror');changing.onWebChange(false);changing.onSourceChange('github');}
  await Promise.resolve();await Promise.resolve();
  const queued=changing.pendingRuntimeCheck_;
  resolveFirst({ok:true,error:''});await inFlight;
  assert.equal(queued,true,'偏好切换必须为被失效的检查保留重查意图');
  assert.equal(changing.prefManager_.jdkLastCheck,0,'旧来源检查不得写成功时间');
  assert.equal(timers.length,1,'多个偏好变化合并为一次重查');
  await timers.shift()();await Promise.resolve();await Promise.resolve();
  assert.equal(requests,2);assert(changing.prefManager_.jdkLastCheck>0);
  if(kind==='web'){assert.equal(changing.jdkSource,'auto');assert.equal(changing.prefManager_.jdkSource,'auto');}
  if(kind==='rapid')assert.deepEqual(configurations.at(-1),{channel:'preview',source:'github',web:false},'合并检查只消费最终偏好');
});

function dialogPage(owner,overrides={}){
  const build={id:'current-build',archive:{sizeBytes:10,sha256:'a'.repeat(64)},notes:[]};
  const page=new Harness();Object.assign(page,{context:{},updateDialogCtrl_:null,
    updatePresenterOwner:owner,gameLaunchedThisSession:false,showPrivacy:false,
    pendingRuntimePrompt_:false,pendingRuntimePromptManual_:false,pendingAppUpdate_:null,
    jdkChannel:'preview',jdkManager_:{listVersions:()=>[{version:'17',updateAvailable:true,userImported:false,installedTag:'old'}]},
    prefManager_:{jdkDeferredAt:0,jdkDeferredTarget:''},
    ...overrides});
  repository.buildFor=()=>build;repository.snapshot=()=>({issuedAt:'2026-10-17T00:00:00Z'});
  return page;
}
for(const reason of ['after-game','hidden-host','privacy','empty-items','deferred','open-failure'])await auditCase('JDK dialog '+reason+' leaves global presenter available',()=>{
  const owner='runtime-no-dialog-'+reason;
  const page=dialogPage(owner);
  if(reason==='after-game')page.gameLaunchedThisSession=true;
  if(reason==='hidden-host')hostVisible=false;
  if(reason==='privacy')page.showPrivacy=true;
  if(reason==='empty-items')page.jdkManager_.listVersions=()=>[];
  if(reason==='deferred'){
    page.prefManager_.jdkDeferredAt=Date.now();
    page.prefManager_.jdkDeferredTarget='preview:'+JSON.stringify({'17':'current-build:'+ 'a'.repeat(64)});
  }
  dialogFailure=reason==='open-failure';
  try {
    page.showRuntimeUpdateDialog_(['open-failure','hidden-host','privacy'].includes(reason));
    assert.equal(presenter.owns(owner),false,'没有展示JDK弹窗时不能占住App/关于页共用席位');
    if(reason==='hidden-host'||reason==='privacy')assert.equal(page.pendingRuntimePromptManual_,true,'宿主暂时不可见时保留手动提示意图');
  } finally { dialogFailure=false;hostVisible=true;presenter.forget(owner); }
});
// 必需修复使用真实Index方法；自动偏好、缓存、提示延后和无网络目标分别构造负控。
for(const channel of ['stable','preview'])await auditCase(channel+' required repair bypasses normal check throttling and has guarded dismiss',()=>{
  const owner='required-'+channel;
  const page=dialogPage(owner,{jdkChannel:channel,jdkAutoCheck:false,runtimeAutoCheckStarted_:false,
    prefManager_:{jdkLastCheck:Date.now(),jdkDeferredAt:Date.now(),jdkDeferredTarget:'keep-existing-defer'}});
  const states=[{version:'17',repairRequired:true,updateAvailable:false,userImported:false,installedTag:'old',stateText:'缺少必需写回修复'}];
  page.jdkManager_.listVersions=()=>states;let checks=0;page.checkRuntimeUpdates_=manual=>{assert.equal(manual,false);checks++;};
  page.initRuntimeUpdateCheck_();assert.equal(checks,1,'本地不兼容不能被自动检查关闭或当天成功时间压住');
  page.initRuntimeUpdateCheck_();assert.equal(checks,1,'同一启动会话不重复联网');
  page.showRuntimeUpdateDialog_(false);const dialog=page.updateDialogCtrl_.options;
  assert.equal(dialog.autoCancel,false);assert.equal(dialog.builder.reminderLevel,'required');
  assert(dialog.builder.requiredNotice.consequence.includes('无法启动'));assert.equal(dialog.builder.newVersion,channel==='stable'?'稳定通道':'预览通道');
  let dismissed=false;dialog.onWillDismiss({dismiss(){dismissed=true;}});assert.equal(dismissed,false,'遮罩与Back不得隐式关闭必需提醒');
  const before=structuredClone(page.prefManager_);page.closeUpdateDialog_=()=>{page.updateDialogCtrl_=null;presenter.release(owner);};
  dialog.builder.onLater();assert.deepEqual(page.prefManager_,before,'必需修复的明确退出不写普通24小时延后');assert(page.runtimeRequiredDismissed_);
  page.showRuntimeUpdateDialog_(false);assert.equal(page.updateDialogCtrl_,null,'明确暂不游戏后同会话不循环弹窗');
  page.gameLaunchedThisSession=true;page.showRuntimeUpdateDialog_(true);assert(page.updateDialogCtrl_,'再次请求受影响游戏必须能重新提示');
  presenter.forget(owner);
});
await auditCase('required runtime repair is presented before a queued ordinary App update',()=>{
  const owner='required-priority',page=dialogPage(owner);const states=[{version:'17',repairRequired:true,updateAvailable:true,userImported:false,stateText:'必须修复'}];
  page.jdkVersions=states;page.jdkManager_.listVersions=()=>states;page.pendingRuntimePrompt_=true;
  page.pendingAppUpdate_={};page.showUpdateDialog=()=>{throw Error('ordinary App prompt must wait');};
  page.drainUpdateDialogs_();assert.equal(page.updateDialogCtrl_.options.builder.reminderLevel,'required');assert(page.pendingAppUpdate_);
  presenter.forget(owner);
});
await auditCase('compatible or imported runtime does not force a disabled automatic check',()=>{
  for(const state of [{version:'17',repairRequired:false},{version:'17',repairRequired:true,userImported:true}]){
    const page=dialogPage('ordinary-disabled',{jdkAutoCheck:false,runtimeAutoCheckStarted_:false});page.jdkManager_.listVersions=()=>[state];
    page.checkRuntimeUpdates_=()=>{throw Error('unexpected forced check');};page.initRuntimeUpdateCheck_();
  }
});
await auditCase('required local repair remains visible without a downloadable catalog target',()=>{
  const owner='required-offline',page=dialogPage(owner);page.jdkCatalogStatus='网络不可用，请重试';
  page.jdkManager_.listVersions=()=>[{version:'21',repairRequired:true,updateAvailable:false,userImported:false,stateText:'旧运行时不兼容'}];
  repository.buildFor=()=>undefined;page.showRuntimeUpdateDialog_(true);const dialog=page.updateDialogCtrl_.options;
  assert.equal(dialog.builder.actionLabel,'重新检查修复包');assert.equal(dialog.builder.items.length,1);assert(dialog.builder.items[0].description.includes('网络不可用'));
  let checked=false;page.closeUpdateDialog_=()=>{presenter.release(owner);page.updateDialogCtrl_=null;};
  page.checkRuntimeUpdates_=manual=>{checked=manual;};dialog.builder.onInstallItems(['21']);assert(checked,'没有目标只能重查，不能创建无身份安装任务');
  presenter.forget(owner);
});
for(const size of [0,3,5,9])await auditCase('local import menu consumes '+size+' registered slots with bounded menus',async()=>{
  const menus=[],steps=[],invalidButtons=[];
  importSlots.splice(0,importSlots.length,...['8','17','21','25','29','33','37','41','45'].slice(0,size));
  const importing=new Harness();Object.assign(importing,{jdkImporting:false,theme:{textPrimary:'#fff'},context:{filesDir:'/app'},
    updateJdkReadyState(){},showToast_(){},getUIContext:()=>({getPromptAction:()=>({showActionMenu:async options=>{
      menus.push(options);assert(options.buttons.length>0&&options.buttons.length<=6,'SDK操作菜单最多显示六个按钮');
      for(const button of options.buttons)if(button.text.startsWith('JDK ')&&!importSlots.includes(button.text.slice(4)))invalidButtons.push(button.text);
      const wanted='JDK '+importSlots.at(-1),found=options.buttons.findIndex(button=>button.text===wanted);
      const index=found>=0?found:options.buttons.findIndex(button=>button.text==='下一页');
      assert(index>=0,'每个注册槽位必须可到达，不能固定只有四个按钮');
      steps.push(index);return{index};
    }})})});
  await importing.importLocalJdk_();
  assert.deepEqual(invalidButtons,[],'少量注册槽位时也不能产生undefined按钮');
  assert.equal(menus.length,size===0?0:Math.ceil(size/4),'菜单应按注册表分页，不显示undefined条目');
  assert.equal(importing.jdkImporting,false,'取消文件选择后释放导入状态');
});
for(const deleted of [false,true])await auditCase('delete callback reports actual '+deleted+' result',()=>{
  const deleting=new Harness(),messages=[];Object.assign(deleting,{jdkManager_:{deleteVersion:()=>deleted},
    updateJdkReadyState(){},showToast_:message=>messages.push(message)});
  deleting.onDelete('17','confirmed-slot');
  assert.equal(deleting.jdkExtractProgress.includes('已删除'),deleted,'租约/IO拒绝时不能显示删除成功');
  if(!deleted)assert(messages.length>0,'删除失败必须有可见反馈');
});
await auditCase('JDK rows follow replaced snapshots without rebuilding on progress frames',()=>{
  // 使用SDK AST读取真正交给ForEach的键函数；宿主只模拟官方“同键复用旧组件”的规则，
  // 不复制生产键算法。真机已复现安装/删除后旧行残留，最终ArkUI刷新仍须在设备复验。
  const body=fs.readFileSync(new URL('../entry/src/main/ets/pages/tabs/DownloadTab.ets',import.meta.url),'utf8');
  const ast=compiler.createSourceFile('DownloadTab.ets',body,compiler.ScriptTarget.Latest,true);
  const component=ast.statements.find(n=>n.name?.getText(ast)==='DownloadTab');
  const items=component.members.find(n=>n.name?.getText(ast)==='JdkItems_');
  const loops=[];
  function walk(node){
    if(node.expression?.getText(ast)==='ForEach'&&node.arguments?.[0]?.getText(ast)==='this.jdkVersions')loops.push(node);
    compiler.forEachChild(node,walk);
  }
  walk(items);assert.equal(loops.length,1,'必须覆盖实际JDK列表，不能测试未接线的辅助函数');
  const helper=component.members.find(n=>n.name?.getText(ast)==='jdkRowKey_')?.getText(ast)??'';
  const code=compiler.transpileModule('class RowHarness {'+helper+'\nkey(info: JdkVersionInfo): string { return ('+
    loops[0].arguments[2].getText(ast)+')(info); }}',{compilerOptions:{target:compiler.ScriptTarget.ES2020}}).outputText;
  const RowHarness=new Function(code+';return RowHarness;')(),page=new RowHarness(),busy=new Set();
  page.taskRevision=0;page.isJdkDownloading=major=>busy.has(major);
  let rows=new Map();
  const render=values=>{const next=new Map();const result=values.map(value=>{
    const key=page.key(value),row=rows.get(key)??{snapshot:structuredClone(value),busy:busy.has(value.version)};
    next.set(key,row);return row;
  });rows=next;return result;};
  const imported=major=>({version:major,installed:true,available:true,sizeMB:100,path:'/jdk/'+major,
    installedTag:'imported:fixture',expectedTag:'preview-'+major,updateAvailable:false,userImported:true,stateText:'本地导入'});
  const original=[imported('8'),imported('17')],first=render(original);
  const official={...original[1],installedTag:'preview-17',userImported:false,stateText:'已是最新'};
  const installed=render([original[0],official]);
  assert.equal(installed[1].snapshot.userImported,false,'受管安装已经提交后不能继续显示本地导入');
  assert.equal(installed[0],first[0],'另一槽位不能因邻居安装而重建');
  const absent={...original[0],installed:false,installedTag:'',userImported:false,stateText:''};
  assert.equal(render([absent,official])[0].snapshot.installed,false,'删除后同主版本行应成为下载入口');
  const stable={...official,expectedTag:'stable-17',updateAvailable:true,stateText:'有更新：preview → stable'};
  assert.equal(render([absent,stable])[1].snapshot.expectedTag,'stable-17','切通道必须显示新推荐');
  busy.add('17');page.taskRevision++;
  const running=render([absent,stable]);assert.equal(running[1].busy,true,'任务开始应同步行按钮状态');
  page.taskRevision++;
  assert.equal(render(structuredClone([absent,stable]))[1],running[1],'普通进度帧不能重复重建同一状态行');
  busy.clear();page.taskRevision++;
  assert.equal(render([absent,stable])[1].busy,false,'终态应恢复操作按钮');
});
assert.deepEqual(failures,[],'所有生产回调和弹窗席位边界应通过');
console.log('PASS production Index: channel/source/web changes coalesce latest checks; manual intent retained; hidden, deferred, empty and failed runtime dialogs do not leak presenter ownership.');
