/**
 * HAP 分轨运行的轻量证据账本。quick/full 按用户显式选择执行；普通会话只负责
 * 租约、计时、真实事件和当前产物收口，不读取源码/SDK全树或历史full基线。
 * 内容审计保留为full显式DeepAudit；它不是quick前置条件，也不会自动改档。
 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {resolveWorkspacePath, assertExternalOutputPath} from './workspace-paths.mjs';
import {findUnregisteredHapScripts} from './build-gate-inventory.mjs';
import {fingerprintSdk} from './sdk-build-inputs.mjs';

const self = fileURLToPath(import.meta.url);
const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const readJson = name => JSON.parse(fs.readFileSync(name, 'utf8').replace(/^\uFEFF/, ''));
const normalized = value => value.split(path.sep).join('/');
const inside = (root, candidate) => {const relative=path.relative(root,candidate);return relative==='' || (!path.isAbsolute(relative)&&relative!=='..'&&!relative.startsWith('..'+path.sep));};

// 身份扫描全程同步执行；复用唯一读缓冲区，避免为每个小文件申请并清零 1 MB。
// 只把 readSync 实际返回的字节送入哈希，因此短文件与空文件不会混入上次文件残留。
const HASH_READ_BUFFER = Buffer.allocUnsafe(1024 * 1024);

/** 分块读取大文件，避免 SDK/JAR 身份核对将大文件整体保留在内存。 */
function fileHash(name) {
  const stat = fs.lstatSync(name);
  if (stat.isSymbolicLink()) throw new Error('Input symlink cannot establish a saved-source identity: ' + name);
  if (!stat.isFile()) throw new Error('Expected file: ' + name);
  const hash = crypto.createHash('sha256');
  const buffer = HASH_READ_BUFFER, fd = fs.openSync(name, 'r');
  try { let count; while ((count = fs.readSync(fd, buffer)) > 0) hash.update(buffer.subarray(0, count)); }
  finally { fs.closeSync(fd); }
  return hash.digest('hex');
}

/** 证据采用临时文件+同卷 rename 发布；完成标记只在所有判据通过后出现。 */
function writeJson(name, data) {
  fs.mkdirSync(path.dirname(name), {recursive:true});
  const pending = name + '.pending-' + crypto.randomUUID();
  fs.writeFileSync(pending, JSON.stringify(data, null, 2) + '\n', {flag:'wx'});
  fs.renameSync(pending, name);
}

function git(root, args) {
  const result = spawnSync('git', ['-C', root, ...args], {encoding:'utf8', maxBuffer:64 * 1024 * 1024});
  if (result.status !== 0) throw new Error('Cannot establish Git input identity: ' + (result.stderr || result.error));
  return result.stdout;
}

/** Git 会从空子模块目录向父目录查找仓库；只有物理根相同才算该 checkout 已初始化。 */
function exactGitCheckout(root) {
  const result=spawnSync('git',['-C',root,'rev-parse','--show-toplevel'],{encoding:'utf8',maxBuffer:1024*1024});
  if(result.error) throw result.error;
  if(result.status!==0||!result.stdout.trim()) return false;
  const selected=fs.realpathSync(root), reported=fs.realpathSync(result.stdout.trim());
  return process.platform==='win32'?selected.toLowerCase()===reported.toLowerCase():selected===reported;
}

/** 保存每个已跟踪/非忽略未跟踪文件的实际字节，递归登记 gitlink 的当前保存内容。 */
function gitInputs(root, prefix, files, seen = new Set()) {
  const real = fs.realpathSync(root), stackKey=process.platform==='win32'?real.toLowerCase():real;
  if(!exactGitCheckout(root)) throw new Error('Input is not its own initialized Git checkout: '+root);
  if (seen.has(stackKey)) throw new Error('Git input recursion cycle: ' + real);
  seen.add(stackKey);
  try {
  const entries = git(root, ['ls-files','--stage','-z']).split('\0').filter(Boolean);
  const tracked = new Set();
  for (const row of entries) {
    const match = /^(\d+) ([a-f0-9]+) (\d)\t([\s\S]+)$/.exec(row);
    if (!match || match[3] !== '0') throw new Error('Unmerged Git input');
    const relative = match[4]; tracked.add(relative);
    if (/^(?:\.aoci\/|aoci(?:\.code|\.meta)?\.txt$)/.test(relative)) continue;
    const name = path.join(root, relative), key = prefix + relative;
    if (match[1] === '160000') {
      // 缺失/未初始化的 gitlink 保留 pin 与现有原始成员身份，不读取父仓 HEAD 或再次递归父仓。
      if(!fs.existsSync(name)) {
        files[key+'/@gitlink']=match[2]+':UNINITIALIZED';files[key+'/@uninitialized-tree']='MISSING';continue;
      }
      if(!fs.statSync(name).isDirectory()||!exactGitCheckout(name)) {
        if(fs.lstatSync(name).isSymbolicLink()) throw new Error('Uninitialized gitlink must not follow an external link: '+name);
        files[key+'/@gitlink']=match[2]+':UNINITIALIZED';files[key+'/@uninitialized-tree']=treeHash(name);continue;
      }
      files[key + '/@gitlink'] = match[2] + ':' + git(name, ['rev-parse','HEAD']).trim();
      gitInputs(name, key + '/', files, seen);
    } else {
      if (!fs.existsSync(name)) { files[key] = 'MISSING'; continue; }
      if (!inside(real,fs.realpathSync(name))) throw new Error('Git input escapes its repository: '+name);
      files[key] = fileHash(name);
      files[key+'/@mode'] = match[1]+':'+(fs.lstatSync(name).mode&0o777);
    }
  }
  for (const relative of git(root, ['ls-files','--others','--exclude-standard','-z']).split('\0').filter(Boolean)) {
    if (tracked.has(relative) || /^(?:\.aoci\/|aoci(?:\.code|\.meta)?\.txt$)/.test(relative)) continue;
    const name = path.join(root, relative);
    if (!inside(real,fs.realpathSync(name))) throw new Error('Untracked input escapes its repository: '+name);
    if (fs.lstatSync(name).isFile()) {
      files[prefix + relative] = fileHash(name);
      files[prefix + relative+'/@mode'] = String(fs.lstatSync(name).mode&0o777);
    }
    else throw new Error('Unknown untracked input kind: ' + name);
  }
  } finally {
    // 只检测当前递归祖先。两个合法 logical gitlink 指向同一物理 checkout 时分别登记，不误报环。
    seen.delete(stackKey);
  }
}

/** 外部 SDK/JDK/材料也按目录成员与内容核对，不以路径或 Git 状态相同代替相同输入。 */
function treeHash(root) {
  const rows = [], seen = new Set();
  const boundary=fs.realpathSync(root);
  /** 已由当前条目的 lstat 核验普通文件，直接读取，避免对同一文件再次查询元数据。 */
  function knownFileHash(name) {
    const hash=crypto.createHash('sha256'),fd=fs.openSync(name,'r');
    try {let count;while((count=fs.readSync(fd,HASH_READ_BUFFER))>0) hash.update(HASH_READ_BUFFER.subarray(0,count));}
    finally {fs.closeSync(fd);}return hash.digest('hex');
  }
  function visit(current, relative, physical) {
    // 输入在扫描期冻结；普通成员物理路径由已核验父目录派生，只有根/链接需要 realpath。
    // 链接仍保留字面身份、目标边界及祖先栈检查，不用mtime或旧摘要跳过任何内容读取。
    const status=fs.lstatSync(current),link=status.isSymbolicLink();
    const real=link?fs.realpathSync(current):physical;
    if (!inside(boundary,real)) throw new Error('External input link escapes its declared root: '+current);
    if (link) rows.push(relative+'@link:'+fs.readlinkSync(current));
    if (seen.has(real)) throw new Error('External input link cycle: ' + current);
    const stat=link?fs.statSync(current):status;
    if (stat.isDirectory()) {
      seen.add(real); rows.push(relative + '/');
      for (const entry of fs.readdirSync(current,{withFileTypes:true}).sort((a,b)=>a.name<b.name?-1:a.name>b.name?1:0)) {
        if (entry.name === '.git') continue;
        visit(path.join(current,entry.name), relative + '/' + entry.name,path.join(real,entry.name));
      }
      seen.delete(real);
    } else if (stat.isFile()) rows.push(relative + ':' + knownFileHash(real));
    else throw new Error('Unknown external input kind: ' + current);
  }
  visit(root,'',boundary); return digest(rows.join('\n'));
}

/**
 * Windows 宿主配方会通过 vswhere/vcvars 选择 PATH 以外的工具，故绑定真实 VS 材料。
 * 首版保守覆盖该实例全部 MSVC/aux/CMake 和 Windows Kits Include/Lib/bin；解析失败
 * 记录 unavailable，使 quick 回 full，完整构建仍按原门禁执行，不改工具选择或安装状态。
 */
export function windowsHostToolchainIdentity(options = {}) {
  if(process.platform!=='win32') return {state:'NOT_APPLICABLE',platform:process.platform};
  const evidence={};
  try {
    const installer=path.join(process.env['ProgramFiles(x86)']??'C:/Program Files (x86)','Microsoft Visual Studio/Installer/vswhere.exe');
    if(!fs.existsSync(installer)) throw new Error('vswhere executable unavailable');
    evidence.vswhere={path:installer,sha256:fileHash(installer)};
    const query=spawnSync(installer,['-latest','-products','*','-requires','Microsoft.VisualStudio.Component.VC.Tools.x86.x64','-format','json'],{encoding:'utf8',maxBuffer:1024*1024});
    if(query.error||query.status!==0) throw new Error('vswhere latest instance query failed');
    const instances=JSON.parse(query.stdout.replace(/^\uFEFF/,''));
    if(instances.length!==1||!instances[0].installationPath||!instances[0].installationVersion) throw new Error('vswhere instance identity incomplete');
    const selected=instances[0];evidence.instance={path:fs.realpathSync(selected.installationPath),version:selected.installationVersion};
    const knownRoots=[evidence.instance.path,'D:/Microsoft Visual Studio/18/Community','C:/Program Files/Microsoft Visual Studio/2022/Community']
      .filter(name=>fs.existsSync(path.join(name,'VC/Auxiliary/Build/vcvars64.bat'))).map(name=>fs.realpathSync(name));
    evidence.instances={};
    for(const root of [...new Set(knownRoots)].sort()) {
      const materials={};
      for(const relative of ['VC/Tools/MSVC','VC/Auxiliary/Build','Common7/IDE/CommonExtensions/Microsoft/CMake','MSBuild/Current/Bin']) {
        const directory=path.join(root,relative);if(!fs.existsSync(directory)) throw new Error('VS material missing: '+directory);
        const began=performance.now();materials[relative]=treeHash(directory);
        options.onStage?.({stage:'windowsHostMaterial',root:directory,milliseconds:performance.now()-began});
      }
      evidence.instances[root]=materials;
    }
    // compile_cpp 优先当前 PATH 的 cl；外来已激活 VC 未在以上材料中时只准 full。
    const where=path.join(process.env.SystemRoot??process.env.SYSTEMROOT??'C:/Windows','System32/where.exe');
    const active=spawnSync(where,['cl.exe'],{encoding:'utf8',maxBuffer:1024*1024});
    if(active.error) throw new Error('Cannot inspect active PATH compiler');
    const activePath=active.status===0?active.stdout.split(/\r?\n/).find(Boolean):null;
    if(activePath) {
      const resolved=fs.realpathSync(activePath);
      if(!knownRoots.some(root=>inside(fs.realpathSync(root),resolved))) throw new Error('Active PATH cl is outside the declared VS material closure');
      evidence.activeCl={path:resolved,sha256:fileHash(resolved)};
    }
    const reg=path.join(process.env.SystemRoot??process.env.SYSTEMROOT??'C:/Windows','System32/reg.exe');
    const registry=spawnSync(reg,['query','HKLM\\SOFTWARE\\Microsoft\\Windows Kits\\Installed Roots','/v','KitsRoot10','/reg:32'],{encoding:'utf8',maxBuffer:1024*1024});
    if(registry.error||registry.status!==0) throw new Error('Windows Kits root registry query failed');
    const kits=/KitsRoot10\s+REG_(?:EXPAND_)?SZ\s+(.+)/i.exec(registry.stdout)?.[1]?.trim();
    if(!kits||!path.isAbsolute(kits)) throw new Error('Windows Kits root cannot be resolved');
    evidence.windowsKits={path:fs.realpathSync(kits),materials:{}};
    for(const relative of ['Include','Lib','bin']) {
      const directory=path.join(kits,relative);if(!fs.existsSync(directory)) throw new Error('Windows Kits material missing: '+directory);
      const began=performance.now();evidence.windowsKits.materials[relative]=treeHash(directory);
      options.onStage?.({stage:'windowsSdkMaterial',root:directory,milliseconds:performance.now()-began});
    }
    return {state:'AVAILABLE',...evidence};
  } catch(error) {return {state:'UNAVAILABLE',reason:error.message,...evidence};}
}

/** 输出路径和已核实的宿主调用遥测不影响构建语义；其余环境仍以摘要参与身份。 */
function environmentFields(env) {
  const outputOnly = new Set(['TEMP','TMP','AMCL_RUN_DIR','AMCL_HOST_TEST_BUILD_DIR']);
  // 实际 quick 仅因 Codex 工具调用 nonce 变化而误回 full；只排除这个确切已知字段，
  // 不通配 CODEX_*。先统一分类键大小写，Linux 上实际语义键仍保持原来的大小写身份。
  const hostTelemetry = new Set(['CODEX_TOOL_CALL_ID']);
  return Object.fromEntries(Object.entries(env).filter(([name]) => {
    const classified = name.toUpperCase();
    return !outputOnly.has(classified) && !hostTelemetry.has(classified) && !name.startsWith('AMCL_GATE_SESSION_');
  })
    .map(([name,value])=>[process.platform==='win32'?name.toUpperCase():name,digest(value)]).sort(([a],[b])=>a.localeCompare(b)));
}
export function environmentIdentity(env) {return digest(JSON.stringify(environmentFields(env)));}

/** 每次会话起止核对。missing 也参与身份，避免删除输入被静默忽略。 */
export function snapshot(root, tools = [], options = {}) {
  const files = {};let phaseStarted=performance.now();gitInputs(root, '', files);
  options.onStage?.({stage:'sourceGit',root,milliseconds:performance.now()-phaseStarted,fileCount:Object.keys(files).length});
  // OpenAL 消费树属于被忽略的实际工程输入，Git 清单不会列出，故独立绑定完整成员字节。
  const openal='entry/src/main/cpp/openal/openal-soft', openalRoot=path.join(root,openal);
  phaseStarted=performance.now();files['@ignored-native/'+openal]=fs.existsSync(openalRoot)?treeHash(openalRoot):'MISSING';
  options.onStage?.({stage:'ignoredNative',root:openalRoot,milliseconds:performance.now()-phaseStarted});
  if (fs.existsSync(path.join(root,'build-profile.json5'))) files['@local/build-profile.json5'] = fileHash(path.join(root,'build-profile.json5'));
  const external = {}, treeDigests=new Map();
  for (const name of ['JAVA_HOME','AMCL_JVM_TEST_JAVA_HOME','AMCL_LWJGL2_INPUTS','AMCL_LWJGL2_JDK8','AMCL_NAPI_SDK_INCLUDE']) {
    const value = process.env[name]; if (value) {
      phaseStarted=performance.now();let sha256='MISSING',real=null,reused=false;
      if(fs.existsSync(value)) {
        real=fs.realpathSync(value);const key=process.platform==='win32'?real.toLowerCase():real;
        reused=treeDigests.has(key);if(!reused) treeDigests.set(key,treeHash(value));sha256=treeDigests.get(key);
      }
      external[name]=sha256;
      options.onStage?.({stage:'external',name,root:value,reused,milliseconds:performance.now()-phaseStarted});
    }
  }
  // SDK 只按已核验的消费闭包读内容；同一物理组件根的两个变量只扫描一次。
  // 内容身份与 Native 图范围资格分开：首次 full 缺图可以完成原门禁，但不授予 quick。
  const sdkQualifications={},sdkReports=new Map();
  for(const name of ['OHOS_SDK_ROOT','AMCL_GATE_SESSION_SDK_ROOT']) {
    const value=process.env[name];if(!value)continue;
    const selected=fs.existsSync(value)?fs.realpathSync(value):path.resolve(value);
    const key=process.platform==='win32'?selected.toLowerCase():selected,reused=sdkReports.has(key);
    phaseStarted=performance.now();
    if(!reused) {
      const report=(options.sdkFingerprintProvider??fingerprintSdk)(selected,{
      product:options.product??'default',mode:options.mode??'debug',abi:'arm64-v8a',nativeCompiler:'BiSheng',
      nativeBuildDir:path.join(root,'entry/.cxx',options.product??'default',options.product??'default',options.mode??'debug','arm64-v8a'),
      onStage:options.onStage
      });
      if(report.identity?.state==='UNAVAILABLE') {
        // 未支持的产品/SDK布局仍可按原 full 验证，不能把固定错误原因当成内容身份。
        // 保守读取整个bundle（包含实际HMS兄弟目录）；该后备不授予任何quick资格。
        const sibling=path.join(path.dirname(selected),'hms');
        const fallbackRoot=path.basename(selected).toLowerCase()==='openharmony'&&fs.existsSync(sibling)?path.dirname(selected):selected;
        const began=performance.now(),sha256=fs.existsSync(fallbackRoot)?treeHash(fallbackRoot):'MISSING';
        report.identity={state:'FULL_TREE_CONTENT',root:fallbackRoot,sha256,scopeReason:report.reason??report.qualification?.reason??'unavailable consumer scope'};
        report.qualification={state:'UNAVAILABLE',reason:report.identity.scopeReason};
        options.onStage?.({stage:'sdkConservativeFallback',name,root:fallbackRoot,milliseconds:performance.now()-began});
      }
      sdkReports.set(key,report);
    }
    const report=sdkReports.get(key);
    external[name]=report.identity;
    sdkQualifications[name]=report.qualification??{state:report.state,reason:report.reason??null};
    options.onStage?.({stage:'sdkIdentity',name,root:selected,reused,milliseconds:performance.now()-phaseStarted,
      state:report.state,qualification:sdkQualifications[name].state,metrics:report.metrics});
  }
  if (process.env.AMCL_SDL_TEST_REPO) {
    phaseStarted=performance.now();gitInputs(process.env.AMCL_SDL_TEST_REPO, '@sdl/', files);
    options.onStage?.({stage:'externalGit',name:'AMCL_SDL_TEST_REPO',root:process.env.AMCL_SDL_TEST_REPO,milliseconds:performance.now()-phaseStarted});
  }
  const toolNames=new Set();
  for (const entry of tools) {
    const name=typeof entry==='string'?entry:entry?.name;
    const selected=typeof entry==='string'?entry:entry?.path;
    if(typeof name!=='string'||!name||toolNames.has(name)||(selected!==null&&typeof selected!=='string')) throw new Error('Invalid/duplicate selected tool identity');
    toolNames.add(name);
    if(selected===null) {external['tool:'+name]={path:null,state:'MISSING'};continue;}
    if(!path.isAbsolute(selected)) throw new Error('Selected tool path must be absolute');
    const absolute=path.resolve(selected);
    external['tool:'+name]=fs.existsSync(absolute)?{path:absolute,realPath:fs.realpathSync(absolute),sha256:fileHash(fs.realpathSync(absolute))}:
      {path:absolute,state:'MISSING'};
  }
  phaseStarted=performance.now();external['@windows-host-toolchain']=(options.hostToolchainProvider??windowsHostToolchainIdentity)({onStage:options.onStage});
  options.onStage?.({stage:'windowsHostToolchain',milliseconds:performance.now()-phaseStarted,state:external['@windows-host-toolchain'].state});
  return {files:Object.fromEntries(Object.entries(files).sort(([a],[b])=>a.localeCompare(b))), external,
    environment:environmentIdentity(process.env),sdkQualifications};
}

/** 只接受显式档位，历史基线、未知修改和环境不触发自动full回退。 */
export function chooseProfile({requested, mode, deepAudit=false}) {
  if (!['quick','full'].includes(requested) || !['debug','release'].includes(mode)) throw new Error('Unknown validation profile or build mode');
  if(deepAudit&&requested!=='full')throw new Error('DeepAudit is an explicit full-only audit');
  return {effective:requested,reason:requested==='quick'?'explicit SDK incremental build':'explicit original full gates',changed:[]};
}

/** 在实际目录外持有独占租约，避免同一 checkout 的两个构建混写 SDK 中间物和基线。 */
export function start(args, options = {}) {
  const startedAt=new Date().toISOString();
  const root = path.resolve(args.root), stateRoot = resolveWorkspacePath('build','validation-state',{root});
  const runRoot = resolveWorkspacePath('run','build-validation',{root});
  fs.mkdirSync(stateRoot,{recursive:true}); fs.mkdirSync(runRoot,{recursive:true});
  const lock = path.join(stateRoot,'checkout.lock');
  const owner=crypto.randomUUID(), baseline=path.join(stateRoot,'last-full.json');
  const filename = path.join(runRoot,'session.json');
  fs.writeFileSync(lock, JSON.stringify({owner,pid:process.ppid,startedAt:new Date().toISOString(),runRoot}),{flag:'wx'});
  try {
    const deepAudit=!!args['deep-audit'];
    const choice=chooseProfile({requested:args.profile,mode:args.mode,deepAudit});
    const tools = JSON.parse(args.tools ?? '[]');
    let current=null,snapshotDurationMs=0;const snapshotStages=[];let unknown=[];
    if(deepAudit) {
      const catalog=readJson(path.join(root,'config/build-gates.json')),scanStarted=performance.now();
      current=(options.snapshotProvider??snapshot)(root,tools,{...options,product:args.product,mode:args.mode,onStage:row=>{
        snapshotStages.push(row);fs.appendFileSync(path.join(runRoot,'snapshot-progress.jsonl'),JSON.stringify({...row,completedAt:new Date().toISOString()})+'\n');options.onStage?.(row);
      }});snapshotDurationMs=performance.now()-scanStarted;
      unknown=findUnregisteredHapScripts({root,catalog});
    }
    // 普通quick不读取或改写旧full记录；full仅记录本轮尚未完成，不据旧记录选档。
    if (choice.effective === 'full') writeJson(baseline,{state:'RUNNING',profile:'full',runRoot});
    const session = {schema:1,root,stateRoot,runRoot,lock,owner,tools,product:args.product,mode:args.mode,
      requested:args.profile,profile:choice.effective,reason:choice.reason,changed:choice.changed,fresh:!!args.fresh,
      deepAudit,deepAuditState:deepAudit?'RUNNING':'NOT_RUN',fullQualified:false,
      notRun:args.profile==='quick'?['full-regression-suite','sdk-arkts-unit-tests','standalone-tu-audit','deep-input-audit','full-provenance-audit']:deepAudit?[]:['deep-input-audit'],
      startedAt,snapshotDurationMs,snapshotStages,...(deepAudit?{environmentInputs:environmentFields(process.env),snapshot:current,unknownHapScripts:unknown}:{}),state:'RUNNING',events:[]};
    writeJson(filename,session);
    const context={filename,runRoot,deepAudit,cacheRoot:resolveWorkspacePath('build','gate-results',{root}),...choice};
    if(args['context-report']) {
      const report=assertExternalOutputPath(path.resolve(args['context-report']),{root});
      if(fs.existsSync(report)) throw new Error('Context report must be a new external file');
      fs.mkdirSync(path.dirname(report),{recursive:true});
      fs.writeFileSync(report,JSON.stringify(context)+'\n',{flag:'wx'});
    }
    return context;
  } catch (error) {
    const failed={schema:1,state:'FAIL',profile:args.profile,fullQualified:false,product:args.product,mode:args.mode,runRoot,error:error.message,completedAt:new Date().toISOString()};
    if(fs.existsSync(filename)) writeJson(filename,{...readJson(filename),...failed});
    if(args.profile==='full')writeJson(baseline,failed);fs.unlinkSync(lock);throw error;
  }
}

/** 普通会话不调度catalog；额外DeepAudit仅允许受信纯静态缓存，不延期任何行为门。 */
export function decision(session, gate, argv) {
  if(!session.deepAudit)return {action:'RUN',reason:'explicitly selected command; no catalog planning in ordinary builds'};
  if (!gate) return {action:'RUN',reason:'unregistered command runs conservatively'};
  const artifact = argv.some(arg => /(?:--hap|--require-artifact|--verify-provenance|--write-provenance|--verify-signature)/.test(arg));
  if (!artifact && gate.kind === 'static' && gate.cachePolicy === 'pass' && gate.deterministic === true && Array.isArray(gate.environmentKeys)) return {action:'CACHE',reason:'trusted deterministic input closure'};
  return {action:'RUN',reason:'current invocation required'};
}

function plan(args) {
  const session = readJson(args.session), argv = JSON.parse(args.argv);
  const script = argv.find(arg=>/\.(?:mjs|py)$/.test(arg));
  const relative = script ? normalized(path.relative(session.root,path.resolve(session.root,script))) : '';
  if(!session.deepAudit)return {action:'RUN',reason:'ordinary build executes only the selected branch',gateId:script?path.basename(script).replace(/\.(?:mjs|py)$/,''):'native-command'};
  const catalog = readJson(path.join(session.root,'config/build-gates.json'));
  const gate = catalog.gates.find(row=>row.script === relative);
  const selected = decision(session,gate,argv);
  if (selected.action !== 'CACHE') return {...selected,gateId:gate?.id ?? relative};
  const spec = {schema:1,gateId:gate.id,kind:gate.kind,deterministic:true,cachePolicy:'pass',profile:session.profile,cwd:session.root,
    command:{executable:args.executable,args:argv},inputs:gate.inputs,tools:[],config:{product:session.product,mode:session.mode},
    environment:Object.fromEntries(gate.environmentKeys.filter(name=>Object.hasOwn(process.env,name)).map(name=>[name,process.env[name]])),
    outputs:[],expectation:gate.expectation ?? {allowEmptyOutput:false}};
  for(const name of gate.outputOnlyEnvironment ?? []) {
    if(!['AMCL_RUN_DIR','TEMP','TMP'].includes(name)) throw new Error('Unsupported output-only gate environment');
    spec.environment[name]='{runRoot}'+(name==='AMCL_RUN_DIR'?'':'/temp');
  }
  const specPath = path.join(session.runRoot,crypto.randomUUID()+'.spec.json'); writeJson(specPath,spec);
  return {...selected,gateId:gate.id,specPath,runRoot:path.join(session.runRoot,'gate-'+crypto.randomUUID()),
    cacheRoot:resolveWorkspacePath('build','gate-results',{root:session.root}),report:path.join(session.runRoot,crypto.randomUUID()+'.cache.json')};
}

export function event(args) {
  const session = readJson(args.session), row=JSON.parse(args.event);
  if(session.state!=='RUNNING') throw new Error('Cannot append events to a completed session');
  if(typeof row.id!=='string' || !['PASS','FAIL','REUSED_PASS','DEFERRED','BLOCKED','ABORTED','RUNNING','NOT_APPLICABLE'].includes(row.state) ||
    !Number.isFinite(row.durationMs)||row.durationMs<0||!Number.isInteger(row.exitCode)||!Number.isFinite(Date.parse(row.completedAt))) throw new Error('Invalid gate event');
  if(['PASS','REUSED_PASS'].includes(row.state)&&row.exitCode!==0) throw new Error('Successful event requires zero exit');
  if(row.argv!==undefined&&(!Array.isArray(row.argv)||row.argv.some(value=>typeof value!=='string'))) throw new Error('Invalid event argv');
  const catalog=session.deepAudit?readJson(path.join(session.root,'config/build-gates.json')):null;
  const declared=catalog?.gates.find(gate=>gate.id===row.id)?.dependsOn??[];
  const previous=session.events.at(-1), resolved=declared.map(id=>[...session.events].reverse().find(entry=>entry.id===id));
  const invocationId=crypto.randomUUID(), previousEventId=previous?.invocationId??null;
  const enriched={...row,sequence:session.events.length+1,invocationId,previousEventId,
    dependsOn:[...new Set([previousEventId,...resolved.map(entry=>entry?.invocationId)].filter(Boolean))],
    declaredDependencies:declared,unresolvedDependencies:declared.filter((id,index)=>!resolved[index]),
    executable:row.executable??null,argv:row.argv??[],phase:row.phase??'unclassified',
    startedAtUTC:row.startedAtUTC??row.completedAt,completedAtUTC:row.completedAtUTC??row.completedAt};
  session.events.push(enriched);writeJson(args.session,session);
}

/** 收口检查不能由两份任意文件或空事件账本获得 full 资格；当前 HAP 与签名收据逐字绑定。 */
function completionEvidence(session,names) {
  if(!Array.isArray(names)||new Set(names).size!==names.length) throw new Error('Distinct artifact paths required');
  const hapNames=names.filter(name=>typeof name==='string'&&name.endsWith('.hap'));
  const provenanceNames=names.filter(name=>typeof name==='string'&&/provenance[^/\\]*\.json$/.test(name));
  if(hapNames.length!==1||provenanceNames.length!==1) throw new Error('Exactly one HAP and one provenance required');
  const hapSha256=fileHash(hapNames[0]), proof=readJson(provenanceNames[0]);
  if((proof.hapSha256??proof.artifacts?.hap?.sha256)!==hapSha256) throw new Error('Provenance is not bound to the current HAP');
  if((proof.product??proof.variant?.product)!==session.product || (proof.mode??proof.variant?.buildMode)!==session.mode) throw new Error('Provenance product/mode differs from session');
  const signature=proof.signature??proof.signatureVerification;
  if(!signature||!['signed','unsigned'].includes(signature.artifactKind)||
    signature.result!==(signature.artifactKind==='signed'?'valid-signature':'no-valid-signature')) throw new Error('Current signature audit evidence required');
  const audit=proof.purpose==='desktop-system-gl-build'?'check-desktop-build-contract':
    proof.purpose==='diagnostic-build-contract'?'check-diagnostics-contract':'check-mg-build-contract';
  return {artifacts:names.map(name=>({path:name,sha256:fileHash(name)})),audit,hap:hapNames[0],provenance:provenanceNames[0]};
}

/** quick只绑定本轮SDK包与轻量收据；它显式不授予full/发布资格，也不伪造重型provenance。 */
function quickCompletionEvidence(session,names) {
  if(!Array.isArray(names)||new Set(names).size!==names.length)throw new Error('Distinct quick artifact paths required');
  const haps=names.filter(name=>typeof name==='string'&&name.endsWith('.hap'));
  const receipts=names.filter(name=>typeof name==='string'&&/quick-build-receipt-(?:signed|unsigned)\.json$/.test(name));
  if(haps.length!==1||receipts.length!==1||names.length!==2)throw new Error('Quick requires exactly one HAP and one quick receipt');
  const hap=path.resolve(haps[0]),receipt=path.resolve(receipts[0]),proof=readJson(receipt),hapSha256=fileHash(hap),hapBytes=fs.statSync(hap).size;
  const same=(left,right)=>process.platform==='win32'?left.toLowerCase()===right.toLowerCase():left===right;
  if(proof.schema!==1||proof.purpose!=='quick-development-build'||proof.validationProfile!=='quick'||proof.fullQualified!==false||
    proof.product!==session.product||proof.mode!==session.mode||proof.hapSha256!==hapSha256||proof.hapBytes!==hapBytes||
    typeof proof.hapPath!=='string'||!same(path.resolve(session.root,proof.hapPath),hap))throw new Error('Quick receipt does not bind this SDK HAP/profile');
  const signature=proof.signatureVerification,kind=/quick-build-receipt-(signed|unsigned)\.json$/.exec(receipt)[1];
  if(signature?.artifactKind!==kind||signature.result!==(kind==='signed'?'valid-signature':'no-valid-signature'))throw new Error('Quick receipt lacks current signature verification');
  return {hap,receipt,artifacts:[{path:hap,sha256:hapSha256},{path:receipt,sha256:fileHash(receipt)}]};
}

function validateQuickCoverage(session,evidence) {
  if(!Array.isArray(session.events)||session.events.some(row=>row.state!=='PASS'||row.exitCode!==0))throw new Error('Quick selected command did not actually pass');
  const assemble=session.events.findIndex(row=>row.id==='sdk-assemble-hap'&&row.state==='PASS');
  const checked=session.events.findIndex(row=>row.id==='check-quick-hap'&&row.state==='PASS');
  if(assemble<0||checked<=assemble)throw new Error('Quick requires current SDK assembly followed by its light HAP check');
  const argv=session.events[checked].argv??[];
  for(const [flag,expected]of [['--hap',evidence.hap],['--receipt',evidence.receipt]]) {
    const index=argv.indexOf(flag),selected=index>=0&&argv[index+1]?path.resolve(session.root,argv[index+1]):null;
    if(!selected||(process.platform==='win32'?selected.toLowerCase()!==expected.toLowerCase():selected!==expected))throw new Error('Quick HAP check event references another artifact');
  }
}

/** 已知的源构建事实必须真实 PASS；缓存资格不能代替单测日志、组包、TU 和当前包审核。 */
function validateCoverage(session,audit,artifacts) {
  if(!Array.isArray(session.events)||session.events.length===0) throw new Error('Build coverage is empty');
  const catalog=session.deepAudit?readJson(path.join(session.root,'config/build-gates.json')):null;
  const byId=new Map((catalog?.gates??[]).map(row=>[row.id,row]));
  for(const row of session.events) {
    if(!['PASS','REUSED_PASS','DEFERRED'].includes(row.state)||row.exitCode!==0) throw new Error('Incomplete or failed gate cannot publish build PASS: '+row.id);
    if(row.unresolvedDependencies?.length) throw new Error('Explicit gate dependencies were not observed: '+row.id);
    if(row.state==='REUSED_PASS') {
      const gate=byId.get(row.id);
      if(gate?.kind!=='static'||gate.cachePolicy!=='pass'||gate.deterministic!==true) throw new Error('Untrusted reused gate: '+row.id);
    }
    if(row.state==='DEFERRED' && (session.profile==='full'||(row.id!=='sdk-clean'&&decision(session,byId.get(row.id),[]).action!=='DEFERRED'))) {
      throw new Error('Invalid deferred coverage: '+row.id);
    }
  }
  const required=['sdk-arkts-unit-command','check-hvigor-test-log','sdk-assemble-hap','check-product-tu-syntax','check-product-contract','check-diagnostics-contract'];
  if(session.profile==='full') required.push('sdk-clean');
  for(const id of required) if(!session.events.some(row=>row.id===id&&row.state==='PASS'&&row.exitCode===0)) throw new Error('Required current gate missing: '+id);
  const minimum=audit==='check-diagnostics-contract'?3:2;
  if(session.events.filter(row=>row.id===audit&&row.state==='PASS'&&row.exitCode===0).length<minimum) throw new Error('Provenance write and independent verify events required: '+audit);
  const write=session.events.findIndex(row=>row.id===audit&&row.state==='PASS'&&row.argv?.includes('--write-provenance'));
  const verify=session.events.findIndex(row=>row.id===audit&&row.state==='PASS'&&row.argv?.includes('--verify-provenance'));
  if(write<0||verify<=write) throw new Error('Provenance write must precede its independent verify event');
  const matches=(argv,flag,expected)=>{
    const position=argv.indexOf(flag);if(position<0||!argv[position+1]) return false;
    const selected=path.resolve(session.root,argv[position+1]), wanted=path.resolve(expected);
    return process.platform==='win32'?selected.toLowerCase()===wanted.toLowerCase():selected===wanted;
  };
  if(!matches(session.events[write].argv,'--hap',artifacts.hap)||!matches(session.events[write].argv,'--write-provenance',artifacts.provenance)||
    !matches(session.events[verify].argv,'--hap',artifacts.hap)||!matches(session.events[verify].argv,'--verify-provenance',artifacts.provenance)) {
    throw new Error('Provenance write/verify must reference the current HAP and provenance paths');
  }
}

/** 顶层按显式档位收口；只有额外DeepAudit执行输入双扫，普通构建不调用快照provider。 */
export function finish(args, options = {}) {
  const session = readJson(args.session); let failure = null;
  const lease=readJson(session.lock);
  if(!session.owner||lease.owner!==session.owner||lease.runRoot!==session.runRoot) throw new Error('Session lease ownership mismatch');
  if(session.state!=='RUNNING') throw new Error('Build session already completed');
  try {
    session.state = args.success ? 'PASS' : 'FAIL';
    if (args.success) {
      if(session.deepAudit) {
      const finalSnapshotStages=[], after = (options.snapshotProvider??snapshot)(session.root,session.tools,{...options,product:session.product,mode:session.mode,onStage:row=>{
        finalSnapshotStages.push(row);fs.appendFileSync(path.join(session.runRoot,'final-snapshot-progress.jsonl'),JSON.stringify({...row,completedAt:new Date().toISOString()})+'\n');
        options.onStage?.(row);
      }});
      session.finalSnapshotStages=finalSnapshotStages;
      session.finalSdkQualifications=after.sdkQualifications;
      const afterEnvironment=environmentFields(process.env), internal=new Set(['AMCL_DIAGNOSTICS','AMCL_MOBILEGL_VALIDATION','DEVECO_SDK_HOME','AMCL_SOURCE_READ_TOKEN','AMCL_EXPECTED_SOURCE_REPOSITORY']);
      const environmentChanged=[...new Set([...Object.keys(session.environmentInputs??{}),...Object.keys(afterEnvironment)])]
        .filter(name=>session.environmentInputs?.[name]!==afterEnvironment[name]);
      if(environmentChanged.some(name=>!internal.has(name))) throw new Error('Build environment drift outside internal assignments');
      session.internalEnvironmentChanges=environmentChanged;
      // 签发基线始终保留初始化环境身份；后置已知配置赋值不能冒充新的起始资格。
      after.environment=session.snapshot.environment;
      // Ninja 图可由本轮真实 full 首次生成；仅资格变化不伪装成SDK内容变化。
      // 若起始缺图，保存的起始 qualification 仍阻止下次 quick 借用该轮基线。
      const savedIdentity=value=>({files:value.files,external:value.external,environment:value.environment});
      if (JSON.stringify(savedIdentity(after)) !== JSON.stringify(savedIdentity(session.snapshot))) throw new Error('Build input drift: final saved inputs differ from start');
      session.deepAuditState='PASS';
      }
      if(session.profile==='quick') {
        const evidence=quickCompletionEvidence(session,JSON.parse(args.artifacts??'[]'));
        validateQuickCoverage(session,evidence);session.artifacts=evidence.artifacts;
      } else {
        const evidence=completionEvidence(session,JSON.parse(args.artifacts??'[]'));
        validateCoverage(session,evidence.audit,evidence);session.artifacts=evidence.artifacts;
      }
    }
  } catch (error) {session.state='FAIL';if(session.deepAudit)session.deepAuditState='FAIL';session.error=error.message;failure=error;}
  finally {
    session.completedAt=new Date().toISOString();
    session.durationMs=Date.parse(session.completedAt)-Date.parse(session.startedAt);
    session.fullQualified=session.state==='PASS'&&session.profile==='full';
    if(session.deepAudit&&session.state!=='PASS')session.deepAuditState='FAIL';
    session.coverage={executed:session.events.filter(row=>row.state==='PASS').length,reused:session.events.filter(row=>row.state==='REUSED_PASS').length,
      deferred:session.events.filter(row=>row.state==='DEFERRED').length,failed:session.events.filter(row=>row.state==='FAIL').length,notRun:session.notRun?.length??0};
    writeJson(args.session,session);
    if (session.profile === 'full') writeJson(path.join(session.stateRoot,'last-full.json'),session);
    // 出错也只能释放自己签发的租约；不得删除后续/其他会话的锁。
    if(fs.existsSync(session.lock)&&readJson(session.lock).owner===session.owner) fs.unlinkSync(session.lock);
  }
  if (failure) throw failure;
  return {state:session.state,profile:session.profile,fullQualified:session.fullQualified,deepAudit:session.deepAudit,deepAuditState:session.deepAuditState,notRun:session.notRun,coverage:session.coverage,report:args.session};
}

/** 严格 CLI 只服务构建包装器；未知/重复参数直接失败，避免错参数静默选空任务。 */
function main() {
  const [command,...argv]=process.argv.slice(2), args={};
  const allowed={start:['root','profile','product','mode','tools','fresh','deep-audit','context-report'],plan:['session','executable','argv'],event:['session','event'],finish:['session','success','artifacts']};
  if(!Object.hasOwn(allowed,command)) throw new Error('Unknown session operation');
  for(let index=0;index<argv.length;index++) {
    const name=argv[index]; if(!name.startsWith('--') || Object.hasOwn(args,name.slice(2))) throw new Error('Invalid/duplicate option: '+name);
    if(!allowed[command].includes(name.slice(2))) throw new Error('Unknown option for '+command+': '+name);
    if(['--fresh','--success','--deep-audit'].includes(name)) args[name.slice(2)]=true;
    else {if(!argv[index+1] || argv[index+1].startsWith('--')) throw new Error('Missing option value');args[name.slice(2)]=argv[++index];}
  }
  const operations={start,plan,event,finish}; if(!operations[command]) throw new Error('Unknown session operation');
  if(args.session) assertExternalOutputPath(args.session,{root:path.resolve(readJson(args.session).root)});
  // stderr 专门提供前台阶段进度；stdout 仍只有原有机器JSON，JS夹具不经过此CLI回调。
  const result=operations[command](args,{onStage:row=>process.stderr.write('[identity] '+row.stage+' '+(row.name??path.basename(row.root??''))+' '+Math.round(row.milliseconds)+'ms\n')});
  if(result) console.log(JSON.stringify(result));
}
if(process.argv[1] && path.resolve(process.argv[1])===self) {
  try {main();} catch(error) {console.error('Build validation rejected: '+error.message);process.exitCode=1;}
}
