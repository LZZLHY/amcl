/**
 * 悬浮鼠标C1交互回归：直接执行生产模型与Entry接线，只替换真实Native边缘。
 * 覆盖两种落指顺序、移动权重锚、单指随指/多指稳位、靠边钳制和reset回执围栏。
 * 本脚本不复制摆位或owner算法；端口记录证明到达接线边界，不代表游戏消费或真人手感。
 */
import assert from 'node:assert/strict';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const { VirtualMouseModel } = makePureEtsLoader()('gamecontrol/src/main/ets/VirtualMouseModel.ets');
let checks = 0;

/** 每项回放隔离模型、输出与失败开关，防止前一接触的余量或持有污染下一项。 */
function fixture(options = {}) {
  const moves = [], wheels = [], edges = [];
  const native = {
    moveTouchMenuPointer: (dx, dy) => { moves.push([dx, dy]); return options.acceptMove?.(dx, dy) ?? true; },
    touchMenuScroll: steps => { wheels.push(steps); return true; },
    touchMenuButton: (owner, code, down) => { edges.push([owner, code, down]); return options.button?.(owner, code, down) ?? true; },
    cancelTouchMenuMouse: () => options.cancel?.() ?? true,
    setTouchMenuMouseBounds: () => true,
  };
  const load = makePureEtsLoader({ commons: { AppLogger: { warn() {} } },
    gamecontrol: { VirtualMouseModel }, 'libentry.so': { __esModule: true, default: native } });
  const { EntryVirtualMouse } = load('entry/src/main/ets/components/EntryVirtualMouse.ets');
  const entry = new EntryVirtualMouse();
  entry.configure(true, options.density ?? 1);
  return { model: entry.model, entry, moves, wheels, edges };
}

/** 统一输出独立场景名称，断言失败立即停止，不把部分通过打印成完整通过。 */
function check(name, run) { run(); checks++; console.log('PASS ' + name); }

/** 只提取可见几何便于比较；compact也属于冻结合同，不只比较左上角。 */
function geometry(frame) { return [frame.x, frame.y, frame.width, frame.height, frame.compact]; }

check('左右键单指即按即拖，本体raw vp 1:1而Entry只乘一次density', () => {
  for (const [part, code] of [['left', -1], ['right', -2], ['move', 0]]) {
    const f = fixture({ density: 2 });
    const initial = f.model.frame(500, 300, 800, 600);
    assert.equal(f.model.beginContact(1, part, 550, 350, 101), true);
    assert.equal(f.model.moveContact(1, 565, 340, 101), true);
    const next = f.model.frame(799, 599, 800, 600);
    assert.deepEqual([next.x - initial.x, next.y - initial.y], [15, -10]);
    assert.deepEqual(f.moves, [[30, -20]], '本体不乘density，Native位移仍沿原Entry边界换算');
    assert.equal(f.model.down(code), code !== 0);
    f.model.endContact(1, 101);
    assert.equal(f.model.down(code), false);
    assert.deepEqual(f.edges.map(e => [e[1], e[2]]), code === 0 ? [] : [[code, true], [code, false]]);
  }
});

check('按键先落或移动先落均由显式move控制，按键owner保持独立', () => {
  for (const buttonFirst of [true, false]) {
    const f = fixture();
    const key = () => f.model.beginContact(1, 'left', 100, 100, 1);
    const pad = () => f.model.beginContact(2, 'move', 200, 200, 2);
    assert.equal(buttonFirst ? key() : pad(), true);
    assert.equal(buttonFirst ? pad() : key(), true);
    assert.equal(f.model.moveContact(1, 140, 145, 1), false);
    assert.equal(f.model.moveContact(2, 207, 211, 2), true);
    assert.deepEqual(f.moves, [[7, 11]]);
    assert.equal(f.model.down(-1), true);
    f.model.endContact(2, 2);
    assert.equal(f.model.down(-1), true, '抬移动指不释放另一按键指');
    f.model.moveContact(1, 143, 149, 1);
    assert.deepEqual(f.moves, [[7, 11], [3, 4]], '回到按键指时不追补其等待期间的40/45vp');
    f.model.endContact(1, 1);
    assert.deepEqual(f.edges.map(e => e[2]), [true, false]);
  }
});

check('移动指反复抬落保持按键，新基线不继承旧位置或等待位移', () => {
  const f = fixture();
  f.model.beginContact(1, 'right', 100, 100, 1);
  for (let round = 0; round < 3; round++) {
    const origin = 300 + round * 100;
    assert.equal(f.model.beginContact(2, 'move', origin, origin, 20 + round), true);
    f.model.moveContact(2, origin + 9, origin - 2, 20 + round);
    f.model.endContact(2, 20 + round);
    assert.equal(f.model.down(-2), true);
  }
  assert.deepEqual(f.moves, [[9, -2], [9, -2], [9, -2]]);
  f.model.endContact(1, 1);
  assert.deepEqual(f.edges.map(e => [e[1], e[2]]), [[-2, true], [-2, false]]);
});

check('多个move指按稳定次序接续，不抢现owner且不回放等待行程', () => {
  const f = fixture();
  f.model.beginContact(1, 'move', 10, 10, 1);
  f.model.beginContact(2, 'move', 100, 100, 2);
  assert.equal(f.model.moveContact(2, 200, 200, 2), false);
  f.model.moveContact(1, 12, 13, 1);
  f.model.endContact(1, 1);
  f.model.moveContact(2, 202, 203, 2);
  assert.deepEqual(f.moves, [[2, 3], [2, 3]]);
});

check('publication等待只拒新意图，已有两指可交接并完成原按键', () => {
  const f = fixture();
  f.model.beginContact(1, 'left', 10, 10, 1);
  f.model.beginContact(2, 'move', 100, 100, 2);
  f.entry.configure(true, 1, false);
  assert.equal(f.model.beginContact(3, 'move', 200, 200, 3), false);
  assert.equal(f.model.toggle(340), false);
  f.model.moveContact(1, 30, 30, 1);
  f.model.endContact(2, 2);
  assert.equal(f.model.moveContact(1, 33, 34, 1), true);
  assert.deepEqual(f.moves, [[3, 4]]);
  f.model.endContact(1, 1);
  assert.equal(f.model.activeContacts(), false);
  assert.equal(f.model.down(-1), false);
});

check('第二触点接受后本轮稳位，抬成单指和移动指重新落下也不解冻', () => {
  const f = fixture();
  f.model.frame(300, 200, 800, 600);
  f.model.beginContact(1, 'left', 350, 250, 1);
  f.model.moveContact(1, 360, 260, 1);
  const before = geometry(f.model.frame(400, 300, 800, 600));
  f.model.beginContact(2, 'move', 400, 350, 2);
  f.model.moveContact(2, 450, 370, 2);
  assert.deepEqual(geometry(f.model.frame(650, 500, 800, 600)), before);
  f.model.endContact(2, 2);
  f.model.moveContact(1, 375, 280, 1);
  assert.deepEqual(geometry(f.model.frame(799, 599, 800, 600)), before);
  f.model.beginContact(2, 'move', 100, 100, 3);
  f.model.moveContact(2, 120, 100, 3);
  f.model.endContact(1, 1);
  assert.deepEqual(geometry(f.model.frame(799, 599, 800, 600)), before);
  f.model.endContact(2, 3);
  assert.notDeepEqual(geometry(f.model.frame(799, 599, 800, 600)), before, '最后抬手才允许重新择侧');
});

check('wheel单指本体保持原位，滚轮与按键协作同样冻结', () => {
  const f = fixture();
  const before = geometry(f.model.frame(300, 200, 800, 600));
  f.model.beginContact(1, 'wheel', 400, 300, 1);
  f.model.moveContact(1, 400, 324, 1);
  assert.deepEqual(f.wheels, [2]);
  assert.deepEqual(geometry(f.model.frame(799, 599, 800, 600)), before);
  f.model.beginContact(2, 'left', 350, 250, 2);
  f.model.endContact(1, 1);
  f.model.moveContact(2, 370, 270, 2);
  assert.deepEqual(geometry(f.model.frame(799, 599, 800, 600)), before);
});

check('活动期靠边仅clamp，反向立即离边，不因指针跨阈值换侧', () => {
  const f = fixture();
  f.model.frame(600, 350, 800, 600);
  f.model.beginContact(1, 'right', 650, 400, 1);
  f.model.moveContact(1, 750, 500, 1);
  assert.deepEqual(geometry(f.model.frame(615, 357, 800, 600)).slice(0, 2), [640, 384]);
  assert.deepEqual(geometry(f.model.frame(616, 358, 800, 600)).slice(0, 2), [640, 384]);
  f.model.moveContact(1, 740, 490, 1);
  assert.deepEqual(geometry(f.model.frame(799, 599, 800, 600)).slice(0, 2), [630, 374]);
  assert.deepEqual(f.moves, [[100, 100], [-10, -10]], '边缘不钳制或回写游戏指针位移');
  f.model.endContact(1, 1);
  assert.deepEqual(geometry(f.model.frame(799, 599, 800, 600)).slice(0, 2), [623, 363]);
});

check('空闲择侧8vp空间滞回防抖，同输入反复读取不改变本体', () => {
  const f = fixture();
  const initial = f.model.frame(616, 200, 800, 600);
  const one = f.model.frame(617, 200, 800, 600);
  assert.deepEqual([initial.x, one.x], [640, 640]);
  assert.equal(f.model.frame(625, 200, 800, 600).x, 449, '超出8vp才从右侧换到左侧');
  assert.equal(f.model.frame(615, 200, 800, 600).x, 439, '刚回到可放右侧临界点仍保持左侧');
  const settled = geometry(f.model.frame(607, 200, 800, 600));
  assert.equal(settled[0], 631, '右侧余量超过8vp才换回');
  for (let i = 0; i < 20; i++) assert.deepEqual(geometry(f.model.frame(607, 200, 800, 600)), settled);
});

check('活动期视口缩小只约束范围，compact切档等全部抬手再应用', () => {
  const f = fixture();
  f.model.frame(300, 200, 800, 600);
  f.model.beginContact(1, 'move', 350, 250, 1);
  let frame = f.model.frame(300, 200, 700, 420);
  assert.deepEqual([frame.width, frame.height, frame.compact], [152, 208, false]);
  assert.ok(frame.x + frame.width <= 700 && frame.y + frame.height <= 420);
  f.model.endContact(1, 1);
  frame = f.model.frame(300, 200, 700, 420);
  assert.deepEqual([frame.width, frame.height, frame.compact], [136, 152, true]);
  f.model.beginContact(2, 'left', 300, 200, 2);
  frame = f.model.frame(0, 0, 50, 40);
  assert.ok(frame.x >= 0 && frame.y >= 0 && frame.x + frame.width <= 50 && frame.y + frame.height <= 40);
});

check('非法投影为空，外部修改快照不污染内部摆位，拒收MOVE不追补', () => {
  const f = fixture({ acceptMove: () => false });
  const initial = f.model.frame(300, 200, 800, 600);
  const expected = geometry(initial);
  initial.x = -999; initial.width = 9999;
  assert.deepEqual(geometry(f.model.frame(300, 200, 800, 600)), expected);
  for (const args of [[NaN, 0, 800, 600], [0, 0, 0, 600], [0, 0, 800, Infinity]]) {
    const empty = f.model.frame(...args); assert.deepEqual([empty.width, empty.height], [0, 0]);
  }
  f.model.beginContact(1, 'left', 100, 100, 1);
  assert.equal(f.model.moveContact(1, Infinity, 110, 1), false);
  f.model.moveContact(1, 120, 130, 1); f.model.moveContact(1, 123, 134, 1);
  assert.deepEqual(f.moves, [[20, 30], [3, 4]]);
  const frame = f.model.frame(0, 0, 800, 600);
  assert.deepEqual([frame.x - expected[0], frame.y - expected[1]], [23, 34]);
});

check('DOWN端口拒收不启动几何会话或抢走已有movement owner', () => {
  const f = fixture({ button: () => false });
  f.model.frame(300, 200, 800, 600);
  f.model.beginContact(1, 'move', 100, 100, 1);
  assert.equal(f.model.beginContact(2, 'left', 200, 200, 2), false);
  assert.equal(f.model.activeContacts(), true); assert.equal(f.model.hasContact(2, 2), false);
  f.model.moveContact(1, 110, 112, 1);
  const frame = f.model.frame(799, 599, 800, 600);
  assert.deepEqual([frame.x, frame.y], [334, 240], '失败的第二触点不能触发协作冻结');
});

check('reset中复用同finger编号时，旧DOWN回执不能覆盖新接触或新held', () => {
  let f, reentered = false;
  f = fixture({ button: (_owner, _code, down) => {
    if (down && !reentered) {
      reentered = true; f.model.acknowledgeReset();
      assert.equal(f.model.beginContact(1, 'left', 300, 300, 200), true);
    }
    return true;
  } });
  assert.equal(f.model.beginContact(1, 'left', 100, 100, 100), false);
  assert.equal(f.model.hasContact(1, 100), false); assert.equal(f.model.hasContact(1, 200), true);
  assert.equal(f.model.down(-1), true);
  assert.equal(f.model.moveContact(1, 900, 900, 100), false);
  f.model.moveContact(1, 305, 306, 200);
  assert.deepEqual(f.moves, [[5, 6]]);
  f.model.endContact(1, 200); assert.equal(f.model.down(-1), false);
  assert.equal(f.edges.at(-1)[0], f.edges[1][0]);
});

check('旧UP回执不能删除同步reset后的同owner新按下', () => {
  let f, reentered = false;
  f = fixture({ button: (_owner, _code, down) => {
    if (!down && !reentered) {
      reentered = true; f.model.acknowledgeReset();
      assert.equal(f.model.beginContact(1, 'right', 300, 300, 200), true);
    }
    return true;
  } });
  f.model.beginContact(1, 'left', 100, 100, 100);
  f.model.endContact(1, 100);
  assert.equal(f.model.hasContact(1, 200), true);
  assert.equal(f.model.down(-2), true); assert.equal(f.model.down(-1), false);
  f.model.endContact(1, 200); assert.equal(f.model.down(-2), false);
});

check('同owner端口同步重入不重复发DOWN，取消失败稳位并保留重试义务', () => {
  let f, allowCancel = false, reentered = false;
  f = fixture({ button: (_owner, _code, down) => {
    if (down && !reentered) { reentered = true; assert.equal(f.model.beginContact(1, 'left', 100, 100, 1), false); }
    return true;
  }, cancel: () => allowCancel });
  f.model.frame(300, 200, 800, 600);
  assert.equal(f.model.beginContact(1, 'left', 100, 100, 1), true);
  f.model.moveContact(1, 110, 112, 1);
  const before = geometry(f.model.frame(310, 212, 800, 600));
  assert.equal(f.edges.length, 1);
  assert.equal(f.model.cancelAll(), false);
  assert.equal(f.model.down(-1), true); assert.equal(f.model.isCancellationPending(), true);
  assert.deepEqual(geometry(f.model.frame(799, 599, 800, 600)), before);
  assert.equal(f.model.beginContact(2, 'move', 200, 200, 2), false);
  assert.equal(f.model.moveContact(1, 200, 200, 1), false);
  allowCancel = true; assert.equal(f.model.cancelAll(), true);
  assert.equal(f.model.activeContacts(), false); assert.equal(f.model.down(-1), false);
  assert.notDeepEqual(geometry(f.model.frame(799, 599, 800, 600)), before);
  assert.equal(f.model.beginContact(1, 'right', 300, 300, 200), true);
});

check('未确认按键期间其他已接受触点抬起，不把pending占位当几何活动轮次', () => {
  let f;
  f = fixture({ button: (_owner, _code, down) => {
    if (down) {
      assert.equal(f.model.beginContact(2, 'move', 200, 200, 2), true);
      f.model.endContact(2, 2);
    }
    return false;
  } });
  const before = geometry(f.model.frame(300, 200, 800, 600));
  assert.equal(f.model.beginContact(1, 'left', 100, 100, 1), false);
  assert.equal(f.model.activeContacts(), false);
  assert.notDeepEqual(geometry(f.model.frame(799, 599, 800, 600)), before, '没有accepted触点时必须回到空闲择位');
});

check('旧cancel确认不能清掉端口同步reset后已经接受的新一轮触点', () => {
  let f;
  f = fixture({ cancel: () => {
    f.model.acknowledgeReset();
    assert.equal(f.model.beginContact(2, 'right', 200, 200, 2), true);
    return true;
  } });
  f.model.beginContact(1, 'left', 100, 100, 1);
  assert.equal(f.model.cancelAll(), true);
  assert.equal(f.model.hasContact(1, 1), false);
  assert.equal(f.model.hasContact(2, 2), true, '旧取消回执只能确认原轮次，不能重复ack新轮次');
  assert.equal(f.model.down(-2), true);
  f.model.moveContact(2, 203, 204, 2);
  assert.deepEqual(f.moves, [[3, 4]]);
});

console.log(`[virtual-mouse-interaction] PASS ${checks} production model/Entry scenarios; device feel remains unmeasured`);
