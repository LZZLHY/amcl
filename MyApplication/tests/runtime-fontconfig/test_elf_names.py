#!/usr/bin/env python3
"""用真实 AArch64 FreeType ELF 验证名称转换边界，避免只拿伪造结构自证。

正例只准改 SONAME 字符串；反例覆盖截断、过长名称、共享字符串、重复动态项
和新增版本表。原始输入保持不变，输出报告位置由调用者显式给出。
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import struct


def main():
    """每个错误用例都由实际有效 ELF 的单处改变生成，并验证明确拒绝。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[2] / 'docker/scripts/package_fontconfig.py'
    spec = importlib.util.spec_from_file_location('fontconfig_package', source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    original = args.reference.read_bytes()
    image = module.Elf(original)
    assert image.names(14) == ['libfreetype.so.6']
    changed, evidence = image.renamed([(14, 'libfreetype.so.6', 'libfreetype.so')])
    assert module.Elf(changed).names(14) == ['libfreetype.so']
    assert len(changed) == len(original)
    assert len(evidence['changedByteOffsets']) == 2
    outcomes = ['valid-exact-name-shortening']

    def reject(name, function):
        """只把预期的输入边界 ValueError 记为拒绝，不吞任意工具/实现异常。"""
        try:
            function()
        except ValueError:
            outcomes.append(name)
        else:
            raise AssertionError('malformed ELF was accepted: ' + name)

    for size in (0, 7, 16, 63, len(original) // 2):
        reject('truncated-' + str(size), lambda size=size: module.Elf(original[:size]))
    reject('name-growth', lambda: image.renamed([(14, 'libfreetype.so.6', 'libfreetype.so.666')]))
    reject('unknown-name', lambda: image.renamed([(14, 'libother.so', 'libother')]))
    reject('embedded-nul', lambda: image.renamed([(14, 'libfreetype.so.6', 'lib\0freetype')]))
    offset = next(value for tag, value in image.tags if tag == 14)
    phoff, shoff = struct.unpack_from('<QQ', original, 32)
    phnum, shsize, shnum = struct.unpack_from('<HHH', original, 56)
    symbols = []
    for index in range(shnum):
        values = struct.unpack_from('<IIQQQQIIQQ', original, shoff + index * shsize)
        if values[1] == 11:
            symbols.append(values[4])
    assert len(symbols) == 1
    for suffix in (0, 3):
        shared = bytearray(original)
        struct.pack_into('<I', shared, symbols[0] + 24, offset + suffix)
        reject('shared-symbol-string-' + str(suffix),
               lambda shared=shared: module.Elf(bytes(shared)).renamed([(14, 'libfreetype.so.6', 'libfreetype.so')]))
    for index in range(phnum):
        program = struct.unpack_from('<IIQQQQQQ', original, phoff + index * 56)
        if program[0] == 2:
            dyn = program
            break
    slots = list(range(dyn[2], dyn[2] + dyn[5], 16))
    # 把已有 NEEDED 槽改为第二个 SONAME，形成歧义；不依赖 ELF 恰好有填充槽，
    # 也不能让解析器选择第一项而遗漏实际重复的动态名称。
    duplicate = bytearray(original)
    needed = next(pos for pos in slots if struct.unpack_from('<q', original, pos)[0] == 1)
    struct.pack_into('<qQ', duplicate, needed, 14, offset)
    reject('duplicate-soname', lambda: module.Elf(bytes(duplicate)).renamed(
        [(14, 'libfreetype.so.6', 'libfreetype.so')]))
    versioned = bytearray(original)
    struct.pack_into('<qQ', versioned, dyn[2], 0x6ffffffe, 0)
    reject('unreviewed-version-table', lambda: module.Elf(bytes(versioned)))
    assert args.reference.read_bytes() == original
    result = {'passed': True, 'reference': str(args.reference),
              'referenceSha256': hashlib.sha256(original).hexdigest(),
              'recipeSha256': hashlib.sha256(source.read_bytes()).hexdigest(), 'cases': outcomes}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    print('Fontconfig ELF naming tests PASS:', len(outcomes), 'cases')


if __name__ == '__main__':
    main()
