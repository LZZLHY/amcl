import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {deflateRawSync} from 'node:zlib';
import {loader,root} from './mod-install-test-runtime.mjs';

const load=loader();
const range=load('mods/src/main/ets/ModVersionRange.ets');
const manifest=load('mods/src/main/ets/ModManifest.ets');
for(const [version,expr,expected] of [
  ['1.10.7+mc1.21.11','<=1.10.7',true],['1.10.7+mc1.21.11','<=1.10.5',false],
  ['0.8.7+mc1.21.11','0.8.x',true],['0.9.0','0.8.x',false],['0.8.0-beta.1','0.8.x',true],
  ['6.6.3','>=6.6.3 <6.7',true],['6.7','>=6.6.3 <6.7',false],
  ['2.3.0','^2.1.0',true],['0.9','^0.8',true],['3.0-alpha','^2.1.0',false],
  ['1.2.3','~1.2',true],['1.3-beta','~1.2',false],['1.2','>=1.2-',true],
  ['1.2-beta.2','>1.2-beta.1',true],['1.2-beta.10','>1.2-beta.2',true],
  ['1.2-1','<1.2-a',true],['opaque','opaque',true],['opaque','different',false],
]){const r=range.matchesModVersion(version,[expr]);assert.equal(r.supported,true,expr);assert.equal(r.matches,expected,version+' '+expr);}
for(const [version,expr,expected] of [['1.20.1','[1.20.1,1.21)',true],['1.21','[1.20.1,1.21)',false],['6','[5,)',true],['1','[1]',true],['3','(,2],[3,)',true]]){
  assert.equal(range.matchesModVersion(version,[expr],'maven').matches,expected,version+' '+expr);
}
assert.equal(range.matchesModVersion('opaque',['>=other']).supported,false);
const fixture=path.join(root,'scripts/fixtures/mod-install');
const zipModule=load('mods/src/main/ets/ModZipReader.ets');
const toArrayBuffer=b=>Uint8Array.from(b).buffer;
assert.equal(zipModule.modCrc32(toArrayBuffer(Buffer.from('123456789'))),0xcbf43926);
function metadataJar(name){
  const raw=JSON.parse(fs.readFileSync(path.join(fixture,name),'utf8'));
  // This fixture tests the exact root declarations.
  delete raw.jars;
  const body=Buffer.from(JSON.stringify(raw)),compressed=deflateRawSync(body),filename=Buffer.from('fabric.mod.json');
  const crc=zipModule.modCrc32(toArrayBuffer(body));
  const local=Buffer.alloc(30);local.writeUInt32LE(0x04034b50,0);local.writeUInt16LE(8,8);local.writeUInt32LE(crc,14);local.writeUInt32LE(compressed.length,18);local.writeUInt32LE(body.length,22);local.writeUInt16LE(filename.length,26);
  const central=Buffer.alloc(46);central.writeUInt32LE(0x02014b50,0);central.writeUInt16LE(8,10);central.writeUInt32LE(crc,16);central.writeUInt32LE(compressed.length,20);central.writeUInt32LE(body.length,24);central.writeUInt16LE(filename.length,28);
  const header=Buffer.concat([local,filename,compressed]),directory=Buffer.concat([central,filename]),end=Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50,0);end.writeUInt16LE(1,8);end.writeUInt16LE(1,10);end.writeUInt32LE(directory.length,12);end.writeUInt32LE(header.length,16);
  return toArrayBuffer(Buffer.concat([header,directory,end]));
}
const iris=await manifest.readModDescriptors('iris.jar','fabric',metadataJar('iris.fabric.mod.json'));
const bad=await manifest.readModDescriptors('sodium-new.jar','fabric',metadataJar('sodium.fabric.mod.json'));
const good=await manifest.readModDescriptors('sodium-pinned.jar','fabric',metadataJar('sodium-pinned.fabric.mod.json'));
const environment={loader:'fabric',loaderVersion:'0.19.5',gameVersion:'1.21.11',javaVersion:'21'};
assert.ok(manifest.validateModSet([...iris,...bad],environment).some(e=>e.includes('iris 1.10.7')&&e.includes('冲突')));
assert.ok(!manifest.validateModSet([...iris,...good],environment).some(e=>e.includes('冲突')));
const ipn=await manifest.readModDescriptors('ipn.jar','fabric',metadataJar('inventoryprofilesnext.fabric.mod.json'));
assert.ok(manifest.validateModSet(ipn,environment).some(e=>e.includes('libipn')&&e.includes('6.6.3')));
assert.ok(manifest.validateModSet([...iris,...iris.map(d=>({...d,file:'different.jar'}))],environment).some(e=>e.includes('重复模组')));
const forge=manifest.parseForgeMods('[[mods]]\nmodId="example"\nversion="1.0"\n[[dependencies.example]]\nmodId="minecraft"\nmandatory=true\nversionRange="[1.20,1.21)"\nside="BOTH"','example.jar','forge');
assert.ok(manifest.validateModSet(forge,{...environment,loader:'forge'}).some(e=>e.includes('minecraft')));
const host={...iris[0],id:'host',name:'host',file:'host.jar',provides:[],breaks:[],depends:[{id:'library',ranges:['<2'],syntax:'fabric',optional:false}]};
const lower={...host,id:'library',name:'library',version:'1.0',file:'host.jar!/library1.jar',nested:true,depends:[]};
const higher={...lower,version:'2.0',file:'host.jar!/library2.jar'};
assert.deepEqual(Array.from(manifest.validateModSet([host,lower,higher],environment)),[],'Nested candidates must satisfy the root instead of unconditionally choosing newest');
const badNested={...lower,depends:[{id:'missing',ranges:['*'],syntax:'fabric',optional:false}]};
assert.ok(manifest.validateModSet([host,badNested],environment).length>0);
assert.equal(manifest.validateModSet([{...host,depends:[]},badNested],environment).length,0,'Unneeded broken nested candidate may be omitted');
console.log('PASS: manifest ranges, CRC32, bounded ZIP with publisher metadata, IPN dependencies, Iris/Sodium reverse conflict, duplicates and Forge interval');
