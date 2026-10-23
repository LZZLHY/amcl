/** 镜像候选的执行权限DTO：仅内存，调用方必须保持同一资产与尝试所有权。 */
import { AuthorizedTransferPolicy } from 'feature_core';
import { SideloadUpdateAsset } from 'update';
/** 公开发现结果可以复用，和每次消费的短时token分开；locator只用于固定官方API。 */
export interface SideloadMirrorCandidate { asset: SideloadUpdateAsset; assetKey: string; provider: string; locator: string; }
export interface SideloadDownloadSource {
  label: string;
  url: string;
  token?: string;
  /** 只在本轮内存流转的权限事实；公开资产键由download入口固定，不能另换原件。 */
  provider?: string;
  candidate?: SideloadMirrorCandidate;
  assetKey?: string;
  leaseGeneration?: number;
  leaseDeadlineMs?: number;
  authorizedPolicy?: AuthorizedTransferPolicy;
}

export type MirrorJsonFetcher = (url: string, body?: Object) => Promise<Record<string, Object>>;
