"""只改真实 ELF 的一个解释字段，形成可归因的动态表边界反例。"""
from pathlib import Path
import struct

root = Path('/output')
original = (root / 'libgood.so').read_bytes()
phoff = struct.unpack_from('<Q', original, 32)[0]
phsize, count = struct.unpack_from('<HH', original, 54)
headers = [struct.unpack_from('<IIQQQQQQ', original, phoff + i * phsize) for i in range(count)]
def file_offset(address):
    """只接受真实 PT_LOAD 文件区间，不用 section 名称猜动态表地址。"""
    for p in headers:
        if p[0] == 1 and p[3] <= address < p[3] + p[5]:
            return p[2] + address - p[3]
    raise AssertionError(address)
dynamic = next(p for p in headers if p[0] == 2)
tags = {}
for offset in range(dynamic[2], dynamic[2] + dynamic[5], 16):
    tag, value = struct.unpack_from('<qQ', original, offset)
    if not tag: break
    tags[tag] = (offset + 8, value)
cases = {}
def mutate(name, offset, format_, value):
    """每个样本从同一个正例复制，只改变指定字节。"""
    data = bytearray(original)
    struct.pack_into(format_, data, offset, value)
    cases[name] = data

mutate('string-address', tags[5][0], '<Q', 0xfffffffffffffff0)
mutate('string-size', tags[10][0], '<Q', 0xffffffffffffffff)
mutate('string-terminator', file_offset(tags[5][1]) + tags[10][1] - 1, '<B', 65)
mutate('symbol-name', file_offset(tags[6][1]) + 24, '<I', tags[10][1])
mutate('symbol-stride', tags[11][0], '<Q', 8)
sysv = file_offset(tags[4][1])
buckets, symbols = struct.unpack_from('<II', original, sysv)
mutate('sysv-zero-buckets', sysv, '<I', 0)
mutate('sysv-large-count', sysv + 4, '<I', 0xffffffff)
mutate('sysv-bucket-index', sysv + 8, '<I', symbols)
mutate('sysv-chain-cycle', sysv + 8 + 4 * buckets + 4, '<I', 1)
gnu = file_offset(tags[0x6ffffef5][1])
bucket_count, first, bloom_count, shift = struct.unpack_from('<IIII', original, gnu)
mutate('gnu-zero-buckets', gnu, '<I', 0)
mutate('gnu-zero-bloom', gnu + 8, '<I', 0)
mutate('gnu-large-bloom', gnu + 8, '<I', 0xffffffff)
mutate('gnu-shift', gnu + 12, '<I', 32)
mutate('gnu-bucket-index', gnu + 16 + bloom_count * 8, '<I', 0xffffffff)
chain = gnu + 16 + bloom_count * 8 + bucket_count * 4
last = chain + (symbols - first - 1) * 4
mutate('gnu-unterminated-chain', last, '<I', struct.unpack_from('<I', original, last)[0] & ~1)
rela = file_offset(tags[7][1])
mutate('rela-size', tags[8][0], '<Q', 23)
mutate('rela-stride', tags[9][0], '<Q', 8)
mutate('rela-target', rela, '<Q', 0xfffffffffffffff0)
info = struct.unpack_from('<Q', original, rela + 8)[0]
mutate('rela-symbol', rela + 8, '<Q', (0xffffffff << 32) | (info & 0xffffffff))
mutate('init-array-size', tags[27][0], '<Q', 7)
mutate('init-array-address', tags[25][0], '<Q', 0xfffffffffffffff0)
for offset in range(rela, rela + tags[8][1], 24):
    target, relocation, addend = struct.unpack_from('<QQq', original, offset)
    if target == tags[25][1] and relocation & 0xffffffff == 1027:
        mutate('init-target', offset + 16, '<q', 0x7000000000000000)
        break
else:
    raise AssertionError('The positive fixture has no init-array RELATIVE relocation')

for name, data in cases.items():
    (root / ('libbad-dynamic-' + name + '.so')).write_bytes(data)
(root / 'bad-dynamic-cases.txt').write_text('\n'.join(cases) + '\n')
print('Prepared', len(cases), 'single-field dynamic metadata negative controls')
