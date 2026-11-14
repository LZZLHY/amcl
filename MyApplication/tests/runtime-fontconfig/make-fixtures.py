#!/usr/bin/env python3
"""生成 AMCL 自有的微型 BDF、PCF 与含 BDF 属性的 TrueType 正例。

字形和属性全部在此定义，不复制外部字体。PCF 按 FreeType 已锁定源码中的
pcf.h/pcfread.c 格式组织；SFNT BDF 表对应同版本 ttbdf.c。测试同时比较真实
像素和属性值，不能以“打开文件返回成功”替代字体解码行为。
"""
import hashlib
import json
from pathlib import Path
import struct
import sys


PROPERTIES = [('FAMILY_NAME', 'AMCLFixture'), ('CHARSET_REGISTRY', 'ISO10646'),
              ('CHARSET_ENCODING', '1'), ('FONT_ASCENT', 4), ('FONT_DESCENT', 0),
              ('PIXEL_SIZE', 4), ('POINT_SIZE', 40), ('RESOLUTION_X', 72),
              ('RESOLUTION_Y', 72), ('AVERAGE_WIDTH', 40), ('DEFAULT_CHAR', 65)]
BITMAP = bytes((0x60, 0x90, 0xf0, 0x90))


def pack(order, fmt, *values):
    """文件字段使用显式字节序；不能受运行生成器的宿主 CPU 字节序影响。"""
    return struct.pack(order + fmt, *values)


def strings_pool():
    """返回独占的 NUL 字符串池和追加函数，表内只保存池内相对偏移。"""
    pool = bytearray()
    def add(value):
        offset = len(pool)
        pool.extend(value.encode('ascii') + b'\0')
        return offset
    return pool, add


def bdf():
    """一个 U+0041 字形；4×4 位图各行高四位恰为测试中的预期像素。"""
    lines = ['STARTFONT 2.1', 'FONT -AMCL-Fixture-Medium-R-Normal--4-40-72-72-C-40-ISO10646-1',
             'SIZE 4 72 72', 'FONTBOUNDINGBOX 4 4 0 0', 'STARTPROPERTIES ' + str(len(PROPERTIES))]
    lines += [name + ' ' + ('"' + value + '"' if isinstance(value, str) else str(value))
              for name, value in PROPERTIES]
    lines += ['ENDPROPERTIES', 'CHARS 1', 'STARTCHAR A', 'ENCODING 65', 'SWIDTH 1000 0',
              'DWIDTH 4 0', 'BBX 4 4 0 0', 'BITMAP']
    lines += [f'{row:02X}' for row in BITMAP]
    return ('\n'.join(lines + ['ENDCHAR', 'ENDFONT']) + '\n').encode()


def pcf():
    """无压缩、低位字节序、高位像素位序 PCF；每个表都提供完整边界。"""
    pool, add = strings_pool()
    records = bytearray()
    for name, value in PROPERTIES:
        is_string = isinstance(value, str)
        name_offset = add(name)
        records += pack('<', 'IBI', name_offset, int(is_string), add(value) if is_string else value)
    properties = pack('<', 'II', 0, len(PROPERTIES)) + records
    properties += b'\0' * (-len(records) % 4) + pack('<', 'I', len(pool)) + pool
    metric = pack('<', '6h', 0, 4, 4, 4, 0, 0)
    accelerators = pack('<', 'I8Biii', 0, 1, 1, 1, 1, 1, 0, 0, 0, 4, 0, 0) + metric + metric
    metrics = pack('<', 'II', 0, 1) + metric
    # format=8: MSB 像素，LSB 字节，1-byte glyph pad 与扫描单元。
    bitmaps = pack('<', 'III4I', 8, 1, 0, 4, 8, 16, 32) + BITMAP
    encodings = pack('<', 'I6H', 0, 65, 65, 0, 0, 65, 0)
    tables = [(1, 0, properties), (2, 0, accelerators), (4, 0, metrics),
              (8, 8, bitmaps), (32, 0, encodings)]
    offset = 8 + 16 * len(tables)
    directory, body = bytearray(), bytearray()
    for kind, fmt, data in tables:
        directory += pack('<', '4I', kind, fmt, len(data), offset)
        body += data
        padding = b'\0' * (-len(data) % 4)
        body += padding
        offset += len(data) + len(padding)
    return pack('<', 'II', 0x70636601, len(tables)) + directory + body


def sfnt():
    """两个 glyph 的最小 TrueType：空 .notdef 和自有正方形 A，含三类 BDF 属性。

    这里仍构造完整 head/hhea/maxp/loca/glyf/cmap 等基本表，使属性查询经过真实
    SFNT 驱动。测试选择 16 ppem，与 BDF strike 一致，并另测不匹配 ppem 失败。
    """
    pool, add = strings_pool()
    values = bytearray()
    for name, kind, value in [('FAMILY_NAME', 0x11, 'AMCLFixture'),
                              ('SIGNED_TEST', 0x12, -7), ('CARDINAL_TEST', 0x13, 0x80000001)]:
        name_offset = add(name)
        encoded = add(value) if isinstance(value, str) else value & 0xffffffff
        values += pack('>', 'IHI', name_offset, kind, encoded)
    bdf_table = pack('>', 'HHIHH', 1, 1, 12 + len(values), 16, 3) + values + pool
    head = pack('>', '4IHHQQ4h5H', 0x10000, 0x10000, 0, 0x5f0f3cf5, 0, 1000,
                0, 0, 0, 0, 1000, 1000, 0, 8, 2, 0, 0)
    hhea = pack('>', 'I3hH11hH', 0x10000, 1000, 0, 0, 1000, 0, 0, 1000,
                1, 0, 0, 0, 0, 0, 0, 0, 2)
    maxp = pack('>', 'I14H', 0x10000, 2, 4, 1, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0)
    glyph = pack('>', '5hHH', 1, 0, 0, 1000, 1000, 3, 0) + b'\1' * 4
    glyph += pack('>', '8h', 0, 1000, 0, -1000, 0, 0, 1000, 0)
    glyph += b'\0' * (-len(glyph) % 4)
    cmap_sub = pack('>', '7H', 4, 32, 0, 4, 4, 1, 0)
    cmap_sub += pack('>', '5H2h2H', 65, 0xffff, 0, 65, 0xffff, -64, 1, 0, 0)
    tables = {'BDF ': bytes(bdf_table), 'head': head, 'hhea': hhea, 'maxp': maxp,
              'hmtx': pack('>', '4H', 1000, 0, 1000, 0), 'loca': pack('>', '3H', 0, 0, len(glyph) // 2),
              'glyf': glyph, 'cmap': pack('>', 'HHHHI', 0, 1, 3, 1, 12) + cmap_sub,
              'name': pack('>', '3H', 0, 0, 6), 'post': pack('>', '8I', 0x30000, 0, 0, 0, 0, 0, 0, 0)}
    count = len(tables)
    power = 1 << (count.bit_length() - 1)
    header = pack('>', 'I4H', 0x10000, count, power * 16, power.bit_length() - 1, (count - power) * 16)
    directory, body = bytearray(), bytearray()
    offset = 12 + count * 16
    for tag, data in sorted(tables.items()):
        padded = data + b'\0' * (-len(data) % 4)
        checksum = sum(struct.unpack('>' + 'I' * (len(padded) // 4), padded)) & 0xffffffff
        directory += tag.encode() + pack('>', '3I', checksum, offset, len(data))
        body += padded
        offset += len(padded)
    result = bytearray(header + directory + body)
    # head 的 checksumAdjustment 在整文件完成后设置；其目录校验仍按零值计算。
    total = sum(struct.unpack('>' + 'I' * (len(result) // 4), result)) & 0xffffffff
    for index, tag in enumerate(sorted(tables)):
        if tag == 'head':
            head_offset = struct.unpack_from('>I', directory, index * 16 + 8)[0]
            struct.pack_into('>I', result, head_offset + 8, (0xb1b0afba - total) & 0xffffffff)
    return bytes(result)


def main():
    """仅写指定外部输出目录，记录每个生成字体的实际身份。"""
    output = Path(sys.argv[1])
    output.mkdir(parents=True, exist_ok=True)
    report = {'author': 'AMCL regression fixture; no third-party font outlines', 'files': {}}
    for name, content in [('fixture.bdf', bdf()), ('fixture.pcf', pcf()), ('fixture.ttf', sfnt())]:
        (output / name).write_bytes(content)
        report['files'][name] = {'sha256': hashlib.sha256(content).hexdigest(), 'size': len(content)}
    (output / 'fixtures.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
