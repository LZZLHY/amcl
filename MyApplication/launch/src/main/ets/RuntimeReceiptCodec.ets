/**
 * 受管安装收据的唯一纯序列化入口。producer和目标App reader预算预测共同消费此字段形状，
 * 不依赖Manager/下载/文件系统，避免循环依赖或两份手抄结构随字段演进而漂移。
 */
import { stringToUtf8 } from 'commons';
import { RuntimeDefinition, RuntimeBuild, RuntimeInstallReceipt, RUNTIME_INSTALL_RECEIPT_LIMIT } from './RuntimeCatalogTypes';

/** JS合法ISO时间戳最长27字节；预测旧reader预算时保守覆盖跨年/系统时间变化。 */
export const RUNTIME_RECEIPT_MAX_ISO_TIMESTAMP: string = '+010000-01-01T00:00:00.000Z';

/**
 * 返回将实际写入staging的JSON原文。调用者已冻结并验证runtime/build及原件身份；这里
 * 只统一生成字段和UTF-8字节预算。超限抛错，producer必须在发布目录之前停止。
 */
export function serializeRuntimeInstallReceipt(runtime: RuntimeDefinition, build: RuntimeBuild, javaMajor: number,
  archiveSha256: string, archiveSizeBytes: number, installedAt: string): string {
  const receipt: RuntimeInstallReceipt = {schemaVersion:1,runtimeId:runtime.id,javaMajor:javaMajor,buildId:build.id,
    recommendationRevision:runtime.recommendationRevision,archiveSha256:archiveSha256,archiveSizeBytes:archiveSizeBytes,
    installedAt:installedAt,origin:'catalog',runtime:runtime,build:build};
  const text = JSON.stringify(receipt);
  if (stringToUtf8(text).byteLength > RUNTIME_INSTALL_RECEIPT_LIMIT) throw new Error('JDK安装收据超过共享UTF-8预算，旧安装已保留');
  return text;
}
