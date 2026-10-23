/**
 * 已核验 SDK 消费闭包的内容身份。此摘要明确区别于全 SDK 摘要：所有成员/链接仍遍历
 * 验证，但只读取声明会被当前 default/arm64/BiSheng 编译、单测、打包和审核消费的字节。
 * 现有 Ninja 图作为只读范围见证；发现未知版本、布局、工具或越界消费返回 UNAVAILABLE，
 * 调用者必须令 quick 回退 full，不能省略原 full 门禁。无下载、工具重建、构建或设备操作。
 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const SELF=fileURLToPath(import.meta.url);
const POLICY=fileURLToPath(new URL('../../config/sdk-build-inputs.json',import.meta.url));
const slash=value=>value.replaceAll('\\','/');
const sha=value=>crypto.createHash('sha256').update(value).digest('hex');
const stable=value=>value===null||typeof value!=='object'?JSON.stringify(value):Array.isArray(value)?'['+value.map(stable).join(',')+']':
  '{'+Object.keys(value).sort().map(key=>JSON.stringify(key)+':'+stable(value[key])).join(',')+'}';
const within=(root,selected)=>{const relative=path.relative(root,selected);return relative===''||(!path.isAbsolute(relative)&&relative!=='..'&&!relative.startsWith('..'+path.sep));};
const beneath=(name,prefix)=>name===prefix||name.startsWith(prefix+'/');
const folded=value=>process.platform==='win32'?value.toLowerCase():value;

/** 使用单个同步缓冲区读取全部实际字节；不按 mtime/size 复用工作目录中的旧摘要。 */
function hashFile(filename,buffer) {
  const fd=fs.openSync(filename,'r'),hash=crypto.createHash('sha256');let bytes=0;
  try {let size;while((size=fs.readSync(fd,buffer))>0){bytes+=size;hash.update(buffer.subarray(0,size));}}
  finally {fs.closeSync(fd);}return {sha256:hash.digest('hex'),bytes};
}

/** 仅按头部/RVA读取 Windows PE import table，不把数百MB工具整体再读一次。 */
export function peImports(filename) {
  const fd=fs.openSync(filename,'r');
  const read=(offset,size)=>{const result=Buffer.alloc(size);if(fs.readSync(fd,result,0,size,offset)!==size)throw new Error('Truncated PE tool: '+filename);return result;};
  try {
    const dos=read(0,64);if(dos.toString('ascii',0,2)!=='MZ')throw new Error('Expected Windows PE tool: '+filename);
    const at=dos.readUInt32LE(0x3c),header=read(at,24);
    if(header.readUInt32LE(0)!==0x4550||header.readUInt16LE(4)!==0x8664)throw new Error('Unsupported PE host architecture: '+filename);
    const sections=header.readUInt16LE(6),optionalSize=header.readUInt16LE(20),optional=read(at+24,optionalSize);
    if(optional.readUInt16LE(0)!==0x20b||optionalSize<128||sections<1||sections>96)throw new Error('Unsupported PE layout: '+filename);
    const table=read(at+24+optionalSize,sections*40),ranges=[];
    for(let index=0;index<sections;index++){const base=index*40;ranges.push({rva:table.readUInt32LE(base+12),size:Math.max(table.readUInt32LE(base+8),table.readUInt32LE(base+16)),raw:table.readUInt32LE(base+20)});}
    const offset=rva=>{const section=ranges.find(row=>rva>=row.rva&&rva<row.rva+row.size);if(!section)throw new Error('PE import RVA outside sections');return section.raw+rva-section.rva;};
    const imports=[];const importRva=optional.readUInt32LE(120);
    const dllName=nameRva=>{
      const start=offset(nameRva),bytes=[];
      for(let cursor=0;cursor<260;cursor++){const value=read(start+cursor,1)[0];if(value===0)break;bytes.push(value);}
      const name=Buffer.from(bytes).toString('ascii');if(!/^[a-zA-Z0-9_.-]+\.dll$/i.test(name))throw new Error('Invalid PE import DLL name');return name;
    };
    let terminated=!importRva;
    for(let index=0;importRva&&index<1024;index++) {
      const row=read(offset(importRva)+index*20,20);if(row.every(byte=>byte===0)){terminated=true;break;}
      const nameRva=row.readUInt32LE(12);if(!nameRva)throw new Error('PE import descriptor missing DLL name');
      imports.push(dllName(nameRva));
    }
    if(!terminated)throw new Error('Unterminated PE import table');
    const delayRva=optionalSize>=224?optional.readUInt32LE(216):0;
    for(let index=0;delayRva&&index<1024;index++) {
      const row=read(offset(delayRva)+index*32,32);if(row.every(byte=>byte===0))return [...new Set(imports)];
      if(row.readUInt32LE(0)!==1)throw new Error('Unsupported delayed PE import address mode');
      imports.push(dllName(row.readUInt32LE(4)));if(index===1023)throw new Error('Unterminated delayed PE import table');
    }
    return [...new Set(imports)];
  } finally {fs.closeSync(fd);}
}

/** root 接受选中的 openharmony 组件根，或包含 default/openharmony 的 SDK 安装根。 */
function bundleRoot(root) {
  const absolute=fs.realpathSync(path.resolve(root));
  if(fs.existsSync(path.join(absolute,'default/openharmony/native')))return fs.realpathSync(path.join(absolute,'default'));
  if(fs.existsSync(path.join(absolute,'openharmony/native')))return absolute;
  if(path.basename(absolute).toLowerCase()==='openharmony'&&fs.existsSync(path.join(absolute,'native')))return fs.realpathSync(path.dirname(absolute));
  throw new Error('Unknown SDK root layout');
}

/** SDK本身可能用内部链接复用内容；所有链接均须落在声明bundle内，环仍拒绝。 */
function validateMember(root,filename) {
  const real=fs.realpathSync(filename);if(!within(root,real))throw new Error('SDK link escapes declared bundle: '+filename);return real;
}

/** 保守范围配置仅接受规范相对路径，不能用 .. 或绝对路径偷偷把别的SDK并入当前身份。 */
function safeRelative(name) {
  if(typeof name!=='string'||path.isAbsolute(name)||name.includes('\\')||name.split('/').some(part=>part==='..'||part===''))throw new Error('Invalid SDK scope path: '+name);
  return name;
}

/** 从现有图回读，不运行 configure/build；tests 可通过显式JS reader注入微型见证。 */
function readNativeEvidence(bundle,options) {
  if(options.nativeEvidenceReader)return options.nativeEvidenceReader();
  const directory=options.nativeBuildDir;if(!directory||!path.isAbsolute(directory))throw new Error('Existing nativeBuildDir required for SDK consumption evidence');
  for(const name of ['compile_commands.json','CMakeCache.txt','CMakeFiles/rules.ninja','build.ninja','.ninja_deps'])if(!fs.existsSync(path.join(directory,name)))throw new Error('Native consumption evidence missing: '+name);
  const ninja=path.join(bundle,'openharmony/native/build-tools/cmake/bin/ninja.exe');
  const deps=spawnSync(ninja,['-C',directory,'-t','deps'],{encoding:'utf8',maxBuffer:64*1024*1024,windowsHide:true});
  if(deps.error||deps.status!==0)throw new Error('Cannot read existing Ninja dependency database');
  return {compileCommands:JSON.parse(fs.readFileSync(path.join(directory,'compile_commands.json'),'utf8')),
    cmakeCache:fs.readFileSync(path.join(directory,'CMakeCache.txt'),'utf8'),ninjaRules:fs.readFileSync(path.join(directory,'CMakeFiles/rules.ninja'),'utf8'),
    buildNinja:fs.readFileSync(path.join(directory,'build.ninja'),'utf8'),dependencyText:deps.stdout};
}

/** 验证实际工具/目标及已有SDK依赖均在当前闭包。见证变化本身不冒充SDK文件内容变化。 */
function validateNativeEvidence(bundle,scope,policy,selected,options) {
  const proof=readNativeEvidence(bundle,options),prefix=slash(bundle)+'/',same=value=>folded(slash(value));
  const relative=filename=>{const normalized=slash(filename).replace(/^"|"$/g,'');return same(normalized).startsWith(same(prefix))?normalized.slice(prefix.length):null;};
  if(!Array.isArray(proof.compileCommands)||proof.compileCommands.length===0)throw new Error('Empty native compile database');
  const compilers=new Set();
  for(const row of proof.compileCommands) {
    const command=row.command??row.arguments?.join(' ');if(typeof command!=='string')throw new Error('Unknown compile database command representation');
    const compiler=row.arguments?.[0]??/^"([^"]+)"|^(\S+)/.exec(command)?.slice(1).find(Boolean);
    const name=relative(compiler??'');
    if(!['hms/native/BiSheng/bin/clang.exe','hms/native/BiSheng/bin/clang++.exe'].includes(name)||!selected(name))throw new Error('Native compiler lies outside selected BiSheng scope');
    if(!command.includes('--target=aarch64-linux-ohos')||!same(command).includes(same(path.join(bundle,'openharmony/native/sysroot'))))throw new Error('Native target/sysroot differs from declared SDK ABI');
    compilers.add(name);
  }
  const cache=proof.cmakeCache;
  if(typeof cache!=='string')throw new Error('Missing native CMake evidence');
  const fields=new Map([...cache.matchAll(/^([^#\r\n:=]+):[^=\r\n]*=(.*)$/gm)].map(match=>[match[1],match[2].trim()]));
  if(fields.get('OHOS_ARCH')!==scope.abi||fields.get('CMAKE_OHOS_ARCH_ABI')!==scope.abi||
    relative(fields.get('CMAKE_TOOLCHAIN_FILE')??'')!=='hms/native/build/cmake/hmos.toolchain.bisheng.cmake'||
    relative(fields.get('CMAKE_MAKE_PROGRAM')??'')!=='openharmony/native/build-tools/cmake/bin/ninja.exe') {
    throw new Error('Native CMake toolchain/ABI evidence differs from SDK scope');
  }
  const dependencies=proof.dependencyText.split(/\r?\n/).map(line=>relative(line.trim())).filter(Boolean);
  if(dependencies.length===0)throw new Error('No SDK header dependencies in existing Ninja evidence');
  for(const name of dependencies)if(!selected(name))throw new Error('Observed SDK dependency outside declared consumer scope: '+name);
  // Ninja 使用 $:/$空格转义。目录参数也要核对，不能只检查带扩展名的库而漏掉 -L 外ABI路径。
  const graphs=slash([proof.ninjaRules,proof.buildNinja].join('\n')).replaceAll('$:',':').replaceAll('$ ',' ').replaceAll('$$','$');
  const graphPattern=new RegExp(prefix.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'[^\\r\\n"$ <>|;]+','gi');
  const graphFiles=[...graphs.matchAll(graphPattern)].map(match=>relative(match[0])).filter(Boolean);
  const ancestor=name=>policy.trees.some(tree=>tree.startsWith(name+'/'))||policy.nativeBinDirectories.some(directory=>directory===name||directory.startsWith(name+'/'));
  for(const name of graphFiles)if(!selected(name)&&!ancestor(name))throw new Error('Observed SDK graph input outside declared consumer scope: '+name);
  if(typeof proof.ninjaRules!=='string'||!slash(proof.ninjaRules).includes('hms/native/BiSheng/bin/clang'))throw new Error('Native Ninja compiler witness missing');
  return {compilerPaths:[...compilers].sort(),sdkHeaderDependencyCount:new Set(dependencies).size,sdkGraphInputCount:new Set(graphFiles).size,
    note:'Existing graph is a scope witness; these counts and graph timestamps are not SDK content identity.'};
}

/**
 * fingerprintSdk(root,{platform,arch,abi,product,mode,nativeCompiler,nativeBuildDir,compilerArguments,onStage})
 * identity 是供会话起止比较的稳定内容记录；qualification 独立决定能否授予 quick。
 * 缺旧Native图的full仍生成相同内容identity，不能因本轮建图成功把合法输入误判漂移。
 * UNAVAILABLE 不抛弃原full门禁，仅撤销quick资格。仅JS单元测试可传nativeEvidenceReader。
 */
export function fingerprintSdk(root,options={}) {
  const started=performance.now(),metrics={members:0,links:0,hashedFiles:0,hashedBytes:0,excludedFiles:0};
  try {
    const policyBytes=fs.readFileSync(POLICY),policy=JSON.parse(policyBytes),bundle=bundleRoot(root),scope={
      platform:options.platform??process.platform,arch:options.arch??process.arch,abi:options.abi??'arm64-v8a',product:options.product??'default',
      mode:options.mode??'debug',nativeCompiler:options.nativeCompiler??'BiSheng',sdkVersion:policy.scope.sdkVersion,clangVersion:policy.scope.clangVersion,
      compilerArguments:options.compilerArguments??[]};
    if(policy.schema!==1)throw new Error('Unknown SDK scope schema');
    for(const [name,value]of Object.entries(policy.scope))if(scope[name]!==value)throw new Error('Unsupported SDK consumer scope '+name+'='+scope[name]);
    if(!Array.isArray(scope.compilerArguments)||scope.compilerArguments.some(value=>typeof value!=='string'))throw new Error('Invalid compiler argument scope');
    for(const name of [...policy.trees,...policy.excludedTrees,...policy.requiredFiles,...policy.metadataFiles,...policy.toolFiles,...policy.nativeBinDirectories])safeRelative(name);
    for(const [relative,members]of Object.entries(policy.layoutMembers)) {
      const directory=path.join(bundle,relative),actual=fs.readdirSync(directory).sort();validateMember(bundle,directory);
      if(stable(actual)!==stable([...members].sort()))throw new Error('Unknown SDK layout members: '+(relative||'bundle'));
    }
    const explicit=new Set([...policy.requiredFiles,...policy.metadataFiles,...policy.toolFiles]);
    validateMember(bundle,path.join(bundle,'sdk-pkg.json'));
    const packageMetadata=JSON.parse(fs.readFileSync(path.join(bundle,'sdk-pkg.json'),'utf8'));
    if(packageMetadata.data?.version!==scope.sdkVersion||String(packageMetadata.data?.apiVersion)!=='26')throw new Error('Unknown SDK bundle version');
    for(const family of ['openharmony','hms'])for(const component of ['ets','js','native','previewer','toolchains']) {
      const metadata=family+'/'+component+'/'+(family==='openharmony'?'oh-uni-package.json':'uni-package.json');
      validateMember(bundle,path.join(bundle,metadata));
      const value=JSON.parse(fs.readFileSync(path.join(bundle,metadata),'utf8'));
      if(value.version!==scope.sdkVersion||String(value.apiVersion)!=='26'||value.path!==component)throw new Error('Unknown SDK component version: '+metadata);
      explicit.add(metadata);
    }
    for(const directory of policy.nativeBinDirectories)for(const name of policy.nativeTools)explicit.add(directory+'/'+name);
    for(const name of policy.bishengDriverTools)explicit.add('hms/native/BiSheng/bin/'+name);
    const windowsSystem=new RegExp(policy.systemDllPattern,'i'),imports={},queue=[...explicit].filter(name=>name.endsWith('.exe'));
    // 工具旁的实际DLL导入递归绑定；未声明/未找到的非系统导入使闭包不可用。
    for(let index=0;index<queue.length;index++) {
      const name=queue[index],absolute=path.join(bundle,name);validateMember(bundle,absolute);
      const dependencies=peImports(absolute);imports[name]=dependencies.map(value=>value.toLowerCase()).sort();
      const adjacent=fs.readdirSync(path.dirname(absolute)),names=new Map(adjacent.map(value=>[value.toLowerCase(),value]));
      for(const dependency of dependencies) {
        const found=names.get(dependency.toLowerCase());
        if(found) {
          const target=slash(path.posix.join(path.posix.dirname(name),found));
          if(!explicit.has(target)){explicit.add(target);queue.push(target);}
        } else if(!windowsSystem.test(dependency)&&!policy.observedSystemDllNames.some(value=>value.toLowerCase()===dependency.toLowerCase())) {
          throw new Error('Unresolved non-system SDK DLL dependency: '+name+' -> '+dependency);
        }
      }
    }
    const selected=name=>!policy.excludedTrees.some(prefix=>beneath(name,prefix))&&(explicit.has(name)||policy.trees.some(prefix=>beneath(name,prefix)));
    for(const name of [...policy.trees,...explicit])if(!fs.existsSync(path.join(bundle,name)))throw new Error('Required SDK scope input missing: '+name);
    const rows=[],membership=[{path:'',kind:'directory'}],stack=new Set(),buffer=Buffer.allocUnsafe(1024*1024);
    const walk=(filename,relative,physical)=>{
      const stat=fs.lstatSync(filename),link=stat.isSymbolicLink(),real=link?validateMember(bundle,filename):physical;
      metrics.members++;if(link){metrics.links++;if(selected(relative))rows.push({path:relative,kind:'link',target:fs.readlinkSync(filename)});}
      const actual=link?fs.statSync(filename):stat;
      membership.push({path:relative,kind:link?'link':actual.isDirectory()?'directory':actual.isFile()?'file':'unknown',
        ...(link?{target:fs.readlinkSync(filename),targetKind:actual.isDirectory()?'directory':'file'}:{})});
      if(actual.isDirectory()) {
        const key=folded(real);if(stack.has(key))throw new Error('SDK directory link cycle: '+relative);stack.add(key);
        if(selected(relative))rows.push({path:relative,kind:'directory'});
        for(const entry of fs.readdirSync(filename,{withFileTypes:true}).sort((a,b)=>a.name<b.name?-1:a.name>b.name?1:0)) {
          walk(path.join(filename,entry.name),relative?relative+'/'+entry.name:entry.name,path.join(real,entry.name));
        }
        stack.delete(key);
      } else if(actual.isFile()) {
        if(selected(relative)){const identity=hashFile(real,buffer);rows.push({path:relative,kind:'file',...identity});metrics.hashedFiles++;metrics.hashedBytes+=identity.bytes;}
        else metrics.excludedFiles++;
      } else throw new Error('Unknown SDK member kind: '+relative);
    };
    walk(path.join(bundle,'sdk-pkg.json'),'sdk-pkg.json',validateMember(bundle,path.join(bundle,'sdk-pkg.json')));
    for(const family of ['openharmony','hms']){const began=performance.now();walk(path.join(bundle,family),family,validateMember(bundle,path.join(bundle,family)));options.onStage?.({stage:'sdkConsumerClosure',name:family,milliseconds:performance.now()-began,...metrics});}
    const membershipSha256=sha(stable(membership));
    const manifest={schema:1,profile:policy.profile,scope,root:bundle,policySha256:sha(policyBytes),implementationSha256:sha(fs.readFileSync(SELF)),imports,membershipSha256,files:rows};
    const key=sha(stable(manifest)),identity={state:'CONTENT_IDENTITY',schema:1,profile:policy.profile,scope,root:bundle,key,membershipSha256};
    let qualification;
    try {qualification={state:'AVAILABLE',evidence:validateNativeEvidence(bundle,scope,policy,selected,options)};}
    catch(error){qualification={state:'UNAVAILABLE',reason:error.message};}
    return {state:qualification.state,identity,qualification,key,scope,metrics:{...metrics,milliseconds:performance.now()-started},
      limitation:policy.excludedReason};
  } catch(error) {
    return {state:'UNAVAILABLE',identity:{state:'UNAVAILABLE',schema:1,reason:error.message},qualification:{state:'UNAVAILABLE',reason:error.message},reason:error.message,metrics:{...metrics,milliseconds:performance.now()-started}};
  }
}
