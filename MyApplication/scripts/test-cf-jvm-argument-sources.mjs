/**
 * 直接运行VersionParser→LaunchProfileBuilder的参数过滤/用户合并，公共清单来自真实C++消费者输出。
 * 不执行文件/设备/VM；旧SSOT反控明确证明原filter会吞相同manifest规则，新清单必须保留来源顺序。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import crypto from 'node:crypto';
const [commonFile, outputFile, specifiedProject] = process.argv.slice(2);
assert.ok(commonFile && outputFile, 'usage: node test-cf-jvm-argument-sources.mjs common-args.txt report.json [project-root]');
const project = specifiedProject ? path.resolve(specifiedProject) : path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const { makePureEtsLoader } = await import(pathToFileURL(path.join(project, 'scripts/lib/load-pure-ets.mjs')).href);
const broad = '-XX:CompileCommand=exclude,java/util/concurrent/CompletableFuture.*';
const actualCommon = fs.readFileSync(commonFile, 'utf8').trimEnd().split(/\r?\n/);
assert.ok(actualCommon.length > 10 && !actualCommon.includes(broad), 'actual C++ SSOT must exclude conditional CF default');
let suppliedCommon = actualCommon;
const noIO = () => { throw new Error('CF argument source regression must not touch filesystem/device APIs'); };
class SilentLogger { info() {} warn() {} error() {} }
const load = makePureEtsLoader({
  '@kit.CoreFileKit': { fileIo: { readTextSync:noIO,statSync:noIO,listFileSync:noIO } },
  '@kit.PerformanceAnalysisKit': { hilog: { info(){},warn(){},error(){} } },
  '../modloader/MavenUtils': { mavenToRelativePath:noIO },
  commons: { ActivityLogger:SilentLogger,formatError:String },feature_core:{},account:{},mods:{},
  './LaunchNativeBridge': { launchNative:()=>({getCommonJvmArgs:()=>suppliedCommon}) },
  './GameCompatibility':{},'./GraphicsProfileRegistry':{GraphicsGameApi:{UNKNOWN:'unknown'}},
  './GraphicsBackendPlan':{VulkanPolicy:{ALLOW:'allow'}},'./GraphicsGameFacts':{},'./LoaderGenerationResolver':{},
  './LaunchContractPreflight':{},'./LaunchAgentProbe':{},
});
const { VersionParser }=load('feature_core/src/main/ets/version/VersionParser.ets');
const { LaunchProfileBuilder }=load('launch/src/main/ets/LaunchProfileBuilder.ets');
function builder(custom='') {
  const value=new LaunchProfileBuilder().setMcDir('/fixture/.minecraft').setVersion('cf-sources').setCustomJvmArgs(custom);
  value.gameDir='/fixture/.minecraft/versions/cf-sources';return value;
}
const manifest=[broad,'-XX:CompileCommand=dontinline,loader/Work.run',broad,
  '-XX:CompileOnly=loader/Work.run','-XX:CompileCommandFile=/loader/commands.txt','-XX:CompilerDirectivesFile=/loader/directives.json'];
const raw={id:'cf-sources',type:'release',mainClass:'example.Main',libraries:[],arguments:{jvm:manifest,game:[]}};
const parsed=VersionParser.parseData(raw);
assert.deepEqual(parsed.jvmArgs,manifest);
const filtered=builder().filterJvmArgs(parsed.jvmArgs,'/fixture/client.jar');
assert.deepEqual(filtered,manifest,'same literal repeated loader rules must survive the real filter');
const user=[broad,'-XX:CompileCommand=inline,user/Work.run','-XX:CompileCommand=dontinline,user/Work.run',broad,
  '-XX:CompileCommandFile=/user/commands.txt','-XX:CompilerDirectivesFile=/user/directives.json'];
const merged=builder(user.join(' ')).mergeUserJvmArgs(filtered);
assert.deepEqual(merged,[...manifest,...user],'manifest/global/per-version rule order must remain unchanged');
assert.deepEqual(builder(broad).mergeUserJvmArgs([]),[broad]);
assert.deepEqual(builder().filterJvmArgs(['-XX:-UseCompressedOops',broad],'/fixture/client.jar'),[broad],
  'other unconditionally injected SSOT options still deduplicate');
assert.ok(!merged.some(value=>value===broad+',false'),'production merge must not add an automatic restoration rule');
// 用户自己写false是原始显式输入，不应被我们禁止、改写或自动复制。
const explicitFalse=broad+',false';assert.deepEqual(builder(explicitFalse).mergeUserJvmArgs(filtered),[...manifest,explicitFalse]);
// 负对照仅改变传给真实filter的旧SSOT集合，证明保留common literal再在Native删掉是错误路线。
suppliedCommon=[...actualCommon,broad];
assert.deepEqual(builder().filterJvmArgs(manifest,'/fixture/client.jar'),manifest.filter(value=>value!==broad));
suppliedCommon=actualCommon;
const sha=value=>crypto.createHash('sha256').update(value).digest('hex');
const report={passed:true,scope:'real ArkTS source argument/provenance only; no target/game qualification',
  manifestPreserved:true,userOrderPreserved:true,repeatedCompilerOptionsPreserved:true,otherSsotDedupUnchanged:true,
  oldSsotCounterfactualRejected:true,automaticFalseAdded:false,explicitUserFalsePreserved:true,
  commonArgumentsSha256:sha(fs.readFileSync(commonFile)),sources:Object.fromEntries([
    'feature_core/src/main/ets/version/VersionParser.ets','launch/src/main/ets/LaunchProfileBuilder.ets',
    'launch/src/main/ets/RuntimeJvmArgumentPolicy.ets'].map(file=>[file,sha(fs.readFileSync(path.join(project,file)))]))};
fs.writeFileSync(outputFile,JSON.stringify(report,null,2)+'\n',{encoding:'utf8',flag:'wx'});
console.log(JSON.stringify(report));
