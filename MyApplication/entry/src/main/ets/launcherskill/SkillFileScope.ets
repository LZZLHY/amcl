import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 文件引用保存在当前面板内。调用方只提交回包中的不透明标识；目录、版本、文件换代均会使引用失效。 */
export class SkillFileScope {
  private root: string = '';
  private dir: string = '';
  private version: string = '';
  private folderRef: string = '';
  private folderStamp: string = '';
  private missingAllowed: boolean = false;
  private names: Map<string,string> = new Map<string,string>();
  private stamps: Map<string,string> = new Map<string,string>();

  private stamp(path: string): string {
    try {
      const st=fs.lstatSync(path);
      return st.isSymbolicLink() ? '' : [String(st.ino),String(st.mtime),String(st.ctime),String(st.size)].join(':');
    } catch (_) { return ''; }
  }
  private withinRoot(root: string,dir: string,allowAbsent:boolean=false): boolean {
    if (!root || (dir!==root && !dir.startsWith(root+'/'))) return false;
    let current=root;
    const parts=dir.slice(root.length).split('/').filter((p:string):boolean=>p.length>0);
    try {
      if (fs.lstatSync(root).isSymbolicLink()) return false;
      for (const part of parts) {
        if (part==='.' || part==='..') return false;
        current+='/'+part;
        if (!fs.lstatSync(current).isDirectory() || fs.lstatSync(current).isSymbolicLink()) return false;
      }
      return true;
    } catch (e) { return allowAbsent && current===dir && (e as BusinessError).code===13900002; }
  }
  private currentStamp(dir:string):string {
    const present=this.stamp(dir);
    if (present || !this.missingAllowed) return present;
    const parent=this.stamp(dir.slice(0,dir.lastIndexOf('/')));
    return parent?'missing:'+parent:'';
  }
  list(root:string,dir:string,version:string,allowAbsent:boolean=false):string {
    this.names.clear(); this.stamps.clear(); this.folderRef='';this.missingAllowed=allowAbsent;
    if (!this.withinRoot(root,dir,allowAbsent)) return '';
    this.root=root; this.dir=dir; this.version=version;
    this.folderStamp=this.currentStamp(dir);
    if (this.folderStamp) this.folderRef=util.generateRandomUUID();
    return this.folderRef;
  }
  row(name:string):string {
    if (!this.folderRef || !name || name==='.' || name==='..' || /[\/\\]/.test(name)) return '';
    const stamp=this.stamp(this.dir+'/'+name);
    if (!stamp) return '';
    const ref=util.generateRandomUUID(); this.names.set(ref,name); this.stamps.set(ref,stamp); return ref;
  }
  belongs(root:string,dir:string,version:string,ref:string):boolean {
    return !!ref && ref===this.folderRef && root===this.root && dir===this.dir && version===this.version && this.withinRoot(root,dir,this.missingAllowed) && this.currentStamp(dir)===this.folderStamp;
  }
  resolve(root:string,dir:string,version:string,folder:string,ref:string):string {
    if (!this.belongs(root,dir,version,folder)) return '';
    const name=this.names.get(ref) ?? '';
    return name && this.stamp(dir+'/'+name)===this.stamps.get(ref) ? name : '';
  }
}

/** 确认窗口保存当时的目录与行身份；提交者重新提供当前作用域和名称，避免替换同名对象。 */
export type FileEntryCheck = (root: string, directory: string, owner: string, name: string) => boolean;
export function captureFileEntry(root: string, directory: string, owner: string, name: string): FileEntryCheck | undefined {
  const scope = new SkillFileScope();
  const folder = scope.list(root, directory, owner);
  const row = scope.row(name);
  if (!folder || !row) return undefined;
  return (currentRoot: string, currentDirectory: string, currentOwner: string, currentName: string): boolean =>
    currentName === name && scope.resolve(currentRoot, currentDirectory, currentOwner, folder, row) === name;
}
