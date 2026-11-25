import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {syncBuiltinESMExports} from 'node:module';
import {fileURLToPath} from 'node:url';

// 增量门用 --import 在夹具装载前记录指定生产源的实际读取；仅在核对该批具名用例的子进程中启用。
const expected=JSON.parse(process.env.AMCL_VERIFY_SKILL_OWNERS ?? '{}');
const owners=new Set(Object.values(expected).map(file=>path.resolve(file)));
const loaded=new Set();
if (owners.size) {
  const read=fs.readFileSync;
  fs.readFileSync=function(file,...args) {
    const result=read.call(this,file,...args);
    const name=file instanceof URL ? fileURLToPath(file) : file;
    if (typeof name==='string' && owners.has(path.resolve(name))) loaded.add(path.resolve(name));
    return result;
  };
  syncBuiltinESMExports();
}

/** 分域用例先执行真实业务函数并核验对象、回读或副作用，再交出两次真实结果供变更检查汇总。 */
export function verifySkillCases(method, success, denied, row='') {
  assert.match(method, /^[a-z][A-Za-z0-9]+$/);
  assert.ok(['ready','accepted','draft','needsUser'].includes(success?.state), method+' missing positive business result');
  assert.ok(['failed','unavailable','unknown','cancelled','busy','needsUser'].includes(denied?.state), method+' missing refusal');
  assert.notDeepEqual(success, denied);
  if (expected[method]) assert.ok(loaded.has(path.resolve(expected[method])), method+' case did not load '+expected[method]);
  if (process.env.AMCL_VERIFY_SKILL_CASES === '1') {
    if (row) assert.match(row,/^L\d{3,}$/);
    console.log('AMCL_SKILL_CASE '+JSON.stringify({method,row,positive:success.state,negative:denied.state}));
  }
}
