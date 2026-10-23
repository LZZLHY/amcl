"""真实公共 CallbackBridge 字符：Java/JNI/owner → 正式 ring → 三个消费出口。

完整CallbackBridge、JNI注册表/OnLoad、bridge/Core均编译真实源码。GLFW注册真实
回调，L2用维护JAR的AMCLDisplay/Keyboard.next，SDL用完整SDK的TextInput/PollEvent。
窗口、未采集typed运输是显式边缘；不复制owner归约、不fake resolveHost或固定成功。
目前完整JNI宿主配方支持Windows，其他系统明确不支持，不能把它记为消费PASS。
"""
import argparse
from datetime import datetime
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import zipfile

from lib.host_cpp import configure_host_cmake, find_host_cmake
from lib.workspace_paths import external_output_path, workspace_path

ROOT = Path(__file__).resolve().parents[1]
CPP = ROOT / 'entry/src/main/cpp'
FIXTURE = ROOT / 'scripts/fixtures/compat-characters'
JAVA = ROOT / 'prebuilt/lwjgl3/ohos-glfw/src/org/lwjgl/glfw/CallbackBridge.java'


def digest(path):
    """材料/生产快照按内容绑定，不依赖文件时间、名字或编译输出目录。"""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def freeze(path, target, identities):
    """一次读取同一份字节再写入仓外快照；收据记录真正送入编译器的内容身份。

    协作中的look模块可在测试期间继续施工，不能在编译末尾读取工作树并把新SHA
    当作本次使用的源码。原文快照保留目录关系，让相对include解析到同一冻结批次。
    """
    data = path.read_bytes()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    identities[path.relative_to(ROOT).as_posix()] = hashlib.sha256(data).hexdigest()
    return target


def module(path, name):
    """复用既有真实L2/SDL源码提取器，不新造另一套消费者实现。"""
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def execute(args, cwd, log, negative=False):
    """前台工具与真实JVM保原日志；只有明确行为AssertionError才算撤回负控。"""
    result = subprocess.run(list(map(str, args)), cwd=cwd, capture_output=True, timeout=180)
    data = result.stdout + result.stderr
    log.write_bytes(data)
    print(data.decode('utf-8', errors='replace')[-6000:], flush=True)
    if negative:
        if result.returncode == 0 or b'COMPAT_CHAR' not in data or b'AssertionError' not in data:
            raise RuntimeError('Compiled negative did not fail actual character behavior: ' + str(log))
    elif result.returncode:
        raise RuntimeError('Actual tool/JVM failed: ' + str(log))
    return result.returncode


def sdl_source(options, output, logs):
    """优先读显式完整已应用源；独立clone可从锁定Git取完整源并应用全部正式series。"""
    if options.sdl_root:
        return options.sdl_root.resolve()
    if not options.sdl_source_repo:
        raise ValueError('Pass --sdl-root (applied full source) or --sdl-source-repo (locked Git source)')
    section = re.search(r'^\[sdl3-native\]\s*\n([\s\S]*?)(?=^\[|\Z)',
                        (ROOT / 'deps.lock').read_text(encoding='utf-8'), re.M).group(1)
    commit = re.search(r'^commit\s*=\s*([0-9a-f]{40})', section, re.M).group(1)
    archive = subprocess.check_output(['git', '-C', str(options.sdl_source_repo), 'archive', commit])
    source = output / 'sdl-source'; source.mkdir()
    with tarfile.open(fileobj=io.BytesIO(archive)) as contents:
        for item in contents:
            target = (source / item.name).resolve()
            if not target.is_relative_to(source.resolve()) or item.issym() or item.islnk():
                raise ValueError('SDL archive member crosses source boundary')
            contents.extract(item, source, filter='data')
    patches = ROOT / 'prebuilt/sdl3/patches'
    for name in (patches / 'series').read_text(encoding='utf-8').splitlines():
        if not name.strip() or name.startswith('#'):
            continue
        execute(['git', '-c', 'core.autocrlf=false', 'apply', '--check', patches / name],
                source, logs / (name + '.check.log'))
        execute(['git', '-c', 'core.autocrlf=false', 'apply', patches / name],
                source, logs / (name + '.apply.log'))
    return source


def build(options):
    """冻结本次读取的生产输入，原文构建完成后以新JVM跑各回调与identity反例。"""
    if os.name != 'nt':
        raise RuntimeError('Actual Windows JNI/SDL fixture is unavailable on this host; no consumer PASS claimed')
    logs = external_output_path(options.out or workspace_path('run', 'compat-characters'))
    work = external_output_path(options.build_out or workspace_path('build', 'compat-characters'))
    if logs.exists() or work.exists():
        raise ValueError('Character evidence and build outputs must be new external directories')
    logs.mkdir(parents=True); work.mkdir(parents=True)
    acquired = datetime.now().astimezone().isoformat()
    identities = {}
    # 冻结完整本地C/C++源码/头文件闭包，编译只选下面列出的生产单元。即使其它协作
    # 者修改原树，这次compiler/include仍只读快照；收据不宣称未参与的模块已经运行。
    cpp = work / 'production-cpp'
    for path in sorted(CPP.rglob('*')):
        if path.is_file() and path.suffix in {'.c', '.cpp', '.h', '.hpp'}:
            freeze(path, cpp / path.relative_to(CPP), identities)
    frozen_java = freeze(JAVA, work / 'production-java/CallbackBridge.java', identities)
    jar = freeze(ROOT / 'entry/src/main/resources/rawfile/lwjgl2/lwjgl.jar', work / 'lwjgl.jar', identities)
    backend_path = ROOT / 'prebuilt/lwjgl2/ohos-backend/amcl_lwjgl2_backend.c'
    frozen_backend = freeze(backend_path, work / 'production-l2.c', identities)
    frozen_fixtures = work / 'fixtures'
    for path in sorted(FIXTURE.glob('*')):
        if path.is_file():
            freeze(path, frozen_fixtures / path.name, identities)
    for path in [Path(__file__), ROOT / 'scripts/generate-desktop-review-tests.py',
                 ROOT / 'scripts/test-lwjgl2-control-delivery.py']:
        identities[path.relative_to(ROOT).as_posix()] = digest(path)
    temp = work / 'temp'; temp.mkdir()
    os.environ.update(TEMP=str(temp), TMP=str(temp), TMPDIR=str(temp))
    jdk = Path(options.jdk or os.environ.get('AMCL_LWJGL2_JDK8') or
               os.environ.get('AMCL_LWJGL2_JDK') or '').resolve()
    inputs = Path(options.inputs or os.environ.get('AMCL_LWJGL2_INPUTS') or '').resolve()
    for name in ['java.exe', 'javac.exe']:
        if not (jdk / 'bin' / name).is_file():
            raise FileNotFoundError('Actual character JVM/compiler missing: ' + str(jdk / 'bin' / name))
    spec = json.loads((ROOT / 'prebuilt/lwjgl2/build-inputs.json').read_text(encoding='utf-8'))
    archive = inputs / 'lwjgl-2df01dd.zip'
    if digest(archive) != spec['files'][archive.name]:
        raise ValueError('Character fixture requires exact locked L2 source ZIP')
    recipe = module(ROOT / 'scripts/generate-desktop-review-tests.py', 'compat_sdl_recipe')
    source = sdl_source(options, work, logs)
    sdl = (source / 'src/video/openharmony/SDL_openharmonyamcl.c').read_text(encoding='utf-8')
    start = sdl.index('        case AMCL_EVENT_CHAR:\n')
    end = sdl.index('        case AMCL_EVENT_MOUSE_BUTTON:', start)
    char_body = sdl[start:end]
    canonical = recipe.patch_sources()['SDL_openharmonyamcl.c']
    a = canonical.index('        case AMCL_EVENT_CHAR:\n')
    b = canonical.index('        case AMCL_EVENT_MOUSE_BUTTON:', a)
    if char_body != canonical[a:b]:
        raise ValueError('Applied SDL character dispatch differs from formal ordered patches')
    registry = (cpp / 'jvm/jni_registry.cpp').read_text(encoding='utf-8')
    declarations = registry[registry.index('extern "C" {'):registry.index('// ============================================================\n// 精确方法表')]
    bridge_path = cpp / 'glfw/input_bridge_ohos.c'
    bridge = bridge_path.read_text(encoding='utf-8')
    bridge = re.sub(r'#include "([^"]+)"', lambda hit: '#include "' +
                    (bridge_path.parent / hit[1]).resolve().as_posix() + '"'
                    if (bridge_path.parent / hit[1]).resolve().exists() else hit[0], bridge)
    (work / 'bridge.cpp').write_text(declarations + '\n' + bridge, encoding='utf-8')
    # 只替代Windows缺席的POSIX PID头，真实registry/table/bind仍编译正式CPP。
    (work / 'unistd.h').write_text('#pragma once\n#include <process.h>\ninline int getpid(){return _getpid();}\n', encoding='utf-8')
    owner = (frozen_fixtures / 'owner.cpp.in').read_text(encoding='utf-8')
    old_start = owner.index('        case AMCL_EVENT_CHAR:\n')
    old_end = owner.index(' default:break;}}', old_start)
    owner = owner[:old_start] + char_body + owner[old_end:]
    (work / 'owner.cpp').write_text(owner.replace('@CPP@', cpp.as_posix()), encoding='utf-8')
    (work / 'foreign.cpp').write_text((frozen_fixtures / 'foreign.cpp.in').read_text(encoding='utf-8').replace('@CPP@', cpp.as_posix()), encoding='utf-8')
    for name in ['CompatCharTest.java', 'CompatL2CharConsumer.java']:
        shutil.copy2(frozen_fixtures / name, work / name)
    l2 = module(ROOT / 'scripts/test-lwjgl2-control-delivery.py', 'compat_l2_recipe')
    with zipfile.ZipFile(archive) as contents:
        common = contents.read('lwjgl-' + spec['sourceCommit'] + '/src/native/common/common_tools.c').decode('utf-8')
    backend = frozen_backend.read_text(encoding='utf-8')
    control = backend[backend.index('static int control_write_emission('):backend.index('/* grab 切换：', backend.index('static int control_write_emission('))]
    contract = backend[backend.index('#define AMCL_L2_CONTROL_PROTOCOL'):backend.index('static int s_width')]
    n = backend.index('JNIEXPORT jboolean JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nNextEvent')
    next_event = backend[n:backend.index('\n/* ===================== 末级控制私有JNI', n)]
    suffix = l2.NATIVE_SUFFIX
    old = l2.function_text(suffix, 'next_record')
    suffix = suffix.replace(old, '__declspec(dllimport) int compatL2Next(int*,int*,int*,int*,int*);\nstatic int next_record(int*t,int*a,int*b,int*c,int*d){return compatL2Next(t,a,b,c,d);}', 1)
    throwers = '\n'.join(l2.function_text(common, name) for name in ['throwGeneralException', 'throwException'])
    other = '\n'.join(l2.function_text(backend, name) for name in ['Java_org_lwjgl_opengl_AMCLDisplay_nInputContract', 'Java_org_lwjgl_opengl_AMCLDisplay_nLookContract', 'Java_org_lwjgl_opengl_AMCLDisplay_nCreateWindow', 'Java_org_lwjgl_opengl_AMCLContextImplementation_nCreate'])
    (work / 'l2.c').write_text('\n'.join([l2.NATIVE_PREFIX, throwers, contract, control, suffix, other, next_event]), encoding='utf-8')
    # 默认重建完整宿主SDK；显式cache只接受调用方选定的SDK库/配置并记录其内容身份。
    if options.sdl_sdk_root:
        sdk = options.sdl_sdk_root.resolve()
        sdk_project = ''
        sdk_link = '"' + (sdk / 'Release/SDL3-static.lib').as_posix() + '"'
    else:
        sdk = work / 'host/sdk'
        sdk_project = '''set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_STATIC ON CACHE BOOL "" FORCE)
set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
set(SDL_TESTS OFF CACHE BOOL "" FORCE)
set(SDL_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SDL_AUDIO OFF CACHE BOOL "" FORCE)
set(SDL_RENDER OFF CACHE BOOL "" FORCE)
set(SDL_GPU OFF CACHE BOOL "" FORCE)
set(SDL_CAMERA OFF CACHE BOOL "" FORCE)
set(SDL_HIDAPI OFF CACHE BOOL "" FORCE)
set(SDL_SENSOR OFF CACHE BOOL "" FORCE)
add_subdirectory("''' + source.as_posix() + '''" sdk)
'''
        sdk_link = 'SDL3::SDL3-static'
    cmake = f'''cmake_minimum_required(VERSION 3.20)
project(compat_char C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS ON)
{sdk_project}
# 完整 bridge 的现役 key/terminal 入口借唯一 Source；补真实账本闭包，不用缺符号 stub。
add_library(compat_owner SHARED owner.cpp bridge.cpp "{cpp.as_posix()}/input/source/source_control.cpp" "{cpp.as_posix()}/platform/input_ledger.cpp" "{cpp.as_posix()}/platform/external_held_registry.cpp" "{cpp.as_posix()}/platform/external_held_edge_router.cpp" "{cpp.as_posix()}/platform/legacy_output_runtime.cpp" "{cpp.as_posix()}/platform/legacy_physical_edge_router.cpp" "{cpp.as_posix()}/jvm/jni_registry.cpp" "{cpp.as_posix()}/input/input_state_core.cpp" "{cpp.as_posix()}/input/adapters/backend_keymaps.cpp" "{cpp.as_posix()}/input/amcl_input_host_descriptor.cpp" "{cpp.as_posix()}/input/input_interaction_order.cpp" "{cpp.as_posix()}/input/delivery/control_delivery.cpp" "{cpp.as_posix()}/input/delivery/look_execution.cpp" "{cpp.as_posix()}/platform/look_delta_math.cpp" "{cpp.as_posix()}/platform/look_pipeline_stats.cpp" "{cpp.as_posix()}/input/adapters/lwjgl2_event_translate.cpp" "{cpp.as_posix()}/platform/physical_wheel_quantizer.cpp" "{cpp.as_posix()}/tests/host/backend_input_bridge_host_stub.cpp")
target_compile_definitions(compat_owner PRIVATE AMCL_JNI_BRIDGE_HOST_TEST AMCL_INPUT_BRIDGE_HOST_TESTING AMCL_CONTROL_DELIVERY_HOST_TESTING AMCL_INPUT_HOST_EXPORTS _CRT_SECURE_NO_WARNINGS)
target_include_directories(compat_owner PRIVATE "{work.as_posix()}" "{cpp.as_posix()}/tests/host/stubs" "{cpp.as_posix()}/input" "{source.as_posix()}/src" "{source.as_posix()}/include" "{sdk.as_posix()}/include-config-release/build_config" "{sdk.as_posix()}/include-revision")
target_link_libraries(compat_owner PRIVATE {sdk_link} user32 gdi32 winmm imm32 ole32 oleaut32 version uuid advapi32 setupapi cfgmgr32 shell32 bcrypt opengl32 dinput8 dxguid)
target_compile_options(compat_owner PRIVATE /utf-8)
add_library(jni_reregister SHARED "{cpp.as_posix()}/glfw/jni_reregister.c")
target_compile_definitions(jni_reregister PRIVATE AMCL_JNI_BRIDGE_HOST_TEST _CRT_SECURE_NO_WARNINGS)
add_library(foreign_owner SHARED foreign.cpp)
target_link_libraries(foreign_owner PRIVATE compat_owner)
add_library(lwjgl_v2 SHARED l2.c)
target_compile_definitions(lwjgl_v2 PRIVATE AMCL_CONTROL_DELIVERY_HOST_TESTING _CRT_SECURE_NO_WARNINGS)
target_include_directories(lwjgl_v2 PRIVATE "{cpp.as_posix()}/input/delivery" "{(jdk/'include').as_posix()}" "{(jdk/'include/win32').as_posix()}")
target_link_libraries(lwjgl_v2 PRIVATE compat_owner)
target_compile_options(lwjgl_v2 PRIVATE /utf-8)
'''
    (work / 'CMakeLists.txt').write_text(cmake, encoding='utf-8')
    tool = find_host_cmake(options.cmake)
    configure_host_cmake(tool, work, work / 'host')
    execute([tool, '--build', work / 'host', '--config', 'Release', '--parallel', '4'], work, logs / 'compile.log')
    classes = work / 'classes'; classes.mkdir()
    java_args = [jdk / 'bin/javac.exe', '-encoding', 'UTF-8', '-source', '8', '-target', '8', '-cp', jar, '-d', classes]
    execute([*java_args, frozen_java, work / 'CompatCharTest.java', work / 'CompatL2CharConsumer.java'], work, logs / 'javac.log')
    library = work / 'host/Release'
    def invocation(classpath, mode, focus='all'):
        """每条轨迹由新JVM初始化真实Class；focus只选择反控断言，不改变消费者执行。"""
        return [jdk / 'bin/java.exe', '-XX:-UsePerfData', '-Dos.name=Linux', '-Djava.library.path=' + str(library),
                '-Dorg.lwjgl.librarypath=' + str(library), '-cp', classpath, 'org.lwjgl.glfw.CompatCharTest',
                library / 'compat_owner.dll', library / 'foreign_owner.dll', str(mode), focus]
    classpath = os.pathsep.join([str(classes), str(jar)])
    facts = [{'name': 'production-three-consumers', 'exit': execute(invocation(classpath, 0), work, logs / 'production.log')}]
    for mode in [1, 2, 3]:
        facts.append({'name': 'actual-resolver-negative-' + str(mode), 'exit': execute(invocation(classpath, mode), work, logs / ('resolver-' + str(mode) + '.log'))})
    # 撤回只恢复public Java双入队；native/Core/SDK和完整消费类保持相同，必须编译成功。
    old_java = work / 'duplicate-java'; old_java.mkdir()
    text = frozen_java.read_text(encoding='utf-8')
    needle = '        nativeSendCharMods(keychar, modifiers);'
    if text.count(needle) != 1:
        raise ValueError('Unique logical character producer mutation no longer matches')
    duplicate = old_java / 'CallbackBridge.java'
    duplicate.write_text(text.replace(needle, needle + '\n        nativeSendChar(keychar);', 1), encoding='utf-8')
    old_classes = work / 'duplicate-classes'; old_classes.mkdir()
    execute([jdk / 'bin/javac.exe', '-encoding', 'UTF-8', '-source', '8', '-target', '8', '-d', old_classes, duplicate], work, logs / 'duplicate-compile.log')
    negative_cp = os.pathsep.join([str(old_classes), str(classes), str(jar)])
    for focus in ['glfw', 'l2', 'sdl']:
        facts.append({'name': 'compiled-duplicate-rejected-' + focus, 'exit': execute(invocation(negative_cp, 0, focus), work, logs / ('duplicate-' + focus + '.log'), True)})
    # 旧bool不是游戏交付ACK：已排队却返回false的外置候选不能触发Java补发plain。
    # 只变异这一正式JNI函数的返回语句；ring、owner、SDK及三个实际出口继续相同。
    frozen_bridge = (work / 'bridge.cpp').read_text(encoding='utf-8')
    # bridge前置有RegisterNatives用的同名声明，必须定位真实定义，不能把prototype后
    # 第一个任意函数当作目标。使用shipping签名和完整brace扫描保持正文原样。
    definition = re.search(r'^JNIEXPORT jboolean JNICALL\s*\nJava_org_lwjgl_glfw_CallbackBridge_nativeSendCharMods\([^;{}]*\)\s*\{', frozen_bridge, re.M)
    if definition is None:
        raise ValueError('Actual JNI character producer definition missing')
    original_function = recipe.block(frozen_bridge, definition.start())
    if original_function.count('return 1;') != 1:
        raise ValueError('Unique JNI char boolean mutation no longer matches')
    uncertain = frozen_bridge.replace(original_function, original_function.replace('return 1;', 'return 0;', 1), 1)
    (work / 'bridge.cpp').write_text(uncertain, encoding='utf-8')
    execute([tool, '--build', work / 'host', '--config', 'Release', '--target', 'compat_owner'], work, logs / 'queued-false-compile.log')
    facts.append({'name': 'queued-false-does-not-retry-plain', 'exit': execute(invocation(classpath, 0), work, logs / 'queued-false.log')})
    (work / 'bridge.cpp').write_text(frozen_bridge, encoding='utf-8')
    execute([tool, '--build', work / 'host', '--config', 'Release', '--target', 'compat_owner'], work, logs / 'production-restored-compile.log')
    execute(invocation(classpath, 0), work, logs / 'production-restored.log')
    receipt = {'schema': 1, 'recordedAt': datetime.now().astimezone().isoformat(), 'acquiredAt': acquired, 'results': facts,
               'sources': identities,
               'worktreeHead': subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD']).decode().strip(),
               'compiledUnits': ['glfw/input_bridge_ohos.c', 'jvm/jni_registry.cpp', 'input/input_state_core.cpp',
                   'input/amcl_input_host_descriptor.cpp', 'input/input_interaction_order.cpp',
                   'input/delivery/control_delivery.cpp', 'input/delivery/look_execution.cpp',
                   # Core 的真实 L2 held reader 依赖生产 mapper；补完整强链接，不以 weak/noop 或假映射替代。
                   'input/adapters/backend_keymaps.cpp',
                   'input/source/source_control.cpp',
                   'platform/input_ledger.cpp',
                   'platform/external_held_registry.cpp',
                   'platform/external_held_edge_router.cpp',
                   'platform/legacy_output_runtime.cpp',
                   'platform/legacy_physical_edge_router.cpp',
                   'platform/look_delta_math.cpp', 'platform/look_pipeline_stats.cpp',
                   'input/adapters/lwjgl2_event_translate.cpp', 'platform/physical_wheel_quantizer.cpp',
                   'tests/host/backend_input_bridge_host_stub.cpp', 'glfw/jni_reregister.c'],
               'derivedAdapterSha256': {name: digest(work / name) for name in ['owner.cpp', 'foreign.cpp', 'bridge.cpp', 'l2.c', 'CMakeLists.txt']},
               'sdlSource': str(source), 'sdlCharCaseSha256': hashlib.sha256(char_body.encode()).hexdigest(),
               'sdkLibrary': {'path': str(sdk / 'Release/SDL3-static.lib'), 'sha256': digest(sdk / 'Release/SDL3-static.lib')},
               'jdk': {'path': str(jdk), 'javaSha256': digest(jdk / 'bin/java.exe')},
               'scope': 'actual public Java/JNI and three BMP/UTF16-unit consumer exits; no surrogate composition, actual game or OHOS device claim'}
    (logs / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('PASS public compatibility character JNI/three actual consumer exits and compiled producer negatives', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jdk', help='真实Windows JDK；缺省专用L2 JDK环境')
    parser.add_argument('--inputs', help='含锁定L2源码ZIP的仓外目录')
    parser.add_argument('--sdl-root', type=Path, help='显式完整已应用series的SDL源树')
    parser.add_argument('--sdl-source-repo', type=Path, default=os.environ.get('AMCL_SDL_TEST_REPO'), help='含deps.lock pin的只读Git源')
    parser.add_argument('--sdl-sdk-root', type=Path, help='可选实际完整已编SDK build/sdk目录；不提供时正常重建完整SDK')
    parser.add_argument('--out', type=Path)
    parser.add_argument('--build-out', type=Path)
    parser.add_argument('--cmake')
    build(parser.parse_args())
