/** 执行独立设置组件真实字段和非绘制方法；覆盖完整数据保留、失败及同实例重新进入。 */
import assert from 'node:assert/strict';
import { environment } from './lib/ets-runtime-fixture.mjs';
const deferred=()=>{let resolve;const promise=new Promise(yes=>resolve=yes);return {promise,resolve};};

function fixture() {
  const gc={},store={leases:0,writes:0,restores:0,commits:0,profile:null,gate:null,fail:false};
  const env=environment({imports:{gamecontrol:gc,'./KeyPickerSheet':{},'./AppIcon':{},'./TouchOptionsEditor':{}}});
  for(const name of ['GlfwKeys','ControlLayout','LookPreferences','TouchPreferences','TouchActionBindings','LayoutEditSession'])
    Object.assign(gc,env.load('gamecontrol/src/main/ets/'+name+'.ets'));
  Object.assign(store,{
    async waitReady(){},beginEditorSession(){this.leases++;return true;},endEditorSession(){this.leases--;assert.ok(this.leases>=0);},
    getProfile(name){return name===this.profile.name?gc.cloneLayout(this.profile):null;},getActiveProfile(){return gc.cloneLayout(this.profile);},
    async saveEditedProfile(value){this.writes++;if(this.gate)await this.gate.promise;if(this.fail)throw Error('disk rejected');return gc.cloneLayout(value);},
    async restoreEditorTransaction(){this.restores++;return true;},commitEditorTransaction(){this.commits++;},
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
console.log('PASS actual input settings editor: complete hidden data, read-only cancel, save failure/retry and stale-save reentry');
