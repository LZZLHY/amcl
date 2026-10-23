/** 真实 Store→V2 分块→游戏懒仓库→journal→owner 合并，文件/设备边界沿既有夹具。 */
import assert from 'node:assert/strict';
import { fixture } from './lib/game-layout-fixture.mjs';
const f=fixture();
try {
  const model=f.owner.load('gamecontrol/src/main/ets/ControlLayout.ets');
  const look=f.owner.load('gamecontrol/src/main/ets/LookPreferences.ets');
  const profile=model.enableLayoutControlGroups(model.getDefaultLayout());
  Object.assign(profile,{name:'组方案',isPreset:false});
  profile.controlGroups.push({id:'tools',name:'工具',initialVisible:false});
  const button=profile.controls.find(c=>c.type===0&&!c.systemAction);
  Object.assign(button,{controlGroupId:'tools',keys:[],keyOrMouse:0,
    groupActions:[{phase:'press',operation:'hide',targets:['tools']}],
    phaseBindings:[{phase:'click',keys:[69],autoKeep:false}]});
  profile.requiredCapabilities.push('touch-phases-v1');
  profile.lookPolicies=look.splitLegacyLookPolicy({sensitivity:1,invertY:false,smoothing:.6,acceleration:0});
  const untouched=model.cloneLayoutWithFreshGroupIds(profile);untouched.name='未打开';
  f.ownerData.set('control_layout',new Map([['profiles',JSON.stringify([profile,untouched])],['active_profile','组方案']]));
  await f.launchV2();
  const loaded=f.child.store.getProfile('组方案');
  assert.equal(loaded.version,5);assert.deepEqual(loaded.controlGroups,profile.controlGroups);
  assert.equal(loaded.controls.find(c=>c.id===button.id).phaseBindings[0].phase,'click');
  loaded.controlGroups[1].name='游戏中修改';
  assert.equal(await f.child.store.saveProfile(loaded),true);
  const copied=await f.child.store.cloneAsUser('组方案');assert.ok(copied);
  const presetName=f.child.store.getPresetProfileNames()[0];
  const presetSource=f.child.store.getProfile(presetName);
  const presetDraft=model.enableLayoutControlGroups(presetSource);
  presetDraft.controlGroups.push({id:'extra',name:'最终草稿',initialVisible:false});
  const presetCopy=await f.child.store.saveEditedProfile(presetDraft);assert.ok(presetCopy);
  assert.notEqual(presetCopy.profileId,presetDraft.profileId);
  assert.notEqual(presetCopy.controlGroups[1].id,presetDraft.controlGroups[1].id);
  assert.notEqual(copied.controlGroups[1].id,'tools');
  const copiedButton=copied.controls.find(c=>c.groupActions?.length);
  assert.deepEqual(copiedButton.groupActions[0].targets,[copied.controlGroups[1].id]);
  assert.equal(f.child.store.beginEditorSession(),true);f.child.store.beginEditorTransaction();
  const cancelled=f.child.store.getProfile(copied.name);cancelled.controlGroups[1].name='不应保存';
  assert.equal(await f.child.store.saveProfile(cancelled),true);
  assert.equal(await f.child.store.restoreEditorTransaction(),true);f.child.store.endEditorSession();
  assert.equal(f.child.store.getProfile(copied.name).controlGroups[1].name,'游戏中修改');
  // 原子写失败不得换成半份引用图，失败前的完整组定义仍可读取。
  f.disk.control.failWrite=path=>String(path).includes('/pending.json.')&&String(path).endsWith('/content.pending');
  const bad=f.child.store.getProfile(copied.name);bad.controlGroups[1].name='失败修改';
  await assert.rejects(()=>f.child.store.saveProfile(bad),/保存失败|RollbackFailed/);
  assert.equal(f.child.store.getProfile(copied.name).controlGroups[1].name,'游戏中修改');
  f.disk.control.failWrite=undefined;f.state.lock=0;
  assert.equal((await f.owner.journal.importPending(f.disk.context)).imported,1);
  assert.equal(f.owner.store.getProfile('组方案').controlGroups[1].name,'游戏中修改');
  assert.deepEqual(f.owner.store.getProfile('未打开').controlGroups,untouched.controlGroups);
  const final=f.owner.store.getProfile(copied.name);assert.equal(final.version,5);assert.ok(final.lookPolicies);
  assert.equal(f.owner.store.getProfile(presetCopy.name).controlGroups[1].name,'最终草稿');
  assert.deepEqual(f.owner.store.getProfile(presetName).controlGroups,presetSource.controlGroups);
  assert.deepEqual(final.controls.find(c=>c.groupActions?.length).groupActions[0].targets,[final.controlGroups[1].id]);
  assert.equal(f.child.xmlOpens(),0);
  console.log('PASS v5 groups: real Store/V2/lazy repository/clone/cancel/write failure/owner merge and lookPolicies');
} finally {f.disk.close();}
