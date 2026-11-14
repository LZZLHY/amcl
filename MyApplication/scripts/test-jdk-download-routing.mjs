/** 执行生产JDK组计划和竞速排序；平台Native测量是显式边界，不重写选路算法。 */
import assert from 'node:assert/strict';
import {loader} from './mod-install-test-runtime.mjs';
const R=loader({})('launch/src/main/ets/JdkDownloadRouting.ets');
const archive={type:'zip',fileName:'jdk21-ohos-full-v7.zip',sizeBytes:114267146,sha256:'2'.repeat(64)};
const github={sourceId:'github',transport:'single-file',url:'https://github.com/LZZLHY/mc-ohos-resources/releases/download/v7/'+archive.fileName};
const gitee={sourceId:'gitee',transport:'concat-parts',parts:[{url:'https://gitee.com/publisher/part1',sizeBytes:38089048,sha256:'3'.repeat(64)},{url:'https://gitee.com/publisher/part2',sizeBytes:76178098,sha256:'4'.repeat(64)}]};
const web={sourceId:'web',transport:'single-file',url:'https://amcl.lovedhy.cn/runtimes/packages/'+archive.fileName};
const downloads=[github,gitee,web];const build={id:'real-shape',archive,downloads};
const plain=v=>JSON.parse(JSON.stringify(v));let passed=0;
/** 每例断言候选本身，不能只凭用户设置或来源标签推断实际URL。 */
function check(name,run){run();passed++;console.log('PASS '+name);}
function plan(preference='auto',enabled=false,gateway=false,b=build,d=downloads){return R.buildJdkDownloadRoutes(d,archive,b,preference,enabled,gateway);}
check('gateway uses official canonical cache then official origin, never a mirror',()=>{
 const result=plan('auto',false,true);assert.deepEqual(plain(result.map(r=>r.key)),['gateway-cache','gateway-origin']);
 assert.ok(result.every(r=>r.canonicalSource==='github'&&!r.probe&&r.githubPreference==='github'));
 assert.equal(result[0].source.url,web.url);assert.equal(result[1].source.url,github.url);
});
check('gateway route does not alter independent opt-in or saved preference',()=>{for(const p of ['auto','github','gitee','mirror','web'])assert.deepEqual(plain(plan(p,false,true).map(r=>r.key)),['gateway-cache','gateway-origin']);assert.equal(downloads[2].sourceId,'web');});
check('explicit origin without gateway stays only origin even with web enabled',()=>{const result=plan('github',true);assert.deepEqual(plain(result.map(r=>r.key)),['github-origin']);assert.equal(result[0].source.url,github.url);assert.equal(result[0].probe,false);});
check('explicit mirror keeps mirror arm and does not race',()=>{const result=plan('mirror');assert.equal(result.length,1);assert.equal(result[0].githubPreference,'mirror');assert.equal(result[0].probe,false);});
check('independent web without opt-in is unavailable',()=>assert.equal(plan('web').length,0));
check('independent web opt-in works without gateway',()=>assert.deepEqual(plain(plan('web',true).map(r=>r.key)),['web']));
check('automatic mode races actual origin and concat-group representative',()=>{const result=plan();assert.deepEqual(plain(result.map(r=>r.key)),['gitee','github-origin','github-mirror']);assert.equal(R.jdkRouteProbePart(result[0],archive).sizeBytes,gitee.parts[0].sizeBytes);assert.equal(R.jdkRouteProbePart(result[1],archive).sizeBytes,archive.sizeBytes);});
check('only independently enabled web joins automatic race',()=>assert.deepEqual(plain(plan('auto',true).filter(r=>r.probe).map(r=>r.key)),['gitee','github-origin','web']));
check('origin-only catalog races one exact proxy transport without measuring one URL then downloading another',()=>{
 const routes=R.buildJdkDownloadRoutes([github],archive,{...build,downloads:[github]},'auto',false,false,['https://mirror.example/{url}','{url}']);
 const proxy=routes.find(r=>r.key==='github-proxy-sample');assert.ok(proxy);
 assert.equal(R.jdkRouteProbePart(proxy,archive).url,'https://mirror.example/'+github.url);
 assert.equal(proxy.githubTemplate,'https://mirror.example/{url}');
});
check('unbound archive cannot authorize a first-party gateway alias',()=>assert.deepEqual(plain(plan('auto',false,true,{...build,archive:{...archive,sha256:'9'.repeat(64)}}).map(r=>r.key)),['gateway-origin']));
check('no signed build cannot authorize alias',()=>assert.deepEqual(plain(R.buildJdkDownloadRoutes(downloads,archive,undefined,'auto',false,true).map(r=>r.key)),['gateway-origin']));
for(const url of ['https://amcl.lovedhy.cn.author.example/runtimes/packages/'+archive.fileName,web.url+'?token=x','https://amcl.lovedhy.cn/runtimes/packages/other.zip']){
 check('cache exact host/path identity '+url,()=>{const d=[github,gitee,{...web,url}];assert.deepEqual(plain(plan('auto',false,true,{...build,downloads:d},d).map(r=>r.key)),['gateway-origin']);});
}
check('configured unofficial origin cannot grant canonical cache or gateway identity',()=>{const d=[{...github,url:'https://github.com/other/repo/download/file'},gitee,web];assert.equal(plan('auto',false,true,{...build,downloads:d},d).length,0);});
/** 测量字段由Native合同给出；真实网络/时间/Range正反另由Native socket套件覆盖。 */
const measurement=(elapsedMs,extra={})=>({httpStatus:206,receivedBytes:262144,elapsedMs,ttfbMs:10,completedSample:true,rangeHonored:true,errorKind:'',...extra});
async function rank(origin,mirror,options={}){
 const calls=[],seen=[];const result=await R.rankJdkDownloadRoutes(plan(),archive,async(url,size)=>{calls.push({url,size});return url===github.url?origin:mirror;},options.current??(()=>true),(route,value)=>seen.push({key:route.key,value}));
 return {result,calls,seen};
}
let race=await rank(measurement(700,{ttfbMs:500}),measurement(3000,{ttfbMs:5}));
assert.equal(race.result[0].key,'github-origin');assert.equal(race.calls.length,2);passed++;console.log('PASS faster official body beats mirror fast first-byte');
race=await rank(measurement(3000),measurement(300));assert.equal(race.result[0].key,'gitee');passed++;console.log('PASS faster mirror body wins in domestic automatic path');
race=await rank(measurement(520,{ttfbMs:500}),measurement(150,{ttfbMs:50}));assert.equal(race.result[0].key,'github-origin');passed++;console.log('PASS high RTT fast official body wins despite slower small-sample completion');
race=await rank(measurement(1000),measurement(980));assert.equal(race.result[0].key,'github-origin');passed++;console.log('PASS near tie prefers origin without hard-coding VPN state');
race=await rank(measurement(1,{httpStatus:200,receivedBytes:100,completedSample:false,errorKind:'InvalidResponse'}),measurement(900));assert.equal(race.result[0].key,'gitee');passed++;console.log('PASS fast HTML/error/partial response is not a winning sample');
const fallback=await R.rankJdkDownloadRoutes(plan(),archive,async()=>{throw new Error('ProbeDeadlineExceeded');},()=>true,()=>{});assert.equal(fallback[0].key,'github-mirror');passed++;console.log('PASS bounded probe failure keeps explicit compatible fallback without manufacturing a winner');
let current=true,observed=0;await assert.rejects(R.rankJdkDownloadRoutes(plan(),archive,async()=>{current=false;return measurement(1);},()=>current,()=>observed++),/取消|改变/);assert.equal(observed,0);passed++;console.log('PASS revoked observer publishes neither winner nor measurement');
console.log(JSON.stringify({passed}));
