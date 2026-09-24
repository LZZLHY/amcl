/**
 * 安装策略回归：执行真实 ModInstallService、API 依赖解析器、文件事务和安装索引。
 * 网络/设备文件系统与来源识别是受控边界；内存文件系统保留真实旧字节并支持提交故障注入。
 * 特殊/旧版 JAR 的元数据不参与裁决，明确选版、传输校验、并发快照及回滚仍须生效。
 */
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {loader, productionPathPolicy, root, ts} from './mod-install-test-runtime.mjs';

const policy = productionPathPolicy();
const hash = body => crypto.createHash('sha1').update(body).digest('hex');
const parent = name => name.slice(0, name.lastIndexOf('/'));

/** 构造 CRC 正确的普通 ZIP/JAR，不依赖本轮退役的元数据读取器。 */
function jar(entries) {
  const locals = [], central = [];
  let offset = 0;
  for (const [name, text] of Object.entries(entries)) {
    const filename = Buffer.from(name), body = Buffer.from(text);
    let crc = 0xffffffff;
    for (const byte of body) {
      crc ^= byte;
      for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    }
    crc = (crc ^ 0xffffffff) >>> 0;
    const local = Buffer.alloc(30), entry = Buffer.alloc(46);
    local.writeUInt32LE(0x04034b50); local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(body.length, 18); local.writeUInt32LE(body.length, 22); local.writeUInt16LE(filename.length, 26);
    entry.writeUInt32LE(0x02014b50); entry.writeUInt32LE(crc, 16);
    entry.writeUInt32LE(body.length, 20); entry.writeUInt32LE(body.length, 24); entry.writeUInt16LE(filename.length, 28);
    entry.writeUInt32LE(offset, 42);
    const data = Buffer.concat([local, filename, body]);
    locals.push(data); central.push(entry, filename); offset += data.length;
  }
  const directory = Buffer.concat(central), end = Buffer.alloc(22), count = Object.keys(entries).length;
  end.writeUInt32LE(0x06054b50); end.writeUInt16LE(count, 8); end.writeUInt16LE(count, 10);
  end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, directory, end]);
}

/** 直接提取生产函数，断言传给下载边界的大小/哈希及安全路径仍由真实构造器生成。 */
const installerFile = path.join(root, 'mods/src/main/ets/ModInstaller.ets');
const installerAst = ts.createSourceFile(installerFile, fs.readFileSync(installerFile, 'utf8'), ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
const buildFunction = installerAst.statements.find(node => ts.isFunctionDeclaration(node) && node.name?.text === 'buildDownloadSpec');
assert.ok(buildFunction, '必须执行生产 buildDownloadSpec');
const downloadExports = {};
vm.runInNewContext(ts.transpileModule(buildFunction.getText(installerAst), {compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText,
  {exports:downloadExports, safeBaseName:policy.safeBaseName});

/** 每例独立加载服务，目录锁/缓存不会跨用例泄漏；系统外不创建用户文件。 */
function harness(options = {}) {
  const mcDir = '/virtual/mc', versionId = '自定义整合包', isolation = options.isolation ?? true;
  const dir = isolation ? mcDir + '/versions/' + versionId + '/mods' : mcDir + '/mods';
  const files = new Map(), dirs = new Set(), handles = new Map(), downloads = [], phases = [], exactIds = [], metadataReads = [];
  const original = jar({'mcmod.info':'[{"modid":"old_coremod","version":"1.0-final"}]'});
  const unrelated = jar({'META-INF/MANIFEST.MF':'Manifest-Version: 1.0\nFMLCorePlugin: example.Plugin\n'});
  const replacement = jar({'quilt.mod.json':JSON.stringify({quilt_loader:{id:'root',version:'opaque-build',depends:[{any:[{id:'api-a'},{id:'api-b'}]}]}})});
  const dependency = jar({'README.txt':'普通辅助库由实际加载器发现；AMCL 不要求 fabric.mod.json。'});
  const put = (name, body) => files.set(name, Buffer.from(body));
  const makeDirs = name => {for (let current = name; current.length; current = parent(current)) dirs.add(current);};
  makeDirs(dir); put(dir + '/old.jar', original); put(dir + '/legacy-helper.jar', unrelated);
  const initialIndex = JSON.stringify({version:1,entries:[{baseName:'old.jar',source:'modrinth',projectId:'root',versionId:'root-old',
    expectedSha1:hash(original),expectedSize:original.length,displayName:'旧模组',at:1}]});
  put(dir + '/.amcl-mods-index.json', initialIndex);
  if(options.fresh){files.delete(dir+'/old.jar');files.delete(dir+'/.amcl-mods-index.json');}
  if(options.disabled){files.delete(dir+'/old.jar');put(dir+'/old.jar.disabled',original);}
  let nextFd = 1, cancelled = false, injected = false, nextTask = 1, oldFileHashReads = 0, cancelledAtFingerprint = false;
  const stat = name => {
    if (!files.has(name) && !dirs.has(name)) throw new Error('ENOENT ' + name);
    return {size:files.get(name)?.length ?? 0,isFile:()=>files.has(name),isDirectory:()=>dirs.has(name),isSymbolicLink:()=>false};
  };
  const io = {
    OpenMode:{CREATE:1,WRITE_ONLY:2,TRUNC:4,READ_ONLY:8},statSync:stat,lstatSync:stat,
    mkdirSync(name){if(dirs.has(name))throw new Error('EEXIST');makeDirs(name);},
    listFileSync:name=>[...files.keys(),...dirs].filter(file=>parent(file)===name).map(file=>file.slice(file.lastIndexOf('/')+1)),
    openSync(name, flags){
      // 服务可写 journal/索引；包内读取若重新接入，立即失败而不能被测试边界悄悄掩盖。
      if(flags===8){metadataReads.push(name);throw new Error('不应读取 JAR 元数据 '+name);}
      put(name,'');const fd=nextFd++;handles.set(fd,name);return {fd};
    },
    writeSync(fd, body){put(handles.get(fd),body);return Buffer.byteLength(body);},
    fsyncSync(){},closeSync(handle){handles.delete(handle.fd ?? handle);},
    readTextSync:name=>{if(!files.has(name))throw new Error('ENOENT');return files.get(name).toString();},
    renameSync(from, to){
      if(options.commitFailure && !injected && from.includes('/download/') && to===dir+'/dependency.jar'){
        injected=true;throw new Error('注入第二个文件提交失败');
      }
      if(!files.has(from))throw new Error('ENOENT '+from);
      files.set(to,files.get(from));files.delete(from);
    },
    unlinkSync(name){if(!files.delete(name))throw new Error('ENOENT '+name);},
  };
  const remove = name => {
    for(const file of [...files.keys()])if(file===name||file.startsWith(name+'/'))files.delete(file);
    for(const directory of [...dirs])if(directory===name||directory.startsWith(name+'/'))dirs.delete(directory);
  };
  const remoteFile = (filename, body) => ({url:'https://example.invalid/'+filename,mirrors:[],filename,size:body.length,sha1:hash(body),isPrimary:true});
  const makeVersion = (id, projectId, file) => ({id,projectId,source:'modrinth',versionNumber:id,versionType:'release',datePublished:'2026-01-01T00:00:00Z',
    gameVersions:['1.20.1'],loaders:['fabric'],files:[file],dependencies:[]});
  const dep = makeVersion('dependency-pinned','dependency',remoteFile('dependency.jar',dependency));
  const rootVersion = makeVersion('root-new','root',remoteFile('root-new.jar',replacement));
  if(options.repair)rootVersion.files[0].filename='old.jar';
  rootVersion.dependencies=[{projectId:'dependency',versionId:'dependency-pinned',dependencyType:'required'}];
  const repo = {
    async getProject(id){return {id,source:'modrinth',title:id};},
    async getVersions(){throw new Error('精确依赖不可回退为最新列表');},
    async getVersion(id){exactIds.push(id);if(options.missingDependency)throw new Error('指定依赖不可用');assert.equal(id,dep.id);return dep;},
  };
  const router = {repoFor:source=>source==='modrinth'?repo:null};
  class Scanner {
    async scan(){
      const oldName=options.disabled?'old.jar.disabled':'old.jar';
      const mods=[{filename:'legacy-helper.jar',filePath:dir+'/legacy-helper.jar',enabled:true,remoteSource:null,remoteProjectId:null,remoteVersionId:null,integrity:'unknown'}];
      if(!options.fresh)mods.unshift({filename:oldName,filePath:dir+'/'+oldName,enabled:options.disabled!==true,
        remoteSource:'modrinth',remoteProjectId:'root',remoteVersionId:'root-old',integrity:options.repair?'corrupt':'verified'});
      return {mods};
    }
  }
  const manager = {
    async createAndWait(spec, listener){
      const item=spec.files[0],taskId=nextTask++;downloads.push(item);
      listener({taskId,finished:false});
      let body=item.localPath.endsWith('dependency.jar')?dependency:replacement;
      if(options.badDownload==='size')body=body.subarray(0,body.length-1);
      if(options.badDownload==='hash'){body=Buffer.from(body);body[body.length-1]^=1;}
      assert.ok(item.check?.size>0,'大小要求必须下传');assert.match(item.check?.sha1 ?? '',/^[a-f0-9]{40}$/,'来源哈希必须下传');
      if(body.length!==item.check.size)throw new Error('下载大小校验失败');
      if(hash(body)!==item.check.sha1)throw new Error('下载哈希校验失败');
      put(item.localPath,body);
      if(options.externalMutation)put(dir+'/external.jar','用户在下载期间添加');
      if(options.cancelAfterDownload)cancelled=true;
      listener({taskId,finished:true});
    },
    cancel(){},purgeTask:()=>true,
  };
  const featureCore = {...policy,DownloadManager:{instance:()=>manager},computeFileSha1:async name=>{
    if(!files.has(name))throw new Error('ENOENT');
    if(name===dir+'/old.jar'){
      oldFileHashReads++;
      // 排序后的 old.jar 是现场指纹的最后一项；在其异步读取期间收到取消，准确覆盖最后一次 await。
      // 第一轮为下载前快照对照，第二轮为提交前现场复查，暂存文件校验不计入这两个轮次。
      const target=options.cancelAtFingerprint==='initial'?1:options.cancelAtFingerprint==='final'?2:0;
      if(oldFileHashReads===target){await Promise.resolve();cancelled=true;cancelledAtFingerprint=true;}
    }
    return hash(files.get(name));
  }};
  const log = {info(){},warn(){},error(){},debug(){}};
  const load = loader({'@kit.CoreFileKit':{fileIo:io},feature_core:featureCore,
    commons:{AppLogger:log,LOG_DOMAIN_DOWNLOAD:0,removeDirRecursive:remove},
    './InstalledLoaderResolver':{resolveInstalledLoader:()=> 'fabric',resolveInstalledMcVersion:()=> '1.20.1'},
    './LocalModScanner':{LocalModScanner:Scanner},'./ModInstaller':downloadExports,
    // 旧实现的任何包内裁决调用都会被记下；此边界仅为证明“不调用”，不伪造通过结果。
    './ModManifest':{readModDescriptors:async name=>{metadataReads.push(name);throw new Error('不应读取 JAR 元数据');},validateModSet:()=>{throw new Error('不应裁决模组组合');}},
  });
  const api=load('mods/src/main/ets/ModInstallService.ets'), service=new api.ModInstallService();
  const request={mcDir,versionId,versionIsolation:isolation,root:rootVersion,title:'特殊格式模组',router,optionalIds:[],
    oldPath:options.fresh?undefined:dir+(options.disabled?'/old.jar.disabled':'/old.jar')};
  const observer={phase:text=>phases.push(text),fileProgress(){},cancelled:()=>cancelled,files(){}};
  return {api,service,request,observer,dir,files,dirs,downloads,phases,exactIds,metadataReads,original,unrelated,replacement,dependency,initialIndex,
    run:()=>service.install(request,observer),injected:()=>injected,fingerprintCancellation:()=>cancelledAtFingerprint};
}

/** 更新/修复成功：无关旧 JAR 原样保留，下载身份和 pin 不变，两种目录隔离模式均执行真实事务。 */
for(const isolation of [true,false]){
  const h=harness({isolation});
  const environment=h.api.installedModEnvironment('/virtual/mc','旧实例');
  assert.equal(environment.loader,'fabric');assert.equal(environment.gameVersion,'1.20.1');
  await h.run();
  assert.deepEqual(h.metadataReads,[]);assert.equal(h.files.has(h.dir+'/old.jar'),false);
  assert.deepEqual(h.files.get(h.dir+'/root-new.jar'),h.replacement);
  assert.deepEqual(h.files.get(h.dir+'/dependency.jar'),h.dependency);
  assert.deepEqual(h.files.get(h.dir+'/legacy-helper.jar'),h.unrelated);
  assert.ok(h.exactIds.length>0);assert.ok(h.exactIds.every(id=>id==='dependency-pinned'));
  const index=JSON.parse(h.files.get(h.dir+'/.amcl-mods-index.json'));
  assert.deepEqual(index.entries.map(entry=>entry.versionId).sort(),['dependency-pinned','root-new']);
  assert.equal(h.files.has(h.dir+'/.amcl-mod-transaction.json'),false);
}

/** 新装、同名修复和禁用文件更新仍消费同一事务；禁用状态不因替换而变成启用。 */
for(const options of [{fresh:true},{repair:true},{disabled:true}]){
  const h=harness(options);await h.run();
  const filename=options.disabled?'root-new.jar.disabled':options.repair?'old.jar':'root-new.jar';
  assert.deepEqual(h.files.get(h.dir+'/'+filename),h.replacement);
  assert.deepEqual(h.files.get(h.dir+'/legacy-helper.jar'),h.unrelated);
  assert.deepEqual(h.metadataReads,[]);
  if(options.disabled){
    assert.equal(h.files.has(h.dir+'/root-new.jar'),false);assert.equal(h.files.has(h.dir+'/old.jar.disabled'),false);
    assert.equal(h.files.has(h.dir+'/dependency.jar'),false,'禁用主文件不应激活新依赖');
  }
}

/** 坏下载和中途提交失败仍保留旧文件/旧索引，不把移除语义检查变成直接覆盖。 */
for(const [options,message] of [
  [{badDownload:'size'},/下载大小校验失败/],
  [{badDownload:'hash'},/下载哈希校验失败/],
  [{commitFailure:true},/注入第二个文件提交失败/],
  [{cancelAfterDownload:true},/模组安装已取消/],
  [{cancelAtFingerprint:'initial'},/模组安装已取消/],
  [{cancelAtFingerprint:'final'},/模组安装已取消/],
  [{externalMutation:true},/本地模组发生变化/],
  [{missingDependency:true},/必需依赖尚未解决/],
]){
  const h=harness(options);await assert.rejects(h.run(),message);
  assert.deepEqual(h.files.get(h.dir+'/old.jar'),h.original);
  assert.equal(h.files.get(h.dir+'/.amcl-mods-index.json').toString(),h.initialIndex);
  assert.equal(h.files.has(h.dir+'/root-new.jar'),false);assert.equal(h.files.has(h.dir+'/dependency.jar'),false);
  assert.deepEqual(h.metadataReads,[]);
  if(options.commitFailure)assert.equal(h.injected(),true,'负控必须走到第二个文件提交，验证已激活首文件也回滚');
  if(options.missingDependency)assert.equal(h.downloads.length,0);
  if(options.externalMutation)assert.equal(h.files.get(h.dir+'/external.jar').toString(),'用户在下载期间添加');
  if(options.cancelAtFingerprint){
    assert.equal(h.fingerprintCancellation(),true,'取消必须发生在指定现场指纹读取期间');
    assert.equal(h.downloads.length,options.cancelAtFingerprint==='initial'?0:2);
    assert.equal(h.phases.includes('正在提交模组文件与安装记录'),false,'现场指纹检查期间收到取消不能进入提交阶段');
    assert.equal(h.files.has(h.dir+'/.amcl-mod-transaction.json'),false,'取消不能产生提交 journal');
  }
}

/** 来源明确标注的错误加载器/游戏版本仍在下载前拒绝；这是安装选版，不是本地组合推演。 */
for(const patch of [{loaders:['forge']},{gameVersions:['1.21.1']}]){
  const h=harness();Object.assign(h.request.root,patch);await assert.rejects(h.run(),/所选文件不支持目标版本/);assert.equal(h.downloads.length,0);
}
console.log('PASS: real installation service skips old/special JAR metadata; exact API pins, loader/game choice, size/hash, cancel, directory snapshots and mid-commit rollback remain enforced');
