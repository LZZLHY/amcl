/**
 * 执行SDK转换后的更新弹窗、进行态和设置入口，覆盖宿主TS转译无法发现的首帧及Builder问题。
 * 只替代ArkUI绘制/属性容器边界；initialRender、分支和几何方法均使用SDK产物原文。
 * 这是SDK产物回归，不声称替代设备布局、登录或安装验收；缺少产物必须失败。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import compiler from './lib/ets-compiler.mjs';

const directory=process.argv[2];
if(!directory)throw Error('需要指定本轮 SDK 转换输出的 ets 根目录或已保存的平铺夹具目录');
const old=process.argv.includes('--expect-old-crash');
const sdkTree=fs.existsSync(path.join(directory,'components'));
const records=[],children=[],storage=new Map();
let storeProduct=false;

/** 平台属性对象仅保存SDK构造器传入的值，不为不存在的业务getter补值。 */
class Property{
 constructor(value){this.value=value;}
 get(){return this.value;}set(value){this.value=value;}reset(value){this.value=value;}
 aboutToBeDeleted(){}purgeDependencyOnElmtId(){}
}
class View{
 constructor(){}finalizeConstruction(){}declareWatch(){}id__(){return 1;}
 createStorageProp(key,fallback){return new Property(storage.has(key)?storage.get(key):fallback);}
 observeComponentCreation2(callback){callback(1,true);}
 ifElseBranchUpdateFunction(_id,callback){callback();}
 forEachUpdateFunction(_id,items,callback){items.forEach(callback);}
 updateDirtyElements(){}updateStateVarsOfChildByElmtId(){}
 getUIContext(){return {};}
 static create(child){children.push(child);}
}
/** 绘制接口只记录实际属性写入，事件回调不执行，不能从测试侧发起更新业务。 */
function widget(name){
 return new Proxy({}, {get(_target,property){
  // 首帧尚无可复用节点。SDK 会在有 id 的条件子树上询问 canRetake，不能返回记录条数。
  if(name==='If'&&property==='canRetake')return ()=>false;
  return (...args)=>{records.push({name,property,args});};
 }});
}
const enumeration=new Proxy({}, {get(_target,key){return String(key);}});
const globals={ViewPU:View,ObservedPropertySimplePU:Property,ObservedPropertyObjectPU:Property,
 SynchedPropertySimpleOneWayPU:Property,SynchedPropertyObjectOneWayPU:Property,
 SubscriberManager:{Get:()=>({delete(){}})},AppStorage:{get:key=>storage.get(key)},
 ViewStackProcessor:{AllocateNewElmetIdForNextComponent:()=>1,StartGetAccessRecordingFor(){},StopGetAccessRecording(){}},
 registerNamedRoute(){},loadDocument(){},$r:name=>name,console};
for(const name of ['Column','Row','Stack','Text','Button','Scroll','If','ForEach','Image','Blank','Divider','Checkbox','LoadingProgress','Progress','SymbolGlyph','__Common__'])globals[name]=widget(name);
for(const name of ['Alignment','BarState','HorizontalAlign','VerticalAlign','TextOverflow','FlexAlign','FontWeight','ButtonType','ImageFit','BorderStyle','TextAlign','FlexDirection','TextCase','Color','ItemAlign','ProgressType'])globals[name]=enumeration;
const child=class{constructor(_parent,params){this.params=params;}};
class AccountPanel extends child {}

/** 依赖按真实模块名显式映射；未知模块失败，避免静默空替身把新依赖错误吞掉。 */
function load(file,exportPage=false,layout){
 // 当前候选直接使用 SDK 目录；历史缺 getter 的反例仍按原文件名从平铺证据读取。
 const sourcePath=path.join(directory,sdkTree?file:path.basename(file));
 const source=fs.readFileSync(sourcePath,'utf8')+(exportPage?'\nexport { '+path.basename(file,'.ts')+' };':'');
 const code=compiler.transpileModule(source,{compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
 const exports={};
 vm.runInNewContext(code,{...globals,exports,require(name){
  if(name.includes('UpdateDialogLayout'))return layout;
  if(name.includes('UpdateReminderPolicy'))return load('components/UpdateReminderPolicy.ts');
  if(name.includes('commons/'))return{AppIconName:enumeration,APP_VERSION:'1.0.0',ThemeMode:{SYSTEM:0},resolveTheme:()=>({bgPrimary:'#fff'}),DistributionPolicy:{isStore:()=>storeProduct}};
  // 旧路由新增主题依赖；这里显式隔离平台配置/偏好端口，首帧测试不冒称主题生命周期验收。
  if(name==='@ohos:app.ability.ConfigurationConstant')return{default:{ColorMode:{COLOR_MODE_DARK:0}}};
  if(name==='@ohos:window')return{default:{}};
  if(name.includes('feature_system/'))return{PreferenceManager:class{constructor(){if(file!=='pages/SoftwareUpdatePage.ts')throw Error('首帧夹具不得启动偏好IO');}}};
  if(name.includes('/AppTheme'))return{applyNativeTheme(){throw Error('首帧夹具不得切换平台主题');}};
  if(name.includes('update/'))return{noteTypeLabel:value=>value,UpdateChecker:{automaticAllowed:()=>true,currentVersionName:()=>''}};
  if(name.includes('SemanticColors'))return{changelogTone:()=>({text:'text',background:'background'})};
  if(name.includes('SideloadUpdateContent'))return{SideloadUpdateContent:child};
  // 进度容器使用真实SDK分支；仅隔离状态源和Web/窗口边界，事件不发起业务动作。
  if(name.includes('SideloadUpdateViewModel'))return{SideloadUpdateViewModel:class{}};
  if(name.includes('DeveloperLoginContent'))return{DeveloperLoginContent:child,developerLoginSheetOptions:input=>input};
  if(name.includes('DeveloperAccountPanel'))return{DeveloperAccountPanel:AccountPanel};
  if(name.includes('DeveloperAccountViewModel'))return{DeveloperAccountViewModel:class{}};
  if(name.includes('DeveloperAuthSession'))return{DeveloperAuthState:{Valid:'valid'}};
  if(name.includes('SettingsPrimitives'))return{SettingsGroup:child,SettingsValueRow:child,SettingsHint:child,SettingsDivider:child};
  if(name.includes('ImmersiveTitleScaffold'))return{ImmersiveTitleScaffold:child};
  if(name==='@ohos:file.picker'||name.includes('SideloadUpdateService')||name.includes('ProductBuildProfile'))return{};
  if(name.includes('AppIcon'))return{AppIcon:child};
  throw Error('未映射的SDK模块 '+name);
 }});
 return exports;
}
const layout=load('components/UpdateDialogLayout.ts');
const {UpdateDialog:Dialog}=load('components/UpdateDialog.ts',false,layout);
const {SideloadUpdatePage:Page}=load('pages/SideloadUpdatePage.ts',true,layout);
const params={selfUpdateParams:{autoStart:true},theme:{},entries:[]};
if(old){
 assert.throws(()=>new Dialog(undefined,params).initialRender(),/undefined/);
 assert.throws(()=>new Page(undefined,{}).initialRender(),/undefined/);
 console.log('PASS known old SDK output reproduces both missing-accessor rendering crashes');
}else{
 for(const updating of [false,true]){
  records.length=0;children.length=0;
  new Dialog(undefined,{...params,selfUpdating:updating}).initialRender();
  assert.equal(records.find(item=>item.name==='Column'&&item.property==='width').args[0],320);
  assert.equal(records.find(item=>item.name==='Column'&&item.property==='height').args[0],464);
 }
 records.length=0;new Dialog(undefined,{theme:{},items:[]}).initialRender();
 assert.equal(records.find(item=>item.name==='Column'&&item.property==='width').args[0],'88%');
 for(const item of records.filter(item=>item.property==='constraintSize')){
  if(item.args[0].maxHeight!==undefined)assert(Number.isFinite(item.args[0].maxHeight));
 }
 // 两种业务载体均运行真实SDK生成的强提醒分支与生命周期guard，不以源码字符串冒充UI行为。
 const reminder=load('components/UpdateReminderPolicy.ts');
 for(const app of [false,true])for(const required of [false,true]){
  records.length=0;let dismissGuard,exitGuard;
  const dialog=new Dialog(undefined,{theme:{},selfUpdateParams:app?{autoStart:true}:undefined,
   reminderLevel:required?reminder.UpdateReminderLevel.REQUIRED:reminder.UpdateReminderLevel.NORMAL,
   requiredNotice:{reason:'已有环境不兼容',consequence:'修复前无法继续此功能',exitLabel:'暂不使用'},
   items:app?[]:[{id:'17',title:'JDK17',current:'old',target:'new',sizeLabel:'1MB',description:'兼容修复'}],
   onDismissGuardReady:guard=>{dismissGuard=guard;},onExitGuardReady:guard=>{exitGuard=guard;}});
  dialog.aboutToAppear();dialog.initialRender();
  if(app)assert(records.some(row=>row.name==='Text'&&row.property==='create'&&row.args[0]==='查看完整更新日志'));
  assert.equal(dismissGuard(),!required);assert.equal(exitGuard(),true,'页面生命周期退出不应被发现态强提醒锁死');
  // 必需态必须显示真实原因与影响；不依赖已移除的重复“必须处理”装饰标签。
  for(const text of ['已有环境不兼容','修复前无法继续此功能'])
   assert.equal(records.some(row=>row.name==='Text'&&row.property==='create'&&row.args[0]===text),required);
  assert(records.some(row=>row.name==='Button'&&row.property==='createWithLabel'&&row.args[0]===(required?'暂不使用':'稍后再说')),
   '两类提醒都应有明确的次操作，必需态不得仍用普通稍后文案');
 }
 records.length=0;new Page(undefined,{}).initialRender();
 assert(records.some(item=>item.property==='width'&&item.args[0]===320));
 storage.set('screenWidthVp',240);storage.set('screenHeightVp',300);
 records.length=0;new Dialog(undefined,params).initialRender();
 assert(records.find(item=>item.name==='Column'&&item.property==='width').args[0]<=240);
 assert(records.find(item=>item.name==='Column'&&item.property==='height').args[0]<=300);
 // 进行态真实SDK渲染不再提供发行日志切换，也不出现禁用的“准备中”按钮。
 const {SideloadUpdateContent:Content}=load('components/SideloadUpdateContent.ts');
 for(const phase of ['downloading','preparing-material','signing','transferring','installing','confirmation-pending']){
  const retryAccount=phase==='preparing-material';
  const viewModel={phase,working:true,finishing:false,version:'1.0.7',runtimeRetired:false,accountReady:!retryAccount,
   needsLogin:false,accountRetry:retryAccount,connectionReady:true,checking:false,signingIssue:'',loginVisible:false,
   loginBusy:false,loginUrl:'',downloadTaskId:'sdk-fixture',downloadState:phase==='downloading'?'running':'done',
   progress:42,transfer:'42 / 100 · 1MB/s',activityId:0};
  const content=new Content(undefined,{viewModel,theme:{},params:{manifest:{versionName:'1.0.7',notes:'本次发行说明'}}});
  for(const expanded of [false,true]){
   records.length=0;children.length=0;
   content.detailsVisible=expanded;
   content.initialRender();
   const text=records.flatMap(item=>(item.name==='Text'&&item.property==='create')||(item.name==='Button'&&item.property==='createWithLabel')?item.args:[]);
   assert(!text.includes('查看完整更新日志'));assert(!text.includes('返回更新进度'));
   assert(text.includes(expanded?'收起详情':'查看详情'));assert(!text.includes('准备中'));
   assert(text.includes(['installing','confirmation-pending'].includes(phase)?'关闭界面':'取消更新'));
   if(retryAccount){
    assert(text.includes('重新检查登录'));assert(!text.includes('重新登录华为账号'));
   }
  }
 }
 // 调用 SDK 生成的正文 builder，核查常驻账号入口和检查按钮的渠道边界；不触发账号或网络操作。
 const {SoftwareUpdatePage:Settings}=load('pages/SoftwareUpdatePage.ts',true);
 for(const store of [false,true]){
  storeProduct=store;
  records.length=0;children.length=0;
  new Settings(undefined,{}).initialRender();
  children.find(item=>item.params.title==='软件更新').params.content();
  const accounts=children.filter(item=>item instanceof AccountPanel);
  assert.equal(accounts.length,store?0:1);
  if(!store)assert.equal(accounts[0].params.active,true);
  assert.equal(records.some(row=>row.name==='Button'&&row.property==='createWithLabel'&&row.args[0]==='检查更新'),!store);
 }
 // 设置打开和预览共用同一组件。通过页面 UIContext 绑定 Sheet，宿主缺席时不启动账号核验。
 const {DeveloperAccountPanel:Panel}=load('components/DeveloperAccountPanel.ts');
 const host={},calls=[];
 const model={initialize(context){assert.equal(context,host);calls.push('initialize');},
  activate(){calls.push('activate');},deactivate(){calls.push('deactivate');}};
 const panel=new Panel(undefined,{model});
 const pageContext={getHostContext:()=>undefined};
 panel.getUIContext=()=>pageContext;
 panel.aboutToAppear();assert.deepEqual(calls,[]);
 pageContext.getHostContext=()=>host;
 panel.aboutToAppear();
 records.length=0;panel.initialRender();
 const sheet=records.find(item=>item.property==='bindSheet');
 assert.equal(sheet.args[2].uiContext,pageContext);
 panel.aboutToDisappear();assert.deepEqual(calls,['initialize','activate','deactivate']);
 console.log('PASS real SDK output: discovery, progress actions, settings account entry, store policy, legacy JDK, route and compact-window render');
}
