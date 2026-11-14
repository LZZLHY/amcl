/** 复用真实字段和方法走原生面板主流程；不伪造创建、删除、导航或颜色修改的实现。 */
import assert from 'node:assert/strict';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { compactEditorFixture } from './lib/compact-editor-fixture.mjs';
const load=makePureEtsLoader(),model=load('gamecontrol/src/main/ets/ControlLayout.ets');
const profile=model.getDefaultLayout();profile.name='原生面板回归';profile.isPreset=false;
const {view:v,modes}=compactEditorFixture(profile);
v.switchMainPanel_(true);v.openTab('secondary-new');v.secondaryNameDraft='F类键';v.createSecondary_();
assert.equal(v.activeSheet,'add');assert.equal(v.buildProfile().version,6);
const gid=v.secondaryEditingGroup,opener=v.currentSecondaryOpener_().id;
assert.equal(v.secondaryMembers_().length,0);assert.equal(v.currentSecondaryReturn_(),undefined);
v.addControlFromPanel_('button');assert.equal(v.secondaryMembers_().length,0);
const old=v.inlinePickerCallback_();v.finishInlineKeyPicker_(null);assert.equal(v.secondaryMembers_().length,0);
v.addControlFromPanel_('button');old([293]);assert.equal(v.secondaryMembers_().length,0,'旧选择器不能提交后来会话');
v.inlinePickerCallback_()([292]);const f3=v.selectedItem().id;
assert.equal(v.selectedItem().controlGroupId,gid);assert.equal(v.activeSheet,'edit');
v.backEditor_();assert.equal(v.activeSheet,'secondary-group');
v.openAddPanel_();v.addControlFromPanel_('f4');assert.equal(v.secondaryMembers_().length,2);
v.backEditor_();assert.equal(v.activeSheet,'secondary-group');v.addSecondaryReturn_();
const back=v.selectedItem().id;assert.equal(v.currentSecondaryReturn_().id,back);
const count=v.controls.length;v.addSecondaryReturn_();assert.equal(v.controls.length,count);
v.selectControlIdentity_(f3);v.openTab('more');v.openTab('style');
const initialStyle={...v.selectedItem().style};v.selectedItem().style.bgPressed='#80123456';
v.applyBorderWidth_(2,modes.Click);v.applyBackgroundOpacity_(0,modes.Click);
assert.equal(v.selectedItem().style.bg,'#00FFFFFF');assert.equal(v.selectedItem().style.bgPressed,'#00123456');
assert.equal(v.selectedItem().style.opacity,initialStyle.opacity);assert.equal(v.selectedItem().style.fg,initialStyle.fg);
v.colorField='fg';v.applyAppearanceRgb_('#FF0000',modes.Click);assert.equal(v.selectedItem().style.fg,'#DDFF0000');
v.colorField='borderColor';v.applyAppearanceRgb_('#0088FF',modes.Click);assert.equal(v.selectedItem().style.borderColor,'#DD0088FF');
v.applyBorderWidth_(0,modes.Click);assert.equal(v.selectedItem().style.borderWidth,0);
const styled=JSON.stringify(v.buildProfile());v.backEditor_();assert.equal(v.activeSheet,'more');v.backEditor_();assert.equal(v.activeSheet,'edit');
assert.equal(JSON.stringify(v.buildProfile()),styled);
v.openSecondaryEditor_(gid);v.toggleSecondaryHide_();assert.equal(v.editorGroupVisible_(v.controls.find(c=>c.id===opener)),true);
assert.equal(v.editorGroupVisible_(v.controls.find(c=>c.systemAction==='edit')),false);
v.removeControls_([back]);assert.equal(v.currentSecondaryReturn_(),undefined);assert.notEqual(v.activeSheet,'confirm-delete');
assert.ok(v.buildProfile(),'隐藏其他一级也不要求返回键');
v.selectControlIdentity_(opener);const before=JSON.stringify(v.buildProfile());v.removeControls_([opener]);
assert.equal(v.activeSheet,'confirm-delete');assert.equal(JSON.stringify(v.buildProfile()),before);
assert.ok(v.pendingDeletionSummary_().includes('全部按键'));assert.equal(v.pendingDeletionTitle_(),'删除展开键？');
v.backEditor_();assert.equal(JSON.stringify(v.buildProfile()),before);
v.removeControls_([opener]);v.selectForEditor_(v.controls.findIndex(c=>c.id===f3));v.backEditor_();
assert.notEqual(v.activeSheet,'confirm-delete','画布切换选择应取消旧确认，返回不能重开失效删除范围');
assert.equal(JSON.stringify(v.buildProfile()),before);
v.removeControls_([opener]);v.confirmControlRemoval_();
assert.equal(v.controls.some(c=>c.id===opener||c.id===f3),false);assert.equal(v.controlGroups.some(g=>g.id===gid),false);
v.undo();assert.equal(JSON.stringify(v.buildProfile()),before);
v.openSecondaryEditor_(gid);v.beginSecondaryDeletion_();v.deleteControlGroup_(true);
assert.equal(v.controls.some(c=>c.id===opener),false);assert.equal(v.controls.find(c=>c.id===f3).controlGroupId,v.defaultControlGroupId);
const after=model.cloneLayout(v.buildProfile());v.loadProfile(after);assert.equal(v.controls.some(c=>c.id===opener),false);
v.screenWidth=720;v.screenHeight=320;v.panelX=300;v.panelY=8;
assert.equal(v.panelWidth(),256);assert.ok(v.panelContentMaxH()+v.panelChromeH()+v.panelTopBase()<=320);

// 使用真实创建/补建、尺寸事务与运行几何，覆盖全局倍率而非只检查UI文字或工厂常量。
const sizingProfile=model.getDefaultLayout();sizingProfile.name='展开键尺寸';sizingProfile.isPreset=false;sizingProfile.globalScale=1.5;
const {view:s}=compactEditorFixture(sizingProfile);
s.switchMainPanel_(true);s.openTab('secondary-new');s.secondaryNameDraft='尺寸组';s.createSecondary_();
const sizingGroup=s.secondaryEditingGroup;let sizingOpener=s.currentSecondaryOpener_();
assert.deepEqual([sizingOpener.baseWidth,sizingOpener.baseHeight,sizingOpener.itemScale],[48,48,1]);
assert.deepEqual([s.itemW(sizingOpener),s.itemH(sizingOpener)],[72,72]);
// 解除后补建入口也必须使用同一默认方形尺寸，旧入口仍作为普通键原样保留。
const oldOpenerId=sizingOpener.id;s.bindCurrentSecondary_();s.createCurrentOpener_();sizingOpener=s.currentSecondaryOpener_();
assert.notEqual(sizingOpener.id,oldOpenerId);assert.equal(s.controls.find(c=>c.id===oldOpenerId).secondaryAction,undefined);
assert.deepEqual([sizingOpener.baseWidth,sizingOpener.baseHeight,sizingOpener.itemScale],[48,48,1]);
const sizingId=sizingOpener.id,otherControls=JSON.stringify(s.controls.filter(c=>c.id!==sizingId));
sizingOpener.itemScale=.75;const beforeRatio=JSON.stringify(s.buildProfile());
s.applySecondaryOpenerRatio_(sizingId,'1:2');
assert.equal(s.secondaryOpenerRatio_(sizingId),'1:2');
assert.deepEqual([s.itemW(sizingOpener),s.itemH(sizingOpener)],[54,108]);
assert.equal(sizingOpener.itemScale,.75);assert.equal(JSON.stringify(s.controls.filter(c=>c.id!==sizingId)),otherControls);
s.undo();assert.equal(JSON.stringify(s.buildProfile()),beforeRatio,'比例选择只占一项撤销');
const touchGeometry=load('gamecontrol/src/main/ets/TouchControlGeometry.ets');
const runtimeGeometry=load('gamecontrol/src/main/ets/RuntimeTouchLayout.ets'),gui=load('gamecontrol/src/main/ets/GameGuiGeometry.ets');
const context=new runtimeGeometry.RuntimeTouchContext();Object.assign(context,{valid:true,widthPx:1600,heightPx:720,density:2,key:'opener-size'});
for(const [ratio,dimensions] of [['1:1',[48,48]],['1:2',[48,96]],['2:1',[96,48]]]){
  s.applySecondaryOpenerRatio_(sizingId,ratio);
  for(const globalScale of [.5,1,1.5,2]){
    s.globalScale=globalScale;const saved=model.validateAndNormalizeLayout(JSON.parse(JSON.stringify(s.buildProfile())));
    assert.ok(saved);const item=saved.controls.find(c=>c.id===sizingId);
    assert.deepEqual([item.baseWidth,item.baseHeight],dimensions);assert.equal(item.itemScale,.75);
    const expected=dimensions.map(n=>n*.75*globalScale);
    assert.deepEqual([s.itemW(item),s.itemH(item)],expected);
    assert.deepEqual([touchGeometry.touchControlWidth(item,saved),touchGeometry.touchControlHeight(item,saved)],expected);
    const runtime=runtimeGeometry.projectRuntimeTouchLayout(saved,context,new gui.GameGuiState(),true,0,new Map());
    const projected=runtime.entries.find(e=>e.item.id===sizingId);assert.ok(projected);
    assert.deepEqual([projected.rectVp.width,projected.rectVp.height],expected,'持久读取、编辑预览与真实运行命中尺寸一致');
  }
}
// 同值、未知比例、普通键及解绑后的旧回调都不能产生几何副作用。
const stable=JSON.stringify(s.buildProfile());s.applySecondaryOpenerRatio_(sizingId,'2:1');s.applySecondaryOpenerRatio_(sizingId,'3:1');
s.applySecondaryOpenerRatio_(oldOpenerId,'1:2');assert.equal(JSON.stringify(s.buildProfile()),stable);
sizingOpener=s.controls.find(c=>c.id===sizingId);sizingOpener.locked=true;
const locked=JSON.stringify(s.buildProfile());s.applySecondaryOpenerRatio_(sizingId,'1:1');assert.equal(JSON.stringify(s.buildProfile()),locked);
sizingOpener.locked=false;s.openSecondaryEditor_(sizingGroup);s.addSecondaryReturn_();
const returnId=s.currentSecondaryReturn_().id,withReturn=JSON.stringify(s.buildProfile());
s.applySecondaryOpenerRatio_(returnId,'1:2');assert.equal(JSON.stringify(s.buildProfile()),withReturn);
s.openSecondaryEditor_(sizingGroup);s.bindCurrentSecondary_();const detached=JSON.stringify(s.buildProfile());
s.applySecondaryOpenerRatio_(sizingId,'1:1');assert.equal(JSON.stringify(s.buildProfile()),detached);
console.log('PASS actual compact editor: direct group creation/addition, optional return, stable back, stale picker rejection, independent appearance, cascade and keep-members deletion, reload and 720x320 geometry');
console.log('PASS opener sizing: both creation paths, 3 ratios × 4 global scales, JSON/runtime geometry, undo, locked/ordinary/return/unbound rejection');
