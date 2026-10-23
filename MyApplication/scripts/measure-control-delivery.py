"""同条件比较旧/新GLFW归约及当前端口热点，保留原始样本、单位和完整编译输入身份。

--baseline-ref必须是真实Git对象；旧源只解出两个明确文件至仓外构建树，不checkout、
不改当前源码。新版链接真实neutral/Core；窗口sink是显式替身，不能把结果提升为真实
GLFW/JNI/SDL/游戏或OHOS性能。此工具不设性能通过阈值、不自动写入产品配置/门禁。
"""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import platform
import re
import shlex
import subprocess
from lib.host_cpp import find_host_cmake, configure_host_cmake
from lib.workspace_paths import external_output_path

ROOT = Path(__file__).resolve().parents[1]
CPP = ROOT / 'entry/src/main/cpp'


def identity(path):
    """绑定完整物理字节，源码检出换行和真实编译工具差异不能被版本名掩盖。"""
    path = Path(path)
    data = path.read_bytes()
    return {'path': str(path), 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}


def percentile(values, fraction):
    """采用nearest-rank，整数样本不减时钟开销；返回一个press/release pair的总ns。"""
    import math
    return sorted(values)[max(0, math.ceil(len(values)*fraction)-1)]


def local_include_preimage(seeds, includes):
    """编译前冻结本地include可达字节；只是候选闭包，不能冒称编译器实际读取集合。

    引号include先相对原文件查找，随后按真实target include顺序解析；条件编译中的
    未使用头也可提前保留。编译后的实际read集合必须全部落在这一原preimage内。
    系统头在这里不猜测位置，其真实读集合由MSVC tlog或GCC依赖文件给出。
    """
    pending = list(seeds)
    found = {}
    while pending:
        source = Path(pending.pop()).resolve()
        key = os.path.normcase(str(source))
        if key in found:
            continue
        found[key] = source
        body = source.read_text(encoding='utf-8-sig', errors='replace')
        for match in re.finditer(r'^\s*#\s*include\s*([<"])([^>"]+)[>"]', body, re.MULTILINE):
            name = match.group(2)
            search = ([source.parent] if match.group(1) == '"' else []) + list(includes)
            resolved = next((folder/name for folder in search if (folder/name).is_file()), None)
            if resolved is not None:
                pending.append(resolved)
    return [found[key] for key in sorted(found)]


def compiler_read_inputs(tree):
    """读取本次真正编译器签发的文件集合，不从路径清单或源扫描推定全读覆盖。

    Windows使用实际bench目标的MSVC CL.read tlog（含真实TU/本地及SDK头）；
    GCC/Clang读取目标.o.d依赖文件。没有读集合就失败，不降级成计划名单。
    """
    values = {}
    if os.name == 'nt':
        files = list(tree.glob('bench.dir/Release/bench.tlog/CL.read.1.tlog'))
        if len(files) != 1:
            raise RuntimeError('本次MSVC bench读取收据不唯一')
        for line in files[0].read_text(encoding='utf-16').splitlines():
            for value in (line[1:].split('|') if line.startswith('^') else [line]):
                path = Path(value.strip())
                if path.is_file():
                    resolved = path.resolve(); values[os.path.normcase(str(resolved))] = resolved
    else:
        files = list(tree.glob('CMakeFiles/bench.dir/**/*.o.d'))
        if not files:
            raise RuntimeError('本次bench编译器依赖文件缺失')
        for file in files:
            text = file.read_text(encoding='utf-8').replace('\\\n', '')
            if ':' not in text:
                raise RuntimeError('编译器依赖文件格式不成立')
            for value in shlex.split(text.split(':', 1)[1]):
                path = Path(value)
                if not path.is_absolute(): path = tree/path
                if path.is_file():
                    resolved = path.resolve(); values[os.path.normcase(str(resolved))] = resolved
    if not values:
        raise RuntimeError('本次bench实际读取集合为空')
    return [values[key] for key in sorted(values)], files


def main():
    """先冻结源/工具，再编译两版并交替运行；失败保留现有材料，不跳过数据或重试。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-ref', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--build-root', required=True)
    args = parser.parse_args()
    output = external_output_path(args.output)
    build = external_output_path(args.build_root)
    output.mkdir(parents=True, exist_ok=False)
    build.mkdir(parents=True, exist_ok=False)
    started = datetime.datetime.now().astimezone().isoformat()
    receipt = {'startedAt': started, 'state': 'Running', 'scope': 'Host synchronous facade and neutral port hotpaths; simulated window/cache',
               'host': platform.platform(), 'commands': [], 'rounds': []}

    def save():
        """每条实际命令完成后追加进度，失败和部分测量也保留，不能把缺失当通过。"""
        (output/'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2), encoding='utf-8')

    def run(label, command, cwd=ROOT):
        """参数数组直接调用真实进程，外置保存完整stdout/stderr；工具失败终止本轮。"""
        item = {'label': label, 'command': [str(value) for value in command], 'startedAt': datetime.datetime.now().astimezone().isoformat()}
        receipt['commands'].append(item)
        result = subprocess.run(command, cwd=cwd, capture_output=True)
        log = output/(label+'.log')
        log.write_bytes(result.stdout+result.stderr)
        item.update(exitCode=result.returncode, finishedAt=datetime.datetime.now().astimezone().isoformat(), log=identity(log))
        save()
        print(label, 'exit', result.returncode, flush=True)
        if result.returncode:
            print((result.stdout+result.stderr).decode('utf-8', errors='replace'), flush=True)
            raise RuntimeError(label+' failed')
        return result.stdout

    try:
        baseline = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', '--verify', args.baseline_ref+'^{commit}']).decode().strip()
        receipt['baselineCommit'] = baseline
        receipt['candidateCommit'] = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD']).decode().strip()
        # 真实target的全部生产TU先定义一次，编译与收据用同一清单；mapper不能只链接不绑定。
        native_names = ['input/adapters/glfw_source_plane_aggregate.cpp', 'input/delivery/control_delivery.cpp',
                        'input/input_state_core.cpp', 'input/adapters/backend_keymaps.cpp',
                        'input/amcl_input_host_descriptor.cpp', 'input/input_interaction_order.cpp']
        probe = ROOT/'scripts/fixtures/input-consumer/control_delivery_benchmark.cpp'
        receipt['probe'] = identity(probe)
        recipe_paths = [Path(__file__).resolve(), ROOT/'scripts/lib/host_cpp.py', ROOT/'scripts/lib/workspace_paths.py']
        receipt['recipeSources'] = [identity(path) for path in recipe_paths]
        candidate_paths = local_include_preimage([probe, *[CPP/name for name in native_names]],
            [CPP/'input/adapters', CPP/'input', CPP/'tests/host/stubs'])
        receipt['candidateSources'] = [identity(path) for path in candidate_paths]
        cmake = find_host_cmake()
        receipt['cmake'] = identity(cmake)
        old = build/'baseline-source'
        old.mkdir()
        for name in ['glfw_source_plane_aggregate.cpp', 'glfw_source_plane_aggregate.h']:
            data = subprocess.check_output(['git', '-C', str(ROOT), 'show', baseline+':entry/src/main/cpp/input/adapters/'+name])
            (old/name).write_bytes(data)
        receipt['baselineSources'] = [identity(path) for path in sorted(old.iterdir())]
        executables = {}
        measurement_dependencies = {}
        for kind in ['baseline', 'candidate']:
            source = build/(kind+'-project')
            source.mkdir()
            adapter = old if kind == 'baseline' else CPP/'input/adapters'
            native = [adapter/'glfw_source_plane_aggregate.cpp'] if kind == 'baseline' else [CPP/name for name in native_names]
            include_dirs = [adapter, CPP/'input', CPP/'tests/host/stubs']
            preimage_paths = local_include_preimage([probe, *native], include_dirs)
            preimage = {os.path.normcase(str(path)): identity(path) for path in preimage_paths}
            receipt.setdefault('compilePreimages', {})[kind] = list(preimage.values())
            cmake_body = 'cmake_minimum_required(VERSION 3.16)\nproject(control_bench LANGUAGES CXX)\n'
            cmake_body += 'add_executable(bench '+ ' '.join('"'+path.as_posix()+'"' for path in [probe, *native])+')\n'
            cmake_body += 'target_include_directories(bench PRIVATE "'+adapter.as_posix()+'" "'+(CPP/'input').as_posix()+'" "'+(CPP/'tests/host/stubs').as_posix()+'")\n'
            cmake_body += 'target_compile_features(bench PRIVATE cxx_std_17)\n'
            # 单配置宿主也明确Release；POSIX端口解析需要导出实际getter，不使用假owner。
            cmake_body += 'set_target_properties(bench PROPERTIES ENABLE_EXPORTS ON)\n'
            cmake_body += 'if(NOT CMAKE_CONFIGURATION_TYPES AND NOT CMAKE_BUILD_TYPE)\n set(CMAKE_BUILD_TYPE Release CACHE STRING "Host benchmark configuration" FORCE)\nendif()\n'
            if kind == 'candidate':
                cmake_body += 'target_compile_definitions(bench PRIVATE AMCL_BENCH_CURRENT AMCL_CONTROL_DELIVERY_HOST_TESTING AMCL_INPUT_HOST_EXPORTS)\n'
            cmake_body += 'if(MSVC)\n target_compile_options(bench PRIVATE /utf-8)\nendif()\n'
            (source/'CMakeLists.txt').write_text(cmake_body, encoding='utf-8')
            tree = build/(kind+'-build')
            # 既有helper固定真实宿主生成器；日志复制在本次构建树，SDK/全局工具不改变。
            configure_host_cmake(cmake, source, tree)
            run(kind+'-compile', [cmake, '--build', str(tree), '--config', 'Release'])
            # 实际编译器读集合核对编译前本地字节；系统头在编译完成后绑定，测量首尾再核。
            # 这不承诺系统SDK在编译期间不可变，收据明示该较窄边界，不把源码扫描当读证据。
            read_paths, read_receipts = compiler_read_inputs(tree)
            read_keys = {os.path.normcase(str(path)) for path in read_paths}
            if not {os.path.normcase(str(path.resolve())) for path in [probe, *native]}.issubset(read_keys):
                raise RuntimeError('实际编译器读取集合缺少目标TU')
            for path in read_paths:
                key = os.path.normcase(str(path))
                local = path.is_relative_to(ROOT) or path.is_relative_to(build)
                if local and key not in preimage:
                    raise RuntimeError('实际编译读取了未在编译前冻结的本地依赖: '+str(path))
                value = identity(path)
                if key in preimage and value != preimage[key]:
                    raise RuntimeError('实际编译本地依赖与原preimage漂移: '+str(path))
                measurement_dependencies[key] = (path, value)
            receipt.setdefault('compilerReadInputs', {})[kind] = [identity(path) for path in read_paths]
            receipt.setdefault('compilerReadReceipts', {})[kind] = [identity(path) for path in read_receipts]
            # 绑定CMake实际选择的编译器与Release工程，不只凭MSVC版本名字判同工具链。
            compiler_files = list(tree.glob('CMakeFiles/*/CMakeCXXCompiler.cmake'))
            if len(compiler_files) != 1: raise RuntimeError('真实编译器元数据不唯一')
            compiler_text = compiler_files[0].read_text(encoding='utf-8')
            compiler_match = re.search(r'set\(CMAKE_CXX_COMPILER "([^"]+)"\)', compiler_text)
            if not compiler_match: raise RuntimeError('真实编译器路径不可观察')
            receipt.setdefault('toolchains', {})[kind] = {'compiler': identity(compiler_match[1]),
                'compilerMetadata': identity(compiler_files[0]), 'configuration': 'Release',
                'generatedProject': identity(tree/'bench.vcxproj') if os.name == 'nt' else identity(tree/'Makefile')}
            executables[kind] = tree/'Release/bench.exe' if os.name == 'nt' else tree/'bench'
        receipt['executables'] = {kind: identity(file) for kind, file in executables.items()}
        # 单位来自实际探针操作，不能把一次Resolve或完整view错报为press/release pair。
        common_units = {'clock-read-pair': 'clock-read-pair', 'single-key-pair': 'press-release-pair',
            'shared-key-pair-256-held': 'press-release-pair'}
        current_units = {'current-port-resolve': 'port-resolve', 'current-delivered-query': 'scalar-query',
            'current-scalar-observe': 'scalar-observe', 'current-view-observe-256': '512-byte-view-256-controls',
            **{'current-shared-pair-pending-'+str(count): 'press-release-pair' for count in [0, 64, 1024]}}
        for index, kind in enumerate(['baseline', 'candidate', 'candidate', 'baseline']):
            if any(identity(path) != value for path, value in measurement_dependencies.values()):
                raise RuntimeError('测量开始前实际编译依赖身份改变')
            data = run('round-'+str(index)+'-'+kind, [str(executables[kind])]).decode('ascii')
            groups = {}
            for line in data.splitlines():
                parts = line.split()
                if len(parts)<3: raise RuntimeError('样本字段缺失')
                values = [int(value) for value in parts[2:]]
                if len(values)!=int(parts[1]) or len(values)!=10000 or min(values)<0: raise RuntimeError('样本长度或值不正确')
                units = {**common_units, **(current_units if kind == 'candidate' else {})}
                if parts[0] not in units or parts[0] in groups: raise RuntimeError('未知或重复测量场景')
                result = {'count': len(values), 'unit': units[parts[0]], 'p50Ns': percentile(values,.5),
                    'p95Ns': percentile(values,.95), 'p99Ns': percentile(values,.99), 'maxNs': max(values),
                    'zeroSamples': values.count(0), 'minimumPositiveNs': min((v for v in values if v>0), default=None)}
                # 保留原pair字段给历史读取者；新单次热点只输出带unit的通用ns口径。
                if parts[0] in common_units:
                    result.update({name+'PerPair': result[name] for name in ['p50Ns','p95Ns','p99Ns','maxNs']})
                groups[parts[0]] = result
            expected = set(common_units) | (set(current_units) if kind == 'candidate' else set())
            if set(groups) != expected: raise RuntimeError('测量场景缺失')
            receipt['rounds'].append({'round': index, 'kind': kind, 'measurements': groups})
        if receipt['toolchains']['baseline']['compiler'] != receipt['toolchains']['candidate']['compiler']:
            raise RuntimeError('两版实际编译器不同，不是同工具条件')
        if receipt['candidateSources'] != [identity(path) for path in candidate_paths]: raise RuntimeError('测量期间源身份改变')
        if receipt['recipeSources'] != [identity(path) for path in recipe_paths]: raise RuntimeError('测量期间编译辅助配方身份改变')
        if any(identity(path) != value for path, value in measurement_dependencies.values()):
            raise RuntimeError('测量结束后实际编译依赖身份改变')
        receipt['dependencyVerification'] = 'Actual compiler read set; local preimage verified before/after compile, all read inputs stable across measurement'
        receipt['state'] = 'Measured'
        receipt['limitations'] = ['同机有其它负载，不是隔离CPU实验', '只测同步facade与neutral归约/receipt，非完整producer队列或游戏ABI',
                                  '窗口与用户callback为明确替身，无OHOS/呈现/physical mouse证明', '仅旧45b同范围归约基线，不对应整份新产品的总体改善',
                                  '系统/标准库头在编译完成时按真实读取集合绑定，测量首尾稳定；未承诺系统SDK编译期间原子快照']
        print(json.dumps(receipt['rounds'], ensure_ascii=False, indent=2), flush=True)
    except Exception as error:
        receipt['state'] = 'Failed'
        receipt['failure'] = str(error)
        raise
    finally:
        receipt['finishedAt'] = datetime.datetime.now().astimezone().isoformat()
        save()


if __name__ == '__main__':
    main()
