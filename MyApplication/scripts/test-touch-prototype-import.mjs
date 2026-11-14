/** 真实HTML边车转换、颜色运算与Store/V2保存链；不执行网页代码，不替换转换或持久化算法。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { fixture as storageFixture } from './lib/game-layout-fixture.mjs';
const load=makePureEtsLoader(),model=load('gamecontrol/src/main/ets/ControlLayout.ets');
const importer=load('gamecontrol/src/main/ets/ExternalLayoutImporter.ets');
const secondary=load('gamecontrol/src/main/ets/SecondaryControlGroups.ets');
const color=load('gamecontrol/src/main/ets/ControlAppearance.ets');

const old=model.enableLayoutControlGroups(model.getDefaultLayout());old.name='HTML当前方案';old.isPreset=false;
old.controlGroups.push({id:'proto_fkeys',name:'F类键',initialVisible:false});
const member=old.controls.find(c=>c.keyOrMouse===292),opener=old.controls.find(c=>c.keyOrMouse===69&&c.systemAction===undefined);
member.controlGroupId='proto_fkeys';member.style={bg:'#00123456',fg:'#DDAABBCC',opacity:.6,borderWidth:undefined};
const back=model.cloneItemWithFreshIds(member,old.controls);Object.assign(back,{label:'返回一级',keyOrMouse:0,keys:[],groupActions:[{phase:'press',operation:'hide',targets:['proto_fkeys']}]});old.controls.push(back);
const proto={format:'amcl-ui-prototype',version:3,pack:{format:'array',root:null,profiles:[model.getDefaultLayout(),old],active:1,
  appearanceExtras:{1:{[member.id]:{borderWidth:0,borderColor:'#FF123456'}}},
  secondaryLayers:{1:{proto_fkeys:{openerId:opener.id,returnId:back.id,hidePrimary:true}}}}};
const original=JSON.stringify(proto),review=importer.analyzeExternalLayout(original,'导入测试');
assert.ok(review.profile,review.reason);assert.equal(review.profile.name,old.name);assert.equal(review.profile.version,6);
assert.ok(review.warnings.some(s=>s.includes('2个方案')&&s.includes('当前选中')));
assert.equal(JSON.stringify(proto),original);assert.equal(review.profile.controls.find(c=>c.id===member.id).style.borderWidth,0);
assert.equal(review.profile.controls.find(c=>c.id===member.id).style.bg,'#00123456');
assert.equal(review.profile.controls.find(c=>c.id===opener.id).secondaryAction.kind,'toggle');
assert.equal(review.profile.controls.find(c=>c.id===back.id).secondaryAction.kind,'return');
assert.deepEqual(review.profile.controls.find(c=>c.id===back.id).groupActions,[]);
for(const mutate of [
 p=>p.pack.active=99,
 p=>p.pack.secondaryLayers[1].proto_fkeys.openerId='missing',
 p=>p.pack.appearanceExtras[1][member.id].borderWidth=13,
 p=>p.pack.secondaryLayers[1].proto_fkeys.returnId=opener.id,
 p=>p.version=1,
 p=>p.pack.secondaryLayers[1].proto_fkeys.hidePrimary='false'
]){const bad=structuredClone(proto);mutate(bad);assert.equal(importer.analyzeExternalLayout(JSON.stringify(bad),'坏输入').profile,null);}
const optional=structuredClone(proto);optional.pack.secondaryLayers[1].proto_fkeys.returnId=null;
optional.pack.profiles[1].controls=optional.pack.profiles[1].controls.filter(c=>c.id!==back.id);
assert.ok(importer.analyzeExternalLayout(JSON.stringify(optional),'可选返回').profile);
const legacy=structuredClone(proto);legacy.version=2;assert.ok(importer.analyzeExternalLayout(JSON.stringify(legacy),'旧原型').profile);
assert.equal(color.controlColorWithAlpha('#80123456',0),'#00123456');
assert.equal(color.controlColorWithRgb('#00123456','#ABCDEF','#30FFFFFF'),'#00ABCDEF');
assert.equal(color.controlColorWithRgb('#DDAABBCC','#123456','#DDFFFFFF'),'#DD123456');
for(const rgb of ['#FFFFFF','#000000','#EF5350','#0088FF','#123456','#F8E421']){
  const parsed=color.controlColorParts(rgb),hsv=color.controlRgbToHsv(parsed),roundtrip=color.controlHsvToRgb(hsv.hue,hsv.saturation,hsv.value);
  assert.equal(color.controlRgbHex(roundtrip),rgb);
}
console.log('PASS actual prototype import: current-profile selection, v2/v3 layers, optional return, alpha/border preservation, strict all-or-nothing and HSV roundtrip');

if(process.env.AMCL_TOUCH_PROTOTYPE_SAMPLE){
  const sample=fs.readFileSync(process.env.AMCL_TOUCH_PROTOTYPE_SAMPLE,'utf8');
  const actual=importer.analyzeExternalLayout(sample,'实际HTML原型');assert.ok(actual.profile,actual.reason);
  assert.ok(model.validateAndNormalizeLayout(actual.profile));console.log('PASS actual HTML exported prototype file through production importer');
}

const f=storageFixture();
try {
  const profile=review.profile;profile.name='原生二级持久化';profile.isPreset=false;
  f.ownerData.set('control_layout',new Map([['profiles',JSON.stringify([profile])],['active_profile',profile.name]]));
  await f.launchV2();const store=f.child.store;
  let current=store.getProfile(profile.name);assert.ok(current);
  const currentOpener=secondary.secondaryGroupOpener(current,'proto_fkeys');assert.ok(currentOpener);
  const edited=model.cloneLayout(current);edited.controls.find(c=>c.id===member.id).style.borderWidth=2;
  const saved=await store.saveEditedProfile(edited);assert.ok(saved);store.commitEditorTransaction();
  current=store.getProfile(saved.name);assert.equal(current.controls.find(c=>c.id===member.id).style.borderWidth,2);
  const removed=model.removeLayoutControlGroup(current,'proto_fkeys',current.defaultControlGroupId);assert.ok(removed);
  const after=await store.saveEditedProfile(removed);assert.ok(after);store.commitEditorTransaction();
  const reopened=store.getProfile(after.name);
  assert.equal(reopened.controls.some(c=>c.id===currentOpener.id||c.id===back.id),false);
  assert.equal(reopened.controls.find(c=>c.id===member.id).controlGroupId,reopened.defaultControlGroupId);
  assert.equal(reopened.controls.find(c=>c.id===member.id).style.borderWidth,2);
  f.state.lock=0;const merged=await f.owner.journal.importPending(f.disk.context);assert.equal(merged.imported,1,JSON.stringify(merged));
  const owner=f.owner.store.getProfile(profile.name);
  assert.equal(owner.controls.some(c=>c.id===opener.id),false);assert.equal(owner.controls.find(c=>c.id===member.id).style.bg,'#00123456');
  console.log('PASS actual Store/V2/owner merge: v6 layers and border survive save, deleting group does not resurrect opener on reopen');
} finally { f.disk.close(); }
