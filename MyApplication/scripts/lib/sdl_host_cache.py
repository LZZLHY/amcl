"""SDL 组合门的输入、成功证据和外置输出生命周期；不替代任何业务正负例。

缓存只引用本入口实际成功执行过的整组合。首次运行从编译器依赖文件取得系统头
闭包，后续只复核这个闭包及原产物，不扫描整个宿主 SDK。失败和历史输出均保留。
"""
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import time
import uuid

from .host_cpp import find_host_cmake
from .workspace_paths import external_output_path, workspace_path, shared_workspace_path

SCHEMA = 'sdl-host-combination-cache/v1'
STAGES = ('test-sdl-control-header-checkout.py', 'test-sdl-control-delivery.py',
          'test-sdl-owned-text-consumption.py')
SDK_NEGATIVES = ('sdk-marker-wrong-version', 'sdk-init-skips-owner',
    'sdk-dynapi-borrows-host-copy', 'sdk-late-init-follows-copy', 'call-as-queue',
    'poll-without-real-read', 'skip-sdk-reentry-guard', 'reset-clears-sibling',
    'lost-target-keeps-cache', 'bypass-neutral-key', 'typed-crosses-legacy-order',
    'source-pull-reentry', 'sdk-skips-reentry-guard')
OWNED_CASES = (('production', None), ('read-withdrawn', 'text-read-withdrawn'),
    ('release-withdrawn', 'text-release-withdrawn'), ('scalar-withdrawn', 'text-scalar-withdrawn'),
    ('restored', None))
CLEARED_BUILD_ENV = ('CL', '_CL_', 'LINK', '_LINK_', 'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS')


def controlled_environment(values=None):
    """固定配方不接受隐式编译/链接参数注入，尤其 @rsp 和 /FI 的新文件依赖。

    只给子进程新建环境；不改调用者、用户全局配置或原三门独立入口。直接忽略这些
    未声明的参数入口，避免仅 hash 变量字符串却遗漏响应文件内容的假命中。
    """
    return {name: value for name, value in (os.environ if values is None else values).items()
        if name not in CLEARED_BUILD_ENV}


def now():
    """收据使用系统实取的带时区完整时间，不估算历史执行时间。"""
    return datetime.now().astimezone().isoformat()


def file_identity(path):
    """逐块读取 raw 字节，记录大小和 SHA；不把时间戳当成内容身份。"""
    path = Path(path)
    with path.open('rb') as stream:
        return stream_identity(stream)


def stream_identity(stream):
    """文件与压缩包成员使用同一 raw SHA/长度核验；归档成功不等于内容已经保全。"""
    digest = hashlib.sha256()
    size = 0
    for block in iter(lambda: stream.read(1024 * 1024), b''):
        size += len(block)
        digest.update(block)
    return {'bytes': size, 'sha256': digest.hexdigest()}


def content_key(value):
    """规范 JSON 仅用于寻址；缓存资格仍须逐项回读真实文件和成功收据。"""
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
        separators=(',', ':')).encode('utf-8')).hexdigest()


def write_json(path, value):
    """同目录原子发布新收据/索引，避免并发读取半份 JSON。"""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.new')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    os.replace(temporary, path)


def routed_path(root, kind, task, *, shared=False):
    """沿用公开克隆的仓外退路；维护工作区新增文件遵循当前 storage-routing。

    不改全局临时目录，不搬历史文件。显式 AMCL_WORKSPACE_ROOT/AMCL_RUN_DIR 仍由
    既有 helper 解释；只有返回路径确在 canonicalStorageRoot 中时才应用物理路由。
    """
    result = shared_workspace_path(kind, task) if shared else workspace_path(kind, task)
    for parent in Path(root).parents:
        routing = parent / '.workspace/storage-routing.json'
        if not routing.is_file():
            continue
        value = json.loads(routing.read_text(encoding='utf-8'))
        canonical = Path(value['canonicalStorageRoot']).resolve()
        if value.get('status', '').startswith('ACTIVE') and result.is_relative_to(canonical):
            result = Path(value['newStorageRoot']).resolve() / result.relative_to(canonical)
        break
    return external_output_path(result)


@contextmanager
def exclusive_lock(path, timeout=600):
    """每个输入键持有操作系统文件锁；崩溃自动释放，不擅自删除别人的陈旧锁。

    锁文件固定保留，避免 unlink/recreate 形成两个不同 inode 的伪独占。超时明确
    失败；并发等待方取得锁后重新核输入，并优先复用先完成的一方。
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a+b') as stream:
        stream.seek(0, os.SEEK_END)
        if stream.tell() == 0:
            stream.write(b'0')
            stream.flush()
        deadline = time.monotonic() + timeout
        announced = False
        while True:
            try:
                if os.name == 'nt':
                    import msvcrt
                    stream.seek(0)
                    msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except (OSError, BlockingIOError):
                if time.monotonic() >= deadline:
                    raise TimeoutError('SDL cache is busy: ' + str(path))
                if not announced:
                    print('[SDL host combination] waiting for exclusive input lock: ' + str(path), flush=True)
                    announced = True
                time.sleep(.2)
        try:
            yield
        finally:
            if os.name == 'nt':
                stream.seek(0)
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(stream, fcntl.LOCK_UN)


def semantic_environment(values=None):
    """构建选择按值摘要绑定；只排除明确的任务身份/输出字段，不通配忽略AMCL配置。"""
    values = os.environ if values is None else values
    # SDL/AMCL 的运行选择也会影响行为；只存值的 SHA，避免把令牌或密码写入收据。
    # 输出路由和 Fresh 本身不改变被测行为，不应令相同源码在每个任务都失效。
    names = ('PATH', 'INCLUDE', 'LIB', 'LIBPATH', 'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS',
        'CMAKE_PREFIX_PATH', 'CMAKE_GENERATOR_INSTANCE', 'VCToolsInstallDir', 'WindowsSdkDir',
        'WindowsSDKVersion', 'SDKROOT', 'MACOSX_DEPLOYMENT_TARGET')
    excluded = {'AMCL_RUN_DIR', 'AMCL_WORKSPACE_ROOT', 'AMCL_GATE_FRESH', 'AMCL_SDL_TEST_REPO',
                'AMCL_TASK_ID', 'AMCL_TASK_ROOT', 'AMCL_BUILD_DIR'}
    relevant = (set(names) - set(CLEARED_BUILD_ENV)) | {name for name in values
        if name.startswith(('SDL_', 'AMCL_')) and name not in excluded}
    return {name: hashlib.sha256(values[name].encode('utf-8')).hexdigest()
        if name in values else None for name in sorted(relevant)}


def input_identity(root, pin, cmake=None):
    """封住实际消费的窄源码闭包、配方、patch 顺序及宿主工具选择。

    input/platform/glfw/stubs 正是两个 CMake 配方借用的本地目录。递归补 literal
    include，新增本地依赖不会靠旧固定清单漏掉；SDL 上游由 Git commit 与完整 series
    raw 字节绑定。系统头/库另从首次真实编译的依赖记录封存，不能只比版本字符串。
    """
    root = Path(root).resolve()
    scripts = ('test-sdl-host-consumer.py', *STAGES, 'test-sdl-source-delivery.py',
        'test-sdl-look-prefix.py', 'test-sdl-cold-protocol.py', 'generate-desktop-review-tests.py',
        'lib/sdl_host_cache.py', 'lib/host_cpp.py', 'lib/workspace_paths.py')
    files = {root / name for name in ('.gitattributes', 'deps.lock')}
    files.update(root / 'scripts' / name for name in scripts)
    fixtures = ('sdl_control_production.c.in', 'sdl_look_production.c.in',
        'sdl_owned_text_production.c.in', 'sdl_source_support.cpp.in')
    files.update(root / 'scripts/fixtures/input-consumer' / name for name in fixtures)
    patches = root / 'prebuilt/sdl3/patches'
    files.add(patches / 'series')
    for line in (patches / 'series').read_text(encoding='utf-8').splitlines():
        if line.strip() and not line.startswith('#'):
            patch = (patches / line.strip()).resolve()
            if not patch.is_relative_to(patches.resolve()):
                raise ValueError('SDL series path escapes patches')
            files.add(patch)
    cpp = root / 'entry/src/main/cpp'
    for directory in (cpp / 'input', cpp / 'platform', cpp / 'glfw', cpp / 'tests/host/stubs'):
        files.update(path for path in directory.rglob('*') if path.is_file())
    includes = (cpp, cpp / 'input', cpp / 'input/delivery', cpp / 'tests/host/stubs')
    pending = list(files)
    while pending:
        path = pending.pop()
        if path.is_symlink() or not path.resolve().is_relative_to(root):
            raise ValueError('SDL input is not an owned regular project file: ' + str(path))
        if path.suffix not in ('.h', '.hpp', '.c', '.cpp', '.in'):
            continue
        for name in re.findall(r'^\s*#\s*include\s*[<"]([^>"\r\n]+)[>"]', path.read_text(encoding='utf-8', errors='replace'), re.M):
            candidate = next((item.resolve() for base in (path.parent, *includes)
                if (item := base / name).is_file() and item.resolve().is_relative_to(root)), None)
            if candidate is not None and candidate not in files:
                files.add(candidate)
                pending.append(candidate)
    tools = {}
    for name, value in (('python', sys.executable), ('cmake', find_host_cmake(cmake)),
                        ('git', shutil.which('git'))):
        if not value:
            raise FileNotFoundError('SDL host tool missing: ' + name)
        path = Path(value).resolve()
        tools[name] = {'path': str(path), **file_identity(path)}
    if os.name == 'nt':
        vswhere = Path(os.environ.get('ProgramFiles(x86)', 'C:/Program Files (x86)')) / 'Microsoft Visual Studio/Installer/vswhere.exe'
        if vswhere.is_file():
            found = json.loads(subprocess.check_output([str(vswhere), '-latest', '-products', '*',
                '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-format', 'json'], text=True))
            tools['visualStudio'] = [{key: row.get(key) for key in ('installationPath', 'installationVersion')}
                for row in found]
            installs = [Path(row['installationPath']) for row in found]
        else:
            installs = [Path('D:/Microsoft Visual Studio/18/Community'),
                Path('C:/Program Files/Microsoft Visual Studio/2022/Community')]
        for install in installs:
            version = install / 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt'
            if version.is_file():
                tools[str(version)] = file_identity(version)
    else:
        for name in ('cc', 'c++', 'make', 'ninja'):
            value = shutil.which(name)
            if value:
                path = Path(value).resolve()
                tools[name] = {'path': str(path), **file_identity(path)}
    environment = semantic_environment()
    return {'schema': SCHEMA, 'root': str(root), 'pin': pin, 'platform': sys.platform,
        'machine': platform.machine(), 'hostVersion': platform.version(), 'pythonVersion': sys.version, 'tools': tools,
        'clearedChildEnvironment': list(CLEARED_BUILD_ENV),
        'environment': environment,
        'files': {path.relative_to(root).as_posix(): file_identity(path) for path in sorted(files)}}


def external_dependencies(root, build):
    """从本轮真实编译 read-tlog/depfile 取得仓外头与库，并补实际工具二进制。

    不扫描系统 SDK；没有取得任何外部头时拒绝授予可复用资格。依赖文件自身可以随
    成功大树回收，首次取得的规范绝对路径与 raw SHA 长期保留在成功 manifest。
    """
    root, build = Path(root).resolve(), Path(build).resolve()
    paths = set()
    records = 0
    link_records = 0
    for log in build.rglob('*.tlog'):
        if '.read.' not in log.name.lower():
            continue
        text = log.read_bytes().decode('utf-16', errors='replace')
        for line in text.splitlines():
            for name in line.lstrip('^').split('|'):
                path = Path(name.strip())
                if path.is_absolute() and path.is_file():
                    paths.add(path.resolve())
                    records += 1
                    if 'link.read.' in log.name.lower():
                        link_records += 1
    for depfile in build.rglob('*.o.d'):
        text = depfile.read_text(encoding='utf-8', errors='replace').replace('\\\n', ' ')
        for name in shlex.split(text.partition(':')[2]):
            path = Path(name)
            path = path if path.is_absolute() else depfile.parent / path
            if path.is_file():
                paths.add(path.resolve())
                records += 1
    # CMake 记录的实际 cl/cc、link、rc 和 MSBuild/make 也必须绑定，不能只信 PATH。
    compilers = {}
    for cache in build.rglob('CMakeCache.txt'):
        for role, name in re.findall(r'^CMAKE_(C_COMPILER|CXX_COMPILER|LINKER|RC_COMPILER|MAKE_PROGRAM):[^=]+=([^\r\n]+)',
                cache.read_text(encoding='utf-8', errors='replace'), re.M):
            path = Path(name)
            if path.is_absolute() and path.is_file():
                paths.add(path.resolve())
                if role in ('C_COMPILER', 'CXX_COMPILER'):
                    compilers[role] = str(path.resolve())
    # Visual Studio 生成器可能不把 compiler 写入 Cache；它实际生成的两份描述才是准据。
    for description in build.rglob('CMake*Compiler.cmake'):
        for role, name in re.findall(r'set\(CMAKE_(C_COMPILER|CXX_COMPILER)\s+"([^"\r\n]+)"\)',
                description.read_text(encoding='utf-8', errors='replace')):
            path = Path(name)
            if path.is_absolute() and path.is_file():
                paths.add(path.resolve())
                compilers[role] = str(path.resolve())
    selected = {path for path in paths if not path.is_relative_to(root) and not path.is_relative_to(build)}
    if not records or not any(path.suffix.lower() in ('.h', '.hpp', '.hxx', '.inc') for path in selected):
        raise ValueError('SDK_EXTERNAL_HEADER_DEPENDENCIES_MISSING: completed execution is not cacheable')
    if set(compilers) != {'C_COMPILER', 'CXX_COMPILER'} or any(Path(name) not in selected for name in compilers.values()):
        raise ValueError('SDK_ACTUAL_COMPILER_DEPENDENCIES_MISSING: completed execution is not cacheable')
    # POSIX depfile 只有编译头闭包，不能据此声称系统链接库/运行库也已冻结。
    # Windows 真实 LINK.read.tlog 可封链接输入，另绑定编译器后端 DLL 与系统 C++ runtime。
    if os.name != 'nt':
        raise ValueError('POSIX_LINK_RUNTIME_CLOSURE_UNAVAILABLE: full execution remains valid but is not cacheable')
    if not link_records or not any(path.suffix.lower() == '.lib' for path in selected):
        raise ValueError('WINDOWS_LINK_INPUT_DEPENDENCIES_MISSING: completed execution is not cacheable')
    for name in compilers.values():
        directory = Path(name).parent
        selected.update(path.resolve() for pattern in ('*.dll', '*.exe')
            for path in directory.glob(pattern) if path.is_file())
    import ctypes
    buffer = ctypes.create_unicode_buffer(32768)
    if not ctypes.windll.kernel32.GetSystemDirectoryW(buffer, len(buffer)):
        raise ValueError('WINDOWS_RUNTIME_DIRECTORY_MISSING')
    system = Path(buffer.value)
    for name in ('ucrtbase.dll', 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll',
                 'concrt140.dll', 'ntdll.dll', 'kernel32.dll', 'kernelbase.dll', 'user32.dll'):
        path = system / name
        if path.is_file():
            selected.add(path.resolve())
    return {'files': {str(path): file_identity(path) for path in sorted(selected)}, 'compilers': compilers}


def validate_execution(out, build):
    """核实原门真实完成全部正负恢复；缺编译、缺断言或源漂移都不授予缓存资格。"""
    out, build = Path(out), Path(build)
    header = json.loads((out / 'headers/receipt.json').read_text(encoding='utf-8'))
    paths = tuple('entry/src/main/cpp/input/delivery/' + name for name in ('control_delivery.h', 'control_delivery_client.h'))
    expected_facts = [(case, path, accepted) for case, accepted in (('positive', True), ('removed-rules', False))
        for path in paths] + [('content-drift', paths[0], False)] + [('restored', path, True) for path in paths]
    facts = header.get('facts', [])
    header_commands = header.get('commands', [])
    if header.get('sourceDrift') != [] or len(header_commands) < 9 or any(
            type(row.get('exitCode')) is not int or row['exitCode'] != 0 or not row.get('command') for row in header_commands):
        raise ValueError('HEADER_CHECKOUT_PROOF_INCOMPLETE')
    if [(row.get('case'), row.get('path'), row.get('rawAccepted')) for row in facts] != expected_facts or any(
            not row.get('identity', {}).get('sha256') or row['identity'].get('bytes', 0) <= 0 for row in facts):
        raise ValueError('HEADER_CHECKOUT_FACTS_INCOMPLETE')
    if set(header.get('sourceIdentities', {})) != {'.gitattributes', *paths} or len(header.get('rules', [])) != 2:
        raise ValueError('HEADER_CHECKOUT_SOURCE_IDENTITY_INCOMPLETE')
    sdk = build / 'sdk'
    control = json.loads((sdk / 'summary.json').read_text(encoding='utf-8'))
    modes = {row['mode']: row['exit'] for row in control.get('modes', [])}
    if set(modes) != {'production', 'restored-production', *SDK_NEGATIVES} or any(type(code) is not int for code in modes.values()) or any(
            modes[name] != 0 for name in ('production', 'restored-production')) or any(
            modes[name] == 0 for name in SDK_NEGATIVES) or control.get('sdkDynamicApi') != 1:
        raise ValueError('FULL_SDK_BEHAVIOR_MATRIX_INCOMPLETE')
    if not control.get('sdkFinal', {}).get('restoredProduction'):
        raise ValueError('SDK_RESTORED_PRODUCTION_MISSING')
    sdk_commands = control.get('commands', [])
    if not sdk_commands or not control.get('frozenInputs') or not control.get('ownerSources'):
        raise ValueError('SDK_EXECUTION_OR_SOURCE_PROOF_EMPTY')
    command_by_log = {}
    for command in sdk_commands:
        code = command.get('exitCode')
        if type(code) is not int or not command.get('command'):
            raise ValueError('SDK_COMMAND_EXIT_OR_ARGUMENTS_MISSING')
        log = Path(command['log']).resolve()
        if not log.is_relative_to(sdk.resolve()) or not log.is_file():
            raise ValueError('SDK_COMMAND_LOG_MISSING')
        command_by_log[log.name] = command
        if command.get('negativeExpected'):
            if not code or b'CHECK failed' not in log.read_bytes():
                raise ValueError('SDK_NEGATIVE_BEHAVIOR_MISSING')
        elif code != 0:
            raise ValueError('SDK_COMPILE_OR_RESTORED_FAILURE')
    for mode in ('production', *SDK_NEGATIVES, 'restored', 'sdk-protocol-restored'):
        log = sdk / (mode + '-compile.log')
        command = command_by_log.get(log.name, {})
        if not log.is_file() or log.stat().st_size == 0 or command.get('exitCode') != 0 or '--build' not in command.get('command', []):
            raise ValueError('SDK_COMPILE_PROOF_MISSING:' + mode)
    for mode, code in modes.items():
        command = command_by_log.get(mode + '.log', {})
        if command.get('exitCode') != code or command.get('negativeExpected') != (mode in SDK_NEGATIVES):
            raise ValueError('SDK_MODE_COMMAND_PROOF_MISSING:' + mode)
    owned = json.loads((out / 'owned/summary.json').read_text(encoding='utf-8'))
    if [(row['name'], row['negative']) for row in owned.get('cases', [])] != list(OWNED_CASES):
        raise ValueError('OWNED_BEHAVIOR_MATRIX_INCOMPLETE')
    sdk_proof = owned.get('sdkControlProof', {})
    if sdk_proof.get('sha256') != file_identity(sdk / 'summary.json')['sha256']:
        raise ValueError('OWNED_SDK_PROOF_IDENTITY_MISMATCH')
    receipts = []
    for (name, negative), case in zip(OWNED_CASES, owned['cases']):
        directory = out / 'owned' / name
        receipt = json.loads((directory / 'receipt.json').read_text(encoding='utf-8'))
        if receipt.get('negative') != negative or receipt.get('sourceDrift') != [] or type(receipt.get('exitCode')) is not int:
            raise ValueError('OWNED_CASE_IDENTITY_DRIFT:' + name)
        if case.get('receiptSha256') != file_identity(directory / 'receipt.json')['sha256'] or case.get('exitCode') != receipt['exitCode']:
            raise ValueError('OWNED_CASE_RECEIPT_IDENTITY_MISMATCH:' + name)
        if not receipt.get('sourcesBefore') or not receipt.get('generatedSha256') or receipt['sourcesBefore'] != receipt.get('sourcesAfter'):
            raise ValueError('OWNED_CASE_SOURCE_IDENTITY_INCOMPLETE:' + name)
        if not (directory / 'compile.log').is_file() or (directory / 'compile.log').stat().st_size == 0:
            raise ValueError('OWNED_COMPILE_PROOF_MISSING:' + name)
        if negative:
            if not receipt.get('exitCode') or b'CHECK failed' not in (directory / 'behavior.log').read_bytes():
                raise ValueError('OWNED_NEGATIVE_BEHAVIOR_MISSING:' + name)
        elif receipt.get('exitCode') != 0:
            raise ValueError('OWNED_PRODUCTION_FAILURE:' + name)
        receipts.append(receipt)
    return header, control, receipts


def retain_success(root, out, build, inputs):
    """保留完整日志、最终库/各例二进制，并压缩归档收据引用的所有源码身份。

    原收据保留原路径，不改历史正文；sources 清单把原路径映射到压缩包 member，
    回收大树后仍能按原 SHA 核对源码。只复制当前新生成结果，不改任何旧输出。
    """
    root, out, build = Path(root).resolve(), Path(out).resolve(), Path(build).resolve()
    header, control, receipts = validate_execution(out, build)
    retained = out / 'retained'
    retained.mkdir()
    sdk = build / 'sdk'
    evidence = out / 'sdk-evidence'
    evidence.mkdir()
    for path in (sdk / 'summary.json', *sdk.glob('*.log')):
        shutil.copyfile(path, evidence / path.name)
    for command in control['commands']:
        log = Path(command['log']).resolve()
        if not log.is_relative_to(sdk):
            raise ValueError('SDK_LOG_OUTSIDE_CURRENT_OUTPUT:' + str(log))
        destination = evidence / log.relative_to(sdk)
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.is_file():
            shutil.copyfile(log, destination)
        if file_identity(destination) != file_identity(log):
            raise ValueError('SDK_RETAINED_LOG_DRIFT:' + str(log))
    originals = {root / name: row['sha256'] for name, row in inputs['files'].items()}
    binaries = set()
    final = control['sdkFinal']
    for row in (final['staticLibrary'], final['generatedConsumer'],
                *final['consumptionSources'].values(), *final['cmakeExports'].values()):
        originals[sdk / row['path']] = row['sha256']
    binaries.add(sdk / final['staticLibrary']['path'])
    binaries.update((sdk / ('build/Release/sdl_control.exe' if os.name == 'nt' else 'build/sdl_control'),
        sdk / ('build/sdk/Release/SDL3.dll' if os.name == 'nt' else 'build/sdk/libSDL3.so'),
        sdk / ('build/Release/amcl_owner_shared.dll' if os.name == 'nt' else 'build/libamcl_owner_shared.so')))
    # MSVC 符号与真实 dynapi 多映像副本同样是解释失败证据所需材料，不随大树丢弃。
    binaries.update(path for path in build.rglob('*.pdb') if path.is_file())
    binaries.update(path for path in sdk.rglob('SDK-copy-*') if path.is_file())
    for name, digest in control.get('ownerSources', {}).items():
        originals[sdk / 'owner' / name] = digest
    for name in ('cold_observer.c', 'CMakeLists.txt'):
        originals[sdk / name] = file_identity(sdk / name)['sha256']
    for receipt in receipts:
        if receipt.get('sourcesBefore') != receipt.get('sourcesAfter'):
            raise ValueError('OWNED_SOURCE_CLOSURE_DRIFT')
        for name, digest in {**receipt['sourcesBefore'], **receipt['generatedSha256']}.items():
            path = Path(name).resolve()
            if path in originals and originals[path] != digest:
                raise ValueError('RETAINED_SOURCE_IDENTITY_CONFLICT:' + name)
            originals[path] = digest
        binaries.update(Path(name).resolve() for name in receipt['generatedSha256']
            if Path(name).name in ('consumer', 'consumer.exe'))
    source_index = {}
    with tarfile.open(retained / 'sources.tar.gz', 'w:gz') as archive:
        for index, (path, expected) in enumerate(sorted(originals.items())):
            actual = file_identity(path)
            if actual['sha256'] != expected:
                raise ValueError('RETAINED_SOURCE_DRIFT:' + str(path))
            if path in binaries:
                continue
            member = 'files/' + str(index) + '/' + path.name
            archive.add(path, arcname=member, recursive=False)
            source_index[str(path)] = {'member': member, **actual}
    binary_index = {}
    for index, path in enumerate(sorted(binaries)):
        original = file_identity(path)
        destination = retained / ('binary-' + str(index) + '-' + path.name)
        shutil.copyfile(path, destination)
        if file_identity(destination) != original or file_identity(path) != original:
            raise ValueError('RETAINED_BINARY_COPY_DRIFT:' + str(path))
        binary_index[str(path)] = {'retainedPath': destination.relative_to(out).as_posix(), **original}
    # 清理前逐 member 解压回读；必须保全 sources.json 引用的每一份原正文及其长度。
    expected = {row['member']: {'bytes': row['bytes'], 'sha256': row['sha256']}
        for row in source_index.values()}
    with tarfile.open(retained / 'sources.tar.gz', 'r:gz') as archive:
        members = archive.getmembers()
        if len(members) != len(expected) or {item.name for item in members} != set(expected):
            raise ValueError('RETAINED_ARCHIVE_MEMBER_SET_MISMATCH')
        for member in members:
            if not member.isfile():
                raise ValueError('RETAINED_ARCHIVE_NON_FILE:' + member.name)
            with archive.extractfile(member) as stream:
                if stream_identity(stream) != expected[member.name]:
                    raise ValueError('RETAINED_ARCHIVE_MEMBER_DRIFT:' + member.name)
    write_json(retained / 'sources.json', source_index)
    write_json(retained / 'binaries.json', binary_index)


def cleanup_owned_build(build, owner):
    """只回收本轮创建且 owner/绝对路径匹配的树；拒绝根 junction，不跟目录链接。

    shutil.rmtree 不递归跟随 symlink/junction；先额外拒绝树内 junction，避免不同
    Python/Windows 行为差异。任何不确定情况保留现场并由调用者报告，绝不扩大清理范围。
    """
    build = Path(build)
    marker = build / '.sdl-combination-owner.json'
    if build.is_symlink() or (hasattr(build, 'is_junction') and build.is_junction()):
        raise ValueError('BUILD_ROOT_LINK_REFUSED')
    absolute = external_output_path(build)
    value = json.loads(marker.read_text(encoding='utf-8'))
    if value != {'owner': owner, 'path': str(absolute)} or absolute != build.absolute():
        raise ValueError('BUILD_OWNER_IDENTITY_MISMATCH')
    for directory, children, _ in os.walk(absolute, followlinks=False):
        for name in children:
            path = Path(directory) / name
            if hasattr(path, 'is_junction') and path.is_junction():
                raise ValueError('BUILD_JUNCTION_REFUSED:' + str(path))
    def retry_readonly(function, name, error):
        """Git checkout 的 object 可能只读；只给本轮普通文件恢复写位再重试删除。

        不修改目录权限/ACL，不处理链接，不把其他访问拒绝误当只读。路径、owner 和
        junction 检查仍是前置条件；重试再次失败时原异常继续上抛并保留剩余现场。
        """
        path = Path(name)
        resolved = path.resolve()
        if not isinstance(error, PermissionError) or function is not os.unlink or not resolved.is_relative_to(absolute):
            raise error
        if path.is_symlink() or (hasattr(path, 'is_junction') and path.is_junction()) or not path.is_file():
            raise error
        mode = path.stat().st_mode
        if mode & stat.S_IWRITE:
            raise error
        path.chmod(mode | stat.S_IWRITE)
        function(name)
    shutil.rmtree(absolute, onexc=retry_readonly)


def publish_manifest(out, inputs, dependencies):
    """只给不可变的成功证据建内容清单；大树回收后不再引用其存活性。"""
    out = Path(out).resolve()
    files = {path.relative_to(out).as_posix(): file_identity(path) for path in sorted(out.rglob('*'))
        if path.is_file() and path.name != 'cache-manifest.json'}
    manifest = {'schema': SCHEMA, 'key': content_key(inputs), 'createdAt': now(),
        'evidenceRoot': str(out), 'inputs': inputs, 'externalDependencies': dependencies, 'files': files}
    write_json(out / 'cache-manifest.json', manifest)
    return manifest


def validate_cached(pointer, inputs):
    """命中须回读原 PASS、全体保留产物/日志及实际系统头；损坏返回明确失效原因。"""
    manifest_path = Path(pointer['manifest'])
    if file_identity(manifest_path) != pointer.get('identity'):
        raise ValueError('CACHE_MANIFEST_IDENTITY_MISMATCH')
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    if manifest.get('schema') != SCHEMA or manifest.get('inputs') != inputs or manifest.get('key') != content_key(inputs):
        raise ValueError('CACHE_INPUT_IDENTITY_MISMATCH')
    out = external_output_path(manifest['evidenceRoot'])
    if manifest_path.resolve() != out / 'cache-manifest.json':
        raise ValueError('CACHE_EVIDENCE_ROOT_MISMATCH')
    dependencies = manifest.get('externalDependencies', {})
    dependency_files = dependencies.get('files', {})
    if not dependency_files or not any(Path(name).suffix.lower() in ('.h', '.hpp', '.hxx', '.inc') for name in dependency_files):
        raise ValueError('CACHE_EXTERNAL_HEADERS_MISSING')
    compilers = dependencies.get('compilers', {})
    if set(compilers) != {'C_COMPILER', 'CXX_COMPILER'} or any(name not in dependency_files for name in compilers.values()):
        raise ValueError('CACHE_ACTUAL_COMPILERS_MISSING')
    for name, expected in dependency_files.items():
        if file_identity(name) != expected:
            raise ValueError('CACHE_HOST_DEPENDENCY_DRIFT:' + name)
    files = manifest.get('files', {})
    for required in ('receipt.json', 'sdk-evidence/summary.json', 'retained/sources.tar.gz',
                     'retained/sources.json', 'retained/binaries.json', 'owned/summary.json', 'headers/receipt.json'):
        if required not in files:
            raise ValueError('CACHE_EVIDENCE_INCOMPLETE:' + required)
    for name, expected in files.items():
        path = (out / name).resolve()
        if not path.is_relative_to(out) or file_identity(path) != expected:
            raise ValueError('CACHE_ARTIFACT_DRIFT:' + name)
    receipt = json.loads((out / 'receipt.json').read_text(encoding='utf-8'))
    if receipt.get('state') != 'PASS' or receipt.get('inputKey') != manifest['key'] or len(receipt.get('commands', [])) != len(STAGES):
        raise ValueError('CACHE_SUCCESS_RECEIPT_INCOMPLETE')
    for item, stage in zip(receipt['commands'], STAGES):
        if item.get('exitCode') != 0 or Path(item['command'][2]).name != stage:
            raise ValueError('CACHE_STAGE_EXECUTION_INCOMPLETE')
    binaries = json.loads((out / 'retained/binaries.json').read_text(encoding='utf-8'))
    sources = json.loads((out / 'retained/sources.json').read_text(encoding='utf-8'))
    if len(binaries) < 9 or not sources:
        raise ValueError('CACHE_RETAINED_IDENTITY_SET_INCOMPLETE')
    for row in binaries.values():
        identity = {'bytes': row['bytes'], 'sha256': row['sha256']}
        if files.get(row['retainedPath']) != identity:
            raise ValueError('CACHE_RETAINED_BINARY_IDENTITY_MISMATCH')
    return manifest
