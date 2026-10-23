"""把真实正向 ELF 的一条重定位改成未支持模型；保留其余文件结构作为反例。"""
from pathlib import Path
import struct

root = Path('/output')
original = (root / 'libgood.so').read_bytes()
offset = struct.unpack_from('<Q', original, 40)[0]
size, count = struct.unpack_from('<HH', original, 58)
record = None
for i in range(count):
    section = struct.unpack_from('<IIQQQQIIQQ', original, offset + i * size)
    if section[1] == 4 and section[5] >= 24:
        record = section[4]
        break
assert record is not None
for kind in [1024, 1028, 1029, 1030, 1032, 4095]:
    data = bytearray(original)
    info = struct.unpack_from('<Q', data, record + 8)[0]
    struct.pack_into('<Q', data, record + 8, (info & 0xffffffff00000000) | kind)
    (root / f'libunsupported-{kind}.so').write_bytes(data)
