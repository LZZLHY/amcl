import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {readUniqueZipEntry} from './zip-entry-buffer.mjs';
const file=path.resolve(process.argv[2]??'entry/build/default/outputs/default/entry-default-signed.hap');
const hap=fs.readFileSync(file),abc=readUniqueZipEntry(hap,'ets/modules.abc');
// Known-positive and negative controls ensure this artifact reader actually inspects the ABC.
if(!abc.includes(Buffer.from('EntryAbility'))||abc.includes(Buffer.from('__amcl_impossible_artifact_canary_79b15__')))throw new Error('Artifact reader control failed');
const expected=['ModInstallService','ModInstallTransaction','ModZipReader','ModVersionRange','ModUpdatePolicy','NestedModSearch','ensureModDirectory','mod plan committed:','模组依赖与兼容性'];
for(const marker of expected)if(!abc.includes(Buffer.from(marker)))throw new Error('HAP lacks '+marker);
const result={path:file,bytes:hap.length,sha256:crypto.createHash('sha256').update(hap).digest('hex'),abcSha256:crypto.createHash('sha256').update(abc).digest('hex'),markers:expected};
console.log(JSON.stringify(result,null,2));
if(process.argv[3])fs.writeFileSync(process.argv[3],JSON.stringify(result,null,2));
