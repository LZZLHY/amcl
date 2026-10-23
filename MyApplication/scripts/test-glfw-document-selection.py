"""复用已执行的26TU文本链，以最终WT sink与单函数撤回体核验同一行为判据。

唯一owner/ingress/Source/adapter/bridge编译原生产文件。只提供明确的宿主窗口、
hilog和callback采集边缘，不伪造Core、READY或owned blob Read/Release。
固定合法wire轨迹直接通过原lease的Native文本入口，原Runtime后来不再发送错域
消息也不能遮住消费端回归。每轮源码冻结与正例/已编译撤回/再次编译恢复分别留证。
"""
from datetime import datetime
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import sys
import argparse
import signal
import threading
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
from lib.workspace_paths import external_output_path, workspace_path
from lib.host_cpp import find_host_cmake, configure_host_cmake
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', help='新建仓库外证据目录；缺省使用工作区run')
parser.add_argument('--build-output', help='新建仓库外宿主构建树；缺省使用工作区build')
parser.add_argument('--cmake', help='显式宿主CMake，不接受SDK交叉编译代替宿主')
options = parser.parse_args()
run_id = 'glfw-doc-' + datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6]
OUT = external_output_path(options.output) if options.output else workspace_path('run', run_id)
BUILD = external_output_path(options.build_output) if options.build_output else workspace_path('build', run_id)
if OUT.exists() or BUILD.exists():
    raise ValueError('Evidence/build outputs must be new external directories')
OUT.mkdir(parents=True);BUILD.mkdir(parents=True)

def sha(path):
    """记录真实读入原字节，绝不把LF/CRLF语义等同当作raw身份。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()

def body(source, name):
    """传递具名现役函数的完整定义；只定位，不生成或改写生产输入政策。"""
    match = re.search(r'(?m)^(?:static )?(?:void|bool|GLFWpreeditfun|GlfwPreeditState\*|amcl::input::GlfwInputSink)\s+' + re.escape(name) + r'\s*\(', source)
    if match is None:
        raise RuntimeError('Missing original definition: ' + name)
    begin = source.index('{', match.start())
    depth, end = 1, begin + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[match.start():end]

def execute(command, name, expected=0):
    """前台实时输出，原日志/退出码保留；超时只结束本命令树，不能冒充行为负控。"""
    started = datetime.now().astimezone().isoformat()
    command = list(map(str, command))
    with (OUT / (name + '.log')).open('wb') as log:
        process = subprocess.Popen(command, cwd=BUILD, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, start_new_session=os.name != 'nt')
        chunks = []
        def capture():
            # 仅观察宿主工具输出，不接触任何产品输入state/clock/lease。
            for line in process.stdout:
                log.write(line);log.flush();chunks.append(line)
                print(line.decode('utf-8', errors='replace').rstrip(), flush=True)
        reader = threading.Thread(target=capture, daemon=True);reader.start()
        try:
            code = process.wait(timeout=240)
        except subprocess.TimeoutExpired:
            if os.name == 'nt':
                subprocess.run(['taskkill','/PID',str(process.pid),'/T','/F'],
                    capture_output=True, timeout=10)
            else:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10);reader.join(timeout=10)
            raise RuntimeError(name + ': tool timeout; no behavioral negative claimed')
        reader.join(timeout=10)
        if reader.is_alive():raise RuntimeError(name + ': output stream did not finish')
    checks.append({'name':name,'startedAt':started,'endedAt':datetime.now().astimezone().isoformat(),
        'command':command,'exitCode':code,'expectedExitCode':expected})
    (OUT/'execution-checks.json').write_text(json.dumps(checks,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    if code != expected:raise RuntimeError(name+': actual exit '+str(code))
    return b''.join(chunks)

started = datetime.now().astimezone().isoformat()
checks = []
BUILD.mkdir(parents=True, exist_ok=True)
(BUILD / 'temp').mkdir(exist_ok=True)
os.environ.update(TEMP=str(BUILD / 'temp'), TMP=str(BUILD / 'temp'),
                  TMPDIR=str(BUILD / 'temp'))
cpp = ROOT / 'entry/src/main/cpp'
frozen = BUILD / 'source/entry/src/main/cpp'
identities = {}
for path in sorted(cpp.rglob('*')):
    if path.is_file() and path.suffix in {'.c', '.cpp', '.h', '.hpp'}:
        data = path.read_bytes()
        target = frozen / path.relative_to(cpp)
        target.parent.mkdir(parents=True, exist_ok=True)
        # 重用上一轮实际构建树时只接受相同冻结原字节，不拿新源码补旧编译身份。
        if target.exists():
            if target.read_bytes()!=data:raise RuntimeError('Frozen production source drift: '+str(path))
        else:target.write_bytes(data)
        identities[path.relative_to(ROOT).as_posix()] = hashlib.sha256(data).hexdigest()

# 此固定wire轨迹来自已复现的原lease反例；它独立于后来Runtime是否停止发送该消息，
# 从而真实GLFW消费政策回归时仍能被捕获，不借新的UI入口遮住Native旧出口。
callbacks = (frozen / 'glfw/glfw_callbacks.cpp').read_text(encoding='utf-8')
compat = (frozen / 'glfw/glfw_compat.cpp').read_text(encoding='utf-8')
internal = (frozen / 'glfw/glfw_internal.h').read_text(encoding='utf-8')
state = re.search(r'struct GlfwPreeditState \{[\s\S]*?\n\};', internal).group(0)
callback_names = ['ensurePreeditState', 'dispatchPreedit', 'glfwSetPreeditCallback',
    'glfwOHOS_UpdatePreedit', 'glfwOHOS_UpdatePreeditSelection',
    'glfwOHOS_UpdatePreeditCandidates', 'glfwOHOS_NotifyImeStatus',
    'glfwOHOS_ResetPreedit', 'glfwOHOS_DestroyPreeditState']
sink_names = ['typedResetSink', 'decodeTypedUtf8', 'recordTypedTextDecodeFailure',
    'typedTextSessionSink', 'typedTextCommitSink', 'typedTextEditingSink',
    'typedTextCandidatesSink', 'typedTextSelectionSink', 'typedTextOnlySink']
functions = '\n\n'.join(body(callbacks, name) for name in callback_names)
functions += '\n\n' + '\n\n'.join(body(compat, name) for name in sink_names)
fixed_sink = body(compat, 'typedTextSelectionSink')
# 仅恢复旧错误授权：有preview且数值合法便把文档selection写入preedit。
# 其它现役函数/25生产TU、全部行为断言与合法预编辑对照均不变。
old_sink = fixed_sink.replace('GlfwTextSelectionSinkEvent&)', 'GlfwTextSelectionSinkEvent& event)', 1)
opening = old_sink.index('{') + 1
old_sink = old_sink[:opening] + """
    if (glfwOHOS_UpdatePreeditSelection(g_currentWindow,
            static_cast<int>(event.selectionStart), static_cast<int>(event.selectionLength))) return;
""" + old_sink[opening:]
assert old_sink != fixed_sink and 'event.selectionStart' in old_sink
assert functions.count(fixed_sink) == 1
withdrawn = functions.replace(fixed_sink, old_sink, 1)

fixture_path = cpp/'tests/host/glfw_document_selection.cpp.in'
template = fixture_path.read_text(encoding='utf-8')
identities[fixture_path.relative_to(ROOT).as_posix()] = sha(fixture_path)
identities[Path(__file__).relative_to(ROOT).as_posix()] = sha(Path(__file__))
# 只替换独占整行标记；模板说明中的标记名不得被注入一遍函数而破坏注释或定义。
assert template.count('\n@STATE@\n') == 1 and template.count('\n@PRODUCTION@\n') == 1
for name, production in [('fixed.cpp', functions), ('withdrawn.cpp', withdrawn), ('restored.cpp', functions)]:
    generated = template.replace('\n@STATE@\n', '\n' + state + '\n', 1)
    generated = generated.replace('\n@PRODUCTION@\n', '\n' + production + '\n', 1)
    (BUILD / name).write_text(generated, encoding='utf-8')

source_names = [
    'input/platform_input_ingress.cpp', 'input/input_shadow_consumer.cpp', 'input/input_trace.cpp',
    'input/delivery/look_execution.cpp', 'input/delivery/control_delivery.cpp', 'input/source/source_control.cpp',
    'platform/legacy_output_runtime.cpp', 'platform/legacy_physical_edge_router.cpp',
    'input/amcl_input_host_descriptor.cpp', 'input/input_state_core.cpp', 'input/adapters/glfw_input_adapter.cpp',
    'input/adapters/backend_input_bridge.cpp', 'input/adapters/backend_keymaps.cpp', 'input/adapters/lwjgl2_event_translate.cpp',
    'input/adapters/glfw_typed_absolute_route.cpp', 'input/input_interaction_order.cpp',
    'platform/physical_wheel_quantizer.cpp', 'platform/source_look_processor.cpp', 'platform/look_delta_math.cpp',
    'platform/look_pipeline_stats.cpp', 'platform/input_source.cpp', 'platform/input_ledger.cpp',
    'platform/external_held_registry.cpp', 'platform/external_held_edge_router.cpp', 'glfw/input_bridge_ohos.c',
]
sources = '\n'.join('"' + (frozen / name).as_posix() + '"' for name in source_names)
includes = ' '.join('"' + path.as_posix() + '"' for path in [frozen, frozen / 'input',
    frozen / 'platform', frozen / 'tests/host/stubs'])
cmake = '''cmake_minimum_required(VERSION 3.20)
project(ime_range_fix LANGUAGES CXX)
find_package(Threads REQUIRED)
set_source_files_properties("''' + (frozen / 'glfw/input_bridge_ohos.c').as_posix() + '''" PROPERTIES LANGUAGE CXX)
# owner解析采用宿主EXE名称契约，但bridge仍读取真实Core路由位；本组合没有可编程transport替身。
if(MSVC)
 set_property(SOURCE "''' + (frozen / 'glfw/input_bridge_ohos.c').as_posix() + '''" APPEND PROPERTY COMPILE_OPTIONS /UAMCL_CONTROL_DELIVERY_HOST_TESTING)
else()
 set_property(SOURCE "''' + (frozen / 'glfw/input_bridge_ohos.c').as_posix() + '''" APPEND PROPERTY COMPILE_OPTIONS -UAMCL_CONTROL_DELIVERY_HOST_TESTING)
endif()
add_library(ime_owner OBJECT
''' + sources + ''')
target_compile_features(ime_owner PUBLIC cxx_std_17)
# 真实owner位于宿主EXE，沿用host名称契约；PUBLIC让三个消费者保留一致的严格身份验证条件。
target_compile_definitions(ime_owner PUBLIC AMCL_INPUT_HOST_EXPORTS AMCL_INPUT_SHADOW=0 AMCL_INPUT_BRIDGE_HOST_TESTING AMCL_CONTROL_DELIVERY_HOST_TESTING _CRT_SECURE_NO_WARNINGS NOMINMAX)
if(MSVC)
 target_compile_options(ime_owner PUBLIC /utf-8 /UNDEBUG)
else()
 target_compile_options(ime_owner PUBLIC -UNDEBUG)
endif()
target_include_directories(ime_owner PUBLIC ''' + includes + ''')
add_executable(ime_range_fixed fixed.cpp)
target_link_libraries(ime_range_fixed PRIVATE ime_owner Threads::Threads ${CMAKE_DL_LIBS})
add_executable(ime_range_withdrawn withdrawn.cpp)
target_link_libraries(ime_range_withdrawn PRIVATE ime_owner Threads::Threads ${CMAKE_DL_LIBS})
add_executable(ime_range_restored restored.cpp)
target_link_libraries(ime_range_restored PRIVATE ime_owner Threads::Threads ${CMAKE_DL_LIBS})
# 三个独立进程都走同一真实owner身份验证；撤回只改被测语义，不撤掉必要动态符号。
set_target_properties(ime_range_fixed ime_range_withdrawn ime_range_restored PROPERTIES ENABLE_EXPORTS ON)
'''
(BUILD / 'CMakeLists.txt').write_text(cmake, encoding='utf-8')
tool = find_host_cmake(options.cmake);configure_host_cmake(tool, BUILD, BUILD / 'host')
execute([tool, '--build', BUILD/'host', '--config','Release','--target','ime_range_fixed','ime_range_withdrawn'], 'compile')
binary_root=BUILD/'host/Release' if os.name=='nt' else BUILD/'host'
suffix='.exe' if os.name=='nt' else ''
positive=binary_root/('ime_range_fixed'+suffix)
negative=binary_root/('ime_range_withdrawn'+suffix)
restored=binary_root/('ime_range_restored'+suffix)
modes = ['document-range', 'valid-preedit', 'document-selection-without-preview',
         'document-selection-with-preview', 'document-selection-outside-preview']
for mode in modes:
    execute([positive, mode], 'fixed-' + mode)
negative_log = execute([negative, 'document-range'], 'withdrawn-document-range', 1)
assert b'IME CORE RANGE CHECK' in negative_log and b'DOCUMENT_SELECTION_ISOLATED' in negative_log
execute([negative, 'valid-preedit'], 'withdrawn-valid-preedit-control')
execute([negative, 'document-selection-without-preview'], 'withdrawn-without-preview-control')
# 撤回后恢复体另作真正编译/链接，再跑所有原正例，不只把源码改回而沿用旧二进制。
execute([tool,'--build',BUILD/'host','--config','Release','--target','ime_range_restored'],'compile-restored')
for mode in modes:execute([restored,mode],'restored-'+mode)
after = {name: sha(ROOT / name) for name in identities}
drift = [name for name in identities if identities[name] != after[name]]
receipt = {
    'startedAt': started, 'endedAt': datetime.now().astimezone().isoformat(),
    'worktreeHead': subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip(),
    'frozenInputCount':len(identities),'productionTranslationUnits':len(source_names),'hostFixtureTranslationUnits':1,
    'sourceBefore': identities, 'sourceAfter': after, 'sourceDrift': drift,
    'candidateSha256':sha(ROOT/'entry/src/main/cpp/glfw/glfw_compat.cpp'),
    'checks': checks, 'fixedBinarySha256': sha(positive), 'withdrawnBinarySha256': sha(negative),
    'fixedFixtureSha256': sha(BUILD / 'fixed.cpp'), 'withdrawnFixtureSha256': sha(BUILD / 'withdrawn.cpp'),
    'restoredBinarySha256':sha(restored),'restoredFixtureSha256':sha(BUILD/'restored.cpp'),
    'negativeOnlyDifference':'typedTextSelectionSink restores old active-preedit range authorization; all other functions/assertions/25 production TUs identical',
    'gitModified': False, 'sdkUsed': False, 'hdcUsed': False,
    'boundary': 'Actual ingress/unique Core/Source/full adapter ReadPacketBlob/ReleasePacket/current text-only GLFW sink/public preedit callback; explicit host window/hilog edge; not full GLFW SDK DSO or actual OS/game',
    'documentReplacementImplemented': False, 'earlyNativeQueuePermissionClosed': False,
}
(OUT / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
if drift:
    raise RuntimeError('Frozen production or Main GLFW bytes drifted')
print(json.dumps({'receipt': str(OUT / 'receipt.json'), 'receiptSha256': sha(OUT / 'receipt.json'),
    'sourceDrift': drift}, ensure_ascii=False), flush=True)
