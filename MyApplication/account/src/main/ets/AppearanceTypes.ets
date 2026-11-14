/**
 * 离线外观的数据契约与纯数据校验。
 *
 * 文件资产属于应用共享库，账号只持有不可变的资产描述和自己的选择。所有公开
 * 拷贝函数均创建新对象，避免两个账号或编辑草稿意外共享可变引用。此文件不执行
 * 文件系统、偏好存储或 UI 操作，游戏进程可从本局账号快照安全恢复相同描述。
 */

/** 共享库中的纹理用途；同一原始文件可分别登记为皮肤和披风。 */
export type AppearanceKind = 'skin' | 'cape';
/** 手臂模型属于账号选择，不属于共享 PNG 文件，多个账号可分别选择。 */
export type AppearanceModel = 'CLASSIC' | 'SLIM';

/** 经过导入校验的共享纹理描述；持久化时不包含设备绝对沙箱路径。 */
export interface AppearanceAsset {
  id: string;
  kind: AppearanceKind;
  name: string;
  sha256: string;
  relativePath: string;
  width: number;
  height: number;
  createdAt: number;
}

/** 单个离线账号的外观选择；缺失皮肤表示游戏默认，缺失披风表示不佩戴。 */
export interface OfflineAppearance {
  revision: number;
  skin?: AppearanceAsset;
  cape?: AppearanceAsset;
  model: AppearanceModel;
}

/** 本地图片来源协议，仅用于 UI 路由，不是可交给游戏或 HTTP 客户端的 URL。 */
export const ACCOUNT_TEXTURE_PREFIX: string = 'amcl-texture:';

/** 创建独立的默认配置；不能复用一个可被多个账号共同修改的默认对象。 */
export function defaultOfflineAppearance(): OfflineAppearance {
  return { revision: 0, model: 'CLASSIC' };
}

/**
 * 校验快照/偏好恢复的资产描述。仅接受摘要决定的内部路径，禁止路径穿越、绝对
 * 路径以及把任意用户选中文件包装成合法库资产。真实文件摘要由资产库/运行侧核对。
 */
export function isAppearanceAssetValid(asset: AppearanceAsset | undefined, kind: AppearanceKind): boolean {
  if (!asset || asset.kind !== kind || typeof asset.id !== 'string'
    || typeof asset.name !== 'string' || asset.name.trim().length === 0 || asset.name.length > 80
    || new RegExp('[\\x00-\\x1f\\x7f]').test(asset.name) || typeof asset.sha256 !== 'string'
    || !new RegExp('^[0-9a-f]{64}$').test(asset.sha256)
    || asset.id !== kind + '-' + asset.sha256
    || asset.relativePath !== 'account-textures/' + asset.sha256 + '.png'
    || !Number.isFinite(asset.createdAt) || asset.createdAt <= 0) return false;
  return asset.width === 64 && (kind === 'skin' ? (asset.height === 32 || asset.height === 64) : asset.height === 32);
}

/** 复制完整资产描述；用于跨账号选择及向 UI 交付，不泄露内部可变引用。 */
export function copyAppearanceAsset(asset: AppearanceAsset): AppearanceAsset {
  return { id: asset.id, kind: asset.kind, name: asset.name, sha256: asset.sha256,
    relativePath: asset.relativePath, width: asset.width, height: asset.height, createdAt: asset.createdAt };
}

/**
 * 从可选旧记录恢复外观；皮肤和披风分别降级，坏皮肤不会禁用有效披风。64×32
 * 旧皮肤没有独立细手臂语义，统一恢复为 Classic，避免预览和游戏模型不一致。
 */
export function copyOfflineAppearance(value?: OfflineAppearance): OfflineAppearance {
  const result: OfflineAppearance = defaultOfflineAppearance();
  if (!value) return result;
  result.revision = Number.isSafeInteger(value.revision) && value.revision >= 0 ? value.revision : 0;
  result.model = value.model === 'SLIM' ? 'SLIM' : 'CLASSIC';
  if (isAppearanceAssetValid(value.skin, 'skin')) result.skin = copyAppearanceAsset(value.skin!);
  if (isAppearanceAssetValid(value.cape, 'cape')) result.cape = copyAppearanceAsset(value.cape!);
  if (result.skin?.height === 32) result.model = 'CLASSIC';
  return result;
}

/** 名称是离线账号的用户可见唯一键；去掉两端空格，大小写变化不产生第二个账号。 */
export function offlineAccountNameKey(username: string): string {
  return username.trim().toLowerCase();
}
