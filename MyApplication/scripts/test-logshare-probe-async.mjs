/**
 * 执行真实合成Probe、账本与证据快照；网络和Native writer只替换平台边界。
 * 人为挂起真实async关闭端口，证明生产Probe不会在关闭完成前冻结/上传，所有文件外置。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {evidenceRuntime} from './lib/evidence-test-runtime.mjs';
let releaseClose,enterClose,beginFails=false,uploaded=0,revoked=0,activeDirectory='',queued='',remoteDeleted=false;
const gate=new Promise(resolve=>releaseClose=resolve),entered=new Promise(resolve=>enterClose=resolve);
const options={imports:{},commons:{DiagnosticPolicy:{hasTestHooks:()=>true,resolvedCapabilities:()=>1}},
 transform(file,source){return file.endsWith('LogShareConnectivityProbe.ets')?source+'\nexport { runProbe };':source;}};
const fixture=evidenceRuntime(options),ledger=fixture.load('commons/src/main/ets/utils/ActivityLedger.ets');
options.commons.ledgerBeginAsync=(dir,id,meta)=>beginFails?Promise.resolve(false):ledger.ledgerBeginAsync(dir,id,meta);
options.commons.ActivityLogger=class{info(_tag,text){queued+=text+'\n';}};
options.imports['./LogShareClient']={LOGSHARE_BACKUP_API_BASE:'https://backup.invalid',logShareInstanceForUrl:()=> 'https://fixture.invalid',
 getLimits:async()=>({ok:true,storageTimeSec:10}),revokeShare:async()=>{revoked++;remoteDeleted=true;return{ok:true};}};
// 只替换外发服务端口：snapshot仍由生产Probe/账本封存，读取其真实文件验证长行尾部，
// 返回合成远端身份供生产撤回链消费；没有联网，uploaded/revoked不是服务端验收。
options.imports['./EvidenceShareService']={async shareEvidenceSnapshot(_context,snapshot){
 uploaded++;const launcher=snapshot.files.find(file=>file.role==='launcher');assert(launcher);
 assert(fs.readFileSync(launcher.path,'utf8').includes('LONG_END'),'真实快照包含平台关闭后写出的长行尾部');
 return{id:'fixture001',url:'https://fixture.invalid/view/fixture001',apiBaseUrl:'https://fixture.invalid',remoteFilesVerified:true};}};
options.imports['@kit.NetworkKit']={http:{RequestMethod:{GET:'GET'},createHttp:()=>({destroy(){},
 async request(url){return{responseCode:remoteDeleted?404:200,result:url.includes('/render/')?'AMCL_SYNTHETIC_RENDER hostprobe':'AMCL synthetic routing probe hostprobe'};}})}};
// Native sink替身只控制关闭完成边界：begin保存当前真实目录，endAsync等gate兑现后写入累积正文。
// 生产Probe必须await它再冻结快照；同步end明确拒绝。finally仅清本fixture目录，不创建真实writer线程。
ledger.setLedgerScopeSink({begin(_id,dir){activeDirectory=dir;fs.mkdirSync(dir+'/launcher',{recursive:true});return true;},
 end(){throw Error('Probe禁止同步Native关闭');},async endAsync(){enterClose();await gate;fs.writeFileSync(activeDirectory+'/launcher/launcher-host.log',queued);}});
const {runProbe}=fixture.load('entry/src/main/ets/components/LogShareConnectivityProbe.ets');
try{
 const pending=runProbe(fixture.context,'hostprobe',true);await entered;
 assert.equal(uploaded,0,'异步关闭挂起时不得上传');assert.equal(revoked,0);
 assert.equal(fs.existsSync(activeDirectory+'/launcher/launcher-host.log'),false);
 releaseClose();await pending;
 const report=JSON.parse(fs.readFileSync(fixture.context.filesDir+'/logshare-connectivity-hostprobe.json','utf8'));
 assert(report.steps.every(step=>step.ok),JSON.stringify(report.steps));assert.equal(uploaded,1);assert.equal(revoked,1);
 beginFails=true;await runProbe(fixture.context,'beginfailed',false);
 const failure=JSON.parse(fs.readFileSync(fixture.context.filesDir+'/logshare-connectivity-beginfailed.json','utf8'));
 assert(failure.steps.some(step=>step.name==='probe-error'&&!step.ok));assert.equal(uploaded,1,'开账失败不发送');
 console.log('PASS: production Probe waits actual async close before snapshot/upload, preserves LONG_END, revokes synthetic share and records begin failure');
}finally{fixture.close();}
