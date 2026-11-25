/**
 * GameArchiveIO.ets — 游戏资源「导入 / 导出」工具（系统 picker + zlib + fileIo）
 *
 * 统一封装版本详情页里各资源板块的本地导入 / 导出能力：
 *   - importResourceFiles(): 模组 / 资源包 / 光影 / 数据包 —— 多选并逐项导入
 *   - importSaveZips():      存档 —— 多选 .zip，解压并整理成 saves/<世界名>/ 文件夹
 *   - exportSaveZip():       存档 —— 把 saves/<世界名>/ 打包成 .zip 让用户另存
 *
 * 设计要点：
 *   - 所有路径都基于调用方传入的目录（来自 mcDir，已是「沙箱 / 沙箱外」位置感知），
 *     因此沙箱外存档走同一套逻辑，无需特判。
 *   - picker 返回的是 file://docs/... uri，zlib.decompressFile 需要真实沙箱路径，
 *     故先把选中的 zip 用 fd 拷到 tempDir，再解压。
 *   - 不用 Record<string,Object> 字面量（ArkTS 严格模式禁），统一用显式 interface。
 *
 * 创建日期：见 CHANGELOG。
 */

import { picker } from '@kit.CoreFileKit';
import { ArchiveDirectory, ArchiveSelectionScope, ArchiveSource, missingEntry } from './ArchiveSelectionScope';
import { fileIo as fs } from '@kit.CoreFileKit';
import { fileUri } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common, Want } from '@kit.AbilityKit';
import { removeDirRecursive } from 'commons';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_UI } from 'commons';
import { LedgerState } from 'commons';
import { getTaskActivityOwner, BusinessActivity, BusinessActivityResult } from 'feature_core';

const TAG = 'GameArchiveIO';

/** launched 仅表示系统接受启动请求，不代表已验证文件管理器最终定位的目录。 */
export interface OpenFolderResult {
  launched: boolean;
  message: string;
}

export interface ImportFailure {
  name: string;
  message: string;
}

export interface BatchImportResult {
  cancelled: boolean;
  targetChanged?: boolean;
  names: string[];
  failures: ImportFailure[];
  message: string;
}

function batchResult(names: string[], failures: ImportFailure[], cancelled: boolean = false): BatchImportResult {
  let message = names.length > 0 ? `已导入 ${names.length} 个文件` : '没有文件导入成功';
  if (failures.length > 0) {
    message += `，${failures.length} 个失败：${failures[0].name} ${failures[0].message}`;
  }
  return { cancelled, names, failures, message: cancelled ? '' : message };
}

/** 导入结果。cancelled=true 表示用户在 picker 里取消，不算失败。 */
export interface ImportResult {
  ok: boolean;
  cancelled: boolean;
  /** 成功时为落地的文件名 / 世界名；失败时为空 */
  name: string;
  /** 失败原因（toast 用）；成功时为空 */
  message: string;
}

function okResult(name: string): ImportResult {
  return { ok: true, cancelled: false, name, message: '' };
}
function failResult(message: string): ImportResult {
  return { ok: false, cancelled: false, name: '', message };
}
function cancelledResult(): ImportResult {
  return { ok: false, cancelled: true, name: '', message: '' };
}

/**
 * 单个导入/导出的领域事务包装。返回值仍表达成功/取消/失败；活动记录覆盖真实复制、
 * 压缩和清理finally，页面关闭不丢收尾。IO故障由统一owner保留补写义务。
 */
async function trackArchiveSingle(ctx: common.UIAbilityContext, title: string,
  action: (activityId: number) => Promise<ImportResult>): Promise<ImportResult> {
  try {
    const owner = getTaskActivityOwner(); owner.configure(ctx.filesDir);
    return await owner.run<ImportResult>({ category: 'resource_manage', title: title },
      (activity: BusinessActivity): Promise<ImportResult> => action(activity.id), (result: ImportResult): BusinessActivityResult => ({
        state: result.cancelled ? LedgerState.ABORTED : result.ok ? LedgerState.SUCCESS : LedgerState.FAILED,
        summary: result.message || (result.cancelled ? '用户取消' : '已完成 ' + result.name), fileCount: result.ok ? 1 : 0,
      }));
  } catch (error) { return failResult((error as Error).message); }
}

/** 多选操作按整批结果记录；部分成功仍保留失败数量，不把Promise返回误判为全部成功。 */
async function trackArchiveBatch(ctx: common.UIAbilityContext, title: string,
  action: (activityId: number) => Promise<BatchImportResult>): Promise<BatchImportResult> {
  try {
    const owner = getTaskActivityOwner(); owner.configure(ctx.filesDir);
    return await owner.run<BatchImportResult>({ category: 'resource_manage', title: title },
      (activity: BusinessActivity): Promise<BatchImportResult> => action(activity.id), (result: BatchImportResult): BusinessActivityResult => ({
        state: result.cancelled ? LedgerState.ABORTED : result.failures.length > 0 ? LedgerState.FAILED : LedgerState.SUCCESS,
        summary: result.message || '用户取消', fileCount: result.names.length,
      }));
  } catch (error) { return batchResult([], [{ name: '', message: (error as Error).message }]); }
}

/** 从 picker uri 取末尾文件名（去掉 query，按 / 切，解码一次百分号转义）。 */
function basenameFromUri(uri: string): string {
  let u = uri;
  let q = u.indexOf('?');
  if (q >= 0) u = u.substring(0, q);
  let slash = u.lastIndexOf('/');
  let name = slash >= 0 ? u.substring(slash + 1) : u;
  try { name = decodeURIComponent(name); } catch (e) { /* 保留原值 */ }
  return name;
}

/** 去掉文件名扩展名（最后一个 .）。无扩展名则原样返回。 */
function stripExt(filename: string): string {
  let dot = filename.lastIndexOf('.');
  return dot > 0 ? filename.substring(0, dot) : filename;
}

/** 递归 mkdir；已存在不报错。 */
function ensureDir(dir: string): void {
  try { fs.mkdirSync(dir, true); } catch (e) {
    try { let st = fs.statSync(dir); if (st.isDirectory()) return; } catch (ee) { /* */ }
    throw new Error('mkdir failed: ' + (e as BusinessError).message);
  }
}

/** 路径是否存在。 */
function pathExists(p: string): boolean {
  try { fs.statSync(p); return true; } catch (e) { return false; }
}

/** 复制单个 picker uri 指向的文件到 destPath（用 fd，兼容 file://docs/ uri）。 */
function copyUriToPath(uri: string, destPath: string): void {
  let f: fs.File | null = null;
  try {
    f = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    fs.copyFileSync(f.fd, destPath);
  } catch (e) {
    throw new Error('copy from uri failed: ' + (e as BusinessError).message);
  } finally {
    if (f !== null) {
      try { fs.closeSync(f); } catch (ee) { /* ignore close error */ }
    }
  }
}

/** 只回收此次创建且身份未变的暂存成员，用户后来放入的文件、同名替代目录和链接均原地保留。 */
interface StageMember {path:string; ino:string; directory:boolean;}
class OwnedArchiveStage {
  readonly dir:ArchiveDirectory;
  private members:StageMember[]=[];
  private directories:Map<string,string>=new Map<string,string>();
  constructor(root:string,prefix:string) {
    const created=fs.mkdtempSync(root+'/'+prefix);
    this.dir=ArchiveDirectory.capture(created,{root:root,current:():boolean=>true});
  }
  remember(path:string,directory:boolean):void {
    if(!path.startsWith(this.dir.path+'/')) throw new Error('暂存位置无效');
    const inode=String(fs.lstatSync(path).ino);
    this.members.push({path:path,ino:inode,directory:directory});
    if(directory) this.directories.set(path,inode);
  }
  published():void { this.members=[];this.directories.clear(); }
  close():void {
    try {
      this.dir.check();
      for(const item of this.members.reverse()) {
        try {
          this.dir.check();
          // 逐层拒绝被换成符号链接／其他目录的中间节点，再比对文件本身。
          let parent=item.path.slice(0,item.path.lastIndexOf('/'));
          let intact=true;
          while(parent!==this.dir.path) {
            const inode=this.directories.get(parent);
            const st=fs.lstatSync(parent);
            if(inode===undefined || String(st.ino)!==inode || st.isSymbolicLink() || !st.isDirectory()) {intact=false;break;}
            parent=parent.slice(0,parent.lastIndexOf('/'));
          }
          if(!intact) continue;
          const st=fs.lstatSync(item.path);
          if(st.isSymbolicLink() || String(st.ino)!==item.ino) continue;
          if(item.directory) {if(st.isDirectory() && !fs.listFileSync(item.path).length) fs.rmdirSync(item.path);}
          else if(st.isFile()) fs.unlinkSync(item.path);
        } catch(_) { /* 原成员已移动、未完整发布或权限已收回时保留。 */ }
      }
      this.dir.check();
      if(!fs.listFileSync(this.dir.path).length) fs.rmdirSync(this.dir.path);
    } catch(_) { /* 同名新目录不是本次临时空间。 */ }
    finally {this.dir.close();}
  }
}
/** 从本次私有解压目录复制到本次独占暂存；不跟随链接，不重开异步复制的目标路径。 */
async function copyWorldContents(src:string,dest:string,current:()=>void,stage?:OwnedArchiveStage):Promise<void> {
  const scope=ArchiveDirectory.capture(dest);
  let inputDir:ArchiveDirectory|undefined;
  try {
    inputDir=ArchiveDirectory.capture(src);
    const pinned=inputDir;
    const names=fs.listFileSync(src).sort();
    for (const name of names) {
      current();scope.check();pinned.check();
      const from=src+'/'+name,to=dest+'/'+name,st=fs.lstatSync(from);
      if (st.isSymbolicLink() || !missingEntry(to)) throw new Error('存档中包含不可导入的项目');
      if (st.isDirectory()) {
        fs.mkdirSync(to);stage?.remember(to,true);
        await copyWorldContents(from,to,():void=>{current();scope.check();pinned.check();},stage);
      } else if(st.isFile()) {
        const input=new ArchiveSource(from,false);
        try {
          const output=fs.openSync(to,fs.OpenMode.WRITE_ONLY|fs.OpenMode.CREATE|fs.OpenMode.NOFOLLOW);
          try {stage?.remember(to,false);await fs.copyFile(input.handle.fd,output.fd);input.check();} finally {fs.closeSync(output);}
        } finally {input.close();}
      } else throw new Error('存档中包含非普通文件');
    }
    current();scope.check();pinned.check();
    if(JSON.stringify(names)!==JSON.stringify(fs.listFileSync(src).sort())) throw new Error('源目录内容已变化');
  } finally {inputDir?.close();scope.close();}
}

/** Promise 化 zlib.decompressFile（沿用 JdkInstaller 的 3 参回调形式 + 超时保护）。 */
function decompress(zipPath: string, destDir: string, timeoutMs: number): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    let timer = setTimeout(() => { reject(new Error('解压超时')); }, timeoutMs);
    try {
      zlib.decompressFile(zipPath, destDir, (err: BusinessError) => {
        clearTimeout(timer);
        if (err && err.code) reject(new Error(err.message)); else resolve();
      });
    } catch (e) {
      clearTimeout(timer);
      reject(e as Error);
    }
  });
}

/** Promise 化 zlib.compressFile（压缩目录或文件为 zip）。 */
function compress(srcPath: string, zipPath: string, timeoutMs: number): Promise<void> {
  let opts: zlib.Options = { level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION };
  return new Promise<void>((resolve, reject) => {
    let timer = setTimeout(() => { reject(new Error('压缩超时')); }, timeoutMs);
    try {
      zlib.compressFile(srcPath, zipPath, opts, (err: BusinessError) => {
        clearTimeout(timer);
        if (err && err.code) reject(new Error(err.message)); else resolve();
      });
    } catch (e) {
      clearTimeout(timer);
      reject(e as Error);
    }
  });
}

export class GameArchiveIO {
  /** 解压 / 压缩超时（存档可能较大，给 300s，与 JDK 解压一致）。 */
  private static readonly ZIP_TIMEOUT_MS = 300_000;

  /** 本地文件/存档操作统一由领域owner记账，内部单文件和递归步骤不重复开账。 */
  static async importResourceFiles(ctx: common.UIAbilityContext, targetDir: string, expectedExts: string[],
    maxSelectNumber: number = 500, scope?:ArchiveSelectionScope): Promise<BatchImportResult> {
    let guard:ArchiveDirectory|undefined;
    try {
      guard=ArchiveDirectory.capture(targetDir,scope);
      if (scope?.consent && !await scope.consent()) return batchResult([],[],true);
      guard.check();
      const bound=guard;
      return await trackArchiveBatch(ctx,'导入本地资源文件',async(id:number):Promise<BatchImportResult>=>{
        const outcome=await GameArchiveIO.importResourceFilesUntracked(ctx,bound,expectedExts,maxSelectNumber,id);
        if(!outcome.cancelled) {
          try {bound.check();} catch (_) {outcome.targetChanged=true;if(!outcome.failures.length) outcome.failures.push({name:'',message:'原目录已经变化'});outcome.message+='；原目录已经变化。';}
        }
        return outcome;
      });
    } catch(e) { return batchResult([],[{name:'',message:(e as Error).message}]); }
    finally { guard?.close(); }
  }

  static async importSaveZips(ctx:common.UIAbilityContext,savesDir:string,scope?:ArchiveSelectionScope):Promise<BatchImportResult> {
    let guard:ArchiveDirectory|undefined;
    try {
      guard=ArchiveDirectory.capture(savesDir,scope);
      if (scope?.consent && !await scope.consent()) return batchResult([],[],true);
      guard.check();
      const bound=guard;
      return await trackArchiveBatch(ctx,'导入存档',async(id:number):Promise<BatchImportResult>=>{
        const outcome=await GameArchiveIO.importSaveZipsUntracked(ctx,bound,id);
        if(!outcome.cancelled) {
          try {bound.check();} catch (_) {outcome.targetChanged=true;if(!outcome.failures.length) outcome.failures.push({name:'',message:'原存档目录已经变化'});outcome.message+='；原目录已经变化。';}
        }
        return outcome;
      });
    } catch(e) { return batchResult([],[{name:'',message:(e as Error).message}]); }
    finally { guard?.close(); }
  }

  static exportSaveZip(ctx:common.UIAbilityContext,savesDir:string,worldName:string,scope?:ArchiveSelectionScope):Promise<ImportResult> {
    return GameArchiveIO.exportBound(ctx,savesDir+'/'+worldName,worldName,true,'导出存档',scope);
  }
  static exportFile(ctx:common.UIAbilityContext,srcPath:string,fileName:string,scope?:ArchiveSelectionScope):Promise<ImportResult> {
    return GameArchiveIO.exportBound(ctx,srcPath,fileName,false,'导出文件',scope);
  }
  static exportDirZip(ctx:common.UIAbilityContext,srcDir:string,dirName:string,scope?:ArchiveSelectionScope):Promise<ImportResult> {
    return GameArchiveIO.exportBound(ctx,srcDir,dirName,true,'导出目录',scope);
  }

  /** 在选择窗口和账本等待之前取得原源文件/目录；普通文件直接从原 fd 读取。 */
  private static async exportBound(ctx:common.UIAbilityContext,path:string,name:string,directory:boolean,title:string,scope?:ArchiveSelectionScope):Promise<ImportResult> {
    let guard:ArchiveDirectory|undefined;
    let source:ArchiveSource|undefined;
    try {
      const normalized=path.replace(/\\/g,'/');
      guard=ArchiveDirectory.capture(normalized.slice(0,normalized.lastIndexOf('/')),scope);
      source=new ArchiveSource(path,directory);
      const parent=guard,original=source;
      return await trackArchiveSingle(ctx,title+' '+name,async(id:number):Promise<ImportResult>=>{
        let scratch='';
        let staged:ArchiveSource|undefined;
        let output:fs.File|undefined;
        try {
          parent.check();original.check();
          if(directory) {
            scratch=fs.mkdtempSync(ctx.tempDir+'/amcl-archive-export-');
            const snapshot=scratch+'/snapshot';fs.mkdirSync(snapshot);
            await copyWorldContents(path,snapshot,():void=>{parent.check();original.check();});
            await compress(snapshot,scratch+'/archive.zip',GameArchiveIO.ZIP_TIMEOUT_MS);
            parent.check();original.check();staged=new ArchiveSource(scratch+'/archive.zip',false);
          }
          const opt=new picker.DocumentSaveOptions();opt.newFileNames=[name+(directory?'.zip':'')];
          const selected=await new picker.DocumentViewPicker(ctx).save(opt);
          if(!selected || !selected.length) return cancelledResult();
          parent.check();original.check();staged?.check();
          // 用户实际批准的 URI 由系统授予。先确认源，再打开输出；误选同一个文件不能将源截断。
          const read=(staged ?? original).handle.fd;
          output=fs.openSync(selected[0],fs.OpenMode.READ_WRITE|fs.OpenMode.CREATE);
          if (fs.statSync(output.fd).ino===fs.statSync(read).ino) return failResult('请选择与原文件不同的目标');
          parent.check();original.check();staged?.check();
          await fs.copyFile(read,output.fd);
          AppLogger.info(TAG,'导出已写入所选目标',LOG_DOMAIN_UI,id);
          return okResult(name);
        } finally {
          if (output) fs.closeSync(output);
          staged?.close();
          if (scratch) removeDirRecursive(scratch);
        }
      });
    } catch(e) {return failResult((e as Error).message);}
    finally { source?.close();guard?.close(); }
  }

  /** JDK/整合包安装仍为单任务流程，不把多个安装包混入一次安装。 */
  static async importResourceFile(ctx: common.UIAbilityContext, targetDir: string,
    expectedExts: string[]): Promise<ImportResult> {
    const result = await GameArchiveIO.importResourceFiles(ctx, targetDir, expectedExts, 1);
    if (result.cancelled) return cancelledResult();
    return result.names.length > 0 ? okResult(result.names[0]) : failResult(result.message);
  }

  /**
   * 多选资源文件，逐项校验、导入；一次失败不阻断其他选中项。
   *
   * @param expectedExts 允许的小写扩展名（含点），如 ['.jar'] 或 ['.zip']
   */
  private static async importResourceFilesUntracked(
    ctx: common.UIAbilityContext,
    target: ArchiveDirectory,
    expectedExts: string[],
    maxSelectNumber: number = 500,
    activityId: number = 0,
  ): Promise<BatchImportResult> {
    target.check();
    let uris: string[] = [];
    try {
      let opt = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = maxSelectNumber;
      if (expectedExts.length > 0) opt.fileSuffixFilters = [expectedExts.join(',')];
      let dp = new picker.DocumentViewPicker(ctx);
      uris = await dp.select(opt);
    } catch (e) {
      return batchResult([], [{ name: '', message: '选择文件失败: ' + (e as BusinessError).message }]);
    }
    if (!uris || uris.length === 0) return batchResult([], [], true);
    const names: string[] = [];
    const failures: ImportFailure[] = [];
    for (let index = 0; index < uris.length; index++) {
      const uri = uris[index];
      const filename = basenameFromUri(uri);
      let scratch:OwnedArchiveStage|undefined;
      let tmpFile:fs.File|undefined;
      let source: fs.File | null = null;
      try {
        if (filename.length === 0 || filename === '.' || filename === '..' ||
          filename.includes('/') || filename.includes('\\') || filename.includes('\0')) {
          throw new Error('文件名无效');
        }
        if (expectedExts.length > 0 &&
          !expectedExts.some((ext: string) => filename.toLowerCase().endsWith(ext))) {
          throw new Error('文件类型不符，需要 ' + expectedExts.join(' / '));
        }
        target.ensure();
        const dest=target.path+'/'+filename;
        if (!missingEntry(dest)) throw new Error('同名文件已存在，原文件已保留');
        scratch=new OwnedArchiveStage(target.path,'.amcl-import-');
        const temp=scratch.dir.path+'/part';
        tmpFile=fs.openSync(temp,fs.OpenMode.READ_WRITE|fs.OpenMode.CREATE|fs.OpenMode.NOFOLLOW);
        scratch.remember(temp,false);
        source=await fs.open(uri,fs.OpenMode.READ_ONLY);
        target.check();scratch.dir.check();
        // 复制只写已经打开的暂存 fd；业务目录或临时路径变化不会把后续字节写进替代目录。
        await fs.copyFile(source.fd,tmpFile.fd);
        target.check();scratch.dir.check();
        if(fs.lstatSync(temp).ino!==fs.statSync(tmpFile.fd).ino) throw new Error('暂存文件已变化');
        fs.moveFileSync(temp,dest,1);
        target.checkIdentity();
        if(fs.lstatSync(dest).ino!==fs.statSync(tmpFile.fd).ino) throw new Error('导入结果已变化');
        scratch.published();
        names.push(filename);
        AppLogger.info(TAG, `importResourceFiles imported=${names.length}/${uris.length} name=${filename}`, LOG_DOMAIN_UI, activityId);
      } catch (e) {
        const message = (e as BusinessError).message;
        failures.push({ name: filename, message });
        AppLogger.warn(TAG, `importResourceFiles failed name=${filename}`, e, LOG_DOMAIN_UI, activityId);
      } finally {
        if (source !== null) { try { fs.closeSync(source); } catch (e) { /* */ } }
        scratch?.close();
        if(tmpFile) fs.closeSync(tmpFile);
      }
    }
    AppLogger.info(TAG, `importResourceFiles completed selected=${uris.length} imported=${names.length} failed=${failures.length}`, LOG_DOMAIN_UI, activityId);
    return batchResult(names, failures);
  }

  /**
   * 导入存档：选 .zip → 解压 → 整理成 saves/<世界名>/（确保 level.dat 在世界根）。
   *
   * 兼容两种 zip 结构：
   *   - 顶层即世界内容（level.dat 在根）→ 世界名取自 zip 文件名
   *   - 顶层是单个世界文件夹（<世界>/level.dat）→ 世界名取自该文件夹
   * 名称冲突时自动追加 " (1)" / " (2)"。
   */
  private static async importSaveZipsUntracked(
    ctx: common.UIAbilityContext,
    target: ArchiveDirectory,
    activityId: number,
  ): Promise<BatchImportResult> {
    target.check();
    let uris: string[] = [];
    try {
      let opt = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 500;
      opt.fileSuffixFilters = ['.zip'];
      let dp = new picker.DocumentViewPicker(ctx);
      uris = await dp.select(opt);
    } catch (e) {
      return batchResult([], [{ name: '', message: '选择文件失败: ' + (e as BusinessError).message }]);
    }
    if (!uris || uris.length === 0) return batchResult([], [], true);
    const names: string[] = [];
    const failures: ImportFailure[] = [];
    for (const uri of uris) {
      const result = await GameArchiveIO.importSaveUri(ctx,target,uri,activityId);
      if (result.ok) names.push(result.name);
      else failures.push({ name: basenameFromUri(uri), message: result.message });
    }
    return batchResult(names, failures);
  }

  private static async importSaveUri(ctx:common.UIAbilityContext,target:ArchiveDirectory,uri:string,activityId:number):Promise<ImportResult> {
    const filename=basenameFromUri(uri);
    if (!filename.toLowerCase().endsWith('.zip')) return failResult('存档需为 .zip 文件');
    let scratch='';
    let staging:OwnedArchiveStage|undefined;
    try {
      target.check();
      scratch=fs.mkdtempSync(ctx.tempDir+'/amcl-world-import-');
      const zip=scratch+'/input.zip',extracted=scratch+'/contents';
      copyUriToPath(uri,zip);fs.mkdirSync(extracted);
      await decompress(zip,extracted,GameArchiveIO.ZIP_TIMEOUT_MS);
      target.ensure();
      const world=GameArchiveIO.locateWorldRoot(extracted);
      const level=fs.lstatSync(world+'/level.dat');
      if(!level.isFile() || level.isSymbolicLink()) return failResult('zip 内未找到有效的 level.dat');
      const baseName=GameArchiveIO.sanitizeName(world===extracted?stripExt(filename):world.slice(world.lastIndexOf('/')+1),'world');
      const base=baseName==='.' || baseName==='..'?'world':baseName;
      const name=GameArchiveIO.uniqueName(target.path,base);
      staging=new OwnedArchiveStage(target.path,'.amcl-world-');
      const bound=staging,worldStage=staging.dir.path+'/'+name;
      fs.mkdirSync(worldStage);staging.remember(worldStage,true);
      const check=():void=>{target.check();bound.dir.check();};
      await copyWorldContents(world,worldStage,check,staging);
      check();
      if(!missingEntry(target.path+'/'+name)) return failResult('新存档名称已被占用');
      const original=fs.lstatSync(worldStage).ino;
      fs.moveDirSync(worldStage,target.path,0);staging.published();
      target.checkIdentity();if(fs.lstatSync(target.path+'/'+name).ino!==original || !fs.lstatSync(target.path+'/'+name+'/level.dat').isFile()) return failResult('目标存档已变化');
      AppLogger.info(TAG,'存档已导入：'+name,LOG_DOMAIN_UI,activityId);
      return okResult(name);
    } catch(e) {return failResult('导入失败：'+(e as Error).message);}
    finally {
      staging?.close();
      if(scratch) removeDirRecursive(scratch);
    }
  }

  /** 系统选取的文件按原目录逐个创建；同名项保留并计入失败。 */
  static async importAnyFiles(ctx:common.UIAbilityContext,targetDir:string,scope?:ArchiveSelectionScope):Promise<BatchImportResult> {
    return GameArchiveIO.importResourceFiles(ctx,targetDir,[],500,scope);
  }

  /**
   * 拉起系统文件管理器浏览公共目录。DocumentViewPicker 仅用于导入/导出。
   * 当前未配置沙箱目录捐献，只接受公共文档 URI。
   * 目录不存在时先创建（便于用户提前进去放文件）。
   */
  static async openFolder(
    ctx: common.UIAbilityContext,
    dirPath: string,
  ): Promise<OpenFolderResult> {
    if (dirPath.length === 0) return { launched: false, message: '目录无效' };
    let uri = '';
    let stage = 'uri';
    try {
      uri = fileUri.getUriFromPath(dirPath);
      AppLogger.info(TAG, `openFolder request path=${dirPath} uri=${uri}`, LOG_DOMAIN_UI);
      if (!uri.startsWith('file://docs/')) {
        AppLogger.warn(TAG, `openFolder unsupported uri=${uri}`, undefined, LOG_DOMAIN_UI);
        return { launched: false, message: '此目录请使用应用内的“版本文件夹”查看' };
      }
      stage = 'directory';
      if (!pathExists(dirPath)) ensureDir(dirPath);
      if (!fs.statSync(dirPath).isDirectory()) {
        return { launched: false, message: '目标不是文件夹' };
      }
      const want: Want = {
        bundleName: 'com.huawei.hmos.filemanager',
        abilityName: 'MainAbility',
        parameters: { 'fileUri': uri },
      };
      stage = 'startAbility';
      await ctx.startAbility(want);
      AppLogger.info(TAG, `openFolder launchAccepted uri=${uri}`, LOG_DOMAIN_UI);
      return { launched: true, message: '' };
    } catch (e) {
      const err = e as BusinessError;
      AppLogger.warn(TAG, `openFolder failed stage=${stage} path=${dirPath} uri=${uri} code=${err.code}`,
        err, LOG_DOMAIN_UI);
      return { launched: false, message: stage === 'startAbility'
        ? '无法打开系统文件管理器，请使用应用内的“版本文件夹”'
        : '无法访问目录，请使用应用内的“版本文件夹”检查' };
    }
  }

  /**
   * 在解压目录里定位「世界根」：
   *   - root 直接含 level.dat → 返回 root
   *   - root 下恰有一个子目录且该子目录含 level.dat → 返回该子目录
   *   - 否则遍历一层子目录找第一个含 level.dat 的 → 返回它
   *   - 都没有 → 返回 root（由调用方做 level.dat 兜底校验）
   */
  private static locateWorldRoot(root: string): string {
    if (pathExists(root + '/level.dat')) return root;
    let entries: string[] = [];
    try { entries = fs.listFileSync(root); } catch (e) { return root; }
    let subDirs: string[] = [];
    for (let name of entries) {
      let p = root + '/' + name;
      try { if (fs.statSync(p).isDirectory()) subDirs.push(p); } catch (e) { /* */ }
    }
    for (let d of subDirs) {
      if (pathExists(d + '/level.dat')) return d;
    }
    return root;
  }

  /** 清理世界名里的非法路径字符；空则回退 fallback。 */
  private static sanitizeName(name: string, fallback: string): string {
    let n = name.replace(/[\/\\:*?"<>|]/g, '_').trim();
    if (n.length === 0) n = fallback;
    if (n.length === 0) n = 'world';
    return n;
  }

  /** 在 dir 下为 base 取一个不冲突的名字：base / base (1) / base (2) ... */
  private static uniqueName(dir: string, base: string): string {
    if (!pathExists(dir + '/' + base)) return base;
    for (let i = 1; i < 1000; i++) {
      let cand = base + ' (' + i + ')';
      if (!pathExists(dir + '/' + cand)) return cand;
    }
    return base + ' (' + Date.now() + ')';
  }
}
