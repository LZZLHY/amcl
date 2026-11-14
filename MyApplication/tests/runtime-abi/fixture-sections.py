"""为固定测试夹具导出真实节边界；生产 loader 不信任/使用本生成头。"""
from pathlib import Path
import struct
import sys
data = Path(sys.argv[1]).read_bytes()
header = struct.unpack_from('<16sHHIQQQIHHHHHH', data)
sections = [struct.unpack_from('<IIQQQQIIQQ', data, header[6] + i * header[11]) for i in range(header[12])]
strings = sections[header[13]]
names = data[strings[4]:strings[4] + strings[5]]
lines = ['/* 只绑定同目录 libelf_unwind_subject.so 的测试输入；不是一般 ELF 解析接口。 */']
for wanted in ('.eh_frame', '.eh_frame_hdr'):
    match = [s for s in sections if names[s[0]:].split(b'\0', 1)[0].decode() == wanted]
    assert len(match) == 1
    section = match[0]
    identifier = 'fixture_' + wanted[1:]
    lines += [f'constexpr uintptr_t {identifier} = {section[3]};', f'constexpr size_t {identifier}_size = {section[5]};']
Path(sys.argv[2]).write_text('\n'.join(lines) + '\n')
# 所有变体都来自同一真实编译夹具。只改目标字段，其他代码和库依赖保持一致。
directory = Path(sys.argv[1]).parent
no_header = bytearray(data)
header_offset = None
for i in range(header[10]):
    offset = header[5] + i * header[9]
    kind, flags, file_offset = struct.unpack_from('<IIQ', data, offset)
    if kind == 0x6474e550:
        struct.pack_into('<I', no_header, offset, 0)
        header_offset = file_offset
assert header_offset is not None
(directory / 'libelf_unwind_noheader.so').write_bytes(no_header)
stripped = bytearray(data)
struct.pack_into('<Q', stripped, 40, 0)
struct.pack_into('<HHH', stripped, 58, 0, 0, 0)
(directory / 'libelf_unwind_stripped.so').write_bytes(stripped)
bad_header = bytearray(data); bad_header[header_offset] = 2
(directory / 'libelf_unwind_badheader.so').write_bytes(bad_header)
frame_section = next(s for s in sections if names[s[0]:].split(b'\0', 1)[0] == b'.eh_frame')
bad_cie = bytearray(data); bad_cie[frame_section[4] + 8] = 4
(directory / 'libelf_unwind_badcie.so').write_bytes(bad_cie)
