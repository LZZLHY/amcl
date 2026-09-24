/**
 * PhysicalKeyEdge.test.ets — 物理键边沿判定 + ESC 去抖判据（提案 D1 / 计划 §66）
 *
 * 钉住的核心是**链路⑤「shift+左键取整组」的真实安全边界**，而它很反直觉：
 * ArkTS 算出的 `mods` 到不了 MC（GLFW 自己从 `win->keys[]` 现算）。让修饰键成立的是
 * Shift 的首个 DOWN 确实以 PRESS 抵达 native。所以 repeat 分类一错 ⇒ core 不新增
 * owner ⇒ **修饰键静默失效**（不报错、不卡键，只是 shift+左键不再取整组）。
 *
 * 本文件是纯判定覆盖：不驱动 ArkUI、不碰 NAPI，不能替代真机的 shift+左键复测。
 *
 * 创建日期：2026-08-21
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  decidePhysicalKeyEdge, shouldSuppressBackPressAfterEsc, shouldRefillChar,
  PhysicalKeyEdgeActions, PHYSICAL_KEY_EDGE_NONE,
  SHADOW_KEY_DOWN, SHADOW_KEY_REPEAT, SHADOW_KEY_UP,
  resolvePhysicalKeyCodepoint, isPrintableUnicodeCodepoint,
} from 'gamecontrol';
import { HeldKeyDownKind } from 'gamecontrol';
import { GLFW_MOD_SHIFT, GLFW_PRESS, GLFW_RELEASE, GLFW_REPEAT } from 'gamecontrol';
import { OHOS_A, OHOS_SPACE } from 'gamecontrol';

export default function physicalKeyEdgeTest() {
  describe('PhysicalKeyEdge.decidePhysicalKeyEdge', () => {
    it('shadowAction 数值与 AMCL_INPUT_ACTION_* 镜像一致（1/2/3）', 0, () => {
      // 这三个值作为 physicalKeyTransaction 的参数直接过界，失配是**静默错标**
      // 而不是编译错误，所以在这里钉住。
      expect(SHADOW_KEY_DOWN).assertEqual(1);
      expect(SHADOW_KEY_REPEAT).assertEqual(2);
      expect(SHADOW_KEY_UP).assertEqual(3);
    });

    it('首次按下 → DOWN + PRESS（这是修饰键能成立的唯一原因）', 0, () => {
      const edge: PhysicalKeyEdgeActions =
        decidePhysicalKeyEdge(true, false, HeldKeyDownKind.FirstDown);
      expect(edge.shouldPublish).assertTrue();
      expect(edge.shadowAction).assertEqual(SHADOW_KEY_DOWN);
      expect(edge.glfwAction).assertEqual(GLFW_PRESS);
    });

    it('平台自动重复 → REPEAT + REPEAT，两个平面同分类', 0, () => {
      const edge: PhysicalKeyEdgeActions =
        decidePhysicalKeyEdge(true, false, HeldKeyDownKind.Repeat);
      expect(edge.shouldPublish).assertTrue();
      expect(edge.shadowAction).assertEqual(SHADOW_KEY_REPEAT);
      expect(edge.glfwAction).assertEqual(GLFW_REPEAT);
    });

    it('FirstDownAfterStale 必须按首次按下处理，**不得**判成 Repeat', 0, () => {
      // 它表示"缓存里的按住已陈旧，中间那个 Up 丢了"。判成 Repeat 会让该键永久发
      // REPEAT 而 native 那边已无 owner ⇒ 边沿被整条丢弃 ⇒ 用户看到"这个键失灵了"
      // （ESC 快按后失效即此）。这条是自愈路径的正确性所在。
      const edge: PhysicalKeyEdgeActions =
        decidePhysicalKeyEdge(true, false, HeldKeyDownKind.FirstDownAfterStale);
      expect(edge.shadowAction).assertEqual(SHADOW_KEY_DOWN);
      expect(edge.glfwAction).assertEqual(GLFW_PRESS);
    });

    it('抬起 → UP + RELEASE，与 downKind 无关', 0, () => {
      const a: PhysicalKeyEdgeActions = decidePhysicalKeyEdge(false, true, undefined);
      const b: PhysicalKeyEdgeActions =
        decidePhysicalKeyEdge(false, true, HeldKeyDownKind.Repeat);
      expect(a.shadowAction).assertEqual(SHADOW_KEY_UP);
      expect(a.glfwAction).assertEqual(GLFW_RELEASE);
      expect(b.shadowAction).assertEqual(SHADOW_KEY_UP);
      expect(b.glfwAction).assertEqual(GLFW_RELEASE);
    });

    it('既非 Down 也非 Up → 整条不上报（平台还有 Unknown 等取值）', 0, () => {
      const edge: PhysicalKeyEdgeActions = decidePhysicalKeyEdge(false, false, undefined);
      expect(edge.shouldPublish).assertFalse();
      expect(edge.shadowAction).assertEqual(PHYSICAL_KEY_EDGE_NONE);
      expect(edge.glfwAction).assertEqual(-1);
    });

    it('两个平面永不出现"一边 REPEAT 一边 PRESS"的错配', 0, () => {
      // 错配会让 legacy edge router 多拿一个 owner 而 typed 不会，两侧 owner 数从此
      // 永久不等，且不变量自检抓不到（各自都自洽）。所以穷举全部输入组合来钉住配对。
      const kinds: (HeldKeyDownKind | undefined)[] = [
        undefined, HeldKeyDownKind.FirstDown,
        HeldKeyDownKind.Repeat, HeldKeyDownKind.FirstDownAfterStale,
      ];
      for (let i = 0; i < kinds.length; i++) {
        const down: PhysicalKeyEdgeActions = decidePhysicalKeyEdge(true, false, kinds[i]);
        const typedIsRepeat: boolean = down.shadowAction === SHADOW_KEY_REPEAT;
        const legacyIsRepeat: boolean = down.glfwAction === GLFW_REPEAT;
        expect(typedIsRepeat).assertEqual(legacyIsRepeat);
      }
    });

    it('Down 与 Up 同时为 true 时按 Down 处理（与抽出前的分支顺序一致）', 0, () => {
      // 平台不该产出这种事件，但抽 TU 不改语义：原实现的三元表达式先判 isDown。
      const edge: PhysicalKeyEdgeActions =
        decidePhysicalKeyEdge(true, true, HeldKeyDownKind.FirstDown);
      expect(edge.shadowAction).assertEqual(SHADOW_KEY_DOWN);
    });
  });

  describe('PhysicalKeyEdge.shouldRefillChar', () => {
    it('四项全真才回灌（穷举 16 种组合，只有一种为 true）', 0, () => {
      // 合取谓词最容易被"顺手加个 ||"改坏，所以直接穷举而不是抽样。
      let trueCount: number = 0;
      for (let mask = 0; mask < 16; mask++) {
        const isDown: boolean = (mask & 1) !== 0;
        const isPrintable: boolean = (mask & 2) !== 0;
        const isGrabbed: boolean = (mask & 4) !== 0;
        const imeActive: boolean = (mask & 8) !== 0;
        const expected: boolean = isDown && isPrintable && !isGrabbed && !imeActive;
        expect(shouldRefillChar(isDown, isPrintable, isGrabbed, imeActive))
          .assertEqual(expected);
        if (expected) trueCount++;
      }
      expect(trueCount).assertEqual(1);
    });

    it('抬起不产字（char 是按下语义）', 0, () => {
      expect(shouldRefillChar(false, true, false, false)).assertFalse();
    });

    it('grabbed 时不回灌 —— 游戏态 MC 自己按 keycode 处理，回灌会多出字符', 0, () => {
      expect(shouldRefillChar(true, true, true, false)).assertFalse();
    });

    it('⚠️ IME 激活时不回灌：输入法已消费过可打印键，再发就是双发', 0, () => {
      // 失效方向不对称（见 ImeActivationGate 契约第 4 条）：
      //   错为 false = 字符双发；错为 true = **物理键盘打不出可打印字符**，更严重。
      // 所以这一项绝不能加"猜一下"的兜底。
      expect(shouldRefillChar(true, true, false, true)).assertFalse();
    });

    it('功能键（非可打印）不回灌', 0, () => {
      expect(shouldRefillChar(true, false, false, false)).assertFalse();
    });
  });

  describe('KeyMap.resolvePhysicalKeyCodepoint', () => {
    it('平台 unicode 优先于 US 键位表（保留当前实体键盘布局）', 0, () => {
      expect(resolvePhysicalKeyCodepoint('@'.charCodeAt(0), OHOS_A, 0))
        .assertEqual('@'.charCodeAt(0));
    });

    it('平台未给码位时退回既有 US 表，含 Space', 0, () => {
      expect(resolvePhysicalKeyCodepoint(undefined, OHOS_A, 0))
        .assertEqual('a'.charCodeAt(0));
      expect(resolvePhysicalKeyCodepoint(0, OHOS_A, GLFW_MOD_SHIFT))
        .assertEqual('A'.charCodeAt(0));
      expect(resolvePhysicalKeyCodepoint(0, OHOS_SPACE, 0)).assertEqual(0x20);
    });

    it('char 与 GLFW key 映射解耦：未知键仍可携带合法 Unicode scalar', 0, () => {
      expect(resolvePhysicalKeyCodepoint(0x4E2D, 999999, 0)).assertEqual(0x4E2D);
    });

    it('控制字符、surrogate、小数与越界值均不能直通', 0, () => {
      const rejected: number[] = [0, 0x1F, 0x7F, 0x85, 0xD800, 1.5, 0x110000];
      for (let i = 0; i < rejected.length; i++) {
        expect(isPrintableUnicodeCodepoint(rejected[i])).assertFalse();
      }
      expect(isPrintableUnicodeCodepoint(0x20)).assertTrue();
      expect(isPrintableUnicodeCodepoint(0x10FFFF)).assertTrue();
    });
  });

  describe('PhysicalKeyEdge.shouldSuppressBackPressAfterEsc', () => {
    const WINDOW_MS: number = 250;

    it('无物理键盘时**永不**抑制 —— 否则会误吞真实返回手势', 0, () => {
      // 纯触摸设备没有物理 ESC，返回手势是用户唯一的退出手段。
      expect(shouldSuppressBackPressAfterEsc(false, 0, WINDOW_MS)).assertFalse();
      expect(shouldSuppressBackPressAfterEsc(false, 10, WINDOW_MS)).assertFalse();
      expect(shouldSuppressBackPressAfterEsc(false, 100000, WINDOW_MS)).assertFalse();
    });

    it('有键盘 + 窗口内 → 抑制（避免 MC 收到两次 ESC）', 0, () => {
      expect(shouldSuppressBackPressAfterEsc(true, 0, WINDOW_MS)).assertTrue();
      expect(shouldSuppressBackPressAfterEsc(true, 249, WINDOW_MS)).assertTrue();
    });

    it('窗口边界是开区间：恰好等于窗口值不抑制', 0, () => {
      expect(shouldSuppressBackPressAfterEsc(true, 250, WINDOW_MS)).assertFalse();
      expect(shouldSuppressBackPressAfterEsc(true, 251, WINDOW_MS)).assertFalse();
    });

    it('从未按过物理 ESC（dt 极大）不抑制', 0, () => {
      // 页面初值 lastEscFromKeyAt=0 ⇒ dt = Date.now()，一个很大的数。
      expect(shouldSuppressBackPressAfterEsc(true, 1_700_000_000_000, WINDOW_MS)).assertFalse();
    });

    it('已知边界（刻意保留）：dt 为负时抑制，与抽出前逐位相同', 0, () => {
      // 只可能来自 Date.now() 被回拨。后果是那一小段时间内返回手势被吞（再按一次即可），
      // 比反方向（双发 ESC ⇒ 菜单刚弹出又关掉）轻。要改应作为独立一轮并说明理由。
      expect(shouldSuppressBackPressAfterEsc(true, -1, WINDOW_MS)).assertTrue();
    });
  });
}
