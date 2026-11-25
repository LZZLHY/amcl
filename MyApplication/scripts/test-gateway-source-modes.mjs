/**
 * 三模式行为矩阵：执行真实URL/Maven/元数据编排及UI来源表达式，只替换平台开关、
 * 磁盘缓存与Native HTTP端口。负控读取固定Git原件，必须在来源断言失败；不访问公网、
 * SDK构建、设备或线上，不把1字节RTT当正文速度。真实body竞争另由Native socket用例验证。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {environment} from './lib/ets-runtime-fixture.mjs';
import compiler from './lib/ets-compiler.mjs';
const repo=path.resolve(import.meta.dirname,'..');
const args=process.argv.slice(2),arg=name=>{const i=args.indexOf(name);return i<0?undefined:args[i+1];};
const negative=arg('--negative-case'),base=arg('--negative-base');
const out=arg('--output');
let enabled=false;const records=[],responses=[],cases=[];
const log={info(){},warn(){},error(){},debug(){}};
const manager={isCaBundleInitialized:()=>true,async fetchTextEx(...values){records.push(values);return responses.shift()??{statusCode:200,headers:{},body:'public-body'};}};
const store={isReady:()=>false,get:()=>null,getMeta:()=>null,getBody:()=>null,touch(){},put(){}};
const relay={isEnabled:()=>enabled,status:()=>({active:false,usable:false,tripped:true})};
const imports={
  './RelayClient':{getRelayClient:()=>relay},
  './DownloadManager':{DownloadManager:{instance:()=>manager}},
  '../download/DownloadManager':{DownloadManager:{instance:()=>manager}},
  '../version/MetadataCacheStore':{getMetadataCacheStore:()=>store},
  '../version/MetadataCache':{buildConditionalRequest:()=>({})},
  './MetadataCacheStore':{getMetadataCacheStore:()=>store},
  './MetadataCache':{buildConditionalRequest:()=>({})},
  '../download/RelayClient':{getRelayClient:()=>relay},
  '../version/VersionFileVerifier':{VersionFileVerifier:{}},
  '../version/VersionInstallLease':{newVersionInstallOwner:()=>''},
  '@kit.NetworkKit':{http:{}},'@kit.CryptoArchitectureKit':{cryptoFramework:{}},
  '@kit.CoreFileKit':{fileIo:{}},
  feature_core:{DownloadManager:{instance:()=>manager},buildConditionalRequest:()=>({})},
};
const sourceOverrides={};
if(base){
  assert.match(base,/^[a-f0-9]{40}$/);
  for(const file of ['mods/src/main/ets/ModrinthUrls.ets','mods/src/main/ets/CurseForgeUrls.ets',
    'feature_core/src/main/ets/download/SourceProber.ets']){
    const original=execFileSync('git',['-C',repo,'show',base+':'+file],{encoding:'utf8'});
    sourceOverrides[file]=()=>original;
  }
}
const env=environment({commons:{AppLogger:log,LogTags:{MOD_MAVEN:'Maven'},LOG_DOMAIN_DOWNLOAD:0,
  LOG_DOMAIN_MODLOADER:0,BMCLAPI_BASE:'https://bmclapi2.bangbang93.com',MOJANG_RESOURCES:'https://resources.download.minecraft.net',
  DiagnosticPolicy:{isDeveloperBuild:()=>false}},imports,sourceOverrides});
const load=env.load,mr=load('mods/src/main/ets/ModrinthUrls.ets'),cf=load('mods/src/main/ets/CurseForgeUrls.ets');
const mc=load('feature_core/src/main/ets/download/SourceProber.ets');
const plain=value=>JSON.parse(JSON.stringify(value));
const official='https://piston-data.mojang.com/v1/objects/0123456789/client.jar';
const mirror='https://bmclapi2.bangbang93.com/version/1.21.1/client';
function check(name,actual,expected){assert.deepEqual(plain(actual),expected,name);cases.push(name);console.log('PASS '+name);}
if(negative==='mr-gateway'){
  check('NEGATIVE enabled gateway forbids mirror saved preference',mr.resolveModrinthSourcePreference('mcim',mr.ModrinthSourceMode.MCIM_FIRST,true),mr.ModrinthSourceMode.OFFICIAL_ONLY);
  throw new Error('old production unexpectedly passed gateway contract');
}
if(negative==='mc-official'){
  mc.setMcSourcePreference('official');
  check('NEGATIVE explicit official cannot retain BMCL',mc.buildSortedUrls(mirror,official),[official]);
  throw new Error('old production unexpectedly passed official contract');
}
for(const preference of ['auto','mirror','official']){
  enabled=true;mc.setMcSourcePreference(preference);
  check('MC gateway intention overrides '+preference,mc.buildSortedUrls(mirror,official),[official]);
  check('MC strict bypasses mirror list candidate '+preference,
    await mc.fetchMcVersionListSources(async ()=>'official',async ()=>{throw new Error('mirror forbidden');}),'official');
  check('MC strict preserves general file transport '+preference,mc.useOrderedMcDownload(),false);
}
check('no extra metadata probe for strict modes',records.length,0);
enabled=false;mc.setMcSourcePreference('official');
check('MC explicit official with gateway off',mc.buildSortedUrls(mirror,official),[official]);
mc.setMcSourcePreference('mirror');check('MC mirror restored after gateway off',mc.buildSortedUrls(mirror,official),[mirror,official]);
mc.setMcSourcePreference('auto');check('MC auto retains full source pool',mc.buildSortedUrls(mirror,official),[mirror,official]);
check('MC auto with gateway off selects ordered transfer',mc.useOrderedMcDownload(),true);
for(let i=0;i<100;i++)mc.buildSortedUrls(mirror,official);
check('body URL construction adds no per-file probe',records.length,0);

// 默认文件排序与真实有效的版本清单绑定。通过宿主定时器端口精确推进备用请求，
// 不访问网络，也不把缓存命中和模拟 Date 时间当作独立网络取样。
const calls=[];
let resolveOfficial;
const officialPending=new Promise(resolve=>{resolveOfficial=resolve;});
const pendingRace=mc.fetchMcVersionListSources(()=>{calls.push('official');return officialPending;},
  async ()=>{calls.push('mirror');return 'mirror-data';});
check('version list starts official before mirror',calls,['official']);
check('version list mirror delay is 5 seconds',[...env.timer.values()].map(timer=>timer.delay),[5000]);
env.runTimers();
check('first valid mirror may win while official pending',await pendingRace,'mirror-data');
resolveOfficial('late-data');
const quickFailure=await mc.fetchMcVersionListSources(async ()=>{throw new Error('offline');},async ()=>'fallback');
check('early official failure starts mirror without waiting',quickFailure,'fallback');
let resolveMirror,rejectOfficial;
const revocation=mc.fetchMcVersionListSources(()=>new Promise((_,reject)=>{rejectOfficial=reject;}),
  ()=>new Promise(resolve=>{resolveMirror=resolve;}));
const revoked=assert.rejects(revocation,/镜像已被当前来源策略禁止|official failed/);
env.runTimers();enabled=true;resolveMirror('forbidden');rejectOfficial(new Error('official failed'));await revoked;
enabled=false;
mc.observeDirectMojangManifest(4000);
check('four seconds exactly keeps mirror-first',mc.buildSortedUrls(mirror,official),[mirror,official]);
const MavenPolicy=load('feature_core/src/main/ets/modloader/MavenSpecBuilder.ets');
const fabricRel='net/fabricmc/fabric-loader/0.20.1/fabric-loader-0.20.1.jar';
const fabricMaven='https://maven.fabricmc.net/'+fabricRel;
const fabricMirror='https://bmclapi2.bangbang93.com/maven/'+fabricRel;
const fabricAlias='https://bmclapi2.bangbang93.com/libraries/'+fabricRel;
check('ordered Maven mirror-first tries Fabric upstream before mirror alias',
  MavenPolicy.buildMavenUrls('net.fabricmc:fabric-loader:0.20.1',undefined,false,undefined,true),
  [fabricMirror,fabricMaven,fabricAlias]);
const Manifest=load('feature_core/src/main/ets/version/McVersionManifest.ets');
const entries=Array.from({length:200},(_,index)=>({id:'fixture-'+index,type:'release',url:official,releaseTime:'2026-11-07'}));
const manifest={latest:{release:'fixture-0',snapshot:'fixture-1'},versions:entries};
responses.push({statusCode:200,headers:{},body:JSON.stringify(manifest)});
check('version install validates selected entry in direct manifest',
  (await Manifest.loadMcVersionManifest(3600,true,'fixture-0')).versions[0].id,'fixture-0');
check('official manifest is one direct candidate for elapsed sampling',records.at(-1).slice(0,2),
  ['https://launchermeta.mojang.com/mc/game/version_manifest_v2.json',[]]);
check('valid fast official manifest latches auto official first',mc.buildSortedUrls(mirror,official),[official,mirror]);
mc.setMcSourcePreference('mirror');
check('explicit mirror overrides process latch',mc.buildSortedUrls(mirror,official),[mirror,official]);
mc.setMcSourcePreference('auto');
check('returning to auto retains fast process observation',mc.buildSortedUrls(mirror,official),[official,mirror]);
check('ordered Maven official-first keeps both mirror aliases behind the real host',
  MavenPolicy.buildMavenUrls('net.fabricmc:fabric-loader:0.20.1',undefined,true,undefined,true),
  [fabricMaven,fabricMirror,fabricAlias]);

enabled=true;
const custom='https://author.example/private/repo/a.jar?token=fixture%2Bvalue&x=2&x=1';
const forged='https://bmclapi2.bangbang93.com.author.example/a.jar';
check('known mirror selection preserves author bytes',mc.selectMcSourceUrls([mirror,official,custom,forged]),[official,custom,forged]);
check('only mirror returns empty instead of synthetic fallback',mc.selectMcSourceUrls([mirror]),[]);
for(const value of ['https://bmclapi2.bangbang93.com.:443/a','https://opaque@mod.mcimirror.top/a'])check('known authority normalization '+value.split('/')[2],mc.selectMcSourceUrls([value]),[]);
check('metadata URI credentials are not relay opt-in',mc.canRelayPublicMcMetadata([custom]),false);
check('metadata userinfo is not relay opt-in',mc.canRelayPublicMcMetadata(['https://opaque@piston-meta.mojang.com/a']),false);
await mc.fetchPublicMcMetadata([mirror,official]);
check('public metadata filtered before Native',records.at(-1).slice(0,2),[official,[]]);
check('public metadata explicit opt-in',records.at(-1)[5],true);
await mc.fetchPublicMcMetadata([custom]);check('author query direct metadata boundary',records.at(-1)[5],false);
const Maven=load('feature_core/src/main/ets/modloader/MavenSpecBuilder.ets');
const candidates=Maven.buildMavenUrls('org.example:fixture:1.0',undefined);
assert.ok(candidates.length>0);assert.ok(candidates.every(url=>!mc.isKnownSourceMirror(url)));cases.push('Maven strict excludes injected public mirrors');
check('Maven unknown direct retains exact origin',Maven.buildMavenArtifactUrls(custom),[custom]);
check('Maven unknown repository remains unique',Maven.buildMavenUrls('org.example:fixture:1.0','https://private-author.example/repo/'),['https://private-author.example/repo/org/example/fixture/1.0/fixture-1.0.jar']);
enabled=false;assert.ok(Maven.buildMavenUrls('org.example:fixture:1.0',undefined).some(url=>mc.isKnownSourceMirror(url)));cases.push('Maven off restores candidate pool');

/** 从真实ArkUI类AST提取来源方法/表达式，执行原文而非在测试中重建provider算法。 */
const bindings={getRelayClient:()=>relay,getModrinthSourceMode:()=>mr.ModrinthSourceMode.MCIM_FIRST,
 resolveModrinthSourcePreference:mr.resolveModrinthSourcePreference,resolveCurseForgeFileSourcePreference:cf.resolveCurseForgeFileSourcePreference,
 CurseForgeFileSourceMode:cf.CurseForgeFileSourceMode};
for(const file of ['entry/src/main/ets/pages/Index.ets','entry/src/main/ets/components/InstalledResourcesSheet.ets']){
  const source=fs.readFileSync(path.join(repo,file),'utf8'),ast=compiler.createSourceFile(file,source,compiler.ScriptTarget.Latest,true),nodes=[];
  const walk=node=>{if(compiler.isCallExpression(node)&&['resolveModrinthSourcePreference','resolveCurseForgeFileSourcePreference'].includes(node.expression.getText(ast)))nodes.push(node);compiler.forEachChild(node,walk);};walk(ast);
  assert.ok(nodes.length,file+' production provider found');
  for(const [i,node] of nodes.entries()){
    const fn=new Function(...Object.keys(bindings),'return function(){return '+node.getText(ast)+';}')(...Object.values(bindings));
    enabled=true;check(file+' provider '+i+' uses intent despite unusable route',fn.call({modSource:'mcim'}),'officialOnly');
    enabled=false;check(file+' provider '+i+' restores saved mirror',fn.call({modSource:'mcim'}),node.expression.getText(ast).includes('Modrinth')?'mcim':'mirrorFirst');
  }
}
// 版本安装面板已把 Fabric API 仓库交给 VersionInstallOptions；执行原面板传参和真实工厂里的来源回调。
const configFile='entry/src/main/ets/components/VersionConfigPanel.ets';
const configAst=compiler.createSourceFile(configFile,fs.readFileSync(path.join(repo,configFile),'utf8'),compiler.ScriptTarget.Latest,true);
const factoryCall=[];
function findFactory(node) {
  if(compiler.isCallExpression(node)&&node.expression.getText(configAst)==='fabricApiRepository')factoryCall.push(node);
  compiler.forEachChild(node,findFactory);
}
findFactory(configAst);
assert.equal(factoryCall.length,1,'version panel uses Fabric API repository');
const fabricEnv=environment({imports:{
  feature_core:{DownloadManager:{instance:()=>manager},getMetadataCacheStore:()=>store,getRelayClient:()=>relay},
  mods:{...bindings,ModrinthRepository:class{constructor(_manager,_disk,mode){this.readMode=mode;}}},
  './LoaderCatalog':{}
}});
const fabricFactory=fabricEnv.load('entry/src/main/ets/components/VersionInstallOptions.ets').fabricApiRepository;
const panelRepository=new Function('fabricApiRepository','return function(){return '+factoryCall[0].getText(configAst)+';}')(fabricFactory)
  .call({modSource:'mcim',cacheRemoteMeta:true});
enabled=true;check('version panel Fabric provider uses current gateway intent',panelRepository.readMode(),'officialOnly');
enabled=false;check('version panel Fabric provider restores saved mirror',panelRepository.readMode(),'mcim');
const pageFile='entry/src/main/ets/pages/ModBrowsePage.ets',pageSource=fs.readFileSync(path.join(repo,pageFile),'utf8'),pageAst=compiler.createSourceFile(pageFile,pageSource,compiler.ScriptTarget.Latest,true);
const owner=pageAst.statements.find(n=>n.members?.some(m=>m.name?.getText(pageAst)==='resolveModrinthMode'));
const names=['resolveModrinthMode','resolveCurseForgeFileMode','onlyOfficialModpackFiles_'];
const members=names.map(name=>{const member=owner?.members.find(m=>m.name?.getText(pageAst)===name);assert.ok(member,name);return member.getText(pageAst);});
const js=compiler.transpileModule('class ActualPolicyPage { '+members.join('\n')+' }',{compilerOptions:{target:compiler.ScriptTarget.ES2020}}).outputText;
const PolicyPage=new Function(...Object.keys(bindings),js+';return ActualPolicyPage;')(...Object.values(bindings));const page=new PolicyPage();page.modSource='mcim';
enabled=true;check('real page captures source-only for archive/manifest/recovery',page.onlyOfficialModpackFiles_(),true);
enabled=false;check('real page closing gateway restores saved preference',page.onlyOfficialModpackFiles_(),false);

enabled=true;
const Downloader=load('feature_core/src/main/ets/download/McDownloader.ets').McDownloader;
const downloader=Object.create(Downloader.prototype);downloader.mgr=manager;downloader.alog=()=>log;
responses.push({statusCode:304,headers:{},body:''},{statusCode:200,headers:{},body:'fresh-public'});
const before=records.length;
check('real MC 304-without-body recovery',await downloader.httpGet(mirror,[official],0),'fresh-public');
check('MC recovery Native calls retain official source',records.slice(before).map(x=>x[0]),[official,official]);
check('MC initial and recovery explicitly opt in',records.slice(before).map(x=>x[5]),[true,true]);

/** CF元数据保留MCIM/默认false，严格文件只取按同一fileId映射的官方CDN。 */
const cache={get:()=>null,getMeta:()=>null,getBody:()=>null,put(){},touch(){}};
const MR=load('mods/src/main/ets/ModrinthRepository.ets').ModrinthRepository;
let mrMode=mr.ModrinthSourceMode.MCIM_FIRST;
const mr304manager={...manager,async fetchTextEx(...args){records.push(args);mrMode=mr.ModrinthSourceMode.OFFICIAL_ONLY;return records.length===mrStart+1?{statusCode:304,headers:{},body:''}:{statusCode:200,headers:{},body:'fresh-mr'};}};
const mrRepo=new MR(mr304manager,cache,()=>mrMode,'AMCL-fixture',()=>true),mrStart=records.length;
check('real MR 304 recovery body',await mrRepo.cachedFetch({primary:'https://mod.mcimirror.top/modrinth/v2/project/p',mirrors:['https://api.modrinth.com/v2/project/p']},0),'fresh-mr');
check('MR strict after await revokes old mirror plan',records.slice(mrStart).map(x=>[x[0],x[1]]),[['https://mod.mcimirror.top/modrinth/v2/project/p',['https://api.modrinth.com/v2/project/p']],['https://api.modrinth.com/v2/project/p',[]]]);
check('MR initial and recovery explicit public opt-in',records.slice(mrStart).map(x=>x[5]),[true,true]);
const CF=load('mods/src/main/ets/CurseForgeRepository.ets').CurseForgeRepository;
const cfRepo=new CF(manager,cache,'AMCL-fixture',()=>true,()=>false,()=>cf.CurseForgeFileSourceMode.OFFICIAL_ONLY);
responses.push({statusCode:200,headers:{},body:JSON.stringify({data:[],pagination:{index:0,pageSize:20,resultCount:0,totalCount:0}})});
const types=load('mods/src/main/ets/ModTypes.ets');
await cfRepo.search({query:'fixture',kind:types.ResourceKind.MOD});
assert.match(records.at(-1)[0],/^https:\/\/mod\.mcimirror\.top\/curseforge\/v1\//);cases.push('CF metadata permission remains MCIM');
check('CF metadata does not opt in relay',records.at(-1)[5]??false,false);

/** 执行真实版本服务与清单选源，只替换磁盘、网络和网关。时间戳过期不影响首显，也不能省略在线检查。 */
async function verifyVersionBrowserCache() {
  const address = 'https://launchermeta.mojang.com/mc/game/version_manifest_v2.json';
  const mirrorAddress = 'https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json';
  const cacheKey = url => 'mc-version-manifest:' + url;
  const disk = new Map();
  function seed(url, release, fresh = false, etag = '"seed"') {
    const body = JSON.stringify({ ...manifest, latest: { release, snapshot: 'fixture-1' },
      versions: [{ ...entries[0], id: release }, ...entries.slice(1)] });
    const key = cacheKey(url);
    disk.set(key, { body, fresh, meta: { url: key, etag } });
    return body;
  }
  const diskPort = {
    isReady: () => true,
    get: (key, age) => (age === -1 || disk.get(key)?.fresh) ? disk.get(key)?.body ?? null : null,
    getBody: key => disk.get(key)?.body ?? null,
    getMeta: key => disk.get(key)?.meta ?? null,
    touch(key) { disk.get(key).fresh = true; },
    put(key, body, headers) { disk.set(key, { body, fresh: true, meta: { url: key, etag: headers.etag } }); }
  };
  const calls = [], replies = [];
  const network = { async fetchTextEx(...args) {
    calls.push(args);
    assert.ok(replies.length > 0, 'unexpected manifest request ' + args[0]);
    return replies.shift();
  } };
  let gateway = false;
  const relayPort = { getRelayClient: () => ({ isEnabled: () => gateway }) };
  const networkPort = { DownloadManager: { instance: () => network } };
  const fixture = environment({ commons: { BMCLAPI_BASE: 'https://bmclapi2.bangbang93.com' },
    imports: { './RelayClient': relayPort, '../download/RelayClient': relayPort,
      './DownloadManager': networkPort, '../download/DownloadManager': networkPort,
      './MetadataCacheStore': { getMetadataCacheStore: () => diskPort } }
  });
  const sources = fixture.load('feature_core/src/main/ets/download/SourceProber.ets');
  const { McVersionService } = fixture.load('feature_core/src/main/ets/version/McVersionService.ets');
  const browser = new McVersionService();
  sources.setMcSourcePreference('mirror');
  check('version browser cold peek does no I/O on network', [browser.peekVersionList(), calls.length], [null, 0]);
  seed(mirrorAddress, 'old-mirror');
  check('version browser expired mirror shown before refresh', [browser.peekVersionList().latest.release, calls.length], ['old-mirror', 0]);
  let finishMirror;
  replies.push(new Promise(resolve => { finishMirror = resolve; }));
  const first = browser.refreshVersionList(), overlapping = browser.refreshVersionList();
  check('version browser overlapping refresh shares real conditional request',
    calls.map(call => [call[0], call[3]]), [[mirrorAddress, { 'If-None-Match': '"seed"' }]]);
  finishMirror({ statusCode: 304, body: '', headers: {} });
  assert.strictEqual(await first, await overlapping);
  check('version browser 304 validates same-source expired snapshot', disk.get(cacheKey(mirrorAddress)).fresh, true);
  let finishOldRequest;
  replies.push(new Promise(resolve => { finishOldRequest = resolve; }));
  const oldRequest = browser.refreshVersionList();
  gateway = true;
  check('version browser gateway revokes displayed mirror even if still running', browser.peekVersionList(), null);
  const officialBody = seed(address, 'only-official');
  replies.push({ statusCode: 200, body: officialBody, headers: {} });
  check('version browser new policy starts independent official request',
    [(await browser.refreshVersionList()).latest.release, calls.at(-1)[0]], ['only-official', address]);
  replies.push({ statusCode: 200, body: officialBody, headers: {} });
  finishOldRequest({ statusCode: 304, headers: {}, body: '' });
  await assert.rejects(oldRequest, /来源已更改/);
  check('late request cannot replace official browser cache', browser.peekVersionList().latest.release, 'only-official');
  replies.push({ statusCode: 503, headers: {}, body: '' });
  await assert.rejects(browser.refreshVersionList(), /503/);
  check('version browser keeps cached rows after online failure', browser.peekVersionList().latest.release, 'only-official');
  replies.push({ statusCode: 503, headers: {}, body: '' });
  check('legacy version service still supports forced offline fallback',
    (await browser.getVersionList(true)).latest.release, 'only-official');
  replies.push({ statusCode: 304, headers: {}, body: '' },
    { statusCode: 200, headers: {}, body: JSON.stringify(manifest) });
  check('unsolicited 304 must retry full body', (await browser.refreshVersionList()).latest.release, 'fixture-0');
  check('version browser repairs unconditional 304 at original official source',
    calls.slice(-2).map(call => call[0]), [address, address]);
}
await verifyVersionBrowserCache();
const result={schema:'gateway-source-modes-host/v1',passed:cases.length,cases,metadataRequests:records.length};
if(out){fs.mkdirSync(path.dirname(path.resolve(out)),{recursive:true});fs.writeFileSync(out,JSON.stringify(result,null,2));}
console.log(JSON.stringify(result));
