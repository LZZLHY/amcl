/**
 * 整合包独立来源服务。仓库和缓存寿命归安装任务，不读取 ModBrowsePage.router_。
 * 下载页、版本管理的补齐入口和重启恢复使用同一工厂，保持精确 fileId 解析语义。
 */
import { APP_NAME, APP_VERSION } from 'commons';
import { DownloadManager, getMetadataCacheStore } from 'feature_core';
import { CurseForgeRepository } from './CurseForgeRepository';
import { isMcimAvailable } from './ModSourceProber';
import { CfFileResolver, CfFileResolution } from './ModpackInstaller';

export function createModpackFileResolver(cacheEnabled: boolean = true): CfFileResolver {
  let repository = new CurseForgeRepository(DownloadManager.instance(), getMetadataCacheStore(),
    APP_NAME + '/' + APP_VERSION, (): boolean => isMcimAvailable(), (): boolean => cacheEnabled);
  return async (projectId: number, fileId: number, gameVersion: string, loader: string): Promise<CfFileResolution> => {
    let file = await repository.resolveFileDownloadInfo(projectId.toString(), fileId.toString(), gameVersion, loader);
    return { filename: file.filename, urls: file.urls, sha1: file.sha1, size: file.size, targetDirectory: file.targetDirectory };
  };
}
