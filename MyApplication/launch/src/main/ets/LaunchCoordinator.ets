/**
 * LaunchCoordinator.ets — launch 域启动编排（三层架构 · 第四步：Index 业务编排下沉）。
 *
 * 定位：把原先散在 Index.ets（@Entry struct）里的【纯启动决策逻辑】下沉到 launch HAR，
 * 使其可独立于 UI 复用 / 测试。本类**只做计算与决策，绝不碰 @State / UIContext / router /
 * toast**——这些 ArkUI 响应式与导航动作仍由产品层 Index 持有（搬不出 struct）。
 *
 * 覆盖两块：
 *   1. resolvePlan：解析启动计划（版本隔离 gameDir + JDK 路由 + xmx），等价原 launchMC 前半段。
 *   2. Forge 修复决策：parseForgeVersionId / needsForgeDeepRepair，决定走深度修复还是普通增量补全。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { JdkManager } from './JdkManager';
import { VersionFileVerifier } from 'feature_core';
import { isNewForgeVersion } from 'feature_core';
import { SUPPORTED_JDK_VERSIONS, JDK_AUTO } from 'commons';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_LAUNCH } from 'commons';

const TAG = 'LaunchCoordinator';

/** Forge 版本 id 解析结果（`<game>-forge-<loader>`）。 */
export interface ForgeIdParts {
  game: string;
  loader: string;
}

/** resolvePlan 的输入（由产品层从 @State + PreferenceManager.resolveLaunch 取齐后传入）。 */
export interface LaunchPlanInput {
  /** 当前选中的 MC 版本（目录名/真实版本由 JdkManager 内部再解析）。 */
  mcVersion: string;
  /** .minecraft 根目录（Index.mcRoot()）。 */
  mcDir: string;
  /** 是否版本隔离（true=运行目录落在 versions/<ver>/）。 */
  versionIsolation: boolean;
  /** 全局手动选择的 JDK（Index.selectedJdkVersion）。 */
  userPreferredJdk: string;
  /** 该版本单版本覆盖里显式指定的 JDK（EffectiveLaunchConfig.jdkVersion，无则 ''）。 */
  overrideJdkVersion: string;
  /** 该版本生效的最大内存（EffectiveLaunchConfig.xmx）。 */
  effectiveXmx: number;
}

/** resolvePlan 的输出：真正拉起游戏所需的三要素。 */
export interface LaunchPlan {
  /** 运行时工作目录（版本隔离时为 versions/<ver>/，否则 = mcDir）。 */
  gameDir: string;
  /** 最终路由出的 JDK 版本号（"17"/"21"/"25"）。 */
  jdkVersion: string;
  /** 最大内存（MB）。 */
  xmx: number;
}

export class LaunchCoordinator {
  private jdk: JdkManager;

  constructor(jdk: JdkManager) {
    this.jdk = jdk;
  }

  /**
   * 解析启动计划（版本隔离 gameDir + JDK 路由 + xmx）。
   *   1. 版本隔离 → gameDir 落在 versions/<ver>/ 并 mkdir（已存在则吞错）。
   *   2. JDK 路由：见 resolveJdk（单版本硬覆盖 > 单版本 auto > 跟随全局[全局 hint / auto]）。
   */
  resolvePlan(input: LaunchPlanInput): LaunchPlan {
    let gameDir = input.mcDir;
    if (input.versionIsolation) {
      gameDir = input.mcDir + '/versions/' + input.mcVersion;
      try {
        fs.mkdirSync(gameDir, true);
      } catch (e) {
        // 目录已存在属正常路径，不算错误
      }
    }

    let jdkVersion = this.resolveJdk(
      input.mcVersion, input.mcDir, input.overrideJdkVersion, input.userPreferredJdk);

    return { gameDir: gameDir, jdkVersion: jdkVersion, xmx: input.effectiveXmx };
  }

  /**
   * JDK 版本决策（单一控制点，供 resolvePlan 与 UI 就绪态 updateJdkReadyState 复用）。
   * 优先级（高→低）：
   *   1. 单版本显式具体版本（'8'/'17'/'21'/'25'）→ **硬覆盖**，原样返回。
   *      即便与该 MC 版本纪元不匹配也照用——这是"选错 JDK 也能启动"的调试通道；
   *      是否已安装由启动前校验 sheet 处理（未装则提示下载该 JDK）。
   *   2. 单版本 = 'auto' → 纯纪元路由（resolveLaunchJdk，忽略全局选择）。
   *   3. 单版本 = ''（跟随全局）：
   *        · 全局为具体版本 → 作为 resolveLaunchJdk 的偏好 hint（兼容则采用，不兼容回退纪元路由）。
   *        · 全局为 'auto'/'' → 纯纪元路由。
   *
   * @param overrideJdkVersion 单版本覆盖值：''|'auto'|具体版本
   * @param userPreferredJdk   全局设置值：'auto'|具体版本（兼容历史 ''）
   */
  resolveJdk(mcVersion: string, mcDir: string, overrideJdkVersion: string, userPreferredJdk: string): string {
    let pv = overrideJdkVersion;
    if (LaunchCoordinator.isSpecificJdk(pv)) {
      AppLogger.info(TAG,
        `resolveJdk(${mcVersion}): per-version FORCE JDK ${pv} (bypass auto-route)`, LOG_DOMAIN_LAUNCH);
      return pv;
    }
    if (pv === JDK_AUTO) {
      return this.jdk.resolveLaunchJdk(mcVersion, '', mcDir);   // 纯纪元路由
    }
    // pv === ''（跟随全局）
    let hint = LaunchCoordinator.isSpecificJdk(userPreferredJdk) ? userPreferredJdk : '';
    return this.jdk.resolveLaunchJdk(mcVersion, hint, mcDir);
  }

  /** v 是否为具体 JDK 版本号（'8'/'17'/'21'/'25'），而非 ''/'auto'。 */
  static isSpecificJdk(v: string): boolean {
    return v.length > 0 && SUPPORTED_JDK_VERSIONS.indexOf(v) >= 0;
  }

  /** 解析 Forge 版本 id（`<game>-forge-<loader>`）。非 Forge（含 fabric）返回 null。 */
  static parseForgeVersionId(ver: string): ForgeIdParts | null {
    let marker = '-forge-';
    let idx = ver.indexOf(marker);
    if (idx <= 0) return null;
    let game = ver.substring(0, idx);
    let loader = ver.substring(idx + marker.length);
    if (game.length === 0 || loader.length === 0) return null;
    return { game: game, loader: loader };
  }

  /**
   * Forge 版本是否需要"深度修复"（走 ForgeRepairTask 重建产物 + 重做合并）：
   *   - 生成产物 forge-client.jar 缺失/损坏（无下载源，必须重跑安装器重建），或
   *   - version.json 是未合并形态（带 inheritsFrom，缺 vanilla 库 → 需重做合并）。
   * 两者都需要重建/合并；普通 RepairTask 修不了。
   */
  static needsForgeDeepRepair(mcDir: string, ver: string, fg: ForgeIdParts): boolean {
    // 生成产物判据只对新版 Forge（≥1.13）成立：旧版（≤1.12 FML legacy）无 binarypatcher、
    // 不产出 -client.jar，forgeClientArtifactBroken 对它恒 true，会把每个旧版 Forge 都
    // 无条件推进深度修复（完整重装安装器）。旧版仍可经下面的 inheritsFrom 判据进入深度修复。
    if (isNewForgeVersion(fg.loader)
        && VersionFileVerifier.forgeClientArtifactBroken(mcDir, fg.game, fg.loader)) return true;
    // 检查 version.json 是否还带 inheritsFrom（未合并 = 清单残缺）
    try {
      let jsonPath = mcDir + '/versions/' + ver + '/' + ver + '.json';
      let obj = JSON.parse(fs.readTextSync(jsonPath)) as Record<string, Object>;
      let inh = obj['inheritsFrom'];
      if (typeof inh === 'string' && (inh as string).length > 0) return true;
    } catch (e) {
      AppLogger.debug(TAG, `needsForgeDeepRepair: read version.json failed, defer to RepairTask: ${(e as Error)?.message ?? String(e)}`, LOG_DOMAIN_LAUNCH);
    }
    return false;
  }
}
