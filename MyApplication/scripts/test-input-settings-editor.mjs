/** 执行独立设置组件真实字段和非绘制方法；覆盖完整数据保留、失败及同实例重新进入。 */
import assert from 'node:assert/strict';
import { loadActionComponent, actionUiReceiver } from './lib/unified-actions-fixture.mjs';
import { environment } from './lib/ets-runtime-fixture.mjs';
const deferred=()=>{let resolve;const promise=new Promise(yes=>resolve=yes);return {promise,resolve};};

const sliderModes={Begin:0,Moving:1,End:2,Click:3};
const windowSize=environment().load('entry/src/main/ets/components/GameSettingsWindow.ets');

function fixture() {
  const gc={},store={leases:0,writes:0,restores:0,commits:0,profile:null,gate:null,fail:false};
  const env=environment({globals:{SliderChangeMode:sliderModes},imports:{gamecontrol:gc,'./KeyPickerSheet':{},'./AppIcon':{},'./TouchOptionsEditor':{}}});
  for(const name of ['GlfwKeys','ControlLayout','LookPreferences','TouchPreferences','TouchActionBindings','LayoutEditSession','ControlEditing'])
    Object.assign(gc,env.load('gamecontrol/src/main/ets/'+name+'.ets'));
  Object.assign(store,{
    async waitReady(){},beginEditorSession(){this.leases++;return true;},endEditorSession(){this.leases--;assert.ok(this.leases>=0);},
    getProfile(name){return name===this.profile.name?gc.cloneLayout(this.profile):null;},getActiveProfile(){return gc.cloneLayout(this.profile);},
    async saveEditedProfile(value){this.writes++;if(this.gate)await this.gate.promise;if(this.fail)throw Error('disk rejected');return gc.cloneLayout(value);},
    async restoreEditorTransaction(){this.restores++;if(this.restoreGate)await this.restoreGate.promise;return !this.rejectRestore;},commitEditorTransaction(){this.commits++;},
  });
  gc.getLayoutStore=()=>store;
  store.profile=gc.enableLayoutControlGroups(gc.getDefaultLayout());
  Object.assign(store.profile,{name:'完整方案',profileId:'settings-profile',profileRevision:3,isPreset:false});
  store.profile.touch={joystickAutoWalk:true,gestureMode:'combat',menuMode:'direct'};
  store.profile.controlGroups.push({id:'tools',name:'工具',initialVisible:false});
  const {InputSettingsEditor}=env.load('entry/src/main/ets/components/InputSettingsEditor.ets',true);
  const view=new InputSettingsEditor(),done=[];view.onDone=p=>done.push(p);view.onInitializationFailed=()=>{};
  return {view,store,gc,done};
}

{
  const {view,store}=fixture();await view.aboutToAppear();
  assert.equal(view.profileName,store.profile.name);assert.equal(view.dirty_(),false);assert.equal(store.writes,0);
  assert.ok(view.gamepadButtonOrder().includes('MODE'),'已保存的额外按钮必须可编辑');
  const map=structuredClone(view.gamepad.buttonMap);view.gamepad.buttonMap=undefined;
  assert.equal(view.gamepadButtonOrder().length,16,'缺省表只读列出常用目录，不创建空映射');
  assert.equal(view.gamepad.buttonMap,undefined);view.gamepad.buttonMap=map;
  const original=structuredClone(view.buildProfile());
  view.pushUndo();view.touch.menuSensitivity=1.8;
  const draft=view.buildProfile();assert.deepEqual(draft.controls,original.controls);assert.deepEqual(draft.controlGroups,original.controlGroups);
  assert.equal(draft.touch.joystickAutoWalk,true);assert.equal(draft.touch.gestureMode,'combat');assert.equal(draft.version,5);
  view.undo_();assert.equal(view.dirty_(),false);
  view.cancel_();await view.pending;assert.equal(store.writes,0);assert.equal(store.leases,0);
}
{
  const {view,store,done}=fixture();await view.aboutToAppear();view.touch.menuSensitivity=1.6;store.fail=true;
  view.run_(true);await view.pending;assert.equal(done.length,0);assert.equal(view.touch.menuSensitivity,1.6);
  assert.equal(view.busy,false);assert.equal(store.leases,1);assert.match(view.statusMsg,/disk rejected/);
  store.fail=false;view.run_(true);await view.pending;assert.equal(done.length,1);assert.equal(store.leases,0);
  assert.equal(done[0].touch.menuSensitivity,1.6);assert.equal(store.commits,1);
}
{
  const {view,store,done}=fixture();await view.aboutToAppear();store.gate=deferred();view.touch.menuSensitivity=2;
  view.run_(true);view.aboutToDisappear();const reopen=view.aboutToAppear();store.gate.resolve();await reopen;
  assert.equal(done.length,0);assert.equal(store.commits,0);assert.equal(store.restores,1);
  assert.equal(store.leases,1);assert.equal(view.touch.menuSensitivity,1);assert.equal(view.dirty_(),false);
  view.cancel_();await view.pending;assert.equal(store.leases,0);
}
{
  // 使用同一个真实选择器验证系统聊天的必备默认值；普通动作的空绑定语义不能跟着改变。
  const env=environment(),{KeyPickerSheet}=env.load('entry/src/main/ets/components/KeyPickerSheet.ets',true);
  const chat=new KeyPickerSheet(),picked=[];chat.requiredDefaultKey=84;chat.currentKeys=[];chat.onPick=keys=>picked.push(keys);
  chat.aboutToAppear();assert.deepEqual(chat.pickedKeys,[84]);
  chat.pickedKeys=[89];chat.clearPickedKeys();assert.deepEqual(chat.pickedKeys,[84]);
  chat.comboMode=true;chat.pickedKeys=[89];chat.toggleKey(89);assert.deepEqual(chat.pickedKeys,[84]);
  chat.pickedKeys=[];chat.confirmChoice();assert.deepEqual(picked,[[84]]);
  chat.pickedKeys=[341,89];chat.confirmChoice();assert.deepEqual(picked[1],[341,89]);
  const ordinary=new KeyPickerSheet(),ordinaryPicked=[];ordinary.onPick=keys=>ordinaryPicked.push(keys);
  ordinary.currentKeys=[89];ordinary.aboutToAppear();ordinary.clearPickedKeys();ordinary.confirmChoice();assert.deepEqual(ordinaryPicked,[[]]);
}
console.log('PASS actual input settings editor: complete hidden data, read-only cancel, save failure/retry, stale-save reentry and required chat key picker');

/** 使用真实目录 Builder、详情路由及事件闭包。组件边界只记录声明，不模拟系统像素或命中。 */
function settingsUi(view) {
  const ui=actionUiReceiver(), globals={...ui.globals};
  const iconName=new Proxy({},{get:(_,name)=>String(name)});
  Object.assign(globals,{Scroll:globals.Column, Divider:globals.Row, Color:{Transparent:'transparent'},
    CopyOptions:{LocalDevice:1}, BarState:{Auto:1}, type:globals.width, alignItems:globals.width});
  const shared={commons:{AppIconName:iconName},'./AppIcon':{AppIcon:globals.AppIcon}};
  const Directory=loadActionComponent('entry/src/main/ets/components/GameSettingsNavigation.ets','GameSettingsDirectory',{
    render:true,globals,dependencies:{...shared,'./TouchEditorTheme':{EditorPalette:class {}}}
  });
  const railParts=[];
  const Rail=loadActionComponent('entry/src/main/ets/components/GameSettingsNavigation.ets','GameSettingsRail',{
    methods:['build'],render:true,globals:{...globals,GameSettingsDirectory:props=>{
      railParts.push({props,afterScroll:ui.records.some(row=>row.modifiers.scrollBar)});
    }},dependencies:shared
  });
  const captures={rail:null,directory:null,body:'',title:''};
  const Shell=loadActionComponent('entry/src/main/ets/components/InputSettingsEditor.ets','InputSettingsEditor',{
    methods:['build','PageBody_','Header_'],render:true,globals,
    dependencies:{...shared,'./GameSettingsWindow':windowSize,'./TouchOptionsEditor':{TouchOptionsEditor:p=>{captures.body=p.section;}},
      './KeyPickerSheet':{},'./GameSettingsNavigation':{
        GameSettingsRail:p=>{captures.rail=p;},
        GameSettingsDirectory:p=>{captures.directory=p;captures.body='home';},
        gameSettingsTitle:id=>{captures.title=id;return id;},gameSettingsDetail:()=>''}}
  });
  Object.assign(view,{
    Header_:Shell.prototype.Header_,PageBody_:Shell.prototype.PageBody_,
    Actions_:()=>{},LookPage_:()=>{captures.body='look';},GamepadTabContent:()=>{captures.body='gamepad';},
    PolicyCard_:()=>{captures.body='policy';}
  });
  function draw() {
    ui.clear();Object.assign(captures,{rail:null,directory:null,body:'',title:''});
    Shell.prototype.build.call(view);
    return captures;
  }
  function directory() {
    ui.clear();railParts.length=0;
    if(captures.rail) {
      Rail.prototype.build.call(captures.rail);
      // 分类创建在滚动组件内部；其 scrollBar 修饰器完成后再创建固定游戏工具。
      assert.deepEqual(railParts.map(part=>part.afterScroll),captures.rail.includeGameTools?[false,true]:[false]);
      assert.equal(railParts[0].props.includeGameTools,false);
      if(captures.rail.includeGameTools) assert.equal(railParts[1].props.toolsOnly,true);
      for(const part of railParts) Object.assign(new Directory(),part.props).build();
    } else {
      assert.ok(captures.directory,'手机设置目录已经呈现');
      Object.assign(new Directory(),captures.directory).build();
    }
    return ui.records.filter(r=>r.modifiers.id);
  }
  function button(id) {
    const el=directory().find(r=>r.modifiers.id[0]===id);
    assert.ok(el,'真实设置目录缺少 '+id);return el.modifiers.onClick[0];
  }
  function confirm(label) {
    const el=ui.records.find(r=>r.type==='Button' && r.args[0]===label);
    assert.ok(el,'真实确认框缺少 '+label);return el.modifiers.onClick[0];
  }
  // 同时执行正常分辨率页的生产 build，读取两个真实外框标识节点的宽/高声明。
  const Resolution=loadActionComponent('entry/src/main/ets/components/GameResolutionPanel.ets','GameResolutionPanel',{
    methods:['build'],render:true,globals,dependencies:{
      './GameSettingsWindow':windowSize,'./GameSettingsNavigation':{GameSettingsRail(){}}
    }
  });
  function frame(resolution=false) {
    if(resolution) {
      ui.clear();
      Resolution.prototype.build.call({screenWidth:view.screenWidth,screenHeight:view.screenHeight,palette:view.palette,
        requiresRestart:()=>false,Content_:()=>{}});
    } else { draw(); }
    const rows=ui.records.filter(row=>row.modifiers.id?.[0]==='game-settings-sheet');
    assert.equal(rows.length,1,'仅有一个正常设置外框');
    const frame=rows[0];
    return [frame.modifiers.width?.[0]??frame.args[0],frame.modifiers.height[0]];
  }
  return {draw,directory,button,confirm,ui,frame};
}

{
  // 进游戏默认视角；同一手机目录放大自动进入视角，缩回目录后继续读原草稿。
  const {view,store}=fixture();view.inGameSettings=true;view.screenWidth=840;view.screenHeight=390;
  await view.aboutToAppear();const ui=settingsUi(view);
  assert.equal(ui.draw().body,'home');
  assert.deepEqual(ui.directory().map(e=>e.modifiers.id[0]),[
    'game-settings-nav-look','game-settings-nav-move','game-settings-nav-menu','game-settings-nav-gesture',
    'game-settings-nav-gyro','game-settings-nav-gamepad','game-settings-nav-policy','game-settings-nav-layout']);
  view.allowLiveResolution=true;ui.draw();assert.ok(ui.button('open-game-resolution'));
  ui.button('game-settings-nav-move')();assert.equal(ui.draw().body,'move');
  view.adjustJoystickDeadZone_(0.24,sliderModes.Click);assert.ok(view.dirty_());
  // 手机返回按钮绑定的是目录，不能结束、保存或丢弃当前草稿。
  ui.ui.records.find(r=>r.modifiers.accessibilityText?.[0]==='返回设置目录').modifiers.onClick[0]();
  assert.equal(ui.draw().body,'home');assert.ok(ui.draw().directory.summaries.some(s=>s.includes('24%')));
  view.screenWidth=1180;view.screenHeight=720;
  const wide=ui.draw();assert.deepEqual([wide.rail.selected,wide.body,wide.title],['look','look','look']);
  assert.equal(wide.rail.profileName,store.profile.name);
  ui.button('game-settings-nav-menu')();assert.deepEqual([ui.draw().rail.selected,ui.draw().body],['menu','menu']);
  assert.equal(view.joystickDeadZone,.24);assert.equal(store.writes,0);
  // 手动选中分类在窗口缩小时继续显示；回目录再放大仍选择默认视角。
  view.screenHeight=390;assert.equal(ui.draw().body,'menu');
  ui.ui.records.find(r=>r.modifiers.accessibilityText?.[0]==='返回设置目录').modifiers.onClick[0]();
  assert.equal(ui.draw().body,'home');assert.equal(view.buildProfile().profileId,store.profile.profileId);
  view.cancel_();ui.draw();ui.confirm('放弃修改')();await view.pending;assert.equal(store.leases,0);
  const launcher=fixture();launcher.view.screenWidth=1200;launcher.view.screenHeight=720;
  launcher.view.allowLiveResolution=true;await launcher.view.aboutToAppear();const standalone=settingsUi(launcher.view);
  assert.equal(standalone.draw().body,'policy');
  assert.ok(standalone.directory().every(row=>!['open-game-resolution','game-settings-nav-layout'].includes(row.modifiers.id[0])));
  launcher.view.cancel_();await launcher.view.pending;
}

{
  // 工具取消、恢复失败、确认后转交事务均通过真正的按钮回调发起。
  const {view,store,done}=fixture();view.inGameSettings=true;view.allowLiveResolution=true;view.screenWidth=1200;view.screenHeight=750;
  const opened=[];view.onOpenGameTool=tool=>opened.push({tool,leases:store.leases,commits:store.commits});
  await view.aboutToAppear();const ui=settingsUi(view);
  assert.deepEqual([ui.draw().rail.selected,ui.draw().body],['look','look']);
  view.setHaptic_(false);ui.draw();ui.button('open-game-resolution')();
  assert.ok(view.leaveConfirm);assert.equal(store.restores,0);
  ui.draw();ui.confirm('继续编辑')();assert.equal(view.dirty_(),true);assert.equal(view.pendingGameTool_,'');
  ui.draw();ui.button('game-settings-nav-move')();assert.equal(ui.draw().body,'move');assert.equal(view.haptic,false);
  store.rejectRestore=true;ui.draw();ui.button('game-settings-nav-layout')();ui.draw();ui.confirm('放弃修改')();
  await view.pending;assert.deepEqual(opened,[]);assert.equal(store.leases,1);assert.equal(view.haptic,false);
  assert.match(view.statusMsg,/恢复未确认/);assert.equal(view.completed,false);
  store.rejectRestore=false;ui.draw();ui.button('open-game-resolution')();ui.draw();ui.confirm('放弃修改')();
  await view.pending;assert.deepEqual(opened,[{tool:'resolution',leases:0,commits:1}]);
  assert.deepEqual(done,[]);assert.equal(store.writes,0);
}

{
  // 校验点击之后销毁，迟到的旧事务结果不得驱动新宿主导航。
  const {view,store,done}=fixture();view.inGameSettings=true;view.allowLiveResolution=true;
  const opened=[];view.onOpenGameTool=id=>opened.push(id);await view.aboutToAppear();
  const ui=settingsUi(view);ui.draw();store.restoreGate=deferred();ui.button('game-settings-nav-layout')();
  assert.ok(view.busy);view.aboutToDisappear();store.restoreGate.resolve();await view.cleanupTask;
  assert.deepEqual(opened,[]);assert.deepEqual(done,[]);assert.equal(store.leases,0);
  // 没有相应产品能力，即使迟到的入口被投递，宿主也不能切入分辨率。
  const blocked=fixture();blocked.view.inGameSettings=true;await blocked.view.aboutToAppear();
  blocked.view.openDestination_('resolution');assert.equal(blocked.store.restores,0);
  blocked.view.cancel_();await blocked.view.pending;
}
console.log('PASS real settings directory and callbacks, capability gate, window changes, source-preserving drafts, confirmed handoff and destroyed/failed tool navigation');

{
  // 桌面面积、断点边界、超大尺寸和长横屏手机均由同一对生产外框产生尺寸。
  const {view}=fixture();view.inGameSettings=true;await view.aboutToAppear();
  const ui=settingsUi(view);
  for(const [width,height,expected] of [[1280,800,[973,560]],[900,480,[828,424]],
    [1600,1000,[1024,640]],[899,600,[883,588]],[1080,390,[1064,378]],[320,180,[304,168]]]) {
    view.screenWidth=width;view.screenHeight=height;
    assert.deepEqual(ui.frame(),expected);
    assert.deepEqual(ui.frame(true),expected);
  }
  view.cancel_();await view.pending;
}
console.log('PASS real settings and resolution frames share compact tablet dimensions and phone margins');
