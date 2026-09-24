/**
 * 用真实 aarch64 ELF 验证本仓跨 DSO 符号门禁；不以伪造 nm 文本代替链接行为。
 * 只在唯一临时目录生成几份极小库，验证依赖边、SONAME、动态定义三者缺一不可。
 */
// 临时夹具及其清理边界统一使用外部宿主测试区，不修改系统 TEMP，也不回退到源码目录。
import { workspaceTempRoot } from './lib/workspace-paths.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
const root=path.resolve(import.meta.dirname,'..');
const temp=fs.mkdtempSync(path.join(workspaceTempRoot(),'amcl-linked-dso-'));
const clang='D:/Huawei/command-line-tools/sdk/default/openharmony/native/llvm/bin/clang.exe';
const provider=path.join(temp,'libamcl_graphics_runtime.so');
const consumer=path.join(temp,'libglfw.so');
/** 生成无 libc 依赖的测试 ELF，失败立即抛出；不会与真实产品目录混用。 */
function compile(name,source,soname,extra=[]){
  const file=path.join(temp,name+'.c');fs.writeFileSync(file,source);
  const result=spawnSync(clang,['--target=aarch64-linux-ohos','-nostdlib','-fPIC','-shared',file,'-Wl,-soname,'+soname,
    '-o',path.join(temp,soname),...extra],{encoding:'utf8',windowsHide:true});
  assert.equal(result.status,0,result.stderr);
}
function gate(expected,label){
  const result=spawnSync(process.execPath,[path.join(root,'scripts/check-dso-undefined-symbols.mjs'),'--so',consumer],{encoding:'utf8',windowsHide:true});
  assert.equal(result.status,expected,label+'\n'+result.stdout+'\n'+result.stderr);console.log('PASS '+label);
}
try {
  compile('provider','int amclGraphicsFixtureV1(void){return 42;}','libamcl_graphics_runtime.so');
  const original=fs.readFileSync(provider);
  const body='extern int amclGraphicsFixtureV1(void); int fixture(void){return amclGraphicsFixtureV1();}';
  compile('consumer',body,'libglfw.so',['-L'+temp,'-lamcl_graphics_runtime']);
  gate(0,'实际 DT_NEEDED + 匹配 SONAME + 动态定义');
  fs.renameSync(provider,provider+'.saved');gate(1,'依赖文件缺失不能借用目录外产物');fs.renameSync(provider+'.saved',provider);
  compile('wrong','int amclGraphicsFixtureV1(void){return 42;}','wrong-soname.so');
  fs.copyFileSync(path.join(temp,'wrong-soname.so'),provider);gate(1,'错误 SONAME 不能满足依赖');
  compile('empty','int unrelated(void){return 0;}','libamcl_graphics_runtime.so');gate(1,'同名依赖没有动态定义仍失败');
  fs.writeFileSync(provider,original);compile('unlinked',body,'libglfw.so');gate(1,'没有 DT_NEEDED 时旁边的库不能充当定义');
} finally {
  // Windows 递归清理前验证完整解析路径确实是刚创建的专属临时目录。
  const resolved=path.resolve(temp);const base=path.resolve(workspaceTempRoot())+path.sep;
  if(!resolved.toLowerCase().startsWith(base.toLowerCase())||!path.basename(resolved).startsWith('amcl-linked-dso-'))
    throw new Error('拒绝清理未知目录 '+resolved);
  fs.rmSync(resolved,{recursive:true,force:true});
}
