/**
 * LaunchNativeBridge.ets — launch 域 native 桥（三层架构 · D1=方案 a / 控制反转）。
 *
 * launch 抽成 HAR 后不直接依赖 libentry.so；由持有 native 的 entry(HAP) 在启动时注入。
 * 注意：真正的 JVM 创建（jvmInit / mcLaunchWithProfileV2）NAPI 由产品层 McGamePage 直接调用（entry 内，允许）；
 * 本桥只覆盖 launch 域用到的两处：JVM 公共参数 SSOT、JIT 可用性探测。
 */
export interface LaunchNativeBridge {
  /** 取 C 层维护的 JVM 公共参数 SSOT（jvm_common_args）。 */
  getCommonJvmArgs(): string[];
  /** 裸 mmap RWX 探测 JIT 是否可用（不创建 JVM）。 */
  checkJitAvailable(): boolean;
}

let g_launchNative: LaunchNativeBridge | null = null;

/** 由 entry（持 libentry.so 的 HAP）在启动时注入 launch native 实现；传 null 卸载。 */
export function setLaunchNativeBridge(b: LaunchNativeBridge | null): void {
  g_launchNative = b;
}

/** 取已注入的 launch native 桥；未注入即抛（调用方各自兜底）。 */
export function launchNative(): LaunchNativeBridge {
  if (!g_launchNative) {
    throw new Error('LaunchNativeBridge 未注入 — 须在启动期调用 setLaunchNativeBridge()');
  }
  return g_launchNative;
}
