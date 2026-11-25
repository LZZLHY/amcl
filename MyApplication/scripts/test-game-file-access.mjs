// 临时夹具及其清理边界统一使用外部宿主测试区，不修改系统 TEMP，也不回退到源码目录。
import { workspaceTempRoot } from './lib/workspace-paths.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import compiler from './lib/ets-compiler.mjs';

const root = path.resolve(import.meta.dirname, '..');
const temp = fs.mkdtempSync(path.join(workspaceTempRoot(), 'amcl-file-access-'));
const logger = { info() {}, warn() {} };
const nativeFs = {
  accessSync: fs.existsSync,
  statSync: fs.statSync,
  mkdirSync: (p) => fs.mkdirSync(p, { recursive: true }),
  renameSync: fs.renameSync,
  unlinkSync: fs.unlinkSync,
  closeSync: f => fs.closeSync(f.fd),
  OpenMode: { READ_ONLY: 0 },
};
function load(relative, name, bindings) {
  const source = fs.readFileSync(path.join(root, relative), 'utf8').replace(/^import .*;\r?\n/gm, '');
  const js = stripTypeScriptTypes(source, { mode: 'transform' }).replace(/^export /gm, '');
  // 文件准入/部分失败专项隔离活动存储；活动自身的真实持久化用组合owner套件覆盖。
  return runInNewContext(js + '\n' + name, { LedgerState: { SUCCESS: 1, FAILED: 2, ABORTED: 3 },
    getTaskActivityOwner: () => ({ configure() {}, run: async (_meta, action) => action({ event() {} }) }), ...bindings });
}
function storage(dir, sdk = 26, extraFs = {}, platform = {}) {
  const api = load('feature_system/src/main/ets/GameStorage.ets', 'GameStorage', {
    fs: { ...nativeFs, ...extraFs }, AppLogger: logger,
    deviceInfo: { sdkApiVersion: sdk, deviceType: 'phone' }, ...platform,
  });
  return { api, ctx: { filesDir: dir } };
}
let count = 0;
function pass(name) { count++; console.log('PASS ' + name); }
try {
  const migration = path.join(temp, 'no-migration');
  fs.mkdirSync(path.join(migration, '.minecraft', 'versions', 'existing'), { recursive: true });
  fs.mkdirSync(path.join(migration, 'minecraft', 'versions', 'unrelated'), { recursive: true });
  let mutations = 0;
  const forbiddenMutation = () => { mutations++; throw new Error('path resolution must not mutate data'); };
  const s = storage(migration, 26, { renameSync: forbiddenMutation, mkdirSync: forbiddenMutation });
  assert.equal(s.api.sandboxMcDir(s.ctx), migration + '/.minecraft');
  assert.equal(mutations, 0);
  assert(fs.existsSync(path.join(migration, '.minecraft', 'versions', 'existing')));
  assert(fs.existsSync(path.join(migration, 'minecraft', 'versions', 'unrelated')));
  const older = storage(migration, 20, { renameSync: forbiddenMutation, mkdirSync: forbiddenMutation });
  assert.equal(older.api.sandboxMcDir(older.ctx), migration + '/.minecraft');
  pass('all API versions preserve original root and never migrate during path resolution');

  // 根选择在真实目录上验证；系统包身份、权限及 Native 读写准入是这里的测试边界。
  const filesDir=path.join(temp,'first-run'), download=path.join(temp,'Download');
  fs.mkdirSync(filesDir);fs.mkdirSync(download);
  let bundle={installTime:100,updateTime:100}, metadataFailure, tablet=false, grant=false, approve=true;
  let requests=0, picks=0, canWrite=true;
  const checkedRoots = [];
  function platformStat(p) {
    try { return fs.lstatSync(p); }
    catch(error) { if(error.code==='ENOENT')error.code=13900002;throw error; }
  }
  const publicDir=download+'/com.amcl.launcher';
  const {api:game,ctx}=storage(filesDir,26,{
    statSync:platformStat, lstatSync:platformStat, listFileSync:fs.readdirSync,
    rmdirSync:()=>assert.fail('检查外部存储不能递归清理游戏目录'),
  },{
    systemNative:()=>({verifyGameDirectoryWritable(root){checkedRoots.push(root);return canWrite;}}),
    canIUse:()=>tablet,
    bundleManager:{BundleFlag:{GET_BUNDLE_INFO_DEFAULT:0},getBundleInfoForSelfSync(){
      if(metadataFailure)throw metadataFailure;return bundle;
    }},
    Environment:{getUserDownloadDir:()=>download},fileUri:{FileUri:class{constructor(uri){this.path=uri;}}},
    picker:{DocumentSaveOptions:class{},DocumentPickerMode:{DOWNLOAD:1},DocumentViewPicker:class{
      async save(opts){assert.equal(opts.pickerMode,1);picks++;return [publicDir];}}},
    abilityAccessCtrl:{GrantStatus:{PERMISSION_GRANTED:0},createAtManager:()=>({
      checkAccessTokenSync:()=>grant?0:-1,requestPermissionsFromUser:async()=>{requests++;grant=approve;return {authResults:[grant?0:-1]};},
    })},
  });
  ctx.applicationInfo={accessTokenId:1};
  assert.equal(game.isFreshInstall(ctx),true);
  bundle.updateTime=101;assert.equal(game.isFreshInstall(ctx),false);
  bundle.updateTime=100;
  metadataFailure=Object.assign(Error('bundle lookup failed'),{code:13900002});
  assert.equal(game.isFreshInstall(ctx),false); metadataFailure=undefined;
  const oldSave=path.join(filesDir,'.minecraft','saves','legacy');
  fs.mkdirSync(oldSave,{recursive:true});assert.equal(game.isFreshInstall(ctx),false);
  const prefs={phoneExternalDir:''};
  assert.equal(await game.prepareExternal(ctx,prefs,true),'ready');
  assert.equal(picks,1);assert.equal(requests,0);
  const externalRoot=game.externalMcDir(), existing=path.join(externalRoot,'existing.txt');
  assert.deepEqual(checkedRoots,[externalRoot]);
  fs.writeFileSync(existing,'player data');
  canWrite=false;
  assert.equal(await game.prepareExternal(ctx,prefs,false),'unavailable');
  canWrite=true;
  assert.equal(await game.prepareExternal(ctx,prefs,false),'ready');
  assert.deepEqual(fs.readdirSync(externalRoot),['existing.txt']);
  assert.equal(fs.readFileSync(existing,'utf8'),'player data');
  assert.equal(picks,1);
  tablet=true;approve=false;
  assert.equal(await game.prepareExternal(ctx,prefs,true),'permissionDenied');
  assert.equal(requests,1);
  assert.equal(await game.prepareExternal(ctx,prefs,false),'permissionDenied');
  assert.equal(requests,1);
  approve=true;assert.equal(await game.prepareExternal(ctx,prefs,true),'ready');
  assert.equal(requests,2);assert.equal(picks,1);
  pass('fresh vs upgraded bundle, restored sandbox world, phone read/write probe and tablet grant or denial');

  let selection = [];
  let options;
  const dest = path.join(temp, 'mods');
  const source = path.join(temp, 'source.jar');
  fs.writeFileSync(source, 'new jar bytes');
  // 用真实文件和 fd；Windows 不能按普通文件打开目录，目录 fd 的 stat 用打开瞬间的真实目录 inode 替代。
  let nextDirFd=-10;const dirs=new Map(),opened=new Map();
  const modes={READ_ONLY:0,READ_WRITE:2,WRITE_ONLY:1,CREATE:64,NOFOLLOW:131072,DIR:65536};
  const owned=p=>{const q=path.resolve(p);assert.ok(q===temp||q.startsWith(temp+path.sep),q);return q;};
  let selectHook=()=>{},copyHook=()=>{},moveHook=()=>{},saveHook=()=>{},afterMove=()=>{},savePath='';
  const errNotFound=e=>{if(e.code==='ENOENT')e.code=13900002;throw e;};
  let lookup=p=>p;
  const stat=p=>{try{const s=fs.lstatSync(lookup(p));return Object.assign(s,{ino:fs.lstatSync(lookup(p),{bigint:true}).ino,mtime:s.mtimeMs,ctime:s.ctimeMs});}catch(e){errNotFound(e);}};
  const fake={
    ...nativeFs,OpenMode:modes,lstatSync:stat,listFileSync:fs.readdirSync,
    statSync:p=>typeof p==='number'?(p<0?dirs.get(p):fs.fstatSync(p,{bigint:true})):fs.statSync(p),
    openSync(p,flags) {
      if(flags&modes.DIR){const fd=nextDirFd--;dirs.set(fd,stat(p));return {fd};}
      const input=p.startsWith('file://docs/')?source:p;
      if(input.endsWith('broken.bin') && !(flags&modes.CREATE))throw Error('copy interrupted');
      const mode=flags&modes.CREATE?(fs.existsSync(input)?'r+':'wx+'):flags&modes.READ_WRITE?'r+':'r';
      const fd=fs.openSync(input,mode);opened.set(fd,input);return {fd};
    },
    async open(p,flags){if(p.includes('unreadable'))throw Error('read denied');return this.openSync(p,flags);},
    closeSync(f){if(f.fd<0){assert.ok(dirs.delete(f.fd));}else{fs.closeSync(f.fd);opened.delete(f.fd);}},
    rmdirSync:p=>fs.rmdirSync(owned(p)),
    mkdirSync:(p,recurse=false)=>fs.mkdirSync(owned(p),{recursive:recurse}),mkdtempSync:p=>fs.mkdtempSync(owned(p)),
    async copyFile(src,dst){ await copyHook(src,dst);if(typeof dst==='number')fs.ftruncateSync(dst,0);fs.writeFileSync(dst,fs.readFileSync(src)); },
    copyFileSync(src,dst){fs.writeFileSync(dst,fs.readFileSync(src));},
    moveFileSync(a,b,mode){assert.equal(mode,1);moveHook(b);assert.ok(!fs.existsSync(b),'文件模式必须拒绝同名目标');
      fs.linkSync(owned(a),owned(b));fs.unlinkSync(a);afterMove(b);},
    moveDirSync(a,parent,mode){assert.equal(mode,0);const b=path.join(parent,path.basename(a));assert.ok(!fs.existsSync(b));fs.renameSync(owned(a),owned(b));},
  };
  const factory=(zlib={})=>{
    const bindings={fs:fake};
    const cls=n=>load('entry/src/main/ets/components/ArchiveSelectionScope.ets',n,bindings);
    return load('entry/src/main/ets/components/GameArchiveIO.ets','GameArchiveIO',{
      fs:fake,ArchiveDirectory:cls('ArchiveDirectory'),ArchiveSource:cls('ArchiveSource'),missingEntry:cls('missingEntry'),zlib,
      picker:{DocumentSelectOptions:class{},DocumentSaveOptions:class{},DocumentViewPicker:class {
        async select(opt){options=opt;await selectHook();return selection;}
        async save(){await saveHook();return savePath?[savePath]:[];}
      }},GameStorage:s.api,setTimeout,clearTimeout,AppLogger:logger,LOG_DOMAIN_UI:0,removeDirRecursive:p=>fs.rmSync(owned(p),{recursive:true,force:true})
    });
  };
  const api=factory();
  selection = ['file://docs/a.jar', 'file://docs/%E4%B8%AD%E6%96%87%20b.jar'];
  let result = await api.importResourceFiles({}, dest, ['.jar']);
  assert.equal(options.maxSelectNumber, 500);
  assert.equal(result.names.length, 2,JSON.stringify(result));
  assert.equal(result.failures.length, 0);
  assert.equal(fs.readFileSync(path.join(dest, '中文 b.jar'), 'utf8'), 'new jar bytes');
  pass('multi-selection imports every URI including encoded name');
  fs.writeFileSync(path.join(dest, 'unreadable.jar'), 'old bytes');
  fs.writeFileSync(path.join(dest, 'blocked.jar'), 'old bytes');
  selection = ['file://docs/unreadable.jar', 'file://docs/blocked.jar', 'file://docs/wrong.txt', 'file://docs/%2E%2E%2Fescape.jar', 'file://docs/good.jar'];
  result = await api.importResourceFiles({}, dest, ['.jar']);
  assert.equal(result.names.length, 1);
  assert.equal(result.failures.length, 4);
  assert.equal(fs.readFileSync(path.join(dest, 'unreadable.jar'), 'utf8'), 'old bytes');
  assert.equal(fs.readFileSync(path.join(dest, 'blocked.jar'), 'utf8'), 'old bytes');
  assert.equal(fs.readdirSync(dest).some(n => n.startsWith('.amcl-import-')), false);
  pass('partial failure continues, old files survive and staging is cleaned');
  selection = [];
  result = await api.importResourceFiles({}, dest, ['.jar']);
  assert.equal(result.cancelled, true);
  assert.equal(result.failures.length, 0);
  pass('cancel is distinct from failure');
  selection = ['file://docs/one.zip'];
  result = await api.importResourceFile({}, dest, ['.zip']);
  assert.equal(options.maxSelectNumber, 1);
  assert.equal(result.ok, true);
  pass('single JDK/modpack install retains its single-task contract');
  selection = ['file://docs/notes.txt', 'file://docs/config.json'];
  result = await api.importAnyFiles({}, dest);
  assert.equal(result.names.length, 2,JSON.stringify(result));
  assert.equal(options.fileSuffixFilters, undefined);
  pass('file browser accepts multiple files without extension filtering');

  let archiveIndex = 0;
  const saves = path.join(temp, 'saves');
  selection=['file://docs/a/world.zip','file://docs/b/broken.zip','file://docs/c/world.zip'];
  const archives=factory({decompressFile:(_zip,dest,callback)=>{
    fs.writeFileSync(path.join(dest,'level.dat'),'world bytes');
    if(++archiveIndex===2)fs.writeFileSync(path.join(dest,'broken.bin'),'bad');
    callback(null);
  }});
  result = await archives.importSaveZips({ tempDir: temp }, saves);
  assert.equal(options.maxSelectNumber, 500);
  assert.equal(result.names.length, 2,JSON.stringify(result));
  assert.equal(result.failures.length, 1,JSON.stringify(result));
  assert.equal(fs.readFileSync(path.join(saves, 'world', 'level.dat'), 'utf8'), 'world bytes');
  assert.equal(fs.readFileSync(path.join(saves, 'world (1)', 'level.dat'), 'utf8'), 'world bytes');
  assert.equal(fs.existsSync(path.join(saves, 'broken')), false);
  pass('multiple saves keep unique names, continue after failure and clean incomplete world');
  const actualRoot=path.join(temp,'scope'),base=path.join(actualRoot,'versions'),target=path.join(base,'one');
  fs.mkdirSync(target,{recursive:true});fs.writeFileSync(path.join(target,'existing.jar'),'before');
  let current=true;const scope={root:actualRoot,current:()=>current};
  function rotate(p,old){fs.renameSync(owned(p),owned(old));fs.mkdirSync(owned(p));}
  selection=['file://docs/existing.jar'];
  selectHook=()=>{rotate(target,target+'-previous');fs.writeFileSync(path.join(target,'existing.jar'),'replacement');};
  result=await api.importAnyFiles({},target,scope);assert.equal(result.names.length,0);assert.ok(result.failures.length);assert.equal(fs.readFileSync(path.join(target,'existing.jar'),'utf8'),'replacement');
  assert.equal(fs.readFileSync(path.join(target+'-previous','existing.jar'),'utf8'),'before');
  pass('same-name directory replacement during system picker receives zero imported bytes');
  selectHook=()=>{};selection=['file://docs/race.jar'];
  const replacement=path.join(actualRoot,'replacement-during-copy');fs.mkdirSync(replacement);fs.writeFileSync(path.join(replacement,'race.jar'),'raced');
  // Windows 不允许移动有打开写句柄的目录；注入路径解析换代，fd 仍真实指向原文件，这是设备上需抵御的竞态。
  copyHook=()=>{lookup=p=>path.resolve(p)===path.resolve(target)?replacement:p;copyHook=()=>{};};
  result=await api.importAnyFiles({},target,scope);assert.equal(result.names.length,0);assert.ok(result.failures.length);assert.equal(fs.readFileSync(path.join(replacement,'race.jar'),'utf8'),'raced');
  assert.deepEqual(fs.readdirSync(replacement),['race.jar']);lookup=p=>p;
  pass('open destination fd pins the original staging file through asynchronous copy');
  selection=['file://docs/first.jar','file://docs/second.jar'];afterMove=()=>{current=false;afterMove=()=>{};};
  result=await api.importAnyFiles({},target,scope);assert.ok(result.failures.length);assert.deepEqual([...result.names],['first.jar']);assert.equal(result.targetChanged,true);assert.equal(fs.existsSync(path.join(target,'second.jar')),false);current=true;
  moveHook=b=>{fs.writeFileSync(b,'new concurrent user file');moveHook=()=>{};};selection=['file://docs/collision.jar'];
  result=await api.importAnyFiles({},target,scope);assert.equal(result.names.length,0);assert.equal(fs.readFileSync(path.join(target,'collision.jar'),'utf8'),'new concurrent user file');
  pass('publication refuses a collision created at commit and does not continue into a changed scope');
  const tree=path.join(actualRoot,'worlds');fs.mkdirSync(tree);selection=['file://docs/archive.zip'];
  const worldRace=factory({decompressFile:(_zip,raw,callback)=>{fs.writeFileSync(path.join(raw,'level.dat'),'level');rotate(tree,tree+'-old');fs.mkdirSync(path.join(tree,'players'));callback(null);}});
  result=await worldRace.importSaveZips({tempDir:temp},tree,scope);assert.equal(result.names.length,0);assert.deepEqual(fs.readdirSync(tree),['players']);
  pass('world extraction cannot populate a replacement saves directory');
  const input=path.join(actualRoot,'owned.txt'),replaced=input+'-old',out=path.join(temp,'output.txt');fs.writeFileSync(input,'original');fs.writeFileSync(out,'do not truncate');
  savePath=out;saveHook=()=>{fs.renameSync(owned(input),owned(replaced));fs.writeFileSync(input,'replacement content');};
  let exported=await api.exportFile({tempDir:temp},input,'owned.txt',scope);assert.equal(exported.ok,false);assert.equal(fs.readFileSync(out,'utf8'),'do not truncate');
  saveHook=()=>{};exported=await api.exportFile({tempDir:temp},input,'owned.txt',scope);assert.equal(exported.ok,true);assert.equal(fs.readFileSync(out,'utf8'),'replacement content');
  savePath=input;exported=await api.exportFile({tempDir:temp},input,'owned.txt',scope);assert.equal(exported.ok,false);assert.equal(fs.readFileSync(input,'utf8'),'replacement content');
  const folderSource=path.join(actualRoot,'export-source');fs.mkdirSync(folderSource);fs.writeFileSync(path.join(folderSource,'level.dat'),'frozen original');
  const compressed=factory({CompressLevel:{COMPRESS_LEVEL_DEFAULT_COMPRESSION:1},compressFile(src,dest,_settings,cb){fs.writeFileSync(dest,fs.readFileSync(path.join(src,'level.dat')));cb(null);}});
  savePath=out;saveHook=()=>{rotate(folderSource,folderSource+'-old');fs.writeFileSync(path.join(folderSource,'level.dat'),'unrelated new world');};
  exported=await compressed.exportSaveZip({tempDir:temp},actualRoot,'export-source',scope);assert.equal(exported.ok,false);assert.equal(fs.readFileSync(out,'utf8'),'replacement content');
  saveHook=()=>{};exported=await compressed.exportDirZip({tempDir:temp},folderSource,'export-source',scope);
  assert.equal(exported.ok,true);assert.equal(fs.readFileSync(out,'utf8'),'unrelated new world');
  pass('world and folder export reject a replaced source before touching the selected output; intact original archive exports');
  let chooser=0;selectHook=()=>{chooser++;};selection=['file://docs/consent.jar'];const asked={root:actualRoot,current:()=>true,consent:async()=>{
    rotate(target,target+'-dialog');return true;}};
  result=await api.importAnyFiles({},target,asked);assert.equal(chooser,0);assert.equal(result.names.length,0);assert.ok(result.failures.length);
  result=await api.importAnyFiles({},target,{...scope,consent:async()=>false});assert.equal(chooser,0);assert.equal(result.cancelled,true);
  pass('scope captured before shared-directory consent; cancellation or replacement never opens picker');
  let foreign='';copyHook=(_src,dst)=>{foreign=path.join(path.dirname(opened.get(dst)),'user-file');fs.writeFileSync(foreign,'keep');throw Error('read interrupted');};
  result=await api.importAnyFiles({},target,scope);assert.ok(result.failures.length);assert.equal(fs.readFileSync(foreign,'utf8'),'keep');assert.equal(fs.readdirSync(path.dirname(foreign)).join(','),'user-file');copyHook=()=>{};
  pass('cleanup only removes issued staging members and keeps independently inserted files');
  // 使用三个页面原来的 doImport：人的点击与机器的 fileSkill_/resourceSkill_ 最终执行相同的这一段。
  for (const [panel, method] of [['VersionFileBrowser','importInstanceFiles'],['InstalledResourcesSheet','importInstalledResources'],['SavesManagerSheet','importWorlds']]) {
    const area=path.join(actualRoot,panel).split(path.sep).join('/');fs.mkdirSync(area);const destination=area+'/target';fs.mkdirSync(destination);
    const original=path.join(destination,'existing.jar');fs.writeFileSync(original,'original');
    let prompted=0,picked=0;
    selection=['file://docs/existing.jar'];selectHook=()=>{picked++;rotate(destination,destination+'-old');fs.writeFileSync(original,'preserve replacement');};
    const subjectFile='entry/src/main/ets/components/'+panel+'.ets';
    const raw=fs.readFileSync(path.join(root,subjectFile),'utf8');const ast=compiler.createSourceFile(subjectFile,raw,compiler.ScriptTarget.Latest,true);
    const page=ast.statements.find(x=>x.name?.text===panel);
    const entry=panel==='InstalledResourcesSheet'?'resourceSkill_':'fileSkill_';
    const members=[entry,'doImport'].map(k=>page.members.find(x=>x.name?.text===k).getText(ast)).join('\n');
    const js=compiler.transpileModule('class Panel { '+members+' }\nmodule.exports=Panel;', {compilerOptions:{target:compiler.ScriptTarget.ES2022}}).outputText;
    const handoffs=[];
    const mod={exports:{}};new Function('module','result','textArg','GameArchiveIO','metaOf','resolveInstanceGameDir','AppLogger','hilog','LOG_DOMAIN_DOWNLOAD','TAG','LOG_DOMAIN_UI','LauncherSkillBus',js)(mod,
      (state,reason)=>({state,reason}),(o,k)=>o[k]??'',api,()=>({primaryExt:'.jar'}),(mc)=>mc,logger,logger,0,'mock',0,{awaitingUser:m=>handoffs.push(m)});
    const Scope=load('entry/src/main/ets/launcherskill/SkillFileScope.ets','SkillFileScope',{fs:fake,util:{generateRandomUUID:()=>String(Math.random())}});
    const scopeRef=new Scope(), ref=scopeRef.list(area,destination,'one');
    const ui=Object.assign(new mod.exports(),{mcDir:area,versionIsolation:false,kind:'mod',versionId:'one',active:true,navigationProjectionAlive_:true,mounted_:true,
      theme:{textSecondary:'#333',actionText:'#000'},busy:false,importing:false,skillScope_:scopeRef,curDir:()=>destination,targetDir:()=>destination,savesDir:()=>destination,navigationBlocked_:()=>false,
      getAbilityCtx:()=>({tempDir:temp}),getUIContext:()=>({getPromptAction:()=>({showDialog:async choice=>{
        assert.match(choice.title,/共享/);assert.match(choice.message,/同名/);prompted++;return {index:1};}})}),safeToast(){},refresh(){},onChanged(){},
      localResourceAccess_:()=>({active:true,version:'one',kind:'mod',shared:true,ready:true,error:false,pending:'',directory:destination,rows:[]})});
    const answer=await ui[entry](method,{instance:'one',kind:'mod',folder:ref});
    assert.ok(handoffs.includes(method) && handoffs.every(name=>name===method),panel+' linked this picker to its original operation');
    assert.equal(prompted,1,panel+' '+JSON.stringify(answer));assert.equal(picked,1,panel+' '+JSON.stringify(answer));assert.equal(answer.state,'failed',panel);assert.equal(answer.reason,'directoryChanged',panel);
    assert.equal(fs.readFileSync(original,'utf8'),'preserve replacement',panel);assert.equal(fs.readFileSync(path.join(destination+'-old','existing.jar'),'utf8'),'original',panel);
    assert.ok(!scopeRef.belongs(area,destination,'one',ref));
  }
  pass('three actual UI/Skill panel entry methods share consent, picker guard, stale failure and original-target preservation');

  // 在真实临时目录执行页面及原对象确认。仅用目录 fd 替身跨过 Windows 的目录打开差异。
  const archiveClasses='entry/src/main/ets/components/ArchiveSelectionScope.ets';
  let simulatePartial=false;
  // 这里只替换 ArkTS/NAPI 边界，核对交付的 fd 与原文件一致。真实隔离、回迁和递归竞态由 Linux Native 测试验证。
  const mutationNative={archiveMutateConfirmedEntry(parent,entry,name,next){
    const source=folder+'/'+name;
    assert.equal(String(dirs.get(parent).ino),String(stat(folder).ino));
    assert.equal(String(fake.statSync(entry).ino),String(stat(source).ino));
    if(simulatePartial && !next) return '原目录仍有未删除的内容';
    if(next) fs.renameSync(owned(source),owned(folder+'/'+next));
    else fs.rmSync(owned(source),{recursive:true});
    return '';
  }};
  const confirmation=load(archiveClasses,'ArchiveEntryConfirmation',{fs:fake,entryNative:mutationNative});
  const isMissing=load(archiveClasses,'missingEntry',{fs:fake});
  const dirHandles=load(archiveClasses,'ArchiveDirectory',{fs:fake});
  const fileHandles=load(archiveClasses,'ArchiveSource',{fs:fake});
  function pageMethods(file, methods, bindings) {
    const source=fs.readFileSync(path.join(root,'entry/src/main/ets',file+'.ets'),'utf8');
    const ast=compiler.createSourceFile(file+'.ets',source,compiler.ScriptTarget.Latest,true);
    const component=ast.statements.find(item=>item.name?.text===file.split('/').pop());
    const members=methods.map(name=>component.members.find(x=>x.name?.text===name).getText(ast));
    const js=compiler.transpileModule('class Subject {\n'+members.join('\n')+'\n}\nmodule.exports=Subject;',
      {compilerOptions:{target:compiler.ScriptTarget.ES2022}}).outputText;
    const module={exports:{}};
    new Function('module',...Object.keys(bindings),js)(module,...Object.values(bindings));
    return new module.exports();
  }
  const mutationRoot=path.join(temp,'confirmed').replaceAll('\\','/');
  const folder=mutationRoot+'/worlds';
  fs.mkdirSync(folder,{recursive:true});
  for(const panel of ['SavesManagerSheet','VersionFileBrowser']){
    simulatePartial=false;
    const changes=[],notices=[];
    const names=['openDelete_','dismissEntry_','executeDelete','removeConfirmed_'];
    if(panel==='VersionFileBrowser') names.push('openRename','executeRename','renameConfirmed_','sanitizeName');
    const subject=pageMethods('components/'+panel,names,{ArchiveEntryConfirmation:confirmation,missingEntry:isMissing,fs:fake});
    Object.assign(subject,{mcDir:mutationRoot,versionId:'A',active:true,navigationProjectionAlive_:true,
      curDir:()=>folder,savesDir:()=>folder,safeToast:m=>notices.push(m),refresh(){},onChanged:()=>changes.push(true)});
    const world=folder+'/World',moved=folder+'/previous';
    fs.mkdirSync(world);subject.openDelete_('World',true);
    fs.renameSync(world,moved);fs.mkdirSync(world);fs.writeFileSync(world+'/level.dat','new');
    subject.executeDelete();
    assert.equal(fs.readFileSync(world+'/level.dat','utf8'),'new');assert.equal(changes.length,0);
    subject.openDelete_('World',true);subject.dismissEntry_();assert.ok(fs.existsSync(world));
    simulatePartial=true;subject.openDelete_('World',true);subject.executeDelete();
    assert.match(notices.at(-1),/删除未完成/);assert.equal(changes.length,0);assert.ok(fs.existsSync(world));
    if(panel==='VersionFileBrowser'){
      subject.openRename('World',true);fs.renameSync(world,folder+'/renamed-previous');fs.mkdirSync(world);
      subject.renameInput='Renamed';subject.executeRename();assert.equal(fs.existsSync(folder+'/Renamed'),false);
      subject.dismissEntry_();
      subject.openRename('World',true);subject.renameInput='Renamed';subject.executeRename();
      assert.ok(fs.existsSync(folder+'/Renamed'));fs.renameSync(folder+'/Renamed',world);changes.length=0;
    }
    simulatePartial=false;subject.openDelete_('World',true);subject.executeDelete();
    assert.equal(fs.existsSync(world),false);assert.equal(changes.length,1);
    assert.equal(dirs.size,0);assert.equal(opened.size,0);fs.rmdirSync(moved);
  }
  pass('player world/file confirmation preserves replacements, rejects partial deletion, renames original and releases handles');

  const pack=pageMethods('pages/ModBrowsePage',['ownLocalArchive_','dismissLocalDraft_','onLocalModpackVisibility_'],
    {ArchiveDirectory:dirHandles,ArchiveSource:fileHandles,fs:fake,AppLogger:logger,TAG:'pack',LOG_DOMAIN_DOWNLOAD:0});
  const drafts=mutationRoot+'/modpack-import',draft=drafts+'/unique';
  fs.mkdirSync(draft,{recursive:true});
  const file=draft+'/pack.zip';
  fs.writeFileSync(file,'copy');
  pack.localArchiveOwner_=pack.ownLocalArchive_(mutationRoot,draft,'pack.zip');pack.localModpackArchive_=file;
  pack.showLocalModpackDetail_=false;pack.onLocalModpackVisibility_();assert.equal(fs.existsSync(draft),false);
  fs.mkdirSync(draft);fs.writeFileSync(file,'new copy');fs.writeFileSync(draft+'/unrelated','keep');
  pack.localArchiveOwner_=pack.ownLocalArchive_(mutationRoot,draft,'pack.zip');pack.dismissLocalDraft_();
  assert.equal(fs.existsSync(file),false);assert.equal(fs.readFileSync(draft+'/unrelated','utf8'),'keep');
  fs.writeFileSync(file,'submitted');pack.ownLocalArchive_(mutationRoot,draft,'pack.zip')(false);
  assert.equal(fs.readFileSync(file,'utf8'),'submitted');
  pass('unsubmitted local pack cleans its own archive, preserves other entries and transfers the submitted file');
  assert.equal(dirs.size,0);assert.equal(opened.size,0);
  pass('regular export pins source across picker, refuses self-truncation and closes all descriptors');
  console.log(`ALL PASS: ${count} behavior groups; platform APIs mocked, real temporary filesystem used`);
} finally {
  assert(path.resolve(temp).startsWith(path.resolve(workspaceTempRoot()) + path.sep + 'amcl-file-access-'));
  fs.rmSync(temp, { recursive: true, force: true });
}
