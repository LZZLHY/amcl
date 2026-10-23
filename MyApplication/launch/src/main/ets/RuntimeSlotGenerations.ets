/** LWJGL 不可变代际的目录契约与 native 存储端口。发布/占用/回收由同一 POSIX 边界实现，
 * HAR 不直接依赖 libentry；构建器只计算确定路径，不能按目录枚举选择另一套 JAR。
 */
import { lwjglRuntimeSlot } from './LwjglRuntimeSlots';

export interface RuntimeSlotNativeOps {
  createStage(destination: string): string;
  publish(stage: string, destination: string): void;
  discardStage(stage: string): void;
  acquire(directory: string): string;
  release(handle: string): boolean;
  retire(directory: string): boolean;
  collect(activeDirectory: string): number;
}
let installed: RuntimeSlotNativeOps | undefined = undefined;
export function setRuntimeSlotNativeOps(port: RuntimeSlotNativeOps): void { installed = port; }
export function runtimeSlotNativeOps(): RuntimeSlotNativeOps {
  if (installed === undefined) throw new Error('运行库代际存储尚未初始化');
  return installed;
}

/** marker 中的 manifest 摘要是现役交付描述符的内容身份；槽叶子名保留，兼容完整性校验。 */
export function lwjglGenerationDirectory(mcDir: string, slotDirectory: string, javaFeature: number = 0): string {
  // 派生 marker 包含源身份、feature、配方及输出摘要；17/21 即使复用相同 rawfile，
  // 也有独立代际。调用方必须传入本局选择，旧槽无需 JDK 专用输出而保持原身份。
  const slot = lwjglRuntimeSlot(slotDirectory, javaFeature);
  const identity: RegExpMatchArray | null = slot.marker.match(new RegExp('^manifest=([0-9a-f]{64})$', 'm'));
  if (identity === null) throw new Error('LWJGL 槽缺少内容身份：' + slot.id);
  return mcDir.replace(new RegExp('/+$'), '') + '/.amcl-runtime/' + identity[1] + '/' + slot.deploymentDirectory;
}

/** 扫描、孤儿认领和删除都交给native同一有界游标；避免ArkTS先无界列出整个根目录。
 * native核验当前指针、stage owner和跨进程读租约，未知归属与旧平铺槽不删除。
 */
export function collectUnusedLwjglGenerations(mcDir: string, slotDirectory: string, javaFeature: number = 0): number {
  const current: string = lwjglGenerationDirectory(mcDir, slotDirectory, javaFeature);
  return runtimeSlotNativeOps().collect(current);
}
