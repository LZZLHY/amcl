/** 原ImeCallbackLease规则与共享runtime真实组件的排队旧回调回归；不复制输入状态机。 */
import assert from 'node:assert/strict';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';

// 完整真实组件/runtime/Coordinator已有queued旧callback与wrong-current成功编译反控。
await import('./test-entry-text-input-runtime.mjs');
const pure=makePureEtsLoader();
const {TextInputSessionLease}=pure('gamecontrol/src/main/ets/TextInputSessionCoordinator.ets');
const {ImeCallbackLease}=pure('gamecontrol/src/main/ets/ImeCallbackLease.ets');
const original=new TextInputSessionLease();original.owner='source';original.generation=9;
const scope=new ImeCallbackLease(original,'field');
assert.equal(scope.accepts(scope,original,'field'),true);
assert.equal(scope.accepts(scope,original.copy(),'field'),false);
assert.equal(scope.accepts(scope,original,'chat'),false);
original.generation=10;assert.equal(scope.accepts(scope,original,'field'),false);original.generation=9;
scope.retire();scope.retire();assert.equal(scope.accepts(scope,original,'field'),false);
console.log('PASS original callback scope exact object/frozen fields/role/idempotent retirement');
