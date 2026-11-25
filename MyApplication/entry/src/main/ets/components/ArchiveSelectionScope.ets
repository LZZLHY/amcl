import entryNative from 'libentry.so';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 标识原业务范围。系统选择器暂时接管前台并不等于页面已销毁，检查应针对目标实例与目录。 */
export interface ArchiveSelectionScope {
  root: string;
  current: () => boolean;
  consent?: () => Promise<boolean>;
}
interface DirectoryPin { path:string; ino:string; handle:fs.File; }
function normalized(path:string):string { return path.replace(/\\/g,'/').replace(/\/+$/,''); }
function absent(error:Error):boolean { return (error as BusinessError).code===13900002; }
function pinDir(path:string):DirectoryPin {
  const st=fs.lstatSync(path);
  if (!st.isDirectory() || st.isSymbolicLink()) throw new Error('目录不是原来的普通目录');
  const handle=fs.openSync(path,fs.OpenMode.READ_ONLY|fs.OpenMode.DIR|fs.OpenMode.NOFOLLOW);
  try {
    if (fs.statSync(handle.fd).ino!==st.ino) throw new Error('目录已经变化');
    return {path:path,ino:String(st.ino),handle:handle};
  } catch (e) { fs.closeSync(handle); throw e as Error; }
}
export function missingEntry(path:string):boolean {
  try { fs.lstatSync(path); return false; }
  catch (e) { if (absent(e as Error)) return true; throw e as Error; }
}

/** 持有原目录链的描述符防止 inode 回收复用。只以目录对象身份核验，同一批导入导致的 mtime 变化不作换代。 */
export class ArchiveDirectory {
  readonly path:string;
  private readonly scope:ArchiveSelectionScope|undefined;
  private pins:DirectoryPin[]=[];
  private missing:string[]=[];
  private constructor(path:string,scope?:ArchiveSelectionScope) { this.path=path; this.scope=scope; }
  static capture(path:string,scope?:ArchiveSelectionScope):ArchiveDirectory {
    const target=normalized(path);
    if (!target || target.split('/').some(p=>p==='.' || p==='..')) throw new Error('无效目录');
    const guard=new ArchiveDirectory(target,scope);
    try {
      let root=scope?normalized(scope.root):target;
      if (!scope) {
        // 单文件 JDK/整合包暂存目录可能尚未创建；沿实际父目录寻找首个已存在的位置。
        while (missingEntry(root)) { const cut=root.lastIndexOf('/');if (cut<=0) throw new Error('找不到已授权的父目录');root=root.slice(0,cut); }
      }
      if (!root || (target!==root && !target.startsWith(root+'/')) || (scope && !scope.current())) throw new Error('目标范围已改变');
      guard.pins.push(pinDir(root));
      let cursor=root;
      for (const part of target.slice(root.length).split('/').filter(v=>v.length>0)) {
        cursor+='/'+part;
        if (guard.missing.length || missingEntry(cursor)) guard.missing.push(cursor);
        else guard.pins.push(pinDir(cursor));
      }
      return guard;
    } catch (e) {guard.close();throw e as Error;}
  }
  check():void {
    if (this.scope && !this.scope.current()) throw new Error('目标业务已切换');
    this.checkIdentity();
  }
  checkIdentity():void {
    if(!this.pins.length) throw new Error('原目录已失效');
    for(const pin of this.pins) {
      const s=fs.lstatSync(pin.path);
      if (!s.isDirectory() || s.isSymbolicLink() || String(s.ino)!==pin.ino || String(fs.statSync(pin.handle.fd).ino)!==pin.ino) throw new Error('原目录已移动或替换');
    }
    if (this.missing.length && !missingEntry(this.missing[0])) throw new Error('原先不存在的目标已被其他操作创建');
  }
  /** 业务同步调用 Native 时借用已核实的目标目录描述符，打开的目录链仍属于本对象。 */
  descriptor(): number {
    this.check();
    if (this.missing.length) throw new Error('目标目录不存在');
    return this.pins[this.pins.length - 1].handle.fd;
  }
  ensure():void {
    this.check();
    while(this.missing.length) {
      const path=this.missing[0];fs.mkdirSync(path);this.pins.push(pinDir(path));this.missing.shift();
      this.check();
    }
  }
  close():void {
    for (const pin of this.pins.reverse()) { try { fs.closeSync(pin.handle); } catch (_) {} }
    this.pins=[];this.missing=[];
  }
}

/** 可读源同样绑定原始 inode；另存时不会从同名的新文件取数据。 */
export class ArchiveSource {
  readonly handle:fs.File;
  private readonly path:string;
  private readonly inode:string;
  private readonly size:number;
  private readonly revision:string;
  private readonly directory:boolean;
  constructor(path:string,directory:boolean) {
    const st=fs.lstatSync(path);
    if (st.isSymbolicLink() || (directory?!st.isDirectory():!st.isFile())) throw new Error('要导出的对象不可读');
    this.path=path;this.inode=String(st.ino);this.size=st.size;this.revision=String(st.mtimeNs ?? st.mtime)+':'+String(st.ctimeNs ?? st.ctime);this.directory=directory;
    this.handle=fs.openSync(path,fs.OpenMode.READ_ONLY|fs.OpenMode.NOFOLLOW|(directory?fs.OpenMode.DIR:0));
    try { this.check(); } catch (e) { this.close();throw e as Error; }
  }
  check():void {
    const st=fs.lstatSync(this.path);
    if (st.isSymbolicLink() || String(st.ino)!==this.inode || String(fs.statSync(this.handle.fd).ino)!==this.inode ||
      (this.directory?!st.isDirectory():!st.isFile()) || st.size!==this.size ||
      String(st.mtimeNs ?? st.mtime)+':'+String(st.ctimeNs ?? st.ctime)!==this.revision) throw new Error('原文件或目录已经变化');
  }
  close():void { try {fs.closeSync(this.handle);} catch (_) {} }
}

/** 确认框所指的对象。目录链和条目同时保持打开，系统不能把已移除条目的 inode 分给后来同名的新对象。 */
export class ArchiveEntryConfirmation {
  private readonly root: string;
  private readonly directory: string;
  private readonly owner: string;
  readonly name: string;
  readonly isDirectory: boolean;
  private readonly parent: ArchiveDirectory;
  private readonly entry: ArchiveSource;

  private constructor(root: string, directory: string, owner: string, name: string, isDirectory: boolean,
    parent: ArchiveDirectory, entry: ArchiveSource) {
    this.root = root; this.directory = directory; this.owner = owner; this.name = name;
    this.isDirectory = isDirectory; this.parent = parent; this.entry = entry;
  }

  static capture(root: string, directory: string, owner: string, name: string, isDirectory: boolean): ArchiveEntryConfirmation | undefined {
    if (!name || name === '.' || name === '..' || name.includes('/') || name.includes('\\')) return undefined;
    let parent: ArchiveDirectory | undefined;
    try {
      parent = ArchiveDirectory.capture(directory, { root: root, current: (): boolean => true });
      const entry = new ArchiveSource(directory + '/' + name, isDirectory);
      return new ArchiveEntryConfirmation(root, directory, owner, name, isDirectory, parent, entry);
    } catch (_) { parent?.close(); return undefined; }
  }

  /** 确认时复核当前实例与目录，再核对保存的句柄；读取失败不能放行。 */
  matches(root: string, directory: string, owner: string): boolean {
    if (root !== this.root || directory !== this.directory || owner !== this.owner) return false;
    try { this.parent.check(); this.entry.check(); return true; } catch (_) { return false; }
  }

  /** Native 在同一父目录隔离并重新核对原 fd。调用结束前保持两个句柄以及原目录链有效。 */
  commit(root: string, directory: string, owner: string, newName: string = ''): void {
    if (!this.matches(root, directory, owner)) throw new Error('原项目已变化');
    const message = entryNative.archiveMutateConfirmedEntry(this.parent.descriptor(), this.entry.handle.fd, this.name, newName);
    if (message) throw new Error(message);
  }

  close(): void { this.entry.close(); this.parent.close(); }
}
