/** 执行真实启动参数桥：平台Agent最先安装，现有Agent相对顺序、诊断参数及不可变输入保留。 */
import assert from 'node:assert/strict';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';
const runtimeJar = 'amcl-audio-service-agent-' + 'a'.repeat(64) + '.jar';
const load = makePureEtsLoader({'./AudioServiceCompatibilityArtifact': {AUDIO_SERVICE_AGENT_RUNTIME_JAR: runtimeJar}});
const {applyAudioServiceCompatibility: apply, audioServiceCompatibilityPath: path} =
  load('launch/src/main/ets/AudioServiceCompatibility.ets');
const directory = '/private/files';
const source = ['-javaagent:/user/A.jar', '-Damcl.audio.diagnostics=1', '-javaagent:/user/B.jar'];
const result = apply(source, directory);
assert.deepEqual(source, ['-javaagent:/user/A.jar', '-Damcl.audio.diagnostics=1', '-javaagent:/user/B.jar']);
assert.equal(result[0], '-Damcl.audio.enabled=true');
assert.equal(result[1], '-Damcl.audio.service.schema=1');
assert.equal(result[2], '-javaagent:' + path(directory));
assert.deepEqual(result.slice(3), source);
for (const override of ['-Damcl.audio.enabled', '-Damcl.audio.enabled=false', '-Damcl.audio.service.schema=0',
  '-javaagent:' + path(directory), '-javaagent:' + directory + '/runtime-compat/amcl-audio-service-agent-old.jar']) {
  assert.throws(() => apply([override], directory), /平台音频组件/);
}
console.log('PASS audio service launch ordering, immutable inputs, diagnostic preservation and reserved identity rejection');
