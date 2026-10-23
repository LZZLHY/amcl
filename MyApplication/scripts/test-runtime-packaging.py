"""发布校验负例：直接调用真实打包入口，缺内容/错误 ELF 不能产生成功 ZIP。"""
from pathlib import Path
import importlib.util
import json
import struct
import subprocess
import sys
from lib.workspace_paths import temporary_directory


def synthetic_elf(symbols, needed=()):
    """生成最小 AArch64 动态 ELF，验证真实解析器对强弱引用与可见性的处理。

    symbols 为 (名称、binding、section index、visibility、value)；测试特意保留
    合法 weak、hidden 与零地址供应者，防止新门禁把“有同名字符串”当作可解析。
    """
    strings = bytearray(b'\0')
    def name_offset(name):
        """为 ELF 字符串表追加一个有界、以零终止的 UTF-8 名称。"""
        offset = len(strings); strings.extend(name.encode() + b'\0'); return offset
    dynamic = b''.join(struct.pack('<qQ', 1, name_offset(name)) for name in needed)
    dynamic += bytes(16)
    entries = bytes(24)
    for name, binding, index, visibility, value in symbols:
        entries += struct.pack('<IBBHQQ', name_offset(name), binding << 4 | 2,
                               visibility, index, value, 0)
    data = bytearray(64)
    data[:7] = b'\x7fELF\x02\x01\x01'
    struct.pack_into('<HH', data, 16, 3, 183)
    pieces = [(3, bytes(strings), 0, 0), (11, entries, 1, 24), (6, dynamic, 1, 16)]
    sections = [bytes(64)]
    for kind, contents, link, stride in pieces:
        offset = len(data); data.extend(contents)
        sections.append(struct.pack('<IIQQQQIIQQ', 0, kind, 0, 0, offset,
                                    len(contents), link, 0, 1, stride))
    struct.pack_into('<Q', data, 40, len(data))
    struct.pack_into('<HH', data, 58, 64, len(sections))
    return bytes(data) + b''.join(sections)


def check_symbol_closure(module, sdk):
    """覆盖失效产物、合法系统供应者、弱引用及不在依赖链中的伪供应者。"""
    missing = '_ZN14ArrayAllocatorImL10MemoryType7EE4freeEv'
    jvm = module.elf_facts(synthetic_elf([(missing, 1, 0, 0, 0),
        ('optional_profiler', 2, 0, 0, 0), ('JNI_CreateJavaVM', 1, 1, 0, 256)], ['libc.so']))
    assert jvm['strongImports'] == [missing] and jvm['weakImports'] == ['optional_profiler']
    sdk.joinpath('libc.so').write_bytes(synthetic_elf([]))
    libs = {'lib/server/libjvm.so': jvm}
    try:
        module.validate_jvm_symbols(libs, 'lib/server/libjvm.so', sdk)
    except ValueError as error:
        assert missing in str(error)
    else:
        raise AssertionError('缺失 HotSpot 强引用被发布门禁接受')
    # 任意发行库导出同名符号仍不能满足 JVM：它并不在 JVM 的启动依赖闭包中。
    libs['lib/unrelated.so'] = module.elf_facts(synthetic_elf([(missing, 1, 1, 0, 512)]))
    # JDK8 经典 image 的重复 libjsig 不属于 JVM 依赖；发布审计不能全包误拒。
    empty = module.elf_facts(synthetic_elf([]))
    libs['lib/libjsig.so'] = empty
    libs['lib/server/libjsig.so'] = empty
    for visibility, value in [(2, 512), (0, 0)]:
        sdk.joinpath('libc.so').write_bytes(synthetic_elf([(missing, 1, 1, visibility, value)]))
        try:
            module.validate_jvm_symbols(libs, 'lib/server/libjvm.so', sdk)
        except ValueError:
            pass
        else:
            raise AssertionError('不在依赖闭包/hidden/零地址导出误满足了强引用')
    sdk.joinpath('libc.so').write_bytes(synthetic_elf([(missing, 1, 1, 0, 512)]))
    audit = module.validate_jvm_symbols(libs, 'lib/server/libjvm.so', sdk)
    assert audit['requiredSymbolCount'] == 1 and audit['suppliers']['libc.so']['kind'] == 'sdk'
    # 仅 weak 缺失应通过；真实宿主缓存刷新入口也保留，不能误拒 JDK17。
    libs['lib/server/libjvm.so'] = module.elf_facts(synthetic_elf([
        ('optional_profiler', 2, 0, 0, 0), ('__clear_cache', 1, 0, 0, 0),
        ('__cxa_thread_atexit', 1, 0, 0, 0)]))
    audit = module.validate_jvm_symbols(libs, 'lib/server/libjvm.so', sdk)
    assert audit['hostSymbolsUsed'] == ['__clear_cache', '__cxa_thread_atexit']


def main():
    """使用工作区外置临时目录；不读取用户安装，不执行目标 ELF。"""
    root = Path(__file__).resolve().parent.parent
    script = root / 'docker/scripts/package_runtime.py'
    spec = importlib.util.spec_from_file_location('runtime_packaging', script)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    negatives = [b'', bytes(64), b'\x7fELF\x01\x01\x01' + bytes(57)]
    header = bytearray(64)
    header[:7] = b'\x7fELF\x02\x01\x01'
    struct.pack_into('<HH', header, 16, 3, 62)
    negatives.append(bytes(header))
    struct.pack_into('<H', header, 18, 183)
    struct.pack_into('<Q', header, 40, 65536)
    struct.pack_into('<HH', header, 58, 64, 1)
    negatives.append(bytes(header))
    for data in negatives:
        try:
            module.elf_facts(data)
        except ValueError:
            pass
        else:
            raise AssertionError('坏 ELF 被发布解析器接受')
    with temporary_directory(prefix='runtime-packaging-negative-') as directory:
        area = Path(directory)
        sdk = area / 'sdk'; sdk.mkdir()
        check_symbol_closure(module, sdk)
        image = area / 'image'; image.mkdir()
        identity = area / 'identity.json'
        identity.write_text(json.dumps({'major': '17', 'head': 'a' * 40}))
        output = area / 'bad.zip'
        result = subprocess.run([sys.executable, '-B', str(script), '--major', '17', '--source', str(image),
            '--identity', str(identity), '--system-library-dir', str(sdk), '--output', str(output)],
            capture_output=True, text=True)
        assert result.returncode != 0 and not output.exists(), '缺少关键文件必须非零失败且不发布 ZIP'
        assert '缺少关键文件' in result.stderr, '负例必须命中内容检查而非 CLI 缺参'
    print('PASS runtime packaging: ELF bounds, image completeness and JVM strong/weak/provider closure')


if __name__ == '__main__':
    main()
