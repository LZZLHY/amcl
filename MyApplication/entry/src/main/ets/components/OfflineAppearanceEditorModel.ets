/**
 * 离线账号外观编辑的数据协调器。
 *
 * 账号保存与共享资产库是两种不同事务：导入立即加入全应用库，选择和改名仅在用户
 * 按“应用到此账号”后提交。视图只保存选择 ID 等临时状态，不直接拼写沙箱路径。
 */
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import {
  AccountType, OfflineAccount, AppearanceAsset, AppearanceKind, AppearanceModel,
  OfflineAppearance, getAccountManager, getAppearanceLibrary,
} from 'account';

/** 一次打开编辑器所用的不可变快照；账号 revision 是并发提交的比较依据。 */
export interface OfflineAppearanceEditorSnapshot {
  username: string;
  appearance: OfflineAppearance;
  skins: AppearanceAsset[];
  capes: AppearanceAsset[];
}

export class OfflineAppearanceEditorModel {
  /** 只接受列表中仍存在的离线账号，不把微软或第三方角色转成本地账号。 */
  private requireAccount(id: string): OfflineAccount {
    const account = getAccountManager().findById(id);
    if (account === undefined || account.type !== AccountType.OFFLINE) {
      throw new Error('此离线账号已被移除，请返回账户列表');
    }
    return account as OfflineAccount;
  }

  /** 库初始化只读取当前应用目录，随后返回账号与两类库的独立快照。 */
  async load(context: common.UIAbilityContext, id: string): Promise<OfflineAppearanceEditorSnapshot> {
    await getAppearanceLibrary().init(context);
    const account = this.requireAccount(id);
    return { username: account.username, appearance: account.getOfflineAppearance(),
      skins: getAppearanceLibrary().list('skin'), capes: getAppearanceLibrary().list('cape') };
  }

  /**
   * 从系统文件管理器导入一张原始 PNG。后缀过滤只改善选择体验，真实格式、大小、
   * 帧数和持久化由资产库验证；用户未选文件时返回 null，不改账号或库。
   */
  async importFile(context: common.UIAbilityContext, kind: AppearanceKind): Promise<AppearanceAsset | null> {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['PNG 纹理|.png'];
    const selected = await new picker.DocumentViewPicker(context).select(options);
    if (selected.length === 0) return null;
    await getAppearanceLibrary().init(context);
    return await getAppearanceLibrary().importFromUri(selected[0], kind);
  }

  /** 删除库条目前检查所有账号引用；一个账号选用它时，其他账号不能破坏该选择。 */
  async removeAsset(id: string): Promise<void> {
    if (getAccountManager().isAppearanceAssetUsed(id)) {
      throw new Error('有离线账号正在使用这张纹理，请先为这些账号更换或恢复默认');
    }
    await getAppearanceLibrary().remove(id);
  }

  /** 重新读取库，避免导入或删除后继续展示异步操作开始时的数组。 */
  list(kind: AppearanceKind): AppearanceAsset[] { return getAppearanceLibrary().list(kind); }

  /**
   * 将名称和外观一次提交到当前账号。只从当时仍在库中的条目取引用；revision 防止
   * 旧编辑器覆盖另一处已经确认的更改，AccountManager 最终仍会再次核对和持久确认。
   */
  async save(id: string, expectedRevision: number, username: string, skinId: string,
    capeId: string, model: AppearanceModel): Promise<OfflineAccount> {
    const account = this.requireAccount(id);
    if (account.getOfflineAppearance().revision !== expectedRevision) {
      throw new Error('此账号的外观已在其他位置更新，请返回后重新编辑');
    }
    const appearance: OfflineAppearance = { revision: expectedRevision, model: model };
    if (skinId.length > 0) {
      const skin = this.list('skin').find((item: AppearanceAsset): boolean => item.id === skinId);
      if (skin === undefined) throw new Error('所选皮肤已不在皮肤库中，请重新选择');
      appearance.skin = skin;
      if (skin.height === 32) appearance.model = 'CLASSIC';
    }
    if (capeId.length > 0) {
      const cape = this.list('cape').find((item: AppearanceAsset): boolean => item.id === capeId);
      if (cape === undefined) throw new Error('所选披风已不在披风库中，请重新选择');
      appearance.cape = cape;
    }
    return await getAccountManager().editOfflineAccount(id, username, appearance);
  }
}
