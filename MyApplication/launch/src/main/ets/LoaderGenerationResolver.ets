/**
 * LoaderGenerationResolver.ets — 加载器世代判定（纯函数，无副作用）
 *
 * 契约见 `docs/refactor/启动世代契约规范.md` §1.1；判定钉子在
 * `entry/src/test/LoaderGenerationContract.test.ets`。
 *
 * ⭐ **这个文件替换的是散在四处、互不一致的 `isForge` / `isFabric` 判定**：
 *
 * | 旧位置 | 旧规则 |
 * |---|---|
 * | `LaunchProfileBuilder.isForgeProfile()` | versionId/mainClass/libraries/gameArgs 四路信号 |
 * | `LaunchProfileBuilder`（isFabric） | mainClass 含 `fabricmc` ∨ `Knot` |
 * | `mc_launcher.cpp`（isForge） | mainClass 含 `forge`\|`Forge`\|`bootstrap`\|`Bootstrap` |
 * | `mc_launcher.cpp`（isFabric） | mainClass 含 `fabricmc`\|`Knot` |
 *
 * 那四份的共同缺陷不是"重复"，是**分辨率低于契约空间**：`isForge` 对
 * ForgeBsl / ForgeBootstrap / NeoForge / ModlauncherLegacy 四代同时为真，
 * 于是"BSL 有 legacyClassPath 旁路、新 bootstrap 没有"这件事写不下来。
 *
 * 纪律（与 `RENDERER_RULES`、`platform/input_channel_policy.h` 同源）：
 * **契约表就是全部策略，改行为只改 `LOADER_GENERATION_CONTRACTS`，
 * 不要在调用点加 `if (某个世代)` 特例。**
 *
 * 创建日期：2026-09-04
 */

import {
  ClasspathDelivery, LOADER_GENERATION_CONTRACTS, LoaderGeneration,
  LoaderGenerationContract, loaderGenerationContract,
} from './LoaderGenerationRegistry';

/**
 * 判定输入。**只放"事实"，不放任何已经推导过的结论。**
 *
 * ⚠️ 这条约束是从渲染后端那次重构继承来的：旧代码曾用
 * `jvmArgs.indexOf('-Damcl.gl.backend=gl4es') >= 0` 反查前面几个块的产物，
 * 那是结论而非事实，也正是顺序依赖的来源。
 */
export interface LoaderGenerationInput {
  /** version.json 的 `mainClass`。**判定主键**，精确匹配。 */
  mainClass: string;
}

/** 命中了什么。**存在的理由是可归因性** —— 真机上要能一眼看出"为什么判成这个世代"。 */
export enum LoaderGenerationReason {
  /** mainClass 精确命中契约表某一行。 */
  MainClassExact = 'main-class-exact',
  /** mainClass 非空但不在表里 ⇒ Unknown（fail-open，见注册表注释）。 */
  MainClassUnrecognized = 'main-class-unrecognized',
  /** mainClass 为空/缺失 ⇒ Unknown。**上游协议破了**，但仍不阻断启动。 */
  MainClassMissing = 'main-class-missing',
}

/** 判定结果。 */
export interface LoaderGenerationDecision {
  generation: LoaderGeneration;
  reason: LoaderGenerationReason;
  /** 该世代的契约。**保证非 undefined**（由结构不变量钉住）。 */
  contract: LoaderGenerationContract;
  /** 供调用方直接打印的一行。含世代 id 与 delivery —— 真机靠它归因。 */
  logLine: string;
}

/**
 * 判定世代。**纯函数：同输入同输出，无 IO、无日志、无全局状态。**
 *
 * ⭐ **只用 mainClass 精确匹配，刻意不用 libraries / versionId 做旁证。** 三个理由：
 * ① 旧 `isForgeProfile` 的四路信号里，`versionId.indexOf('forge')` 会被用户自定义的
 *    版本名（"我的forge整合包"）误命中，而 libraries 信号对 NeoForge 与 Forge 同时为真 ——
 *    多路信号提高的是"是不是 Forge 家族"的召回，而**本判定要的是精确到世代**；
 * ② mainClass 是上游加载器自己声明的入口，它与"用什么协议拿 classpath"是同一件事的两面，
 *    因果最短；
 * ③ 认不出来时的行为是明确的（fail-open 到完整 classpath），所以"少一路信号"的代价是
 *    可控的掉帧，而不是启动失败。
 *
 * ⚠️ **不要为了"更聪明"把 libraries 扫描加回来。** 若将来出现两个世代共用同一 mainClass
 * 的情形，正确做法是在契约表里把它们并成一行（共享同一份契约），而不是在这里加旁证。
 */
export function resolveLoaderGeneration(i: LoaderGenerationInput): LoaderGenerationDecision {
  const main: string = i.mainClass ?? '';
  if (main.length === 0) {
    return decide(LoaderGeneration.Unknown, LoaderGenerationReason.MainClassMissing,
      'mainClass is empty');
  }
  for (let r = 0; r < LOADER_GENERATION_CONTRACTS.length; r++) {
    const row: LoaderGenerationContract = LOADER_GENERATION_CONTRACTS[r];
    for (let m = 0; m < row.mainClasses.length; m++) {
      if (row.mainClasses[m] === main) {
        return decide(row.generation, LoaderGenerationReason.MainClassExact,
          `mainClass='${main}'`);
      }
    }
  }
  return decide(LoaderGeneration.Unknown, LoaderGenerationReason.MainClassUnrecognized,
    `mainClass='${main}' is not a known loader entrypoint`);
}

function decide(generation: LoaderGeneration, reason: LoaderGenerationReason,
                why: string): LoaderGenerationDecision {
  // 非空由结构不变量保证（每个枚举值都必须在表里有一行）。这里仍然显式兜底成
  // Unknown 的那一行，**而不是抛异常** —— 判定器抛异常会让启动在一个可恢复的
  // 分类问题上失败，与 fail-open 的设计意图相反。
  const found: LoaderGenerationContract | undefined = loaderGenerationContract(generation);
  const contract: LoaderGenerationContract = found !== undefined
    ? found
    : LOADER_GENERATION_CONTRACTS[LOADER_GENERATION_CONTRACTS.length - 1];
  return {
    generation: generation,
    reason: reason,
    contract: contract,
    logLine: `AMCL_LOADER_GENERATION schema=1 generation=${generation}`
      + ` delivery=${contract.classpathDelivery}`
      + ` isolationAsserts=${contract.isolationAsserts ? 1 : 0}`
      + ` reason=${reason} — ${why}`,
  };
}

/**
 * 便捷判据：该世代是否要求收窄 `java.class.path`。
 *
 * 存在的理由是**让调用点读不到 `ClasspathDelivery` 的字面量** ——
 * 调用点一旦开始写 `delivery === 'amcl-loader-only'`，改交付方式就要改 N 处。
 */
export function requiresNarrowJvmClasspath(contract: LoaderGenerationContract): boolean {
  return contract.classpathDelivery === ClasspathDelivery.AmclLoaderOnly;
}
