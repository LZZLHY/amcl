/**
 * 多产品构建的宿主回归：检查原位输出、产品隔离及失败时的签名配置恢复。
 * 使用仓外夹具执行真实 PowerShell 入口；编译和签名由替身代替，不读取本机秘密。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {workspaceTempRoot} from './lib/workspace-paths.mjs';

if(process.platform!=='win32'){
  console.log('SKIP: PowerShell build entry regression requires Windows');
  process.exit(0);
}
const root=path.resolve(import.meta.dirname,'..');
const dir=fs.mkdtempSync(path.join(workspaceTempRoot(),'build-delivery-'));
const write=(name,text)=>{const file=path.join(dir,name);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,text);};
try{
  // 实际调用定向清理，确认旧的全模块 clean 不会再擦掉先构建产品的包。
  const removed=['entry/build/store/cache','entry/build/store/generated','entry/build/store/intermediates',
    'entry/.cxx/store/store/release/arm64-v8a'];
  const retained=['entry/build/store/outputs/store/entry-store-signed.hap',
    'entry/.cxx/store/store/debug/arm64-v8a/compile_commands.json',
    'entry/build/default/outputs/default/entry-default-signed.hap',
    'entry/build/sideload/outputs/sideload/entry-sideload-unsigned.hap',
    'entry/build/desktop/outputs/desktop/entry-desktop-signed.hap',
    'entry/build/default/intermediates/keep.txt'];
  for(const file of [...removed.map(name=>name+'/stale.txt'),...retained])write('cleanup/'+file,'fixture');
  const clear=()=>spawnSync('pwsh',['-NoProfile','-Command',
    '. ./scripts/lib/build-tools.ps1; Clear-AmclProductIntermediates -ProjectRoot $env:AMCL_CLEANUP_FIXTURE -Product store -BuildMode release'],
    {cwd:root,encoding:'utf8',windowsHide:true,env:{...process.env,AMCL_CLEANUP_FIXTURE:path.join(dir,'cleanup')}});
  const cleaned=clear();assert.equal(cleaned.status,0,cleaned.stderr);
  for(const name of removed)assert.equal(fs.existsSync(path.join(dir,'cleanup',name)),false,name);
  for(const name of retained)assert.equal(fs.readFileSync(path.join(dir,'cleanup',name),'utf8'),'fixture',name);
  // junction 不能把工程内的清理路径变成指向外部资料的递归删除。
  write('linked-evidence/keep.txt','untouched');
  const junction=path.join(dir,'cleanup/entry/build/store/cache');
  fs.symlinkSync(path.join(dir,'linked-evidence'),junction,'junction');
  const rejected=clear();assert.notEqual(rejected.status,0);assert.match(rejected.stdout+rejected.stderr,/路径包含链接/);
  assert.equal(fs.readFileSync(path.join(dir,'linked-evidence/keep.txt'),'utf8'),'untouched');fs.unlinkSync(junction);

  // SDK 环境优先采用当前产品显式指定的可用根目录，不回到失效的旧 shim。
  const mobile=path.join(dir,'mobile-sdk'),desktop=path.join(dir,'desktop-sdk');
  for(const sdk of [mobile,desktop])fs.mkdirSync(path.join(sdk,'default/openharmony'),{recursive:true});
  const sdkProbe=spawnSync('pwsh',['-NoProfile','-Command',
    '. ./scripts/lib/build-tools.ps1; @((Resolve-AmclBuildSdk -Product store), (Resolve-AmclBuildSdk -Product desktop)) | ConvertTo-Json -Compress'],
    {cwd:root,encoding:'utf8',windowsHide:true,env:{...process.env,AMCL_SDK_HOME_MOBILE:mobile,AMCL_SDK_HOME_DESKTOP:desktop,DEVECO_SDK_HOME:path.join(dir,'missing')}});
  assert.equal(sdkProbe.status,0,sdkProbe.stderr);assert.deepEqual(JSON.parse(sdkProbe.stdout.trim()),[mobile,desktop]);

  const fixture=path.join(dir,'runner');
  write('runner/build-delivery.ps1',fs.readFileSync(path.join(root,'build-delivery.ps1')));
  write('runner/scripts/build-menu-signing.mjs',`import fs from 'node:fs';const a=process.argv;const get=k=>a[a.indexOf('--'+k)+1];
fs.appendFileSync('trace.txt',get('kind')+'/'+get('product')+'\\n');fs.writeFileSync('build-profile.json5','temporary signing fixture');`);
  write('runner/build-hap.ps1',`param($Product,$HapKind,$BuildMode)
if($env:AMCL_DELIVERY_FIXTURE_FAIL -eq '1'){exit 23}
if($BuildMode -ne 'debug' -or $HapKind -ne 'signed'){exit 24}
New-Item -ItemType Directory -Force -Path "entry/build/$Product/outputs/$Product" | Out-Null
foreach($Kind in @('signed','unsigned')){Set-Content -LiteralPath "entry/build/$Product/outputs/$Product/entry-$Product-$Kind.hap" -Value $Product}
`);
  write('runner/build-app.ps1',`New-Item -ItemType Directory -Force -Path 'entry/build/store/outputs/store','build/outputs/store' | Out-Null
foreach($Kind in @('signed','unsigned')){
Set-Content -LiteralPath "entry/build/store/outputs/store/entry-store-$Kind.hap" -Value 'store'
Set-Content -LiteralPath "build/outputs/store/MyApplication-store-$Kind.app" -Value 'store'
}
`);
  const original=Buffer.from('{"fixture":"original bytes"}\r\n');
  const profile=path.join(fixture,'build-profile.json5'),backup=path.join(fixture,'.secrets/amcl-build-menu-profile.backup');
  fs.writeFileSync(profile,original);
  const invoke=fail=>spawnSync('pwsh',['-NoProfile','-File',path.join(fixture,'build-delivery.ps1')],
    {cwd:fixture,encoding:'utf8',windowsHide:true,env:{...process.env,AMCL_DELIVERY_FIXTURE_FAIL:fail?'1':'0'}});
  const success=invoke(false);assert.equal(success.status,0,success.stderr);
  assert.deepEqual(fs.readFileSync(profile),original);assert.equal(fs.existsSync(backup),false);
  assert.deepEqual(fs.readFileSync(path.join(fixture,'trace.txt'),'utf8').trim().split('\n'),
    ['debug/default','debug/sideload','debug/desktop','release/store']);
  for(const product of ['default','sideload','desktop','store'])for(const kind of ['signed','unsigned']){
    const file=path.join(fixture,`entry/build/${product}/outputs/${product}/entry-${product}-${kind}.hap`);
    assert.ok(fs.existsSync(file));assert.ok(success.stdout.includes(file));
  }
  for(const kind of ['signed','unsigned'])assert.ok(success.stdout.includes(path.join(fixture,`build/outputs/store/MyApplication-store-${kind}.app`)));
  const failure=invoke(true);assert.notEqual(failure.status,0);assert.match(failure.stdout+failure.stderr,/HAP 构建失败/);
  assert.deepEqual(fs.readFileSync(profile),original);assert.equal(fs.existsSync(backup),false);
  fs.writeFileSync(backup,'existing owner');const busy=invoke(false);assert.notEqual(busy.status,0);
  assert.equal(fs.readFileSync(backup,'utf8'),'existing owner');assert.deepEqual(fs.readFileSync(profile),original);
}finally{
  // 只允许移除本次 mkdtemp 创建、仍在外部测试父目录内的夹具。
  const parent=fs.realpathSync(workspaceTempRoot()),target=fs.realpathSync(dir),relative=path.relative(parent,target);
  if(!relative||relative.startsWith('..')||path.isAbsolute(relative))throw new Error('夹具清理边界不合法');
  fs.rmSync(target,{recursive:true,force:true});
}
const syntax=spawnSync('pwsh',['-NoProfile','-Command',
  "$errors=$null;$tokens=$null;foreach($p in @('build-delivery.ps1','build-app.ps1','build-hap.ps1','scripts/lib/build-tools.ps1')){[void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Get-Location) $p),[ref]$tokens,[ref]$errors);if($errors.Count){$errors|ForEach-Object {Write-Error $_};exit 1}}"],
  {cwd:root,encoding:'utf8',windowsHide:true});
assert.equal(syntax.status,0,syntax.stderr);
console.log('PASS: normal product builds, native signed/unsigned outputs, isolated cleanup and signing configuration restoration');
