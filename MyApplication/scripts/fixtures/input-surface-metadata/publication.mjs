/**
 * 实际McGamePage发布方法连接实编Native ingress/core探针。
 * SDK端口每次在新进程重放完整历史，接受态与当前context均来自生产API，不编写JS接受算法。
 */
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import compiler from '../../lib/ets-compiler.mjs';
import {makePureEtsLoader} from '../../lib/load-pure-ets.mjs';
import {PROJECT_ROOT,assertExternalOutputPath} from '../../lib/workspace-paths.mjs';

const getArg=name=>{const i=process.argv.indexOf(name);return i>=0?process.argv[i+1]:undefined;};
const binary=getArg('--native'),output=assertExternalOutputPath(getArg('--output'));assert.ok(binary);
const relative='entry/src/main/ets/pages/McGamePage.ets';
let text=fs.readFileSync(path.join(PROJECT_ROOT,relative),'utf8');
if(getArg('--source'))text=fs.readFileSync(getArg('--source'),'utf8');
const ast=compiler.createSourceFile(relative,text,compiler.ScriptTarget.Latest,true);
const owner=ast.statements.find(n=>n.name?.getText(ast)==='McGamePage');assert.ok(owner);
const method=owner.members.find(n=>n.name?.getText(ast)==='publishStoredInputSurfaceContext');assert.ok(method);
const compiled=compiler.transpileModule('class Subject{'+method.getText(ast)+'}\nmodule.exports=Subject;',
  {compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS},reportDiagnostics:true});
assert.equal((compiled.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error).length,0,'actual Mc method must compile');
const game=makePureEtsLoader()('gamecontrol/src/main/ets/InputSurfaceContext.ets');
const history=[],nativeResults=[],frameHints=[],densities=[],diagnosticLines=[],diagnosticWarnings=[];
let inputTraceEnabled=true,diagnosticFailure=false;
const napi={publishInputSurfaceContext:(...values)=>{
  history.push(values);
  const execution=spawnSync(binary,[],{input:history.map(row=>row.join(' ')).join('\n')+'\n',encoding:'utf8',timeout:30000});
  assert.equal(execution.status,0,'actual Native execution: '+execution.stderr);
  const rows=execution.stdout.trim().split(/\r?\n/).map(line=>JSON.parse(line));assert.equal(rows.length,history.length);
  const last=rows.at(-1);nativeResults.push(last);return last.accepted;
},setDisplayDensity:d=>densities.push(d),gate0InputTelemetryEnabled:()=>false,
refreshOhosFrameRateHint:hz=>{frameHints.push(hz);return true;}};
const dependencies={...game,testNapi:napi,DiagnosticPolicy:{inputTraceEnabled:()=>inputTraceEnabled},TAG:'host',LOG_DOMAIN_LAUNCH:0};
const module={exports:{}};new Function('module',...Object.keys(dependencies),compiled.outputText)(module,...Object.values(dependencies));
const subject=new module.exports();Object.assign(subject,{nativeSurfaceContextGeneration:0,nativeSurfaceContextMetadata:'',
  surfaceContextDiagnosticFingerprint_:'',launchLogger_:()=>({warn:(...values)=>diagnosticWarnings.push(values),
    info:(...values)=>{if(diagnosticFailure)throw new Error('explicit logger boundary failure');diagnosticLines.push(values);}})});
const store=new game.InputSurfaceContextStore(),lease=store.beginPublisher('real-page'),value=new game.InputSurfaceContextCandidate();
Object.assign(value,{windowId:45,displayId:0,widthPx:2800,heightPx:1840,density:2.125,transform:0,refreshRateHz:60,provisional:false});
let context=store.publish(lease,value);subject.publishStoredInputSurfaceContext(context,'display-change');
const initial=nativeResults.at(-1);assert.equal(initial.accepted,true);assert.equal(initial.hz,60);assert.equal(initial.held,1);
const baselineFields=['generation','held','resetEvents','surfaceEpoch','focusEpoch','contextEvents'];
function heldAndEpochs(result){for(const key of baselineFields)assert.equal(result[key],initial[key],'metadata-only preserves '+key);}

// 等价发布保留缓存，但frame hint仍逐调用使用最新采样；新缓存不能吞兼容消费者。
subject.publishStoredInputSurfaceContext(context,'window-heartbeat');assert.equal(history.length,1);
assert.deepEqual(frameHints,[60,60]);
assert.equal(diagnosticLines.length,1,'SAME_SURFACE_DIAGNOSTIC_QUIET');
value.refreshRateHz=120;context=store.publish(lease,value);assert.equal(context.generation,initial.generation);
subject.publishStoredInputSurfaceContext(context,'display-change');
assert.equal(history.length,2,'NATIVE_METADATA_MIRROR_UPDATED');
let current=nativeResults.at(-1);assert.equal(current.accepted,true);assert.equal(current.hz,120,'NATIVE_METADATA_MIRROR_UPDATED');heldAndEpochs(current);
assert.deepEqual(frameHints,[60,60,120]);

// Hz可用性单独变化不换输入身份；Native当前快照仍必须同步清掉有效位和旧Hz。
value.refreshRateHz=NaN;context=store.publish(lease,value);subject.publishStoredInputSurfaceContext(context,'display-change');
current=nativeResults.at(-1);assert.equal(current.accepted,true);assert.equal(current.hz,0);
assert.equal(current.fields&game.INPUT_SURFACE_FIELD_REFRESH_RATE,0);heldAndEpochs(current);assert.equal(frameHints.length,3);
value.refreshRateHz=90;context=store.publish(lease,value);subject.publishStoredInputSurfaceContext(context,'display-change');
current=nativeResults.at(-1);assert.equal(current.hz,90);assert.ok(current.fields&game.INPUT_SURFACE_FIELD_REFRESH_RATE);heldAndEpochs(current);

// 篡改同代输入字段并改变Hz以触发真实publisher；原Store不产生这种载荷，Native仍必须独立拒绝。
for(const [field,next] of [['widthPx',2801],['density',2.25],['transform',1],['windowId',46]]) {
  const forged=context.copy();forged[field]=next;forged.refreshRateHz=91;
  const before=history.length;subject.publishStoredInputSurfaceContext(forged,'forged-same-generation');
  current=nativeResults.at(-1);assert.equal(current.accepted,false,'SAME_GEN_INPUT_FORGERY_REJECTED '+field);
  assert.equal(current.hz,90);assert.equal(current.width,2800);heldAndEpochs(current);
  subject.publishStoredInputSurfaceContext(forged,'retry-after-rejection');
  assert.equal(history.length,before+2,'REJECTED_METADATA_NOT_CACHED');assert.equal(nativeResults.at(-1).accepted,false);
}
value.refreshRateHz=92;context=store.publish(lease,value);subject.publishStoredInputSurfaceContext(context,'display-change');
current=nativeResults.at(-1);assert.equal(current.accepted,true);assert.equal(current.hz,92);heldAndEpochs(current);
const calls=history.length;subject.publishStoredInputSurfaceContext(context,'window-heartbeat');assert.equal(history.length,calls);

// 原生命周期恢复会将generation缓存归零；即使metadata相等，也必须再次走现Native接受路径。
subject.nativeSurfaceContextGeneration=0;subject.publishStoredInputSurfaceContext(context,'window-restored');
assert.equal(history.length,calls+1);assert.equal(nativeResults.at(-1).accepted,true);heldAndEpochs(nativeResults.at(-1));
assert.equal(densities.length,frameHints.length+1,'缺Hz时仍保留一次密度兼容发布');

// 诊断稳定静默不裁掉必要Native refresh；完整生产方法重复执行100次，不另写日志模型。
const beforeStable={hints:frameHints.length,densities:densities.length,lines:diagnosticLines.length,native:history.length};
for(let i=0;i<100;i++)subject.publishStoredInputSurfaceContext(context,'window-heartbeat');
assert.equal(frameHints.length,beforeStable.hints+100,'NATIVE_REFRESH_NOT_GATED_BY_OBSERVER');
assert.equal(densities.length,beforeStable.densities+100);assert.equal(history.length,beforeStable.native);
assert.equal(diagnosticLines.length,beforeStable.lines,'SAME_SURFACE_DIAGNOSTIC_QUIET');

// 每页恢复重开诊断基线；logger异常不能安装成功指纹，也不能阻断下一次Native维护。
subject.surfaceContextDiagnosticFingerprint_='';diagnosticFailure=true;
subject.publishStoredInputSurfaceContext(context,'window-restored');
assert.equal(subject.surfaceContextDiagnosticFingerprint_,'');assert.ok(diagnosticWarnings.length>0);
diagnosticFailure=false;subject.publishStoredInputSurfaceContext(context,'window-restored');
assert.equal(diagnosticLines.length,beforeStable.lines+1,'LOGGER_FAILURE_RETRIED_ON_SAME_FACT');
const beforeDisabled=frameHints.length,linesDisabled=diagnosticLines.length;inputTraceEnabled=false;
for(let i=0;i<8;i++)subject.publishStoredInputSurfaceContext(context,'window-heartbeat');
assert.equal(frameHints.length,beforeDisabled+8,'NATIVE_REFRESH_NOT_GATED_BY_OBSERVER');assert.equal(diagnosticLines.length,linesDisabled);
fs.writeFileSync(path.join(output,getArg('--label')??'positive.json'),JSON.stringify({scope:'actual Mc publisher → actual ingress/core; not SDK/device acceptance',
  history,nativeResults,frameHints,densities,diagnosticLines,diagnosticWarnings},null,2)+'\n');
console.log('PASS actual Mc/native metadata: same-generation current Hz/validbit, no stream events/reset/held loss, forged input rejected, failed-cache retry');
