#!/usr/bin/env python3
"""发布字体候选的 ELF 依赖变体，并逐字节记录限定的动态字符串转换。

只允许 AArch64 ELF64 小端 ET_DYN；每个边界来自程序头/动态表。名称缩短
不会移动任何节、段、重定位或指令。共享字符串、版本表和未知依赖直接拒绝。
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess


def digest(data):
    """返回字节的固定 SHA-256 身份，既用于转换前后也用于来源归档。"""
    return hashlib.sha256(data).hexdigest()


class Elf:
    """只读解析本配方生成的标准动态 ELF，任何越界均在写候选前报错。"""
    def __init__(self, data):
        self.data = data
        if data[:7] != b'\x7fELF\x02\x01\x01' or self.unpack('HH', 16) != (3, 183):
            raise ValueError('Expected little-endian AArch64 ET_DYN')
        phoff, shoff = self.unpack('QQ', 32)
        phsize, phnum, shsize, shnum = self.unpack('HHHH', 54)
        if phsize != 56 or shsize != 64 or not phnum or not shnum:
            raise ValueError('Unsupported ELF table layout')
        self.loads, dynamic = [], []
        for i in range(phnum):
            p = self.unpack('IIQQQQQQ', phoff + i * phsize)
            if p[2] + p[5] > len(data):
                raise ValueError('ELF segment outside file')
            if p[0] == 1:
                self.loads.append(p)
            if p[0] == 2:
                dynamic.append(p)
        if len(dynamic) != 1 or dynamic[0][5] % 16:
            raise ValueError('Expected one complete dynamic table')
        self.tags = []
        p = dynamic[0]
        for pos in range(p[2], p[2] + p[5], 16):
            tag, value = self.unpack('qQ', pos)
            if tag == 0:
                break
            self.tags.append((tag, value))
        else:
            raise ValueError('Unterminated dynamic table')
        # 版本定义/需求含额外字符串引用；本库不需要它们，不能漏查后强行修改。
        if any(t in (0x6ffffffc, 0x6ffffffe) for t, _ in self.tags):
            raise ValueError('Versioned dynamic names require a separate reviewed recipe')
        table = dict(self.tags)
        self.str_size = table[10]
        self.str_start = self.offset(table[5], self.str_size)
        self.references = [(t, n) for t, n in self.tags if t in (1, 14, 15, 29, 0x6ffffefa, 0x6ffffefb, 0x6ffffefc)]
        self.symbols = []
        for i in range(shnum):
            section = self.unpack('IIQQQQIIQQ', shoff + i * shsize)
            if section[1] != 11:
                continue
            if section[9] != 24 or section[5] % 24:
                raise ValueError('Unsupported dynamic symbol entry size')
            strings = self.unpack('IIQQQQIIQQ', shoff + section[6] * shsize)
            if strings[4] != self.str_start or strings[5] != self.str_size:
                raise ValueError('Dynamic symbol string table does not match DT_STRTAB')
            for pos in range(section[4], section[4] + section[5], 24):
                symbol = self.unpack('IBBHQQ', pos)
                self.references.append(('symbol', symbol[0]))
                self.symbols.append((self.string(symbol[0]), symbol[3], symbol[1], symbol[2]))
        if not self.symbols:
            raise ValueError('Missing dynamic symbols')
        for _, offset in self.references:
            self.string(offset)

    def unpack(self, fmt, offset):
        """严格检查结构的文件边界，避免异常输入被 struct 的负偏移接受。"""
        size = struct.calcsize('<' + fmt)
        if offset < 0 or offset + size > len(self.data):
            raise ValueError('ELF structure outside file')
        return struct.unpack_from('<' + fmt, self.data, offset)

    def offset(self, address, size):
        """只接受一个完整可文件寻址的 LOAD 映射，拒绝 BSS 或重叠歧义。"""
        hits = [p[2] + address - p[3] for p in self.loads
                if p[3] <= address and address + size <= p[3] + p[5]]
        if len(hits) != 1:
            raise ValueError('ELF virtual address has no unique file range')
        return hits[0]

    def string(self, offset):
        """字符串必须在动态字符串表内终止；不允许跨节查找 NUL。"""
        if offset < 0 or offset >= self.str_size:
            raise ValueError('Dynamic string offset outside table')
        start = self.str_start + offset
        end = self.data.find(b'\0', start, self.str_start + self.str_size)
        if end < 0:
            raise ValueError('Unterminated dynamic string')
        return self.data[start:end].decode('ascii')

    def names(self, tag):
        return [self.string(n) for t, n in self.tags if t == tag]

    def renamed(self, changes):
        """只缩短指定动态项，先排除任何其他字符串引用共享同一字节范围。"""
        result = bytearray(self.data)
        allowed = set()
        records = []
        for tag, old, new in changes:
            hits = [(t, n) for t, n in self.tags if t == tag and self.string(n) == old]
            if len(hits) != 1 or not new or '\0' in new or len(new) > len(old):
                raise ValueError('Expected one exact shorten-only dynamic name: ' + old)
            _, offset = hits[0]
            for other, start in self.references:
                if other == tag and start == offset:
                    continue
                end = start + len(self.string(start)) + 1
                if start < offset + len(old) + 1 and offset < end:
                    raise ValueError('Dynamic name shares bytes with another reference: ' + old)
            first = self.str_start + offset
            replacement = new.encode() + b'\0' * (len(old) + 1 - len(new))
            result[first:first + len(replacement)] = replacement
            allowed.update(range(first, first + len(replacement)))
            records.append({'tag': tag, 'old': old, 'new': new, 'fileOffset': first})
        differences = [i for i, (a, b) in enumerate(zip(self.data, result)) if a != b]
        if len(result) != len(self.data) or any(i not in allowed for i in differences):
            raise ValueError('Unexpected non-name byte change')
        return bytes(result), {'changes': records, 'changedByteOffsets': differences}


def main():
    """打包两种明确依赖闭包，保存未剥离原件和源/配方身份，不执行目标 ELF。"""
    parser = argparse.ArgumentParser()
    for name in ('library', 'reference', 'source-root', 'spec', 'output'):
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    data = args.library.read_bytes()
    image = Elf(data)
    if sorted(image.names(1)) != ['libc.so', 'libfreetype.so.6']:
        raise ValueError('Unexpected Fontconfig dependency closure: ' + repr(image.names(1)))
    if image.names(14) != ['libfontconfig.so.1'] or image.names(15) or image.names(29):
        raise ValueError('Unexpected SONAME or build-tree runtime search path')
    exported = sorted(n for n, sh, info, visibility in image.symbols
                      if sh and info >> 4 in (1, 2) and visibility & 3 in (0, 3))
    if any(n.startswith(('XML_', 'FT_')) for n in exported):
        raise ValueError('Private dependency symbols escaped Fontconfig')
    required = sorted({n for n, sh, _, _ in image.symbols if not sh and n.startswith('FT_')})
    reference = Elf(args.reference.read_bytes())
    available = {n for n, sh, info, visibility in reference.symbols
                 if sh and info >> 4 in (1, 2) and visibility & 3 in (0, 3)}
    if not required or set(required) - available:
        raise ValueError('Reference FreeType cannot satisfy Fontconfig imports')
    receipt = {'schemaVersion': 1, 'sourceLibrarySha256': digest(data),
               'spec': json.loads(args.spec.read_text()), 'specSha256': digest(args.spec.read_bytes()),
               'requiredFreeTypeSymbols': required, 'exportedSymbols': exported,
               'referenceFreeTypeSha256': digest(args.reference.read_bytes()),
               'variants': {}, 'targetExecutionQualified': False}
    # 此命名空间是当前 provider 的真实源适配，不属于较早的 JDK 编译输入。
    # 原 Git 归档与配方保留，编译的两个源文件和 generic 宏头另按实际字节绑定。
    adaptation = json.loads((args.output / 'sources/fontconfig-adaptation.json').read_text())
    for name, expected in adaptation['after'].items():
        if digest((args.source_root / 'fontconfig' / name).read_bytes()) != expected:
            raise ValueError('Compiled Fontconfig source drifted after controlled adaptation')
    generic_header = (args.source_root / 'fontconfig' / adaptation['compiledHeader']).read_bytes()
    if digest(generic_header) != adaptation['genericHeaderSha256']:
        raise ValueError('Compiled generic rules differ from frozen provider input')
    receipt['sourceAdaptation'] = adaptation
    generic_match = re.search(r'^#define AMCL_FONTCONFIG_GENERIC_RULES (".*")$', generic_header.decode('utf-8'), re.M)
    if not generic_match:
        raise ValueError('Missing controlled generic XML macro')
    generic_xml = json.loads(generic_match.group(1)).encode('utf-8')
    markers = {'genericXml': generic_xml,
               'contextApi': b'OH_AbilityRuntime_ApplicationContextGetCacheDir',
               'contextLibrary': b'libability_runtime.so',
               'outsideRuntimeCache': b'.amcl-fontconfig-cache',
               'classicLayout': b'/jre/lib/aarch64/libfontconfig.so',
               'modernLayout': b'/lib/libfontconfig.so'}
    # 只有目标宏实际进入产物才接纳，不仅依据 wrapper 源码中的 -D__OHOS__。
    # API 必须仍是固定 NDK DSO 的可选动态查询，不能偷偷新增最低 API13 的硬导入。
    if any(not marker or marker not in data for marker in markers.values()):
        raise ValueError('Actual Fontconfig ELF is missing OHOS default/cache code markers')
    if any(not sh and name.startswith('OH_AbilityRuntime_') for name, sh, _, _ in image.symbols):
        raise ValueError('Optional context cache introduced a hard NDK API dependency')
    receipt['compiledOhosDefaults'] = {
        'markers': {name: {'offset': data.index(marker), 'sha256': digest(marker), 'sizeBytes': len(marker)}
                    for name, marker in markers.items()},
        'hardContextApiImport': False, 'targetCacheExecutionQualified': False}
    (args.output / 'reference' / 'libfontconfig-original.so').write_bytes(data)
    (args.output / 'reference' / 'libfreetype-link-reference.so').write_bytes(args.reference.read_bytes())
    for variant, needed in [('classic', 'libfreetype.so.6'), ('modern', 'libfreetype.so')]:
        changes = [(14, 'libfontconfig.so.1', 'libfontconfig.so')]
        if needed != 'libfreetype.so.6':
            changes.append((1, 'libfreetype.so.6', needed))
        result, transformation = image.renamed(changes)
        parsed = Elf(result)
        destination = args.output / variant / 'libfontconfig.so'
        destination.write_bytes(result)
        receipt['variants'][variant] = dict(transformation, path=variant + '/' + destination.name,
                                            sha256=digest(result), sizeBytes=len(result),
                                            needed=parsed.names(1), soname=parsed.names(14))
        inspect = subprocess.check_output(['readelf', '-h', '-d', '-sW', str(destination)], text=True)
        (destination.parent / 'readelf.txt').write_text(inspect)
    receipt['buildConfigurations'] = {}
    for name in ('target.cmake', 'target.ini', 'fontconfig-build/meson-config.h',
                 'expat-build/CMakeCache.txt', 'freetype-build/CMakeCache.txt'):
        contents = (args.source_root / name).read_bytes()
        receipt['buildConfigurations'][name] = digest(contents)
        (args.output / 'reference' / name.replace('/', '-')).write_bytes(contents)
    (args.output / 'fontconfig-provenance.json').write_text(json.dumps(receipt, indent=2) + '\n')


if __name__ == '__main__':
    main()
