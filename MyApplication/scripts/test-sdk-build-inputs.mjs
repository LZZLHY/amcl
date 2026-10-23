/**
 * SDK消费身份的微型永久回归；全部伪PE/头/库/loader材料在仓外，不执行任何SDK工具。
 * 真实Ninja读取由显式JS测试reader替代，生产CLI/会话不提供该回退。
 * 对照覆盖内容、成员、链接、scope、布局及见证资格，避免“少读字节”等同于盲信旧包。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {fingerprintSdk,peImports} from './lib/sdk-build-inputs.mjs';
import {assertExternalOutputPath,resolveWorkspacePath} from './lib/workspace-paths.mjs';

const policy=JSON.parse(fs.readFileSync(new URL('../config/sdk-build-inputs.json',import.meta.url),'utf8'));
const position=process.argv.indexOf('--out');let output;
if(position>=0){if(!process.argv[position+1])throw new Error('Missing --out');output=assertExternalOutputPath(path.resolve(process.argv[position+1]));if(fs.existsSync(output))throw new Error('Evidence output must be new');fs.mkdirSync(output,{recursive:true});}
else {const parent=resolveWorkspacePath('run','sdk-input-regression');fs.mkdirSync(parent,{recursive:true});output=fs.mkdtempSync(path.join(parent,'case-'));}
const cases=[];
const slash=value=>value.replaceAll('\\','/');

/** 最小合法x64 PE，普通/延迟import都留独立终止项；尾部字节可变而不影响结构。 */
function pe({normal,delay}={}) {
  const bytes=Buffer.alloc(4096);bytes.write('MZ');bytes.writeUInt32LE(0x80,0x3c);bytes.writeUInt32LE(0x4550,0x80);
  bytes.writeUInt16LE(0x8664,0x84);bytes.writeUInt16LE(1,0x86);bytes.writeUInt16LE(240,0x94);bytes.writeUInt16LE(0x20b,0x98);
  const section=0x98+240;bytes.write('.rdata',section);bytes.writeUInt32LE(0x800,section+8);bytes.writeUInt32LE(0x1000,section+12);
  bytes.writeUInt32LE(0x800,section+16);bytes.writeUInt32LE(0x200,section+20);
  if(normal){bytes.writeUInt32LE(0x1000,0x98+120);bytes.writeUInt32LE(0x1100,0x200+12);bytes.write(normal,0x300);}
  if(delay){bytes.writeUInt32LE(0x1200,0x98+216);bytes.writeUInt32LE(1,0x400);bytes.writeUInt32LE(0x1300,0x404);bytes.write(delay,0x500);}
  return bytes;
}

/** 根据真实配置创建所有必须布局；只用极小文件，验证范围策略而非复制SDK实现。 */
function fixture(name) {
  const root=path.join(output,name,'bundle');fs.mkdirSync(root,{recursive:true});
  const write=(relative,value)=>{const selected=path.join(root,relative);fs.mkdirSync(path.dirname(selected),{recursive:true});fs.writeFileSync(selected,value);};
  for(const [directory,members]of Object.entries(policy.layoutMembers))for(const member of members) {
    const selected=path.posix.join(directory,member);
    if(/\.(?:json|txt)$/i.test(member))write(selected,'{}');else fs.mkdirSync(path.join(root,selected),{recursive:true});
  }
  for(const directory of [...policy.trees,...policy.excludedTrees,...policy.nativeBinDirectories])fs.mkdirSync(path.join(root,directory),{recursive:true});
  const files=[...policy.requiredFiles,...policy.metadataFiles,...policy.toolFiles,
    ...policy.nativeBinDirectories.flatMap(directory=>policy.nativeTools.map(tool=>directory+'/'+tool)),
    ...policy.bishengDriverTools.map(tool=>'hms/native/BiSheng/bin/'+tool)];
  for(const name of files)write(name,name.endsWith('.exe')?pe():'original payload');
  write('sdk-pkg.json',JSON.stringify({data:{version:policy.scope.sdkVersion,apiVersion:'26'}}));
  for(const family of ['openharmony','hms'])for(const component of ['ets','js','native','previewer','toolchains']) {
    write(family+'/'+component+'/'+(family==='openharmony'?'oh-uni-package.json':'uni-package.json'),JSON.stringify({version:policy.scope.sdkVersion,apiVersion:'26',path:component}));
  }
  write('openharmony/native/sysroot/usr/lib/aarch64-linux-ohos/libc.so','target library A');
  write('openharmony/native/llvm/bin/clangd.exe','unused debugger bytes');
  write('openharmony/native/docs/unused.txt','unused documentation bytes');
  write('openharmony/ets/build-tools/ets-loader/main.js','actual loader code');
  const tool=slash(path.join(root,'hms/native/BiSheng/bin/clang++.exe'));
  const sdk=slash(path.join(root,'openharmony/native/sysroot'));
  const proof={compileCommands:[{command:'"'+tool+'" --target=aarch64-linux-ohos --sysroot="'+sdk+'" -c fixture.cpp'}],
    cmakeCache:'OHOS_ARCH:STRING=arm64-v8a\nCMAKE_OHOS_ARCH_ABI:STRING=arm64-v8a\nCMAKE_TOOLCHAIN_FILE:FILEPATH='+slash(path.join(root,'hms/native/build/cmake/hmos.toolchain.bisheng.cmake'))+'\nCMAKE_MAKE_PROGRAM:FILEPATH='+slash(path.join(root,'openharmony/native/build-tools/cmake/bin/ninja.exe'))+'\n',
    ninjaRules:'command = '+tool+' --target=aarch64-linux-ohos --sysroot='+sdk,
    buildNinja:'LINK_LIBRARIES = '+slash(path.join(root,'openharmony/native/sysroot/usr/lib/aarch64-linux-ohos/libc.so')),
    dependencyText:slash(path.join(root,'openharmony/native/sysroot/usr/include/stdint.h'))+'\n'+slash(path.join(root,'hms/native/BiSheng/include/libcxx-ohos/include/c++/v1/__config'))+'\n'};
  const options={platform:'win32',arch:'x64',product:'default',mode:'debug',abi:'arm64-v8a',nativeCompiler:'BiSheng',nativeEvidenceReader:()=>proof};
  return {root,write,proof,options,run:extra=>fingerprintSdk(path.join(root,'openharmony'),{...options,...extra})};
}

function check(name,body) {
  try {body();cases.push({name,state:'PASS'});console.log('PASS SDK input closure: '+name);}
  catch(error){cases.push({name,state:'FAIL',error:error.stack});throw error;}
}

try {
  check('complete declared layout and actual target witness produce a stable content identity',()=>{
    const item=fixture('positive'),first=item.run(),second=item.run();
    assert.equal(first.state,'AVAILABLE',first.reason??first.qualification?.reason);assert.equal(first.key,second.key);
    assert.deepEqual(first.identity,second.identity);assert.equal(first.identity.state,'CONTENT_IDENTITY');
    assert.ok(first.metrics.hashedFiles>0);assert.ok(first.metrics.excludedFiles>0);assert.ok(!Object.hasOwn(first.identity,'metrics'));
  });

  check('header, target library, tool and loader code raw changes invalidate without mtime assumptions',()=>{
    const item=fixture('content');let before=item.run();assert.equal(before.state,'AVAILABLE',before.reason);
    for(const name of ['openharmony/native/sysroot/usr/include/stdint.h','openharmony/native/sysroot/usr/lib/aarch64-linux-ohos/libc.so',
      'openharmony/ets/build-tools/ets-loader/main.js','hms/native/BiSheng/bin/clang++.exe']) {
      const filename=path.join(item.root,name),stamp=fs.statSync(filename).mtime;
      const bytes=fs.readFileSync(filename);bytes[bytes.length-1]^=1;fs.writeFileSync(filename,bytes);fs.utimesSync(filename,stamp,stamp);
      const after=item.run();assert.equal(after.state,'AVAILABLE',after.reason??after.qualification?.reason);assert.notEqual(after.key,before.key,name);before=after;
    }
  });

  check('unused bytes do not enter content scope, but every member and empty directory remains identity',()=>{
    const item=fixture('unused'),before=item.run();assert.equal(before.state,'AVAILABLE',before.reason);
    item.write('openharmony/native/llvm/bin/clangd.exe','different unrelated debugger binary');
    item.write('openharmony/native/docs/unused.txt','different unconsumed docs');
    assert.equal(item.run().key,before.key);
    fs.mkdirSync(path.join(item.root,'openharmony/native/docs/new-empty-directory'));
    const added=item.run();assert.notEqual(added.key,before.key);assert.notEqual(added.identity.membershipSha256,before.identity.membershipSha256);
    item.write('openharmony/native/sysroot/usr/include/new-shadow.h','new same-search-root header');assert.notEqual(item.run().key,added.key);
  });

  check('scope parameters alter identity and unknown ABI/product/version cannot qualify',()=>{
    const item=fixture('scope'),before=item.run();
    assert.notEqual(item.run({compilerArguments:['-fno-exceptions']}).key,before.key);
    for(const extra of [{abi:'x86_64'},{product:'store'},{nativeCompiler:'OtherCompiler'},{mode:'release'},{platform:'linux'}])assert.equal(item.run(extra).state,'UNAVAILABLE');
    item.write('openharmony/ets/oh-uni-package.json',JSON.stringify({version:'26.0.0.999',apiVersion:'26',path:'ets'}));
    assert.equal(item.run().state,'UNAVAILABLE');
  });

  check('unknown component layout rejects availability before it can be used as quick proof',()=>{
    const item=fixture('layout');fs.mkdirSync(path.join(item.root,'unknown-component'));
    const value=item.run();assert.equal(value.state,'UNAVAILABLE');assert.match(value.reason,/Unknown SDK layout/);
  });

  check('missing previous native graph preserves content identity while quick qualification is unavailable',()=>{
    const item=fixture('missing-graph'),before=item.run();
    const missing=item.run({nativeEvidenceReader:()=>{throw new Error('existing native graph missing');}});
    assert.equal(missing.state,'UNAVAILABLE');assert.equal(missing.qualification.state,'UNAVAILABLE');assert.deepEqual(missing.identity,before.identity);
    assert.equal(item.run().key,missing.key);
  });

  check('observed dependencies or compiler outside selected scope cannot be silently ignored',()=>{
    const item=fixture('outside-consumer'),before=item.run();assert.equal(before.state,'AVAILABLE',before.reason);
    item.write('openharmony/native/sysroot/usr/include/arm-linux-ohos/other.h','foreign ABI header');
    item.proof.dependencyText+=slash(path.join(item.root,'openharmony/native/sysroot/usr/include/arm-linux-ohos/other.h'))+'\n';
    assert.match(item.run().qualification.reason,/outside declared consumer scope/);
    item.proof.dependencyText='';assert.match(item.run().qualification.reason,/No SDK header/);
    item.proof.dependencyText=slash(path.join(item.root,'openharmony/native/sysroot/usr/include/stdint.h'));
    item.proof.buildNinja='LINK_PATH = -L'+slash(path.join(item.root,'openharmony/native/sysroot/usr/lib/arm-linux-ohos')).replace(':','$:');
    assert.match(item.run().qualification.reason,/outside declared consumer scope/);
    item.proof.compileCommands=[{command:'"'+slash(path.join(item.root,'openharmony/native/llvm/bin/clang.exe'))+'" --target=aarch64-linux-ohos --sysroot=x'}];
    assert.match(item.run().qualification.reason,/compiler lies outside/);
  });

  check('normal and delayed adjacent DLL dependencies are parsed and bound by content',()=>{
    const item=fixture('dll');item.write('hms/native/BiSheng/bin/clang.exe',pe({normal:'localdep.dll',delay:'delaydep.dll'}));
    item.write('hms/native/BiSheng/bin/localdep.dll',pe());item.write('hms/native/BiSheng/bin/delaydep.dll',pe());
    assert.deepEqual(peImports(path.join(item.root,'hms/native/BiSheng/bin/clang.exe')),['localdep.dll','delaydep.dll']);
    const before=item.run();assert.equal(before.state,'AVAILABLE',before.reason);
    const bytes=pe();bytes[0xf00]=1;item.write('hms/native/BiSheng/bin/delaydep.dll',bytes);assert.notEqual(item.run().key,before.key);
    item.write('hms/native/BiSheng/bin/clang.exe',pe({normal:'unknown-not-installed.dll'}));assert.match(item.run().reason,/Unresolved non-system/);
  });

  check('links even in unused directories must stay inside the bundle and cycles are rejected',()=>{
    for(const kind of ['escape','cycle']) {
      const item=fixture('link-'+kind),outside=path.join(output,'outside-'+kind);fs.mkdirSync(outside);
      const target=kind==='escape'?outside:path.join(item.root,'openharmony/native/docs');
      fs.symlinkSync(target,path.join(item.root,'openharmony/native/docs/link'),process.platform==='win32'?'junction':'dir');
      const value=item.run();assert.equal(value.state,'UNAVAILABLE');assert.match(value.reason,kind==='escape'?/escapes/:/cycle/);
    }
    const item=fixture('internal-link');const before=item.run();
    fs.symlinkSync(path.join(item.root,'openharmony/native/docs'),path.join(item.root,'openharmony/native/docs-alias'),process.platform==='win32'?'junction':'dir');
    // 新的未登记native顶层成员本身就是未知布局，不能利用链接别名绕过范围检查。
    assert.equal(item.run().state,'UNAVAILABLE');assert.ok(before.key);
    const metadata=fixture('metadata-link'),outside=path.join(output,'outside-ets');
    fs.renameSync(path.join(metadata.root,'openharmony/ets'),outside);
    fs.symlinkSync(outside,path.join(metadata.root,'openharmony/ets'),process.platform==='win32'?'junction':'dir');
    assert.match(metadata.run().reason,/escapes/);
  });
} finally {
  // 汇总和进程共用结论；不另维护容易随新增用例失真的固定总数。
  const state=cases.length>0&&cases.every(row=>row.state==='PASS')?'PASS':'FAIL';
  fs.writeFileSync(path.join(output,'summary.json'),JSON.stringify({completedAt:new Date().toISOString(),state,cases},null,2)+'\n');
  if(state!=='PASS')process.exitCode=1;
}
