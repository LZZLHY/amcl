/**
 * 产物门禁负向测试：保留所有新标记但夹带旧求解器必须失败，缺失事务保障也必须失败。
 * 使用内存 ABC 标记避免生成假 HAP；ZIP 条目唯一性由已有 test-zip-entry-buffer 覆盖。
 */
import assert from 'node:assert/strict';
import {verifyModInstallAbc, requiredModMarkers, retiredModMarkers} from './check-mod-install-artifact.mjs';

const body = markers => Buffer.from(['EntryAbility', ...markers].join('\0'));
assert.doesNotThrow(() => verifyModInstallAbc(body(requiredModMarkers)));
for (const marker of retiredModMarkers) {
  assert.throws(() => verifyModInstallAbc(body([...requiredModMarkers, marker])), /retains retired mod gate/);
}
for (const marker of requiredModMarkers) {
  assert.throws(() => verifyModInstallAbc(body(requiredModMarkers.filter(value => value !== marker))), /HAP lacks/);
}
assert.throws(() => verifyModInstallAbc(Buffer.alloc(0)), /reader control/);
assert.throws(() => verifyModInstallAbc(body([...requiredModMarkers, '__amcl_impossible_artifact_canary_79b15__'])), /reader control/);
console.log('PASS: mod artifact requires transaction/startup-state markers and rejects retired compatibility gates');
