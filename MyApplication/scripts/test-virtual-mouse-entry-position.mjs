/**
 * 虚拟鼠标入口出厂位置与缺项补齐回归。
 * 直接转译生产ETS及其布局投影，不复制坐标计算、夹取或迁移算法；断言覆盖新建、旧版升级和用户设置保留。
 * 测试只在宿主内存构造布局，不写用户存档、不调用设备输入，也不把几何通过解释为真机触达验证。
 */
import assert from 'node:assert/strict';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';

const load=makePureEtsLoader();
const layout=load('gamecontrol/src/main/ets/ControlLayout.ets');
const presets=load('gamecontrol/src/main/ets/LayoutPresets.ets');
const presentation=load('gamecontrol/src/main/ets/TouchControlPresentation.ets');
const candidate=load('gamecontrol/src/main/ets/LayoutCandidate.ets');
const runtime=load('gamecontrol/src/main/ets/RuntimeTouchLayout.ets');
const gui=load('gamecontrol/src/main/ets/GameGuiGeometry.ets');
let cases=0;

/** 每例失败立即中断，避免只输出已开始的名称而被误记成通过。 */
function check(name,body) { body();cases++;console.log('PASS '+name); }
function mouse(profile) {
  const matches=profile.controls.filter(item=>item.systemAction==='mouse');
  assert.equal(matches.length,1,'每份布局只补一颗顶层鼠标入口');
  return matches[0];
}

check('统一工厂、通用默认与手机/平板新预设使用同一右下工具位',()=>{
  const expected=layout.makeDefaultSystemMouseControl();
  assert.equal(expected.xPct,.94);assert.equal(expected.yPct,.90);
  assert.equal(expected.alignGroup,layout.AlignGroup.NONE);
  assert.equal(expected.hidden,undefined);assert.equal(expected.visibilityOverride,undefined);
  assert.equal(expected.grabbedOnly,false);assert.equal(expected.menuOnly,false);
  for(const profile of [layout.getDefaultLayout(),presets.presetPhone(),presets.presetTablet()])
    assert.deepEqual(mouse(profile),expected);
});

check('已发布版缺入口时补到右下，不借用旧默认滚轮位置，不删除自建滚轮和其它用户控件',()=>{
  const profile=layout.getDefaultLayout();
  profile.controls=profile.controls.filter(item=>item.systemAction!=='mouse');
  const wheel={...layout.makeSystemButton('visibility',.27,.61,0),
    id:'scroll',systemAction:undefined,type:layout.ControlType.SCROLL_WHEEL};
  const custom={...wheel,id:'custom-wheel',xPct:.8,style:{bg:'#123456'},children:undefined};
  profile.controls.push(wheel,custom);
  const untouched=profile.controls.filter(item=>item!==wheel);
  const before=structuredClone(untouched);
  presentation.ensureSystemMouseControl(profile);
  assert.equal(mouse(profile).xPct,.94);assert.equal(mouse(profile).yPct,.90);
  assert.equal(profile.controls.some(item=>item.id==='scroll'),false);
  assert.deepEqual(profile.controls.filter(item=>item.systemAction!=='mouse'),before);
  untouched.forEach(item=>assert.ok(profile.controls.includes(item),'用户原控件对象不能被替换或重排'));
});

check('已有入口所有用户字段按原值保留，加载不依据旧坐标猜测是否定制',()=>{
  // 旧开发默认坐标和明显手摆坐标都必须保留；已发布版本无入口，不能设计坐标识别迁移。
  for(const [xPct,yPct] of [[.6863,.7243],[.7291,.8717],[.92,.84],[.13,.22]]) {
    const profile=layout.getDefaultLayout();
    const item=mouse(profile);
    Object.assign(item,{xPct,yPct,baseWidth:72,baseHeight:56,itemScale:1.4,
      label:'自用鼠标',hidden:true,visibilityOverride:'force_hide',grabbedOnly:true,menuOnly:false,
      locked:true,alignGroup:layout.AlignGroup.NONE,style:{bg:'#123456',fg:'#abcdef',cornerRadius:.6,opacity:.45},
      hideOnInput:['mouse'],keys:[],modifiers:0,dragLook:false});
    const before=structuredClone(item);
    presentation.ensureSystemMouseControl(profile);
    assert.equal(mouse(profile),item);assert.deepEqual(item,before);
    item.hidden=false;item.visibilityOverride='force_show';item.grabbedOnly=false;item.menuOnly=true;
    const changed=structuredClone(item);
    presentation.ensureSystemMouseControl(profile);
    assert.deepEqual(item,changed,'第二次加载仍不能清掉用户显隐和场景');
  }
});

check('缺项补齐避让顶层与抽屉身份，重复调用不新增入口、不覆盖用户后续移动',()=>{
  const profile=layout.getDefaultLayout();
  profile.controls=profile.controls.filter(item=>item.systemAction!=='mouse');
  const nested=layout.makeSystemButton('input',.1,.2,0);
  nested.id='sys_mouse';nested.systemAction=undefined;
  const nestedSecond=layout.cloneItem(nested);nestedSecond.id='system_mouse_0';
  profile.controls[0].children=[nested,nestedSecond];
  presentation.ensureSystemMouseControl(profile);
  const item=mouse(profile);assert.equal(item.id,'system_mouse_1');
  item.xPct=.42;item.yPct=.37;
  const before=structuredClone(profile);
  presentation.ensureSystemMouseControl(profile);
  assert.deepEqual(profile,before);
});

check('真实布局事务经过前后两次整表校验后仍保留用户入口设置，缺项新增只发生在副本',()=>{
  const profile=layout.getDefaultLayout();
  const item=mouse(profile);
  Object.assign(item,{xPct:.33,yPct:.27,hidden:true,visibilityOverride:'force_hide',
    grabbedOnly:false,menuOnly:true,style:{bg:'#123456',cornerRadius:.6},itemScale:1.2});
  const before=structuredClone(profile);
  const first=candidate.buildLayoutCandidate(profile);
  assert.ok(first.profile,first.reason);assert.deepEqual(profile,before);
  const out=mouse(first.profile);
  for(const field of ['xPct','yPct','hidden','visibilityOverride','grabbedOnly','menuOnly','itemScale'])
    assert.deepEqual(out[field],item[field],field+'在加载事务中不可被恢复默认');
  // cloneStyle会显式补undefined可选字段；按持久化JSON语义比较，避免把“缺席”和“显式undefined”误判成用户样式变化。
  assert.deepEqual(JSON.parse(JSON.stringify(out.style)),JSON.parse(JSON.stringify(item.style)));
  assert.notEqual(out,item,'事务必须保留独立副本，不能借出用户持久对象');
  profile.controls=profile.controls.filter(control=>control!==item);
  const absent=structuredClone(profile);
  const second=candidate.buildLayoutCandidate(profile);
  assert.ok(second.profile,second.reason);assert.equal(mouse(second.profile).xPct,.94);
  assert.equal(mouse(second.profile).yPct,.90);assert.deepEqual(profile,absent);
});

/** 实际投影保证UI和Native共用同一有界矩形；此处没有替产品实现另一套夹取。 */
function projected(profile,width,height) {
  const context=new runtime.RuntimeTouchContext();
  Object.assign(context,{valid:true,widthPx:width*2,heightPx:height*2,density:2});
  const state=gui.parseGameGuiState([2,0,2,width*2,height*2,width,height,1,1,1,0,0,0]);
  assert.equal(state.valid,true);
  return runtime.projectRuntimeTouchLayout(profile,context,state,true,0,new Map());
}

check('新默认在手机/平板和缩小窗口中保持整颗可达，投影不写回百分比存档',()=>{
  for(const [factory,sizes] of [[layout.getDefaultLayout,[[720,360],[640,360],[400,240]]],
    [presets.presetPhone,[[827,374],[720,360],[640,320]]],
    [presets.presetTablet,[[1280,720],[960,600],[800,480]]]]) {
    for(const [width,height] of sizes) {
      const profile=factory();const before=structuredClone(profile);
      const projection=projected(profile,width,height);
      const entry=projection.find(mouse(profile).id);assert.ok(entry);
      const rect=entry.rectVp;
      assert.ok(rect.x>=0&&rect.y>=0&&rect.x+rect.width<=width&&rect.y+rect.height<=height);
      assert.ok(rect.x>=width*.8&&rect.y>=height*.7,'入口应位于可用游戏区域右下角');
      assert.equal(rect.width,mouse(profile).baseWidth*profile.globalScale);
      assert.equal(rect.height,mouse(profile).baseHeight*profile.globalScale);
      assert.deepEqual(profile,before);
    }
  }
});

check('新出厂工具位和被调整的潜行键在常用横屏中与全部其它控件不重叠',()=>{
  // 缩小窗口的回归只要求有界可达；本例核对有足够空间的出厂目标尺寸，不承诺极窄窗口整张布局零重叠。
  for(const [factory,sizes,changedId] of [[layout.getDefaultLayout,[[720,360],[827,374]],'sneak'],
    [presets.presetPhone,[[720,360],[827,374]],'btn_086848'],
    [presets.presetTablet,[[960,600],[1024,768],[1280,720]],'btn_420906']]) {
    for(const [width,height] of sizes) {
      const profile=factory();const projection=projected(profile,width,height);
      for(const id of [mouse(profile).id,changedId]) {
        const target=projection.find(id);assert.ok(target);
        const a=target.rectVp;
        for(const other of projection.entries) {
          if(other.item.id===id)continue;
          const b=other.rectVp;
          const overlap=Math.min(a.x+a.width,b.x+b.width)>Math.max(a.x,b.x)&&
            Math.min(a.y+a.height,b.y+b.height)>Math.max(a.y,b.y);
          assert.equal(overlap,false,`${profile.name} ${width}×${height}: ${id}与${other.item.id}重叠`);
        }
      }
    }
  }
});

console.log('Virtual mouse entry position: '+cases+' scenarios passed.');
