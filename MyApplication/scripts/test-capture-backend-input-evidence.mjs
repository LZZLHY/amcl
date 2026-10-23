/** PowerShell采集器的实际函数回归；只调用解析测试，不启动采集器或HDC。 */
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const root=path.resolve(import.meta.dirname,'..');
// 格式闭包来自真实生产日志声明；实际判定仍由下面的PowerShell函数执行，而非源码正则代替。
const emitter=fs.readFileSync(path.join(root,'entry/src/main/cpp/input/adapters/backend_input_bridge.cpp'),'utf8');
const start=emitter.indexOf('"AMCL_BACKEND_DELIVERED backend=');
assert.ok(start>=0,'actual delivery log marker');
const end=emitter.indexOf('backend,',start);
assert.ok(end>start,'actual delivery log argument list');
const fields=[...emitter.slice(start,end).matchAll(/([A-Za-z][A-Za-z0-9]*)=%\{public\}/g)].map(match=>match[1]);
const collector=fs.readFileSync(path.join(root,'scripts/capture-backend-input-evidence.ps1'),'utf8');
const required=/\$counts=@\(([^\n]+)\)/.exec(collector);
assert.ok(required,'production parser required field list');
assert.deepEqual([...required[1].matchAll(/'([^']+)'/g)].map(match=>match[1]),fields,'parser must follow complete current production fields');
const result=spawnSync('pwsh',['-NoProfile','-File',path.join(root,'scripts/test-capture-backend-input-evidence.ps1')],
  {cwd:root,encoding:'utf8',windowsHide:true,timeout:30000});
if(result.error?.code==='ENOENT'&&process.platform!=='win32'){
  console.log('SKIP Windows Local-HDC PowerShell collector regression: install pwsh to execute it on this host');
}else{
  process.stdout.write(result.stdout??'');process.stderr.write(result.stderr??'');
  if(result.error)throw result.error;
  if(result.status!==0)throw new Error('production PowerShell collector regression failed status='+result.status);
}
