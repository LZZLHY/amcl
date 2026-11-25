/** 软件更新回执只记录官方包目标和受理状态。选择器、文件权限和更新操作仍由原页面持有。 */
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AtomicFileWriter } from 'commons';
import { LauncherSkillBus } from './LauncherSkillBus';
import { SettingsSkillData, settingFailure, settingKeys, settingText } from './SettingsSkillValues';

interface SelectionRow {
  reference: string;
  outcome: SettingsSkillData;
}

export class UpdatePackageSelection {
  private static active: Set<string> = new Set<string>();

  /** 单进程启动器同步提交有界的小文件，不保存用户 URI；途中进程退出的 waiting 只能报告未知。 */
  private static rows(path: string): SelectionRow[] {
    if (!fs.accessSync(path)) return [];
    if (fs.statSync(path).size > 64 * 1024) throw new Error('选择回执过大');
    const rows = JSON.parse(fs.readTextSync(path)) as SelectionRow[];
    if (!Array.isArray(rows) || rows.length > 32 || rows.some((row: SelectionRow): boolean =>
      !row || typeof row.reference !== 'string' || !row.outcome || typeof row.outcome !== 'object' ||
      !['waiting','accepted','cancelled','failed','unknown'].includes(settingText(row.outcome, 'state')) ||
      (row.outcome['state'] === 'accepted' && !settingText(row.outcome, 'target')))) {
      throw new Error('选择回执异常');
    }
    return rows;
  }

  static begin(files: string, select: () => Promise<SettingsSkillData>): SettingsSkillData {
    const path = files + '/launcher-update-selections.json';
    const reference = util.generateRandomUUID();
    try {
      const rows = UpdatePackageSelection.rows(path);
      // 只淘汰最旧且已离开本进程执行链的记录，正在等待用户的其它引用继续可查。
      if (rows.length >= 32) {
        const completed = rows.findIndex((row: SelectionRow): boolean => !UpdatePackageSelection.active.has(row.reference));
        if (completed < 0) return { 'state':'busy', 'reason':'pendingSelections' };
        rows.splice(completed, 1);
      }
      rows.push({ reference:reference, outcome:{ 'state':'waiting' } });
      AtomicFileWriter.write(path, JSON.stringify(rows));
    } catch (_) { return settingFailure('selectionReceiptUnavailable'); }
    UpdatePackageSelection.active.add(reference);
    const work = UpdatePackageSelection.complete(path, reference, select);
    LauncherSkillBus.followUserDecision('openUpdateSource', work);
    return { 'state':'needsUser', 'reason':'systemFilePicker', 'reference':reference };
  }

  /** 安装页面成功接手后才发布 accepted。回执写入失败仍不重放已经发生的选择或路由操作。 */
  private static async complete(path: string, reference: string, select: () => Promise<SettingsSkillData>): Promise<void> {
    let outcome: SettingsSkillData;
    try { outcome = await select(); }
    catch (_) { outcome = { 'state':'unknown', 'reason':'selectionUnconfirmed' }; }
    try {
      const rows = UpdatePackageSelection.rows(path);
      const row = rows.find((item: SelectionRow): boolean => item.reference === reference);
      if (row) {
        row.outcome = outcome;
        AtomicFileWriter.write(path, JSON.stringify(rows));
      }
    } catch (_) { /* 读取端将未提交的 waiting 报为未知，不冒认成功。 */ }
    finally { UpdatePackageSelection.active.delete(reference); }
  }

  /** 只读本机原操作结果，任何路由都不能凭引用取得安装权。 */
  static read(files: string, args: SettingsSkillData): SettingsSkillData {
    const ref = settingText(args, 'reference');
    if (!ref || !settingKeys(args, ['reference'])) return settingFailure('invalidArguments');
    try {
      const row = UpdatePackageSelection.rows(files + '/launcher-update-selections.json')
        .find((item: SelectionRow): boolean => item.reference === ref);
      if (!row) return settingFailure('selectionExpired');
      if (row.outcome['state'] === 'waiting' && !UpdatePackageSelection.active.has(ref)) {
        return { 'state':'unknown', 'reason':'selectionUnconfirmed' };
      }
      return row.outcome;
    } catch (_) { return { 'state':'unknown', 'reason':'selectionReceiptUnavailable' }; }
  }
}
