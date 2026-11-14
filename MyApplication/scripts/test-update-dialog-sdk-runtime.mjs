/**
 * 执行SDK真实转换后的两个更新UI容器，捕获struct getter被转换器丢弃而宿主TS测试看不见的缺陷。
 * 只替代ArkUI绘制/属性容器边界；initialRender、分支和几何方法均使用SDK产物原文。
 * 这是SDK产物回归，不声称替代设备布局、登录或安装验收；缺少产物必须失败。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import compiler from './lib/ets-compiler.mjs';

const directory=process.argv[2];
if(!directory)throw Error('需要明确指定本轮SDK生成的三个UI容器文件目录');
const old=process.argv.includes('--expect-old-crash');
const records=[],children=[],storage=new Map();

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
 static create(child){children.push(child);}
}
/** 绘制接口只记录实际属性写入，事件回调不执行，不能从测试侧发起更新业务。 */
function widget(name){return new Proxy({}, {get(_target,property){return (...args)=>records.push({name,property,args});}});}
const enumeration=new Proxy({}, {get(_target,key){return String(key);}});
const globals={ViewPU:View,ObservedPropertySimplePU:Property,ObservedPropertyObjectPU:Property,
 SynchedPropertySimpleOneWayPU:Property,SynchedPropertyObjectOneWayPU:Property,
 SubscriberManager:{Get:()=>({delete(){}})},AppStorage:{get:key=>storage.get(key)},
 ViewStackProcessor:{AllocateNewElmetIdForNextComponent:()=>1,StartGetAccessRecordingFor(){},StopGetAccessRecording(){}},
 registerNamedRoute(){},loadDocument(){},$r:name=>name,console};
for(const name of ['Column','Row','Stack','Text','Button','Scroll','If','ForEach','Image','Blank','Divider','Checkbox','__Common__'])globals[name]=widget(name);
for(const name of ['BarState','HorizontalAlign','VerticalAlign','TextOverflow','FlexAlign','FontWeight','ButtonType','ImageFit','BorderStyle','TextAlign','FlexDirection','TextCase','Color'])globals[name]=enumeration;
const child=class{constructor(_parent,params){this.params=params;}};

/** 依赖按真实模块名显式映射；未知模块失败，避免静默空替身把新依赖错误吞掉。 */
function load(file,exportPage=false,layout){
 const source=fs.readFileSync(path.join(directory,file),'utf8')+(exportPage?'\nexport { SideloadUpdatePage };':'');
 const code=compiler.transpileModule(source,{compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
 const exports={};
 vm.runInNewContext(code,{...globals,exports,require(name){
  if(name.includes('UpdateDialogLayout'))return layout;
  if(name.includes('UpdateReminderPolicy'))return load('UpdateReminderPolicy.ts');
  if(name.includes('commons/'))return{AppIconName:enumeration,ThemeMode:{SYSTEM:0},resolveTheme:()=>({bgPrimary:'#fff'})};
  // 旧路由新增主题依赖；这里显式隔离平台配置/偏好端口，首帧测试不冒称主题生命周期验收。
  if(name==='@ohos:app.ability.ConfigurationConstant')return{default:{ColorMode:{COLOR_MODE_DARK:0}}};
  if(name.includes('feature_system/'))return{PreferenceManager:class{constructor(){throw Error('首帧夹具不得启动偏好IO');}}};
  if(name.includes('/AppTheme'))return{applyNativeTheme(){throw Error('首帧夹具不得切换平台主题');}};
  if(name.includes('update/'))return{noteTypeLabel:value=>value};
  if(name.includes('SemanticColors'))return{changelogTone:()=>({text:'text',background:'background'})};
  if(name.includes('SideloadUpdateContent'))return{SideloadUpdateContent:child};
  if(name.includes('AppIcon'))return{AppIcon:child};
  throw Error('未映射的SDK模块 '+name);
 }});
 return exports;
}
const layout=load('UpdateDialogLayout.ts');
const {UpdateDialog:Dialog}=load('UpdateDialog.ts',false,layout);
const {SideloadUpdatePage:Page}=load('SideloadUpdatePage.ts',true,layout);
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
 const reminder=load('UpdateReminderPolicy.ts');
 for(const app of [false,true])for(const required of [false,true]){
  records.length=0;let dismissGuard,exitGuard;
  const dialog=new Dialog(undefined,{theme:{},selfUpdateParams:app?{autoStart:true}:undefined,
   reminderLevel:required?reminder.UpdateReminderLevel.REQUIRED:reminder.UpdateReminderLevel.NORMAL,
   requiredNotice:{reason:'已有环境不兼容',consequence:'修复前无法继续此功能',exitLabel:'暂不使用'},
   items:app?[]:[{id:'17',title:'JDK17',current:'old',target:'new',sizeLabel:'1MB',description:'兼容修复'}],
   onDismissGuardReady:guard=>{dismissGuard=guard;},onExitGuardReady:guard=>{exitGuard=guard;}});
  dialog.aboutToAppear();dialog.initialRender();
  assert.equal(dismissGuard(),!required);assert.equal(exitGuard(),true,'页面生命周期退出不应被发现态强提醒锁死');
  assert.equal(records.some(row=>row.name==='Text'&&row.property==='create'&&row.args[0]==='必须处理'),required);
  assert(records.some(row=>row.name==='Button'&&row.property==='createWithLabel'&&row.args[0]===(required?'暂不使用':'稍后再说')),
   '两类提醒都应有明确的次操作，必需态不得仍用普通稍后文案');
 }
 records.length=0;new Page(undefined,{}).initialRender();
 assert(records.some(item=>item.property==='width'&&item.args[0]===320));
 storage.set('screenWidthVp',240);storage.set('screenHeightVp',300);
 records.length=0;new Dialog(undefined,params).initialRender();
 assert(records.find(item=>item.name==='Column'&&item.property==='width').args[0]<=240);
 assert(records.find(item=>item.name==='Column'&&item.property==='height').args[0]<=300);
 console.log('PASS real SDK output: app discovery/progress, legacy JDK, route and compact-window render without missing geometry');
}
