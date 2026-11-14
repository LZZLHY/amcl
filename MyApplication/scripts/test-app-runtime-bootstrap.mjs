/** 实际HAP ZIP入口与共享发布判据；所有小原件/资格值均为隔离机制夹具。 */
import assert from 'node:assert/strict';
import {runtimeBootstrapIssues} from './check-product-contract.mjs';
function zip(body){
  const name=Buffer.from('resources/rawfile/runtime-catalog/builtin.json'),bytes=Buffer.from(JSON.stringify(body));
  const local=Buffer.alloc(30),central=Buffer.alloc(46),end=Buffer.alloc(22);
  local.writeUInt32LE(0x04034b50);local.writeUInt32LE(bytes.length,18);local.writeUInt32LE(bytes.length,22);local.writeUInt16LE(name.length,26);
  central.writeUInt32LE(0x02014b50);central.writeUInt32LE(bytes.length,20);central.writeUInt32LE(bytes.length,24);central.writeUInt16LE(name.length,28);
  end.writeUInt32LE(0x06054b50);end.writeUInt16LE(1,8);end.writeUInt16LE(1,10);end.writeUInt32LE(central.length+name.length,12);end.writeUInt32LE(local.length+name.length+bytes.length,16);
  return Buffer.concat([local,name,bytes,central,name,end]);
}
const catalog={schemaVersion:2,catalogRevision:5,channel:'stable',issuedAt:'2026-11-01T00:00:00Z',expiresAt:'2099-01-01T00:00:00Z',runtimes:[],builds:[]};
for(const major of [8,17,21,25]){
  const id='java'+major,build='fixed-'+major;
  catalog.runtimes.push({id,javaMajor:major,displayName:'Java '+major,os:'ohos',arch:'aarch64',libc:'musl',adapter:major===8?'classic-jre-v1':'modular-jdk-v1',minimumCatalogProtocol:1,minimumApi:20,recommendationRevision:1,recommendedBuildIds:[build]});
  catalog.builds.push({id:build,runtimeId:id,requiredHostProtocol:2,javaVersion:String(major),legacyTags:[],archive:{type:'zip',fileName:build+'.zip',sha256:'a'.repeat(64),sizeBytes:10},downloads:[{sourceId:'github',transport:'single-file',url:'https://github.com/LZZLHY/mc-ohos-resources/releases/download/ohos-runtimes/'+build+'.zip'}],notes:[],capabilities:['zipfs-transaction-v1'],validationLevel:'device-matrix-tested',provenance:{kind:'source-build',sourceRepository:'https://github.com/openjdk/fixture',sourceCommit:'b'.repeat(40),manifestSha256:'c'.repeat(64),evidence:['fixture only']},status:'available'});
}
const metadata={runtimeHostProtocols:[1,2],runtimeRequiredCapabilities:['zipfs-transaction-v1'],runtimeRequiredMajors:[8,17,21,25]},app={minAPIVersion:60000020};
assert.deepEqual(runtimeBootstrapIssues(zip(catalog),metadata,app),[]);
for(const mutate of [c=>c.schemaVersion=1,c=>c.builds[0].capabilities=[],c=>c.builds[0].validationLevel='artifact-audited',c=>c.runtimes[0].minimumApi=26,c=>c.expiresAt='2026-11-02T00:00:00Z']){
  const bad=structuredClone(catalog);mutate(bad);assert(runtimeBootstrapIssues(zip(bad),metadata,app).length>0);
}
assert(runtimeBootstrapIssues(zip(catalog),{...metadata,runtimeHostProtocols:[1]},app).length>0);
console.log('PASS actual HAP runtime bootstrap: four-major stable coverage, ABI/capability/qualification/expiry and minimum API');
