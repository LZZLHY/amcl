/** 两个同级镜像竞速与授权续领。协议实现由独立provider管理，统一下载仍由调用方执行。 */
import { SideloadUpdateAsset } from 'update';
import { DownloadFailure } from 'feature_core';
import { SideloadMirrorProviders } from './SideloadMirrorProviders';
import { SideloadDownloadSource, MirrorJsonFetcher } from './SideloadMirrorTypes';
export { SideloadDownloadSource } from './SideloadMirrorTypes';

export class SideloadDownloadSources {
  /** 兼容测试/旧受控入口的HTTP边界；只代理同一个provider实现。 */
  static get json(): MirrorJsonFetcher { return SideloadMirrorProviders.json; }
  static set json(fetcher: MirrorJsonFetcher) { SideloadMirrorProviders.setRequestBoundary(fetcher); }
  static identity(asset: SideloadUpdateAsset): string { return SideloadMirrorProviders.identity(asset); }
  private static now(): number { return SideloadMirrorProviders.now(); }
  /** 发现与领取由provider执行，兼容原调用方不会同时建立第二个选择器。
   * @throws 供应方错误由本类download按来源隔离。
   */
  static miawa(asset: SideloadUpdateAsset, active: () => boolean = (): boolean => true): Promise<SideloadDownloadSource> { return SideloadMirrorProviders.miawa(asset, active); }
  /** @throws 同级枫源失败由本类download隔离，不影响另一个已准备来源。 */
  static fyhub(asset: SideloadUpdateAsset, active: () => boolean = (): boolean => true): Promise<SideloadDownloadSource> { return SideloadMirrorProviders.fyhub(asset, active); }

  /** 备用lease实际出场时复检；已消费失败只有限重领一次，摘要/本地IO错误不重新授权。 */
  private static async transfer(asset: SideloadUpdateAsset, initial: SideloadDownloadSource, active: () => boolean,
    run: (source: SideloadDownloadSource) => Promise<void>): Promise<void> {
    let source = initial;
    const refresh = async (): Promise<SideloadDownloadSource> => {
      try {
        if (source.candidate !== undefined) return await SideloadMirrorProviders.authorize(source.candidate, active);
        if (source.provider === 'miawa') return await SideloadDownloadSources.miawa(asset, active);
        return await SideloadDownloadSources.fyhub(asset, active);
      } catch (error) { throw error as Error; } // 明确转交外层来源选择，保留typed failure不吞错。
    };
    for (let renewal = 0; renewal < 2; renewal++) {
      if (!active()) throw new Error('更新已取消');
      if (!SideloadMirrorProviders.sourceReady(source.url)) throw new Error('镜像仍在退避，正在使用其他来源');
      if (source.token !== undefined && source.assetKey !== SideloadDownloadSources.identity(asset)) throw new Error('下载权限的原件身份不匹配');
      if (source.token !== undefined && source.leaseDeadlineMs !== undefined &&
        source.leaseDeadlineMs - SideloadDownloadSources.now() < 5000) source = await refresh();
      if (source.authorizedPolicy !== undefined && source.leaseDeadlineMs !== undefined)
        source.authorizedPolicy.validForNewRequestMs = Math.max(1, Math.floor(source.leaseDeadlineMs - SideloadDownloadSources.now()));
      try { await run(source); return; }
      catch (error) {
        const detail = (error as DownloadFailure).detail;
        if (detail !== undefined && (detail.httpStatus === 429 || detail.httpStatus === 503) && (detail.retryAfterMs ?? 0) > 0) {
          SideloadMirrorProviders.noteCooldown(source.url, detail.retryAfterMs ?? 0); throw error as Error;
        }
        if (renewal !== 0 || source.token === undefined || detail === undefined || detail.needsNewLease !== true || !active()) throw error as Error;
        source = await refresh();
      }
    }
  }

  /** 两个 Promise 同时开始，以第一个成功授权的节点开始下载；所有失败均有处理，不产生游离拒绝。 */
  static async download(asset: SideloadUpdateAsset, active: () => boolean,
    run: (source: SideloadDownloadSource) => Promise<void>): Promise<void> {
    let ended = false;
    const current = (): boolean => !ended && active();
    const pending: Promise<SideloadDownloadSource | undefined>[] = [
      SideloadDownloadSources.miawa(asset, current).catch((): undefined => undefined),
      SideloadDownloadSources.fyhub(asset, current).catch((): undefined => undefined)
    ];
    const completed: boolean[] = [false, false];
    const successes: SideloadDownloadSource[] = [];
    let wake: (() => void) | undefined = undefined;
    pending.forEach((job: Promise<SideloadDownloadSource | undefined>, index: number): void => {
      job.then((source: SideloadDownloadSource | undefined): void => {
        completed[index] = true; if (source !== undefined) successes.push(source); wake?.();
      });
    });
    try {
    for (let consumed = 0; consumed < 2;) {
      if (!active()) throw new Error('更新已取消');
      if (successes.length > 0) {
        const source = successes.shift(); consumed++;
        if (source !== undefined) { try { await SideloadDownloadSources.transfer(asset, source, current, run); return; } catch (_) { if (!active()) throw new Error('更新已取消'); } }
      } else if (completed.every((done: boolean): boolean => done)) break;
      else await new Promise<void>((resolve): void => { wake = resolve; });
    }
    // GitHub 是第一兜底；官网独立副本只在所有前序来源失败后使用。
    if (!active()) throw new Error('更新已取消');
    try { await run({ label: 'GitHub', url: asset.url }); return; }
    catch (_) { if (!active()) throw new Error('更新已取消'); }
    if (asset.websiteUrl) { await run({ label: 'AMCL 官网', url: asset.websiteUrl }); return; }
    throw new Error('所有更新下载源暂不可用，请稍后重试');
    } finally { ended = true; }
  }
}
