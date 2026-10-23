"""编译真实descriptor/parser，验证单次映射扫描和原平台发布协议，并运行机械反控。

此脚本是正常Source门的独立入口，沿既有host_cpp工具链及外置临时目录；不构建HAP、不接设备。
Windows仅适配Linux maps文本来源，不能据此声称设备线程/调度已验收；原VirtualQuery/并发测试另跑。
"""
from pathlib import Path
import os
import subprocess
import sys
sys.dont_write_bytecode = True
from lib.host_cpp import compile_cpp
from lib.workspace_paths import temporary_directory

ROOT = Path(__file__).resolve().parents[1]
INPUT = ROOT / 'entry/src/main/cpp/input'
TESTS = ROOT / 'entry/src/main/cpp/tests/host'


def compile_probe(work, name, source, maps_mode, mappings=None):
    """每个变体独立生成源码和二进制；完整生产正文只替换明确声明的反控锚点。"""
    implementation = work / (name + '-descriptor.cpp')
    implementation.write_text(source, encoding='utf-8')
    # 每个二进制编译前写入其私有头版本，编译/执行串行，反控不修改正式源码。
    header = mappings if mappings is not None else (INPUT / 'amcl_input_mapped_ranges.h').read_text(encoding='utf-8')
    (work / 'amcl_input_mapped_ranges.h').write_text(header, encoding='utf-8')
    wrapper = work / (name + '.cpp')
    wrapper.write_text('#include "' + implementation.as_posix() + '"\n#include "' +
        (TESTS / 'amcl_input_mapped_ranges_test.cpp').as_posix() + '"\n', encoding='utf-8')
    binary = work / (name + ('.exe' if os.name == 'nt' else ''))
    defines = ['AMCL_INPUT_HOST_TESTING']
    if maps_mode:
        defines.append('AMCL_INPUT_DESCRIPTOR_MAPS_TESTING')
    compile_cpp(wrapper, binary, [INPUT, TESTS], defines)
    return binary


def run(binary, args, expected_success):
    """真实子进程退出决定通过/拒绝；编译失败不算反控成功，保留断言原输出。"""
    print(('RUN ' if expected_success else 'EXPECT REJECTION ') + binary.name, flush=True)
    result = subprocess.run([str(binary), *map(str, args)], capture_output=True, text=True, timeout=60)
    print(result.stdout, end='')
    if result.stderr:
        print(result.stderr, end='', file=sys.stderr)
    if expected_success and result.returncode != 0:
        raise RuntimeError('Production test failed: ' + binary.name)
    if not expected_success and result.returncode == 0:
        raise RuntimeError('Negative control unexpectedly passed: ' + binary.name)


def main():
    """正向计数、原平台owner并发和两种有效机械反控全部完成后才发布PASS。"""
    original = (INPUT / 'amcl_input_host_descriptor.cpp').read_text(encoding='utf-8')
    with temporary_directory(prefix='amcl-input-mapped-ranges-') as directory:
        work = Path(directory)
        model = compile_probe(work, 'production-maps', original, True)
        run(model, [work / 'mapped-fixture.txt'], True)
        native = compile_probe(work, 'production-native', original, False)
        run(native, [work / 'native-read-error.txt'], True)
        # 只撤本轮集合传参，退回生产原逐范围函数；先实测20/2成功，再证明1/1约束能拒绝旧成本。
        anchors = ['false, &mappedRanges)', 'descriptorGeneration, &mappedRanges)']
        if original.count(anchors[0]) != 2 or original.count(anchors[1]) != 1:
            raise RuntimeError('Production batch anchors changed; negative control needs review')
        legacy = original.replace(anchors[0], 'false)').replace(anchors[1], 'descriptorGeneration)')
        old = compile_probe(work, 'legacy-per-range', legacy, True)
        run(old, [work / 'legacy-fixture.txt', '--legacy-count'], True)
        run(old, [work / 'legacy-fixture.txt'], False)
        # 错误跨Resolve缓存必须被本轮重读计数/撤权限拒绝；不是另写一个模拟判定算法。
        anchor = 'amcl::input::detail::MappedRangeSnapshot mappedRanges;'
        if original.count(anchor) != 1:
            raise RuntimeError('Per-call snapshot anchor changed')
        stale = original.replace(anchor, 'static thread_local amcl::input::detail::MappedRangeSnapshot mappedRanges;')
        cached = compile_probe(work, 'wrong-persistent-maps', stale, True)
        run(cached, [work / 'stale-fixture.txt'], False)
        # 原整文件快照也只open一次，但读完8192无关尾行；生产fgets上界必须实际拒绝这种退化。
        header = (INPUT / 'amcl_input_mapped_ranges.h').read_text(encoding='utf-8')
        start = header.index('    bool Contains(')
        end = header.index('\nprivate:', start)
        eager = header[:start] + '''    bool Contains(uintptr_t address, size_t size, bool executable) {
        if (!ready_ || address == 0u || size == 0u || address > UINTPTR_MAX - size) return false;
        MappedRange ignored{};
        while (ReadNextRange(&ignored)) {}
        if (!ready_) return false;
        for (const auto& range : ranges_) if (Matches(range, address, size, executable)) return true;
        return false;
    }
''' + header[end:]
        full = compile_probe(work, 'wrong-eager-tail', original, True, eager)
        run(full, [work / 'eager-fixture.txt'], False)
    print('PASS production mapping scan cursor: cold20->1/warm2->1, early-target8192-tail bounds, close/error/permission/ABI/owner regression, negative controls')


if __name__ == '__main__':
    main()
