/**
 * 直接解析并执行生产SDL构建入口的安全错误路径；不编译SDL、不替换工具/门禁结果。
 * 固定模式拒绝、普通旧锁严格性及候选失败收据/实际输入摘要，不用一份模板模拟构建流程。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {computeSdl3PatchsetDigest} from './sdl3-patchset-digest.mjs';
import {workspacePath,resolveWorkspacePath,assertExternalOutputPath} from './lib/workspace-paths.mjs';

if(process.platform!=='win32'){console.log('SKIP SDL build PowerShell execution requires Windows');process.exit(0);}
const root=path.resolve(import.meta.dirname,'..'),script=path.join(root,'scripts/build-sdl3-ohos.ps1');
const output=assertExternalOutputPath(process.env.AMCL_TEST_OUTPUT_DIR??workspacePath('run','sdl3-candidate-test'));
fs.mkdirSync(output,{recursive:true});
const run=fs.mkdtempSync(path.join(output,'run-'));
// 测试只继承调用者的环境；不能由固定父目录层数推导工作区。隔离工作树与独立CI克隆
// 的目录深度不同，显式环境未设置时应由既有解析器发现最近的规范工作区或系统临时容器。
const env={...process.env};
const command=(args,extra={},environment=env)=>spawnSync('pwsh',['-NoProfile',...args],{cwd:root,env:{...environment,...extra},encoding:'utf8',windowsHide:true});
const hash=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const lockLines=fs.readFileSync(path.join(root,'deps.lock'),'utf8').split(/\r?\n/);
const lockStart=lockLines.findIndex(line=>line.trim()==='[sdl3-native]');assert.ok(lockStart>=0);
const nextSection=lockLines.findIndex((line,index)=>index>lockStart&&/^\s*\[.+\]\s*$/.test(line));
const locked=lockLines.slice(lockStart+1,nextSection<0?undefined:nextSection).join('\n');
const field=name=>new RegExp('^\\s*'+name+'\\s*=\\s*([^#\\r\\n]+)','m').exec(locked)?.[1].trim();
const protectedFiles=['deps.lock','entry/libs/arm64-v8a/libSDL3.so'].map(name=>path.join(root,name)).filter(file=>fs.existsSync(file));
const before=protectedFiles.map(file=>[file,hash(file)]);

// 生产PowerShell AST本身必须可解析，不能因只有拒绝分支被执行而漏掉后面的构建语法错误。
const parser=command(['-Command',"$t=$null;$e=$null;$a=[System.Management.Automation.Language.Parser]::ParseFile($env:SDL_SCRIPT,[ref]$t,[ref]$e);if($e.Count){$e|Write-Output;exit 1};$g=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.IfStatementAst]},$true)|ForEach-Object {$_.Clauses|ForEach-Object {$_.Item1.Extent.Text}});@{parameters=@($a.ParamBlock.Parameters|ForEach-Object {$_.Name.VariablePath.UserPath});guards=$g}|ConvertTo-Json -Depth 4 -Compress"],{SDL_SCRIPT:script});
assert.equal(parser.status,0,parser.stderr);const parsed=JSON.parse(parser.stdout.trim());assert.ok(parsed.parameters.includes('Candidate'));
assert.ok(parsed.guards.some(guard=>guard.includes('-not $Candidate')&&guard.includes('$ActualSize -ne $ExpectedSize')&&guard.includes('$ActualSha -ne $ExpectedSha')),
 '真实AST必须保留普通模式完整size/SHA锁字节门，不能仅因测试没编译SDL而漏掉它');

// 实际运行配对模式拒绝；工具和目录cmdlet边界全部设为只记录的失败spy，必须一次也未到达。
const trace=path.join(run,'forbidden-calls.txt'),forbiddenOutput=path.join(run,'forbidden-output');
const spy=path.join(run,'guard.ps1');
fs.writeFileSync(spy,`$ErrorActionPreference='Stop'
foreach($name in @('node','git','Get-AmclWorkspacePath','New-Item','Split-Path','Join-Path','Get-Content','Get-Item','Test-Path','Get-Command')){
 Set-Item -LiteralPath "Function:global:$name" -Value { [IO.File]::AppendAllText($env:SDL_SPY_TRACE,'unexpected call'+[Environment]::NewLine);throw 'unexpected directory/tool call' }
}
try { & $env:SDL_SCRIPT -Candidate -Deploy -SourceRepo $env:SDL_BAD_SOURCE -BuildRoot $env:SDL_FORBIDDEN_OUTPUT;exit 81 }
catch { Write-Output $_.Exception.Message;exit 31 }
`);
const rejected=command(['-File',spy],{SDL_SCRIPT:script,SDL_SPY_TRACE:trace,SDL_FORBIDDEN_OUTPUT:forbiddenOutput,SDL_BAD_SOURCE:path.join(run,'missing-source')});
assert.equal(rejected.status,31,rejected.stdout+rejected.stderr);
assert.match(rejected.stdout+rejected.stderr,/Candidate cannot be combined with Deploy/);
assert.equal(fs.existsSync(trace),false);assert.equal(fs.existsSync(forbiddenOutput),false);

const allowed=spawnSync(process.execPath,[path.join(root,'scripts/lib/workspace-paths.mjs'),'build','sdl3',root],{cwd:root,env,encoding:'utf8'});
assert.equal(allowed.status,0,allowed.stderr);const buildBase=allowed.stdout.trim();
// 即使上层测试进程设置了工作区，也必须直接检验未设置环境的真实发现分支。这里只解析
// 路径，不创建目录；Node CLI、PowerShell适配层和候选执行均使用相同的生产解析入口，
// 防止测试自行注入一个路径后把目录发现错误隐藏起来。
const unsetEnv={...env};delete unsetEnv.AMCL_WORKSPACE_ROOT;
const discoveredExpected=resolveWorkspacePath('build','sdl3',{root,env:unsetEnv});
const existedBeforeDiscovery=fs.existsSync(discoveredExpected);
const discoveredNode=spawnSync(process.execPath,[path.join(root,'scripts/lib/workspace-paths.mjs'),'build','sdl3',root],{cwd:root,env:unsetEnv,encoding:'utf8'});
assert.equal(discoveredNode.status,0,discoveredNode.stderr);
assert.equal(path.resolve(discoveredNode.stdout.trim()),discoveredExpected);
const discoveredPs=command(['-Command',". $env:SDL_WORKSPACE_HELPER;Get-AmclWorkspacePath -Kind build -Id sdl3 -ProjectRoot $env:SDL_PROJECT_ROOT"],
 {SDL_WORKSPACE_HELPER:path.join(root,'scripts/lib/workspace-paths.ps1'),SDL_PROJECT_ROOT:root},unsetEnv);
assert.equal(discoveredPs.status,0,discoveredPs.stderr);assert.equal(path.resolve(discoveredPs.stdout.trim()),discoveredExpected);
assert.equal(fs.existsSync(discoveredExpected),existedBeforeDiscovery,'纯路径发现不能创建新的工作区目录');
const fresh=(name,base=buildBase)=>path.join(base,name+'-'+crypto.randomUUID());
const recipe=computeSdl3PatchsetDigest(root),normalRoot=fresh('normal-lock-test');
const normal=command(['-File',script,'-SourceRepo',path.join(run,'missing-source'),'-BuildRoot',normalRoot]);
assert.notEqual(normal.status,0);
if(recipe.sha256!==field('patchset_sha256'))assert.match(normal.stdout+normal.stderr,/SDL3 patchset mismatch/);
else assert.match(normal.stdout+normal.stderr,/command failed|cannot change to|not found/i);
assert.equal(fs.existsSync(normalRoot),false,'普通严格路径不得在旧锁/源码错误后预约候选目录');

// 候选执行实际ordered digest和真实git错误；不存在的repo保证不会进入patch/SDK/SDL编译。
const candidateRoot=fresh('candidate-source-failure',discoveredExpected);
const failed=command(['-File',script,'-Candidate','-SourceRepo',path.join(run,'missing-source'),'-BuildRoot',candidateRoot],{},unsetEnv);
assert.notEqual(failed.status,0);
const receipt=JSON.parse(fs.readFileSync(path.join(candidateRoot,'candidate-receipt.json'),'utf8'));
assert.equal(receipt.mode,'candidate');assert.equal(receipt.state,'Failed');assert.equal(receipt.lockedArtifactApproved,false);
assert.equal(receipt.invocation.deploy,false);assert.equal(receipt.artifact,null);assert.equal(receipt.sdk,null);
assert.equal(receipt.error.phase,'source-pin');assert.ok(Date.parse(receipt.finishedAt)>=Date.parse(receipt.startedAt));
assert.equal(receipt.script.sha256,hash(script));assert.equal(receipt.source.pin,field('commit'));assert.equal(receipt.source.abiBase,field('abi_base'));
assert.equal(receipt.patchset.actualSha256,recipe.sha256);assert.equal(receipt.patchset.lockedSha256,field('patchset_sha256'));
assert.equal(receipt.patchset.artifactRevision,field('version_string')+'-amclps'+recipe.sha256);
assert.deepEqual(receipt.patchset.orderedInputs.map(input=>input.name),recipe.names);
for(const input of receipt.patchset.orderedInputs){assert.equal(input.sha256,hash(input.path));assert.equal(input.size,fs.statSync(input.path).size);}
const canonical=receipt.patchset.orderedInputs.map(({ordinal,name,size,sha256})=>({ordinal,name,size,sha256}));
assert.equal(receipt.patchset.inputListSha256,crypto.createHash('sha256').update(JSON.stringify(canonical)).digest('hex'));
for(const entry of receipt.commands){assert.equal(entry.tool.sha256,hash(entry.tool.path));assert.ok(Date.parse(entry.finishedAt)>=Date.parse(entry.startedAt));}
assert.equal(receipt.commands.at(-1).exitCode,128);assert.equal(receipt.commands.at(-1).arguments.includes('cat-file'),true);
assert.equal(fs.existsSync(path.join(candidateRoot,'source')),false);assert.doesNotMatch(failed.stdout,/\[sdl3-build\] PASS|CANDIDATE VERIFIED/);
// 同一候选目录再次调用必须拒绝，不能覆盖原Failed证据或承认某个旧缓存产物。
const receiptFile=path.join(candidateRoot,'candidate-receipt.json'),receiptHash=hash(receiptFile);
const repeated=command(['-File',script,'-Candidate','-SourceRepo',path.join(run,'missing-source'),'-BuildRoot',candidateRoot],{},unsetEnv);
assert.notEqual(repeated.status,0);assert.match(repeated.stdout+repeated.stderr,/BuildRoot already exists/);assert.equal(hash(receiptFile),receiptHash);
const forbiddenProjectOutput=path.join(root,'entry/libs/candidate-forbidden-'+crypto.randomUUID());
const projectRejected=command(['-File',script,'-Candidate','-BuildRoot',forbiddenProjectOutput]);
assert.notEqual(projectRejected.status,0);assert.equal(fs.existsSync(forbiddenProjectOutput),false);
for(const [file,expected]of before)assert.equal(hash(file),expected,'候选/拒绝测试不能写libs或lock');
fs.writeFileSync(path.join(run,'guard.log'),rejected.stdout+rejected.stderr);
fs.writeFileSync(path.join(run,'normal.log'),normal.stdout+normal.stderr);
fs.writeFileSync(path.join(run,'candidate-failure.log'),failed.stdout+failed.stderr);
fs.writeFileSync(path.join(run,'result.json'),JSON.stringify({recordedAt:new Date().toISOString(),timezone:'Asia/Shanghai',
 script,scriptSha256:hash(script),recipeSha256:recipe.sha256,patches:recipe.names.length,candidateReceipt:path.join(candidateRoot,'candidate-receipt.json'),
 workspaceDiscovery:{AMCL_WORKSPACE_ROOT:null,node:discoveredNode.stdout.trim(),powershell:discoveredPs.stdout.trim(),candidateOutput:candidateRoot},
 result:'PASS actual parser/early mode guard/strict normal path/unset workspace discovery/candidate failure receipt; SDL compilation not run'},null,2));
console.log('PASS SDL candidate actual script: parser, pre-tool mode rejection, normal strict lock, unset workspace discovery, ordered inputs and failed receipt; evidence='+run);
