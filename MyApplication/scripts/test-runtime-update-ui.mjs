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
  const start=source.indexOf('  private '+name);assert(start>=0,name+' missing');
  const end=source.indexOf('\n  /**',start+1);assert(end>start);
  return source.slice(start,end);
}
/** 提取生产组件传给设置页的真实回调，测试不复制偏好切换后的调度逻辑。 */
function callback(signature,name,argument){
  const start=source.indexOf(signature),bodyStart=source.indexOf('{',start)+1;
  const bodyEnd=source.indexOf('\n              },',bodyStart);assert(start>0&&bodyEnd>bodyStart);
  return name+'('+argument+'): void {'+source.slice(bodyStart,bodyEnd)+'\n}';
}
// 这些既有更新场景都从正常可交互首页开始；开屏/恢复排队由专门来源回归执行。
const text='class Harness {\nstartupFinished_=true; recoveringSessions_=false; recoveryPresentationDeferred_=false; showMcErrorSheet=false;\n'+[
  productionGetter('getPrefManager_'),productionGetter('getJdkManager_'),
  method('async checkRuntimeUpdates_'),method('drainUpdateDialogs_'),
  method('showRuntimeUpdateDialog_'),method('showUpdateDialog('),
  method('async importLocalJdk_'),
  callback('onJdkChannelChange: (channel: string): void => {','onChannelChange','channel: string'),
  callback('onJdkWebChange: (enabled: boolean): void => {','onWebChange','enabled: boolean'),
  callback('onJdkSourceChange: (value: string) => {','onSourceChange','value: string'),
  callback('onJdkDelete: (version: string) => {','onDelete','version: string')].join('\n')+'\n}';
const js=compiler.transpileModule(text,{compilerOptions:{target:compiler.ScriptTarget.ES2020}}).outputText;
/** 来源/排队判据装载真实类，仅关闭诊断产品门；正式候选不能依赖一份简化的测试替身。 */
function loadPromptModule(file,deps={}){
  const code=compiler.transpileModule(fs.readFileSync(new URL(file,import.meta.url),'utf8'),{
    compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
  const exports={};vm.runInNewContext(code,{exports,require:name=>{
    if(!(name in deps))throw new Error('Unmocked prompt dependency: '+name);return deps[name];
  },Object,Number,JSON,Array,RegExp,Map});return exports;
}
const prompt=loadPromptModule('../entry/src/main/ets/sideload/SideloadUpdateTestSession.ets',{
  commons:{DiagnosticPolicy:{hasTestHooks:()=>false},UPDATE_MANIFEST_URLS:['https://production.example/update.json']},
  'entry/ProductBuildProfile':{ProductBuildProfile:{product:'default'}},update:{}});
const presenter=loadPromptModule('../entry/src/main/ets/components/UpdatePromptPresenter.ets').UpdatePromptPresenter;
let resolveFirst;let requests=0;const configured=[],configurations=[],timers=[];
const repository={configure:async(channel,source,web)=>{configured.push(channel);configurations.push({channel,source,web});},refresh:()=>{
  requests++;return requests===1?new Promise(resolve=>{resolveFirst=resolve;}):Promise.resolve({ok:true,error:''});
}};
const scheduling=loadPromptModule('../launch/src/main/ets/RuntimeUpdatePolicy.ets');
let dialogFailure=false,hostVisible=true;
const importSlots=[];
const Harness=new Function('RuntimeCatalogRepository','AppStorage','setTimeout','SideloadUpdateTestSession',
  'SideloadUpdatePromptPolicy','UpdatePromptPresenter','runtimePromptDue','formatBytes',
  'CustomDialogController','UpdateDialog','DialogAlignment','setJdkDownloadSource','setJdkWebEnabled',
  'AppLogger','TAG','LOG_DOMAIN_LAUNCH','SUPPORTED_JDK_VERSIONS','GameArchiveIO','JdkImporter','fs',js+'\nreturn Harness;')(
  {instance:()=>repository},{get:()=>hostVisible},fn=>{timers.push(fn);return timers.length;},
  prompt.SideloadUpdateTestSession,prompt.SideloadUpdatePromptPolicy,presenter,
  scheduling.runtimePromptDue,String,
  class { open(){if(dialogFailure)throw Error('controlled dialog open failure');} },
  options=>options,{Center:'center'},()=>{},()=>{},{info(){},warn(){}},'test',0,
  importSlots,{importResourceFile:async()=>({cancelled:true})},{},{unlinkSync(){}});
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
  deleting.onDelete('17');
  assert.equal(deleting.jdkExtractProgress.includes('已删除'),deleted,'租约/IO拒绝时不能显示删除成功');
  if(!deleted)assert(messages.length>0,'删除失败必须有可见反馈');
});
assert.deepEqual(failures,[],'所有生产回调和弹窗席位边界应通过');
console.log('PASS production Index: channel/source/web changes coalesce latest checks; manual intent retained; hidden, deferred, empty and failed runtime dialogs do not leak presenter ownership.');
