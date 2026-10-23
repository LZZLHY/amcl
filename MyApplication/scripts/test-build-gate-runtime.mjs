/**
 * 用真实 PowerShell 7、Node 和 Python 子进程验证构建计时包装器。会话使用外置轻量
 * 替身，缓存分支调用生产缓存 CLI；不进入 Hvigor、SDK 构建、签名或设备通道。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {assertExternalOutputPath, resolveWorkspacePath} from './lib/workspace-paths.mjs';

const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const argumentsList = process.argv.slice(2);
const option = name => argumentsList.includes(name) ? argumentsList[argumentsList.indexOf(name) + 1] : null;
let output;
if (option('--out')) {
  output = assertExternalOutputPath(path.resolve(option('--out')));
  if (fs.existsSync(output)) throw new Error('Runtime fixture output must be new');
  fs.mkdirSync(output, {recursive:true});
} else {
  const parent = resolveWorkspacePath('run','gate-runtime-regression');
  fs.mkdirSync(parent,{recursive:true});
  output = fs.mkdtempSync(path.join(parent,'cases-'));
}
// 正常构建与 CI 可无参运行；只接受真实可执行的 PS7，缺工具直接失败。
const powershellCandidates = option('--powershell') ? [option('--powershell')] : [
  process.env.AMCL_POWERSHELL, 'pwsh', ...(process.platform === 'win32' ? [
    path.join(os.homedir(),'.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe'),
  ] : []),
].filter(Boolean);
const powershell = powershellCandidates.find(candidate=>{
  const probe=spawnSync(candidate,['-NoLogo','-NoProfile','-NonInteractive','-Command','$PSVersionTable.PSVersion.Major'],{encoding:'utf8',timeout:10000});
  return !probe.error && probe.status===0 && Number(probe.stdout.trim())>=7;
});
if(!powershell) throw new Error('A working PowerShell 7 is required; runtime regression cannot be skipped');
console.log('Build runtime fixture output: '+output);
const runtime = path.join(project, 'scripts/lib/build-gate-runtime.ps1');
const cases = [];
const ps = value => "'" + String(value).replaceAll("'", "''") + "'";
const psArray = values => '@(' + values.map(ps).join(',') + ')';

const sessionSource = `import fs from 'node:fs'; import path from 'node:path';
const [operation,...tokens]=process.argv.slice(2), args={};
for(let i=0;i<tokens.length;i++){const flag=tokens[i].slice(2);args[flag]=['fresh','success','deep-audit'].includes(flag)?true:tokens[++i];}
const base=process.env.AMCL_RUNTIME_FIXTURE, filename=path.join(base,'session.json'), lock=path.join(base,'session.lock');
const load=()=>JSON.parse(fs.readFileSync(filename,'utf8'));
const save=value=>fs.writeFileSync(filename,JSON.stringify(value,null,2));
if(operation==='start'){
 const value={state:'RUNNING',events:[],plans:[],finishCalls:0,root:args.root,tools:JSON.parse(args.tools),deepAudit:!!args['deep-audit'],startedAt:new Date().toISOString()};
 save(value);fs.writeFileSync(lock,'owned',{flag:'wx'});
 const context={filename,effective:args.profile,deepAudit:!!args['deep-audit'],reason:'fixture session'};
 fs.writeFileSync(args['context-report'],JSON.stringify(context),{flag:'wx'});
 console.log(process.env.AMCL_RUNTIME_BAD_START==='1'?'invalid start stdout':JSON.stringify(context));
}else if(operation==='plan'){
 const value=load(), argv=JSON.parse(args.argv);value.plans.push({executable:args.executable,argv});save(value);
 const action=process.env.AMCL_RUNTIME_ACTION??'RUN', plan={action,gateId:'fixture-gate',reason:'fixture policy'};
 if(action==='CACHE'){
  const spec={schema:1,gateId:'fixture-gate',kind:'static',profile:'quick',cwd:value.root,
   command:{executable:args.executable,args:argv},inputs:{files:['gate.mjs']},tools:[],config:{},environment:{},outputs:[],
   expectation:{allowEmptyOutput:false,stdoutIncludes:['"marker":"native-json"']}};
  Object.assign(plan,{specPath:path.join(base,'spec-'+value.plans.length+'.json'),cacheRoot:path.join(base,'cache'),
   runRoot:path.join(base,'cache-runs',String(value.plans.length)),report:path.join(base,'cache-report-'+value.plans.length+'.json')});
  fs.writeFileSync(plan.specPath,JSON.stringify(spec));
 }
 console.log(JSON.stringify(plan));
}else if(operation==='event'){
 if(process.env.AMCL_RUNTIME_EVENT_FAIL==='1'){console.error('fixture evidence writer rejected');process.exit(23);}
 const value=load();value.events.push(JSON.parse(args.event));save(value);
}else if(operation==='finish'){
 const value=load();value.state=args.success?'PASS':'FAIL';value.finishCalls++;value.completedAt=new Date().toISOString();
 value.durationMs=Date.parse(value.completedAt)-Date.parse(value.startedAt);save(value);fs.unlinkSync(lock);
 console.log(JSON.stringify({state:value.state,report:filename}));
}else throw new Error('Unexpected mock session operation');
`;

/** 每个场景拥有独立会话及源码，最终证据保留在 --out 中，不借真实应用工作树。 */
function fixture(name, body, {action='RUN', extraEnv={}, invalidCache=false}={}) {
  // 缓存/旧计划包装器仅在显式DeepAudit分支验证；普通会话应完全跳过逐门plan子进程。
  if(action!=='RUN')body=body.replaceAll(initialize,initialize+' -DeepAudit');
  const base = path.join(output,name), root = path.join(base,'source'), lib = path.join(root,'scripts/lib');
  fs.mkdirSync(lib,{recursive:true}); fs.mkdirSync(path.join(root,'config'));
  fs.writeFileSync(path.join(lib,'build-gate-session.mjs'),sessionSource);
  for(const file of ['workspace-paths.mjs','build-gate-cache.mjs']) fs.copyFileSync(path.join(project,'scripts/lib',file),path.join(lib,file));
  if(invalidCache) fs.writeFileSync(path.join(lib,'build-gate-cache.mjs'),
    `import fs from 'node:fs';const a=process.argv.slice(2);const p=a[a.indexOf('--report')+1];fs.writeFileSync(p,JSON.stringify({state:'CORRUPT',exitCode:0}));console.log('{"marker":"native-json"}');`);
  fs.writeFileSync(path.join(root,'config/build-gates.json'),JSON.stringify({schema:1,gates:[
    {id:'fixture-gate',script:'gate.mjs',kind:'static',deterministic:true,cachePolicy:'pass'}]}));
  fs.writeFileSync(path.join(root,'gate.mjs'),`import fs from 'node:fs';
if(process.env.AMCL_RUNTIME_CHILD_MARKER)fs.writeFileSync(process.env.AMCL_RUNTIME_CHILD_MARKER,'executed');
console.log(JSON.stringify({marker:'native-json',argv:process.argv.slice(2)}));
process.exitCode=Number(process.env.AMCL_RUNTIME_CHILD_EXIT??0);
`);
  fs.writeFileSync(path.join(root,'gate.py'),`import json,sys\nprint(json.dumps({'marker':'python-json','noBytecode':sys.flags.dont_write_bytecode,'argv':sys.argv[1:]}))\n`);
  const driver = path.join(base,'driver.ps1');
  fs.writeFileSync(driver,`$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -lt 7){throw 'PowerShell 7 is required'}
. ${ps(runtime)}
$fixtureRoot=${ps(root)}
$script:AmclGatePhase='source-fixture'
${body}
`,{flag:'wx'});
  const result = spawnSync(powershell,['-NoLogo','-NoProfile','-NonInteractive','-File',driver],{
    cwd:root,encoding:'utf8',timeout:30000,maxBuffer:8*1024*1024,
    env:{...process.env,AMCL_RUN_DIR:path.join(base,'run'),AMCL_RUNTIME_FIXTURE:base,AMCL_RUNTIME_ACTION:action,
      AMCL_RUNTIME_CHILD_MARKER:path.join(base,'child-executed.txt'),...extraEnv},
  });
  fs.writeFileSync(path.join(base,'stdout.log'),result.stdout??'');fs.writeFileSync(path.join(base,'stderr.log'),result.stderr??'');
  fs.writeFileSync(path.join(base,'process.json'),JSON.stringify({status:result.status,signal:result.signal,error:result.error?.message},null,2));
  assert.equal(result.error,undefined,result.error?.message);assert.equal(result.signal,null,result.stderr);
  const session=fs.existsSync(path.join(base,'session.json'))?JSON.parse(fs.readFileSync(path.join(base,'session.json'),'utf8')):null;
  return {base,root,result,session,receipt:result.status===0?JSON.parse(result.stdout):null};
}

const initialize = "Initialize-AmclValidation -Root $fixtureRoot -Profile full -Product default -Mode debug";
const complete = "Complete-AmclValidation -Success -Artifacts @('fixture.hap','fixture.provenance')";

async function check(name,run) {
  const startedAt=new Date().toISOString();
  try {await run();cases.push({name,state:'PASS',startedAt,completedAt:new Date().toISOString()});console.log('PASS build runtime: '+name);}
  catch(error){cases.push({name,state:'FAIL',startedAt,completedAt:new Date().toISOString(),error:error.stack});throw error;}
}

try {
  await check('原生 JSON 不被会话初始化、计时或完成 JSON 污染，事件保留完整元数据',()=>{
    const item=fixture('stdout-json',`${initialize}
$captured=Invoke-AmclNode (Join-Path $fixtureRoot 'gate.mjs') --product default
$nativeCode=$LASTEXITCODE
${complete}
if($nativeCode -ne 0){throw 'Unexpected native failure'}
[Console]::Out.WriteLine(($captured -join "\n"))`);
    assert.equal(item.result.status,0,item.result.stderr);assert.equal(item.receipt.marker,'native-json');
    assert.deepEqual(item.receipt.argv,['--product','default']);assert.equal(item.session.events.length,1);
    const event=item.session.events[0];assert.equal(event.state,'PASS');assert.equal(event.phase,'source-fixture');
    assert.equal(path.resolve(event.executable),path.resolve(process.execPath));assert.deepEqual(event.argv,[path.join(item.root,'gate.mjs'),'--product','default']);
    assert.ok(Number.isFinite(Date.parse(event.startedAtUTC)));assert.ok(Number.isFinite(Date.parse(event.completedAtUTC)));
    assert.ok(Date.parse(event.completedAtUTC)>=Date.parse(event.startedAtUTC));assert.ok(event.durationMs>0);
    assert.equal(item.session.state,'PASS');assert.equal(item.session.finishCalls,1);assert.ok(!fs.existsSync(path.join(item.base,'session.lock')));
    assert.deepEqual(item.session.tools.map(tool=>tool.name),['node']);assert.equal(item.session.deepAudit,false);assert.equal(item.session.plans.length,0);
    assert.ok(item.session.tools.every(tool=>tool.path===null||path.isAbsolute(tool.path)));
  });
  await check('quick初始化不需要Python/Git/VS或catalog，也不为选中命令spawn plan',()=>{
    const nodeOnlyPath=path.dirname(process.execPath);
    const item=fixture('quick-node-only',`$env:PATH=${ps(nodeOnlyPath)}
Remove-Item -LiteralPath (Join-Path $fixtureRoot 'config/build-gates.json')
Initialize-AmclValidation -Root $fixtureRoot -Profile quick -Product default -Mode debug
$captured=Invoke-AmclNode (Join-Path $fixtureRoot 'gate.mjs') --quick
${complete}
[Console]::Out.WriteLine(($captured -join "\n"))`);
    assert.equal(item.result.status,0,item.result.stderr);assert.equal(item.receipt.marker,'native-json');
    assert.deepEqual(item.session.tools.map(tool=>tool.name),['node']);assert.equal(item.session.deepAudit,false);assert.equal(item.session.plans.length,0);
    assert.equal(item.session.events.length,1);assert.equal(item.session.events[0].id,'gate');assert.equal(item.session.events[0].state,'PASS');
  });
  await check('DeepAudit只有full显式选择时才发现Python及全部宿主工具',()=>{
    const item=fixture('deep-tools',`${initialize} -DeepAudit
Complete-AmclValidation
[Console]::Out.WriteLine('{"closed":true}')`);
    assert.equal(item.result.status,0,item.result.stderr);assert.equal(item.session.deepAudit,true);
    assert.deepEqual(item.session.tools.map(tool=>tool.name),['node','python','git','cmake','ninja','clang','clang++','gcc','g++','java','javac','hvigorw']);
  });
  await check('quick与DeepAudit冲突明确拒绝，不自动改为full',()=>{
    const item=fixture('quick-deep-reject',`$caught=$false
try{Initialize-AmclValidation -Root $fixtureRoot -Profile quick -Product default -Mode debug -DeepAudit}catch{$caught=$true}
[Console]::Out.WriteLine((@{caught=$caught}|ConvertTo-Json -Compress))`);
    assert.equal(item.result.status,0,item.result.stderr);assert.equal(item.receipt.caught,true);assert.equal(item.session,null);
  });
  await check('原生非零退出码不被成功事件写入覆盖',()=>{
    const item=fixture('native-failure',`${initialize}
$captured=Invoke-AmclNode (Join-Path $fixtureRoot 'gate.mjs')
$nativeCode=$LASTEXITCODE
Complete-AmclValidation
[Console]::Out.WriteLine((@{nativeCode=$nativeCode;captured=$captured}|ConvertTo-Json -Compress))`,{extraEnv:{AMCL_RUNTIME_CHILD_EXIT:'17'}});
    assert.equal(item.result.status,0,item.result.stderr);assert.equal(item.receipt.nativeCode,17);
    assert.equal(item.session.events[0].exitCode,17);assert.equal(item.session.events[0].state,'FAIL');assert.equal(item.session.state,'FAIL');
  });
  await check('array/splat 参数的空字符串、引号、空格、Unicode及原生选项顺序不变',()=>{
    const values=['--flag','value with spaces','quote"inside',"apostrophe'inside",'-Dname=a;b','中文',''];
    const item=fixture('splat-argv',`${initialize}
$gateArguments=@((Join-Path $fixtureRoot 'gate.mjs'))+${psArray(values)}
$captured=Invoke-AmclNode @gateArguments
${complete}
[Console]::Out.WriteLine(($captured -join "\n"))`);
    assert.equal(item.result.status,0,item.result.stderr);assert.deepEqual(item.receipt.argv,values);
    assert.deepEqual(item.session.events[0].argv,[path.join(item.root,'gate.mjs'),...values]);
  });
  await check('真实 Python -B 未被 PowerShell 包装器吞掉',()=>{
    const item=fixture('python-b',`${initialize}
$gateArguments=@('-B',(Join-Path $fixtureRoot 'gate.py'),'value with spaces','--fixture')
$captured=Invoke-AmclPython @gateArguments
${complete}
[Console]::Out.WriteLine(($captured -join "\n"))`);
    assert.equal(item.result.status,0,item.result.stderr);assert.equal(item.receipt.noBytecode,1);
    assert.deepEqual(item.receipt.argv,['value with spaces','--fixture']);assert.equal(item.session.events[0].argv[0],'-B');
  });
  await check('原生命令抛异常时 finally 仍记录失败并收口会话',()=>{
    const item=fixture('command-exception',`${initialize}
$caught=$false
try{Invoke-AmclGateCommand -Executable (Join-Path $fixtureRoot 'missing-native-executable') -GateArguments @('fixture')}
catch{$caught=$true}finally{Complete-AmclValidation}
[Console]::Out.WriteLine((@{caught=$caught}|ConvertTo-Json -Compress))`);
    assert.equal(item.result.status,0,item.result.stderr);assert.equal(item.receipt.caught,true);
    assert.equal(item.session.events[0].state,'FAIL');assert.notEqual(item.session.events[0].exitCode,0);
    assert.equal(item.session.state,'FAIL');assert.ok(!fs.existsSync(path.join(item.base,'session.lock')));
  });
  await check('DEFERRED 不执行子进程也不制造 PASS',()=>{
    const item=fixture('deferred',`${initialize}
$captured=@(Invoke-AmclNode (Join-Path $fixtureRoot 'gate.mjs'))
$nativeCode=$LASTEXITCODE
Complete-AmclValidation
[Console]::Out.WriteLine((@{nativeCode=$nativeCode;capturedCount=$captured.Count}|ConvertTo-Json -Compress))`,{action:'DEFERRED'});
    assert.equal(item.result.status,0,item.result.stderr);assert.equal(item.receipt.capturedCount,0);assert.equal(item.receipt.nativeCode,0);
    assert.equal(item.session.events[0].state,'DEFERRED');assert.equal(item.session.events[0].durationMs,0);
    assert.ok(!fs.existsSync(path.join(item.base,'child-executed.txt')));
  });
  await check('真实缓存 CLI 首次与命中均透传原生 JSON，不注入 helper JSON',()=>{
    const item=fixture('cache-passthrough',`${initialize}
$first=Invoke-AmclNode (Join-Path $fixtureRoot 'gate.mjs') --fixture
$second=Invoke-AmclNode (Join-Path $fixtureRoot 'gate.mjs') --fixture
${complete}
[Console]::Out.WriteLine((@{first=($first|ConvertFrom-Json);second=($second|ConvertFrom-Json)}|ConvertTo-Json -Depth 8 -Compress))`,{action:'CACHE'});
    assert.equal(item.result.status,0,item.result.stderr);assert.equal(item.receipt.first.marker,'native-json');assert.deepEqual(item.receipt.second,item.receipt.first);
    assert.deepEqual(item.session.events.map(event=>event.state),['PASS','REUSED_PASS']);
  });
  await check('缓存进程零退出但收据资格无效时仍失败',()=>{
    const item=fixture('cache-invalid-receipt',`${initialize}
$caught=$false
try{Invoke-AmclNode (Join-Path $fixtureRoot 'gate.mjs')|Out-Null}catch{$caught=$true}
Complete-AmclValidation
[Console]::Out.WriteLine((@{caught=$caught}|ConvertTo-Json -Compress))`,{action:'CACHE',invalidCache:true});
    assert.equal(item.result.status,0,item.result.stderr);assert.equal(item.receipt.caught,true);assert.equal(item.session.events[0].state,'FAIL');assert.notEqual(item.session.events[0].exitCode,0);
  });
  await check('初始化 stdout JSON 解析失败按独占 context 收口，不遗留租约',()=>{
    const item=fixture('initialize-parse-failure',`$caught=$false
try{${initialize}}catch{$caught=$true}
[Console]::Out.WriteLine((@{caught=$caught}|ConvertTo-Json -Compress))`,{extraEnv:{AMCL_RUNTIME_BAD_START:'1'}});
    assert.equal(item.result.status,0,item.result.stderr);assert.equal(item.receipt.caught,true);assert.equal(item.session.state,'FAIL');assert.equal(item.session.finishCalls,1);
    assert.ok(!fs.existsSync(path.join(item.base,'session.lock')));
  });
  await check('事件持久化失败不能因为原生命令成功而放行',()=>{
    const item=fixture('event-failure',`${initialize}
$caught=$false;$observedCode=0
try{Invoke-AmclNode (Join-Path $fixtureRoot 'gate.mjs')|Out-Null}catch{$caught=$true;$observedCode=$LASTEXITCODE}
Complete-AmclValidation
[Console]::Out.WriteLine((@{caught=$caught;observedCode=$observedCode}|ConvertTo-Json -Compress))`,{extraEnv:{AMCL_RUNTIME_EVENT_FAIL:'1'}});
    assert.equal(item.result.status,0,item.result.stderr);assert.equal(item.receipt.caught,true);assert.notEqual(item.receipt.observedCode,0);
    assert.equal(item.session.state,'FAIL');
  });
} finally {
  fs.writeFileSync(path.join(output,'result.json'),JSON.stringify({completedAt:new Date().toISOString(),cases,
    passed:cases.filter(item=>item.state==='PASS').length,failed:cases.filter(item=>item.state==='FAIL').length,
    sdkBuildExecuted:false,deviceOperations:false},null,2)+'\n',{flag:'wx'});
}
