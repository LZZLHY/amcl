"""核对锁定 Sherpa 运行库的真实字节、OHOS ELF 依赖与必需 JNI 导出。

不用文件名冒充ABI，也不以字符串搜索代替实际动态符号表。可被HAP门禁用于
检查已解包的原件：--directory 指向任意外部产物目录，锁仍来自正式prebuilt。
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]
SPEC = ROOT / 'prebuilt/mod-natives/sherpa-onnx'


def read_elf(path):
    """读取小端ELF64的实际动态段/符号段，未知结构失败关闭而不猜测文件身份。"""
    data = path.read_bytes()
    if data[:6] != b'\x7fELF\x02\x01':
        raise ValueError('不是小端 ELF64：' + str(path))
    header = struct.unpack_from('<HHIQQQIHHHHHH', data, 16)
    if header[0] != 3 or header[1] != 183:
        raise ValueError('不是AArch64共享库：' + str(path))
    section_offset, section_size, section_count = header[5], header[10], header[11]
    sections = [struct.unpack_from('<IIQQQQIIQQ', data, section_offset + i * section_size)
                for i in range(section_count)]

    def content(section):
        return data[section[4]:section[4] + section[5]]

    def string(table, offset):
        end = table.index(0, offset)
        return table[offset:end].decode('utf-8')

    exports, undefined, needed, soname, runpath = set(), set(), [], None, None
    for section in sections:
        if section[1] == 11:  # SHT_DYNSYM，sh_link指向它实际使用的字符串表。
            table = content(sections[section[6]])
            symbols = content(section)
            for offset in range(0, len(symbols), section[9]):
                name, info, other, index, value, size = struct.unpack_from('<IBBHQQ', symbols, offset)
                if name:
                    (exports if index else undefined).add(string(table, name))
        if section[1] == 6:  # SHT_DYNAMIC，同样以sh_link确定字符串来源。
            table = content(sections[section[6]])
            dynamic = content(section)
            for offset in range(0, len(dynamic), section[9]):
                tag, value = struct.unpack_from('<qQ', dynamic, offset)
                if tag == 1:
                    needed.append(string(table, value))
                elif tag == 14:
                    soname = string(table, value)
                elif tag == 29:
                    runpath = string(table, value)
    if any('GLIBC_' in symbol or '_ZNSt3__1' in symbol for symbol in undefined):
        raise ValueError('发现glibc或宿主libc++ ABI引用：' + str(path))
    return {'soname': soname, 'needed': sorted(needed), 'runpath': runpath,
            'exports': sorted(exports), 'undefined': sorted(undefined)}


def main():
    """同时审查prebuilt或最终HAP内提取件，摘要/依赖/符号任一不符即失败。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=SPEC / 'arm64-v8a')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    lock = json.loads((SPEC / 'artifacts.json').read_text())
    actual = {}
    for record in lock['artifacts']:
        path = args.directory / record['filename']
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != record['sha256'] or path.stat().st_size != record['size']:
            raise ValueError('制品字节与锁不符：' + str(path))
        elf = read_elf(path)
        if elf['soname'] != record['filename'] or elf['runpath'] != '$ORIGIN':
            raise ValueError('SONAME/RUNPATH不符合目标加载合同：' + str(path))
        if elf['needed'] != sorted(record['needed']):
            raise ValueError('实际ELF依赖闭包与锁不符：' + str(path))
        missing = set(record.get('requiredSymbols', [])) - set(elf['exports'])
        if missing:
            raise ValueError('缺必需真实导出：' + ', '.join(sorted(missing)))
        actual[record['filename']] = {'sha256': digest, **elf}
    result = {'schemaVersion': 1, 'state': 'PASS', 'artifacts': actual}
    if args.report:
        args.report.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8', newline='\n')
    print('Sherpa OHOS artifacts PASS: ' + ', '.join(actual))


if __name__ == '__main__':
    main()
