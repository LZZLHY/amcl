/** 执行真实跑马灯方法；原生动画边界提供可控实际帧，不用计时推算或复写拖动算法。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';

const source = fs.readFileSync(new URL('../entry/src/main/ets/components/MarqueeText.ets', import.meta.url), 'utf8');
const ast = compiler.createSourceFile('MarqueeText.ets', source, compiler.ScriptTarget.Latest, true);
const component = ast.statements.find(node => node.name?.text === 'MarqueeText');
assert.ok(component?.members);
const methods = component.members.filter(node => node.body && node.name?.text !== 'build')
  .map(node => source.slice(node.getStart(ast), node.end)).join('\n');
const code = compiler.transpileModule('class Probe {' + methods + '\n}\nmodule.exports=Probe;',
  { compilerOptions: { target: compiler.ScriptTarget.ES2022 } }).outputText;

/**
 * 无参数创建独立跑马灯Probe；所有资格、取消与free/anchored规则来自实际生产方法。
 * 时钟、原生Animator、测量及定时器是替身，timers/animators保留任务与帧接口，advance/reduced只改变系统输入。
 * 用例通过生产显隐/销毁方法核对取消与代次，不手动计算offset，也不把虚拟时间当设备掉帧证据。
 * 替身没有真实线程或定时器；各用例实例隔离，若验证销毁行为则须实际调用生命周期后检查注册集合。
 */
function fixture() {
  let now = 1000, reduced = false, next = 1;
  const timers = new Map(), animators = [];
  const module = { exports: {} };
  new Function('module', 'systemDateTime', 'UiMotion', 'TextOverflow', 'setTimeout', 'clearTimeout', code)(module,
    { TimeType: { ACTIVE: 1 }, getUptime: () => now }, { reduced: () => reduced },
    { None: 0 },
    (callback, delay) => { const id = next++; timers.set(id, { callback, delay }); return id; }, id => timers.delete(id));
  const subject = new module.exports();
  Object.assign(subject, { alive_: false, animationRunning_: false, animationGeneration_: 0,
    animation_: undefined, dragging_: false, resumeTimer_: 0, resumeRemaining_: 0,
    resumeDeadline_: 0, resumeGeneration_: 0, hostPageVisible: true, appInForeground: true,
    homeTabVisible: true, content: 'long version', contentW: 300, viewportW: 100, gapVp: 60,
    fontSize: 16, fontWeight: 400, pixelsPerSec: 60, resumeDelayMs: 2000, mode: 'auto', offsetX: 0,
    getUIContext: () => ({ getMeasureUtils: () => ({ measureTextSize: () => ({ width: 300 }) }), px2vp: value => value,
      createAnimator(options) { const animator = { options, plays: 0, cancels: 0,
        play() { this.plays++; }, cancel() { this.cancels++; } }; animators.push(animator); return animator; } }),
  });
  return { subject, animators, timers, advance: amount => { now += amount; }, reduced: value => { reduced = value; } };
}

test('只有存活/前台/宿主/首页同时成立才启动；不溢出、减少动画或非正速度没有空转任务', () => {
  for (const key of ['appInForeground', 'hostPageVisible', 'homeTabVisible']) {
    const f = fixture(); f.subject[key] = false; f.subject.aboutToAppear();
    assert.equal(f.animators.length, 0); f.subject[key] = true; f.subject.onVisibilityChange();
    assert.equal(f.animators.length, 1); f.subject[key] = false; f.subject.onVisibilityChange();
    assert.equal(f.animators[0].cancels, 1); assert.equal(f.timers.size, 0);
  }
  const fit = fixture(); fit.subject.viewportW = 500; fit.subject.aboutToAppear(); assert.equal(fit.animators.length, 0);
  const quiet = fixture(); quiet.reduced(true); quiet.subject.aboutToAppear(); assert.equal(quiet.animators.length, 0);
  const stopped = fixture(); stopped.subject.pixelsPerSec = 0; stopped.subject.aboutToAppear(); assert.equal(stopped.animators.length, 0);
});

test('手动接管以真正帧值为准，任意时钟/动画倍率不改变锚点，取消后的帧不能覆盖拖动', () => {
  const f = fixture(); f.subject.aboutToAppear(); const animator = f.animators[0];
  animator.onFrame(123); f.advance(60000); f.subject.handlePanStart();
  assert.equal(f.subject.panBaseOffset_, 123); assert.equal(f.subject.mode, 'anchored');
  f.subject.handlePanUpdate(-50); assert.equal(f.subject.offsetX, 173);
  animator.onFrame(359); assert.equal(f.subject.offsetX, 173);
  f.subject.handlePanUpdate(-1000); assert.equal(f.subject.offsetX, 200);
});

test('过渡区按下仍自由拖动，第一次触及自然窗口后边界约束和续播周期不变', () => {
  const f = fixture(); f.subject.aboutToAppear(); f.animators[0].onFrame(260); f.subject.handlePanStart();
  assert.equal(f.subject.mode, 'free'); f.subject.handlePanUpdate(-20); assert.equal(f.subject.offsetX, 280);
  f.subject.handlePanUpdate(100); assert.equal(f.subject.offsetX, 160); assert.equal(f.subject.mode, 'anchored');
  f.subject.handlePanUpdate(-1000); assert.equal(f.subject.offsetX, 200);
  f.subject.handlePanEnd(); const timer = f.timers.get(f.subject.resumeTimer_); assert.equal(timer.delay, 2000);
  timer.callback(); assert.equal(f.subject.mode, 'auto'); assert.equal(f.animators[1].options.begin, 200);
  assert.equal(f.animators[1].options.end, 560); assert.equal(f.animators[1].options.iterations, -1);
});

test('隐藏暂停用户等待，返回恢复剩余时间；旧定时器、旧帧和销毁不能重启动画', () => {
  const f = fixture(); f.subject.aboutToAppear(); f.subject.handlePanStart(); f.subject.handlePanEnd();
  const old = f.timers.get(f.subject.resumeTimer_); f.advance(750); f.subject.homeTabVisible = false; f.subject.onVisibilityChange();
  assert.equal(f.subject.resumeRemaining_, 1250); assert.equal(f.timers.size, 0);
  old.callback(); assert.notEqual(f.subject.mode, 'auto');
  f.subject.homeTabVisible = true; f.subject.onVisibilityChange();
  const resumed = f.timers.get(f.subject.resumeTimer_); assert.equal(resumed.delay, 1250);
  f.subject.aboutToDisappear(); resumed.callback(); f.animators[0].onFrame(100);
  assert.equal(f.subject.alive_, false); assert.equal(f.animators.length, 1); assert.equal(f.timers.size, 0);
});

test('手势被隐藏中断仍在返回后恢复，内容重测取消旧循环且未识别拖动不产生恢复计时器', () => {
  const f = fixture(); f.subject.aboutToAppear(); f.subject.handlePanStart();
  f.subject.hostPageVisible = false; f.subject.onVisibilityChange(); assert.equal(f.subject.dragging_, false);
  f.subject.hostPageVisible = true; f.subject.onVisibilityChange(); assert.equal(f.timers.size, 1);
  f.subject.onMeasureDepsChange(); assert.equal(f.subject.offsetX, 0); assert.equal(f.subject.mode, 'auto');
  assert.equal(f.timers.size, 0); f.subject.handlePanEnd(); assert.equal(f.timers.size, 0);
});
