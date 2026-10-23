/** 通用导出生产纯逻辑宿主回归；无文件输出和平台替身，不操作用户实例。 */
import assert from 'node:assert/strict';
import {loader} from './mod-install-test-runtime.mjs';
const load=loader();
const {ExportVersionResolver:V}=load('feature_core/src/main/ets/export/ExportVersionResolver.ets');
const {DesktopDependencyPlanner:D}=load('feature_core/src/main/ets/export/DesktopDependencyPlanner.ets');
const {ExportFilePlan:F}=load('feature_core/src/main/ets/export/ExportFilePlan.ets');
const {ExportPath:P}=load('feature_core/src/main/ets/export/ExportPath.ets');
// 以下小样本直接执行纯生产模块，源根只是内存字符串，不访问或写入用户实例。
const hash='a'.repeat(40), sha256='b'.repeat(64);
const artifact=path=>({path,url:'https://example.org/'+path,sha1:hash,size:12});
const vanilla={id:'1.21.1',mainClass:'net.minecraft.client.main.Main',downloads:{client:artifact('client.jar')},libraries:[{name:'org.example:base:1',downloads:{artifact:artifact('org/example/base/1/base-1.jar')}}],assetIndex:{id:'1',url:'https://example.org/index.json',sha1:hash,size:12},arguments:{game:['--username','${auth_player_name}'],jvm:[]}};
const version=V.resolve('Renamed',[{id:'Renamed',jsonText:JSON.stringify({...vanilla,id:'Renamed',clientVersion:'1.21.1'})}]);
assert.equal(version.issues.length,0);
assert.equal(version.jarVersionId,'Renamed');
const dep=D.plan(version,{os:'windows',arch:'x64',version:''},JSON.stringify({objects:{'sounds/a.ogg':{hash,size:4}}}));
assert.deepEqual(Array.from(dep.issues),[]);
assert.equal(dep.dependencies.length,4);
const request={mcRoot:'/mc',versionId:'Renamed',gameDir:'/mc/versions/Renamed',exportId:'Copy',displayName:'测试导出',format:'full',launcher:'pcl',platform:{os:'windows',arch:'x64',version:''},includeDirectories:['mods','config','saves','logs'],includeFiles:['options.txt'],selectedWorlds:['世界'],sharedGameDir:false};
const files=['mods/a.jar','config/a.json','saves/世界/level.dat','saves/other/level.dat','logs/latest.log','logs/amcl-launch.log','options.txt'].map(path=>({path,size:4,sha1:hash,sha256,directory:false}));
const plan=F.build(request,version,dep.dependencies,files);
assert.equal(plan.issues.filter(x=>x.severity==='error').length,0);
assert.ok(plan.files.some(x=>x.archivePath==='.minecraft/versions/Copy/Copy.jar'));
assert.ok(plan.files.some(x=>x.archivePath==='.minecraft/versions/Copy/saves/世界/level.dat'));
assert.ok(!plan.files.some(x=>x.archivePath.includes('other')||x.archivePath.includes('amcl-launch.log')));
assert.ok(!plan.files.some(x=>x.archivePath==='.minecraft/versions/Copy/Copy.json'&&x.content.includes('/mc')));
const inherited=V.resolve('Child',[{id:'Child',jsonText:JSON.stringify({id:'Child',inheritsFrom:'1.21.1',libraries:[]})},{id:'1.21.1',jsonText:JSON.stringify(vanilla)}]);
assert.equal(inherited.jarVersionId,'1.21.1');
assert.equal(inherited.vanillaVersion,'1.21.1');
assert.ok(V.resolve('a',[{id:'a',jsonText:'{"id":"a","inheritsFrom":"b"}'},{id:'b',jsonText:'{"id":"b","inheritsFrom":"a"}'}]).issues.some(x=>x.code==='INHERITANCE_CYCLE'));
assert.ok(V.resolve('a',[{id:'a',jsonText:'{"id":"a","inheritsFrom":"missing"}'}]).issues.some(x=>x.code==='PARENT_MISSING'));
const rules={dependencies:[],issues:[]};
assert.equal(D.allowed([{action:'allow'},{action:'disallow',os:{name:'windows'}},{action:'allow',os:{name:'windows',arch:'x86_64'}}],request.platform,rules),true);
assert.equal(D.allowed([{action:'allow',os:{name:'linux'}}],request.platform,rules),false);
// 旧 AMCL 只部署 virtual/legacy 命名资源；电脑对象目标与源候选必须分离，不能要求先补写源 objects。
const legacy=D.plan(version,request.platform,JSON.stringify({virtual:true,objects:{'sound/a.ogg':{hash,size:4}}}));
const legacyAssets=legacy.dependencies.filter(d=>d.kind==='asset');
assert.ok(legacyAssets.every(d=>d.sourcePath==='assets/virtual/legacy/sound/a.ogg'));
assert.ok(legacyAssets.every(d=>d.sourceCandidates.includes('assets/objects/aa/'+hash)));
const legacyFiles=F.build(request,version,legacy.dependencies,[]).files;
assert.equal(legacyFiles.find(f=>f.archivePath==='.minecraft/assets/objects/aa/'+hash).sourcePath,'assets/virtual/legacy/sound/a.ogg');
// 认证等号参数和缺值曾绕过普通分隔参数检查；失败计划正文也不能继续保留字面令牌。
const clientOnly=dep.dependencies.filter(d=>d.kind==='client');
for(const args of [['--accessToken=FAKE_PRIVATE_REVIEW_VALUE'],['--accessToken'],['--session','FAKE_PRIVATE_REVIEW_VALUE']]) {
 const unsafe={...version,json:{...version.json,arguments:{game:args,jvm:[]}}};
 const rejected=F.build(request,unsafe,clientOnly,[]);
 assert.ok(rejected.issues.some(i=>i.code==='LITERAL_AUTH_ARGUMENT'));
 assert.ok(!rejected.files.some(f=>f.content.includes('FAKE_PRIVATE_REVIEW_VALUE')));
}
for(const format of ['modrinth','curseforge']) {
 const standard=F.build({...request,format},version,[],files);
 assert.ok(standard.files.some(x=>x.archivePath==='overrides/mods/a.jar'));
 assert.equal(standard.files.filter(x=>x.archivePath==='modrinth.index.json'||x.archivePath==='manifest.json').length,1);
 assert.ok(!standard.files.some(x=>x.archivePath.startsWith('.minecraft')));
 const content=JSON.parse(standard.files.find(x=>x.archivePath=== (format==='modrinth'?'modrinth.index.json':'manifest.json')).content);
 assert.equal(content.files.length,0);
}
for(const path of ['../a','a/../b','C:/a','a\\b','CON.txt','a.','a//b']) assert.equal(P.relative(path),false,path);
assert.equal(P.relative('saves/中文/level.dat'),true);
assert.equal(P.https('https://user:pass@example.org/x'),false);
const collision=F.build({...request,format:'modrinth'},version,[],[...files,{path:'mods/A.jar',size:4,sha1:hash,sha256,directory:false}]);
assert.ok(collision.issues.some(x=>x.code==='ARCHIVE_COLLISION'));
// 同一套 ArkTS Hypium 用例也在宿主实际运行；只替换断言框架，生产解析/计划不打替身。
let executed=0;
const expect=value=>({
 assertTrue(){assert.equal(value,true);},assertFalse(){assert.equal(value,false);},
 assertEqual(other){assert.equal(value,other);},
 assertDeepEquals(other){assert.equal(JSON.stringify(value),JSON.stringify(other));},
});
const production={...load('feature_core/src/main/ets/export/ExportTypes.ets'),...load('feature_core/src/main/ets/export/ExportPath.ets'),
 ...load('feature_core/src/main/ets/export/ExportContentSelection.ets'),
 ...load('feature_core/src/main/ets/export/ExportVersionResolver.ets'),...load('feature_core/src/main/ets/export/DesktopDependencyPlanner.ets'),
 ...load('feature_core/src/main/ets/export/ForgelikeExportPlanner.ets'),
 ...load('feature_core/src/main/ets/export/ExportFilePlan.ets')};
const suite=loader({'feature_core':production,'@ohos/hypium':{expect,describe(name,body){body();},it(name,timeout,body){body();executed++;}}});
suite('entry/src/test/GameExportPlan.test.ets').default();
suite('entry/src/test/ForgelikeExportPlan.test.ets').default();
assert.ok(executed>=27);
console.log('PASS Hypium production export plan cases: '+executed);
console.log('PASS pure export: inheritance, desktop closure, target rules, full paths, both standard formats, selected worlds, private exclusion, collisions');
