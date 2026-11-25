/** 独立构造最小ELF负控，验证错来源、错产品HAP字节及strip后篡改不能取得交付证明。 */
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {allocatedElfIdentity,lockedBundleProvider,verifyProviderBytes} from './check-hap-native-providers.mjs';
import {readSdl3ArtifactLock} from './lib/sdl3-artifact-lock.mjs';
const sha=b=>createHash('sha256').update(b).digest('hex');
/** 构造含真实ELF64节表、ALLOC可执行代码、NOBITS及非装载调试节的独立固定样本。 */
function elf({code=1,debug=1,sectionFlags=6,nobits=64}={}){
  const b=Buffer.alloc(1024);Buffer.from([127,69,76,70,2,1,1]).copy(b);b.writeUInt16LE(3,16);b.writeUInt16LE(183,18);
  b.writeBigUInt64LE(512n,40);b.writeUInt16LE(64,58);b.writeUInt16LE(5,60);b.writeUInt16LE(1,62);
  const names=Buffer.from('\0.shstrtab\0.text\0.bss\0.debug\0');names.copy(b,128);b[200]=code;b[220]=debug;
  function section(i,name,type,flags,address,offset,size){const p=512+i*64;b.writeUInt32LE(name,p);b.writeUInt32LE(type,p+4);b.writeBigUInt64LE(BigInt(flags),p+8);b.writeBigUInt64LE(BigInt(address),p+16);b.writeBigUInt64LE(BigInt(offset),p+24);b.writeBigUInt64LE(BigInt(size),p+32);}
  section(1,1,3,0,0,128,names.length);section(2,11,1,sectionFlags,4096,200,1);section(3,17,8,3,8192,0,nobits);section(4,22,1,0,0,220,1);return b;
}
const origin=elf(),stripped=elf({debug:2}),input={artifact:'libexample.so',origin,staged:origin,stripped,embedded:stripped,expectedSourceSha256:sha(origin)};
assert.equal(verifyProviderBytes(input).hapEntrySha256,sha(stripped));
assert.deepEqual(allocatedElfIdentity(origin),allocatedElfIdentity(stripped));
assert.throws(()=>verifyProviderBytes({...input,expectedSourceSha256:'0'.repeat(64)}),/locked prebuilt/);
assert.throws(()=>verifyProviderBytes({...input,staged:elf({code:2})}),/origin\/staged/);
assert.throws(()=>verifyProviderBytes({...input,embedded:elf({code:2})}),/stripped\/HAP/);
for(const changed of [elf({code:2}),elf({sectionFlags:2}),elf({nobits:32})]){
  assert.throws(()=>verifyProviderBytes({...input,stripped:changed,embedded:changed}),/allocated|executable/);
}
const wrongArch=Buffer.from(origin);wrongArch.writeUInt16LE(62,18);assert.throws(()=>allocatedElfIdentity(wrongArch),/AArch64/);
const truncated=origin.subarray(0,700);assert.throws(()=>allocatedElfIdentity(truncated),/section table/);
// 直接从当前模块清单走与 HAP 相同的锁选择路径，覆盖 SDL 与普通预编译库两种格式。
const root=resolve(import.meta.dirname,'..');
const {modules}=JSON.parse(readFileSync(resolve(root,'prebuilt/lwjgl3/target-manifest-coverage.json'),'utf8'));
const fields=readSdl3ArtifactLock(root);
const sdl=modules.find(module=>module.name==='lwjgl-sdl');
const sdlLock=lockedBundleProvider(root,modules,'libSDL3.so');
assert.equal(sdlLock.sha256,fields.get('sha256'));
assert.equal(sdlLock.size,Number(fields.get('size')));
assert.deepEqual(sdlLock.hap,{size:Number(fields.get('hap_size')),sha256:fields.get('hap_sha256')});
assert.throws(()=>lockedBundleProvider(root,[sdl,sdl],'libSDL3.so'),/unique locked provider/);
assert.throws(()=>lockedBundleProvider(root,[],'libSDL3.so'),/unique locked provider/);
assert.throws(()=>lockedBundleProvider(root,[{...sdl,native:{...sdl.native,sha256:sdlLock.sha256}}],'libSDL3.so'),/without inline/);
// 分配器的同名 SO 必须属于独立锁节，错绑 SDL 或复制 inline 摘要都不能放行。
const allocator=modules.find(module=>module.name==='lwjgl-jemalloc');
const allocatorLock=lockedBundleProvider(root,modules,'libamcl_lwjgl_jemalloc.so');
assert.equal(allocatorLock.sha256,sha(readFileSync(resolve(root,allocator.native.artifact))));
assert.deepEqual(allocatorLock.hap,{size:allocatorLock.size,sha256:allocatorLock.sha256});
assert.throws(()=>lockedBundleProvider(root,[{...allocator,native:{...allocator.native,lockSection:'sdl3-native'}}],
  'libamcl_lwjgl_jemalloc.so'),/jemalloc-native/);
const freetype=modules.find(module=>module.name==='lwjgl-freetype');
assert.equal(lockedBundleProvider(root,modules,'libfreetype.so').sha256,freetype.native.sha256);
assert.throws(()=>lockedBundleProvider(root,[{...freetype,native:{...freetype.native,sha256:''}}],'libfreetype.so'),/source SHA-256/);
assert.throws(()=>verifyProviderBytes({...input,expectedSourceSize:origin.length+1}),/source size/);
assert.equal(verifyProviderBytes({...input,expectedHap:{size:stripped.length,sha256:sha(stripped)}}).hapEntrySha256,sha(stripped));
assert.throws(()=>verifyProviderBytes({...input,expectedHap:{size:stripped.length,sha256:sha(origin)}}),/locked HAP/);
assert.throws(()=>verifyProviderBytes({...input,expectedHap:{size:stripped.length+1,sha256:sha(stripped)}}),/locked HAP/);
console.log('[test-hap-native-providers] PASS unique SDL and inline provider locks, raw/strip identities, source/staged/HAP chain, allocated image and ELF controls');
