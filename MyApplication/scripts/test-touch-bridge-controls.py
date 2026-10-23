"""编译真实bridge组合套件，并逐项破坏持有、坐标、取消、公共顺序和退休证明。

每项只改外置生产副本，编译成功后必须由正式轨迹CHECK拒绝；编译失败不是反控成功。
"""
from pathlib import Path
import sys
# 正式脚本只读；导入缓存和宿主产物均遵循外置路径契约。
sys.dont_write_bytecode = True
import argparse
import os
import re
import subprocess
import uuid
from lib.workspace_paths import external_output_path, workspace_path
from lib.host_cpp import find_host_cmake, configure_host_cmake

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', help='仓库外的证据目录；缺省自动外置')
parser.add_argument('--cmake', help='宿主CMake；缺省寻找原生工具')
args = parser.parse_args()
output_root = external_output_path(args.output) if args.output else workspace_path('run','touch-bridge-controls')
# 正常构建与独立预检可能来自同一仓的不同任务。每次运行独占变异源、可执行文件和日志，
# 防止另一个进程在编译/断言期间覆盖bridge.c，让错误变异的失败冒充本负控捕获。
# 根仍由工作区策略/显式外部路径决定；证据保留在独立叶目录，原始生产源始终只读。
run_id = 'run-' + str(os.getpid()) + '-' + uuid.uuid4().hex[:8]
output = output_root / run_id
output.mkdir(parents=True, exist_ok=True)
build_root = workspace_path('build', 'touch-bridge-controls') / run_id
build = build_root / 'build'
configure_source = build_root / 'fixture'
configure_source.mkdir(parents=True,exist_ok=True)
cmake_tool = find_host_cmake(args.cmake)
cpp = root / 'entry/src/main/cpp'
bridge = cpp / 'glfw/input_bridge_ohos.c'
source = bridge.read_text(encoding='utf-8')
# 临时变异副本只变换include的解析位置，不复制实现；生产源保持原位与原字节。
def absolute_include(match):
    name = match.group(1)
    target = (bridge.parent / name).resolve()
    return '#include "' + target.as_posix() + '"' if target.exists() else match.group(0)
source = re.sub(r'#include "([^"]+)"', absolute_include, source)
# 共同归约器为生产私有头，正例与反控均用完整真实正文。把它展开进独占的外置副本，
# 才能击中共用算法本身；不会修改原头文件，也不会通过编译期替身复制状态转换。
transaction = cpp / 'input/delivery/pointer_transaction.h'
transaction_include = '#include "' + transaction.as_posix() + '"'
assert source.count(transaction_include) == 1
source = source.replace(transaction_include, transaction.read_text(encoding='utf-8'), 1)
candidate = output / 'bridge.c'
cmake = f'''cmake_minimum_required(VERSION 3.16)
project(touch_bridge_controls LANGUAGES CXX)
find_package(Threads REQUIRED)
set_source_files_properties("{candidate.as_posix()}" PROPERTIES LANGUAGE CXX)
add_executable(controls "{(cpp/'tests/host/glfw_runtime_input_bridge_test.cpp').as_posix()}"
 "{candidate.as_posix()}"
 "{(cpp/'platform/input_ledger.cpp').as_posix()}"
 "{(cpp/'input/source/source_control.cpp').as_posix()}"
 "{(cpp/'platform/external_held_registry.cpp').as_posix()}"
 "{(cpp/'platform/external_held_edge_router.cpp').as_posix()}"
 "{(cpp/'platform/legacy_output_runtime.cpp').as_posix()}"
 "{(cpp/'platform/legacy_physical_edge_router.cpp').as_posix()}"
 "{(cpp/'input/delivery/look_execution.cpp').as_posix()}"
 "{(cpp/'platform/look_delta_math.cpp').as_posix()}"
 "{(cpp/'platform/look_pipeline_stats.cpp').as_posix()}"
 "{(cpp/'platform/legacy_ring_discontinuity.cpp').as_posix()}"
 "{(cpp/'input/input_interaction_order.cpp').as_posix()}"
 "{(cpp/'input/adapters/glfw_source_plane_aggregate.cpp').as_posix()}"
 "{(cpp/'input/delivery/control_delivery.cpp').as_posix()}"
 "{(cpp/'input/input_state_core.cpp').as_posix()}"
 # Core 真实 L2 held reader 的生产映射依赖；不提供伪造 mapper 或 weak fallback。
 "{(cpp/'input/adapters/backend_keymaps.cpp').as_posix()}"
 "{(cpp/'input/amcl_input_host_descriptor.cpp').as_posix()}"
 "{(cpp/'input/adapters/lwjgl2_event_translate.cpp').as_posix()}"
 "{(cpp/'platform/physical_wheel_quantizer.cpp').as_posix()}"
 "{(cpp/'tests/host/backend_input_bridge_host_stub.cpp').as_posix()}")
target_compile_features(controls PRIVATE cxx_std_17)
# 保持生产descriptor校验，宿主EXE显式导出它实际拥有的getter。
set_target_properties(controls PROPERTIES ENABLE_EXPORTS ON)
target_link_libraries(controls PRIVATE Threads::Threads ${{CMAKE_DL_LIBS}})
target_compile_definitions(controls PRIVATE AMCL_INPUT_BRIDGE_HOST_TESTING AMCL_CONTROL_DELIVERY_HOST_TESTING AMCL_INPUT_HOST_EXPORTS EVENT_WINDOW_SIZE=8 _CRT_SECURE_NO_WARNINGS)
target_include_directories(controls PRIVATE "{cpp.as_posix()}" "{(cpp/'input').as_posix()}" "{(cpp/'tests/host/stubs').as_posix()}")
if(MSVC)
 target_compile_options(controls PRIVATE /utf-8)
endif()
'''
(configure_source/'CMakeLists.txt').write_text(cmake,encoding='utf-8')
(output/'CMakeLists.txt').write_text(cmake,encoding='utf-8')
candidate.write_text(source,encoding='utf-8')
configure_host_cmake(cmake_tool,configure_source,build)
def check(name, body, negative=False):
    """编译错误/超时不是负对照成功；必须是本组合套件的运行时CHECK触发。"""
    candidate.write_text(body,encoding='utf-8')
    subprocess.run([cmake_tool,'--build',str(build),'--config','Release','--target','controls'],check=True)
    binary = build/'Release'/'controls.exe' if os.name=='nt' else build/'controls'
    result = subprocess.run([str(binary)],capture_output=True,text=True,timeout=30)
    (output/(name+'.log')).write_text(result.stdout+result.stderr,encoding='utf-8')
    if negative:
        assert result.returncode != 0 and 'GLFW RUNTIME BRIDGE FAIL' in result.stderr,result.stdout+result.stderr
        print('PASS negative control: '+name+' -> '+result.stderr.strip())
    else:
        assert result.returncode==0,result.stdout+result.stderr
        print(result.stdout.strip())
check('positive',source)
for name,before,after in [
    ('menu-latest-edge-wins','const bool after = legacyLeftHeld(state);','const bool after = held;'),
    ('drop-current-held-baseline','baseline->held = g_producerOrdinary;','memset(&baseline->held,0,sizeof(baseline->held));'),
    ('drop-accepted-key-512','i1 <= 512','i1 < 512'),
    ('baseline-precedes-pending-typed','baseline->interactionOrder = amclInputInteractionFence();','baseline->interactionOrder = 0;'),
    ('local-overflow-increments-global-epoch','if (l2Recovery || l3Recovery) {','if (l2Recovery || l3Recovery) { noteLegacyRingDiscontinuity();'),
    # 三个consumer的源点由同一生产实现冻结；变异必须在真实最终轨迹上被识别。
    ('common-source-coordinate-corrupted','state->sourceX = x; state->sourceY = y;',
      'state->sourceX = x + 1; state->sourceY = y;'),
    ('glfw-cancel-loses-priority',
      'const bool cancelled = queuedMenuInvalidates(g_glfwPointer.token, g_glfwPointer.scopeEpoch,\n        read, cancelTarget, maxOrder, g_glfwPointer.gestureBegun);',
      'const bool cancelled = false;'),
    ('pending-typed-overtakes-source',
      'const uint64_t typedCeiling = g_glfwPointer.pressPending && g_glfwPointer.pendingOrder <= maxOrder\n        ? g_glfwPointer.pendingOrder - 1ULL : maxOrder;',
      'const uint64_t typedCeiling = maxOrder;'),
    ('common-up-discards-final-position',
      'plan.position = phase != AMCL_POINTER_CANCEL && (phase != AMCL_POINTER_END || endMoves);',
      'plan.position = phase != AMCL_POINTER_CANCEL && phase != AMCL_POINTER_UP && (phase != AMCL_POINTER_END || endMoves);'),
    ('common-committed-up-keeps-contribution',
      'plan.contribution = state->buttonDown ? 0 : -1; amclPointerFinishUp(state);',
      'plan.contribution = -1; amclPointerFinishUp(state);'),
    ('common-source-frame-gate-removed',
      'if (state->pendingOrder > maxOrder || presentSerial < state->pressAfterPresent) return AMCL_POINTER_WAIT;',
      'if (state->pendingOrder > maxOrder) return AMCL_POINTER_WAIT;'),
    ('common-duplicate-down-borrows-begin',
      'return phase == AMCL_POINTER_DOWN && token == currentToken && begun && !heldOrPending && !downAccepted;',
      'return phase == AMCL_POINTER_DOWN && token == currentToken && begun;'),
    ('common-late-down-after-up-reclaims-contact',
      'return phase == AMCL_POINTER_DOWN && token == currentToken && begun && !heldOrPending && !downAccepted;',
      'return phase == AMCL_POINTER_DOWN && token == currentToken && begun && !heldOrPending;'),
    ('touch-scope-does-not-retire',
      'atomic_fetch_add_explicit(&g_touchMenuScopeEpoch, 1ULL, memory_order_release);',
      '/* negative: do not advance menu scope */'),
    ('tool-left-contribution-omitted',
      'return state->ordinaryLeftHeld || state->committedMenuActive || state->toolLeftHeld;',
      'return state->ordinaryLeftHeld || state->committedMenuActive;'),
    ('paused-candidate-exceeds-deadline',
      '#define MENU_PENDING_TIMEOUT_NS 500000000ULL',
      '#define MENU_PENDING_TIMEOUT_NS 600000000ULL')
]:
    assert source.count(before)==1,name
    check(name,source.replace(before,after,1),negative=True)
# tool-only与fullscope都推进工具代次，必须只变异工具入口的真实定义，不能误改完整退休。
tool_start = source.index('JNIEXPORT void inputBridge_retireTouchMenuToolScopeV1(void) {')
tool_end = source.index('\n}\n', tool_start) + len('\n}')
tool_body = source[tool_start:tool_end]
tool_epoch = 'atomic_fetch_add_explicit(&g_touchMenuToolScopeEpoch, 1ULL, memory_order_release);'
assert tool_body.count(tool_epoch) == 1
for name, replacement in [
    ('tool-cancel-leaves-queued-click', '(void)0; /* negative: preserve old tool epoch */'),
    ('tool-cancel-widens-to-direct-menu', tool_epoch + '\n    atomic_fetch_add_explicit(&g_touchMenuScopeEpoch, 1ULL, memory_order_release);'),
]:
    mutated = tool_body.replace(tool_epoch, replacement, 1)
    check(name, source[:tool_start] + mutated + source[tool_end:], negative=True)
# 留存完整生产副本，负对照源码单独保存收据；之后重新使用target会自动恢复正例。
candidate.write_text(source,encoding='utf-8')
# 负控二进制也属于该外置目标；结束前真正重新编译/运行生产，不能只还原源文件后遗留旧二进制。
check('restored-production',source)
