/** 正常HAP入口也执行GUI桥的生产Java测试；只编译两个文件，输出在工作区外置临时树。 */
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {PROJECT_ROOT,createWorkspaceTemp,assertExternalOutputPath} from './lib/workspace-paths.mjs';

const out=createWorkspaceTemp('gui-bridge-');
const suffix=process.platform==='win32'?'.exe':'';
const javaHome=process.env.AMCL_JVM_TEST_JAVA_HOME || process.env.JAVA_HOME;
function tool(name){const candidate=javaHome?path.join(javaHome,'bin',name+suffix):'';return candidate&&fs.existsSync(candidate)?candidate:name;}
function run(program,args){
  const result=spawnSync(program,args,{cwd:PROJECT_ROOT,encoding:'utf8',timeout:60000,maxBuffer:4*1024*1024});
  if(result.status!==0)throw new Error(`${program} failed: ${result.error?.message||''}\n${result.stdout||''}\n${result.stderr||''}`);
  return result.stdout||'';
}
let success=false;
try {
  run(tool('javac'),['-encoding','UTF-8','-source','8','-target','8','-d',out,
    'JavaApp/src/com/amcl/launcher/GameGuiBridge.java','JavaApp/test/com/amcl/launcher/GameGuiBridgeTest.java']);
  const result=run(tool('java'),['-cp',out,'com.amcl.launcher.GameGuiBridgeTest']);
  if(!/Results: \d+ passed, 0 failed/.test(result))throw new Error('Missing successful production test result\n'+result);
  console.log(result.trim());success=true;
} finally {
  // 只清理本次成功测试自己创建的目录；失败产物保留诊断，不按名称批量删除。
  assertExternalOutputPath(out);
  if(success && path.basename(out).startsWith('gui-bridge-'))fs.rmSync(out,{recursive:true});
  else console.log('GUI bridge fixture retained: '+out);
}
