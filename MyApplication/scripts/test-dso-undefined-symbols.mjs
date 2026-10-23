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
  // 中立输入库按同样三证验证；特别覆盖没有下划线的兼容pump入口。
  const inputProvider=path.join(temp,'libamcl_input_runtime.so');
  const inputBody='extern const char* amclInputRuntimeBuildIdentityV1(void); extern void inputBridgeStartPumping(void); int fixture(void){inputBridgeStartPumping();return amclInputRuntimeBuildIdentityV1()!=0;}';
  compile('input-provider','const char* amclInputRuntimeBuildIdentityV1(void){return "fixture";} void inputBridgeStartPumping(void){}','libamcl_input_runtime.so');
  const inputBytes=fs.readFileSync(inputProvider);
  compile('input-consumer',inputBody,'libglfw.so',['-L'+temp,'-lamcl_input_runtime']);
  gate(0,'输入C ABI和兼容pump由真实中立依赖满足');
  fs.renameSync(inputProvider,inputProvider+'.saved');gate(1,'输入provider缺失不能凭前缀放行');fs.renameSync(inputProvider+'.saved',inputProvider);
  compile('input-wrong','const char* amclInputRuntimeBuildIdentityV1(void){return "fixture";} void inputBridgeStartPumping(void){}','wrong-input.so');
  fs.copyFileSync(path.join(temp,'wrong-input.so'),inputProvider);gate(1,'输入provider SONAME必须正确');
  fs.writeFileSync(inputProvider,inputBytes);compile('input-unlinked',inputBody,'libglfw.so');gate(1,'输入provider必须有真实依赖边');
  compile('input-unknown','int amclUnrelatedPrivate(void){return 1;}','libamcl_input_runtime.so');
  compile('input-private-consumer','extern int amclUnrelatedPrivate(void);int fixture(void){return amclUnrelatedPrivate();}',
    'libglfw.so',['-L'+temp,'-lamcl_input_runtime']);gate(1,'输入库不能泛放非公开amcl前缀');

  // look-v1是已有neutral门声明的冷C getter。真实链接建立版本需求，不能给未链接名字
  // 或任意amclLook族白名单；每个负例只换一个真实ELF输入，不伪造nm/readelf正文。
  const lookVersion=path.join(temp,'look.version');
  fs.writeFileSync(lookVersion,'AMCL_INPUT_RUNTIME { global: amclLookExecutionGetPortV1; local: *; };\n');
  const lookBody='extern const void* amclLookExecutionGetPortV1(void); int fixture(void){return amclLookExecutionGetPortV1()!=0;}';
  const lookProviderBody='static int table; const void* amclLookExecutionGetPortV1(void){return &table;}';
  compile('look-provider',lookProviderBody,'libamcl_input_runtime.so',['-Wl,--version-script='+lookVersion]);
  const lookProviderBytes=fs.readFileSync(inputProvider);
  compile('look-consumer',lookBody,'libglfw.so',['-L'+temp,'-lamcl_input_runtime']);
  const lookConsumerBytes=fs.readFileSync(consumer);
  gate(0,'look getter实际版本化强U+neutral强默认定义+直接依赖闭包');
  fs.renameSync(inputProvider,inputProvider+'.look-saved');
  gate(1,'look provider缺失不能借其它目录/global名字满足');fs.renameSync(inputProvider+'.look-saved',inputProvider);
  compile('look-unlinked',lookBody,'libglfw.so');gate(1,'look getter旁边有provider但没有物理link仍拒绝');
  fs.writeFileSync(consumer,lookConsumerBytes);
  const wrongVersion=path.join(temp,'look-wrong.version');
  fs.writeFileSync(wrongVersion,'WRONG_RUNTIME { global: amclLookExecutionGetPortV1; local: *; };\n');
  compile('look-wrong-version',lookProviderBody,'libamcl_input_runtime.so',['-Wl,--version-script='+wrongVersion]);
  gate(1,'同getter名字的错误provider version不能剥@放行');
  compile('look-wrong-consumer',lookBody,'libglfw.so',['-L'+temp,'-lamcl_input_runtime']);
  fs.writeFileSync(inputProvider,lookProviderBytes);gate(1,'错误consumer version不能借当前正确provider放行');
  fs.writeFileSync(consumer,lookConsumerBytes);
  compile('look-hidden','static int table; __attribute__((visibility("hidden"))) const void* amclLookExecutionGetPortV1(void){return &table;}','libamcl_input_runtime.so',
    ['-Wl,--version-script='+lookVersion]);
  gate(1,'hidden getter不能由源码或同名SONAME冒称动态定义');
  compile('look-weak','static int table; __attribute__((weak)) const void* amclLookExecutionGetPortV1(void){return &table;}',
    'libamcl_input_runtime.so',['-Wl,--version-script='+lookVersion]);
  gate(1,'weak provider getter不能代替唯一owner强定义');
  compile('look-object','int amclLookExecutionGetPortV1=42;','libamcl_input_runtime.so',['-Wl,--version-script='+lookVersion]);
  gate(1,'同名字data object不能代替实际C function');
  compile('look-zero','__asm__(".globl amclLookExecutionGetPortV1\\n.type amclLookExecutionGetPortV1,%function\\n.set amclLookExecutionGetPortV1,0\\n");',
    'libamcl_input_runtime.so',['-Wl,--version-script='+lookVersion]);
  gate(1,'零地址/非实际代码section getter不能充当可调用定义');
  fs.writeFileSync(inputProvider,lookProviderBytes);
  compile('look-weak-consumer','extern __attribute__((weak)) const void* amclLookExecutionGetPortV1(void);int fixture(void){return amclLookExecutionGetPortV1?amclLookExecutionGetPortV1()!=0:0;}',
    'libglfw.so',['-L'+temp,'-lamcl_input_runtime']);
  gate(1,'weak consumer query不能假称原strong cold port依赖');
} finally {
  // Windows 递归清理前验证完整解析路径确实是刚创建的专属临时目录。
  const resolved=path.resolve(temp);const base=path.resolve(workspaceTempRoot())+path.sep;
  if(!resolved.toLowerCase().startsWith(base.toLowerCase())||!path.basename(resolved).startsWith('amcl-linked-dso-'))
    throw new Error('拒绝清理未知目录 '+resolved);
  fs.rmSync(resolved,{recursive:true,force:true});
}
