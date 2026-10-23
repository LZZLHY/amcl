/**
 * 映射手柄模拟量稳定性回归。装载现役GamepadManager及其依赖，只有Native输出端口用记录器替代。
 * 覆盖阈值/八向迟滞、径向死区、双杆/双设备与数字+模拟贡献聚合，以及退休后的历史清理。
 * 所有转译和样本均在内存执行，只向stdout输出；不生成工程内文件，不代表实体型号已验。
 * 执行：node scripts/test-gamepad-analog-stability.mjs。
 */
import assert from 'node:assert/strict';
import { environment } from './lib/ets-runtime-fixture.mjs';

const prefix = 'gamecontrol/src/main/ets/';
let passed = 0;

/** 每场独立装载生产模块，避免上场的配置、设备桶或失败回执污染本场。 */
function fixture(configure = () => {}, shared = false, sourceOverrides = {}) {
  const env = environment({ sourceOverrides });
  const module = env.load(prefix + 'GamepadManager.ets');
  const config = env.load(prefix + 'ControlLayout.ets').defaultGamepadConfig();
  const keys = env.load(prefix + 'OhosKeyCodes.ets');
  configure(config);
  const events = [], looks = [];
  const emitter = {
    emitKey: (key, action) => { events.push(['key', key, action]); return true; },
    emitMouse: (button, action) => { events.push(['mouse', button, action]); return true; },
    emitScroll: direction => { events.push(['scroll', direction]); return true; },
    emitLookDelta: (x, y) => { looks.push([x, y]); return true; },
    ...(shared ? {
      lookExecutionMode: 'neutral-rate-v1',
      emitLookVelocity: (_device, _connection, x, y) => { looks.push([x, y]); return true; },
      advanceLookExecution: () => true,
      retireLookConnection: () => true,
    } : {}),
  };
  const manager = new module.GamepadManager(config, emitter);
  const frame = (values = {}, device = 7) => {
    manager.handleAxisForDevice(device, axis => values[axis] ?? 0);
    if (!shared) manager.advanceMappedLook(1 / 60);
  };
  const count = (kind, code, action) => events.filter(event =>
    event[0] === kind && event[1] === code && event[2] === action).length;
  return { manager, module, config, keys, events, looks, frame, count };
}

/** 只承认完整行为断言通过的场次，不以日志关键词代替结果。 */
function test(name, body) { body(); passed++; console.log('PASS ' + name); }
const near = (actual, expected) => assert.ok(Math.abs(actual - expected) < 1e-6, `${actual} != ${expected}`);
const magnitude = value => Math.hypot(...value);

test('analog-only trigger noise causes one press and releases on zero or invalid input', () => {
  for (const axisName of ['AXIS_ABS_GAS', 'AXIS_ABS_BRAKE']) {
    const f = fixture(), axis = f.module[axisName], mouse = axisName === 'AXIS_ABS_GAS';
    for (const value of [0.49, 0.51, 0.495, 0.505, 0.49, 0.51, 0.495, 0.505]) f.frame({ [axis]: value });
    assert.equal(f.count(mouse ? 'mouse' : 'key', mouse ? 0 : 81, 1), 1);
    assert.equal(f.count(mouse ? 'mouse' : 'key', mouse ? 0 : 81, 0), 0);
    f.frame({ [axis]: NaN });
    assert.equal(f.count(mouse ? 'mouse' : 'key', mouse ? 0 : 81, 0), 1);
    f.frame({ [axis]: 0 });
    assert.equal(f.count(mouse ? 'mouse' : 'key', mouse ? 0 : 81, 0), 1);
  }
});

test('move deadzone chatter preserves one press and center releases it', () => {
  const f = fixture(), y = f.module.AXIS_ABS_Y;
  for (const value of [-0.179, -0.181, -0.179, -0.182, -0.178, -0.181]) f.frame({ [y]: value });
  assert.equal(f.count('key', 87, 1), 1); assert.equal(f.count('key', 87, 0), 0);
  f.frame(); assert.equal(f.count('key', 87, 0), 1); assert.equal(f.manager.hasDeviceState(7), false);
});

test('true sector-boundary noise is stable but intentional turns and 0-degree wrap remain immediate', () => {
  const f = fixture(), x = f.module.AXIS_ABS_X, y = f.module.AXIS_ABS_Y;
  const angle = degrees => f.frame({ [x]: 0.8 * Math.cos(degrees * Math.PI / 180), [y]: 0.8 * Math.sin(degrees * Math.PI / 180) });
  for (const value of [292.1, 292.9, 292.1, 292.9]) angle(value);
  assert.equal(f.count('key', 87, 1), 1); assert.equal(f.count('key', 68, 1), 0);
  angle(300); assert.equal(f.count('key', 68, 1), 1);
  angle(292.9); assert.equal(f.count('key', 68, 0), 0);
  angle(288); assert.equal(f.count('key', 68, 0), 1);
  f.frame(); angle(359.5); angle(0.5); angle(359.5);
  assert.equal(f.count('key', 68, 1), 2); assert.equal(f.count('key', 68, 0), 1);
  f.frame(); assert.equal(f.count('key', 68, 0), 2);
});

test('equal-angle move vectors at different depths preserve the same diagonal', () => {
  const f = fixture(), x = f.module.AXIS_ABS_X, y = f.module.AXIS_ABS_Y;
  f.frame({ [x]: 0.3, [y]: -0.5 }); f.frame({ [x]: 0.6, [y]: -1 });
  assert.equal(f.count('key', 87, 1), 1); assert.equal(f.count('key', 68, 1), 1);
  assert.equal(f.count('key', 87, 0), 0); assert.equal(f.count('key', 68, 0), 0);
});

for (const shared of [false, true]) {
  test(`${shared ? 'shared Native rate' : 'legacy delta'} look preserves direction and normalizes circular/square gate speed`, () => {
    const f = fixture(() => {}, shared), x = f.module.AXIS_ABS_Z, y = f.module.AXIS_ABS_RZ;
    f.frame({ [x]: 0.5, [y]: 0.3 }); near(f.looks.at(-1)[1] / f.looks.at(-1)[0], 0.6);
    f.frame({ [x]: 0.6, [y]: 0.15 }); near(f.looks.at(-1)[1] / f.looks.at(-1)[0], 0.25);
    f.frame({ [x]: 1 }); const cardinal = magnitude(f.looks.at(-1));
    f.frame({ [x]: Math.SQRT1_2, [y]: Math.SQRT1_2 }); near(magnitude(f.looks.at(-1)) / cardinal, 1);
    f.frame({ [x]: 1, [y]: 1 }); near(magnitude(f.looks.at(-1)) / cardinal, 1);
    f.frame(); if (shared) assert.deepEqual(f.looks.at(-1), [0, 0]);
  });
}

test('zero deadzone and zero trigger threshold still accept positive movement and release at true zero', () => {
  const f = fixture(config => { config.stickDeadZone = 0; config.triggerThreshold = 0; });
  const x = f.module.AXIS_ABS_X, trigger = f.module.AXIS_ABS_GAS;
  f.frame(); assert.equal(f.events.length, 0);
  f.frame({ [x]: 0.00001, [trigger]: 0.00001 });
  assert.equal(f.count('key', 68, 1), 1); assert.equal(f.count('mouse', 0, 1), 1);
  f.frame(); assert.equal(f.count('key', 68, 0), 1); assert.equal(f.count('mouse', 0, 0), 1);
  assert.equal(f.manager.hasDeviceState(7), false);
});

test('digital trigger contribution does not prematurely lower analog entry and OR retains the final owner', () => {
  const f = fixture(), trigger = f.module.AXIS_ABS_GAS, key = f.keys.OHOS_BUTTON_R2;
  f.manager.handleButtonForDevice(7, key, true); f.frame({ [trigger]: 0.49 });
  f.manager.handleButtonForDevice(7, key, false); assert.equal(f.count('mouse', 0, 0), 1);
  f.frame({ [trigger]: 0.51 }); f.manager.handleButtonForDevice(7, key, true);
  f.frame({ [trigger]: 0.49 }); assert.equal(f.count('mouse', 0, 1), 2);
  f.frame(); assert.equal(f.count('mouse', 0, 0), 1);
  f.manager.handleButtonForDevice(7, key, false); assert.equal(f.count('mouse', 0, 0), 2);
});

test('two move sticks and two devices keep independent hysteresis and aggregate until final release', () => {
  const f = fixture(config => { config.rightStick = 'move'; });
  const x = f.module.AXIS_ABS_Z, y = f.module.AXIS_ABS_Y, trigger = f.module.AXIS_ABS_GAS;
  f.frame({ [y]: -0.181, [x]: 1, [trigger]: 0.51 }, 7);
  f.frame({ [y]: -0.181, [trigger]: 0.51 }, 8);
  f.frame({ [y]: -0.179, [x]: 1, [trigger]: 0.49 }, 7);
  f.frame({ [y]: -0.179, [trigger]: 0.49 }, 8);
  assert.equal(f.count('key', 87, 1), 1); assert.equal(f.count('mouse', 0, 1), 1);
  f.manager.releaseDevice(7);
  assert.equal(f.count('key', 87, 0), 0); assert.equal(f.count('key', 68, 0), 1);
  assert.equal(f.count('mouse', 0, 0), 0);
  f.frame({}, 8); assert.equal(f.count('key', 87, 0), 1); assert.equal(f.count('mouse', 0, 0), 1);
});

test('release, remove, disable, configuration and Native reset never lend old hysteresis to a new input', () => {
  for (const retire of ['release', 'remove', 'disable', 'configuration', 'reset']) {
    const f = fixture(), y = f.module.AXIS_ABS_Y, trigger = f.module.AXIS_ABS_GAS;
    f.frame({ [y]: -0.181, [trigger]: 0.51 });
    if (retire === 'release') f.manager.releaseAll();
    else if (retire === 'remove') f.manager.releaseDevice(7);
    else if (retire === 'reset') f.manager.dropHeldStateAfterNativeReset('test-reset');
    else {
      const config = { ...f.config, enabled: retire !== 'disable', lookScale: retire === 'configuration' ? 1.1 : 1 };
      assert.equal(f.manager.updateConfig(config), true);
      if (retire === 'disable') assert.equal(f.manager.updateConfig(f.config), true);
    }
    const keyPress = f.count('key', 87, 1), mousePress = f.count('mouse', 0, 1);
    f.frame({ [y]: -0.179, [trigger]: 0.49 });
    assert.equal(f.count('key', 87, 1), keyPress, retire + ': stale move hysteresis');
    assert.equal(f.count('mouse', 0, 1), mousePress, retire + ': stale trigger hysteresis');
    assert.equal(f.manager.hasDeviceState(7), false, retire + ': stale state');
  }
});

test('compiled removal of trigger hysteresis and radial speed cap fails actual behavior assertions', () => {
  const source = prefix + 'GamepadManager.ets';
  // 负向对照仅修改内存副本，并先确认命中真实正文；转译错误不能冒充行为检查发现回归。
  const replace = (text, before, after) => { assert.ok(text.includes(before), 'mutation anchor'); return text.replace(before, after); };
  const trigger = fixture(() => {}, false, { [source]: text => replace(text,
    '? value > GamepadManager.analogReleaseBoundary(threshold) : value >= threshold',
    '? value >= threshold : value >= threshold') });
  for (const value of [0.51, 0.49, 0.51, 0.49]) trigger.frame({ [trigger.module.AXIS_ABS_GAS]: value });
  assert.throws(() => assert.equal(trigger.count('mouse', 0, 1), 1), error => error.code === 'ERR_ASSERTION');
  const radial = fixture(() => {}, false, { [source]: text => replace(text,
    '(Math.min(radius, 1) - deadZone)', '(radius - deadZone)') });
  radial.frame({ [radial.module.AXIS_ABS_Z]: 1 }); const cardinal = magnitude(radial.looks.at(-1));
  radial.frame({ [radial.module.AXIS_ABS_Z]: 1, [radial.module.AXIS_ABS_RZ]: 1 });
  assert.throws(() => near(magnitude(radial.looks.at(-1)) / cardinal, 1), error => error.code === 'ERR_ASSERTION');
});

console.log(`PASS mapped gamepad analog stability: ${passed} scenarios; physical devices and model-specific axes unverified`);
