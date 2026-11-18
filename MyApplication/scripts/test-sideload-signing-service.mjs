/** 执行真实授权请求边界：传输、HTTP、坏JSON均保留重试，只有认证失效才清登录。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import compiler from './lib/ets-compiler.mjs';

const root=path.resolve(import.meta.dirname,'..');
function fixture(response,saved){
 const modules=new Map(),calls=[],delays=[],signals=[];let destroyed=0;
 const state={saved,writes:0,failSave:false,saveGate:undefined};
 class InvalidCredential extends Error{}
 class Vault{
  async read(){return state.saved;}
  async save(value,current){if(state.saveGate)await state.saveGate;if(state.failSave)throw Error('storage fixture');if(current()){state.saved=structuredClone(value);state.writes++;}}
 }
 const load=relative=>{
  if(modules.has(relative))return modules.get(relative);
  const exports={},file=path.join(root,'entry/src/main/ets/sideload',relative+'.ets');
  const code=compiler.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
  vm.runInNewContext(code,{exports,require(name){
   if(name==='@kit.NetworkKit')return{http:{RequestMethod:{GET:'GET',POST:'POST'},HttpDataType:{STRING:0},createHttp:()=>({destroy(){destroyed++;},async request(url,options){calls.push({url,options});if(options.extraData==='')throw Object.assign(Error('Parameter error'),{code:401});if(response instanceof Error)throw response;return typeof response==='function'?response(url,options,calls):response;}})}};
   if(name==='@kit.ArkTS')return{util:{}};
   if(name==='./DeveloperAuthVault')return{DeveloperAuthVault:Vault,DeveloperCredentialInvalidError:InvalidCredential};
   if(name==='./SigningPreparationError')return load('SigningPreparationError');
   if(name==='./DeveloperAuthSession')return load('DeveloperAuthSession');
   throw Error('Unexpected module '+name);
  },Observed:value=>value,Date,console,setTimeout:(fn,ms)=>{delays.push(ms);return setTimeout(fn,0);},clearTimeout});modules.set(relative,exports);return exports;
 };
 const {DeveloperAuthSession:Auth}=load('DeveloperAuthSession'),auth=new Auth();
 // 模拟已通过官方授权的内存边界；所有值都是固定夹具，不读取设备/浏览器/真实账号。
 Object.assign(auth,{accessToken:'fixture-only',uid:'fixture-user',teams:['fixture-team'],authenticatedAt:Date.now(),jwtExpiresAt:Date.now()+60000});
 auth.initialize({filesDir:'/fixture'});auth.complete=(ok,message)=>signals.push({ok,message});
 return{auth,Auth,calls,state,delays,signals,newSession(){const next=new Auth();next.initialize({filesDir:'/fixture'});return next;},
  newSettingsModel(){const {DeveloperAccountViewModel:Model}=load('DeveloperAccountViewModel');const next=new Model();next.initialize({filesDir:'/fixture'});return next;},destroyed:()=>destroyed};
}
for(const [response,issue] of [
 [new Error('fixture network'),'service'],
 [Object.assign(new Error('private fixture detail must not escape'),{code:401}),'preparation'],
 [{responseCode:503,result:''},'service'],
 [{responseCode:403,result:''},'permission'],
 [{responseCode:200,result:'not JSON'},'response'],
 [{responseCode:200,result:'null'},'response'],
 [{responseCode:200,result:'{"ret":{}}'},'response'],
]){
 const f=fixture(response);await assert.rejects(f.auth.request('/api/cps/harmony-cert-manage/v1/cert/list','POST','fixture-team'),error=>error.issue===issue);
 assert.equal(f.auth.signedIn(),true);assert.equal(f.destroyed(),1);
}
/** 执行真实请求组装；模拟平台空正文拒绝，覆盖省略正文、空JSON和有内容JSON三条路径。 */
{
 const f=fixture({responseCode:200,result:'{"ret":{"code":0}}'});
 for(const method of ['GET','POST']){
  await f.auth.request('/api/cps/harmony-cert-manage/v1/cert/list',method,'fixture-team');
  assert.equal(Object.hasOwn(f.calls.at(-1).options,'extraData'),false);
 }
 await f.auth.request('/api/cps/harmony-cert-manage/v1/cert/list','POST','fixture-team',{});
 assert.equal(f.calls.at(-1).options.extraData,'{}');
 await f.auth.request('/api/cps/harmony-cert-manage/v1/cert/add','POST','fixture-team',{certName:'fixture'});
 assert.equal(f.calls.at(-1).options.extraData,'{"certName":"fixture"}');
 assert.equal(f.destroyed(),4);
 const local=fixture(Object.assign(new Error('private fixture detail must not escape'),{code:401}),{schema:1,jwt:'fixture',expiresAt:0,savedAt:1});
 await assert.rejects(local.auth.request('/api/cps/harmony-cert-manage/v1/cert/list','POST','fixture-team'),error=>
  error.issue==='preparation'&&!error.message.includes('private')&&!local.Auth.isExpired(error));
 assert.equal(local.calls.length,1);assert.equal(local.auth.signedIn(),true);assert.equal(local.state.writes,0);
}
{
 const f=fixture({responseCode:401,result:''});await assert.rejects(f.auth.request('/api/cps/harmony-cert-manage/v1/cert/list','POST','fixture-team'),error=>f.Auth.isExpired(error));
 assert.equal(f.auth.signedIn(),false);assert.equal(f.destroyed(),1);
}
{
 const f=fixture({responseCode:200,result:'{"list":[]}'});
 await f.auth.request('/api/cps/provision-manage/v1/provision/list?encodeFlag=0&start=1&pageSize=100','GET','fixture-team',undefined,'registered-app');
 assert.equal(f.calls[0].options.header.appId,'registered-app');
 await f.auth.request('/api/cps/provision-manage/v1/ide/test/provision/add','POST','fixture-team',{packageName:'com.amcl.launcher'});
 assert.equal(f.calls[1].options.header.appId,undefined);
}
console.log('PASS signing service: network/HTTP/schema classification, genuine expiry and profile request identity');

const cached={schema:1,jwt:'opaque-saved-jwt',expiresAt:1,savedAt:1};
const ok=body=>({responseCode:200,result:JSON.stringify(body)});
const teams=ok({teams:[{id:'fixture-team'}]});
const refreshed=ok({userId:'fixture-user',accessToken:'refreshed-access'});
const api='/api/cps/harmony-cert-manage/v1/cert/list';
const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return{promise,resolve};};
const settle=async()=>{for(let i=0;i<4;i++)await new Promise(r=>setImmediate(r));};

/** 真实restore不解析本地JWT/期限，只消费官方刷新和团队证据；不需要重新打开网页登录。 */
for(const body of [{userId:'server-user',accessToken:'refreshed-access'},
 {userInfo:{userId:'server-user',accessToken:'refreshed-access'}},
 {status:false,userInfo:{userId:'server-user',accessToken:'refreshed-access'}},
 {userId:'server-user',userInfo:{accessToken:'refreshed-access'}},
 {userId:12345,accessToken:'refreshed-access'}]){
 const f=fixture(url=>url.includes('jwToken/check')?ok(body):teams,structuredClone(cached));
 assert.equal(await f.auth.restore(),'valid');assert(f.auth.signedIn());assert.equal(f.state.writes,0);
 assert.equal(f.calls[0].options.header.refresh,'true');assert.equal(f.calls[0].options.header.jwtToken,cached.jwt);
 assert.equal(f.calls[1].options.header.uid,body.userId===12345?'12345':'server-user');
 f.auth.authenticatedAt=Date.now()-3600000;assert(f.auth.signedIn(),'no artificial five-minute login expiry');
 assert.deepEqual(f.state.saved,cached);f.auth.close();
}

/** 网络/坏响应有界重试并保留密文，明确401/失效响应才返回expired，仍不销毁原缓存。 */
for(const [response,expected,count] of [[{responseCode:503,result:''},'unavailable',3],
 [ok({status:true}),'unavailable',3],[ok(null),'unavailable',3],
 [{responseCode:401,result:''},'expired',1],[ok({status:false}),'expired',1],[ok({ret:{code:10001}}),'expired',1]]){
 const f=fixture(response,structuredClone(cached));assert.equal(await f.auth.restore(),expected);
 assert.equal(f.calls.length,count);assert.equal(f.state.writes,0);assert.deepEqual(f.state.saved,cached);
 assert.deepEqual(f.delays,count===3?[1000,1000]:[]);
}
{
 let checks=0;const f=fixture(url=>url.includes('jwToken/check')?(++checks<3?{responseCode:503,result:''}:refreshed):teams,structuredClone(cached));
 assert.equal(await f.auth.restore(),'valid');assert.equal(checks,3);assert.deepEqual(f.state.saved,cached);
}

/** 原始文本和JSON交换都可靠保存JWT后才通知成功；新对象可直接恢复这份本地授权。 */
for(const wrapped of [false,true]){
 const f=fixture(url=>url.includes('temptoken/check')?{responseCode:200,result:wrapped?JSON.stringify({jwtToken:'fresh-fixture-jwt'}):' fresh-fixture-jwt '}:
  url.includes('jwToken/check')?refreshed:teams);
 const gate=deferred();f.state.saveGate=gate.promise;
 const pending=f.auth.exchange('fixture-temp','1',f.auth.epoch);await settle();assert.equal(f.signals.length,0);
 gate.resolve();await pending;assert.equal(f.signals.at(-1).ok,true);assert.equal(f.state.saved.jwt,'fresh-fixture-jwt');assert.equal(f.state.saved.expiresAt,0);
 f.auth.close();const next=f.newSession();assert.equal(await next.restore(),'valid');assert.equal(f.state.writes,1);next.close();
}
{
 const f=fixture(url=>url.includes('temptoken/check')?{responseCode:200,result:'fresh-fixture-jwt'}:url.includes('jwToken/check')?refreshed:teams);
 f.state.failSave=true;await f.auth.exchange('fixture-temp','1',f.auth.epoch);
 assert.equal(f.signals.at(-1).ok,false);assert.equal(f.state.saved,undefined);
}

/** HTTP与业务认证失效只重发一次，业务配额错误不刷新或清登录。 */
for(const expiry of [{responseCode:401,result:''},ok({ret:{code:10001}}),ok({ret:{code:10002}})]){
 let requests=0;const f=fixture((url,opts)=>url.includes('jwToken/check')?refreshed:url.includes('user-team-list')?teams:++requests===1?expiry:ok({certList:[]}));
 f.auth.jwt=cached.jwt;const result=await f.auth.request(api,'POST','fixture-team');assert(Array.isArray(result.certList));assert.equal(requests,2);
 assert.equal(f.calls.filter(c=>c.url.includes('jwToken/check')).length,1);
}
{
 const f=fixture(ok({ret:{code:205389872}}));f.auth.jwt=cached.jwt;
 await assert.rejects(f.auth.request(api,'POST','fixture-team'),e=>e.issue==='service');assert.equal(f.calls.length,1);assert(f.auth.signedIn());
}
{
 const f=fixture(url=>url.includes('jwToken/check')?refreshed:url.includes('user-team-list')?teams:{responseCode:401,result:''});f.auth.jwt=cached.jwt;
 await assert.rejects(f.auth.request(api,'POST','fixture-team'),e=>f.Auth.isExpired(e));
 assert.equal(f.calls.filter(c=>c.url.includes('/cert/list')).length,2);assert.equal(f.calls.filter(c=>c.url.includes('jwToken/check')).length,1);
}

/** 并发和迟到401不反复刷新；取消/换会话后不能把旧请求重发到新账号。 */
{
 const gate=deferred();const f=fixture((url,opts)=>url.includes('jwToken/check')?gate.promise:url.includes('user-team-list')?teams:
  opts.header.oauth2Token==='fixture-only'?{responseCode:401,result:''}:ok({certList:[]}));f.auth.jwt=cached.jwt;
 const pending=Promise.all([f.auth.request(api,'POST','fixture-team'),f.auth.request(api,'POST','fixture-team')]);await settle();gate.resolve(refreshed);await pending;
 assert.equal(f.calls.filter(c=>c.url.includes('jwToken/check')).length,1);
}
for(const accessToken of ['refreshed-access','fixture-only']){
 const late=deferred();let firstOld=0,renewed=false;
 const f=fixture((url,opts)=>{
  if(url.includes('jwToken/check')){renewed=true;return ok({userId:'fixture-user',accessToken});}
  if(url.includes('user-team-list'))return teams;
  return !renewed?(++firstOld===1?late.promise:{responseCode:401,result:''}):ok({certList:[]});
 });f.auth.jwt=cached.jwt;
 const first=f.auth.request(api,'POST','fixture-team');await f.auth.request(api,'POST','fixture-team');late.resolve({responseCode:401,result:''});await first;
 assert.equal(f.calls.filter(c=>c.url.includes('jwToken/check')).length,1);assert(f.auth.signedIn());
}
{
 const f=fixture(url=>url.includes('jwToken/check')?ok({userId:'foreign-user',accessToken:'foreign-access'}):url.includes('user-team-list')?teams:{responseCode:401,result:''});
 f.auth.jwt=cached.jwt;await assert.rejects(f.auth.request(api,'POST','fixture-team'),e=>e.issue==='response');
 assert.equal(f.auth.uid,'fixture-user');assert.equal(f.auth.jwt,cached.jwt);assert.equal(f.auth.accessToken,'');
 assert.equal(f.calls.filter(c=>c.url.includes('/cert/list')).length,1);
 assert.equal(f.calls.filter(c=>c.url.includes('user-team-list')).length,0,'foreign identity cannot obtain a team or replay a write');
}
{
 const gate=deferred();const f=fixture(url=>url.includes('jwToken/check')?gate.promise:{responseCode:401,result:''});f.auth.jwt=cached.jwt;
 const pending=f.auth.request(api,'POST','fixture-team');await settle();f.auth.close();
 Object.assign(f.auth,{accessToken:'new-session-access',uid:'new-session-user',teams:['new-team'],authenticatedAt:Date.now(),jwt:'new-session-jwt'});
 gate.resolve(refreshed);await assert.rejects(pending);assert.equal(f.auth.uid,'new-session-user');assert.equal(f.auth.accessToken,'new-session-access');
 assert.equal(f.calls.filter(c=>c.url.includes('/cert/list')).length,1);
}
console.log('PASS actual auth reuse: flat/nested identities, raw/JSON exchange, cold restore, retained cache, bounded read retries and single-flight token refresh');

/** 设置入口执行同一真实AuthSession：本地有记录不冒称有效，网络故障不清登录。 */
for(const [saved,response,expected,label] of [
 [cached,url=>url.includes('jwToken/check')?refreshed:teams,'valid','已登录'],
 [undefined,refreshed,'missing','登录'],
 [cached,{responseCode:503,result:''},'unavailable','重试'],
 [cached,{responseCode:401,result:''},'expired','重新登录']
]){
 const f=fixture(response,saved),model=f.newSettingsModel();model.active=true;await model.check();
 assert.equal(model.state,expected);assert.equal(model.statusText(),label);assert.equal(f.state.writes,0);
 assert.deepEqual(f.state.saved,saved);model.deactivate();
}

/** 用真实exchange完成可靠保存，再以独立更新会话restore，证明设置登录可直接供更新使用。 */
{
 const f=fixture(url=>url.includes('temptoken/check')?{responseCode:200,result:'settings-jwt'}:
  url.includes('jwToken/check')?refreshed:teams);
 const model=f.newSettingsModel();model.active=true;await model.check();assert.equal(model.state,'missing');
 const begin=deferred();model.auth.begin=async callback=>{model.auth.complete=callback;return begin.promise;};
 const login=model.login();assert(model.loginVisible);
 await model.auth.exchange('fixture-temp','1',model.auth.epoch);
 assert.equal(f.state.saved.jwt,'settings-jwt');assert.equal(model.state,'valid');assert.equal(model.loginVisible,false);
 begin.resolve('https://fixture.example/late-login-url');await login;
 assert.equal(model.loginVisible,false);assert.equal(model.loginUrl,'','late begin must not reopen completed sheet');
 const updater=f.newSession();assert.equal(await updater.restore(),'valid');assert(updater.signedIn());
 assert.equal(f.calls.some(c=>c.url.includes('/api/cps/')),false,'settings login never prepares signing or installs');
 updater.close();model.deactivate();
}

/** 关闭或路由隐藏会撤销旧回调，但不清此前凭据；重新显示后的检查不受迟到结果覆盖。 */
{
 const f=fixture(refreshed,structuredClone(cached)),model=f.newSettingsModel(),begin=deferred();let callback;
 model.active=true;model.auth.begin=async value=>{callback=value;return begin.promise;};
 const pending=model.login();model.closeLogin();begin.resolve('https://fixture.example/cancelled');await pending;
 callback(true,'late fixture');assert.equal(model.loginVisible,false);assert.equal(model.state,'unavailable');
 assert.deepEqual(f.state.saved,cached);assert.equal(f.state.writes,0);model.deactivate();
}
{
 const first=deferred();let checks=0;
 const f=fixture(url=>url.includes('jwToken/check')?(++checks===1?first.promise:refreshed):teams,cached);
 const model=f.newSettingsModel();model.activate();await settle();model.deactivate();model.activate();await settle();
 assert.equal(model.state,'valid');first.resolve({responseCode:503,result:''});await settle();
 assert.equal(model.state,'valid');assert.equal(model.checking,false);assert.equal(model.loginVisible,false);model.deactivate();
}
console.log('PASS settings account: saved authorization shared with updater, no auto-update, missing/expired/network states, cancellation and late callback guards');
