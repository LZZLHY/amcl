/** 直接调用正式 Skill 路由，观察真实账户表单和布局编辑方法，替换平台、持久化与渲染边界。 */
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { environment } from './lib/ets-runtime-fixture.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { loadActionComponent } from './lib/unified-actions-fixture.mjs';

const types={OFFLINE:'legacy',MICROSOFT:'msa',AUTHLIB_INJECTOR:'authlib'};
function player(id,type){
  return {id,type,uuid:'private-uuid',username:'private-name',secret:'token',getDisplayName:()=> 'private-name',
    getSkinUrl:()=>'',getSkinVariant:()=>'',getCapeUrl:()=>'',getCapeAlias:()=>'',isUsable:async()=>true};
}
const players = [player('first',types.MICROSOFT)];
let selected='first',saves=0;
const manager={isReady:()=>true,list:()=>players.slice(),getSelectedId:()=>selected,
  findById:id=>players.find(a=>a.id===id),getAvailableSelection:()=>players.find(a=>a.id===selected),
  add:async a=>{players.push(a);saves++;},select:async (id,expected)=>{if(expected)assert.equal(manager.findById(id),expected);selected=id;}};
const env=environment({imports:{account:{getAccountManager:()=>manager,AccountType:types,OfflineAccount:{create:()=>player('added',types.OFFLINE)}},
  feature_core:{reserveTaskActivityId:()=>1,ActivityCategory:{ACCOUNT:'account'},ActivityStatus:{SUCCESS:'success',FAILED:'failed',ABORTED:'abort'},
    getTaskActivityOwner:()=>({recordSummary(){}})},'@kit.ArkWeb':{webview:{WebviewController:class{}}}},
  commons:{DeviceForm:{PHONE:'phone'},Breakpoint:{SM:'sm'},SKIN_SERVER_PRESETS:[]},globals:{AppStorage:{get:()=>true},setTimeout,clearTimeout}});
const bus=env.load('entry/src/main/ets/launcherskill/LauncherSkillBus.ets').LauncherSkillBus;
const Accounts=env.load('entry/src/main/ets/components/AccountListSheet.ets',true).AccountListSheet;
const Form=env.load('entry/src/main/ets/components/AddAccountSheet.ets',true).AddAccountSheet;
const host={};bus.attach(host,()=>true);const page=new Accounts();let pendingForm;
page.onAccountsChanged=()=>{};page.onClose=()=>page.aboutToDisappear();page.aboutToAppear();
const call=(method,args={})=>bus.call('accounts',method,args);
let inventory=await call('listPlayerAccounts');assert.equal(inventory.state,'ready');assert.equal(inventory.accounts.length,1);
assert(!/private|first|token/.test(JSON.stringify(inventory)));
const old=inventory.accounts[0].accountRef;
assert.equal((await call('checkPlayerAccount',{accountRef:old})).credential,'local');
async function mountForm() {
  while (!page.showAddSheet) await new Promise(resolve=>setImmediate(resolve));
  pendingForm=new Form();pendingForm.onPlayerLoginOutcome=(...args)=>page.loginOutcome_(...args);
  const close=()=>{pendingForm.aboutToDisappear();page.showAddSheet=false;};
  pendingForm.onClose=close;pendingForm.onSuccess=()=>{page.refresh();close();};pendingForm.aboutToAppear();
}
const savedSelection = selected;
selected = '';
assert.equal((await call('listPlayerAccounts', {})).accounts.some(item => item.selected), false);
selected = savedSelection;
const adding=call('addOfflinePlayer',{playerName:'TestPlayer'});await mountForm();const added=await adding;
assert.equal(added.state,'ready');assert(added.accountRef);assert.equal(selected,'added');assert.equal(saves,1);
assert.equal((await call('readPlayerLogin',{loginRef:added.loginRef})).accountRef,added.accountRef);
assert.equal((await call('addOfflinePlayer',{playerName:'超过输入长度的玩家名字'.repeat(2)})).state,'failed');assert.equal(saves,1);
const login=call('beginPlayerLogin',{provider:'authlib'});await mountForm();const handoff=await login;
assert.equal(handoff.state,'needsUser');assert.equal(pendingForm.mode,3);
pendingForm.requestAccountClose_();assert.equal((await call('readPlayerLogin',{loginRef:handoff.loginRef})).state,'cancelled');
players[0]=player('first',types.MICROSOFT);
assert.equal((await call('selectPlayerAccount',{accountRef:old})).reason,'staleAccount');
bus.detach(host);
console.log('PASS official account dispatch, real offline form and readback, login handoff/cancel, no credentials or stale same-ID selection');

const pure=makePureEtsLoader({'@kit.ArkTS':{util:{generateRandomUUID:randomUUID}}});
const draftModule=pure('entry/src/main/ets/launcherskill/LayoutDraftAccess.ets');
const model=pure('gamecontrol/src/main/ets/ControlLayout.ets');
const groups=pure('gamecontrol/src/main/ets/ControlGroups.ets');
const keys=pure('gamecontrol/src/main/ets/GlfwKeys.ets');
const editing=pure('gamecontrol/src/main/ets/ControlEditing.ets');
const controlsModule={...model,...groups,...keys,...editing};
const editorFile='entry/src/main/ets/components/LayoutEditor.ets';
const Shape=loadActionComponent(editorFile,'LayoutEditor',{methods:['skillWorkbench_','readWorkbench_','changedWorkbench_','applyPositionDraft_','syncPositionDraft_',
  'itemPxX','itemPxY','itemW','itemH','selectedItem','skillKeys_','skillStyle_','skillBinding_','chooseScene_','skillBatch_','commitGroupDrag',
  'setMultiSelect','clearSelection','selectControlIdentity_','skillGroup_','chooseControlGroup_'],
  globals:{SliderChangeMode:{Click:3},MAX_LAYOUT_CONTROL_KEYS:8},dependencies:{gamecontrol:controlsModule,
  '../launcherskill/LauncherSkillBus':{LauncherSkillBus:bus},
  '../launcherskill/LayoutDraftAccess':draftModule}});
const shape=new Shape();shape.playerDraft_=new draftModule.LayoutDraftAccess();shape.playerDraft_.open();
const button={id:'a',type:model.ControlType.BUTTON,label:'A',keyCode:65,xPct:.2,yPct:.25,baseWidth:40,baseHeight:40,itemScale:1};
Object.assign(shape,{launcherWorkbench:true,editorReady:true,editorMounted:true,editorClosed:false,groupDragging:false,dragIdx:-1,
  controls:[button],controlGroups:[],screenWidth:400,screenHeight:200,globalScale:1,globalOpacity:1,profileName:'P',
  picked:'',labelDraft:'A',selectedIdx:0,selectedChildId:'',currentControlGroup:'',multiSelectMode:false,selectedIds:[],ver:0,pushUndo(){this.undos++;},
  undos:0,refreshControls(){},loadStatus:'',contentSignature(){return JSON.stringify(this.controls);},
  selectControlIdentity_(id){this.selectedIdx=this.controls.findIndex(x=>x.id===id);}});
let initial=await shape.skillWorkbench_('readControlWorkbench',{});assert.equal(initial.items[0].id,'a');
const identity=s=>({draftRef:s.draftRef,draftRevision:s.draftRevision});
const edit={...identity(initial),controlId:'a',x:160,y:40,width:88,height:50};
let resized=await shape.skillWorkbench_('setWorkbenchGeometry',edit);
assert.equal(resized.state,'draft');assert.equal(resized.items[0].width,88);assert.equal(button.xPct,.4);assert.equal(shape.undos,1);
assert.equal((await shape.skillWorkbench_('setWorkbenchGeometry',edit)).reason,'draftChanged');
button.label='human';assert.equal((await shape.skillWorkbench_('setWorkbenchGeometry',{...edit,...identity(resized)})).reason,'draftChanged');
shape.launcherWorkbench=false;assert.equal((await shape.skillWorkbench_('readControlWorkbench',{})).state,'busy');
assert.equal(draftModule.layoutList('a,a',5),undefined);
console.log('PASS real workbench geometry, proportional storage, one undo, stale/user-changed revisions, game workbench excluded');

const touch={...pure('gamecontrol/src/main/ets/TouchPreferences.ets'),...pure('gamecontrol/src/main/ets/TouchActionBindings.ets')};
const touchHelpers=makePureEtsLoader({gamecontrol:{...controlsModule,...touch}})('entry/src/main/ets/runtime/TouchOptionDraft.ets');
const value=new touch.TouchConfiguration();
const altered=touchHelpers.touchChoiceDraft(value,'menu','direct');assert.equal(altered.menuMode,'direct');
const reset=touchHelpers.touchBindingDraft(value,0,false);assert(!Object.hasOwn(reset.actionOverrides,touch.TOUCH_ACTION_NAMES[0]));
const unbound=touchHelpers.touchBindingDraft(value,0,true);assert.equal(unbound.actionOverrides[touch.TOUCH_ACTION_NAMES[0]],0);
assert.equal(touchHelpers.touchNumberDraft(value,'bogus',9),undefined);
console.log('PASS shared touch option transforms, identity of reset versus explicit unbinding and unsupported fields');

// 实际系统文件选择与兼容确认被平台替身驱动；核实原 review 的提交次数、取消和滞后的页面替换。
let chooseFiles=[],answer=1,commits=0;
const docpicker={DocumentSelectOptions:class{},DocumentViewPicker:class{async select(){return chooseFiles;}}};
const catalogStore={getProfileNames:()=>[],getActiveProfile:()=>({name:'Default'}),getLoadIssues:()=>({}),
  async analyzeImportFile(uri){assert.equal(uri,'granted');return {ok:true,legacy:true,sourceVersion:3,format:'amcl',name:'Binding',controlCount:2,reviewId:'original'};},
  async commitReviewedImport(id){assert.equal(id,'original');commits++;return {name:'Binding',profileId:'imported',profileRevision:1};}};
const Catalog=loadActionComponent('entry/src/main/ets/pages/LayoutListPage.ets','LayoutListPage',{methods:['catalogSkill_','doImport','analyzeAndImport','commitImport'],
  dependencies:{'entry/ProductInputProfile':{ProductInputProfile:{supportsTouchLayouts:()=>true}},'@kit.CoreFileKit':{picker:docpicker},
    '../launcherskill/LayoutDraftAccess':draftModule,'../launcherskill/LauncherSkillBus':{LauncherSkillBus:bus}}});
const catalog=new Catalog();Object.assign(catalog,{importPageMounted:true,importPageGeneration:1,store:catalogStore,
  getAbilityContext:()=>({}),refreshList(){},titleTheme:{actionText:'#000'},
  getUIContext:()=>({getPromptAction:()=>({showDialog:async()=>({index:answer})})})});
assert.equal((await catalog.catalogSkill_('importControlLayout',{})).state,'cancelled');assert.equal(commits,0);
chooseFiles=['granted'];answer=0;
assert.equal((await catalog.catalogSkill_('importControlLayout',{})).state,'cancelled');assert.equal(commits,0);
answer=1;assert.equal((await catalog.catalogSkill_('importControlLayout',{})).id,'imported');assert.equal(commits,1);
assert.equal(catalog.lastImport_.revision,1);
catalog.getUIContext=()=>({getPromptAction:()=>({showDialog:async()=>{catalog.importPageGeneration++;return {index:1};}})});
assert.equal((await catalog.catalogSkill_('importControlLayout',{})).state,'unknown');assert.equal(commits,1);
console.log('PASS layout import from picker, cancellation, compatibility consent, late owner and durable named result');

const Input=loadActionComponent('entry/src/main/ets/components/InputSettingsEditor.ets','InputSettingsEditor',{methods:['playerTouchOption_','playerLookOption_','playerGamepadOption_',
  'playerInputAction_','setIndependentLook','editorLookParameters','selectLookSource','updateEditorLook','setLookNumber_','setGamepadNumber_',
  'setGamepadAction_','ensureButtonMap','setStickRole_','setGamepadEnabled_','applyTouchChange','setHaptic_','setLookInversion_'],
  globals:{SliderChangeMode:{Click:3}},
  dependencies:{gamecontrol:{...controlsModule,...touch,...pure('gamecontrol/src/main/ets/LookPreferences.ets')},
    '../launcherskill/LauncherSkillBus':{LauncherSkillBus:bus},
    '../runtime/TouchOptionDraft':touchHelpers}});
const input=new Input();
Object.assign(input,{launcherWorkbench:true,mounted:true,leaseHeld:true,busy:false,leaveConfirm:false,touchBindingEditIndex:-1,gamepadBtnPicker:'',
  touch:new touch.TouchConfiguration(),gamepad:{enabled:true},selectedLookSource:'touch',lookSensitivity:1,invertY:false,lookSmoothing:.6,lookAccel:0,
  playerInput_:new draftModule.LayoutDraftAccess(),pushUndo(){this.undoCount++;},undoCount:0,
  prepareSliderChange(_k,_mode,changed){if(changed)this.pushUndo();return changed;},cloneGamepad:structuredClone,
  buildProfile(){return {touch:this.touch,gamepad:this.gamepad,look:this.editorLookParameters()};},
  inputSnapshot_(){return {state:'draft',...this.playerInput_.snapshot(JSON.stringify(this.buildProfile()))};}});
input.playerInput_.open();
const inputCall=async(name,data)=>input.playerInputAction_(name,{...identity(input.inputSnapshot_()),...data});
assert.equal((await inputCall('setTouchOption',{field:'sprintThreshold',value:'110'})).state,'draft');assert.equal(input.touch.joystickSprintThreshold,1.1);
assert.equal((await inputCall('setTouchOption',{field:'sprintThreshold',value:'151'})).state,'failed');assert.equal(input.touch.joystickSprintThreshold,1.1);
assert.equal((await inputCall('setLookOption',{field:'sensitivity',source:'physical',value:'150'})).state,'draft');assert.equal(input.lookSensitivity,1.5);
assert.equal((await inputCall('setGamepadOption',{field:'right',value:'none'})).state,'draft');assert.equal(input.gamepad.rightStick,'none');
assert.equal((await inputCall('setGamepadOption',{field:'enabled',value:'false'})).state,'draft');assert.equal(input.gamepad.enabled,false);
console.log('PASS launcher-only input draft uses the touch/aim/gamepad product mutations and rejects outside ranges');
