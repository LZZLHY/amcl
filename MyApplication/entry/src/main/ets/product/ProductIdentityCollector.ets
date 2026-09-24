/**
 * ProductIdentityCollector.ets — 采集当前运行的产品身份（批次 D8）
 *
 * 文档：docs/refactor/测试自动化方案.md §三.8
 *
 * 与 `commons` 的 `ProductIdentity.ets` 的分工：
 *   - 那边是纯类型与格式化，不知道值从哪儿来 ⇒ 可在 Node 单测里喂样本；
 *   - 这边知道每个值该问谁（generated profile / DiagnosticPolicy / deviceInfo / bundleManager），
 *     但**不做任何判断与格式化**。
 *
 * ⭐ 它是"同一事实源"的那个源：启动 banner 与未来的 `app.identity` 读模型
 * 都必须调这一个函数，而不是各自再拼一遍（契约 §1.1 同路径）。
 *
 * ⚠️ 本文件在 `entry` 内，因为 `ProductBuildProfile` 是**每条产品轨各一份**的生成文件
 * （`entry/src/{main,desktop,store,sideload}/ProductBuildProfile.ets`），
 * HAR 里拿不到。⇒ 反过来说：**本函数返回的产品轨字段来自哪一份，取决于本次构建的
 * target**，源码级门禁只能断言"字段集合一致"，断言不了"出货包里读的是对的那一份" ——
 * 那需要产物级反查（契约 §5.1 / G2），属 P2。
 */

import deviceInfo from '@ohos.deviceInfo';
import { bundleManager } from '@kit.AbilityKit';
import { AppLogger, DiagnosticPolicy, LogTags, LOG_DOMAIN_LAUNCH, ProductIdentity } from 'commons';
import { ProductBuildProfile } from 'entry/ProductBuildProfile';

const TAG = LogTags.ENTRY_ABILITY;

/** 取不到时的占位。刻意不猜一个"看起来合理"的值 —— 未知就写未知。 */
const UNKNOWN_TEXT = 'unknown';
const UNKNOWN_NUMBER = -1;

interface SelfVersion {
  code: number;
  name: string;
}

/**
 * 读本包的 versionCode / versionName。
 * 走 `getBundleInfoForSelfSync`，与 `Index` 的"检查更新"读的是同一个 API ——
 * 那条路已经在产品里跑了很久（契约 §1.1：不为诊断另开一条读法）。
 */
function readSelfVersion(): SelfVersion {
  try {
    const info = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    return { code: info.versionCode, name: info.versionName };
  } catch (e) {
    // 拿不到版本号不该拖垮启动：banner 退化成 unknown，其余字段照常输出。
    AppLogger.warn(TAG, 'product identity: bundle info unavailable', e as Object, LOG_DOMAIN_LAUNCH);
    return { code: UNKNOWN_NUMBER, name: UNKNOWN_TEXT };
  }
}

function textOr(value: string | undefined, fallback: string): string {
  return value !== undefined && value.length > 0 ? value : fallback;
}

/**
 * 采集一次产品身份。
 *
 * ⚠️ 调用时机：必须在 `DiagnosticPolicy.configure(...)` **之后** ——
 * 在此之前 `resolvedCapabilities()` 恒为 0，banner 会记下一个假的"什么都没开"。
 * `EntryAbility.onCreate` 里 configure 是第一行，所以任何在日志系统就绪后的
 * 调用点都满足这条。
 */
export function collectProductIdentity(): ProductIdentity {
  const version: SelfVersion = readSelfVersion();
  return {
    product: ProductBuildProfile.product,
    family: ProductBuildProfile.family,
    storeChannel: ProductBuildProfile.storeChannel,
    publishable: ProductBuildProfile.publishable,
    developerDiagnostics: ProductBuildProfile.developerDiagnostics,
    touchControls: ProductBuildProfile.touchControls,
    runtimeRawMouse: ProductBuildProfile.runtimeRawMouse,
    capabilities: DiagnosticPolicy.resolvedCapabilities(),
    developerBuild: DiagnosticPolicy.isDeveloperBuild(),
    testHooks: DiagnosticPolicy.hasTestHooks(),
    inputTrace: DiagnosticPolicy.inputTraceEnabled(),
    versionCode: version.code,
    versionName: version.name,
    deviceModel: textOr(deviceInfo.productModel, UNKNOWN_TEXT),
    deviceBrand: textOr(deviceInfo.brand, UNKNOWN_TEXT),
    osFullName: textOr(deviceInfo.osFullName, UNKNOWN_TEXT),
    apiVersion: deviceInfo.sdkApiVersion,
  };
}
