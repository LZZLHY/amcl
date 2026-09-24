/**
 * ForgelikeNative.ets — Forge-like 加载器（Forge / NeoForge）共用的 native 桥（控制反转）。
 *
 * feature_core 抽成 HAR 后不直接依赖 libentry.so；由持有 native 的 entry(HAP) 在启动期注入
 * testNapi 实现。Forge 与 NeoForge 安装都要跑 installer（fork + JNI_CreateJavaVM/jvmInit），共用同一桥。
 *
 *   - checkJitAvailable / getRecommendedXmx：installer 运行前置（JIT 权限 / 推荐内存）。
 *   - runJavaProcessor：跑单个 processor（干净 classpath 独立 JVM，FCL/HMCL 同款）。
 *
 * 历史：原 runForgeInstaller（bangbang93 bootstrapper 同进程跑 processors）已废弃——Forge/NeoForge
 * 现统一走 ForgelikeInstaller + ForgelikeProcessorRunner（runJavaProcessor，每 processor 干净 classpath），
 * 见 docs/adaptation/NeoForge适配方案.md 附录 Z。
 * 原定义在 ForgeService.ets 内。抽出到本文件，使 ForgelikeInstaller / NeoForgeService 不必
 * 反向依赖 ForgeService 即可取到同一注入实例。setForgeNativeBridge 仍由 entry 经 'feature_core'
 * 调用（barrel 重导出），签名不变，100% 向后兼容。
 */

export interface ForgeNativeBridge {
  checkJitAvailable(): boolean;
  getRecommendedXmx(): number;
  /**
   * 跑单个 Forge/NeoForge processor —— 任意 args + 显式工作目录，fork 出**干净 classpath**的
   * 独立 JVM（彻底隔离 installer.jar 的 shaded 库，杜绝类加载冲突）。FCL/HMCL 同款思路。
   */
  runJavaProcessor(filesDir: string, jdkVersion: string, xmxMb: number,
                   classpath: string, mainClass: string, args: string[],
                   workDir: string, logFile: string): Promise<number>;
}

let g_forgeNative: ForgeNativeBridge | null = null;

/** 由 entry（持 libentry.so 的 HAP）在启动时注入；传 null 卸载。 */
export function setForgeNativeBridge(b: ForgeNativeBridge | null): void {
  g_forgeNative = b;
}

/** 取已注入的 native 桥；未注入即抛（调用方在安装链路里捕获并给出可读错误）。 */
export function forgeNative(): ForgeNativeBridge {
  if (!g_forgeNative) {
    throw new Error('ForgeNativeBridge 未注入 — 须在启动期调用 setForgeNativeBridge()');
  }
  return g_forgeNative;
}
