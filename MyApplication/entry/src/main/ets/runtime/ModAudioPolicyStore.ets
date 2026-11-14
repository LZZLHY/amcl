/**
 * 启动器唯一写入的跨进程录音撤销记录。固定小文件原子发布，游戏进程只读；
 * epoch变化使已经开始的旧局永久失去采集资格，重新开启需要下一局重新捕获该身份。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { ProcessPreferences } from 'commons';

const FILE_NAME: string = 'mod-audio-policy.v1';

export class ModAudioPolicyStore {
  /** 只读现存完整记录；损坏/不存在均视为未初始化，由原启动器owner修复而非游戏进程写回。 */
  private static read_(context: common.UIAbilityContext): string[] | undefined {
    try {
      const text: string = fs.readTextSync(context.filesDir + '/' + FILE_NAME);
      const match = /^v1 ([0-9]{1,16}) ([01])\n$/.exec(text);
      if (match !== null && Number.isSafeInteger(Number(match[1])) && Number(match[1]) > 0) return [match[1], match[2]];
    } catch (_) {}
    return undefined;
  }

  /** 初始化不改变相同选择的epoch；Entry销毁/切前后台不写这里，避免误撤销独立前台游戏。 */
  static ensure(context: common.UIAbilityContext, enabled: boolean): void {
    if (ProcessPreferences.isGameProcess()) return;
    const previous: string[] | undefined = ModAudioPolicyStore.read_(context);
    if (previous !== undefined && previous[1] === (enabled ? '1' : '0')) return;
    ModAudioPolicyStore.publish(context, enabled);
  }

  /**
   * 只允许原设置owner发布。先fsync完整临时文件再rename，Native读取不到半条记录。
   * 选择每次显式变更均增加epoch，关闭后即使又开启也不能复活旧局的录音句柄。
   */
  static publish(context: common.UIAbilityContext, enabled: boolean): void {
    if (ProcessPreferences.isGameProcess()) throw new Error('游戏进程不能修改录音政策');
    const previous: string[] | undefined = ModAudioPolicyStore.read_(context);
    const epoch: number = previous === undefined ? 1 : Number(previous[0]) + 1;
    if (!Number.isSafeInteger(epoch)) throw new Error('录音政策版本已超限');
    const path: string = context.filesDir + '/' + FILE_NAME;
    const temporary: string = path + '.pending';
    const file: fs.File = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      const value: string = 'v1 ' + epoch + ' ' + (enabled ? '1' : '0') + '\n';
      if (fs.writeSync(file.fd, value) !== value.length) throw new Error('录音政策写入不完整');
      fs.fsyncSync(file.fd);
    } finally { fs.closeSync(file); }
    fs.renameSync(temporary, path);
  }
}
