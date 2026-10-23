#!/usr/bin/env node
/**
 * GameControls 虚拟按键释放回归（I27-07 抽屉子按钮 / I27-06 编辑器打开顺序 / WASD 锁存补发）。
 *
 * 做法与 test-layout-editor-failures.mjs 相同：用宿主 TypeScript 解析真实 GameControls.ets，按名字
 * 抽取生产字段初值与方法（含模块级 sendKey/sendMouse 与常量）转译执行；只替换 native、定时器、
 * 时钟、触觉与存储边界，不复制控制流。native 用一张按 (source, kind, code) 配对的持有表模拟
 * 5668042 起的 NAPI 契约：PRESS 登记并返回 true；RELEASE 只有存在本端记录时才返回 true 并摘除；
 * 具名modal只退休TouchControls记录，物理键鼠/手柄的页面routing由独立runtime验证。
 *
 * 每个缺陷场景都带一个负向对照：把 HEAD 76d9b85 时的旧方法原文装到同一个夹具上重放，
 * 断言旧行为确实会漏放（键仍在 native 表里）——证明本测试能识别它要守的那一类缺陷。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import compiler from './lib/ets-compiler.mjs';
import { environment } from './lib/ets-runtime-fixture.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SOURCE = 'entry/src/main/ets/components/GameControls.ets';
const load = makePureEtsLoader({});
const keysModule = load('gamecontrol/src/main/ets/GlfwKeys.ets');
const layoutModule = load('gamecontrol/src/main/ets/ControlLayout.ets');
const sectorModule = load('gamecontrol/src/main/ets/JoystickSector.ets');
const { GLFW_PRESS, GLFW_RELEASE, GLFW_KEY_W, GLFW_KEY_E, GLFW_KEY_Q, GLFW_KEY_R, GLFW_KEY_Z, GLFW_KEY_X, GLFW_KEY_F3 } = keysModule;
const { ControlType } = layoutModule;
let passed = 0;
function check(name) { passed++; console.log('PASS ' + name); }

const FIELDS = ['configurationListener', 'controlClient', 'isGrabbed', 'pageActive', 'profile', 'profileVer', 'editing', 'editorOpening', 'editorLeaseHeld',
  'editorInputPaused', 'editorDisposeTask', 'globalVisMode', 'imeOpen', 'fieldImeOpen',
  'joystickX', 'joystickY', 'joystickFingerId', 'btnVisMap', 'btnPressedVer', 'buttonFingerIds', 'arktsButtonOutputs',
  'dragLookFinger', 'dragLookLastX', 'dragLookLastY', 'scrollFingerIds', 'scrollAccumDy', 'scrollLastY',
  'hotbarFingerId', 'hotbarLastSlot', 'drawerOpen', 'activeKeys', 'keyLastReleaseAt', 'pendingLatchedDirections',
  'directionLatchTimer', 'directionLatchDueAt', 'mounted', 'appearanceGeneration', 'schemaActive',
  'schemaTakeoverJoystick', 'schemaTakeoverButtons', 'toggleStates', 'accessibilityToggleStates', 'lastTapAt',
  'longPressTimers', 'longPressFired', 'mouseResetRevision', 'desiredProfile', 'imeModal', 'editorModal'];
const METHODS = ['emitDragLookVp', 'hasContinuousControlInteraction', 'getBtnVis', 'setPressed', 'isPressed', 'isButtonHeld', 'findControlById', 'findControlIn',
  'isTopLevelControl', 'cOwnsButton', 'cOwnsJoystick', 'dispatchButton', 'releaseArktsButtonOutput',
  'emitCheckedKeySequence', 'emitTouchKey', 'releaseAllArktsButtonOutputs', 'activateButtonFromAccessibility',
  'releaseAccessibilityToggle', 'emitAccessibilityKeys', 'forceReleaseTouchSource', 'dropHeldCacheAfterNativeReset',
  'buttonAddFinger', 'buttonRemoveFinger', 'buttonReleaseAllFingers', 'clearAllToggles', 'resetTransientInputState',
  'onGrabChanged', 'maybeOpenLearning', 'onImeOpenChanged', 'releaseInputForSurfaceRebuild', 'releaseAllDirections', 'applyDirection',
  'updateJoystickKeys', 'armDirectionLatchTimer', 'onDirectionLatchExpired', 'cancelDirectionLatch',
  'collapseHiddenDrawers', 'toggleDrawer', 'releaseDrawerChildren', 'releaseControlInputs', 'cycleVisMode',
  'isControlVisible', 'openEditor', 'resumeEditorInput_', 'showEditorError_', 'releaseEditorLease_'];
const MODULE_FUNCTIONS = [];
const MODULE_CLASSES = ['BtnVisState', 'ArktsButtonOutputRecord'];

/** 按名字从真实源码的 AST 取文本；缺任何一个成员立即失败，防止生产改名后测试静默跳过。 */
function productionSource() {
  const text = fs.readFileSync(path.join(root, SOURCE), 'utf8');
  const ast = compiler.createSourceFile(SOURCE, text, compiler.ScriptTarget.Latest, true);
  const owner = ast.statements.find(node => node.name?.getText(ast) === 'GameControls' && node.members);
  assert.ok(owner, 'GameControls 组件未找到');
  const strip = source => source.replace(/@(Prop|State|Watch|Observed|Link|ObjectLink|StorageProp)(\([^\n]*?\))?\s*/g, '');
  const member = name => {
    const found = owner.members.find(item => item.name?.getText(ast) === name);
    assert.ok(found, '生产成员缺失：' + name);
    return strip(found.getText(ast));
  };
  const topLevel = (kind, names) => names.map(name => {
    const found = ast.statements.find(node => node.kind === kind && node.name?.getText(ast) === name);
    assert.ok(found, '模块级声明缺失：' + name);
    return strip(found.getText(ast));
  });
  const constants = ast.statements.filter(node => node.kind === compiler.SyntaxKind.VariableStatement)
    .map(node => node.getText(ast));
  return [...constants, ...topLevel(compiler.SyntaxKind.ClassDeclaration, MODULE_CLASSES),
    ...topLevel(compiler.SyntaxKind.FunctionDeclaration, MODULE_FUNCTIONS),
    'class Subject {', ...FIELDS.map(member), ...METHODS.map(member), '}'].join('\n');
}

/**
 * HEAD 76d9b85 的旧实现原文（负向对照专用）。只在对照用例里覆盖到实例上，证明旧行为会漏放；
 * 旧的无障碍 toggle 是 Set，负向对照会同时把字段换回 Set。
 */
const LEGACY = `class Legacy {
  buttonReleaseAllFingers(keepHeld = false) {
    this.buttonFingerIds.forEach((set, id) => {
      if (set.size === 0) return
      const item = this.profile.controls.find((c) => c.id === id)
      const trig = item ? (item.trigger ?? 'press') : 'press'
      const isSystem = item !== undefined && item.systemAction !== undefined
      if (keepHeld && !isSystem && trig === 'press') {
        return
      }
      if (item && !isSystem && (trig === 'press' || trig === 'doubleTap')) {
        this.dispatchButton(item, GLFW_RELEASE)
      }
      set.clear()
    })
    this.btnVisMap.forEach((v) => { v.pressed = false })
    this.buttonFingerIds.forEach((set, id) => {
      if (set.size > 0) this.getBtnVis(id).pressed = true
    })
    this.btnPressedVer++
    this.clearAllToggles()
  }
  clearAllToggles() {
    this.toggleStates.forEach((id) => {
      const item = this.profile.controls.find((c) => c.id === id)
      if (item !== undefined) this.dispatchButton(item, GLFW_RELEASE)
    })
    this.toggleStates.clear()
    this.accessibilityToggleStates.forEach((id) => {
      const item = this.profile.controls.find((control) => control.id === id)
      if (item !== undefined) this.emitAccessibilityButton(item, GLFW_RELEASE)
    })
    this.accessibilityToggleStates.clear()
    this.lastTapAt.clear()
    this.longPressTimers.forEach((tid) => clearTimeout(tid))
    this.longPressTimers.clear()
    this.longPressFired.forEach((id) => {
      const item = this.profile.controls.find((c) => c.id === id)
      if (item !== undefined) this.dispatchButton(item, GLFW_RELEASE)
    })
    this.longPressFired.clear()
  }
  onImeOpenChanged() {
    if (this.imeOpen || this.fieldImeOpen) {
      setTimeout(() => {
        this.releaseAllDirections()
        this.joystickFingerId = -1
        this.joystickX = 0
        this.joystickY = 0
        this.buttonReleaseAllFingers(false)
      }, 0)
    }
  }
  activateButtonFromAccessibility(item) {
    const trigger = item.trigger ?? 'press'
    if (trigger === 'toggle') {
      if (this.accessibilityToggleStates.has(item.id)) {
        if (this.emitAccessibilityButton(item, GLFW_RELEASE)) {
          this.accessibilityToggleStates.delete(item.id)
          this.setPressed(item.id, false)
        }
      } else if (this.toggleStates.has(item.id)) {
        if (this.dispatchButton(item, GLFW_RELEASE)) {
          this.toggleStates.delete(item.id)
          this.setPressed(item.id, false)
        }
      } else {
        if (this.emitAccessibilityButton(item, GLFW_PRESS)) {
          this.accessibilityToggleStates.add(item.id)
          this.setPressed(item.id, true)
        }
      }
      return
    }
  }
  emitAccessibilityButton(item, action) {
    for (const key of effectiveKeys(item)) {
      if (!sendKey(key, action)) { if (action === GLFW_RELEASE) this.forceReleaseTouchSource('legacy-release'); return false; }
    }
    return true;
  }
  applyDirection(key, want) {
    const has = this.activeKeys.has(key)
    if (want && !has) {
      const lastReleaseAt = this.keyLastReleaseAt.get(key) ?? 0
      const now = Date.now()
      if (now - lastReleaseAt < JOYSTICK_REPRESS_LOCKOUT_MS) {
        return
      }
      if (sendKey(key, GLFW_PRESS)) this.activeKeys.add(key)
    } else if (!want && has) {
      if (sendKey(key, GLFW_RELEASE)) {
        this.activeKeys.delete(key)
        this.keyLastReleaseAt.set(key, Date.now())
      }
    }
  }
}`;

/** 按 (source, kind, code) 配对的 native 持有表；log 保留每次调用及返回值，供顺序断言。 */
function fakeNative() {
  const held = new Map(), log = [], leases = new Map(), modals = new Set(); let nextToken = 1;
  const state = { resets: 0, sourceReleases: 0 };
  const edge = kind => (source, code, third, fourth) => {
    const action = kind === 'key' ? fourth : third;
    const slot = source + ':' + kind + ':' + code;
    let accepted = true;
    if (action === GLFW_PRESS) held.set(slot, (held.get(slot) ?? 0) + 1);
    else if ((held.get(slot) ?? 0) > 0) { const left = held.get(slot) - 1; if (left > 0) held.set(slot, left); else held.delete(slot); }
    else accepted = false;
    log.push((action === GLFW_PRESS ? 'press:' : 'release:') + kind + ':' + code + ':' + accepted);
    return accepted;
  };
  return { held, log, state,
    napi: {
      sendSourceKeyEvent: edge('key'), sendSourceMouseEvent: edge('mouse'),
      acquireSourceControl(source, device, control, codes) {
        const token=String(nextToken++); leases.set(token,{source,codes:codes.slice()});
        for(const code of codes) { if(code>0)edge('key')(source,code,0,1);else edge('mouse')(source,-code-1,1,0); }
        return token;
      },
      releaseSourceControl(token) {
        const lease=leases.get(token);if(!lease)return true;leases.delete(token);
        for(const code of lease.codes.slice().reverse()) { if(code>0)edge('key')(lease.source,code,0,0);else edge('mouse')(lease.source,-code-1,0,0); }
        return true;
      },
      releaseSourceHeld: source => { state.sourceReleases++; for (const slot of [...held.keys()]) if (slot.startsWith(source + ':')) held.delete(slot); },
      noteSourceReset: () => { state.resets++; },
      setTouchPaused: paused => { log.push('pause:' + paused); if (paused) { held.clear(); leases.clear(); } },
      acquireTouchModal: owner => {
        const token='modal-'+String(nextToken++);modals.add(token);log.push('modal+'+owner);
        for(const slot of [...held.keys()])if(slot.startsWith('1:'))held.delete(slot);
        for(const[token,lease]of leases)if(lease.source===1)leases.delete(token);
        return token;
      },
      releaseTouchModal: token => { log.push('modal-'+token);return modals.delete(token); },
      setControlSchema: () => 1, onButtonPressed() {}, onHaptic() {},
      publishTouchSchema(){},touchPublicationState(){},confirmTouchPublication(){},
    },
    holds: code => held.has('1:key:' + code),
  };
}

/** 可控时钟与定时器：advance 按到期先后执行回调，回调里新排的定时器同样参与本次推进。 */
function fakeTimers() {
  let now = 1000, nextId = 1;
  const queue = new Map();
  return { Date: { now: () => now },
    setTimeout: (fn, delay = 0) => { const id = nextId++; queue.set(id, { fn, at: now + Math.max(0, delay) }); return id; },
    clearTimeout: id => { queue.delete(id); },
    pending: () => queue.size,
    advance(ms) {
      const target = now + ms;
      for (;;) {
        let next;
        for (const [id, timer] of queue) if (timer.at <= target && (!next || timer.at < next[1].at)) next = [id, timer];
        if (!next) break;
        queue.delete(next[0]); now = Math.max(now, next[1].at); next[1].fn();
      }
      now = target;
    } };
}

function button(id, keys, trigger = 'press') {
  return { id, label: '', type: ControlType.BUTTON, keyOrMouse: keys[0], keys: keys.slice(), trigger,
    xPct: 0.1, yPct: 0.1, baseWidth: 48, baseHeight: 48, itemScale: 1, isCircle: false,
    alignGroup: 'none', alignIndex: 0, grabbedOnly: false };
}

function profile() {
  const drawer = { ...button('drawer', [0]), type: ControlType.DRAWER, keys: [], keyOrMouse: 0, children: [
    button('c_press', [GLFW_KEY_E]), button('c_toggle', [GLFW_KEY_Q], 'toggle'),
    button('c_long', [GLFW_KEY_R], 'longPress'), button('c_access', [GLFW_KEY_Z], 'toggle')] };
  return { name: '测试', globalScale: 1, isPreset: false, haptic: false, joystickDeadZone: 0.18,
    controls: [button('f3', [GLFW_KEY_F3]), button('top_access', [GLFW_KEY_Z], 'toggle'), drawer] };
}

/** 组装一个带生产方法的实例；legacy=true 时把旧方法（及旧的 Set 字段）覆盖上去做负向对照。 */
function harness({ grabbed = false, legacy = false } = {}) {
  const native = fakeNative(), timers = fakeTimers(), warnings = [], regions = [];
  const store = { beginEditorSession: () => true, beginEditorTransaction() {}, endEditorSession() {},
    restoreEditorTransaction: async () => true, cloneAsUser: async () => null, getActiveProfile: () => instance.profile };
  const { SourceControlClient } = load('gamecontrol/src/main/ets/SourceControlClient.ets');
  const modal=environment({imports:{'libentry.so':{default:native.napi}}}).load('entry/src/main/ets/components/EntryTouchModalBroker.ets');
  const bindings = { testNapi: native.napi, AmclInputSource: { TouchControls: 1 },
    ...modal,
    createEntrySourceControlClient: source => new SourceControlClient(source, {
      acquire: (...args) => native.napi.acquireSourceControl(...args), release: token => native.napi.releaseSourceControl(token) }),
    sendKey: (key, action) => native.napi.sendSourceKeyEvent(1,key,0,action),
    sendMouse: (button, action) => native.napi.sendSourceMouseEvent(1,button,action,0),
    GLFW_PRESS, GLFW_RELEASE, GLFW_KEY_W: keysModule.GLFW_KEY_W, GLFW_KEY_A: keysModule.GLFW_KEY_A,
    GLFW_KEY_S: keysModule.GLFW_KEY_S, GLFW_KEY_D: keysModule.GLFW_KEY_D,
    isMouseCode: keysModule.isMouseCode, decodeMouse: keysModule.decodeMouse,
    ControlType, touchBehaviorKey: environment().load('gamecontrol/src/main/ets/InputConfiguration.ets').touchBehaviorKey, effectiveKeys: layoutModule.effectiveKeys, MAX_LAYOUT_CHILD_DEPTH: layoutModule.MAX_LAYOUT_CHILD_DEPTH,
    runtimeTouchControlVisible:load('gamecontrol/src/main/ets/RuntimeTouchLayout.ets').runtimeTouchControlVisible,
    getDefaultLayout: layoutModule.getDefaultLayout, cloneLayout: layoutModule.cloneLayout,
    isVisibleInScene: layoutModule.isVisibleInScene, DEFAULT_JOYSTICK_DEAD_ZONE: layoutModule.DEFAULT_JOYSTICK_DEAD_ZONE,
    joystickSector: sectorModule.joystickSector, hapticTap() {},
    hilog: { warn: (...args) => warnings.push(args), error: (...args) => warnings.push(args), info() {} },
    getLayoutStore: () => store,
    setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout, Date: timers.Date };
  const compile = source => {
    const out = compiler.transpileModule(source + '\nmodule.exports = { Subject: typeof Subject === "undefined" ? undefined : Subject, Legacy: typeof Legacy === "undefined" ? undefined : Legacy };',
      { compilerOptions: { target: compiler.ScriptTarget.ES2020, module: compiler.ModuleKind.CommonJS }, reportDiagnostics: true });
    assert.equal((out.diagnostics ?? []).filter(item => item.category === compiler.DiagnosticCategory.Error).length, 0);
    const module = { exports: {} };
    new Function('module', ...Object.keys(bindings), out.outputText)(module, ...Object.values(bindings));
    return module.exports;
  };
  const exported = compile(productionSource() + '\n' + (legacy ? LEGACY : ''));
  const instance = new exported.Subject();
  // 文件/传感器/视觉会话是此释放夹具的外部平台边界；其真实接线由touch优化专项回归执行。
  Object.assign(instance, { touchVisual: { joystickActive: false, locked: false, guide:{grabbed:false} },
    touchSession: { refreshBindings() {}, refreshVisual() {}, setGrabbed() {}, stop() {},setTouchAdmission(){} },
    touchGuide:{baseline(){}},syncGuideObservation(){},syncGuideBounds(){},syncMouseBounds(){},touchSurface:{admits:()=>true},
    // 菜单面板独立owner的真实账本/关闭路径由两个touch-basics/menu-mouse专项执行；此夹具只替换外部平台边界。
    mouseController: { release() {}, model:{acknowledgeReset(){}} }, mouseOpen:false, mousePending:false });
  Object.assign(instance, { profile: profile(), isGrabbed: grabbed, mounted: true, appearanceGeneration: 1,
    // 本组直接回放ArkUI兼容/无障碍输出的退休；普通触摸的Native接管在下方用实际投影单独验证。
    runtimeLayout:new (load('gamecontrol/src/main/ets/RuntimeTouchLayout.ets').RuntimeTouchLayout)(),
    registerRegions() { regions.push(instance.globalVisMode); return true; }, onLayoutChanged() {}, onInputPause() {},
    getUIContext: () => ({ getPromptAction: () => ({ showToast() {} }) }) });
  if (legacy) {
    for (const name of Object.getOwnPropertyNames(exported.Legacy.prototype)) {
      if (name !== 'constructor') instance[name] = exported.Legacy.prototype[name];
    }
    instance.accessibilityToggleStates = new Set();
  }
  const drawer = () => instance.profile.controls[2];
  const child = id => drawer().children.find(item => item.id === id);
  const top = id => instance.profile.controls.find(item => item.id === id);
  return { i: instance, native, timers, warnings, regions, drawer, child, top,
    open: () => { instance.drawerOpen.set('drawer', true); instance.drawerOpen = new Map(instance.drawerOpen); } };
}

// 外观刷新不能借ForEach重建取消已有手势；配置保持pending，松手后由同一订阅者确认。
{
  const t=harness(),samples=[];
  t.i.getUIContext=()=>({vp2px:value=>value*3.25});
  t.native.napi.sendSourceCursorSample=(...sample)=>{samples.push(sample);return true;};
  t.i.emitDragLookVp(10,-4,123456789);
  assert.deepEqual(samples,[[1,32.5,-13,123456789]],'真实控件入口转换vp并保留平台采样ns');
  check('ArkUI dragLook以surface px和原采样ns进入触控公共加工器');
}

// 外观刷新不能借ForEach重建取消已有手势；配置保持pending，松手后由同一订阅者确认。
{
  const t=harness();const control=t.top('f3');t.i.buttonAddFinger(control,1);
  const changed=layoutModule.cloneLayout(t.i.profile);changed.controls[0].label='新标签';
  const version=t.i.profileVer;
  let acknowledged=false;const requested=[];
  t.i.registerRegions=()=>{requested.push(t.i.desiredProfile);return acknowledged;};
  assert.equal(t.i.configurationListener(changed,2),false);
  assert.equal(t.i.profileVer,version);assert.ok(t.native.holds(GLFW_KEY_F3));
  assert.equal(t.i.desiredProfile.controls[0].label,'新标签');assert.equal(t.i.profile.controls[0].label,control.label);
  t.i.buttonRemoveFinger(control,1);
  acknowledged=true;
  assert.equal(t.i.configurationListener(changed,2),true);
  assert.equal(requested.at(-1).controls[0].label,'新标签');assert.equal(t.i.profileVer,version,'订阅入口不提前伪造UI提交');
  const before=t.i.profile;const pending=layoutModule.cloneLayout(before);pending.controls[0].label='未确认';
  t.i.registerRegions=()=>false;assert.equal(t.i.configurationListener(pending,3),false);
  assert.equal(t.i.profile,before,'原生发布失败不提交新的UI配置');
  check('配置订阅冻结desired并返回协调器回执；自身不替换已呈现UI（真实fence组合另由专项执行）');
}

// ---- I27-07 ①：IME 打开时按住的抽屉子按钮必须按记录释放（这条边界没有 native cancel 兜底） ----
{
  const t = harness({ grabbed: true }); t.open();
  t.i.buttonAddFinger(t.child('c_press'), 11);
  assert.ok(t.native.holds(GLFW_KEY_E), '子按钮 PRESS 由 ArkTS 发出');
  // 布局替换后遗留的孤儿记录也要放：模拟一个已不在 profile 里的控件记录。
  t.i.buttonAddFinger(button('gone', [GLFW_KEY_X]), 12);
  t.i.profile.controls = t.i.profile.controls.filter(item => item.id !== 'gone');
  // 没有任何手指 / 状态机再指向它的输出记录（例如释放恢复失败后遗留）：只有按记录的全量释放能放掉。
  t.i.dispatchButton(button('orphan', [GLFW_KEY_Q]), GLFW_PRESS);
  t.i.imeOpen = true; t.i.onImeOpenChanged(); t.timers.advance(0);
  assert.equal(t.native.holds(GLFW_KEY_E), false); assert.equal(t.native.holds(GLFW_KEY_X), false);
  assert.equal(t.native.holds(GLFW_KEY_Q), false, 'IME 边界补发按记录的全量释放');
  assert.equal(t.i.isButtonHeld('c_press'), false, '指集同步清空，抬手不会再被当成持有');
  assert.equal(t.i.arktsButtonOutputs.size, 0);
  assert.equal(t.native.state.resets, 0, '正常释放不应触发源级恢复');
  const old = harness({ grabbed: true, legacy: true }); old.open();
  old.i.buttonAddFinger(old.child('c_press'), 11);
  old.i.imeOpen = true; old.i.onImeOpenChanged(); old.timers.advance(0);
  assert.equal(old.native.holds(GLFW_KEY_E), true, '负向对照：旧的顶层查找让子按钮键一直按着');
  assert.equal(old.i.arktsButtonOutputs.has('c_press'), true, '负向对照：旧实现留下孤儿记录');
  check('IME 打开释放按住的抽屉子按钮与孤儿记录；旧实现卡键');
}

// ---- I27-07 ②：grab 翻转只豁免顶层 press，toggle / longPress 子按钮必须释放 ----
{
  const run = legacy => {
    const t = harness({ grabbed: false, legacy }); t.open();
    t.i.buttonAddFinger(t.top('f3'), 1);
    t.i.buttonAddFinger(t.child('c_toggle'), 2); t.i.buttonRemoveFinger(t.child('c_toggle'), 2);
    t.i.buttonAddFinger(t.child('c_long'), 3); t.timers.advance(200);
    t.i.buttonAddFinger(t.child('c_press'), 4);
    assert.ok(t.native.holds(GLFW_KEY_F3) && t.native.holds(GLFW_KEY_Q) && t.native.holds(GLFW_KEY_R) && t.native.holds(GLFW_KEY_E));
    t.i.isGrabbed = true; t.i.resetTransientInputState(true);
    return t;
  };
  const t = run(false);
  assert.equal(t.native.holds(GLFW_KEY_F3), true, '顶层 press 按住跨 grab 翻转保留（F3+F4 组合）');
  assert.equal(t.i.isButtonHeld('f3'), true); assert.equal(t.i.getBtnVis('f3').pressed, true);
  assert.equal(t.native.holds(GLFW_KEY_Q), false); assert.equal(t.native.holds(GLFW_KEY_R), false);
  assert.equal(t.native.holds(GLFW_KEY_E), false, '按住的 press 子按钮不享受 keepHeld 豁免');
  assert.equal(t.i.toggleStates.size, 0); assert.equal(t.i.longPressFired.size, 0);
  assert.equal(t.i.drawerOpen.size, 0, '翻转收起抽屉');
  t.i.buttonRemoveFinger(t.top('f3'), 1);
  assert.equal(t.native.holds(GLFW_KEY_F3), false, '真正抬手时按按下记录释放');
  assert.equal(t.native.state.resets, 0);
  const old = run(true);
  assert.equal(old.native.holds(GLFW_KEY_Q), true, '负向对照：旧实现 toggle 子按钮卡键');
  assert.equal(old.native.holds(GLFW_KEY_R), true, '负向对照：旧实现已触发的 longPress 子按钮卡键');
  check('grab 翻转释放 toggle/longPress/press 子按钮，保留按住的顶层 press；旧实现卡键');
}

// ---- I27-07 ③：无障碍 toggle 子按钮按按下时记录的键释放（热更新改键也不放错键） ----
{
  const t = harness({ grabbed: true }); t.open();
  t.i.activateButtonFromAccessibility(t.child('c_access'));
  assert.ok(t.native.holds(GLFW_KEY_Z));
  t.child('c_access').keys = [GLFW_KEY_X]; t.child('c_access').keyOrMouse = GLFW_KEY_X;
  t.i.onGrabChanged();
  assert.equal(t.native.holds(GLFW_KEY_Z), false, '按记录的 Z 释放');
  assert.equal(t.native.log.some(item => item.startsWith('release:key:' + GLFW_KEY_X)), false, '不会拿新键去放旧键');
  assert.equal(t.i.accessibilityToggleStates.size, 0); assert.equal(t.native.state.resets, 0);
  // 顶层无障碍 toggle 同样按记录释放；旧实现用热更新后的键释放 → RELEASE 无配对 → 误走源级恢复。
  const fresh = harness({ grabbed: true });
  fresh.i.activateButtonFromAccessibility(fresh.top('top_access'));
  fresh.top('top_access').keys = [GLFW_KEY_X];
  fresh.i.clearAllToggles();
  assert.equal(fresh.native.holds(GLFW_KEY_Z), false); assert.equal(fresh.native.state.resets, 0);
  const old = harness({ grabbed: true, legacy: true }); old.open();
  old.i.activateButtonFromAccessibility(old.child('c_access'));
  old.i.onGrabChanged();
  assert.equal(old.native.holds(GLFW_KEY_Z), true, '负向对照：旧实现查不到子按钮，无障碍 toggle 永远按着');
  const oldTop = harness({ grabbed: true, legacy: true });
  oldTop.i.activateButtonFromAccessibility(oldTop.top('top_access'));
  oldTop.top('top_access').keys = [GLFW_KEY_X];
  oldTop.i.clearAllToggles();
  assert.equal(oldTop.native.state.resets, 1, '负向对照：旧实现用新键释放，RELEASE 无配对后被迫整端复位');
  check('无障碍 toggle（子按钮/顶层）按记录的键释放；旧实现漏放或误触发源级恢复');
}

// ---- I27-07 ④：用户收起抽屉、可见性档位隐藏抽屉都先释放子按钮 ----
{
  const t = harness({ grabbed: true }); t.open();
  t.i.buttonAddFinger(t.child('c_press'), 5);
  t.i.buttonAddFinger(t.child('c_toggle'), 6); t.i.buttonRemoveFinger(t.child('c_toggle'), 6);
  t.i.toggleDrawer(t.drawer());
  assert.equal(t.i.drawerOpen.get('drawer'), false);
  assert.equal(t.native.holds(GLFW_KEY_E), false); assert.equal(t.native.holds(GLFW_KEY_Q), false);
  assert.equal(t.i.isButtonHeld('c_press'), false); assert.equal(t.i.getBtnVis('c_press').pressed, false);
  assert.ok(t.regions.length > 0, '收起后重下发 schema');
  const v = harness({ grabbed: true }); v.open(); v.i.globalVisMode = 1;
  v.i.buttonAddFinger(v.child('c_press'), 7);
  v.i.cycleVisMode();
  assert.equal(v.i.globalVisMode, 2); assert.equal(v.i.drawerOpen.get('drawer'), false);
  assert.equal(v.native.holds(GLFW_KEY_E), false, '隐藏档位收起抽屉前释放子按钮');
  // 负向对照：旧的收起只翻转展开状态，子按钮键留在 native 表里。
  const old = harness({ grabbed: true, legacy: true }); old.open();
  old.i.buttonAddFinger(old.child('c_press'), 5);
  old.i.drawerOpen.set('drawer', false);
  assert.equal(old.native.holds(GLFW_KEY_E), true, '负向对照：只翻转状态会卡键');
  check('收起抽屉 / 可见性档位隐藏抽屉先释放子按钮；只翻转状态会卡键');
}

// ---- 实际运行投影决定Native解释权；释放查找仍覆盖整个控件树 ----
{
  const t = harness({ grabbed: true });
  const geometry=load('gamecontrol/src/main/ets/RuntimeTouchLayout.ets');
  const gui=load('gamecontrol/src/main/ets/GameGuiGeometry.ets');
  const context=new geometry.RuntimeTouchContext();Object.assign(context,{valid:true,widthPx:800,heightPx:600,density:1,key:'release'});
  t.i.runtimeLayout=geometry.projectRuntimeTouchLayout(t.i.profile,context,new gui.GameGuiState(),true,0,new Map([['drawer',true]]));
  assert.equal(t.i.cOwnsButton(t.child('c_press')), true);
  assert.equal(t.i.cOwnsButton(t.top('f3')), true);
  assert.equal(t.i.findControlById('c_long'), t.child('c_long'));
  assert.equal(t.i.isTopLevelControl('c_long'), false);
  check('实际投影中的子按钮由Native接管，findControlById仍覆盖抽屉子树');
}

// ---- 编辑器按记录释放后取得touch模态；不会借全域cancel清掉其它端 ----
{
  const t = harness({ grabbed: false });
  t.i.buttonAddFinger(t.top('f3'), 1);
  t.native.napi.sendSourceKeyEvent(2,GLFW_KEY_E,0,1);
  await t.i.openEditor();
  const release = t.native.log.indexOf('release:key:' + GLFW_KEY_F3 + ':true');
  const pause = t.native.log.findIndex(item=>item.startsWith('modal+editor:'));
  assert.ok(release >= 0 && pause > release, '配对RELEASE发生在触控modal取得之前');
  assert.equal(t.native.held.has('2:key:'+GLFW_KEY_E),true,'touch模态不释放手柄贡献');
  assert.equal(t.native.log.includes('pause:true'),false,'编辑器不再调用全域setTouchPaused');
  assert.equal(t.native.state.resets, 0); assert.equal(t.native.state.sourceReleases, 0);
  assert.equal(t.i.editing, true);
  const old = harness({ grabbed: false });
  old.i.buttonAddFinger(old.top('f3'), 1);
  old.native.napi.setTouchPaused(true);
  old.i.buttonReleaseAllFingers();
  assert.equal(old.native.holds(GLFW_KEY_F3), false);
  assert.equal(old.native.log.includes('release:key:' + GLFW_KEY_F3 + ':false'), false, '原生先撤销时旧token幂等释放，不再逐键发无配对边沿');
  assert.equal(old.native.state.resets, 0, 'token退休不触发额外全源恢复');
  check('openEditor先自释放再取得touch域模态；手柄贡献保留、旧token退休仍幂等');
}

// ---- WASD 30ms 锁存：被压住的方向在到期后补发；松开 / 反向采样 / 复位都撤销补发 ----
{
  const latched = legacy => {
    const t = harness({ grabbed: false, legacy });
    t.i.joystickFingerId = 7;
    t.i.updateJoystickKeys(0, -1);
    assert.ok(t.native.holds(GLFW_KEY_W));
    t.timers.advance(5); t.i.updateJoystickKeys(0, 0);
    assert.equal(t.native.holds(GLFW_KEY_W), false);
    t.timers.advance(5); t.i.updateJoystickKeys(0, -1);
    assert.equal(t.native.holds(GLFW_KEY_W), false, '锁存窗口内暂不按下');
    return t;
  };
  const t = latched(false);
  assert.equal(t.timers.pending(), 1, '只排一个补发定时器');
  t.timers.advance(25);
  assert.equal(t.native.holds(GLFW_KEY_W), true, '手指不动也在锁存到期后补发');
  assert.equal(t.timers.pending(), 0);
  const released = latched(false); released.i.releaseAllDirections(); released.timers.advance(40);
  assert.equal(released.native.holds(GLFW_KEY_W), false); assert.equal(released.timers.pending(), 0);
  const reversed = latched(false); reversed.i.updateJoystickKeys(0, 0); reversed.timers.advance(40);
  assert.equal(reversed.native.holds(GLFW_KEY_W), false, 'want=false 采样撤销补发');
  const reset = latched(false); reset.i.dropHeldCacheAfterNativeReset(); reset.timers.advance(40);
  assert.equal(reset.native.holds(GLFW_KEY_W), false); assert.equal(reset.timers.pending(), 0);
  const destroyed = latched(false); destroyed.i.resetTransientInputState(); destroyed.timers.advance(40);
  assert.equal(destroyed.native.holds(GLFW_KEY_W), false, '复位 / 销毁路径撤销补发');
  const old = latched(true); old.timers.advance(100);
  assert.equal(old.native.holds(GLFW_KEY_W), false, '负向对照：旧锁存直接丢弃，手指不动时方向永远不按下');
  check('WASD 锁存到期补发，释放/反向/复位撤销；旧实现丢失方向');
}

console.log('[game-controls-release] PASS ' + passed + ' production-method scenarios with paired native table');
