/**
 * RendererBackendResolver.test.ets — 渲染后端选择规则的等价性钉子
 *
 * 契约见 `docs/guides/renderer-backend-governance.md` §2/§4；
 * 施工过程与设计取舍见 `docs/refactor/渲染后端治理施工记录.md` §S2。
 *
 * ⭐ **本文件钉住的不是"解析器能跑"，而是"解析器与被它替换掉的三个 if 块在全判定矩阵上逐项相同"。**
 *
 * 那三个 if 块此前散在 `LaunchProfileBuilder.buildProfile` 里，且第三块靠
 * `jvmArgs.indexOf('-Damcl.gl.backend=gl4es') >= 0` **反查前两块的产物**来决定要不要 zink ——
 * 也就是说它们有顺序依赖。收敛成纯函数之后，唯一能证明"没改变行为"的东西就是这份矩阵。
 *
 * ⚠️ **zink 相关的用例是刻意保留的。** D1 已决定 zink 完全退役（施工记录 §0.3），
 * 但退役是**语义变更**、排在 §S6；本批（§S2–§S5）是**等价性重构**。两者混批之后真机回归
 * 失败就分不清是哪一半造成的。⇒ 本文件先钉住"现状"，§S6 再连同规则一起改。
 *
 * 创建日期：2026-08-27
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  resolveRendererBackend,
  RendererResolveInput,
  RendererDecision,
  RendererDecisionReason,
  RENDERER_BACKEND_DEFAULT_ID,
  rendererBackendById,
  RendererBackendLifecycle,
  RendererWindowAcquisition,
  RENDERER_BACKENDS,
  userSelectableRendererBackends,
  GraphicsPlatformFamily,
} from 'launch';
import { CapabilityEvidence, CapabilityResult, VulkanEvidence } from 'launch';

/** DevTools 的 mobilegl 覆盖用一份明确绑定 profile/需求/provider 的能力证据。 */
function mobileglCapability(): CapabilityResult {
  return {
    evidenceProfileId: 'mobilegl', requirementId: 'mobilegl-direct-vulkan-v1', windowProvider: 'SDL3',
    loader: CapabilityEvidence.YES, instance: CapabilityEvidence.YES,
    windowSurface: CapabilityEvidence.YES, physicalDevice: CapabilityEvidence.YES,
    apiVersion: '1.3', deviceExtensions: CapabilityEvidence.YES, featureBits: CapabilityEvidence.YES,
    queuePresentation: CapabilityEvidence.YES, shaderToolchain: CapabilityEvidence.YES,
    nativeArtifacts: CapabilityEvidence.YES, lifecycleSmoke: CapabilityEvidence.YES,
    reasonCode: 'unit-fixture', observedProvider: 'SDL3', observedUnderlyingVulkan: VulkanEvidence.YES,
  };
}

/** 造一份解析输入。默认是"现代 MC + 现代 LWJGL 槽位 + 默认偏好"。 */
function input(mcVersion: string, lwjglVersion: number, needs322: boolean,
               pref: string): RendererResolveInput {
  return {
    realMcVersion: mcVersion,
    lwjglVersion: lwjglVersion,
    needsLwjgl322Slot: needs322,
    userPreferredBackendId: pref,
  };
}

/** 现代路径的常用输入（LWJGL 3.4.1 槽位）。 */
function modern(mcVersion: string, pref: string): RendererResolveInput {
  return input(mcVersion, 3, false, pref);
}

/** LWJGL 3.2 槽位（MC 声明 LWJGL 3.0–3.2）。 */
function slot322(mcVersion: string, pref: string): RendererResolveInput {
  return input(mcVersion, 3, true, pref);
}

/** 真 LWJGL2 槽位（MC ≤1.12）。 */
function lwjgl2(mcVersion: string, pref: string): RendererResolveInput {
  return input(mcVersion, 2, false, pref);
}

export default function rendererBackendResolverTest() {

  describe('华为原生 GL 验证路线', () => {
    it('无能力证据时拒绝原生 GL 覆盖', 0, () => {
      const request: RendererResolveInput = modern('1.21.1', '');
      request.devOverrideBackendId = 'nativegl';
      expect(resolveRendererBackend(request).backendId === 'nativegl').assertFalse();
    });
    it('能力探针通过后允许显式原生 GL 验证', 0, () => {
      const request: RendererResolveInput = modern('1.21.1', '');
      request.devOverrideBackendId = 'nativegl';
      request.nativeGlAvailable = true;
      expect(resolveRendererBackend(request).backendId).assertEqual('nativegl');
    });
    it('系统 GL 偏好由能力准入', 0, () => {
      const request: RendererResolveInput = modern('1.21.1', 'nativegl');
      request.nativeGlAvailable = true;
      expect(resolveRendererBackend(request).backendId).assertEqual('nativegl');
    });
    it('原生 GL 验证不能覆盖 LWJGL2 的强制路线', 0, () => {
      const request: RendererResolveInput = lwjgl2('1.12.2', '');
      request.devOverrideBackendId = 'nativegl';
      request.nativeGlAvailable = true;
      expect(resolveRendererBackend(request).backendId).assertEqual('gl4es');
    });
    it('电脑 LWJGL2 自动使用包内 GL4ES', 0, () => {
      for (const version of ['1.7.10', '1.12.2']) {
        const request: RendererResolveInput = lwjgl2(version, 'mobileglues');
        request.platformFamily = GraphicsPlatformFamily.DESKTOP;
        request.nativeGlAvailable = true;
        expect(resolveRendererBackend(request).backendId).assertEqual('gl4es');
      }
    });
    it('电脑 LWJGL3 固定管线版本使用 GL4ES', 0, () => {
      const request: RendererResolveInput = slot322('1.16.5', 'gl4es');
      request.nativeGlAvailable = true;
      expect(resolveRendererBackend(request).backendId).assertEqual('gl4es');
    });
    it('电脑系统 GL 能力缺失时选择包内兼容路线', 0, () => {
      const request: RendererResolveInput = modern('1.21.1', 'mobileglues');
      request.platformFamily = GraphicsPlatformFamily.DESKTOP;
      expect(resolveRendererBackend(request).backendId).assertEqual('mobileglues');
    });
  });

  describe('RendererBackendRegistry 的结构不变量', () => {
    // 这几条是 check-renderer-registry.mjs 的同款断言。门禁跑在 CI/构建期，
    // 这里跑在单测里 —— 两处都要有，因为门禁只看源码文本，测试能看运行期真值。
    it('每个后端的 id 非空且互不重复', 0, () => {
      const seen: Set<string> = new Set();
      for (let i = 0; i < RENDERER_BACKENDS.length; i++) {
        const id: string = RENDERER_BACKENDS[i].id;
        expect(id.length > 0).assertTrue();
        expect(seen.has(id)).assertFalse();
        seen.add(id);
      }
    });

    it('id 不得含大写或缩写记号（规范 §3.2：MGL 一族禁止）', 0, () => {
      for (let i = 0; i < RENDERER_BACKENDS.length; i++) {
        const id: string = RENDERER_BACKENDS[i].id;
        expect(id).assertEqual(id.toLowerCase());
        expect(id.indexOf('mgl')).assertEqual(-1);
      }
    });

    it('ForcedByVersion 与 Candidate 必须不可用户选择', 0, () => {
      // 否则用户会选到一个被无声忽略的值 —— 那正是 zink 现在的形态之一。
      for (let i = 0; i < RENDERER_BACKENDS.length; i++) {
        const b = RENDERER_BACKENDS[i];
        if (b.lifecycle === RendererBackendLifecycle.ForcedByVersion ||
            b.lifecycle === RendererBackendLifecycle.Candidate) {
          expect(b.userSelectable).assertFalse();
        }
      }
    });

    it('ownsPresent 必然要求 native-window-lease', 0, () => {
      // 同一个 OHNativeWindow 只能有一个生产者；自己上屏就必须自己持租约。
      for (let i = 0; i < RENDERER_BACKENDS.length; i++) {
        const b = RENDERER_BACKENDS[i];
        if (b.ownsPresent) {
          expect(b.windowAcquisition).assertEqual(RendererWindowAcquisition.NativeWindowLease);
        }
      }
    });

    it('有且仅有一个 Default 后端', 0, () => {
      let n: number = 0;
      for (let i = 0; i < RENDERER_BACKENDS.length; i++) {
        if (RENDERER_BACKENDS[i].lifecycle === RendererBackendLifecycle.Default) n++;
      }
      expect(n).assertEqual(1);
    });

    it('RENDERER_BACKEND_DEFAULT_ID 指向那个 Default 后端', 0, () => {
      const spec = rendererBackendById(RENDERER_BACKEND_DEFAULT_ID);
      expect(spec !== undefined).assertTrue();
      expect(spec!.lifecycle).assertEqual(RendererBackendLifecycle.Default);
    });

    it('rendererBackendById 对未知 id 返回 undefined，不静默落默认', 0, () => {
      // 静默落默认会让"打错一个 id"变成一次无声的行为改变。
      expect(rendererBackendById('nope') === undefined).assertTrue();
      expect(rendererBackendById('') === undefined).assertTrue();
      expect(rendererBackendById('MobileGlues') === undefined).assertTrue();  // 大小写敏感
    });
  });

  describe('等价性：LWJGL2 槽位（MC ≤1.12）', () => {
    it('lwjglVersion===2 恒选 gl4es，且不看真实 MC 版本', 0, () => {
      // 旧代码：`if (lwjglVersion === 2) { push('-Damcl.gl.backend=gl4es') }` —— 无版本判据。
      const versions: string[] = ['1.7.10', '1.8.9', '1.12.2'];
      for (let i = 0; i < versions.length; i++) {
        const d: RendererDecision = resolveRendererBackend(lwjgl2(versions[i], 'mobileglues'));
        expect(d.backendId).assertEqual('gl4es');
        expect(d.reason).assertEqual(RendererDecisionReason.ForcedByLwjgl2);
      }
    });

    it('⚠️ 即使真实版本 ≥1.17，lwjglVersion===2 仍然是 gl4es', 0, () => {
      // 这个组合现实中不该出现，但旧代码里 LWJGL2 那一支**确实没有版本判据** ——
      // 等价性要求解析器复现它，而不是"顺手修正"。
      const d = resolveRendererBackend(lwjgl2('1.20.4', 'mobileglues'));
      expect(d.backendId).assertEqual('gl4es');
    });

    it('LWJGL2 下 zink 偏好被忽略（强制规则优先于任何偏好）', 0, () => {
      // 旧代码第三块的前置是 `!alreadyGl4es`，而 LWJGL2 块已经注入了 gl4es。
      // ⚰️ zink 退役后这条依然成立且更强：强制规则在偏好段**之前**执行，
      //   所以连"偏好是否可选"都不会被问到。
      const d = resolveRendererBackend(lwjgl2('1.12.2', 'zink'));
      expect(d.backendId).assertEqual('gl4es');
      expect(d.userPreferenceHonored).assertFalse();
      expect(d.reason).assertEqual(RendererDecisionReason.ForcedByLwjgl2);
    });
  });

  describe('等价性：LWJGL 3.2 槽位（needs322）', () => {
    it('needs322 且真实版本 <1.17 → gl4es', 0, () => {
      const versions: string[] = ['1.13.2', '1.14.4', '1.15.2', '1.16.5'];
      for (let i = 0; i < versions.length; i++) {
        const d = resolveRendererBackend(slot322(versions[i], 'mobileglues'));
        expect(d.backendId).assertEqual('gl4es');
        expect(d.reason).assertEqual(RendererDecisionReason.ForcedByFixedFunctionEra);
      }
    });

    it('⭐ needs322 但真实版本 ≥1.17 → 仍是 mobileglues，不是 gl4es', 0, () => {
      // 最容易漏的一条。旧注释专门写了：「1.17+ 虽也用 LWJGL 3.2，但 1.17 起渲染重写为
      // core profile（无固定管线）→ 仍用 MobileGlues」。LWJGL 槽位与渲染器不是同一判据。
      const d = resolveRendererBackend(slot322('1.17.1', 'mobileglues'));
      expect(d.backendId).assertEqual('mobileglues');
    });

    it('needs322 且 <1.17 时 zink 偏好被忽略', 0, () => {
      const d = resolveRendererBackend(slot322('1.16.5', 'zink'));
      expect(d.backendId).assertEqual('gl4es');
      expect(d.userPreferenceHonored).assertFalse();
    });
  });

  describe('等价性：现代槽位（MC ≥1.17）', () => {
    it('默认偏好 → mobileglues', 0, () => {
      const versions: string[] = ['1.17.1', '1.20.4', '1.21.4', '26.1.2', '26.2', '26.3'];
      for (let i = 0; i < versions.length; i++) {
        const d = resolveRendererBackend(modern(versions[i], 'mobileglues'));
        expect(d.backendId).assertEqual('mobileglues');
        expect(d.reason).assertEqual(RendererDecisionReason.Default);
      }
    });

    it('⚰️ zink 已退役：偏好里存着它的老用户落默认，且不抛错', 0, () => {
      // ⭐ 这是 zink 退役（§S6）最关键的一条用户可见行为：
      //   老用户的持久化偏好里仍然存着 'zink'（`PreferenceManager` 刻意不清空存储），
      //   解析器必须把它当"不可选"落默认 —— **不抛错、不卡启动**。
      // 判据是 `userSelectable=false`，走的是 UserPreferenceUnknown 那条路
      //   （注册表里查得到这一行，但它不可选）。
      const d = resolveRendererBackend(modern('1.20.4', 'zink'));
      expect(d.backendId).assertEqual(RENDERER_BACKEND_DEFAULT_ID);
      expect(d.reason).assertEqual(RendererDecisionReason.UserPreferenceUnknown);
      expect(d.userPreferenceHonored).assertFalse();
      // 日志必须留痕："这个用户曾经选过 zink"是有诊断价值的事实。
      expect(d.logLine.indexOf('zink') >= 0).assertTrue();
    });

    it('⚰️ zink 退役后，版本不再影响它的处置（各版本一致落默认）', 0, () => {
      // 退役前 zink 有两条不同的路：≥1.17 采纳、<1.17 被版本拒绝。
      // 退役后**版本判据不再参与** —— 它在 userSelectable 那一关就被挡下了。
      const versions: string[] = ['1.16.5', '1.17.1', '1.20.4', '26.3'];
      for (let i = 0; i < versions.length; i++) {
        const d = resolveRendererBackend(modern(versions[i], 'zink'));
        expect(d.backendId).assertEqual(RENDERER_BACKEND_DEFAULT_ID);
        expect(d.reason).assertEqual(RendererDecisionReason.UserPreferenceUnknown);
      }
    });

    it('zink 在注册表里仍然查得到（墓碑），但不可选', 0, () => {
      // 刻意保留整行：① 让上面那条"落默认"走确定的路而不是"未知 id"；② rationale 是墓碑。
      const spec = rendererBackendById('zink');
      expect(spec !== undefined).assertTrue();
      expect(spec!.lifecycle).assertEqual(RendererBackendLifecycle.Retired);
      expect(spec!.userSelectable).assertFalse();
      expect(spec!.rationale.toLowerCase().indexOf('retired') >= 0).assertTrue();
    });

    it('⚰️ 退役后端不出现在 userSelectableRendererBackends() 里', 0, () => {
      const selectable = userSelectableRendererBackends();
      for (let i = 0; i < selectable.length; i++) {
        expect(selectable[i].lifecycle === RendererBackendLifecycle.Retired).assertFalse();
      }
    });

    it('未知偏好 id 落默认，且标记未被采纳', 0, () => {
      // 用户偏好来自持久化存储，可能是旧版本写的、或将来被退役的 id。
      // 必须落默认而不是抛错 —— 退役一个后端不能让老用户启动失败。
      const d = resolveRendererBackend(modern('1.20.4', 'some-retired-backend'));
      expect(d.backendId).assertEqual(RENDERER_BACKEND_DEFAULT_ID);
      expect(d.userPreferenceHonored).assertFalse();
      expect(d.reason).assertEqual(RendererDecisionReason.UserPreferenceUnknown);
    });

    it('空偏好落默认', 0, () => {
      expect(resolveRendererBackend(modern('1.20.4', '')).backendId)
        .assertEqual(RENDERER_BACKEND_DEFAULT_ID);
    });
  });

  describe('版本解析的边界（喂给解析器的真实版本可能不规范）', () => {
    it('空版本串不得崩，落默认现代路径', 0, () => {
      // resolveInstalledMcVersion 对整合包/重命名版本可能给不出版本号。
      // 旧代码此时 isMcVersionAtLeast('', '1.17') 为 false ⇒ 会走 gl4es（在 needs322 内）。
      const d = resolveRendererBackend(slot322('', 'mobileglues'));
      expect(d.backendId).assertEqual('gl4es');
    });

    it('现代槽位 + 空版本 + 默认偏好 → mobileglues', 0, () => {
      const d = resolveRendererBackend(modern('', 'mobileglues'));
      expect(d.backendId).assertEqual('mobileglues');
    });
  });

  describe('决策对象自身的契约', () => {
    it('backendId 恒指向一个注册表里存在的后端', 0, () => {
      // 解析器不允许产出一个查不到的 id —— 那会让 native 侧拿到一个没有 glLibName 的值。
      const cases: RendererResolveInput[] = [
        lwjgl2('1.12.2', 'zink'),
        slot322('1.16.5', 'mobileglues'),
        modern('1.20.4', 'zink'),
        modern('26.3', 'bogus'),
      ];
      for (let i = 0; i < cases.length; i++) {
        const d = resolveRendererBackend(cases[i]);
        expect(rendererBackendById(d.backendId) !== undefined).assertTrue();
      }
    });

    it('reason 与 userPreferenceHonored 不得自相矛盾', 0, () => {
      const cases: RendererResolveInput[] = [
        lwjgl2('1.12.2', 'zink'),
        slot322('1.16.5', 'zink'),
        modern('1.20.4', 'zink'),
        modern('1.16.5', 'zink'),
        modern('1.20.4', 'bogus'),
        modern('1.20.4', 'mobileglues'),
      ];
      for (let i = 0; i < cases.length; i++) {
        const d = resolveRendererBackend(cases[i]);
        if (d.reason === RendererDecisionReason.UserPreference) {
          expect(d.userPreferenceHonored).assertTrue();
        } else {
          expect(d.userPreferenceHonored).assertFalse();
        }
      }
    });

    it('日志行非空且含 backendId（native 侧靠它归因）', 0, () => {
      const d = resolveRendererBackend(modern('1.20.4', 'mobileglues'));
      expect(d.logLine.length > 0).assertTrue();
      expect(d.logLine.indexOf(d.backendId) >= 0).assertTrue();
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  DevTools 覆盖通道（Phase 2b，施工记录 §S14）
  //  治理规范 §2.3：candidate 的可达路径只有 DevTools；强制规则仍然优先。
  // ═══════════════════════════════════════════════════════════════════
  describe('DevTools 覆盖通道（mobilegl candidate）', () => {
    const withOverride = (base: RendererResolveInput, dev: string): RendererResolveInput => {
      return {
        realMcVersion: base.realMcVersion,
        lwjglVersion: base.lwjglVersion,
        needsLwjgl322Slot: base.needsLwjgl322Slot,
        userPreferredBackendId: base.userPreferredBackendId,
        devOverrideBackendId: dev,
        usesSdl3: true,
        capabilityResults: [mobileglCapability()],
      };
    };

    it('mobilegl 在注册表里是 Optional peer，旧设置列表仍由兼容视图隔离', 0, () => {
      const spec = rendererBackendById('mobilegl');
      expect(spec !== undefined).assertTrue();
      if (spec !== undefined) {
        expect(spec.lifecycle).assertEqual(RendererBackendLifecycle.Optional);
        expect(spec.userSelectable).assertTrue();
        expect(spec.glLibName).assertEqual('libmobilegl.so');
      }
      const selectable = userSelectableRendererBackends();
      for (let i = 0; i < selectable.length; i++) {
        expect(selectable[i].id === 'mobilegl').assertFalse();
      }
    });

    it('GLFW 不借用 SDL 证据，匹配自己的证据后可选 MobileGL', 0, () => {
      const input = withOverride(modern('1.21.1', 'mobileglues'), 'mobilegl');
      input.usesSdl3 = false;
      const glfw = resolveRendererBackend(input);
      expect(glfw.backendId).assertEqual(RENDERER_BACKEND_DEFAULT_ID);
      input.usesSdl3 = undefined;
      expect(resolveRendererBackend(input).backendId).assertEqual(RENDERER_BACKEND_DEFAULT_ID);
      input.usesSdl3 = false;
      const evidence: CapabilityResult = mobileglCapability();
      evidence.windowProvider = 'GLFW';
      input.capabilityResults = [evidence];
      expect(resolveRendererBackend(input).backendId).assertEqual('mobilegl');
    });

    it('SDL3 MC + 覆盖 ⇒ 选中 mobilegl（reason=DevOverride，honored=false）', 0, () => {
      const d = resolveRendererBackend(withOverride(modern('26.3', 'mobileglues'), 'mobilegl'));
      expect(d.backendId).assertEqual('mobilegl');
      expect(d.reason).assertEqual(RendererDecisionReason.DevOverride);
      expect(d.userPreferenceHonored).assertFalse();
    });

    it('覆盖压过用户偏好（覆盖存在的目的），但压不过强制规则', 0, () => {
      // 用户偏好 mobileglues + 覆盖 mobilegl ⇒ mobilegl
      const d1 = resolveRendererBackend(withOverride(modern('1.20.4', 'mobileglues'), 'mobilegl'));
      expect(d1.backendId).assertEqual('mobilegl');
      // LWJGL2 槽位（≤1.12）⇒ 仍是 gl4es，覆盖无效
      const d2 = resolveRendererBackend(withOverride(lwjgl2('1.12.2', 'mobileglues'), 'mobilegl'));
      expect(d2.backendId).assertEqual('gl4es');
      expect(d2.reason).assertEqual(RendererDecisionReason.ForcedByLwjgl2);
      // 固定管线纪元（1.16.5 + 322 槽位）⇒ 仍是 gl4es
      const d3 = resolveRendererBackend(withOverride(slot322('1.16.5', 'mobileglues'), 'mobilegl'));
      expect(d3.backendId).assertEqual('gl4es');
      expect(d3.reason).assertEqual(RendererDecisionReason.ForcedByFixedFunctionEra);
    });

    it('覆盖 + MC <1.17（现代槽位）⇒ 落默认（版本判据）', 0, () => {
      const d = resolveRendererBackend(withOverride(modern('1.16.5', 'mobileglues'), 'mobilegl'));
      expect(d.backendId).assertEqual(RENDERER_BACKEND_DEFAULT_ID);
      expect(d.reason).assertEqual(RendererDecisionReason.DevOverrideRejectedByVersion);
    });

    it('覆盖指向未知 / 产品后端 / 已退役 ⇒ 落默认（显式 reason，可 grep）', 0, () => {
      // 默认候选现在包含按版本推荐的 MobileGL；比较必须保持相同的 SDL/能力证据。
      // 此处钉住“非法覆盖不改变默认选择”，不把旧 registry 的 fallback 常量当作最终结果。
      const automatic = resolveRendererBackend(withOverride(modern('26.3', 'mobileglues'), ''));
      // 未知 id
      const d1 = resolveRendererBackend(withOverride(modern('26.3', 'mobileglues'), 'bogus'));
      expect(d1.backendId).assertEqual(automatic.backendId);
      expect(d1.reason).assertEqual(RendererDecisionReason.DevOverrideInvalid);
      // 产品后端（Default 生命周期）不属于这个通道
      const d2 = resolveRendererBackend(withOverride(modern('26.3', 'mobileglues'), 'mobileglues'));
      expect(d2.reason).assertEqual(RendererDecisionReason.DevOverrideInvalid);
      // 已退役
      const d3 = resolveRendererBackend(withOverride(modern('26.3', 'mobileglues'), 'zink'));
      expect(d3.backendId).assertEqual(automatic.backendId);
      expect(d3.reason).assertEqual(RendererDecisionReason.DevOverrideInvalid);
    });

    it('⭐ 无覆盖（缺省字段）⇒ 与旧行为逐位一致（新通道不得改变既有路径）', 0, () => {
      // `input()` 不设 devOverrideBackendId ⇒ 本文件其余全部矩阵用例天然就是这条的证据；
      // 这里再显式钉一组："空串覆盖"与"缺省"同义。
      // withOverride 会补入 SDL 和能力证据；先统一这些条件，再仅改变覆盖字段有无。
      const base = withOverride(modern('26.3', 'mobileglues'), '');
      base.devOverrideBackendId = undefined;
      const dAbsent = resolveRendererBackend(base);
      const dEmpty = resolveRendererBackend(withOverride(base, ''));
      expect(dAbsent.backendId).assertEqual(dEmpty.backendId);
      expect(dAbsent.reason).assertEqual(dEmpty.reason);
      expect(dEmpty.reason).assertEqual(RendererDecisionReason.Default);
    });
  });
}
