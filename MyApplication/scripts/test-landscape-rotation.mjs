/**
 * 双向横屏的生产窗口/显示回调/触控投影回归。
 * 只替换系统 Window 与 Display 边界；实际策略选择、方向采样、代际发布和布局投影均执行生产代码。
 * 这些宿主断言证明应用链路，不替代真机控制中心和物理翻转验收。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

/** 使用真实 McGamePage 的显示通知闭包，避免测试用另一套回调掩盖同尺寸翻转的漏通知。 */
function pageDisplayCallback(coordinator, notifications) {
  const file = new URL('../entry/src/main/ets/pages/McGamePage.ets', import.meta.url);
  const text = fs.readFileSync(file, 'utf8');
  const ast = compiler.createSourceFile('McGamePage.ets', text, compiler.ScriptTarget.Latest, true);
  const owner = ast.statements.find(node => node.name?.getText(ast) === 'McGamePage');
  const member = owner.members.find(node => node.name?.getText(ast) === 'displayChangeListener');
  assert.ok(member, '页面必须保留独立于窗口尺寸事件的 Display 变化通知');
  const source = 'class Subject {' + member.getText(ast) + '} module.exports = Subject;';
  const js = compiler.transpileModule(source, { compilerOptions: {
    target: compiler.ScriptTarget.ES2020, module: compiler.ModuleKind.CommonJS
  } }).outputText;
  const box = { exports: {} };
  new Function('module', js)(box);
  const page = new box.exports();
  page.gameWindowCoordinator = coordinator;
  page.syncInputSurfaceContext = (snapshot, reason) => notifications.push({ snapshot, reason });
  return page.displayChangeListener;
}

/** 每次装载独立的生产事实源，系统只提供当前窗口所属 Display；禁止借默认屏幕掩盖方向错误。 */
function fixture(rotation) {
  const pure = makePureEtsLoader();
  const surfaces = pure('gamecontrol/src/main/ets/InputSurfaceContext.ets');
  const geometry = pure('gamecontrol/src/main/ets/RuntimeTouchLayout.ets');
  const layouts = pure('gamecontrol/src/main/ets/ControlLayout.ets');
  const gui = pure('gamecontrol/src/main/ets/GameGuiGeometry.ets');
  const orientations = [], events = new Map();
  const currentDisplay = { rotation, densityPixels: 2, refreshRate: 120 };
  // 枚举值来自当前 SDK @ohos.window.d.ts；允许方向及系统开关语义由官方 SDK 负责。
  const Orientation = { UNSPECIFIED: 0, LANDSCAPE: 2, AUTO_ROTATION_RESTRICTED: 8,
    AUTO_ROTATION_LANDSCAPE_RESTRICTED: 10 };
  const win = {
    getWindowProperties: () => ({ id: 42, displayId: 7, isLayoutFullScreen: false,
      windowRect: { left: 0, top: 0, width: 2400, height: 1080 } }),
    getPreferredOrientation: () => Orientation.AUTO_ROTATION_RESTRICTED,
    setPreferredOrientation: async value => { orientations.push(value); },
    setWindowLayoutFullScreen: async () => {}, setWindowSystemBarEnable: async () => {},
    on: (event, callback) => events.set(event, callback),
    off: (event, callback) => { assert.equal(events.get(event), callback); events.delete(event); }
  };
  const load = makePureEtsLoader({ gamecontrol: surfaces, '@kit.AbilityKit': {},
    '@kit.ArkUI': { window: { Orientation, getLastWindow: async () => win }, display: {
      getDisplayByIdSync: id => { assert.equal(id, 7); return currentDisplay; },
      getDefaultDisplaySync: () => { throw Error('必须读取游戏窗口所属屏幕'); }
    } }
  });
  const { MobileGameWindowCoordinator } = load('entry/src/main/ets/window/MobileGameWindowCoordinator.ets');
  return { coordinator: new MobileGameWindowCoordinator(), surfaces, geometry, layouts, gui,
    orientations, events, currentDisplay };
}

// 两侧横持进入均使用同一个受系统锁控制的双向横屏策略，退出恢复进入前的启动器策略。
for (const initialRotation of [1, 3]) {
  const f = fixture(initialRotation), notifications = [];
  const first = await f.coordinator.enter({});
  assert.deepEqual(f.orientations, [10], '游戏必须允许双向横屏并遵守系统旋转锁，不能放开四向旋转');
  assert.equal(first.transform, initialRotation);
  const displayChanged = pageDisplayCallback(f.coordinator, notifications);
  const store = f.surfaces.getInputSurfaceContextStore();
  const profile = f.layouts.getDefaultLayout();
  const project = () => f.geometry.projectRuntimeTouchLayout(profile,
    f.geometry.runtimeTouchContext(store.snapshot(), 1200, 540, 2),
    new f.gui.GameGuiState(), true, 0, new Map());
  let previous = project();
  const originalProfile = JSON.stringify(profile);
  // 不发 windowRectChange：180° 翻转不改变宽高，必须由真实页面 Display 回调更新代次。
  for (const nextRotation of [4 - initialRotation, initialRotation]) {
    f.currentDisplay.rotation = nextRotation;
    displayChanged(7);
    const notification = notifications.at(-1), next = project();
    assert.equal(notification.reason, 'display-change');
    assert.equal(notification.snapshot.transform, nextRotation);
    assert.ok(next.context.surfaceGeneration > previous.context.surfaceGeneration,
      '同尺寸翻转仍须更换输入身份，不能继续使用旧触点或旧控件发布资格');
    assert.notEqual(next.context.key, previous.context.key);
    assert.equal(next.context.transform, nextRotation);
    assert.equal(next.context.widthPx, 2400); assert.equal(next.context.heightPx, 1080);
    assert.ok(next.entries.length > 0);
    assert.deepEqual(next.entries.map(entry => [entry.item.id, entry.rectPx, entry.rectVp]),
      previous.entries.map(entry => [entry.item.id, entry.rectPx, entry.rectVp]),
      '系统已旋转窗口，控件仍使用窗口坐标，不能再次镜像或旋转按钮热区');
    const generation = next.context.surfaceGeneration;
    displayChanged(7);
    assert.equal(store.snapshot().generation, generation, '重复显示通知不应反复退休触点');
    previous = next;
  }
  assert.equal(JSON.stringify(profile), originalProfile, '翻转不得重写用户保存的虚拟按键布局');
  await f.coordinator.restore();
  assert.deepEqual(f.orientations, [10, 8]);
  assert.equal(f.events.size, 0, '离开游戏必须取消本窗口监听');
  assert.equal(store.snapshot().validFields, 0, '离开后旧窗口坐标不能继续接收输入');
  console.log(`PASS landscape ${initialRotation}: restricted policy, same-size 180-degree display publication, touch geometry and restore`);
}
