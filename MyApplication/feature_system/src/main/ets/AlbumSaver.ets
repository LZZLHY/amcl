/**
 * AlbumSaver.ets — 把网络图片保存到系统相册（无需任何存储权限）
 *
 * 背景：HarmonyOS NEXT 不向普通应用授予外部存储 / 媒体写入权限（WRITE_IMAGEVIDEO 为受限
 * 权限）。保存图片到相册的【免权限】官方做法是 `photoAccessHelper.showAssetsCreationDialog`：
 * 系统弹一个保存确认框（这就是用户授权），通过后返回一个可写的相册媒体 uri，应用把图片内容
 * 写进去即可。手机 / 平板一视同仁，**都不需要在 module.json5 里申请权限**。
 *
 * 用途：赞助页（SponsorPage）WebView 里点收款码「下载」时，onDownloadStart 拿到图片 url，
 * 调本工具下载并保存。下载走项目原生 libcurl 引擎（DownloadManager），天然支持 HTTP 明文，
 * 不受 net.http 明文限制影响。
 */

import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DownloadManager, DownloadTaskSpec, DownloadTaskView } from 'feature_core';
import { formatError } from 'commons';

const TAG = 'AlbumSaver';

/** 保存结果：'saved' 成功 / 'cancelled' 用户取消保存弹窗 / 抛错=失败。 */
export type AlbumSaveResult = 'saved' | 'cancelled';

export class AlbumSaver {
  /**
   * 下载网络图片并保存到相册。仅支持 http(s) 直链（blob:/data: 不支持）。
   * @throws Error 下载失败 / 写入失败。用户在系统弹窗点取消返回 'cancelled'（不抛错）。
   */
  static async saveImageUrl(context: common.UIAbilityContext, url: string): Promise<AlbumSaveResult> {
    if (!url || !(url.startsWith('http://') || url.startsWith('https://'))) {
      throw new Error('不支持的图片地址');
    }
    let ext = AlbumSaver.extFromUrl_(url);
    let localPath = context.cacheDir + '/amcl_save_' + Date.now() + '.' + ext;

    // 1) 下载到应用缓存（原生 libcurl，支持 HTTP 明文）
    let spec: DownloadTaskSpec = {
      name: 'album-save-' + Date.now(),
      files: [{ localPath: localPath, urls: [url], allowedRoot: context.cacheDir }],
    };
    let view: DownloadTaskView;
    try {
      view = await DownloadManager.instance().createAndWait(spec);
    } catch (e) {
      // 下载 reject 时可能已写入部分临时文件，清理后再抛出，避免 cacheDir 残留。
      try { fs.unlinkSync(localPath); } catch (cleanupError) { /* ignore */ }
      throw e as Error;
    }
    if (!view.success) {
      try { fs.unlinkSync(localPath); } catch (cleanupError) { /* ignore */ }
      throw new Error('图片下载失败');
    }

    try {
      // 2) 系统保存弹窗（免权限）→ 返回可写相册 uri
      let helper = photoAccessHelper.getPhotoAccessHelper(context);
      let config: photoAccessHelper.PhotoCreationConfig = {
        title: 'AMCL_' + Date.now(),
        fileNameExtension: ext,
        photoType: photoAccessHelper.PhotoType.IMAGE,
        subtype: photoAccessHelper.PhotoSubtype.DEFAULT,
      };
      let srcUri = fileUri.getUriFromPath(localPath);
      let destUris = await helper.showAssetsCreationDialog([srcUri], [config]);
      if (!destUris || destUris.length === 0) {
        return 'cancelled';   // 用户取消保存
      }
      AlbumSaver.copyInto_(localPath, destUris[0]);
      hilog.info(0x0000, TAG, 'saved image to album');
      return 'saved';
    } finally {
      // 清理缓存临时文件
      try { fs.unlinkSync(localPath); } catch (e) { /* ignore */ }
    }
  }

  /** 把缓存文件内容写进相册返回的目标 uri。 */
  private static copyInto_(srcPath: string, destUri: string): void {
    let src: fs.File | null = null;
    let dest: fs.File | null = null;
    try {
      src = fs.openSync(srcPath, fs.OpenMode.READ_ONLY);
      dest = fs.openSync(destUri, fs.OpenMode.READ_WRITE);
      fs.copyFileSync(src.fd, dest.fd);
    } catch (e) {
      hilog.error(0x0000, TAG, 'copyInto failed: %{public}s', formatError(e));
      throw e as Error;
    } finally {
      if (src) { try { fs.closeSync(src); } catch (_) { /* */ } }
      if (dest) { try { fs.closeSync(dest); } catch (_) { /* */ } }
    }
  }

  /** 从 url 推断图片扩展名（去掉 query），非常见图片格式回退 png。 */
  private static extFromUrl_(url: string): string {
    let q = url.indexOf('?');
    let u = q >= 0 ? url.substring(0, q) : url;
    let dot = u.lastIndexOf('.');
    if (dot >= 0) {
      let e = u.substring(dot + 1).toLowerCase();
      if (e === 'png' || e === 'jpg' || e === 'jpeg' || e === 'webp' || e === 'gif') return e;
    }
    return 'png';
  }
}
