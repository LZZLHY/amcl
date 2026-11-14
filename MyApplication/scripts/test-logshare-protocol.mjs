// 实际 LogShare 新旧协议、凭据与历史 SSE 解析回归；所有网络均为可控边界，绝不外发用户日志。
import assert from 'node:assert/strict';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';
const mocks = {};
const fixture = evidenceRuntime({ imports: mocks });
const load = fixture.load;
try {
  const PRIMARY = 'https://api.logshare.cn', BACKUP = 'https://amcl.lovedhy.cn/logshare-api';
  const MiB = 1024 * 1024;
  const officialLimits = { maxFiles: 200, maxTotalBytes: 20 * MiB, maxRequestBodyBytes: 32 * MiB, storageTime: 1296000 };
  const legacyLimits = { maxLength: 10 * MiB, maxLines: 50000, storageTime: 604800 };
  let limitsOverride;
  let response;
  let readbackResponse;
  let lastRequest;
  let requestError;
  let officialDown = false, backupDown = false, primaryUploadDown = false;
  let saved = '', failSave = false;
  fixture.control.failWrite = name => failSave && name.includes('share-records');
  const calls = [];
  const successFor = url => ({ responseCode: 200, result: JSON.stringify({ success: true, id: 'abc1234', url: url.startsWith(BACKUP) ? 'https://amcl.lovedhy.cn/logshare/abc1234' : 'https://logshare.cn/abc1234', raw: url.replace(/\/log$/, '/raw/abc1234'), token: 'delete-credential' }) });
  mocks['@kit.NetworkKit'] = { http: {
    RequestMethod: { POST: 'POST', GET: 'GET', DELETE: 'DELETE' },
    createHttp() {
      return {
        async request(url, options) {
          lastRequest = { url, ...options }; calls.push(lastRequest);
          if (requestError) throw requestError;
          if ((officialDown && url.startsWith(PRIMARY)) || (backupDown && url.startsWith(BACKUP))) throw Object.assign(new Error('offline'), {code:2300007});
          if (url.endsWith('/limits')) {
            return { responseCode: 200, result: JSON.stringify(limitsOverride
              ?? (url.startsWith(PRIMARY) ? officialLimits : legacyLimits)) };
          }
          if (primaryUploadDown && url === PRIMARY+'/v1/log') return {responseCode:503,result:JSON.stringify({error:'unavailable',code:503})};
          if (readbackResponse && options.method === 'GET') return readbackResponse(url, options);
          if (response) return response;
          if (options.method === 'DELETE') return {responseCode:200,result:JSON.stringify({success:true,deleted:url.split('/').pop().split(','),failed:[]})};
          return successFor(url);
        },
        async requestInStream(url, options) {
          calls.push({url,...options});
          throw new Error('已下架 AI 不应创建流式网络请求');
        },
        destroy() {}
      };
    }
  } };
  mocks['@kit.ArkData'] = { preferences: { async getPreferences() { return { async get() { return saved; }, async put(key, value) { if (failSave) throw new Error('disk full'); saved = value; }, async flush() {} }; } } };
  mocks['@kit.AbilityKit'] = { bundleManager: { BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0 }, getBundleInfoForSelfSync() { return { versionName: '1.2.3-test' }; } } };
  const client = load('entry/src/main/ets/components/LogShareClient.ets');
  const meta = { launcher:'AMCL', appVersion:'', mcVersion:'1.21.11', loader:'Fabric', jdk:'21', device:'fixture', osVersion:'HarmonyOS',
    outcome:'failed', activityId:7, snapshot:'digest-fixture', environmentSchema:'1' };
  let routed = await client.submitLog('synthetic test log', 'amcl-launcher', meta);
  assert.equal(routed.ok, true);
  assert.equal(routed.apiBaseUrl, PRIMARY);
  assert.equal(routed.usedFallback, false);
  assert.equal(routed.storageTimeSec, 1296000);
  assert.equal(calls.filter(call=>call.url.startsWith(BACKUP)).length, 0, 'primary success never touches backup');
  assert.equal(lastRequest.readTimeout, 10000, '远端清单只读核对使用短超时，不阻塞生成链接');
  const uploadRequest = calls.find(call=>call.method==='POST');
  assert.equal(uploadRequest.readTimeout, 300000, '上传仍遵循长读超时');
  assert.equal(JSON.parse(uploadRequest.extraData).source, 'amcl/1.2.3-test');
  assert.equal(Object.hasOwn(JSON.parse(uploadRequest.extraData),'content'),false,'新旧实例统一只上传 files，不重复发送兼容 content');
  const metadata = JSON.parse(uploadRequest.extraData).metadata;
  assert(Array.isArray(metadata));
  assert.equal(metadata.find(item=>item.key==='version').value,'1.21.11');
  assert.equal(metadata.some(item=>item.key==='mcVersion'),false,'公开 Minecraft 版本使用平台约定的 version key');
  assert(metadata.every(item=>typeof item.label==='string'&&item.label.length>0&&typeof item.visible==='boolean'));
  for(const key of ['activityId','snapshot','environmentSchema']) assert.equal(metadata.find(item=>item.key===key).visible,false);
  assert.equal(metadata.find(item=>item.key==='version').visible,true);
  const current = await client.getLimits(PRIMARY), legacy = await client.getLimits(BACKUP);
  assert.equal(current.ok,true); assert.equal(current.maxBytes,Number.MAX_SAFE_INTEGER); assert.equal(current.maxLines,Number.MAX_SAFE_INTEGER);
  assert.equal(current.maxFiles,200); assert.equal(current.maxTotalBytes,20*MiB); assert.equal(current.maxRequestBodyBytes,32*MiB);
  assert.equal(legacy.ok,true); assert.equal(legacy.maxBytes,10*MiB); assert.equal(legacy.maxLines,50000);
  assert.equal(legacy.maxFiles,200); assert.equal(legacy.maxTotalBytes,12*MiB); assert.equal(legacy.maxRequestBodyBytes,20*MiB);
  assert.equal(client.logShareExportBudgetBytes(current),20*MiB); assert.equal(client.logShareExportBudgetBytes(legacy),12*MiB);
  // 新模型中任意一个字段错误都不能偷偷降级为“无限制”；旧模型仍须完整且类型正确。
  for (const invalid of [
    {...officialLimits,maxFiles:'200'}, {...officialLimits,maxTotalBytes:0}, {...officialLimits,maxRequestBodyBytes:1.5},
    {...officialLimits,maxRequestBodyBytes:undefined}, {...officialLimits,storageTime:-1},
    {...legacyLimits,maxLength:'10485760'}, {...legacyLimits,maxLines:0},
  ]) { limitsOverride=invalid; assert.equal((await client.getLimits()).ok,false,JSON.stringify(invalid)); }
  limitsOverride=undefined;

  calls.length = 0; officialDown = true;
  routed = await client.submitLog('synthetic', 'test', {...meta,activityId:123,snapshot:'internal-snapshot',environmentSchema:'1'});
  assert.equal(routed.ok, true); assert.equal(routed.apiBaseUrl, BACKUP); assert.equal(routed.usedFallback, true);
  assert.equal(routed.storageTimeSec,604800);
  assert.equal(calls.filter(call=>call.url===PRIMARY+'/v1/log').length,0,'failed preflight does not upload');
  assert.equal(calls.filter(call=>call.method==='POST').length,1);
  const backupMetadata=JSON.parse(calls.find(call=>call.method==='POST').extraData).metadata;
  assert(backupMetadata.every(item=>item.visible!==false),'旧实例不发送隐藏元数据，避免依赖其可见性实现');
  assert(!backupMetadata.some(item=>['activityId','snapshot','environmentSchema'].includes(item.key)));
  backupDown = true;
  routed = await client.submitLog('synthetic','test');
  assert.equal(routed.ok,false); assert.equal(routed.error,'日志分享暂不可用');
  assert.equal(routed.attempts.length,2); assert(routed.attempts.every(attempt=>attempt.networkCode===2300007));
  officialDown = false; backupDown = false; calls.length = 0;
  routed = await client.submitLog('synthetic','test');
  assert.equal(routed.apiBaseUrl,PRIMARY,'recovery always retries primary');
  assert.equal(calls.some(call=>call.url.startsWith(BACKUP)),false);
  primaryUploadDown = true;
  routed = await client.submitLog('synthetic','test');
  assert.equal(routed.apiBaseUrl,PRIMARY,'POST failures never cross instances automatically');
  assert.equal(routed.ok,false);
  primaryUploadDown = false;

  response = {responseCode:400,result:JSON.stringify({error:'Required content',code:'MISSING_CONTENT'})}; calls.length = 0;
  routed = await client.submitLog('synthetic','test');
  assert.equal(routed.httpStatus,400); assert.equal(routed.apiCode,'MISSING_CONTENT'); assert.equal(routed.errorStage,'http');
  assert.equal(calls.some(call=>call.url.startsWith(BACKUP)),false,'bad input is not a service outage');
  response = {responseCode:429,result:JSON.stringify({error:'too many',code:429})};
  routed = await client.submitLog('synthetic','test');
  assert.equal(routed.httpStatus,429);
  assert.equal(routed.ok,false);
  response = {responseCode:200,result:JSON.stringify({success:true,id:'abc1234',url:'https://logshare.cn/abc1234'})};
  routed = await client.submitLog('synthetic','test');
  assert.equal(routed.ok,false,'missing credentials cannot look successful');
  response = {responseCode:200,result:JSON.stringify({success:true,id:'abc1234',url:'https://logshare.cn/abc1234',token:'discard-this-token',deduplicated:true})};
  routed = await client.submitLog('synthetic','test');
  assert.equal(routed.ok,true,'去重命中的分享链接仍有效'); assert.equal(routed.token,''); assert.equal(routed.deduplicated,true);
  response = undefined;
  requestError = Object.assign(new Error('Internal error'),{code:2300999});
  for (const failed of [await client.getLimits(),await client.deleteLogs(['abc1234'],'test')]) {
    assert.equal(failed.networkCode,2300999); assert.equal(failed.httpStatus,undefined);
    assert.match(failed.error,/NetworkKit 2300999/);
  }
  requestError = undefined;

  const shares = Array.from({length:101},(_,n)=>({activityId:n,id:'logtest'+n,url:'https://logshare.cn/logtest'+n,token:'test',sharedAt:Date.now(),versionId:'test'}));
  await Promise.all(shares.map(rec=>client.addShareRecord(fixture.context,rec)));
  assert.equal((await client.loadShareRecords(fixture.context)).length,101);
  failSave = true; await assert.rejects(client.addShareRecord(fixture.context,shares[0]),/保存失败/); failSave = false;
  assert.equal((await client.revokeShare(fixture.context,shares[0])).ok,true);
  assert.equal(lastRequest.url,PRIMARY+'/v1/log/logtest0');
  assert.equal((await client.loadShareRecords(fixture.context)).length,100);
  const primarySame = {id:'sameID1',url:'https://logshare.cn/sameID1',token:'official-secret',sharedAt:Date.now(),versionId:'test'};
  const backupSame = {id:'sameID1',url:'https://amcl.lovedhy.cn/logshare/sameID1',token:'backup-secret',sharedAt:Date.now(),versionId:'test'};
  await client.addShareRecord(fixture.context,primarySame); await client.addShareRecord(fixture.context,backupSame);
  assert.equal((await client.loadShareRecords(fixture.context)).filter(rec=>rec.id==='sameID1').length,2);
  await client.revokeShare(fixture.context,backupSame);
  assert.equal(lastRequest.url,BACKUP+'/v1/log/sameID1'); assert.equal(lastRequest.header.Authorization,'Bearer backup-secret');
  assert.equal((await client.loadShareRecords(fixture.context)).filter(rec=>rec.id==='sameID1').length,1);
  // 同实例去重返回的新 token 无删除权，不能覆盖首次上传时已持久化的凭据。
  await client.addShareRecord(fixture.context,{...primarySame,token:'',deduplicated:true,sharedAt:Date.now()+1});
  assert.equal((await client.loadShareRecords(fixture.context)).find(rec=>rec.id==='sameID1').token,'official-secret');
  const unowned={id:'unowned',url:'https://logshare.cn/unowned',token:'',deduplicated:true,sharedAt:Date.now(),versionId:'test'};
  await client.addShareRecord(fixture.context,unowned); calls.length=0;
  assert.equal((await client.revokeShare(fixture.context,unowned)).ok,false);
  assert.equal(calls.length,0,'没有删除权的去重记录不能发 DELETE');
  // 同 ID 的去重接收可以复用 token，但旧一代核验不能覆盖新快照或广播旧活动结果。
  const replacement={...unowned,sharedAt:unowned.sharedAt+1,activityId:222,snapshotDigest:'new-snapshot'};
  await client.addShareRecord(fixture.context,replacement);
  assert.equal(await client.updateShareVerification(fixture.context,unowned,{verified:true,warning:'old result'}),false);
  assert.equal(await client.updateShareVerification(fixture.context,replacement,{verified:true,warning:'current result'}),true);
  calls.length=0;
  assert.equal((await client.revokeShare(fixture.context, {...primarySame,apiBaseUrl:BACKUP})).ok,false);
  assert.equal(calls.length,0,'mismatched provenance never sends a credential');

  const runStream = (base = PRIMARY) => new Promise(resolve => {
    let answer='',done=0;
    client.streamAiAnalysis('abc1234',{
      onDelta(text){answer+=text;},onDone(text){done++;resolve({answer,text,done});},
      onError(error){resolve({answer,error,done});}
    },base);
  });
  // 线上生成式 AI 已下架：官方与备用都在本地明确拒绝，绕过 UI 也不能触发请求。
  calls.length=0;
  for (const base of [PRIMARY,BACKUP]) {
    const unavailable=await runStream(base);
    assert.equal(unavailable.error,client.LOGSHARE_AI_UNAVAILABLE); assert.equal(unavailable.done,0); assert.equal(unavailable.answer,'');
  }
  assert.equal(calls.length,0,'下架的 AI 入口零网络请求');
  assert.equal(client.logShareSupportsAi('https://logshare.cn/abc1234'),false);
  assert.equal(client.logShareSupportsAi('https://amcl.lovedhy.cn/logshare/abc1234'),false);
  const parserModule=load('entry/src/main/ets/components/LogShareSse.ets');
  let errorMessage='',completion=0;
  const parser=new parserModule.LogShareSseParser({onDelta(){},onDone(){completion++;},onError(message){errorMessage=message;}});
  parser.feed('event: error\r\ndata: {"message":"queue failed"}\r\n\r\n');
  assert.equal(errorMessage,'queue failed'); assert.equal(completion,0);

  // 官方全部状态事件、未知命名事件隔离和多种换行均走实际生产解析器。
  const parse = (chunks) => {
    const out = {answer:'',done:0,error:'',statuses:[]};
    const p = new parserModule.LogShareSseParser({onDelta(t){out.answer+=t;},onDone(t){out.done++;out.full=t;},
      onError(e){out.error=e;},onStatus(s,n){out.statuses.push([s,n]);}});
    for (const chunk of chunks) p.feed(chunk);
    p.end(); return out;
  };
  const publicFrame='data: {"choices":[{"delta":{"content":"中文结论"}}]}\n\n';
  const doneFrame='event: done\ndata: {"status":"completed"}\n\n';
  const statuses=['queued','thinking','tool','tool_result','limit'].map(type=>
    'event: status\ndata: '+JSON.stringify({type,position:3,summary:'内部工具结果',choices:[{delta:{content:'不能显示'}}]})+'\n\n').join('');
  const unknown='event: private\ndata: {"choices":[{"delta":{"content":"不能显示"}}]}\n\n';
  for(const ending of ['\n','\r\n','\r']) {
    const out=parse(Array.from(('\uFEFF'+statuses+unknown+publicFrame+doneFrame+doneFrame).replaceAll('\n',ending)));
    assert.equal(out.answer,'中文结论'); assert.equal(out.done,1); assert.equal(out.error,'');
    assert.deepEqual(out.statuses,[['queued',3],['analyzing',0],['analyzing',0],['analyzing',0],['limit',0]]);
  }
  assert.match(parse([publicFrame+doneFrame.trimEnd()]).error,/中断/,'半截终态帧不能靠 EOF 补齐');
  assert.equal(parse([publicFrame+doneFrame.trimEnd()]).done,0);
  assert.match(parse(['data: x\n'.repeat(140000)]).error,/单帧过大/,'累计短行必须有界');
  assert.equal(parse([': heartbeat\n\n'.repeat(90000)+publicFrame+doneFrame]).done,1,'同一网络块的许多小帧不触发误限额');
  assert.equal(parse([publicFrame+'event: error\n\n'+doneFrame]).done,0);

  console.log('PASS retired AI makes no requests; historical SSE parser retains status isolation, CR/LF/BOM, fragmented UTF-8 and bounded frames');
  // 新接口分别限制正文总量与 JSON 请求体；利用小动态限额核对转义膨胀，不生成大夹具。
  calls.length=0;
  const newPlan = {apiBaseUrl:PRIMARY,checkedAt:Date.now(),attempts:[],limits:current};
  const tinyBodyPlan={...newPlan,limits:{...current,maxTotalBytes:2048,maxRequestBodyBytes:1024}};
  const oversized=await client.submitLogFiles([{name:'launcher/launcher-host.log',content:'"'.repeat(600)}],'test',undefined,tinyBodyPlan);
  assert.equal(oversized.ok,false);assert.equal(oversized.errorStage,'local-prepare');
  assert.equal(calls.filter(c=>c.method==='POST').length,0);
  // 多文件 200 响应是选择清单；客户端不能把它当成“零问题”的有效分析。
  const selectedName='crash-reports/测试 日志 #1.txt';
  response={responseCode:200,result:JSON.stringify({success:true,id:'abc1234',fileCount:2,requiresFileSelection:true,
    files:[{name:'latest.log'},{name:selectedName}]})};
  const selection=await client.getInsights('abc1234',PRIMARY);
  assert.equal(selection.ok,false); assert.equal(selection.requiresFileSelection,true);
  assert.deepEqual(selection.files,['latest.log',selectedName]); assert.match(selection.error,/选择/);
  response={responseCode:200,result:JSON.stringify({id:'vanilla/client',name:'Vanilla',type:'Client Log',version:'1.21.11',
    analysis:{problems:[{message:'Synthetic problem',counter:1,solutions:[]}],information:[]}})};
  const insight=await client.getInsights('abc1234',PRIMARY,selectedName);
  assert.equal(insight.ok,true); assert.equal(insight.name,'Vanilla');
  assert.equal(lastRequest.url,PRIMARY+'/v1/insights/abc1234/'+selectedName.split('/').map(encodeURIComponent).join('/'));
  response=undefined;
  // GET 元数据返回空 files 不能用“少一项”推断主文件已收到；缺失状态只保留为未核验。
  calls.length=0; response={responseCode:200,result:JSON.stringify({id:'abc1234',files:[]})};
  const missingFiles=await client.verifyLogShareFiles('abc1234',['launcher/launcher-host.log'],PRIMARY);
  assert.equal(missingFiles.verified,false); assert.equal(calls.length,1);
  response=undefined;
  // 已收到 HTTP 响应时只按真实语义处理：限流、删除和形状错误不会自动重读。
  for (const code of [202, 400, 403, 404, 409, 425, 429]) {
    calls.length=0;
    response={responseCode:code,result:JSON.stringify({error:'synthetic read refusal'})};
    assert.equal((await client.verifyLogShareFiles('abc1234',['game/a.log'],PRIMARY)).verified,false);
    assert.equal(calls.length,1,'HTTP '+code+' must not be retried or reuploaded');
  }
  for (const files of [[], [{name:'main'}], [{name:'game/a.log'},{name:'game/a.log'}], null, {}]) {
    calls.length=0; response={responseCode:200,result:JSON.stringify({id:'abc1234',files})};
    assert.equal((await client.verifyLogShareFiles('abc1234',['game/a.log'],PRIMARY)).verified,false);
    assert.equal(calls.length,1,'malformed or missing files do not fabricate success');
  }
  response=undefined;
  const expectedFile='game/a.log';
  const fileList={responseCode:200,result:JSON.stringify({id:'abc1234',files:[{name:expectedFile}]})};
  let reads=0;
  readbackResponse=()=>++reads < 3 ? {responseCode:503,result:'temporarily unavailable'} : fileList;
  calls.length=0;
  assert.equal((await client.verifyLogShareFiles('abc1234',[expectedFile],PRIMARY)).verified,true);
  assert.equal(reads,3); assert(calls.every(call=>call.method==='GET'));
  reads=0;
  readbackResponse=()=>{ reads++; throw Object.assign(new Error('offline'),{code:2300007}); };
  assert.equal((await client.verifyLogShareFiles('abc1234',[expectedFile],PRIMARY)).verified,false);
  assert.equal(reads,3,'transport retry terminates at its budget');
  reads=0;
  const crypto=await import('node:crypto');
  const sha=text=>crypto.createHash('sha256').update(text).digest('hex');
  const receipts=[{name:expectedFile,bytes:4,sha256:sha('body')}];
  readbackResponse=url=>url.includes('/v1/log/') ? fileList
    : ++reads < 2 ? {responseCode:503,result:'temporary'} : {responseCode:200,result:'body'};
  const readback=await client.verifyLogShareContents('abc1234',receipts,PRIMARY);
  assert.equal(readback.contentStatus,'content-verified'); assert.equal(reads,2);
  reads=0;
  readbackResponse=url=>url.includes('/v1/log/') ? fileList
    : (reads++,{responseCode:429,result:'limit'});
  assert.equal((await client.verifyLogShareContents('abc1234',receipts,PRIMARY)).contentStatus,'unavailable');
  assert.equal(reads,1,'raw readback also respects HTTP 429');
  readbackResponse=undefined;
  // 新实例没有逐文件大小或行数限制；正文总量与文件数独立检查。
  const noOldLineLimit=await client.submitLogFiles([{name:'game/logs/long.log',content:'x\n'.repeat(250001)}],
    'test',undefined,newPlan,{deferVerification:true,onAccepted:async()=>{}});
  assert.equal(noOldLineLimit.ok,true,'新实例不能继承旧 maxLines 限制');
  const totalPlan={...newPlan,limits:{...current,maxTotalBytes:100,maxRequestBodyBytes:4096}};
  calls.length=0;
  const overTotal=await client.submitLogFiles([{name:'a.log',content:'a'.repeat(60)},{name:'b.log',content:'b'.repeat(60)}],
    'test',undefined,totalPlan);
  assert.equal(overTotal.ok,false); assert.equal(calls.filter(call=>call.method==='POST').length,0);
  const countPlan={...newPlan,limits:{...current,maxFiles:1}};
  const overCount=await client.submitLogFiles([{name:'a.log',content:'a'},{name:'b.log',content:'b'}],'test',undefined,countPlan);
  assert.equal(overCount.ok,false); assert.equal(calls.filter(call=>call.method==='POST').length,0);
  const overLocalCount=await client.submitLogFiles(Array.from({length:201},(_,i)=>({name:'f'+i+'.log',content:'x'})),
    'test',undefined,newPlan);
  assert.equal(overLocalCount.ok,false); assert.equal(calls.filter(call=>call.method==='POST').length,0);
  // 备用旧实例 maxLines 仍逐文件检查，多个合格文件的行数不能错误地求和。
  const lineFile = 'x\n'.repeat(30000);
  const linePreflight = {apiBaseUrl:BACKUP,checkedAt:Date.now(),attempts:[],limits:legacy};
  const twoFiles=await client.submitLogFiles([
    {name:'game/logs/a.log',content:lineFile}, {name:'game/logs/b.log',content:lineFile},
  ],'test',undefined,linePreflight,{deferVerification:true,onAccepted:async()=>{}});
  assert.equal(twoFiles.ok,true,'two files below per-file maxLines remain uploadable');
  const oneTooMany=await client.submitLogFiles([{name:'game/logs/too-many.log',content:'x\n'.repeat(50001)}],
    'test',undefined,linePreflight,{deferVerification:true,onAccepted:async()=>{}});
  assert.equal(oneTooMany.ok,false); assert.equal(oneTooMany.errorStage,'validation'); assert.match(oneTooMany.error,/maxLines/);
  // maxLength 也是逐文件限制，小文件之和允许超过它；仍保留12MiB附件总预算。
  const smallLimit={...linePreflight,limits:{...linePreflight.limits,maxBytes:80}};
  const smallPair=await client.submitLogFiles([{name:'a.log',content:'a'.repeat(60)},{name:'b.log',content:'b'.repeat(60)}],
    'test',undefined,smallLimit,{deferVerification:true,onAccepted:async()=>{}});
  assert.equal(smallPair.ok,true);
  const tooLong=await client.submitLogFiles([{name:'a.log',content:'a'.repeat(81)}],
    'test',undefined,smallLimit,{deferVerification:true,onAccepted:async()=>{}});
  assert.equal(tooLong.ok,false); assert.match(tooLong.error,/maxLength/);
  calls.length=0;
  const tooLargeBundle=await client.submitLogFiles([{name:'a.log',content:'a'.repeat(6*1024*1024)},
    {name:'b.log',content:'b'.repeat(6*1024*1024+1)}],'test',undefined,linePreflight);
  assert.equal(tooLargeBundle.ok,false); assert.match(tooLargeBundle.error,/展开/);
  assert.equal(calls.length,0,'oversized bundle never sends a POST');
  console.log('PASS dynamic new totals/body/count, legacy per-file limits, explicit insights selection and encoded filenames');
  let afterCancel=0;
  const disabledHandle=client.streamAiAnalysis('abc1234',{onDelta(){afterCancel++;},onDone(){afterCancel++;},onError(){afterCancel++;}});
  const unavailableNotifications=afterCancel; disabledHandle.cancel();
  await new Promise(resolve=>setTimeout(resolve,10));assert.equal(afterCancel,unavailableNotifications,'禁用入口取消后没有迟到通知');
  console.log('PASS primary preference, health-only failover; no automatic POST replay, dual outage, recovery, input rejection, per-provider retention and credential isolation');
  console.log('PASS metadata visibility, canonical version key, deduplicated ownership and retired AI guard');
} finally { fixture.close(); }
