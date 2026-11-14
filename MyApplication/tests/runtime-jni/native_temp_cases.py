#!/usr/bin/env python3
"""原生临时根的正式宿主回归：直接编译生产头，只在独占输出生成小型ELF和日志。

迁入已验证的host_temp_test/marker_reader边界；不复制第三方JDK或整套D实验脚本。
交叉链接的AArch64 ELF只作为只读文件样本，不执行目标代码；目录/env用本机真实POSIX。
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent


def digest(path):
    """小型测试/源码输入按实际文件字节登记，不从文件名推定身份。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    if out.exists() or any((v / '.git').exists() for v in (out, *out.parents)):
        parser.error('需要新的仓外输出目录')
    out.mkdir(parents=True)
    commands, cases = [], []

    def run(name, argv):
        """固定参数数组、有限超时并保存原stdout/stderr；任一非零立即停止，不跳过负例。"""
        start = datetime.datetime.now().astimezone().isoformat()
        cp = subprocess.run([str(x) for x in argv], capture_output=True, timeout=40)
        (out / (name + '.stdout.log')).write_bytes(cp.stdout)
        (out / (name + '.stderr.log')).write_bytes(cp.stderr)
        commands.append({'name': name, 'argv': [str(x) for x in argv], 'startedAt': start,
                         'endedAt': datetime.datetime.now().astimezone().isoformat(), 'exitCode': cp.returncode})
        (out / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n', encoding='utf-8')
        if cp.returncode:
            raise RuntimeError(name + ': ' + (cp.stdout + cp.stderr).decode('utf-8', errors='replace'))
        return cp

    clang = shutil.which('clang-15')
    if not clang:
        raise RuntimeError('标准JDK工具链镜像缺少clang-15，不能用伪造e_machine替代真实AArch64链接')
    run('clang-version', [clang, '--version'])
    run('cxx-version', ['g++', '--version'])
    reader = out / 'marker-reader'
    run('reader-build', ['g++', '-std=c++17', '-O2', '-g', '-Wall', '-Wextra', '-Werror',
                        HERE / 'native_temp_marker_test.cpp', '-o', reader])
    root_test = out / 'root-env-test'
    run('root-env-build', ['g++', '-std=c++17', '-O2', '-g', '-pthread', '-Wall', '-Wextra', '-Werror',
                          HERE / 'native_temp_test.cpp', '-Wl,--wrap=setenv', '-Wl,--wrap=unsetenv',
                          '-o', root_test])
    # 沿用已测marker_sdk.c的used+retain只读节形状；无libc/第三方样本，大小仅几KiB。
    # marker必须跨GC/strip保留，导出的普通函数使映像确为真实ET_DYN而非手填ELF头。
    code = out / 'marker-fixture.c'
    code.write_text('''/* 只读marker文件样本；不执行，不代表完整目标JDK。 */
#ifndef LEGACY
__attribute__((used, retain, section(".amcl.nativetemp")))
static const char marker[] = "AMCL_OHOS_NATIVE_TMPDIR_V1";
#endif
int native_temp_fixture(void) { return 7; }
''', encoding='utf-8')
    common = [clang, '--target=aarch64-linux-gnu', '-fuse-ld=lld', '-nostdlib', '-shared', '-fPIC',
              '-O2', '-Wl,--gc-sections', '-Wl,-soname,libnative-temp-fixture.so', code]
    for name, extra in [('new', []), ('new-stripped', ['-Wl,-s']),
                        ('legacy', ['-DLEGACY']), ('legacy-stripped', ['-DLEGACY', '-Wl,-s'])]:
        run('link-' + name, [*common, *extra, '-o', out / (name + '.so')])

    def read(path, expected, reason=None):
        """分类与必要拒绝原因同时匹配，防止损坏了无关ELF字段却误称目标边界通过。"""
        run('read-' + path.stem, [reader, path, str(expected), *([reason] if reason else [])])
        cases.append({'name': path.name, 'expectedContract': expected, 'expectedReason': reason,
                      'bytes': path.stat().st_size, 'sha256': digest(path)})

    def section_info(data):
        """仅定位已成功链接样本的节表以制造单项负例，不实现生产reader的通过判断。"""
        offset = struct.unpack_from('<Q', data, 40)[0]
        count, names_index = struct.unpack_from('<HH', data, 60)
        names_header = offset + names_index * 64
        names_offset, names_size = struct.unpack_from('<QQ', data, names_header + 24)
        names = data[names_offset:names_offset + names_size]
        headers = {}
        for index in range(count):
            header = offset + index * 64
            name_offset = struct.unpack_from('<I', data, header)[0]
            name = names[name_offset:names.index(0, name_offset)].decode('ascii')
            headers[name] = header
        return offset, count, names_index, headers

    new = (out / 'new-stripped.so').read_bytes()
    old = (out / 'legacy-stripped.so').read_bytes()
    assert struct.unpack_from('<HH', new, 16) == (3, 183)
    assert '.symtab' not in section_info(new)[3]
    marker = section_info(new)[3]['.amcl.nativetemp']
    marker_offset = struct.unpack_from('<Q', new, marker + 24)[0]
    marker_size = struct.unpack_from('<Q', new, marker + 32)[0]
    assert new[marker_offset:marker_offset + marker_size] == b'AMCL_OHOS_NATIVE_TMPDIR_V1\0'
    for name, expected in [('new', 1), ('new-stripped', 1), ('legacy', 0), ('legacy-stripped', 0)]:
        read(out / (name + '.so'), expected)

    def changed(name, mutate, expected, reason=None, source=new):
        """每个损坏副本来自同一成功样本，绝不回写基线或历史证据。"""
        data = bytearray(source)
        mutate(data)
        path = out / (name + '.so')
        path.write_bytes(data)
        read(path, expected, reason)

    bad_marker = 'unsupported or non-readonly native temp marker'
    bad_mapping = 'native temp marker is not in an exact readonly PT_LOAD file range'
    changed('wrong-version', lambda b: b.__setitem__(marker_offset + marker_size - 2, ord('2')), 2, bad_marker)
    changed('unterminated-marker', lambda b: b.__setitem__(marker_offset + marker_size - 1, 1), 2, bad_marker)
    changed('wrong-marker-size', lambda b: struct.pack_into('<Q', b, marker + 32, marker_size - 1), 2, bad_marker)
    changed('writable-section', lambda b: struct.pack_into('<Q', b, marker + 8, 3), 2, bad_marker)
    changed('unknown-section-flag', lambda b: struct.pack_into('<Q', b, marker + 8, 0x102), 2, bad_marker)
    changed('without-retain-flag', lambda b: struct.pack_into('<Q', b, marker + 8, 2), 1)
    changed('fake-unmapped-section', lambda b: struct.pack_into('<Q', b, marker + 16, 1 << 48), 2, bad_mapping)

    # 改marker所属真实PT_LOAD权限；不改变文件/虚拟范围，故诊断应准确落在映射合同。
    phoff = struct.unpack_from('<Q', new, 32)[0]
    phnum = struct.unpack_from('<H', new, 56)[0]
    address = struct.unpack_from('<Q', new, marker + 16)[0]
    owner = None
    for index in range(phnum):
        at = phoff + index * 56
        kind, flags, offset, va, _, length = struct.unpack_from('<IIQQQQ', new, at)
        if kind == 1 and va <= address and address - va + marker_size <= length and offset + address - va == marker_offset:
            owner = at
            break
    assert owner is not None
    flags = struct.unpack_from('<I', new, owner + 4)[0]
    changed('writable-load', lambda b: struct.pack_into('<I', b, owner + 4, flags | 2), 2, bad_mapping)
    changed('unreadable-load', lambda b: struct.pack_into('<I', b, owner + 4, flags & ~4), 2, bad_mapping)
    # 把另一个节改为同名，验证重复合同拒绝，不只接受找到的第一份marker。
    another = section_info(new)[3]['.text']
    marker_name = struct.unpack_from('<I', new, marker)[0]
    changed('duplicate-marker', lambda b: struct.pack_into('<I', b, another, marker_name), 2, 'duplicate native temp marker')

    def sectionless(data):
        struct.pack_into('<Q', data, 40, 0)
        struct.pack_into('<HHH', data, 58, 0, 0, 0)

    def extended(data):
        offset, count, names, _ = section_info(data)
        struct.pack_into('<HH', data, 60, 0, 0xffff)
        struct.pack_into('<Q', data, offset + 32, count)
        struct.pack_into('<I', data, offset + 40, names)

    # 原验证已覆盖的合法无节名/无节表旧包不能误拒绝；坏marker也不能降级成Legacy。
    changed('legacy-no-section-names', lambda b: struct.pack_into('<H', b, 62, 0), 0, source=old)
    changed('legacy-no-sections', sectionless, 0, source=old)
    changed('legacy-extra-unmapped-marker', lambda b: b.extend(b'AMCL_OHOS_NATIVE_TMPDIR_V1\0'), 0, source=old)
    changed('extended-legacy', extended, 0, source=old)
    changed('extended-marker', extended, 1)
    changed('out-of-range-table', lambda b: struct.pack_into('<Q', b, 40, len(b) + 1024), 2, 'invalid native temp section table')

    def overflow(data):
        extended(data)
        struct.pack_into('<Q', data, struct.unpack_from('<Q', data, 40)[0] + 32, (1 << 64) - 1)

    changed('extended-count-overflow', overflow, 2, 'invalid native temp section table')
    # 真实POSIX准备/环境对象消费刚链接的两种文件；输出根在/output下，避免路径预算被宿主长路径占满。
    run('root-env', [root_test, out, out / 'new-stripped.so', out / 'legacy-stripped.so'])
    inputs = [HERE / 'native_temp_test.cpp', HERE / 'native_temp_marker_test.cpp', Path(__file__),
              REPO / 'entry/src/main/cpp/jvm/jdk_native_temp_contract.h',
              REPO / 'entry/src/main/cpp/jvm/jdk_native_temp_preparation.h']
    receipt = {'recordedAt': datetime.datetime.now().astimezone().isoformat(), 'passed': True,
               'markerCases': cases, 'sourceSha256': {str(p): digest(p) for p in inputs},
               'scope': 'production helper POSIX lifecycle and real linked AArch64 ELF reader; not target JVM/Attach qualification'}
    (out / 'result.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('PASS native temp prepare/env/fd lifecycle and %d linked ELF marker cases' % len(cases), flush=True)


if __name__ == '__main__':
    main()
