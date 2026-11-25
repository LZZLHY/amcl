/** 执行真实的版本行组件和帧控制，只用宿主接收器代替 ArkUI 的可见性与绘制。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { actionUiReceiver, loadActionComponent } from './lib/unified-actions-fixture.mjs';

const rowModule = makePureEtsLoader({ '@kit.ArkUI': { FrameCallback: class {} } })(
  'entry/src/main/ets/components/VersionDownloadRows.ets');

function rowFixture() {
  const ui = actionUiReceiver(), frames = [], animations = [];
  const facts = { reduced: false, stage: true, allowed: true, seen: false, checks: 0, clicks: 0 };
  const Row = loadActionComponent('entry/src/main/ets/components/VersionScrollEntrance.ets', 'VersionScrollEntrance', {
    render: true, globals: { ...ui.globals, Curve: { EaseOut: 'easeOut' } },
    dependencies: { './VersionDownloadRows': rowModule, './UiMotion': { UiMotion: { reduced: () => facts.reduced } } }
  });
  const view = new Row();
  Object.assign(view, {
    shouldStage: () => facts.stage && !facts.seen,
    onFirstVisible() {
      facts.checks++;
      const first = !facts.seen;
      facts.seen = true;
      return facts.allowed && first;
    },
    content: () => { ui.globals.Button().onClick(() => facts.clicks++); },
    getUIContext: () => ({
      postFrameCallback(frame) { frames.push(frame); },
      animateTo(options, update) { animations.push(options); update(); }
    })
  });
  view.aboutToAppear(); view.build();
  const trigger = ui.records.find(record => record.modifiers.onVisibleAreaChange).modifiers.onVisibleAreaChange;
  assert.equal(trigger[0].includes(0), true);
  return { facts, view, frames, animations, visible: (ratio) => trigger[1](ratio > 0, ratio),
    click: () => ui.records.find(record => record.type === 'Button').modifiers.onClick[0]() };
}

test('预加载不消费版本身份，首帧可点击；真正露出才获得一次轻微入场，回看呈现最终状态', () => {
  const f = rowFixture();
  assert.equal(f.facts.checks, 0); assert.equal(f.view.staged_, true);
  f.click(); assert.equal(f.facts.clicks, 1);
  f.visible(0); assert.equal(f.facts.checks, 0); assert.equal(f.frames.length, 0);
  f.visible(0.03); f.visible(0.7);
  assert.equal(f.facts.checks, 1); assert.equal(f.frames.length, 1);
  f.frames.shift().onIdle(2);
  assert.equal(f.animations.length, 1); assert.equal(f.view.staged_, false);
  f.visible(0); f.visible(0.5); assert.equal(f.frames.length, 0); assert.equal(f.view.staged_, false);
});

test('快速滑出或卸载会取消未放行的行；整组切换和减少动效仍可浏览', () => {
  for (const leave of [f => f.visible(0), f => f.view.aboutToDisappear()]) {
    const f = rowFixture();
    f.visible(0.2); const first = f.frames.shift(); first.onFrame(0);
    leave(f); f.frames.shift().onFrame(16_670_000); first.onIdle(2);
    assert.equal(f.animations.length, 0); assert.equal(f.view.staged_, false);
  }
  for (const update of [f => { f.facts.allowed = false; }, f => { f.facts.reduced = true; }]) {
    const f = rowFixture(); update(f); f.visible(0.8);
    assert.equal(f.frames.length, 0); assert.equal(f.view.staged_, false);
    f.click(); assert.equal(f.facts.clicks, 1);
  }
});
