/*
 * LaunchJdkPolicy.test.ets — JDK 可用区间与选择策略（批次 D）
 *
 * ⭐ **这份测试钉的是两个方向的病，它们各自都在真机上发生过一次。**
 *
 * **病一：判据缺了上限那一维**（施工记录 §S09.3）。`1.19.4-forge-45.4.5` 自检全绿然后闪退 ——
 * 纪元理想 JDK 17 只装了一半 ⇒ 路由降级到 25 ⇒ Forge 自带 ASM 9.7.1 读不了 JDK 25 的
 * class file v69 ⇒ 建类层次时崩。Phase 0 只有下限判据（25 ≥ 17 ⇒ pass）。
 *
 * **病二：把"推荐"当成了"唯一"**（§S12）。第一版修法把上限取成"纪元理想那个数"，
 * 于是用户只装 JDK 21、选自动时被告知"JDK 17 未安装"而**拒启** —— 而 ASM 9.7.1 的上限是
 * Java 24，**JDK 21 完全可用**（用户实测跑通）。一条过严的判据与一条过宽的判据同样有害，
 * 只是前者的受害者会来投诉、后者不会。
 *
 * ⇒ 现在的模型：**可用性是区间 `[min, max]`**，`min` 来自游戏纪元、
 * `max` **实读该版本自己 `libraries` 里声明的 ASM 版本**（七个版本实测全部声明了它）。
 *
 * ⭐⭐ **最承重的是「等价矩阵」那一节**：改路由这种核心路径时，"新逻辑更对"不算证据，
 * "对所有已在真机上跑通的组合逐条不变"才算（与 `RendererRouteEquivalence.test.ets` 同源纪律）。
 *
 * ⚠️ 边界：本文件只测**策略与区间**（纯函数）。`eraIdealJdk` / `minRuntimeMajor` 由
 * `JdkManager` 按游戏纪元算好传进来，那部分是既有逻辑、本批未改。
 *
 * 创建日期：2026-09-04
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  resolveJdkRange, resolveJdkPolicy, JdkRange, JdkPolicyDecision,
  usable, classifyJdkChoice, describeAboveMax, describeNotPreferred,
  findAsmSupport, AsmSupportInfo,
  PreLaunchValidator, PreLaunchCheck,
  LoaderGeneration, LoaderGenerationContract, loaderGenerationContract, JdkCeiling,
} from 'launch';

/** 那台设备当时的实际状态：JDK 8 与 25 完整，17 只有一个空 lib 目录（= 未安装）。 */
const DEV_8_25: string[] = ['8', '25'];
/** ⭐ 用户第二轮的状态：**只装了 21**。 */
const ONLY_21: string[] = ['21'];

const MAIN_VANILLA: string = 'net.minecraft.client.main.Main';
const MAIN_FML_LEGACY: string = 'net.minecraft.launchwrapper.Launch';
const MAIN_MODLAUNCHER: string = 'cpw.mods.modlauncher.Launcher';
const MAIN_FORGE_BSL: string = 'cpw.mods.bootstraplauncher.BootstrapLauncher';
const MAIN_FORGE_BOOTSTRAP: string = 'net.minecraftforge.bootstrap.ForgeBootstrap';
const MAIN_NEOFORGE: string = 'net.neoforged.fml.startup.Client';
const MAIN_KNOT: string = 'net.fabricmc.loader.impl.launch.knot.KnotClient';

/** `libraries` 的真实形状（相对路径）。逐字取自设备上那些版本 JSON 的实读结果。 */
function asmLibs(version: string): string[] {
  return [
    'com/mojang/logging/1.1.1/logging-1.1.1.jar',
    `org/ow2/asm/asm/${version}/asm-${version}.jar`,
    `org/ow2/asm/asm-tree/${version}/asm-tree-${version}.jar`,
    `org/ow2/asm/asm-commons/${version}/asm-commons-${version}.jar`,
  ];
}

function rangeOf(mainClass: string, asmVersion: string, eraIdeal: string,
                 minMajor: number): JdkRange {
  return resolveJdkRange({
    mainClass: mainClass,
    libraryPaths: asmVersion.length > 0 ? asmLibs(asmVersion) : ['net/minecraft/foo/foo.jar'],
    eraIdealJdk: eraIdeal,
    minRuntimeMajor: minMajor,
  });
}

function pick(range: JdkRange, installed: string[], userPick: string = ''): JdkPolicyDecision {
  return resolveJdkPolicy({ range: range, userPreferred: userPick, installedMajors: installed });
}

function contractOf(g: LoaderGeneration): LoaderGenerationContract {
  return loaderGenerationContract(g) as LoaderGenerationContract;
}

export default function launchJdkPolicyTest() {
  describe('LaunchJdkPolicy', () => {

    // ── 一、ASM 上限实读（数据来源是版本自己的 libraries）──────────────
    it('从 libraries 实读 ASM 版本并映射到最高 Java', 0, () => {
      // 逐条对应设备上七个版本 JSON 的实读值。
      expect(findAsmSupport(asmLibs('9.7.1')).maxJavaMajor).assertEqual(24);   // 1.19.4-forge
      expect(findAsmSupport(asmLibs('9.10.1')).maxJavaMajor).assertEqual(27);  // 26.2-forge / neoforge / fabric
      expect(findAsmSupport(asmLibs('7.2')).maxJavaMajor).assertEqual(14);     // 1.15.2-forge
      expect(findAsmSupport(asmLibs('9.2')).maxJavaMajor).assertEqual(18);     // 1.18.2-forge 那一档
      expect(findAsmSupport(asmLibs('9.5')).maxJavaMajor).assertEqual(21);     // 1.20.1-forge 那一档
      // 原版不声明 ASM ⇒ 无 ASM 侧上限。
      expect(findAsmSupport(['net/minecraft/foo.jar']).maxJavaMajor).assertEqual(0);
    });

    it('⭐ 版本号按数字段比较：9.10 比 9.7.1 新（字符串比较会反）', 0, () => {
      expect(findAsmSupport(asmLibs('9.10')).maxJavaMajor).assertEqual(27);
      expect(findAsmSupport(asmLibs('9.7')).maxJavaMajor).assertEqual(23);
      // 一个版本同时声明两个不同 ASM 时取**最老**那个（任一组件读不了就崩）。
      const mixed: string[] = ['org/ow2/asm/asm/9.10.1/asm-9.10.1.jar',
        'org/ow2/asm/asm-tree/9.2/asm-tree-9.2.jar'];
      expect(findAsmSupport(mixed).maxJavaMajor).assertEqual(18);
    });

    it('表里没单独列出的 ASM 版本落到前一条断点（保守方向）', 0, () => {
      // 9.0 没有单独断点 ⇒ 落到 7.3.1 的 Java 15，而不是猜一个更高的值。
      expect(findAsmSupport(asmLibs('9.0')).maxJavaMajor).assertEqual(15);
      // 比最老断点还老 ⇒ Java 8（asm-debug-all:5.2 = 1.12.2-forge 的形状）。
      expect(findAsmSupport(
        ['org/ow2/asm/asm-debug-all/5.2/asm-debug-all-5.2.jar']).maxJavaMajor).assertEqual(8);
    });

    // ── 二、⭐ 用户实测的两个组合（病一 + 病二）─────────────────────
    it('⭐ 病二修复：只装 JDK 21 + 版本推荐 17 + ASM 9.7.1 ⇒ 直接用 21，不拒启', 0, () => {
      const r: JdkRange = rangeOf(MAIN_FORGE_BSL, '9.7.1', '17', 17);
      expect(r.minMajor).assertEqual(17);
      expect(r.maxMajor).assertEqual(24);            // ASM 9.7.1 ⇒ Java 24
      expect(r.preferredJdk).assertEqual('17');      // 推荐仍是纪元理想
      const d: JdkPolicyDecision = pick(r, ONLY_21);
      expect(d.jdk).assertEqual('21');               // ← 用户实测可跑的那个
      expect(d.installed).assertTrue();
      expect(d.reason).assertEqual('in-range');
    });

    it('⭐ 病一仍然修着：同一版本 + 只装 [8,25] ⇒ 不许选 25', 0, () => {
      const r: JdkRange = rangeOf(MAIN_FORGE_BSL, '9.7.1', '17', 17);
      const d: JdkPolicyDecision = pick(r, DEV_8_25);
      expect(d.jdk === '25').assertFalse();          // 25 > 24 ⇒ 越界，必崩
      expect(d.jdk).assertEqual('17');               // 返回推荐值让上层提示安装
      expect(d.installed).assertFalse();
      expect(d.reason).assertEqual('none-installed');
    });

    it('装上 17 之后优先用 17（推荐值优先于区间内其它可用值）', 0, () => {
      const r: JdkRange = rangeOf(MAIN_FORGE_BSL, '9.7.1', '17', 17);
      const d: JdkPolicyDecision = pick(r, ['8', '17', '21', '25']);
      expect(d.jdk).assertEqual('17');
      expect(d.reason).assertEqual('era-ideal');
    });

    // ── 三、⭐ 等价矩阵：真机跑通过的组合逐条不变 ────────────────────
    it('六条真机路线选出的 JDK 与实测一致', 0, () => {
      // 1.12.2 原版（无 ASM，≤1.12 纪元规则 → 8）
      expect(pick(rangeOf(MAIN_VANILLA, '', '8', 8), DEV_8_25).jdk).assertEqual('8');
      // 1.12.2-forge（fml-legacy，asm-debug-all:5.2 ⇒ 上限 8）
      const fml: JdkRange = resolveJdkRange({
        mainClass: MAIN_FML_LEGACY,
        libraryPaths: ['org/ow2/asm/asm-debug-all/5.2/asm-debug-all-5.2.jar'],
        eraIdealJdk: '8', minRuntimeMajor: 8,
      });
      expect(pick(fml, DEV_8_25).jdk).assertEqual('8');
      // 1.15.2-forge（modlauncher-legacy）：ASM 7.2 给的上限是 14，但契约钉死 8 ⇒ 8
      const ml: JdkRange = rangeOf(MAIN_MODLAUNCHER, '7.2', '17', 8);
      expect(ml.maxMajor).assertEqual(8);
      expect(pick(ml, DEV_8_25).jdk).assertEqual('8');
      expect(pick(ml, DEV_8_25).reason).assertEqual('pinned');
      // 26.2-forge / neoforge / fabric 26.1.1（ASM 9.10.1 ⇒ 上限 27）→ 25
      expect(pick(rangeOf(MAIN_FORGE_BOOTSTRAP, '9.10.1', '25', 25), DEV_8_25).jdk).assertEqual('25');
      expect(pick(rangeOf(MAIN_NEOFORGE, '9.10.1', '25', 25), DEV_8_25).jdk).assertEqual('25');
      expect(pick(rangeOf(MAIN_KNOT, '9.10.1', '25', 25), DEV_8_25).jdk).assertEqual('25');
      // 26.3-snapshot-10 原版（无 ASM ⇒ 无上限）→ 25
      expect(pick(rangeOf(MAIN_VANILLA, '', '25', 25), DEV_8_25).jdk).assertEqual('25');
      // 1.19.4-forge 装了 17 之后 → 17（用户第一轮实测跑通的那次）
      expect(pick(rangeOf(MAIN_FORGE_BSL, '9.7.1', '17', 17), ['8', '17', '25']).jdk)
        .assertEqual('17');
    });

    it('原版无上限：纪元理想没装时仍向上替换（旧行为不变）', 0, () => {
      const r: JdkRange = rangeOf(MAIN_VANILLA, '', '21', 21);
      expect(r.maxMajor).assertEqual(0);
      const d: JdkPolicyDecision = pick(r, DEV_8_25);
      expect(d.jdk).assertEqual('25');
      expect(d.reason).assertEqual('in-range');
    });

    // ── 四、上限来源的优先级 ────────────────────────────────────────
    it('钉住值比 ASM 更严时以钉住值为准（老 modlauncher）', 0, () => {
      const r: JdkRange = rangeOf(MAIN_MODLAUNCHER, '7.2', '17', 8);
      expect(r.minMajor).assertEqual(8);
      expect(r.maxMajor).assertEqual(8);
      expect(r.ceilingSource).assertEqual('pinned:8');
      // 用户硬覆盖 17 也不许采纳（1000154：给 17 会崩 urls is null）。
      expect(pick(r, ['8', '17'], '17').jdk).assertEqual('8');
    });

    it('没声明 ASM 的加载器路线回落到世代兜底（收紧到纪元）', 0, () => {
      const r: JdkRange = rangeOf(MAIN_FORGE_BSL, '', '17', 17);
      expect(r.maxMajor).assertEqual(17);
      expect(r.ceilingSource).assertEqual('generation-fallback');
    });

    it('纪元理想越过上限时推荐值被夹回上限', 0, () => {
      // 假想：纪元要 25，而该版本自带 ASM 9.5（≤21）⇒ 推荐 21 而不是 25。
      const r: JdkRange = rangeOf(MAIN_FORGE_BOOTSTRAP, '9.5', '25', 17);
      expect(r.maxMajor).assertEqual(21);
      expect(r.preferredJdk).assertEqual('21');
    });

    it('结构不变量：jdkCeiling 为 None 的世代只有原版', 0, () => {
      const all: LoaderGeneration[] = [
        LoaderGeneration.Vanilla, LoaderGeneration.FmlLegacy,
        LoaderGeneration.ModlauncherLegacy, LoaderGeneration.ForgeBsl,
        LoaderGeneration.ForgeBootstrap, LoaderGeneration.NeoForge,
        LoaderGeneration.FabricKnot, LoaderGeneration.Unknown,
      ];
      for (let i = 0; i < all.length; i++) {
        const none: boolean = contractOf(all[i]).jdkCeiling === JdkCeiling.None;
        expect(none).assertEqual(all[i] === LoaderGeneration.Vanilla);
      }
    });

    it('未识别世代：有 ASM 就按 ASM，没有就 fail-closed 到纪元', 0, () => {
      const withAsm: JdkRange = rangeOf('com.example.WeirdEntry', '9.8', '17', 17);
      expect(withAsm.generation).assertEqual('unknown');
      expect(withAsm.maxMajor).assertEqual(25);
      const noAsm: JdkRange = rangeOf('com.example.WeirdEntry', '', '17', 17);
      expect(noAsm.maxMajor).assertEqual(17);
    });

    // ── 五、区间判定与 Phase 0 自检 ─────────────────────────────────
    it('usable / classifyJdkChoice 的四种结论', 0, () => {
      const r: JdkRange = rangeOf(MAIN_FORGE_BSL, '9.7.1', '17', 17);
      expect(usable(21, r)).assertTrue();
      expect(usable(25, r)).assertFalse();
      expect(usable(8, r)).assertFalse();
      expect(classifyJdkChoice(17, r)).assertEqual('ok');
      expect(classifyJdkChoice(21, r)).assertEqual('ok-not-preferred');
      expect(classifyJdkChoice(25, r)).assertEqual('above-max');
      expect(classifyJdkChoice(8, r)).assertEqual('below-min');
      // 无上限时永不越界。
      const v: JdkRange = rangeOf(MAIN_VANILLA, '', '25', 25);
      expect(classifyJdkChoice(25, v)).assertEqual('ok');
      expect(usable(99, v)).assertTrue();
    });

    it('⭐ 自检：可用但非推荐 ⇒ pass + 说明，**绝不阻塞**', 0, () => {
      const r: JdkRange = rangeOf(MAIN_FORGE_BSL, '9.7.1', '17', 17);
      const c: PreLaunchCheck = PreLaunchValidator.runJdk('21', r, false);
      expect(c.status).assertEqual('pass');          // ← 用户要的"换一种提示而不是阻塞"
      expect(c.fixActionKey).assertEqual('');
      expect(c.detail.indexOf('JDK 21 可用') >= 0).assertTrue();
      expect(c.detail.indexOf('9.7.1') >= 0).assertTrue();   // 实读值进文案，便于复核
      expect(c.detail.indexOf('JDK 17') >= 0).assertTrue();  // 仍然告诉他更贴合的是哪个
    });

    it('⭐ 自检：越上限 ⇒ fail，且"保留并继续"不能放行', 0, () => {
      const r: JdkRange = rangeOf(MAIN_FORGE_BSL, '9.7.1', '17', 17);
      const c: PreLaunchCheck = PreLaunchValidator.runJdk('25', r, true);
      expect(c.status).assertEqual('fail');
      expect(c.fixActionKey).assertEqual('jdk_mismatch');
      expect(c.detail.indexOf('ASM 9.7.1') >= 0).assertTrue();
      expect(c.detail.indexOf('Unsupported class file major version') >= 0).assertTrue();
    });

    it('自检：低于下限仍是 warn（保留调试通道）', 0, () => {
      const r: JdkRange = rangeOf(MAIN_FORGE_BSL, '9.7.1', '17', 17);
      expect(PreLaunchValidator.runJdk('8', r, false).status).assertEqual('warn');
    });

    it('自检：真机六条组合全部 pass', 0, () => {
      expect(PreLaunchValidator.runJdk('8',
        rangeOf(MAIN_FML_LEGACY, '', '8', 8), false).status).assertEqual('pass');
      expect(PreLaunchValidator.runJdk('8',
        rangeOf(MAIN_MODLAUNCHER, '7.2', '17', 8), false).status).assertEqual('pass');
      expect(PreLaunchValidator.runJdk('17',
        rangeOf(MAIN_FORGE_BSL, '9.7.1', '17', 17), false).status).assertEqual('pass');
      expect(PreLaunchValidator.runJdk('25',
        rangeOf(MAIN_FORGE_BOOTSTRAP, '9.10.1', '25', 25), false).status).assertEqual('pass');
      expect(PreLaunchValidator.runJdk('25',
        rangeOf(MAIN_KNOT, '9.10.1', '25', 25), false).status).assertEqual('pass');
      expect(PreLaunchValidator.runJdk('25',
        rangeOf(MAIN_VANILLA, '', '25', 25), false).status).assertEqual('pass');
    });

    // ── 六、判据行 ──────────────────────────────────────────────────
    it('判据行带齐区间与来源', 0, () => {
      const d: JdkPolicyDecision = pick(rangeOf(MAIN_FORGE_BSL, '9.7.1', '17', 17), ONLY_21);
      expect(d.logLine.indexOf('AMCL_JDK_POLICY schema=2') >= 0).assertTrue();
      expect(d.logLine.indexOf('generation=forge-bsl') >= 0).assertTrue();
      expect(d.logLine.indexOf('range=[17,24]') >= 0).assertTrue();
      expect(d.logLine.indexOf('ceiling=asm:9.7.1') >= 0).assertTrue();
      expect(d.logLine.indexOf('reason=in-range') >= 0).assertTrue();
      // 无上限写 inf 而不是 0 —— "没有上限"与"上限是 0"必须在日志里不同。
      const v: JdkPolicyDecision = pick(rangeOf(MAIN_VANILLA, '', '25', 25), DEV_8_25);
      expect(v.logLine.indexOf('range=[25,inf]') >= 0).assertTrue();
    });
  });
}
