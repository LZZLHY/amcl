import assert from 'node:assert/strict';
import { probeEvidence, launchEvidence, exitEvidence, swapchainEvidence } from './check-mobilegl-device-evidence.mjs';
const commit = 'a'.repeat(40);
const probe = `MobileGL DirectVulkan 出帧探针
GIT@aaaaaaa
provider glGetString direct=0x11 proc=0x11 image=/bundle/libmobilegl.so
provider glGetIntegerv direct=0x12 proc=0x12 image=/bundle/libmobilegl.so
provider glGetError direct=0x13 proc=0x13 image=/bundle/libmobilegl.so
GPU texture content survived pbuffer -> window
GPU texture content survived window -> pbuffer
${[1,2,3,4,5].map(n => `AMCL_MOBILEGL_PRESENT successful=${n}`).join('\n')}
eglTerminate OK
✅ PASS`;
probeEvidence(probe, commit);
assert.throws(() => probeEvidence(probe + '\nMobileGL DirectVulkan 出帧探针\n[X] failed', commit));
assert.throws(() => probeEvidence(probe.replace('proc=0x11', 'proc=0x99'), commit));
assert.throws(() => probeEvidence(probe.replace('/bundle/libmobilegl.so', '/system/libGLESv3.so'), commit));
assert.throws(() => probeEvidence(probe.replace('successful=5', 'successful=4'), commit));
assert.throws(() => probeEvidence(probe.replace('eglTerminate OK', 'eglTerminate failed'), commit));
assert.throws(() => probeEvidence(probe, 'b'.repeat(40)));
const launch = '09-06 17:00 42 43 I LOG Using graphics backend OpenGL MobileGL GIT@aaaaaaa\n09-06 17:01 42 43 I LOG event=create role=presented';
launchEvidence(launch, commit);
assert.throws(() => launchEvidence(launch.replace('17:01 42', '17:01 99'), commit));
const exit = '09-06 17:00 42 43 I LOG Stopping!\n09-06 17:01 42 43 I LOG OPENHARMONY_WINDOW schema=1 event=summary swap_ok=10 swap_fail=0 makecurrent_fail=0 config_mismatch=0 input_to_auxiliary=0 presented_notify=10 presented_swap_success=10 balanced=1 lease_acquire=2 lease_release=2 aux_create_ok=1 aux_destroy=1 presented_create_ok=1 presented_destroy=1';
exitEvidence(exit);
for (const [from, to] of [['swap_fail=0', 'swap_fail=1'], ['lease_release=2', 'lease_release=1'],
  ['balanced=1', 'balanced=0'], ['Stopping!', 'Still running'], ['17:00 42', '17:00 99']]) {
  assert.throws(() => exitEvidence(exit.replace(from, to)));
}
const geometry = (width, height, transform = 'ROTATE_90') =>
  `09-06 17:00 42 43 I LOG Swapchain currentTransform = ${transform}\n09-06 17:00 42 43 I LOG Swapchain created, extent = ${width}x${height}\n`;
swapchainEvidence(geometry(320, 480) + geometry(2688, 1216));
assert.throws(() => swapchainEvidence(geometry(2688, 1216) + geometry(1216, 2688) + geometry(2688, 1216) + geometry(1216, 2688)));
swapchainEvidence(geometry(2688, 1216) + geometry(1216, 2688, 'IDENTITY'));
assert.throws(() => swapchainEvidence(''));
console.log('MobileGL device evidence negative controls: PASS');
