/**
 * 真实包格式的宿主要求回归。执行生产ArkTS，仅替换Kit文件边界；可重复传--archive
 * 读取冻结ZIP中的真实清单，Python只向stdout读内容，不解包、不执行包内代码。
 * 正常CI覆盖大清单、旧构建契约、导入收据冲突和错误输入，避免只测试几十字节声明。
 */
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';

const files=new Map();let protocols=[1,2];
const missing=()=>Object.assign(Error('ENOENT'),{code:'ENOENT'});
const io={statSync(path){if(!files.has(path))throw missing();return{size:Buffer.byteLength(files.get(path)),isFile:()=>true};},
  readTextSync(path){if(!files.has(path))throw missing();return files.get(path);}};
const check=makePureEtsLoader({'@kit.CoreFileKit':{fileIo:io},
  // 本套只测ABI/格式边界；当前App行为要求由test-runtime-compatibility使用真实配置覆盖。
  './RuntimeHostProtocol':{runtimeHostProtocols:()=>protocols,runtimeRequiredCapabilities:()=>[]}})('launch/src/main/ets/RuntimeHostDeclaration.ets').validateRuntimeHostDeclaration;
const root='/fixture',manifest=root+'/amcl-runtime.json',receipt=root+'/.amcl-runtime-receipt.json';
const patch='0025-ohos-javasound-duplex-host-callbacks.patch';
const legacy={schema:1,build:{patches:{[patch]:'a'.repeat(64)}},nativeLibraries:{inventory:'x'.repeat(2*1024*1024)}};
files.set(manifest,JSON.stringify(legacy));
assert.equal(check(root,2),'');protocols=[1];assert.match(check(root),/不兼容/);protocols=[1,2];
files.set(receipt,JSON.stringify({build:{requiredHostProtocol:1}}));assert.match(check(root,1),/不一致/);files.delete(receipt);
files.set(manifest,JSON.stringify({...legacy,requiredHostProtocol:9}));assert.match(check(root),/不兼容/);
files.set(manifest,JSON.stringify({schema:1,build:{patches:{[patch]:'not-a-hash'}}}));assert.match(check(root),/摘要无效/);
files.set(manifest,'x'.repeat(16*1024*1024+1));assert.match(check(root),/大小无效/);
files.delete(manifest);files.set(receipt,'x'.repeat(1024*1024+1));assert.match(check(root),/大小无效/);files.clear();
files.set(manifest,'{broken');assert.match(check(root),/无法确认/);files.clear();assert.equal(check(root),'');

const actual=[];
for(let i=2;i<process.argv.length;i++){
  assert.equal(process.argv[i],'--archive');const archive=process.argv[++i];assert(archive);
  const processResult=spawnSync(process.env.AMCL_PYTHON||'python',['-B','-c',
    'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); i=z.getinfo("amcl-runtime.json"); assert i.file_size<=16777216; sys.stdout.buffer.write(z.read(i))',archive],
    {encoding:'utf8',maxBuffer:17*1024*1024});
  assert.equal(processResult.status,0,processResult.stderr);files.set(manifest,processResult.stdout);
  protocols=[1,2];assert.equal(check(root,2),'');protocols=[1];assert.match(check(root),/不兼容/);
  actual.push({archive,manifestBytes:Buffer.byteLength(processResult.stdout),host2:'accepted',host1:'rejected'});files.clear();
}
console.log(JSON.stringify({passed:9,actual,scope:'production metadata parser; no device or runtime execution'},null,2));
