/** 宿主输入准备的有界HTTP/真实pin/外置落盘回归；小流量替身不替代生产锁定摘要。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { receivePinnedTool,prepareSideloadHostInputs } from './prepare-sideload-host-inputs.mjs';
import { createHostTestScope } from './lib/host-test-lifecycle.mjs';
const scope=createHostTestScope('sideload-inputs-'),bytes=Buffer.from('bounded pinned input');
const digest=crypto.createHash('sha256').update(bytes).digest('hex');
const pin={url:'https://raw.githubusercontent.com/openharmony/test/fixed/tool.jar',sha256:digest};
let requests=0;
const request=async()=>{requests++;return new Response(bytes,{status:200,headers:{'content-length':String(bytes.length)}});};
assert.deepEqual(await receivePinnedTool(pin,{request}),bytes);assert.equal(requests,1);
await assert.rejects(receivePinnedTool({...pin,sha256:'a'.repeat(64)},{request}),/SHA/);
await assert.rejects(receivePinnedTool(pin,{request,maxBytes:3}),/size/);
await assert.rejects(receivePinnedTool(pin,{request:async()=>new Response(bytes,{status:503})}),/request failed/);
await assert.rejects(receivePinnedTool(pin,{maxBytes:3,request:async()=>new Response(new ReadableStream({start(controller){controller.enqueue(bytes);controller.close();}}))}),/stream exceeds/);
const local=path.join(scope.directory,'local.jar');fs.writeFileSync(local,bytes);
assert.deepEqual(await receivePinnedTool(pin,{source:local,request:async()=>{throw Error('must not fetch local input');}}),bytes);
fs.writeFileSync(local,'bad');await assert.rejects(receivePinnedTool(pin,{source:local}),/SHA/);
await assert.rejects(prepareSideloadHostInputs({output:'relative-output',request}),/absolute external/);
await assert.rejects(prepareSideloadHostInputs({output:path.resolve(import.meta.dirname,'fake-raw'),request}),/outside/);
// 公开CLI永远取仓库pin。即便网络替身成功响应小fixture，也不能把它变成可运行的生产签名工具。
const invalidOutput=path.join(scope.directory,'invalid-output');
await assert.rejects(prepareSideloadHostInputs({output:invalidOutput,request}),/SHA/);
assert.equal(fs.existsSync(path.join(invalidOutput,'sideload/hap-sign-tool.jar')),false);
assert.equal(fs.existsSync(path.join(invalidOutput,'sideload-host-inputs.json')),false);
console.log('PASS sideload input preparation: fixed production pin, bounded streams, explicit external root, no partial success and verified local source');
