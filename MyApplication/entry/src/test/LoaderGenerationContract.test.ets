/*
 * LoaderGenerationContract.test.ets — 加载器世代判定 + 启动契约校验
 *
 * ⭐ **这份测试存在的直接原因：一个布尔值承载了七元区分，于是同一处改动崩掉两个世代。**
 *
 * 2026-08-26 的 `642edf87` 把 `java.class.path` 从"启动器 + 完整游戏 classpath"收窄成
 * "只有 amcl-launcher.jar"。那个改动对**原版**是必需且正确的（字节码变换只在
 * `AmclClassLoader.findClass` 里发生），但 `java.class.path` 是一条被 7 个世代以
 * 7 种方式消费的共享信道：
 *   · Fabric Knot 只认它            ⇒ 2026-08-29 全线启动即崩（CHANGELOG 1000576）
 *   · Forge 新 bootstrap 只认它     ⇒ 2026-09-04 启动即崩（同一根因，此前从未被修）
 *   · Forge BSL 有 legacyClassPath 旁路 ⇒ 侥幸没事
 * 而当时代码里能表达世代的只有 `isForge` / `isFabric`，且 `isForge` 对
 * ForgeBsl / ForgeBootstrap / NeoForge / ModlauncherLegacy **四代同时为真**
 * （`'neoforged'.indexOf('forge') >= 0`）⇒ "BSL 有旁路、新 bootstrap 没有"**写不下来**。
 *
 * ⚠️ **本文件与 `scripts/check-launch-generation-contract.mjs` 分工不同，不要合并：**
 *
 * | 谁 | 钉住什么 | 何时跑 |
 * |---|---|---|
 * | 那道静态门禁 | 契约表的**结构**、棘轮钉住值、跨语言字面量一致 | 提交前（CI 无 OHOS SDK 也能跑） |
 * | **本文件** | 判定器与校验器的**行为** | `hvigorw test`（需设备） |
 *
 * ⇒ 两者都不能证明真机能启动，那需要五路线真机验收（方案 §3.4）。
 *
 * 三类断言在这里同等重要：
 *   - **正向**：每个世代都判得对、契约都取得到；
 *   - **反向**：破坏契约的输入**必须**被判失败（一条不会失败的判据比没有判据更糟，
 *     本仓 1000513 吃过"判据在 CI 上恒真"的亏）；
 *   - **fail-open 的方向**：未识别的 mainClass 必须倒向"能启动"，且必须留痕。
 *
 * 创建日期：2026-09-04
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  resolveLoaderGeneration, LoaderGenerationReason,
  LoaderGeneration, ClasspathDelivery, LOADER_GENERATION_CONTRACTS,
  loaderGenerationContract, LoaderGenerationContract,
  evaluateLaunchContract, LaunchContractSeverity, LaunchContractVerdict,
  UNKNOWN_GENERATION_DELIVERY,
} from 'launch';

/** 构造一个"各项都合法"的校验输入，再由各用例只改要考察的那一项。 */
function okInput(contract: LoaderGenerationContract): Record<string, Object> {
  const args: string[] = [];
  if (contract.requiresLegacyClassPathProperty) {
    args.push('-DlegacyClassPath=/a.jar:/b.jar');
  }
  return {
    'contract': contract,
    'effectiveDelivery': contract.classpathDelivery,
    'gameClasspathEntries': 42,
    'jvmArgs': args,
    'jdkMajor': contract.pinnedJdkMajor.length > 0 ? contract.pinnedJdkMajor : '25',
  };
}

function evalOk(contract: LoaderGenerationContract): LaunchContractVerdict {
  const i = okInput(contract);
  return evaluateLaunchContract({
    contract: i['contract'] as LoaderGenerationContract,
    effectiveDelivery: i['effectiveDelivery'] as ClasspathDelivery,
    gameClasspathEntries: i['gameClasspathEntries'] as number,
    jvmArgs: i['jvmArgs'] as string[],
    jdkMajor: i['jdkMajor'] as string,
  });
}

function hasCode(v: LaunchContractVerdict, code: string): boolean {
  for (let k = 0; k < v.violations.length; k++) {
    if (v.violations[k].code === code) return true;
  }
  return false;
}

export default function loaderGenerationContractTest() {
  describe('LoaderGenerationContract', () => {

    // ── 一、判定：每个世代的 mainClass 都判得对 ──────────────────────
    it('resolves each known entrypoint to its own generation', 0, () => {
      // 逐条写死而不是遍历契约表 —— 遍历会让"表和判定器一起错"变成绿。
      expect(resolveLoaderGeneration({ mainClass: 'net.minecraft.client.main.Main' })
        .generation).assertEqual(LoaderGeneration.Vanilla);
      expect(resolveLoaderGeneration({ mainClass: 'net.minecraft.launchwrapper.Launch' })
        .generation).assertEqual(LoaderGeneration.FmlLegacy);
      expect(resolveLoaderGeneration({ mainClass: 'cpw.mods.modlauncher.Launcher' })
        .generation).assertEqual(LoaderGeneration.ModlauncherLegacy);
      expect(resolveLoaderGeneration({ mainClass: 'cpw.mods.bootstraplauncher.BootstrapLauncher' })
        .generation).assertEqual(LoaderGeneration.ForgeBsl);
      expect(resolveLoaderGeneration({ mainClass: 'net.minecraftforge.bootstrap.ForgeBootstrap' })
        .generation).assertEqual(LoaderGeneration.ForgeBootstrap);
      expect(resolveLoaderGeneration({ mainClass: 'net.neoforged.fml.startup.Client' })
        .generation).assertEqual(LoaderGeneration.NeoForge);
      expect(resolveLoaderGeneration({
        mainClass: 'net.fabricmc.loader.impl.launch.knot.KnotClient',
      }).generation).assertEqual(LoaderGeneration.FabricKnot);
    });

    // ⭐ 这条是整份测试的核心：旧 isForge 对这四个**同时为真**。
    it('separates the four Forge-family generations that isForge collapsed', 0, () => {
      const bsl = resolveLoaderGeneration({
        mainClass: 'cpw.mods.bootstraplauncher.BootstrapLauncher',
      });
      const boot = resolveLoaderGeneration({
        mainClass: 'net.minecraftforge.bootstrap.ForgeBootstrap',
      });
      const neo = resolveLoaderGeneration({ mainClass: 'net.neoforged.fml.startup.Client' });
      const ml = resolveLoaderGeneration({ mainClass: 'cpw.mods.modlauncher.Launcher' });

      // 四个互不相等 —— 分辨率真的到了世代级。
      expect(bsl.generation === boot.generation).assertFalse();
      expect(boot.generation === neo.generation).assertFalse();
      expect(neo.generation === ml.generation).assertFalse();
      // 且它们的契约确实不同：只有老 modlauncher 钉 JDK 8、只有它要求 URLClassLoader。
      expect(ml.contract.pinnedJdkMajor).assertEqual('8');
      expect(neo.contract.pinnedJdkMajor).assertEqual('');
      expect(ml.contract.requiresUrlClassLoaderSystemLoader).assertTrue();
      expect(bsl.contract.requiresUrlClassLoaderSystemLoader).assertFalse();
      expect(boot.contract.requiresUrlClassLoaderSystemLoader).assertFalse();
    });

    // ⚠️ NeoForge 的 mainClass 含子串 'forge'，正是旧判定塌缩的来源。
    it('does not let the neoforged substring pull NeoForge into Forge', 0, () => {
      const neo = resolveLoaderGeneration({ mainClass: 'net.neoforged.fml.startup.Client' });
      expect(neo.generation).assertEqual(LoaderGeneration.NeoForge);
      expect(neo.reason).assertEqual(LoaderGenerationReason.MainClassExact);
    });

    // ── 二、fail-open 的方向必须是"能启动"────────────────────────────
    it('falls open to full classpath for an unrecognized entrypoint', 0, () => {
      const d = resolveLoaderGeneration({ mainClass: 'com.example.WeirdModpackEntry' });
      expect(d.generation).assertEqual(LoaderGeneration.Unknown);
      expect(d.reason).assertEqual(LoaderGenerationReason.MainClassUnrecognized);
      // 猜错的代价：变换失效（掉帧）。反向猜错的代价：启动即崩。⇒ 必须是 full。
      expect(d.contract.classpathDelivery).assertEqual(ClasspathDelivery.JvmClasspathFull);
      expect(UNKNOWN_GENERATION_DELIVERY).assertEqual(ClasspathDelivery.JvmClasspathFull);
    });

    it('treats an empty mainClass as Unknown without throwing', 0, () => {
      const d = resolveLoaderGeneration({ mainClass: '' });
      expect(d.generation).assertEqual(LoaderGeneration.Unknown);
      expect(d.reason).assertEqual(LoaderGenerationReason.MainClassMissing);
    });

    // Unknown 必须留痕（Warn），否则"认不出来"与"认出来了"在真机上不可区分。
    it('warns but does not block on an unknown generation', 0, () => {
      const c = loaderGenerationContract(LoaderGeneration.Unknown) as LoaderGenerationContract;
      const v = evalOk(c);
      expect(v.ok).assertTrue();
      expect(hasCode(v, 'unknown-generation')).assertTrue();
      let warned = false;
      for (let k = 0; k < v.violations.length; k++) {
        if (v.violations[k].code === 'unknown-generation') {
          warned = v.violations[k].severity === LaunchContractSeverity.Warn;
        }
      }
      expect(warned).assertTrue();
    });

    // ── 三、结构不变量（与静态门禁重叠是刻意的：两条防线独立）────────
    it('gives every generation exactly one contract row', 0, () => {
      const all: LoaderGeneration[] = [
        LoaderGeneration.Vanilla, LoaderGeneration.FmlLegacy,
        LoaderGeneration.ModlauncherLegacy, LoaderGeneration.ForgeBsl,
        LoaderGeneration.ForgeBootstrap, LoaderGeneration.NeoForge,
        LoaderGeneration.FabricKnot, LoaderGeneration.Unknown,
      ];
      expect(LOADER_GENERATION_CONTRACTS.length).assertEqual(all.length);
      for (let i = 0; i < all.length; i++) {
        expect(loaderGenerationContract(all[i]) !== undefined).assertTrue();
      }
    });

    it('keeps isolationAsserts strictly equal to (delivery === amcl-loader-only)', 0, () => {
      for (let i = 0; i < LOADER_GENERATION_CONTRACTS.length; i++) {
        const c: LoaderGenerationContract = LOADER_GENERATION_CONTRACTS[i];
        const expected: boolean = c.classpathDelivery === ClasspathDelivery.AmclLoaderOnly;
        expect(c.isolationAsserts).assertEqual(expected);
      }
    });

    it('narrows the JVM classpath for vanilla only', 0, () => {
      for (let i = 0; i < LOADER_GENERATION_CONTRACTS.length; i++) {
        const c: LoaderGenerationContract = LOADER_GENERATION_CONTRACTS[i];
        const narrow: boolean = c.classpathDelivery === ClasspathDelivery.AmclLoaderOnly;
        expect(narrow).assertEqual(c.generation === LoaderGeneration.Vanilla);
      }
    });

    // ── 四、正向：每个世代的合法 profile 都通过 ─────────────────────
    it('passes a well-formed profile for every generation', 0, () => {
      for (let i = 0; i < LOADER_GENERATION_CONTRACTS.length; i++) {
        const v = evalOk(LOADER_GENERATION_CONTRACTS[i]);
        expect(v.ok).assertTrue();
      }
    });

    // ── 五、反向：破坏契约必须失败（本节是 G2 的行为侧载体）──────────
    // ⭐ 642edf87 的最小复现：给只认 java.class.path 的世代发收窄的 delivery。
    it('fails when a java.class.path-only loader gets the narrowed delivery', 0, () => {
      const c = loaderGenerationContract(
        LoaderGeneration.ForgeBootstrap) as LoaderGenerationContract;
      const v = evaluateLaunchContract({
        contract: c,
        effectiveDelivery: ClasspathDelivery.AmclLoaderOnly,
        gameClasspathEntries: 98,
        jvmArgs: [],
        jdkMajor: '25',
      });
      expect(v.ok).assertFalse();
      expect(hasCode(v, 'delivery-mismatch')).assertTrue();
    });

    it('fails when Fabric Knot gets the narrowed delivery', 0, () => {
      const c = loaderGenerationContract(LoaderGeneration.FabricKnot) as LoaderGenerationContract;
      const v = evaluateLaunchContract({
        contract: c,
        effectiveDelivery: ClasspathDelivery.AmclLoaderOnly,
        gameClasspathEntries: 47,
        jvmArgs: [],
        jdkMajor: '21',
      });
      expect(v.ok).assertFalse();
      expect(hasCode(v, 'delivery-mismatch')).assertTrue();
    });

    // ⭐⭐ 2026-09-04 真机否证的一条 B 级推断，值得单独钉住。
    it('does not require legacyClassPath from Forge BSL (disproved 2026-09-04)', 0, () => {
      // 这一格曾是 true，依据是"BSL 的官方 JSON 自带 -DlegacyClassPath=${classpath}"。
      // 真机：官方 1.19.4-forge-45.4.5 的合并 JSON 里该属性 **0 次出现**
      // （它用 -p / --add-modules / -DmergeModules / -DlibraryDirectory，其余靠 -cp），
      // 而 AMCL 全仓也从未注入它 ⇒ 那条判据把整代 Forge 1.17–1.20.1 拒之门外
      // （日志逐字 fails=1 codes=legacy-classpath-missing，连试两次）。
      const c = loaderGenerationContract(LoaderGeneration.ForgeBsl) as LoaderGenerationContract;
      expect(c.requiresLegacyClassPathProperty).assertFalse();
      // 而它必须能在"只有完整 java.class.path、没有那条属性"时通过 —— 那正是真机形态。
      const v = evaluateLaunchContract({
        contract: c,
        effectiveDelivery: c.classpathDelivery,
        gameClasspathEntries: 82,   // 真机实测条目数
        jvmArgs: [],                // ← 没有 -DlegacyClassPath，这是官方 JSON 的形状
        jdkMajor: '25',
      });
      expect(v.ok).assertTrue();
      expect(hasCode(v, 'legacy-classpath-missing')).assertFalse();
    });

    // C4 这条判据**本身**仍然要能工作：当前没有世代打开它（见上一条），
    // 所以用一个合成契约行来钉机制 —— 否则这段代码会变成"从不执行且无人知道"。
    it('still catches a lost legacyClassPath channel when a generation asks for it', 0, () => {
      const base = loaderGenerationContract(
        LoaderGeneration.ForgeBsl) as LoaderGenerationContract;
      const synthetic: LoaderGenerationContract = {
        generation: base.generation,
        mainClasses: base.mainClasses,
        displayName: base.displayName,
        classpathDelivery: base.classpathDelivery,
        isolationAsserts: base.isolationAsserts,
        requiresLegacyClassPathProperty: true,   // ← 合成：假设某个分发确实要求它
        requiresUrlClassLoaderSystemLoader: base.requiresUrlClassLoaderSystemLoader,
        pinnedJdkMajor: base.pinnedJdkMajor,
        jdkCeiling: base.jdkCeiling,
        rationale: 'synthetic row for the C4 mechanism test',
      };
      const missing = evaluateLaunchContract({
        contract: synthetic,
        effectiveDelivery: synthetic.classpathDelivery,
        gameClasspathEntries: 60,
        jvmArgs: [],
        jdkMajor: '17',
      });
      expect(missing.ok).assertFalse();
      expect(hasCode(missing, 'legacy-classpath-missing')).assertTrue();

      // 空值等于没有那条通道。
      const empty = evaluateLaunchContract({
        contract: synthetic,
        effectiveDelivery: synthetic.classpathDelivery,
        gameClasspathEntries: 60,
        jvmArgs: ['-DlegacyClassPath='],
        jdkMajor: '17',
      });
      expect(empty.ok).assertFalse();
      expect(hasCode(empty, 'legacy-classpath-missing')).assertTrue();

      // 有值就通过 —— 判据不是恒假。
      const present = evaluateLaunchContract({
        contract: synthetic,
        effectiveDelivery: synthetic.classpathDelivery,
        gameClasspathEntries: 60,
        jvmArgs: ['-DlegacyClassPath=/a.jar:/b.jar'],
        jdkMajor: '17',
      });
      expect(present.ok).assertTrue();
    });

    // 1000154：老 modlauncher 给 JDK 17 会崩 `urls is null`，且回退更高版本照样崩。
    it('fails when legacy modlauncher is not routed to JDK 8', 0, () => {
      const c = loaderGenerationContract(
        LoaderGeneration.ModlauncherLegacy) as LoaderGenerationContract;
      const v = evaluateLaunchContract({
        contract: c,
        effectiveDelivery: c.classpathDelivery,
        gameClasspathEntries: 30,
        jvmArgs: [],
        jdkMajor: '17',
      });
      expect(v.ok).assertFalse();
      expect(hasCode(v, 'jdk-major-mismatch')).assertTrue();
    });

    it('fails on an empty game classpath', 0, () => {
      const c = loaderGenerationContract(LoaderGeneration.Vanilla) as LoaderGenerationContract;
      const v = evaluateLaunchContract({
        contract: c,
        effectiveDelivery: c.classpathDelivery,
        gameClasspathEntries: 0,
        jvmArgs: [],
        jdkMajor: '25',
      });
      expect(v.ok).assertFalse();
      expect(hasCode(v, 'empty-game-classpath')).assertTrue();
    });

    // ── 六、判据行必须带上归因所需的字段 ────────────────────────────
    // "通道建起来了但一个事件都没流过"与"工作正常"在日志里长得一样（本仓 1000544）。
    // 这里钉住的是：一行日志足以判断走了哪个世代、哪种交付。
    it('emits an attributable one-liner', 0, () => {
      const d = resolveLoaderGeneration({
        mainClass: 'net.minecraftforge.bootstrap.ForgeBootstrap',
      });
      expect(d.logLine.indexOf('generation=forge-bootstrap') >= 0).assertTrue();
      expect(d.logLine.indexOf('delivery=jvm-classpath-full') >= 0).assertTrue();
      expect(d.logLine.indexOf('isolationAsserts=0') >= 0).assertTrue();

      const v = evalOk(d.contract);
      expect(v.logLine.indexOf('AMCL_LAUNCH_CONTRACT') >= 0).assertTrue();
      expect(v.logLine.indexOf('fails=0') >= 0).assertTrue();
    });
  });
}
