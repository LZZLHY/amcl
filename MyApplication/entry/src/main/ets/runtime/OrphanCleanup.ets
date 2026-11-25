import { fileIo as fs } from '@kit.CoreFileKit';
import { claimVersionInstall, newVersionInstallOwner, safeBaseName } from 'feature_core';
import { LocalVersionInventory } from 'feature_core';

type Data = Record<string,Object>;
export interface OrphanCleanupAccess {
  root: () => string;
  current: () => boolean;
  inventory: () => Promise<LocalVersionInventory>;
  reserved: (root:string, names:string[]) => boolean;
  confirm: (message:string)=>Promise<boolean>;
}
interface Item {name:string; content:string[]; stamp:string; filesStamp:string;}
export interface OrphanCleanupPlan {
  root:string; rootKey:string; dirKey:string; names:string[]; installed:string[]; orphans:string[]; items:Item[];
}

/** 只接受实际目录及普通的同名启动文件。世界、配置、链接及来源不明的其他文件保留在原位。 */
function inspect(directory:string, name:string, observedName:string=name): Item {
  const path=directory+'/'+observedName;
  const stat=fs.lstatSync(path);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('targetChanged');
  const content=fs.listFileSync(path).sort();
  const identity:string[]=[];
  for (const member of content) {
    if (member!==name+'.jar' && member!==name+'.json') throw new Error('userContentPresent');
    const st=fs.lstatSync(path+'/'+member);
    if (!st.isFile() || st.isSymbolicLink()) throw new Error('userContentPresent');
    identity.push(member,String(st.ino),String(st.ctime),String(st.mtime),String(st.size));
  }
  const filesStamp=JSON.stringify(identity);
  return {name:name,content:content,filesStamp:filesStamp,stamp:JSON.stringify([String(stat.ino),String(stat.ctime),String(stat.mtime),filesStamp])};
}
function directoryStamp(path:string):string {
  const stat=fs.lstatSync(path);
  return stat.isDirectory() && !stat.isSymbolicLink()?String(stat.ino):'';
}
function equal(a:string[], b:string[]):boolean {
  return JSON.stringify(a.slice().sort())===JSON.stringify(b.slice().sort());
}
function response(state:string,reason:string,removed:string[],remaining:string[]):Data {
  return {'state':state,'reason':reason,'removed':removed,'remaining':remaining};
}

/** 在原根捕获完整候选和目录身份。宿主收到的确认只暴露候选名与同名文件。 */
export async function prepareOrphanCleanup(access:OrphanCleanupAccess, selected:string[], all:boolean):Promise<OrphanCleanupPlan> {
  const root=access.root(), versions=root+'/versions', names=selected.slice().sort();
  if (!root || !access.current() || !names.length || new Set(names).size!==names.length ||
    names.some(v=>!v || v!==safeBaseName(v) || v.startsWith('.') || v==='download-temp')) throw new Error('invalidTargets');
  const rootKey=directoryStamp(root), dirKey=directoryStamp(versions);
  if (!rootKey || !dirKey) throw new Error('rootChanged');
  const before=await access.inventory();
  if (!access.current() || access.root()!==root || before.error || (all && !equal(names,before.orphans)) ||
    names.some(v=>!before.orphans.includes(v)) || access.reserved(root,names)) throw new Error('targetsChangedOrInUse');
  return {root:root,rootKey:rootKey,dirKey:dirKey,names:names,installed:before.installed.slice(),
    orphans:before.orphans.slice(),items:names.map(v=>inspect(versions,v))};
}

/** 收齐写租约并复验原计划后才删除。界面与开发 QA 共享同一删除策略。 */
export async function applyOrphanCleanup(access:OrphanCleanupAccess, plan:OrphanCleanupPlan):Promise<Data> {
  const root=plan.root, versions=root+'/versions', names=plan.names, items=plan.items, removed:string[]=[];
  const releases:Array<()=>void>=[];
  let reason='targetChanged';
  try {
    reason='instanceInUse';
    const owner=newVersionInstallOwner();
    for (const name of names) releases.push(claimVersionInstall(root,name,owner));
    reason='targetChanged';
    const after=await access.inventory();
    if (!access.current() || access.root()!==root || directoryStamp(root)!==plan.rootKey || directoryStamp(versions)!==plan.dirKey ||
      after.error || !equal(plan.orphans,after.orphans) || !equal(plan.installed,after.installed) || access.reserved(root,names) ||
      items.some(item=>inspect(versions,item.name).stamp!==item.stamp)) return response('failed','targetsChangedOrInUse',[],names);

    // 锁内同步执行。先把本次确认的目录改至不可被正常安装器认领的唯一隐藏名，避免清理时递归进入新实例。
    for (const item of items) {
      if (access.root()!==root || !access.current() || inspect(versions,item.name).stamp!==item.stamp) throw new Error('targetChanged');
      const source=versions+'/'+item.name, temporary='.cleanup-'+owner+'-'+removed.length, moved=versions+'/'+temporary;
      if (fs.accessSync(moved)) throw new Error('stagingConflict');
      const inode=directoryStamp(source);
      fs.renameSync(source,moved);
      try {
        if (directoryStamp(moved)!==inode || inspect(versions,item.name,temporary).filesStamp!==item.filesStamp) throw new Error('targetChanged');
        for (const file of item.content) fs.unlinkSync(moved+'/'+file);
        if (fs.listFileSync(moved).length) throw new Error('targetChanged');
        fs.rmdirSync(moved);
        removed.push(item.name);
      } catch (_) {
        // 异常时保留剩余现场，不覆盖期间可能出现的新目录。
        const rest=names.filter(n=>!removed.includes(n));
        if (!fs.accessSync(source)) { try { fs.renameSync(moved,source); } catch (_) {} }
        const failed=response('partial','cleanupIncomplete',removed,rest);
        failed['affected']=item.name;
        if (fs.accessSync(moved)) failed['retainedDirectory']=temporary;
        return failed;
      }
    }
    return response('ready','',removed,[]);
  } catch (e) {
    if ((e as Error).message==='userContentPresent') reason='userContentPresent';
    return response(removed.length?'partial':'failed',reason,removed,names.filter(n=>!removed.includes(n)));
  } finally {
    for (const release of releases.reverse()) release();
  }
}


/** 玩家确认可以等待任意时间，落盘仍以弹窗打开时的计划为准。 */
export async function clearOrphanInstances(access:OrphanCleanupAccess, selected:string[], all:boolean=true):Promise<Data> {
  try {
    const plan=await prepareOrphanCleanup(access,selected,all);
    const summary=plan.items.map(item=>item.name+'（'+(item.content.length?item.content.join('、'):'空目录')+'）');
    if (!await access.confirm('清理以下不完整的实例目录？\n'+summary.join('\n'))) return response('cancelled','',[],plan.names);
    return await applyOrphanCleanup(access,plan);
  } catch (error) {
    const reason=(error as Error).message;
    const known=['invalidTargets','rootChanged','targetsChangedOrInUse','userContentPresent'];
    return response('failed',known.includes(reason)?reason:'targetChanged',[],selected.slice().sort());
  }
}
