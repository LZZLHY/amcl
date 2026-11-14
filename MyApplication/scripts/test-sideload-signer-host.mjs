/**
 * 不依赖DevEco SDK的真实Java签名器门禁。固定公开工具提供编译API；测试源码编译为Java17，
 * 执行真实身份及ZIP检查，再逐字节比较tracked runner内的class与当前源码编译结果。
 * 所有classes/HAP夹具归本轮独占运行域；成功后关闭资源并回收，失败保留原始现场。
 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { createHostTestScope } from './lib/host-test-lifecycle.mjs';

const project=path.resolve(import.meta.dirname,'..'),scope=createHostTestScope('sideload-java-host-');
const hash=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const input=process.env.AMCL_SIDELOAD_TEST_RAW_ROOT;
if(!input||!path.isAbsolute(input))throw Error('Prepare AMCL_SIDELOAD_TEST_RAW_ROOT explicitly before Java host tests');
const dependency=path.join(input,'sideload/hap-sign-tool.jar');
const pin=JSON.parse(fs.readFileSync(path.join(project,'prebuilt/hap-sign-tool/pin.json'),'utf8'));
if(hash(dependency)!==pin.sha256)throw Error('Java host compiler dependency differs from public signer pin');

/** 选择同一完整JDK的三个工具，避免PATH中的旧java与新javac混用而给出伪结论。 */
function completeJdk() {
  const suffix=process.platform==='win32'?'.exe':'';
  const inspect=compiler=>{
    if(!compiler||!fs.existsSync(compiler))return undefined;
    const directory=path.dirname(fs.realpathSync(compiler));
    return ['javac','java','jar'].every(name=>fs.existsSync(path.join(directory,name+suffix)))?directory:undefined;
  };
  let result=process.env.JAVA_HOME&&inspect(path.join(process.env.JAVA_HOME,'bin/javac'+suffix));
  if(!result){let candidates=[];try{candidates=execFileSync(process.platform==='win32'?'where':'which',process.platform==='win32'?['javac']:['-a','javac'],{encoding:'utf8'}).trim().split(/\r?\n/);}catch{/* 下方给出明确缺工具原因。 */}
    result=candidates.map(inspect).find(Boolean);}
  if(!result)throw Error('A complete JDK17+ (javac/java/jar) is required');
  return name=>path.join(result,name+suffix);
}
const tool=completeJdk(),classes=path.join(scope.directory,'classes'),extracted=path.join(scope.directory,'tracked');
fs.mkdirSync(classes);fs.mkdirSync(extracted);
const source=path.join(project,'entry/src/main/sideload/AmclSigningRunner.java');
const tests=path.join(project,'entry/src/main/sideload/tests');
const compileArgs=['--release','17','-proc:none','-encoding','UTF-8','-cp',dependency,'-d',classes,source,
  path.join(tests,'SigningIdentityTest.java'),path.join(tests,'ManualPackageInspectionTest.java')];
execFileSync(tool('javac'),compileArgs,{stdio:'inherit'});
const classpath=classes+path.delimiter+dependency;
execFileSync(tool('java'),['-cp',classpath,'SigningIdentityTest'],{stdio:'inherit'});
execFileSync(tool('java'),['-cp',classpath,'ManualPackageInspectionTest',path.join(scope.directory,'hap-fixtures')],{stdio:'inherit'});
const tracked=path.join(project,'entry/src/main/resources/rawfile/sideload/amcl-signing-runner.jar');
execFileSync(tool('jar'),['--extract','--file',tracked,'AmclSigningRunner.class'],{cwd:extracted,stdio:'inherit'});
const compiledSha=hash(path.join(classes,'AmclSigningRunner.class')),trackedSha=hash(path.join(extracted,'AmclSigningRunner.class'));
if(compiledSha!==trackedSha)throw Error('Tracked runner class is stale; rebuild it from the current Java source');
const receipt={schema:1,passed:true,completedAt:new Date().toISOString(),sourceSha256:hash(source),
  compilerDependencySha256:pin.sha256,runnerJarSha256:hash(tracked),compiledClassSha256:compiledSha,trackedClassSha256:trackedSha,targetJava:17};
if(process.env.AMCL_TEST_OUTPUT_DIR)fs.writeFileSync(path.join(process.env.AMCL_TEST_OUTPUT_DIR,'sideload-signer-host-results.json'),JSON.stringify(receipt,null,2)+'\n');
console.log('PASS real public-pinned Java signer: identity/ZIP tests and current-source versus tracked-class bytes match');
