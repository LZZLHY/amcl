import assert from 'node:assert/strict';
import { graphicsRuntimeIssues } from './check-graphics-runtime-artifact.mjs';
const fixture = () => ({
  'libmobilegl.so': { soname: 'libMobileGL.so', machine: 183, runpath: [], needed: ['libvulkan.so'], exports: ['mobileglGetPresentedSequenceV1'] },
  'libamcl_vulkan_wsi.so': { soname: 'libamcl_vulkan_wsi.so', machine: 183, runpath: ['$ORIGIN'], needed: ['libc.so', 'libhilog_ndk.z.so'],
    exports: ['vkGetInstanceProcAddr', 'amclVulkanSetAdmission', 'amclVulkanAdmissionGranted',
      'vkGetDeviceProcAddr', 'amclVulkanCreateSurface', 'amclVulkanWindowHasLiveSurface',
      'amclVulkanGetStats', 'amclVulkanGetDeviceProcAddr'] },
  'libamcl_window_host.so': { soname: 'libamcl_window_host.so', machine: 183, runpath: ['$ORIGIN'], needed: ['libc.so', 'libnative_window.so'],
    exports: ['amclWindowHostPublish', 'amclWindowHostUpdateSize', 'amclWindowHostClear', 'amclWindowHostReadSnapshot',
      'amclWindowHostGetBroker', 'amclWindowHostAcquire', 'amclWindowHostRelease', 'amclWindowHostGetStats'] },
  'libamcl_gl_host.so': { soname: 'libamcl_gl_host.so', machine: 183, runpath: ['$ORIGIN'], needed: ['libc.so', 'libhilog_ndk.z.so'],
    exports: ['glGetString', 'eglGetProcAddress', 'glXGetProcAddress', 'glXGetProcAddressARB', 'amclGlHostInitializeV1',
      'amclGlHostGetInitReportV1',
      'amclGlHostGetProcAddressV1', 'amclGlHostGetEglProcAddressV1', 'amclGlHostSourceIdentityV1'], undefined: [] },
  'libamcl_graphics_runtime.so': { soname: 'libamcl_graphics_runtime.so', machine: 183, runpath: ['$ORIGIN'], needed: ['libamcl_window_host.so', 'libc.so'],
    exports: ['amclGraphicsBindRuntimeV1', 'amclGraphicsGlProcV1', 'amclGraphicsEglProcV1', 'amclGraphicsBoundProfileV1',
      'amclGraphicsReadPresentSequenceV1', 'amclGraphicsDispatchPresentV1', 'amclGraphicsRegisterPresentSinkV1',
      'amclGraphicsBoundApiV1', 'amclGraphicsRuntimeOwnerV1', 'amclGraphicsPublishObserverV1', 'amclGraphicsPresentedV1',
      'amclGraphicsSwapV1', 'amclGraphicsFatalV1', 'amclGraphicsForegroundV1', 'amclGraphicsRuntimeJsonV1', 'amclGraphicsFailureJsonV1', 'amclGraphicsObservationEnabledV1', 'amclGraphicsInspectContextV1', 'glXGetProcAddress', 'glXGetProcAddressARB'] },
  'libglfw.so': { soname: 'libglfw.so', machine: 183, runpath: ['$ORIGIN'], needed: ['libamcl_vulkan_wsi.so', 'libamcl_window_host.so', 'libamcl_graphics_runtime.so'],
    exports: ['glfwInitVulkanLoader', 'glfwVulkanSupported', 'glfwGetRequiredInstanceExtensions',
      'glfwGetInstanceProcAddress', 'glfwGetPhysicalDevicePresentationSupport', 'glfwCreateWindowSurface',
      'glfwOHOS_BindGraphicsRuntimeV1', 'glfwOHOS_GraphicsGlProcV1', 'glfwOHOS_GraphicsEglProcV1',
      'glfwOHOS_PublishGraphicsObserverV1', 'glfwOHOS_GraphicsRuntimeJsonV1', 'glfwOHOS_GraphicsFailureJsonV1'] },
  'libentry.so': { soname: 'libentry.so', machine: 183, runpath: ['$ORIGIN'], needed: ['libglfw.so', 'libamcl_vulkan_wsi.so', 'libamcl_window_host.so', 'libamcl_graphics_runtime.so'], exports: [] }
});
assert.deepEqual(graphicsRuntimeIssues(fixture()), []);
// 旧包即使全部中立ABI及依赖存在，提前导出EGL也必须拒绝，避免门禁再次把污染当能力。
for (const name of ['libamcl_graphics_runtime.so', 'libentry.so', 'libamcl_window_host.so']) {
  const intercepted = fixture(); intercepted[name].exports.push('eglGetProcAddress');
  assert.match(graphicsRuntimeIssues(intercepted).join(), /startup EGL provider export eglGetProcAddress/);
}
const oldMobilegl = fixture(); oldMobilegl['libmobilegl.so'].exports = [];
assert.match(graphicsRuntimeIssues(oldMobilegl).join(), /actual-presentation evidence ABI/);
const eager = fixture(); eager['libglfw.so'].needed.push('libamcl_gl_host.so');
assert.match(graphicsRuntimeIssues(eager).join(), /eager translator dependency/);
const missing = fixture(); delete missing['libamcl_vulkan_wsi.so'];
assert.match(graphicsRuntimeIssues(missing).join(), /missing HAP/);
const monolith = fixture(); monolith['libglfw.so'].needed = [];
assert.match(graphicsRuntimeIssues(monolith).join(), /physical WSI dependency/);
const polluted = fixture(); polluted['libamcl_vulkan_wsi.so'].needed.push('libEGL.so');
assert.match(graphicsRuntimeIssues(polluted).join(), /renderer dependency/);
const pollutedWindow = fixture(); pollutedWindow['libamcl_window_host.so'].needed.push('libGLESv3.so');
assert.match(graphicsRuntimeIssues(pollutedWindow).join(), /WindowHost has renderer dependency/);
const exported = fixture(); exported['libamcl_vulkan_wsi.so'].exports = [];
assert.match(graphicsRuntimeIssues(exported).join(), /missing definition/);
const duplicate = fixture(); duplicate['libglfw.so'].exports.push('vkGetInstanceProcAddr');
assert.match(graphicsRuntimeIssues(duplicate).join(), /duplicated/);
const duplicateGl = fixture(); duplicateGl['libglfw.so'].exports.push('glGetString');
assert.match(graphicsRuntimeIssues(duplicateGl).join(), /GLFW duplicates GL\/EGL provider/);
const wrong = fixture(); wrong['libamcl_vulkan_wsi.so'].machine = 62;
assert.match(graphicsRuntimeIssues(wrong).join(), /architecture/);
const hostPath = fixture(); hostPath['libglfw.so'].runpath = ['D:/build/output'];
assert.match(graphicsRuntimeIssues(hostPath).join(), /sibling RUNPATH/);
assert.match(graphicsRuntimeIssues(hostPath).join(), /host build directory/);
console.log('Graphics runtime HAP linkage negative fixtures PASS');

const reverseRuntime = fixture(); reverseRuntime['libamcl_graphics_runtime.so'].needed.push('libglfw.so');
assert.match(graphicsRuntimeIssues(reverseRuntime).join(), /frontend\/translator dependency/);
const duplicateRuntime = fixture(); duplicateRuntime['libglfw.so'].exports.push('amclGraphicsBindRuntimeV1');
assert.match(graphicsRuntimeIssues(duplicateRuntime).join(), /Runtime implementation duplicated/);
