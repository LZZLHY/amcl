/**
 * 普通 MC 安装意图与独占工作目录的持久身份。冷启动只列出计划，不启动 Native 下载。
 * 用户重新提交同一意图时复用 owner；目标实例另有 pending 收据，清理不得凭同名目录推断归属。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ensureDirSync } from 'commons';
import { safeBaseName } from '../modloader/MavenUtils';

export const MC_INSTALL_PENDING: string = '.amcl-mc-pending.json';

/** 路径由调用者的当前根验证，恢复数据不能把任务带往别的游戏目录。 */
export interface McInstallSession {
  schemaVersion: number;
  id: string;
  gameVersion: string;
  loaderType: string;
  loaderVersion: string;
  versionName: string;
  mcDir: string;
  complete: boolean;
}

/** 原子 JSON 保存：完整写入并 fsync 后替换，再刷父目录；异常向上传递以保留恢复现场。 */
export function writeMcInstallRecord(path: string, value: Object): void {
  let temporary = path + '.writing';
  let handle = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    let bytes = new util.TextEncoder().encodeInto(JSON.stringify(value));
    let offset = 0;
    while (offset < bytes.byteLength) {
      let written = fs.writeSync(handle.fd, bytes.slice(offset).buffer);
      if (written <= 0) throw new Error('安装恢复记录写入不完整');
      offset += written;
    }
    fs.fsyncSync(handle.fd);
  } finally { fs.closeSync(handle); }
  fs.renameSync(temporary, path);
  let parent = fs.openSync(path.substring(0, path.lastIndexOf('/')), fs.OpenMode.READ_ONLY);
  try { fs.fsyncSync(parent.fd); } finally { fs.closeSync(parent); }
}

/** 保存位置固定在应用 filesDir 中；id 只允许安全单段，禁止链接形式的记录目录。 */
export function saveMcInstallSession(filesDir: string, session: McInstallSession): void {
  if (safeBaseName(session.id) !== session.id || session.id.length === 0) throw new Error('MC 安装身份不安全');
  let dir = filesDir + '/mc-install-work';
  ensureDirSync(dir);
  if (fs.lstatSync(dir).isSymbolicLink()) throw new Error('MC 恢复目录不能是链接');
  writeMcInstallRecord(dir + '/' + session.id + '.json', session);
}

/** 只列出当前根的合法未完成计划；损坏、旧根或未知加载器记录原样保留，不自动删除。 */
export function listMcInstallRecovery(filesDir: string, mcDir: string): McInstallSession[] {
  let result: McInstallSession[] = [];
  let dir = filesDir + '/mc-install-work';
  try {
    if (fs.lstatSync(dir).isSymbolicLink()) return result;
    for (let name of fs.listFileSync(dir)) {
      if (!name.endsWith('.json') || safeBaseName(name) !== name) continue;
      try {
        if (!fs.lstatSync(dir + '/' + name).isFile() || fs.lstatSync(dir + '/' + name).isSymbolicLink()) continue;
        let record = JSON.parse(fs.readTextSync(dir + '/' + name)) as McInstallSession;
        if (record === null || record.schemaVersion !== 1 || record.complete !== false || record.mcDir !== mcDir
          || name !== record.id + '.json' || safeBaseName(record.id) !== record.id
          || safeBaseName(record.gameVersion) !== record.gameVersion || safeBaseName(record.versionName) !== record.versionName
          || typeof record.loaderVersion !== 'string'
          || ['', 'fabric', 'forge', 'neoforge', 'quilt', 'optifine'].indexOf(record.loaderType) < 0) continue;
        result.push(record);
      } catch (e) { /* 不完整记录没有恢复资格，保留原始材料。 */ }
    }
  } catch (e) { /* 首次安装还没有恢复目录。 */ }
  return result;
}

/** 检查普通目录中的持久 owner；错误和链接都按无归属处理，不能据此清理。 */
export function ownsMcInstallDirectory(dir: string, owner: string): boolean {
  try {
    let directory = fs.lstatSync(dir);
    let marker = fs.lstatSync(dir + '/' + MC_INSTALL_PENDING);
    if (!directory.isDirectory() || directory.isSymbolicLink() || !marker.isFile() || marker.isSymbolicLink()) return false;
    let receipt = JSON.parse(fs.readTextSync(dir + '/' + MC_INSTALL_PENDING)) as Record<string, string>;
    return receipt['id'] === owner;
  } catch (e) { return false; }
}
