import { requiredJdkMajorForMc } from 'commons';
import { DownloadManager, getMetadataCacheStore, getRelayClient, ModLoaderManager, ModLoaderType } from 'feature_core';
import { getModrinthSourceMode, ModrinthRepository, pickBestVersion, pickPrimaryFile, RemoteFile, RemoteVersion,
  resolveModrinthSourcePreference } from 'mods';
import { getLoaderInfo, LoaderKey } from './LoaderCatalog';

/** 界面实际提供的加载器顺序；引擎能识别的其他类型不能变成未经产品开放的安装入口。 */
export const VERSION_LOADER_KEYS: LoaderKey[] = ['vanilla', 'fabric', 'forge', 'neoforge', 'quilt'];
export function panelLoaderTypes(manager: ModLoaderManager): ModLoaderType[] {
  return manager.getSupportedLoaderTypes().filter((type: ModLoaderType): boolean => {
    const key = type as string as LoaderKey;
    return VERSION_LOADER_KEYS.includes(key) && getLoaderInfo(key).supported;
  });
}

export function loaderAtChoice(index: number): ModLoaderType | null {
  if (index <= 0 || index >= VERSION_LOADER_KEYS.length) return null;
  const key = VERSION_LOADER_KEYS[index];
  return getLoaderInfo(key).supported ? key as string as ModLoaderType : null;
}

/** 用户未指定实例名时使用页面的命名规则；Forge 系安装器有独立的最低 JDK 要求。 */
export function suggestedVersionName(game: string, loader: ModLoaderType | null, version: string): string {
  if (loader === null || !version) return game;
  if (loader === ModLoaderType.FABRIC) return 'fabric-loader-' + version + '-' + game;
  return game + '-' + loader + '-' + version;
}
export function installerJdkMajor(game: string, loader: ModLoaderType | null): number {
  return loader === ModLoaderType.FORGE || loader === ModLoaderType.NEOFORGE ? requiredJdkMajorForMc(game) : 0;
}

export interface FabricApiSelection {
  version: RemoteVersion | null;
  primary: RemoteFile | null;
  error: string;
}

/** 选择器与安装流程共用来源偏好和真实 Modrinth 候选，不能按列表位置猜兼容版本。 */
export function fabricApiRepository(source: () => string, cache: () => boolean): ModrinthRepository {
  return new ModrinthRepository(DownloadManager.instance(), getMetadataCacheStore(),
    () => resolveModrinthSourcePreference(source(), getModrinthSourceMode(), getRelayClient().isEnabled()),
    'AMCL/1.0.0 (https://github.com/axecraft/amcl)', cache);
}
/** 图标与安装资格分开读取。项目图片获取失败仍使用统一的任务默认图标。 */
export async function loadFabricApiIcon(repo: ModrinthRepository): Promise<string> {
  try {
    return (await repo.getProjectsByIds(['fabric-api']))[0]?.iconUrl ?? '';
  } catch (_) {
    return '';
  }
}

export async function loadFabricApiSelection(repo: ModrinthRepository, game: string): Promise<FabricApiSelection> {
  const versions = await repo.getVersions('fabric-api', ['fabric'], [game]);
  const version = pickBestVersion(versions, 'fabric', game);
  if (version === null) return { version: null, primary: null, error: '该 MC 版本无可用的 Fabric API' };
  const primary = pickPrimaryFile(version.files);
  if (primary === null || !primary.url) return { version: null, primary: null, error: 'Fabric API 主文件不可下载' };
  return { version: version, primary: primary, error: '' };
}
