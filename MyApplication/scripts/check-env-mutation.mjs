#!/usr/bin/env node
// scripts/check-env-mutation.mjs
//
// ============================ 它挡的是什么 ============================
//
// I27-05：进程环境的写入与任意线程上的 getenv 构成数据竞争。musl 的 setenv 每次 malloc 新的
// "NAME=value"、替换 environ 槽位后 free 旧串；新名字还会 realloc 整个 environ 数组；unsetenv
// 原地压缩数组。SDL 每帧读前台位、LWJGL2 每帧读尺寸、JVM/libc 随时读 TZ 等 —— 游戏/JVM 线程
// 出现后，任何线程上的一次 setenv/unsetenv/putenv 都可能让读者碰到已释放内存或错位数组。
//
// 本门禁把“谁还在改环境”钉成一张显式清单：扫描首方原生源码、LWJGL2 预编译后端源码与 SDL3
// 补丁的新增行，找出全部 setenv / unsetenv / putenv / clearenv / _putenv(_s) /
// SDL_setenv_unsafe / SDL_unsetenv_unsafe 调用，以及清单登记过的“转发包装”（publishEnv、
// writeEnvironment、PublishEnvironment）的每个调用点。每个调用点必须在 ALLOWLIST 里按
// （文件, 所在函数, 调用, 第一个实参）登记 phase 与理由；清单外的调用点、清单里已不存在的
// 条目、次数不符、顺序锚点失守，全部失败。
//
// ============================ phase 的含义 ============================
//
//   pre-thread               在第一个游戏/JVM 线程出现之前执行（NAPI 模块初始化、同步的
//                            mcLaunchWithProfileV2、jvmInit 的 JNI_CreateJavaVM 之前），或在
//                            刚 fork 的单线程子进程里执行；进程常量描述符另有一次性守卫。
//   slot-registry            platform/env_slot.h 自身：登记期 putenv 进程期静态缓冲区，之后只原位改值。
//   pending-prebuilt-rebuild 预编译库（SDL3 补丁、LWJGL2 后端）里仍在运行期改环境的点，待 batch 4
//                            重建预编译库时改为槽位/显式 ABI；只允许出现在 prebuilt/。

// ============================ 名字级规则（不依赖清单） ============================
//
// SLOT_NAMES：env_slot.h 预登记的静态槽位。首方（非 prebuilt/）代码任何直接 setenv/unsetenv/putenv
// 这些名字都会把槽位从 environ 摘走，之后宿主的原位写入全部失效 ⇒ 直接失败，清单也放行不了。
// RETIRED_NAMES：已随 I27-05 删除写者的名字（无读者或已由 ABI/原子量取代）。首方代码重新写它们
// 直接失败；预编译库里残留的写点只能以 pending-prebuilt-rebuild 登记。
//
// ============================ 它不能证明什么 ============================
//
// ❌ 不证明 pre-thread 条目在运行期确实早于线程：这是按源码顺序与调用方人工核对后的登记，
//    理由写在 why 里；before 锚点与 ORDER_PINS 只把其中可机械核对的顺序钉住。
// ❌ 不扫第三方库（openal-soft、third_party、MobileGlues 上游）与宿主测试（tests/host 不进 HAP）。
// ❌ 不理解宏展开：包在宏里的调用只按宏定义所在行记为 <preprocessor>。
// ❌ 函数归属是文本启发式（C/C++ 花括号作用域；补丁用 hunk 内最近的顶格定义行）；作用域
//    建模失衡且文件里有调用点时直接失败，不猜。

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');

export const PHASES = new Set(['pre-thread', 'slot-registry', 'pending-prebuilt-rebuild']);
export const MUTATION_CALLS = ['setenv', 'unsetenv', 'putenv', 'clearenv', '_putenv_s', '_putenv',
  'SDL_setenv_unsafe', 'SDL_unsetenv_unsafe'];

const CPP_ROOT = 'entry/src/main/cpp';
const SLOT_HEADER = `${CPP_ROOT}/platform/env_slot.h`;
const SOURCE_EXT = /\.(?:c|cc|cpp|cxx|h|hh|hpp|inc|ipp)(?:\.in)?$/;
// 第三方与非产品目录：目录级排除，与 check-cpp-runtime-assert.mjs 的 vendored 判据一致，
// 另加宿主测试（tests/host 只编宿主可执行文件，不进 HAP）与构建产物目录。
const EXCLUDED_PREFIXES = [
  'entry/src/main/cpp/openal/openal-soft/',
  'entry/src/main/cpp/third_party/',
  'entry/src/main/cpp/tests/host/',
];
const EXCLUDED_SEGMENTS = new Set(['mobileglues', 'build', '.cxx', 'node_modules', 'oh_modules', '.hvigor']);
const LWJGL2_BACKEND = 'prebuilt/lwjgl2/ohos-backend';
const SDL3_PATCHES = 'prebuilt/sdl3/patches';

export const SLOT_NAMES = new Map([
  ['AMCL_WINDOW_FOREGROUND', ['kWindowForegroundEnv']],
  ['AMCL_WINDOW_WIDTH', ['kWindowWidthEnv']],
  ['AMCL_WINDOW_HEIGHT', ['kWindowHeightEnv']],
  ['AMCL_RENDERER_REQUIRES_PROCESS_RESTART', ['kRendererRestartEnv']],
  ['AMCL_SDL_HOST_RUNTIME', ['kSdlHostRuntimeEnv']],
  ['AMCL_CALLBACK_BRIDGE_HOST_V1', ['AMCL_CALLBACK_BRIDGE_HOST_ENV']],
  ['AMCL_ENV_SLOT_REGISTRY_V1', ['kRegistryEnv']],
]);
// 退役名的常量别名：AMCL_CURSOR_MODE 只以占位槽位登记（给预编译 LWJGL2 写者），宿主从不写它。
const RETIRED_ALIASES = new Map([['kCursorModePlaceholderEnv', 'AMCL_CURSOR_MODE']]);
export const RETIRED_NAMES = new Map([
  ['AMCL_CURSOR_MODE', 'no reader; grab state is the inputBridge atomic (isGrabbing); only a placeholder slot remains for the prebuilt LWJGL2 writer'],
  ['AMCL_WINDOW_GENERATION', 'no reader in any shipped image'],
  ['AMCL_NATIVE_WINDOW', 'window host broker/snapshot is the only NativeWindow channel'],
  ['AMCL_NATIVE_WINDOW_SNAPSHOT', 'no reader since SDL patch 0003'],
  ['AMCL_GRAPHICS_FOREGROUND', 'replaced by the in-image atomic of libamcl_graphics_runtime'],
  ['AMCL_VULKAN_WSI_GIPA', 'loader identity is logged directly at admission'],
]);

// 把第一个实参规范化成环境名：字符串字面量取内容；标识符取最后一段并按别名映射。
export function canonicalName(argument) {
  const text = String(argument ?? '').trim();
  const literal = /^"([^"\\]*)"$/.exec(text);
  if (literal) return literal[1];
  const identifier = /^(?:[A-Za-z_][A-Za-z0-9_]*::)*([A-Za-z_][A-Za-z0-9_]*)$/.exec(text);
  if (!identifier) return null;
  for (const [name, aliases] of SLOT_NAMES) if (aliases.includes(identifier[1])) return name;
  return RETIRED_ALIASES.get(identifier[1]) ?? identifier[1];
}

// ============================ 放行清单 ============================
// 键：file + function + call + name（第一个实参的规范化文本）；补丁另带 target（被改文件）。
// count 缺省为 1；name '*' 匹配同一 (file, function, call) 下所有未被精确条目认领的实参。
// wrapper：本条是该转发函数的函数体，同文件里对它的每次调用都成为调用点，必须另行登记。
// before：同一函数内、该调用点之后必须出现的锚点文本（钉住“早于建 JVM / 起线程”这类顺序）。
const MC = 'entry/src/main/cpp/jvm/mc_launcher.cpp';
const JVM = 'entry/src/main/cpp/jvm/jvm_launcher.cpp';
const FORK = 'entry/src/main/cpp/jvm/fork_run_java.cpp';
const BEFORE_JVM = 'if (!phase_initJvmWithClasspath(';
const BEFORE_CREATE_VM = 'createVM(&jvm';
const LAUNCH_WHY = 'launchWithProfileImpl runs synchronously on the UI thread (mcLaunchWithProfileV2); every write precedes phase_initJvmWithClasspath → jvmInit → JNI_CreateJavaVM and std::thread(mcLaunchThreadWithProfile)';
const JVMINIT_WHY = 'jvmInit sets JVM bootstrap variables after the creation claim and before createVM on the same thread; no JVM or game thread exists yet';
const FORK_WHY = 'childMain runs in a freshly forked single-threaded child before it creates its own JVM';
const DEVTOOLS_WHY = 'DevTools probe (MC_OHOS_BUILD_TESTS only); napi_tests.cpp refuses to run it once the env registry is sealed (JVM claimed), so it only mutates env before any JVM/game thread exists';

function launch(name, count = 1) {
  return { file: MC, function: 'launchWithProfileImpl', call: name.call ?? 'setenv', name: name.name ?? name,
    count, phase: 'pre-thread', before: BEFORE_JVM, why: LAUNCH_WHY };
}

export const ALLOWLIST = [
  // Source/getter 描述符带预线程PID，fork客户端先拒；表地址/职责句柄在模块初始化后不重写。
  { file: 'entry/src/main/cpp/input/source/source_control.cpp', function: 'amclSourceControlPublishV1',
    call: 'setenv', name: 'AMCL_SOURCE_CONTROL_ENV', phase: 'pre-thread',
    why: 'env_publication先于JVM/game线程发布一次，Source解析核PID/同image executable/唯一Core，输入入口不会新增环境名' },
  { file: 'entry/src/main/cpp/input/source/source_control.cpp', function: 'amclSourceControlPublishV1',
    call: '_putenv_s', name: 'AMCL_SOURCE_CONTROL_ENV', phase: 'pre-thread',
    why: '仅Windows真实owner宿主使用同一预线程Source描述符，不是consumer/pump环境写者' },
  // 已冻结look owner的同一早发布闭包；真实新源在最终纳入版本控制后也必须被扫描。
  { file: 'entry/src/main/cpp/input/delivery/look_execution.cpp', function: 'amclLookExecutionPublishV1',
    call: 'setenv', name: 'AMCL_LOOK_EXECUTION_ENV', phase: 'pre-thread',
    why: 'env_publication在Source之前预线程发布look，独立表和PID不会在输入时重写' },
  { file: 'entry/src/main/cpp/input/delivery/look_execution.cpp', function: 'amclLookExecutionPublishV1',
    call: '_putenv_s', name: 'AMCL_LOOK_EXECUTION_ENV', phase: 'pre-thread',
    why: '仅Windows真实host owner的同一look早期描述符发布' },
  // 新私有control port只发布同owner getter地址，实际早期调用在env_publication顺序钉核实。
  { file: 'entry/src/main/cpp/input/delivery/control_delivery.cpp', function: 'amclControlDeliveryPublishV1',
    call: 'setenv', name: 'AMCL_CONTROL_ENV', phase: 'pre-thread',
    why: 'PublishEarlyProcessEnvironment的module Init闭环早于JVM/game线程，一次guard之后无环境重写；函数表及唯一Core owner在读取端再次严格核验' },
  { file: 'entry/src/main/cpp/input/delivery/control_delivery.cpp', function: 'amclControlDeliveryPublishV1',
    call: '_putenv_s', name: 'AMCL_CONTROL_ENV', phase: 'pre-thread',
    why: '仅Windows真实host owner的同一早期描述符发布，不是consumer/pump写者' },
  // L2键盘能力表由同一control发布成功分支预线程公布，active资格仍由真实Keyboard创建授予。
  { file: 'entry/src/main/cpp/input/delivery/control_delivery.cpp', function: 'amclInputL2KeyboardPublishV1',
    call: 'setenv', name: 'AMCL_L2_KEYBOARD_ENV', phase: 'pre-thread',
    why: '只从control的成功一次发布分支调用，公布原PID/同owner能力表；不在输入或Keyboard生命周期重写环境' },
  { file: 'entry/src/main/cpp/input/delivery/control_delivery.cpp', function: 'amclInputL2KeyboardPublishV1',
    call: '_putenv_s', name: 'AMCL_L2_KEYBOARD_ENV', phase: 'pre-thread',
    why: 'Windows宿主使用同一L2能力表早发布合同，不授游戏线程写入资格' },
  // ---- slot-registry：env_slot.h 自身 ----
  { file: SLOT_HEADER, function: 'amcl::envslot::SystemPut', call: 'putenv', name: 'entry', phase: 'slot-registry',
    why: 'Registry::Register puts a process-lifetime static "NAME=VALUE" buffer before the seal; Store only rewrites bytes in place' },
  { file: SLOT_HEADER, function: 'amcl::envslot::SystemPut', call: '_putenv', name: 'entry', phase: 'slot-registry',
    why: 'Windows CRT copies putenv strings, so the host-test backend re-puts the whole entry; never compiled for OHOS' },

  // ---- NAPI 模块初始化（UI 线程，早于任何 AMCL 游戏/JVM 线程） ----
  { file: 'entry/src/main/cpp/napi/napi_entry.cpp', function: 'Init', call: 'setenv', name: '"AMCL_SMPL_HOOKS"',
    phase: 'pre-thread', before: 'amcl::napi::registerTestsNapi(env, exports)',
    why: 'sampler-only build: module Init publishes JVM hook addresses before registerTestsNapi/RegisterXComponent and long before any JVM' },
  { file: 'entry/src/main/cpp/platform/mg_config.cpp', function: 'prepareMobileGluesRuntime', call: 'setenv', name: '"MG_DIR_PATH"',
    phase: 'pre-thread', why: 'called only from module Init (napi_entry.cpp) before any AMCL thread; value is process constant' },
  { file: 'entry/src/main/cpp/platform/mg_config.cpp', function: 'prepareMobileGluesRuntime', call: 'setenv', name: '"MG_ANGLE_DIR"',
    phase: 'pre-thread', why: 'called only from module Init (napi_entry.cpp) before any AMCL thread; value is process constant' },
  { file: 'entry/src/main/cpp/napi/napi_input.cpp', function: 'PublishGrabChangeTrampolineOnce', call: 'setenv', name: '"AMCL_GRAB_CB"',
    phase: 'pre-thread', why: 'std::call_once from registerInputNapi (module Init); onGrabChange only swaps the tsfn under g_grabMutex' },
  { file: 'entry/src/main/cpp/platform/touch_input.cpp', function: 'publishReverseTrampolinesOnce', call: 'setenv', name: '"AMCL_TOUCH_GRAB_CB"',
    phase: 'pre-thread', why: 'std::call_once; first call is registerInputNapi (module Init), resolveBridge re-entry is a no-op' },
  { file: 'entry/src/main/cpp/platform/touch_input.cpp', function: 'publishReverseTrampolinesOnce', call: 'setenv', name: '"AMCL_TOUCH_CANCEL_CB"',
    phase: 'pre-thread', why: 'std::call_once; first call is registerInputNapi (module Init), resolveBridge re-entry is a no-op' },
  { file: 'entry/src/main/cpp/platform/touch_input.cpp', function: 'publishReverseTrampolinesOnce', call: 'setenv', name: '"AMCL_LOOK_DELTA_V2_CB"',
    phase: 'pre-thread', why: 'same module-init call_once as old callback; preserves sample ns across namespace' },
  { file: 'entry/src/main/cpp/platform/touch_input.cpp', function: 'publishReverseTrampolinesOnce', call: 'setenv', name: '"AMCL_LOOK_DELTA_CB"',
    phase: 'pre-thread', why: 'std::call_once; first call is registerInputNapi (module Init), resolveBridge re-entry is a no-op' },
  { file: 'entry/src/main/cpp/glfw/input_bridge_ohos.c', function: 'publishBridgeInstanceDescriptor', call: 'setenv', name: 'AMCL_LEGACY_BRIDGE_INSTANCE_ENV',
    phase: 'pre-thread', why: 'owner-image once guard (g_bridgeOwner); first publication is PublishEarlyProcessEnvironment at module Init' },
  { file: 'entry/src/main/cpp/glfw/input_bridge_ohos.c', function: 'inputBridge_publishAddress', call: 'setenv', name: '"OHOS_INPUT_BRIDGE"',
    phase: 'pre-thread', why: 'g_bridgeAddressPublished once guard; module Init publishes first, surface commits and glfwInit then return early' },
  { file: 'entry/src/main/cpp/glfw/input_bridge_ohos.c', function: 'inputBridge_publishAddress', call: 'setenv', name: '"AMCL_INPUT_ORDER_BRIDGE"',
    phase: 'pre-thread', why: 'same once guard and early module-init call; publish ordered tail before SDL bridge' },
  { file: 'entry/src/main/cpp/glfw/input_bridge_ohos.c', function: 'inputBridge_publishAddress', call: 'setenv', name: '"AMCL_SDL_TOUCH_BRIDGE"',
    phase: 'pre-thread', before: 'setenv("AMCL_SDL_INPUT_BRIDGE", sdlbuf, 1)',
    why: '私有目标/呈现函数表只含同一进程owner的固定函数地址；PublishEarlyProcessEnvironment在module Init首先调用，g_bridgeAddressPublished阻止后续surface/glfwInit重写。完整touch尾表须先于既有SDL描述符发布，JVM/游戏线程仅解析既定入口' },
  { file: 'entry/src/main/cpp/glfw/input_bridge_ohos.c', function: 'inputBridge_publishAddress', call: 'setenv', name: '"AMCL_SDL_INPUT_BRIDGE"',
    phase: 'pre-thread', why: 'g_bridgeAddressPublished once guard; module Init publishes first, surface commits and glfwInit then return early' },
  { file: 'entry/src/main/cpp/glfw/input_bridge_ohos.c', function: 'amclHostSetEnv', call: '_putenv_s', name: 'name',
    phase: 'pre-thread', why: 'Windows host shim behind "#define setenv"; reached only through the same once-guarded process descriptor publications above' },
  { file: 'entry/src/main/cpp/input/adapters/backend_input_bridge.cpp', function: 'PublishEnvironment', call: 'setenv', name: 'name',
    wrapper: 'PublishEnvironment', phase: 'pre-thread', why: 'forwarding wrapper; its only callers are the once-guarded publication below' },
  { file: 'entry/src/main/cpp/input/adapters/backend_input_bridge.cpp', function: 'PublishEnvironment', call: '_putenv_s', name: 'name',
    phase: 'pre-thread', why: 'Windows host-test branch of the same wrapper' },
  { file: 'entry/src/main/cpp/input/adapters/backend_input_bridge.cpp', function: 'amclBackendInputPublishAddress', call: 'PublishEnvironment',
    name: '"AMCL_BACKEND_TEXT_BRIDGE"', phase: 'pre-thread', why: 'g_backendDescriptorsPublished once guard; module Init publishes first' },
  { file: 'entry/src/main/cpp/input/adapters/backend_input_bridge.cpp', function: 'amclBackendInputPublishAddress', call: 'PublishEnvironment',
    name: '"AMCL_BACKEND_INPUT_BRIDGE"', phase: 'pre-thread', why: 'g_backendDescriptorsPublished once guard; module Init publishes first' },
  { file: 'entry/src/main/cpp/platform/window_host.cpp', function: 'publishEnv', call: 'setenv', name: 'name', wrapper: 'publishEnv',
    phase: 'pre-thread', why: 'forwarding wrapper; its only callers are publishOwner below' },
  { file: 'entry/src/main/cpp/platform/window_host.cpp', function: 'publishEnv', call: '_putenv_s', name: 'name',
    phase: 'pre-thread', why: 'Windows host-test branch of the same wrapper' },
  { file: 'entry/src/main/cpp/platform/window_host.cpp', function: 'publishOwner', call: 'publishEnv', name: 'AMCL_NATIVE_WINDOW_LEASE_BROKER_ENV',
    phase: 'pre-thread', why: 'ownerPublished once guard under ownerPublicationMutex; amclWindowHostPublishOwner at module Init writes it first' },
  { file: 'entry/src/main/cpp/platform/window_host.cpp', function: 'publishOwner', call: 'publishEnv', name: 'kOwnerEnv',
    phase: 'pre-thread', why: 'ownerPublished once guard under ownerPublicationMutex; amclWindowHostPublishOwner at module Init writes it first' },
  { file: 'entry/src/main/cpp/utils/amcl_log.cpp', function: 'publishExternalSinkDescriptorOnce', call: 'setenv', name: '"AMCL_LOG_SINK_V1"',
    phase: 'pre-thread', why: 'once per PID from amclLogInit (NAPI, UI thread) before the writer thread is created; fork children republish single-threaded' },
  { file: 'entry/src/main/cpp/utils/amcl_log.cpp', function: 'publishExternalSinkDescriptorOnce', call: '_putenv_s', name: '"AMCL_LOG_SINK_V1"',
    phase: 'pre-thread', why: 'Windows host-test branch of the same once-per-PID publication' },

  // ---- 启动事务（mcLaunchWithProfileV2 同步执行，建 JVM 之前） ----
  { file: MC, function: 'initMarkerPath', call: 'setenv', name: '"AMCL_FILES_DIR"', phase: 'pre-thread',
    why: 'called only from launchWithProfileImpl before phase_initJvmWithClasspath (UI thread, no JVM yet)' },
  launch('"AMCL_NATIVE_GL_ACTIVE"'),
  launch('"SDL_VULKAN_LIBRARY"'),
  launch({ call: 'unsetenv', name: '"SDL_VULKAN_LIBRARY"' }, 2),
  launch('"AMCL_MG_FRAME_PACING_FPS"'),
  launch('"MOBILEGL_BACKEND_TYPE"'),
  launch('"AMCL_MG_EXPOSE_INDIRECT_DRAW"'),
  launch('"AMCL_MG_EXPOSE_BASE_INSTANCE"'),
  launch('"AMCL_JDK_IF_INET6_SHIM"'),
  launch('"AMCL_RENDER_SCALE"', 2),
  launch('"SDL_OPENHARMONY_AUXILIARY_WINDOW_MODE"'),
  launch('"SDL_OPENGL_LIBRARY"'),
  launch('"SDL_EGL_LIBRARY"'),
  launch({ call: 'unsetenv', name: '"SDL_OPENGL_FORCE_SRGB_FRAMEBUFFER"' }, 2),
  launch('"SDL_OPENGL_FORCE_SRGB_FRAMEBUFFER"'),
  launch({ call: 'unsetenv', name: '"SDL_OPENGL_LIBRARY"' }),
  launch({ call: 'unsetenv', name: '"SDL_EGL_LIBRARY"' }),
  launch('"AMCL_GAME_DIR"'),
  launch('"LIBGL_GLES"'),
  launch('"LIBGL_NOBANNER"'),
  launch('"AMCL_GRAPHICS_OBSERVATION"'),
  launch('"AMCL_GRAPHICS_OBSERVATION_COST"'),
  // 两项诊断只在同一启动事务内、JVM/游戏线程创建前冻结；仍逐名登记并核对
  // BEFORE_JVM 顺序，不放宽运行期环境写入或用通配条目吸收其他新增开关。
  launch('"AMCL_MC_LOG_MIRROR"'),
  launch('"AMCL_AUDIO_DIAGNOSTICS"'),
  { file: 'entry/src/main/cpp/platform/graphics_plan.cpp', function: 'amcl::graphics::writeEnvironment', call: 'setenv', name: 'name',
    wrapper: 'writeEnvironment', phase: 'pre-thread',
    why: 'forwarding wrapper; callers are plan activation/grant/fork reset, all inside launchWithProfileImpl before the JVM' },
  { file: 'entry/src/main/cpp/platform/graphics_plan.cpp', function: 'amcl::graphics::writeEnvironment', call: '_putenv_s', name: 'name',
    phase: 'pre-thread', why: 'Windows host-test branch of the same wrapper' },
  { file: 'entry/src/main/cpp/platform/graphics_plan.cpp', function: 'amcl::graphics::resetAfterFork', call: 'writeEnvironment', name: '*', count: 6,
    phase: 'pre-thread', why: 'first statement of ActivateGraphicsPlan/GrantNativeVulkan (launch transaction, pre-JVM); only writes when the PID changed' },
  { file: 'entry/src/main/cpp/platform/graphics_plan.cpp', function: 'amcl::graphics::publishPlan', call: 'writeEnvironment', name: '*', count: 14,
    phase: 'pre-thread', why: 'called only by ActivateGraphicsPlan inside launchWithProfileImpl before the JVM' },
  { file: 'entry/src/main/cpp/platform/graphics_plan.cpp', function: 'amcl::graphics::GrantNativeVulkan', call: 'writeEnvironment',
    name: '"AMCL_GRAPHICS_ALLOW_NATIVE_VULKAN"', count: 2, phase: 'pre-thread',
    why: 'Vulkan admission inside launchWithProfileImpl before the JVM' },
  { file: 'entry/src/main/cpp/platform/graphics_observation.cpp', function: 'amclGraphicsPublishObserverV1', call: 'setenv', name: 'ownerKey.c_str()',
    phase: 'pre-thread', why: 'first call is mc_launcher before the JVM; later calls return at descriptor() without writing' },
  { file: 'entry/src/main/cpp/platform/graphics_observation.cpp', function: 'amclGraphicsPublishObserverV1', call: 'setenv', name: 'AMCL_GRAPHICS_OBSERVER_ENV',
    phase: 'pre-thread', why: 'first call is mc_launcher before the JVM; later calls return at descriptor() without writing' },
  { file: 'entry/src/main/cpp/platform/graphics_runtime_binding.cpp', function: 'amcl::graphics::service', call: 'setenv', name: 'serviceEnv',
    phase: 'pre-thread', why: 'overwrite=0 first publication during the launch binding (pre-JVM); cachedService short-circuits later calls' },
  { file: 'entry/src/main/cpp/platform/graphics_runtime_binding.cpp', function: 'amcl::graphics::service', call: '_putenv_s', name: 'serviceEnv',
    phase: 'pre-thread', why: 'Windows host-test branch of the same first publication' },
  { file: 'entry/src/main/cpp/platform/graphics_runtime_binding.cpp', function: 'amcl::graphics::FreezeGraphicsRuntime', call: 'setenv',
    name: 'AMCL_GRAPHICS_RUNTIME_ENV', phase: 'pre-thread',
    why: 'first freeze is mc_launcher (amclGraphicsBindRuntimeV1, pre-JVM); game-thread re-freezes find the identical descriptor and return' },
  { file: 'entry/src/main/cpp/platform/graphics_runtime_binding.cpp', function: 'amcl::graphics::FreezeGraphicsRuntime', call: '_putenv_s',
    name: 'AMCL_GRAPHICS_RUNTIME_ENV', phase: 'pre-thread', why: 'Windows host-test branch of the same publication' },
  { file: 'entry/src/main/cpp/platform/vulkan_wsi.cpp', function: 'publishEnv', call: 'setenv', name: 'name', wrapper: 'publishEnv',
    phase: 'pre-thread', why: 'forwarding wrapper; its only caller is amclVulkanSetAdmission below' },
  { file: 'entry/src/main/cpp/platform/vulkan_wsi.cpp', function: 'publishEnv', call: '_putenv_s', name: 'name',
    phase: 'pre-thread', why: 'Windows host-test branch of the same wrapper' },
  { file: 'entry/src/main/cpp/platform/vulkan_wsi.cpp', function: 'amclVulkanSetAdmission', call: 'publishEnv', name: '"AMCL_VULKAN_WSI_OWNER"',
    phase: 'pre-thread', why: 'only mc_launcher calls admission (pre-JVM); ownerPublishedPid writes once per PID' },
  { file: 'entry/src/main/cpp/platform/mobilegl_capability_driver.cpp', function: 'amcl::graphics::PublishMobileGlDirectVulkanBeforeLoad', call: 'setenv',
    name: '"MOBILEGL_BACKEND_TYPE"', phase: 'pre-thread',
    why: 'shared production cold publisher, called by pre-JVM admission or claimed disposable TestHooks before provider freeze; identical value is read-only, sealed/loaded provider and write failure reject' },
  { file: JVM, function: 'jvmInit', call: 'setenv', name: '"JAVA_HOME"', phase: 'pre-thread', before: BEFORE_CREATE_VM, why: JVMINIT_WHY },
  { file: JVM, function: 'jvmInit', call: 'setenv', name: '"SUN_BOOT_LIBRARY_PATH"', phase: 'pre-thread', before: BEFORE_CREATE_VM, why: JVMINIT_WHY },
  { file: JVM, function: 'jvmInit', call: 'setenv', name: '"LC_ALL"', phase: 'pre-thread', before: BEFORE_CREATE_VM, why: JVMINIT_WHY },
  { file: JVM, function: 'jvmInit', call: 'setenv', name: '"LANG"', phase: 'pre-thread', before: BEFORE_CREATE_VM, why: JVMINIT_WHY },
  ...['"FONTCONFIG_PATH"', '"FONTCONFIG_FILE"', '"LC_ALL"', '"LANG"', '"AMCL_GAME_DIR"', '"LD_LIBRARY_PATH"'].map((name) => (
    { file: FORK, function: 'childMain', call: 'setenv', name, phase: 'pre-thread', why: FORK_WHY })),

  // ---- DevTools 探针（MC_OHOS_BUILD_TESTS） ----
  { file: 'entry/src/main/cpp/tests/mg_test.cpp', function: 'runMobileGluesTest', call: 'setenv', name: '"MG_DIR_PATH"',
    phase: 'pre-thread', why: 'inside the forked single-threaded probe child (child == 0) before it initializes MobileGlues' },
  // 专用语义探针只接受应用重启后的冷状态，先阻断后续JVM/游戏，再在冻结provider前固定配置目录。
  { file: 'entry/src/main/cpp/tests/graphics_scene_probe_common.h', function: 'amcl::test_graphics_scene::Run', call: 'setenv', name: '"MG_DIR_PATH"',
    phase: 'pre-thread', why: 'shared TestHooks rejects sealed/runtime/initialized state and atomically claims disposable cold app before configuration and provider freeze; subsequent JVM/game launch requires restart' },
  { file: 'entry/src/main/cpp/tests/graphics_depth_range_test.cpp', function: 'runMgDepthRangeTest', call: 'setenv', name: '"MG_DIR_PATH"',
    phase: 'pre-thread', before: 'Probe(report)', why: 'dedicated cold-start default test process before any JVM/game claim; rejects sealed registry, existing runtime and non-COLD MG, then blocks JVM/game until application restart' },
  ...['"SDL_OPENGL_LIBRARY"', '"SDL_EGL_LIBRARY"', '"SDL_NO_SIGNAL_HANDLERS"', '"SDL_VIDEO_DRIVER"'].map((name) => (
    { file: 'entry/src/main/cpp/tests/sdl3_c2_test.cpp', function: 'runSdl3C2Test', call: 'setenv', name, phase: 'pre-thread', why: DEVTOOLS_WHY })),
  { file: 'entry/src/main/cpp/tests/sdl3_window_test.cpp', function: 'ScopedEnvRestore::~ScopedEnvRestore', call: 'setenv', name: 'entry.name',
    phase: 'pre-thread', why: `${DEVTOOLS_WHY}; restores the probe's own SDL variables (the restart slot is deliberately not in the table)` },
  { file: 'entry/src/main/cpp/tests/sdl3_window_test.cpp', function: 'ScopedEnvRestore::~ScopedEnvRestore', call: 'unsetenv', name: 'entry.name',
    phase: 'pre-thread', why: `${DEVTOOLS_WHY}; restores the probe's own SDL variables (the restart slot is deliberately not in the table)` },
  ...['"SDL_OPENHARMONY_AUXILIARY_WINDOW_MODE"', '"SDL_VIDEODRIVER"', '"SDL_VIDEO_DRIVER"', '"SDL_NO_SIGNAL_HANDLERS"',
    '"SDL_OPENGL_LIBRARY"', '"SDL_EGL_LIBRARY"'].map((name) => (
    { file: 'entry/src/main/cpp/tests/sdl3_window_test.cpp', function: 'runSdl3HybridWindowProbe', call: 'setenv', name, phase: 'pre-thread', why: DEVTOOLS_WHY })),
  ...['"SDL_OPENGL_LIBRARY"', '"SDL_EGL_LIBRARY"', '"SDL_VIDEO_DRIVER"', '"SDL_NO_SIGNAL_HANDLERS"'].map((name) => (
    { file: 'entry/src/main/cpp/tests/sdl3_window_test.cpp', function: 'runSdl3WindowTest', call: 'setenv', name, phase: 'pre-thread', why: DEVTOOLS_WHY })),

  // ---- 历史SDL补丁中的声明；现役完整series由后续补丁收口 ----
  ...[['0003-openharmony-hybrid-multi-window.patch', 'src/video/openharmony/SDL_openharmonyopengl.c', 'OPENHARMONY_GLES_MarkRendererRestartRequired', 1],
    ['0003-openharmony-hybrid-multi-window.patch', 'src/video/openharmony/SDL_openharmonyopengl.c', 'OPENHARMONY_GLES_UnloadLibrary', 1],
    ['0003-openharmony-hybrid-multi-window.patch', 'src/video/openharmony/SDL_openharmonywindow.c', 'OPENHARMONY_DestroyWindow', 2],
    ['0012-openharmony-presentation-session.patch', 'src/video/openharmony/SDL_openharmonyamcl.c', 'OPENHARMONY_AMCL_PresentationFailure', 1],
  ].map(([patch, target, fn, count]) => ({
    file: `${SDL3_PATCHES}/${patch}`, target, function: fn, call: 'SDL_setenv_unsafe', name: '"AMCL_RENDERER_REQUIRES_PROCESS_RESTART"', count,
    phase: 'pending-prebuilt-rebuild',
    why: 'SDL failure paths (game thread) setenv the restart marker, detaching the host slot; the rebuilt SDL must flip it via the host registry/ABI',
  })),
];

// ============================ 顺序钉 ============================
// 把 pre-thread 登记依赖的时序骨架钉成可机械核对的锚点序列（在去注释文本里按序查找）。
export const ORDER_PINS = [
  { id: 'l2-keyboard-follows-control-once-publication', file: 'entry/src/main/cpp/input/delivery/control_delivery.cpp',
    anchors: ['void amclControlDeliveryPublishV1()', 'if(published.load(std::memory_order_acquire))return;',
      'if(status==0){published.store(true,std::memory_order_release);amclInputL2KeyboardPublishV1();}'],
    why: 'L2能力描述符只随control预线程一次发布成功分支建立，不移到pump或当前Keyboard创建路径' },
  { id: 'module-init-publishes-first', file: 'entry/src/main/cpp/napi/napi_entry.cpp',
    anchors: ['amcl::ohos::PublishEarlyProcessEnvironment("module-init")', 'amcl::napi::registerInputNapi(env, exports)',
      'amcl::napi::registerTestsNapi(env, exports)', 'RegisterXComponent(env, exports)'],
    why: 'early publication must precede every registration that can start a thread or surface callback' },
  { id: 'early-publication-covers-slots-and-descriptors', file: 'entry/src/main/cpp/platform/env_publication.cpp',
    anchors: ['EnsureRendererRestartSlot()',
      'amclBackendInputPublishAddress()', 'inputBridge_publishAddress()', 'amclControlDeliveryPublishV1()',
      'amclLookExecutionPublishV1()', 'amclSourceControlPublishV1()', 'amclWindowHostPublishOwner()'],
    why: 'module Init registers every dynamic slot and publishes every once-guarded descriptor before any AMCL thread' },
  { id: 'input-descriptor-once-and-complete-tail', file: 'entry/src/main/cpp/glfw/input_bridge_ohos.c',
    anchors: ['void inputBridge_publishAddress(void) {',
      'if (atomic_load_explicit(&g_bridgeAddressPublished, memory_order_acquire)) return;',
      'if (!publishBridgeInstanceDescriptor())',
      'setenv("AMCL_SDL_TOUCH_BRIDGE", touchbuf, 1)',
      'setenv("AMCL_SDL_INPUT_BRIDGE", sdlbuf, 1)',
      'atomic_store_explicit(&g_bridgeAddressPublished, true, memory_order_release)'],
    why: '首次模块初始化在游戏/JVM线程之前完成完整SDL目标尾表；后来调用必须在任何environ写入前返回，完成标志只能在尾表和原SDL表都已发布后设置' },
  { id: 'grab-callback-published-at-registration', file: 'entry/src/main/cpp/napi/napi_input.cpp',
    anchors: ['void registerInputNapi(', 'ohos_input_publish_trampolines();',
      'std::call_once(g_grabTrampolinePublished, PublishGrabChangeTrampolineOnce)', 'napi_define_properties('],
    why: 'AMCL_GRAB_CB is published once during module Init, never from onGrabChange (after mcStarted)' },
  { id: 'launch-slots-before-jvm', file: MC,
    anchors: ['amcl::ohos::EnsureRendererRestartSlot()', 'amcl::ohos::PrepareRuntimeEnvironmentSlots(', BEFORE_JVM,
      'std::thread(mcLaunchThreadWithProfile'],
    why: 'runtime text slots are registered before the JVM claim and the game thread' },
  { id: 'seal-at-jvm-claim', file: JVM,
    anchors: ['g_runtimeOnce.beginResult()', 'amcl::ohos::SealProcessEnvironment(', BEFORE_CREATE_VM],
    why: 'the registry is sealed after the JVM creation claim and before JNI_CreateJavaVM creates JVM threads' },
  { id: 'surface-size-slots-only-on-change', file: 'entry/src/main/cpp/platform/xcomponent.cpp',
    anchors: ['static void RefreshPublishedSurfaceGeometry(', 'amcl::ohos::SurfacePublicationUnchanged(current, next)',
      'amcl::ohos::ApplyExpectedFrameRateHint(component, reason);',
      'ohos_surface_input_gate_update_transaction('],
    why: 'I27-04: an unchanged real OnSurfaceChanged returns before the size slots and the publication; only real changes advance the broker surface publication' },
];

// ============================ 源码遮罩 ============================

function blank(chars, from, to) {
  for (let k = from; k < to && k < chars.length; k++) if (chars[k] !== '\n' && chars[k] !== '\r') chars[k] = ' ';
}

/**
 * 返回两份与原文等长的遮罩：comments 只抹掉注释（保留字符串，用于取实参）；code 再抹掉
 * 字面量内容与预处理行（用于花括号作用域与“是否调用”的前一记号判断）。
 * startsInComment 用于从块注释中间开始的补丁 hunk。
 */
export function maskSource(text, { startsInComment = false } = {}) {
  const comments = text.split('');
  const code = text.split('');
  const n = text.length;
  let i = 0;
  if (startsInComment) {
    const close = text.indexOf('*/');
    const end = close < 0 ? n : close + 2;
    blank(comments, 0, end);
    blank(code, 0, end);
    i = end;
  }
  while (i < n) {
    const c = text[i];
    const d = text[i + 1];
    const prev = i > 0 ? text[i - 1] : '';
    if (c === '/' && d === '/') {
      let j = i;
      while (j < n && text[j] !== '\n') j++;
      blank(comments, i, j);
      blank(code, i, j);
      i = j;
      continue;
    }
    if (c === '/' && d === '*') {
      const close = text.indexOf('*/', i + 2);
      const end = close < 0 ? n : close + 2;
      blank(comments, i, end);
      blank(code, i, end);
      i = end;
      continue;
    }
    if (c === 'R' && d === '"' && !/[A-Za-z0-9_]/.test(prev)) {
      const open = text.indexOf('(', i + 2);
      if (open > 0 && open - (i + 2) <= 16 && !text.slice(i + 2, open).includes('\n')) {
        const delimiter = text.slice(i + 2, open);
        const close = text.indexOf(`)${delimiter}"`, open + 1);
        const end = close < 0 ? n : close + delimiter.length + 2;
        blank(code, i + 2, end - 1);
        i = end;
        continue;
      }
    }
    if (c === '\'' && /[0-9A-Za-z_]/.test(prev) && /[0-9A-Fa-f]/.test(d ?? '')) {
      // C++14 数字分隔符（1'000、0xFF'FF）：前一个记号以数字开头才算，`case'a'` 仍是字符字面量。
      let start = i - 1;
      while (start > 0 && /[0-9A-Za-z_]/.test(text[start - 1])) start--;
      if (/[0-9]/.test(text[start])) {
        i++;
        continue;
      }
    }
    if (c === '"' || c === '\'') {
      let j = i + 1;
      while (j < n && text[j] !== c && text[j] !== '\n') j += text[j] === '\\' ? 2 : 1;
      blank(code, i + 1, j);
      i = j + 1;
      continue;
    }
    i++;
  }
  // 预处理行（含反斜杠续行）整行从 code 里抹掉：宏体里的花括号不参与作用域。
  const preprocessorLines = new Set();
  const lines = comments.join('').split('\n');
  let offset = 0;
  let continuing = false;
  lines.forEach((line, index) => {
    const directive = continuing || /^\s*#/.test(line);
    if (directive) {
      preprocessorLines.add(index + 1);
      blank(code, offset, offset + line.length);
    }
    continuing = directive && /\\\s*$/.test(line);
    offset += line.length + 1;
  });
  return { comments: comments.join(''), code: code.join(''), preprocessorLines };
}

// ============================ 函数归属 ============================

const NOT_FUNCTION_NAMES = new Set(['if', 'for', 'while', 'switch', 'return', 'sizeof', 'alignof',
  'decltype', 'static_assert', '_Static_assert', 'alignas', '_Alignas', 'noexcept', 'throw', 'catch',
  'defined', 'operator', 'typeof', '__typeof__', 'do', 'else', 'case', 'new', 'delete',
  'void', 'int', 'char', 'bool', 'float', 'double', 'long', 'short', 'unsigned', 'signed', 'auto',
  'const', 'volatile', 'static', 'inline', 'extern']);

function stripDecorations(header) {
  let out = header.replace(/^\s*template\s*<[^{};]*?>\s*/, ' ');
  for (const keyword of ['__attribute__', '__declspec', 'alignas', '_Alignas']) {
    let index;
    while ((index = out.indexOf(keyword)) >= 0) {
      let j = index + keyword.length;
      while (j < out.length && /\s/.test(out[j])) j++;
      if (out[j] !== '(') { out = out.slice(0, index) + ' ' + out.slice(index + keyword.length); continue; }
      let depth = 0;
      let k = j;
      for (; k < out.length; k++) {
        if (out[k] === '(') depth++;
        else if (out[k] === ')' && --depth === 0) { k++; break; }
      }
      out = out.slice(0, index) + ' ' + out.slice(k);
    }
  }
  return out;
}

/** 头部里第一个“不在括号内、不是关键字/类型字、不是全大写宏”的 标识符( 。 */
export function extractFunctionName(header) {
  const text = stripDecorations(header);
  const re = /(~?[A-Za-z_][A-Za-z0-9_]*(?:\s*::\s*~?[A-Za-z_][A-Za-z0-9_]*)*)\s*\(/g;
  let match;
  while ((match = re.exec(text))) {
    let depth = 0;
    for (let k = 0; k < match.index; k++) {
      if (text[k] === '(') depth++;
      else if (text[k] === ')') depth--;
    }
    const name = match[1].replace(/\s+/g, '');
    const last = name.split('::').pop();
    if (depth !== 0 || NOT_FUNCTION_NAMES.has(last) || /^[A-Z0-9_]+$/.test(last)) continue;
    return name;
  }
  return null;
}

function hasTopLevelAssignment(header) {
  let depth = 0;
  for (let k = 0; k < header.length; k++) {
    const c = header[k];
    if (c === '(' || c === '[') depth++;
    else if (c === ')' || c === ']') depth--;
    else if (c === '=' && depth === 0 && !/[=!<>+\-*/%&|^]/.test(header[k - 1] ?? '') && header[k + 1] !== '=') return true;
  }
  return false;
}

// 对 file-scope / 命名空间 / 类体里的一个 '{' 分类：transparent（匿名 namespace、extern "C"）、
// namespace（具名，计入限定名）、container（class/struct/union/enum）、function 或 block。
function classifyBrace(rawHeader) {
  const header = stripDecorations(rawHeader).replace(/\s+/g, ' ').trim();
  const namespaced = /(?:^|[\s;])namespace\s+([A-Za-z_][A-Za-z0-9_]*(?:\s*::\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*$/.exec(header);
  if (namespaced) return { kind: 'namespace', name: namespaced[1].replace(/\s+/g, '') };
  if (/(?:^|[\s;])namespace\b[^(]*$/.test(header) || /\bextern\s*"[^"]*"\s*$/.test(header)) {
    return { kind: 'transparent' };
  }
  if (hasTopLevelAssignment(header)) return { kind: 'block', name: '<initializer>' };
  const container = /(?:^|\s)(?:typedef\s+)?(class|struct|union|enum(?:\s+class|\s+struct)?)\b\s*([A-Za-z_][A-Za-z0-9_]*)?[^()]*$/.exec(header);
  if (container) return { kind: 'container', name: container[2] ?? '<anonymous>' };
  if (header.includes('(')) return { kind: 'function', name: extractFunctionName(header) ?? '<anonymous>' };
  return { kind: 'block', name: '<unknown>' };
}

/**
 * 单遍花括号扫描：对每个 offset 给出最外层函数（带具名 namespace 与类名限定）；
 * balanced=false 表示建模失衡。
 */
export function functionContexts(code, offsets) {
  const wanted = [...new Set(offsets)].sort((a, b) => a - b);
  const result = new Map();
  const stack = [];
  let boundary = 0;
  let cursor = 0;
  let balanced = true;
  const current = () => {
    const scopes = [];
    for (const scope of stack) {
      if (scope.kind === 'namespace' || scope.kind === 'container') scopes.push(scope.name);
      if (scope.kind === 'function') {
        // 类外定义（Foo::bar）已自带限定；只有尚未限定的名字才拼上外层作用域。
        return scope.name.includes('::') && scopes.length === 0 ? scope.name : [...scopes, scope.name].join('::');
      }
      if (scope.kind === 'block' && scope.top) return scope.name;
    }
    return '<file-scope>';
  };
  for (let i = 0; i <= code.length; i++) {
    while (cursor < wanted.length && wanted[cursor] === i) result.set(wanted[cursor++], current());
    if (i === code.length) break;
    const c = code[i];
    if (c === '{') {
      const inner = stack[stack.length - 1];
      const nested = inner && (inner.kind === 'function' || inner.kind === 'block');
      const scope = nested ? { kind: 'block', name: '<block>' } : { ...classifyBrace(code.slice(boundary, i)), top: true };
      stack.push(scope);
      boundary = i + 1;
    } else if (c === '}') {
      if (!stack.length) balanced = false;
      else stack.pop();
      boundary = i + 1;
    } else if (c === ';') {
      boundary = i + 1;
    }
  }
  if (stack.length) balanced = false;
  return { contexts: result, balanced };
}

// ============================ 调用点提取 ============================

function lineOf(text, offset) {
  let line = 1;
  for (let k = 0; k < offset; k++) if (text[k] === '\n') line++;
  return line;
}

// 从 '(' 之后取第一个顶层实参（跨行、跳过字符串与嵌套括号），空白规范化为单个空格。
function firstArgument(text, open) {
  let depth = 0;
  let k = open + 1;
  for (; k < text.length; k++) {
    const c = text[k];
    if (c === '"' || c === '\'') {
      k++;
      while (k < text.length && text[k] !== c) k += text[k] === '\\' ? 2 : 1;
      continue;
    }
    if (c === '(' || c === '[' || c === '{') depth++;
    else if (c === ')' || c === ']' || c === '}') {
      if (depth === 0) break;
      depth--;
    } else if (c === ',' && depth === 0) break;
  }
  return text.slice(open + 1, k).replace(/\s+/g, ' ').trim();
}

function previousToken(text, index) {
  let k = index - 1;
  while (k >= 0 && /\s/.test(text[k])) k--;
  if (k < 0) return '';
  if (!/[A-Za-z0-9_]/.test(text[k])) return text[k];
  let start = k;
  while (start > 0 && /[A-Za-z0-9_]/.test(text[start - 1])) start--;
  return text.slice(start, k + 1);
}

// 一次调用（不是声明/定义）：前一个记号是标识符或 '*' 时视为 `int setenv(` 这类声明。
// 前一记号取自 code 遮罩：紧跟在 #ifdef/#else 之后的调用不会被预处理行里的标识符误判成声明。
function isCall(code, index) {
  const token = previousToken(code, index);
  if (token === '' || ['return', 'else', 'do'].includes(token)) return true;
  if (/^[A-Za-z0-9_]+$/.test(token) || token === '*') return false;
  return true;
}

function callPattern(names) {
  const escaped = names.map((name) => name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
  return new RegExp(`(?<![A-Za-z0-9_])(${escaped.join('|')})\\s*\\(`, 'g');
}

function findCalls(masked, names = MUTATION_CALLS) {
  const calls = [];
  const re = callPattern(names);
  let match;
  while ((match = re.exec(masked.comments))) {
    // 名字若落在字符串字面量里（例如日志文案 "setenv(MG_DIR_PATH) failed"），code 遮罩里那段是空白。
    if (masked.code.slice(match.index, match.index + match[1].length) !== match[1]) continue;
    if (!isCall(masked.code, match.index)) continue;
    const open = match.index + match[0].length - 1;
    calls.push({ offset: match.index, call: match[1], name: firstArgument(masked.comments, open) });
  }
  return calls;
}

/** 扫一份 C/C++ 源码：返回 { sites, balanced, masked, contexts }。wrappers 为本文件登记的转发函数名。 */
export function scanSource(text, { wrappers = [] } = {}) {
  const masked = maskSource(text);
  const calls = findCalls(masked, [...MUTATION_CALLS, ...wrappers]);
  const { contexts, balanced } = functionContexts(masked.code, calls.map((c) => c.offset));
  const sites = calls.map((c) => {
    const line = lineOf(text, c.offset);
    const fn = masked.preprocessorLines.has(line) ? '<preprocessor>' : contexts.get(c.offset);
    return { line, offset: c.offset, call: c.call, name: c.name, function: fn };
  });
  return { sites, balanced, masked };
}

// 补丁里的顶格定义行（SDL 风格）：行首是标识符、含 名字( 、不以 ; 或 , 结尾。
function definitionName(line) {
  if (!/^[A-Za-z_]/.test(line) || /[;,]\s*$/.test(line)) return null;
  return extractFunctionName(line);
}

/** 扫一份补丁：只看 hunk 的新增行；函数归属取 hunk 内最近的顶格定义行，缺省用 hunk 头上下文。 */
export function scanPatch(text) {
  const lines = text.split(/\r?\n/);
  const sites = [];
  let target = null;
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (line.startsWith('diff --git ')) {
      const m = / b\/(.+)$/.exec(line);
      target = m ? m[1] : null;
      i++;
      continue;
    }
    const hunk = /^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@ ?(.*)$/.exec(line);
    if (!hunk) { i++; continue; }
    // 按 hunk 头声明的行数消费正文，不会把下一个提交的说明文字吞进来。
    let oldRemaining = hunk[1] === undefined ? 1 : Number(hunk[1]);
    let newRemaining = hunk[2] === undefined ? 1 : Number(hunk[2]);
    const body = [];
    i++;
    while (i < lines.length && (oldRemaining > 0 || newRemaining > 0)) {
      const l = lines[i];
      if (l.startsWith('+')) {
        body.push({ text: l.slice(1), added: true, patchLine: i + 1 });
        newRemaining--;
      } else if (l.startsWith('-')) {
        oldRemaining--;
      } else if (l.startsWith(' ') || l === '') {
        body.push({ text: l.slice(1), added: false, patchLine: i + 1 });
        oldRemaining--;
        newRemaining--;
      } else if (!l.startsWith('\\')) {
        break;
      }
      i++;
    }
    const post = body.map((b) => b.text).join('\n');
    const close = post.indexOf('*/');
    const open = post.indexOf('/*');
    const masked = maskSource(post, { startsInComment: close >= 0 && (open < 0 || close < open) });
    const codeLines = masked.code.split('\n');
    for (const call of findCalls(masked)) {
      const index = lineOf(post, call.offset) - 1;
      if (!body[index]?.added) continue;
      let fn = null;
      for (let k = index; k >= 0 && !fn; k--) fn = definitionName(codeLines[k]);
      fn = fn ?? extractFunctionName(hunk[3]) ?? '<unknown>';
      sites.push({ line: body[index].patchLine, target, call: call.call, name: call.name, function: fn });
    }
  }
  return sites;
}

// ============================ 收集与判定 ============================

function isExcluded(rel) {
  if (EXCLUDED_PREFIXES.some((p) => rel.startsWith(p))) return true;
  return rel.split('/').some((segment) => EXCLUDED_SEGMENTS.has(segment));
}

function walk(root, dir, out) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    const rel = path.relative(root, full).replace(/\\/g, '/');
    if (entry.isDirectory()) {
      if (!isExcluded(`${rel}/`)) walk(root, full, out);
    } else if (entry.isFile() && SOURCE_EXT.test(entry.name) && !isExcluded(rel)) {
      out.push(rel);
    }
  }
  return out;
}

/** 默认扫描清单：首方 cpp 树（排除第三方/宿主测试/构建目录）+ LWJGL2 后端源码 + SDL3 补丁。 */
export function defaultFiles(root = ROOT) {
  return [
    ...walk(root, path.join(root, CPP_ROOT), []),
    ...fs.readdirSync(path.join(root, LWJGL2_BACKEND)).filter((f) => f.endsWith('.c')).map((f) => `${LWJGL2_BACKEND}/${f}`),
    ...fs.readdirSync(path.join(root, SDL3_PATCHES)).filter((f) => f.endsWith('.patch')).map((f) => `${SDL3_PATCHES}/${f}`),
  ].sort();
}

// 在同一函数内、site 之后查找锚点（去注释文本）；找到返回 true。
function anchorFollows(masked, site, anchor) {
  let from = site.offset + 1;
  for (;;) {
    const at = masked.comments.indexOf(anchor, from);
    if (at < 0) return false;
    const { contexts } = functionContexts(masked.code, [at]);
    if (contexts.get(at) === site.function) return true;
    from = at + 1;
  }
}

/** 按序在去注释文本里查找锚点；返回第一个缺失/乱序的锚点，全部就位返回 null。 */
export function firstBrokenAnchor(text, anchors) {
  const { comments } = maskSource(text);
  let from = 0;
  for (const anchor of anchors) {
    const at = comments.indexOf(anchor, from);
    if (at < 0) return anchor;
    from = at + anchor.length;
  }
  return null;
}

/** 收集全部调用点。read 可注入（自测用）；scanErrors 列出作用域失衡且含调用点的文件。 */
export function collectSites({ root = ROOT, read = (rel) => fs.readFileSync(path.join(root, rel), 'utf8'),
  files, allowlist = ALLOWLIST } = {}) {
  const list = files ?? defaultFiles(root);
  const wrappersByFile = new Map();
  for (const entry of allowlist) {
    if (entry.wrapper) wrappersByFile.set(entry.file, [...(wrappersByFile.get(entry.file) ?? []), entry.wrapper]);
  }
  const sites = [];
  const scanErrors = [];
  const orderProblems = [];
  for (const file of [...list].sort()) {
    const text = read(file);
    if (file.endsWith('.patch')) {
      for (const site of scanPatch(text)) sites.push({ file, ...site });
      continue;
    }
    const { sites: found, balanced, masked } = scanSource(text, { wrappers: wrappersByFile.get(file) ?? [] });
    if (found.length && !balanced) scanErrors.push(file);
    for (const site of found) {
      sites.push({ file, ...site });
      for (const entry of allowlist) {
        if (!entry.before || entry.file !== file || entry.function !== site.function || entry.call !== site.call) continue;
        if (entry.name !== '*' && entry.name !== site.name) continue;
        if (!anchorFollows(masked, site, entry.before)) {
          orderProblems.push({ kind: 'order', detail: `${file}:${site.line} :: ${site.function} :: ${site.call}(${site.name}) must precede "${entry.before}" in the same function` });
        }
      }
    }
  }
  return { files: list.length, sites, scanErrors, orderProblems };
}

const keyOf = (item, fn = item.function, name = item.name) => [item.file, item.target ?? '', fn, item.call, name].join('\u0000');
const describe = (item) =>
  `${item.file}${item.target ? ` [${item.target}]` : ''} :: ${item.function} :: ${item.call}(${item.name})`;

function validateEntries(allowlist, problems) {
  const seen = new Set();
  for (const entry of allowlist) {
    const where = describe(entry);
    if (!PHASES.has(entry.phase)) problems.push({ kind: 'invalid-entry', detail: `${where}: unknown phase ${entry.phase}` });
    if (!entry.why || entry.why.trim().length < 12) problems.push({ kind: 'invalid-entry', detail: `${where}: why is missing` });
    if (entry.phase === 'pending-prebuilt-rebuild' && !entry.file.startsWith('prebuilt/')) {
      problems.push({ kind: 'invalid-entry', detail: `${where}: pending-prebuilt-rebuild is only for prebuilt/ sources` });
    }
    if (entry.phase === 'slot-registry' && entry.file !== SLOT_HEADER) {
      problems.push({ kind: 'invalid-entry', detail: `${where}: slot-registry is only for ${SLOT_HEADER}` });
    }
    const key = keyOf(entry);
    if (seen.has(key)) problems.push({ kind: 'invalid-entry', detail: `${where}: duplicate entry` });
    seen.add(key);
  }
}

// 名字级规则：首方（非 prebuilt/、非 env_slot.h）代码不得直接改写槽位名或已退役名。
function nameRuleProblems(sites) {
  const problems = [];
  for (const site of sites) {
    if (site.file.startsWith('prebuilt/') || site.file === SLOT_HEADER) continue;
    const name = canonicalName(site.name);
    if (name && SLOT_NAMES.has(name)) {
      problems.push({ kind: 'slot-name', detail: `${describe(site)} (line ${site.line}): ${name} is a pre-registered env slot; write it with env_slot.h Store/RequestRendererRestart, never setenv/unsetenv` });
    } else if (name && RETIRED_NAMES.has(name)) {
      problems.push({ kind: 'retired-name', detail: `${describe(site)} (line ${site.line}): ${name} was retired (${RETIRED_NAMES.get(name)})` });
    }
  }
  return problems;
}

/** 纯判定：sites 与 allowlist → 问题列表。 */
export function evaluate(sites, allowlist = ALLOWLIST) {
  const problems = [];
  validateEntries(allowlist, problems);
  problems.push(...nameRuleProblems(sites));
  const exact = new Map();
  const wildcard = new Map();
  for (const entry of allowlist) (entry.name === '*' ? wildcard : exact).set(keyOf(entry), entry);
  const counts = new Map();
  const lines = new Map();
  for (const site of sites) {
    const entry = exact.get(keyOf(site)) ?? wildcard.get(keyOf(site, site.function, '*'));
    if (!entry) {
      problems.push({ kind: 'unlisted', detail: `${describe(site)} (line ${site.line})` });
      continue;
    }
    counts.set(entry, (counts.get(entry) ?? 0) + 1);
    lines.set(entry, [...(lines.get(entry) ?? []), site.line]);
  }
  for (const entry of allowlist) {
    const found = counts.get(entry) ?? 0;
    const expected = entry.count ?? 1;
    if (found === 0) problems.push({ kind: 'stale', detail: `${describe(entry)}: no such call site any more` });
    else if (found !== expected) {
      problems.push({ kind: 'count-mismatch', detail: `${describe(entry)} (lines ${lines.get(entry).join(',')}): ${found} call(s), allowlist expects ${expected}` });
    }
  }
  return { ok: problems.length === 0, problems };
}

/** 顺序钉：每个 pin 的锚点必须按序出现在去注释文本里。 */
export function evaluatePins(read, pins = ORDER_PINS) {
  const problems = [];
  for (const pin of pins) {
    let text = null;
    try { text = read(pin.file); } catch { text = null; }
    const broken = text === null ? '(file missing)' : firstBrokenAnchor(text, pin.anchors);
    if (broken) problems.push({ kind: 'order-pin', detail: `${pin.id} (${pin.file}): anchor missing or out of order: ${broken} — ${pin.why}` });
  }
  return problems;
}

/** 完整门禁：可注入 read/files/allowlist/pins，自测用同一入口。 */
export function runGate({ root = ROOT, read, files, allowlist = ALLOWLIST, pins = ORDER_PINS } = {}) {
  const reader = read ?? ((rel) => fs.readFileSync(path.join(root, rel), 'utf8'));
  const collected = collectSites({ root, read: reader, files, allowlist });
  const verdict = evaluate(collected.sites, allowlist);
  const problems = [...verdict.problems, ...collected.orderProblems, ...evaluatePins(reader, pins)];
  for (const file of collected.scanErrors) problems.push({ kind: 'scan-error', detail: `${file}: brace scopes unbalanced; function attribution is unreliable` });
  return { ok: problems.length === 0, problems, sites: collected.sites, files: collected.files };
}

function main() {
  const json = process.argv.includes('--json');
  if (process.argv.includes('--list')) {
    const { sites } = collectSites();
    for (const s of sites) console.log(`${s.file}:${s.line}${s.target ? ` [${s.target}]` : ''} ${s.function} ${s.call}(${s.name})`);
    process.exit(0);
  }
  const result = runGate();
  const byPhase = {};
  for (const entry of ALLOWLIST) byPhase[entry.phase] = (byPhase[entry.phase] ?? 0) + (entry.count ?? 1);
  if (json) {
    process.stdout.write(`${JSON.stringify({ ok: result.ok, scannedFiles: result.files, sites: result.sites.length, byPhase, pins: ORDER_PINS.length, problems: result.problems })}\n`);
    process.exit(result.ok ? 0 : 1);
  }
  if (result.ok) {
    console.log(`env mutation OK: ${result.files} files, ${result.sites.length} call sites, all allowlisted ${JSON.stringify(byPhase)}, ${ORDER_PINS.length} order pins`);
  } else {
    console.error(`env mutation FAIL: ${result.problems.length} problem(s) in ${result.files} files / ${result.sites.length} call sites`);
    for (const p of result.problems) console.error(`  [${p.kind}] ${p.detail}`);
    console.error('  Runtime environment writes race every getenv on game/JVM threads (I27-05).');
    console.error('  Publish before the first game/JVM thread, or use platform/env_slot.h in-place slots.');
  }
  process.exit(result.ok ? 0 : 1);
}

if (import.meta.url === url.pathToFileURL(process.argv[1] ?? '').href) {
  main();
}
