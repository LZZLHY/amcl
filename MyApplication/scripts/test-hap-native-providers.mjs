/** 独立构造最小ELF负控，验证错来源、错产品HAP字节及strip后篡改不能取得交付证明。 */
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {allocatedElfIdentity,verifyProviderBytes} from './check-hap-native-providers.mjs';
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
console.log('[test-hap-native-providers] PASS valid strip, wrong source/staged/HAP, allocated code/flags/BSS mutation, wrong ABI and truncated ELF');
