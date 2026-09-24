/*
 * ProbeRegistry.test.ets — native 探针注册表纯模型层的单测（批次 D4）
 *
 * 覆盖：形状声明与运行体的一致性校验、纯分派对四种形状的处理、无 UI 入口清单。
 *
 * 为什么能测（契约 §8.3.1）：模型层不 import `libentry.so`，
 * 运行体是普通函数 ⇒ 这里直接喂假探针。绑定层（NativeProbeRegistry.ets）
 * 才碰 NAPI，那一半只能靠真机。
 *
 * 创建日期：2026-09-07
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  NativeProbeDef,
  ProbeOutcome,
  ProbeShape,
  findProbe,
  probesWithoutUiEntry,
  runProbe,
  validateProbeDef,
  validateProbeRegistry,
} from '../main/ets/devtools/ProbeRegistryModel';

/** ArkTS 禁止无类型对象字面量（arkts-no-untyped-obj-literals）⇒ 假的 JSON 载荷也要有类型。 */
interface FakeCapability {
  a: number;
}

function textProbe(id: string, hasUiEntry: boolean = true): NativeProbeDef {
  return {
    id, title: id, shape: ProbeShape.SYNC_TEXT, hasUiEntry, needsFilesDir: false,
    runSyncText: (filesDir: string) => `ran ${id} in ${filesDir}`,
  };
}

export default function probeRegistryTest() {
  describe('ProbeRegistryModel', () => {

    it('正向：四种形状各自跑通并整形成 ProbeOutcome', 0, async () => {
      const sync: ProbeOutcome = await runProbe(textProbe('t'), '/files');
      expect(sync.ok).assertTrue();
      expect(sync.text).assertEqual('ran t in /files');
      expect(sync.code === null).assertTrue();

      const code: ProbeOutcome = await runProbe({
        id: 'c', title: 'c', shape: ProbeShape.SYNC_CODE, hasUiEntry: false, needsFilesDir: false,
        runSyncCode: () => 0,
      }, '/files');
      expect(code.ok).assertTrue();
      expect(code.code).assertEqual(0);

      const capability: FakeCapability = { a: 1 };
      const json: ProbeOutcome = await runProbe({
        id: 'j', title: 'j', shape: ProbeShape.ASYNC_JSON, hasUiEntry: false, needsFilesDir: false,
        runAsyncJson: () => Promise.resolve(capability as object),
      }, '/files');
      expect(json.ok).assertTrue();
      expect(json.text).assertEqual('{"a":1}');

      const cb: ProbeOutcome = await runProbe({
        id: 'k', title: 'k', shape: ProbeShape.CALLBACK_TEXT, hasUiEntry: false, needsFilesDir: true,
        runCallbackText: (filesDir: string, done: (text: string) => void) => { done('done ' + filesDir); },
      }, '/files');
      expect(cb.ok).assertTrue();
      expect(cb.text).assertEqual('done /files');
    });

    it('⭐ 返回码不得被裹成文本：code 单独成字段，非 0 即 ok=false', 0, async () => {
      // "不为统一签名而包装"的可执行形态：若把 () => number 裹成 () => string，
      // 数字 0 与字符串 "0" 的区别就没了，而调用方要判的正是"是不是 0"。
      const bad: ProbeOutcome = await runProbe({
        id: 'c', title: 'c', shape: ProbeShape.SYNC_CODE, hasUiEntry: false, needsFilesDir: false,
        runSyncCode: () => 3,
      }, '/files');
      expect(bad.code).assertEqual(3);
      expect(bad.ok).assertFalse();
      expect(typeof bad.code === 'number').assertTrue();
    });

    it('反向：声明的形状与提供的运行体不一致必须被抓到', 0, () => {
      const issues: string[] = validateProbeDef({
        id: 'x', title: 'x', shape: ProbeShape.SYNC_TEXT, hasUiEntry: true, needsFilesDir: false,
        runSyncCode: () => 0,
      });
      expect(issues.length > 0).assertTrue();
      expect(issues[0].indexOf('provides a') >= 0).assertTrue();
    });

    it('反向：一条声明提供两个运行体必须被抓到（另一条永远跑不到）', 0, () => {
      const issues: string[] = validateProbeDef({
        id: 'x', title: 'x', shape: ProbeShape.SYNC_TEXT, hasUiEntry: true, needsFilesDir: false,
        runSyncText: (_f: string) => 'a',
        runSyncCode: () => 0,
      });
      expect(issues.some((i: string) => i.indexOf('exactly one is allowed') >= 0)).assertTrue();
    });

    it('反向：一个运行体都没有必须被抓到', 0, () => {
      const issues: string[] = validateProbeDef({
        id: 'x', title: 'x', shape: ProbeShape.SYNC_TEXT, hasUiEntry: true, needsFilesDir: false,
      });
      expect(issues.some((i: string) => i.indexOf('provides no runner') >= 0)).assertTrue();
    });

    it('反向：错配的声明不会被跑，而是原样报回来', 0, async () => {
      // 分派器**不**替它挑一个能跑的运行体 —— 那会把一条声明错误变成静默的行为差异。
      const outcome: ProbeOutcome = await runProbe({
        id: 'x', title: 'x', shape: ProbeShape.ASYNC_JSON, hasUiEntry: true, needsFilesDir: false,
        runSyncText: (_f: string) => 'should not run',
      }, '/files');
      expect(outcome.ok).assertFalse();
      expect(outcome.text).assertEqual('');
      expect(outcome.error !== null).assertTrue();
    });

    it('探针抛异常 → ok=false 且带 error，不向上抛', 0, async () => {
      // 探针抛异常是**探针的结果**，不是分派器的失败：向上抛会让一次失败的探针
      // 看起来像"工具坏了"（契约 §8.4 里 FAIL 与 BLOCKED 的同型区分）。
      const outcome: ProbeOutcome = await runProbe({
        id: 'boom', title: 'boom', shape: ProbeShape.SYNC_TEXT, hasUiEntry: true, needsFilesDir: false,
        runSyncText: (_f: string) => { throw new Error('probe exploded'); },
      }, '/files');
      expect(outcome.ok).assertFalse();
      expect(outcome.error).assertEqual('probe exploded');
    });

    it('反向：重复 id 必须被抓到', 0, () => {
      const issues: string[] = validateProbeRegistry([textProbe('dup'), textProbe('dup')]);
      expect(issues.some((i: string) => i.indexOf('duplicate probe id') >= 0)).assertTrue();
    });

    it('findProbe 找不到时返回 null（不抛、不猜）', 0, () => {
      const defs: NativeProbeDef[] = [textProbe('a'), textProbe('b')];
      expect(findProbe(defs, 'b')!.id).assertEqual('b');
      expect(findProbe(defs, 'nope')).assertNull();
    });

    it('probesWithoutUiEntry 列出契约 §3.10 那批', 0, () => {
      const defs: NativeProbeDef[] = [textProbe('withUi', true), textProbe('noUi', false)];
      const hidden: string[] = probesWithoutUiEntry(defs);
      expect(hidden.length).assertEqual(1);
      expect(hidden[0]).assertEqual('noUi');
    });
  });
}
