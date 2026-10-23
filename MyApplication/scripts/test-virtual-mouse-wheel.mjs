/**
 * 悬浮鼠标滚轮的生产模型与Entry接线组合回归。
 * 直接执行两层生产类，只将Native边缘替换为可拒收、记录已接受包的端口；不复制滚轮算法。
 * 覆盖采样合并保真、方向、部分拒收、接触结束与取消，不能代替设备或游戏消费验收。
 */
import assert from 'node:assert/strict';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const { VirtualMouseModel } = makePureEtsLoader()('gamecontrol/src/main/ets/VirtualMouseModel.ets');

/** 每个夹具有独立面板和已接受输出；失败包不计为已交付，不伪造Native成功。 */
function fixture(rejectCall = 0, acceptedCallback = () => {}) {
  const packets = [];
  let calls = 0;
  const native = {
    moveTouchMenuPointer: () => true,
    touchMenuButton: () => true,
    cancelTouchMenuMouse: () => true,
    setTouchMenuMouseBounds: () => true,
    touchMenuScroll: steps => {
      assert.ok(Number.isInteger(steps) && steps !== 0 && Math.abs(steps) <= 32,
        '每笔真实端口请求必须满足既有Native32格上限，不能靠出口静默截断');
      if (++calls === rejectCall) return false;
      packets.push(steps);
      acceptedCallback(steps, calls);
      return true;
    },
  };
  const load = makePureEtsLoader({ commons: { AppLogger: { warn() {} } },
    gamecontrol: { VirtualMouseModel }, 'libentry.so': { __esModule: true, default: native } });
  const { EntryVirtualMouse } = load('entry/src/main/ets/components/EntryVirtualMouse.ets');
  const entry = new EntryVirtualMouse();
  entry.configure(true, 1);
  assert.equal(entry.model.beginContact(1, 'wheel', 0, 0), true);
  return { model: entry.model, packets, total: () => packets.reduce((a, b) => a + b, 0) };
}

// 端口同步回入时，原循环只能确认原包；同编号新接触不能被旧扣量污染。
{
  let f;
  f = fixture(0, (_steps, calls) => {
    if (calls !== 1) return;
    f.model.endContact(1);
    assert.equal(f.model.beginContact(1, 'wheel', 0, 0, 20), true);
  });
  f.model.moveContact(1, 0, 600);
  assert.deepEqual(f.packets, [32]);
  f.model.moveContact(1, 0, 12, 20);
  assert.deepEqual(f.packets, [32, 1]);
}

// 同接触在途新增MOVE只累计一次；禁止先多滚再反向补偿，列表边界下两者不等价。
{
  let f;
  f = fixture(0, (_steps, calls) => { if (calls === 1) f.model.moveContact(1, 0, 876); });
  f.model.moveContact(1, 0, 600);
  assert.deepEqual(f.packets, [32, 32, 9]);
  assert.equal(f.total(), 73);
}

// 同一长行程在单个合并样本和多个小样本下，必须产生相同已接受格数。
for (const direction of [1, -1]) {
  const merged = fixture(), split = fixture();
  merged.model.moveContact(1, 0, direction * 600);
  for (let y = 12; y <= 600; y += 12) split.model.moveContact(1, 0, direction * y);
  assert.deepEqual(merged.packets, [direction * 32, direction * 18]);
  assert.equal(merged.total(), direction * 50);
  assert.equal(merged.total(), split.total());
  merged.model.endContact(1); split.model.endContact(1);
}

// 已接受32格、随后18格被拒时，只保留未接受行程；下一真实MOVE可继续，不重发前32格。
{
  const f = fixture(2);
  f.model.moveContact(1, 0, 600);
  assert.equal(f.total(), 32);
  f.model.moveContact(1, 0, 612);
  assert.deepEqual(f.packets, [32, 19]);
  assert.equal(f.total(), 51);
}

// UP与取消都不自动续滚；即使旧包拒收或有不足一格余量，也不能带进新接触。
for (const cancelled of [false, true]) {
  const f = fixture(2);
  f.model.moveContact(1, 0, 607);
  if (cancelled) assert.equal(f.model.cancelAll(), true);
  else f.model.endContact(1);
  assert.equal(f.total(), 32);
  assert.equal(f.model.beginContact(2, 'wheel', 0, 0), true);
  f.model.moveContact(2, 0, 11);
  assert.equal(f.total(), 32);
  f.model.moveContact(2, 0, 12);
  assert.equal(f.total(), 33);
}

// 小幅位移保持余量；无效坐标不污染有效基线，也不能触发失控循环。
{
  const f = fixture();
  for (const bad of [NaN, Infinity, -Infinity, Number.MAX_VALUE]) {
    assert.equal(f.model.moveContact(1, 0, bad), false);
  }
  f.model.moveContact(1, 0, 7);
  assert.equal(f.total(), 0);
  f.model.moveContact(1, 0, 13);
  assert.equal(f.total(), 1);
  assert.equal(f.model.moveContact(99, 0, 600), false);
  assert.equal(f.total(), 1);
  f.model.endContact(1);
  assert.equal(f.model.beginContact(2, 'wheel', 0, Number.MAX_VALUE), false);
  f.model.startWheel(2, Number.MAX_VALUE);
  assert.equal(f.model.beginContact(2, 'wheel', 0, 0), true);
  f.model.moveContact(2, 0, 12);
  assert.equal(f.total(), 2, '异常DOWN不得占用滚轮或污染后续合法基线');
}
console.log('[virtual-mouse-wheel] PASS merged/split direction, partial rejection, UP/CANCEL and numeric boundaries');
