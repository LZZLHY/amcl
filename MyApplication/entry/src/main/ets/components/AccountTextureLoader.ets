/**
 * 账号预览的统一图片入口。
 *
 * 远程皮肤继续使用 commons 已有的共享 HTTP 缓存；本地皮肤由账号资产库按受限的
 * amcl-texture: 引用解码。调用方只借用返回的 PixelMap，不得 release 共享原图。
 * 组件自己裁出的头像、披风或绘制目标仍由各组件单独管理。
 */
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { getRemotePixelMap } from 'commons';
import { getAppearanceLibrary } from 'account';

/** 是否为应用沙箱中的账号纹理；本地加载失败不能改为访问第三方头像服务。 */
export function isLocalAccountTexture(source: string): boolean {
  return source.startsWith('amcl-texture:');
}

/**
 * 返回共享原图或 null。上下文暂不可用、引用损坏和文件已丢失均按可恢复的预览失败
 * 处理，不让账号面板因图片问题崩溃；实际文件是否合法仍由资产库统一校验。
 */
export async function loadAccountTexture(source: string): Promise<image.PixelMap | null> {
  if (source.length === 0) return null;
  if (!isLocalAccountTexture(source)) return getRemotePixelMap(source);
  const context = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
  if (context === undefined) return null;
  try {
    const library = getAppearanceLibrary();
    await library.init(context);
    return await library.loadTexture(source);
  } catch (_) {
    return null;
  }
}
