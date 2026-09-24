// 实际 LogShare 客户端协议/凭据/SSE 回归。所有网络均为可控边界，绝不外发用户日志。
import assert from 'node:assert/strict';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';
const mocks = {};
const fixture = evidenceRuntime({ imports: mocks });
const load = fixture.load;
try {
  const PRIMARY = 'https://api.logshare.cn', BACKUP = 'https://amcl.lovedhy.cn/logshare-api';
  let response;
  let readbackResponse;
  let lastRequest;
  let requestError;
  let officialDown = false, backupDown = false, primaryUploadDown = false;
  let saved = '', failSave = false;
  fixture.control.failWrite = name => failSave && name.includes('share-records');
  const calls = [];
  let streamCode = 200;
  // 模拟 NetworkKit 合法的不同回调顺序：数据/EOF 可以早于状态 Promise。
  let streamEarly = false, streamHeaders = {}, streamChunked = true;
  let streamText = 'event: status\ndata: {"type":"thinking","delta":"private reasoning"}\n\ndata: {"choices":[{"delta":{"content":"中文分析结论"}}]}\n\nevent: done\ndata: {"status":"completed"}\n\n';
  const successFor = url => ({ responseCode: 200, result: JSON.stringify({ success: true, id: 'abc1234', url: url.startsWith(BACKUP) ? 'https://amcl.lovedhy.cn/logshare/abc1234' : 'https://logshare.cn/abc1234', raw: url.replace(/\/log$/, '/raw/abc1234'), token: 'delete-credential' }) });
  mocks['@kit.NetworkKit'] = { http: {
    RequestMethod: { POST: 'POST', GET: 'GET', DELETE: 'DELETE' },
    createHttp() {
      const handlers = new Map();
      let destroyed = false;
      return {
        on(name, handler) { handlers.set(name, handler); }, off(name) { handlers.delete(name); },
        async request(url, options) {
          lastRequest = { url, ...options }; calls.push(lastRequest);
          if (requestError) throw requestError;
          if ((officialDown && url.startsWith(PRIMARY)) || (backupDown && url.startsWith(BACKUP))) throw Object.assign(new Error('offline'), {code:2300007});
          if (url.endsWith('/limits')) {
            const official = url.startsWith(PRIMARY);
            return { responseCode: 200, result: JSON.stringify({
              maxLength: official ? 20485760 : 10485760,
              maxLines: official ? 200000 : 50000,
              storageTime: official ? 1296000 : 604800,
            }) };
          }
          if (primaryUploadDown && url === PRIMARY+'/v1/log') return {responseCode:503,result:JSON.stringify({error:'unavailable',code:503})};
          if (readbackResponse && options.method === 'GET') return readbackResponse(url, options);
          if (response) return response;
          if (options.method === 'DELETE') return {responseCode:200,result:JSON.stringify({success:true,deleted:url.split('/').pop().split(','),failed:[]})};
          return successFor(url);
        },
        async requestInStream(url, options) {
          calls.push({url,...options});
          const deliver = () => {
            handlers.get('headersReceive')?.(streamHeaders);
            const bytes = new TextEncoder().encode(streamText);
            if (streamChunked) for (const byte of bytes) { if (destroyed) break; handlers.get('dataReceive')?.(Uint8Array.of(byte).buffer); }
            else handlers.get('dataReceive')?.(bytes.buffer);
            handlers.get('dataEnd')?.();
          };
          if (streamEarly) deliver();
          else if (streamCode === 200) setTimeout(deliver, 0);
          return streamCode;
        },
        destroy() { destroyed = true; }
      };
    }
  } };
  mocks['@kit.ArkData'] = { preferences: { async getPreferences() { return { async get() { return saved; }, async put(key, value) { if (failSave) throw new Error('disk full'); saved = value; }, async flush() {} }; } } };
  mocks['@kit.AbilityKit'] = { bundleManager: { BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0 }, getBundleInfoForSelfSync() { return { versionName: '1.2.3-test' }; } } };
  const client = load('entry/src/main/ets/components/LogShareClient.ets');
  const meta = { launcher:'AMCL', appVersion:'', mcVersion:'test', loader:'', jdk:'', device:'', osVersion:'', outcome:'test' };
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
  assert(Array.isArray(JSON.parse(uploadRequest.extraData).metadata));

  calls.length = 0; officialDown = true;
  routed = await client.submitLog('synthetic', 'test');
  assert.equal(routed.ok, true); assert.equal(routed.apiBaseUrl, BACKUP); assert.equal(routed.usedFallback, true);
  assert.equal(routed.storageTimeSec,604800);
  assert.equal(calls.filter(call=>call.url===PRIMARY+'/v1/log').length,0,'failed preflight does not upload');
  assert.equal(calls.filter(call=>call.method==='POST').length,1);
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
  const complete=await runStream();
  assert.equal(complete.text,'中文分析结论'); assert.equal(complete.done,1); assert(!complete.answer.includes('private'));
  calls.length=0;
  assert.match((await runStream(BACKUP)).error,/备用/);
  assert.equal(calls.length,0,'backup IDs never reach the official AI service');
  streamText='data: {"choices":[{"delta":{"content":"partial"}}]}\n\n';
  const truncated=await runStream(); assert.equal(truncated.done,0); assert.match(truncated.error,/中断/);
  streamCode=429;
  assert.match((await runStream()).error,/HTTP 429/);
  streamCode=200;
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

  streamText=publicFrame+doneFrame; streamEarly=true;
  const earlyOk=await runStream(); assert.equal(earlyOk.done,1); assert.equal(earlyOk.answer,'中文结论');
  streamCode=429; streamHeaders={'Retry-After':'42','Content-Type':'text/event-stream'};
  const earlyBad=await runStream(); assert.equal(earlyBad.done,0); assert.equal(earlyBad.answer,''); assert.match(earlyBad.error,/42 秒/);
  streamCode=200; streamHeaders={'Content-Type':'application/json'}; streamText='{"error":"not a stream"}';
  assert.match((await runStream()).error,/未返回流式/);
  streamHeaders={}; streamChunked=false; streamText='x'.repeat(2*1024*1024+1);
  assert.match((await runStream()).error,/确认 HTTP 状态前过大/);
  console.log('PASS official status frames, CR/LF/BOM and fragmented boundaries, bounded frames, unknown-event isolation, early HTTP callbacks and JSON refusal');
  // files 正文低于 12 MiB 仍可能因 JSON 转义超出官网 20 MiB 解压保护；必须在 POST 前拒绝。
  calls.length=0;
  const oversized=await client.submitLogFiles([{name:'launcher/launcher-host.log',content:'"'.repeat(10*1024*1024)}],'test',undefined,
    {apiBaseUrl:PRIMARY,checkedAt:Date.now(),attempts:[],limits:{ok:true,maxBytes:20485760,maxLines:200000,storageTimeSec:1296000,error:''}});
  assert.equal(oversized.ok,false);assert.equal(oversized.errorStage,'local-prepare');assert.match(oversized.error,/20 MiB/);
  assert.equal(calls.filter(c=>c.method==='POST').length,0);
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
  // 服务端 maxLines 按主正文/单个附加文件分别过滤，不是跨 files[] 求和。
  const lineFile = 'x\n'.repeat(150000);
  const linePreflight = {apiBaseUrl:PRIMARY,checkedAt:Date.now(),attempts:[],limits:{ok:true,maxBytes:20485760,maxLines:200000,storageTimeSec:1296000,error:''}};
  const twoFiles=await client.submitLogFiles([
    {name:'game/logs/a.log',content:lineFile}, {name:'game/logs/b.log',content:lineFile},
  ],'test',undefined,linePreflight,{deferVerification:true,onAccepted:async()=>{}});
  assert.equal(twoFiles.ok,true,'two files below per-file maxLines remain uploadable');
  const oneTooMany=await client.submitLogFiles([{name:'game/logs/too-many.log',content:'x\n'.repeat(200001)}],
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
  console.log('PASS per-file limits, strict file manifests, bounded transport/5xx GET retries and no retry for 429/404');
  streamEarly=false;streamCode=200;streamHeaders={};streamText=publicFrame+doneFrame;
  let afterCancel=0;
  client.streamAiAnalysis('abc1234',{onDelta(){afterCancel++;},onDone(){afterCancel++;},onError(){afterCancel++;}}).cancel();
  await new Promise(resolve=>setTimeout(resolve,10));assert.equal(afterCancel,0,'取消后的迟到回调不再通知页面');
  console.log('PASS complete JSON request budget and cancelled stream callback isolation');
  console.log('PASS primary preference, health-only failover; no automatic POST replay, dual outage, recovery, input rejection, per-provider retention and credential isolation');
  console.log('PASS SSE one-byte UTF-8 chunks, hidden status suppression, done, interrupted stream, HTTP 429, server errors, backup AI refusal');
} finally { fixture.close(); }
