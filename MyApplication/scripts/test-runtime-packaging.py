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


def native_temp_elf(marker, flags=0x200002, load_flags=4):
    """最小真实ELF表结构；标记不是任意尾部字符串，读取仍走正式elf_facts。"""
    names = b'\0.shstrtab\0.amcl.nativetemp\0'
    data = bytearray(128)
    data[:7] = b'\x7fELF\x02\x01\x01'
    struct.pack_into('<HHI', data, 16, 3, 183, 1)
    struct.pack_into('<Q', data, 32, 64)
    struct.pack_into('<HHHH', data, 52, 64, 56, 1, 64)
    names_offset = len(data); data.extend(names)
    marker_offset = len(data); data.extend(marker)
    table = len(data)
    data.extend(bytes(64))
    data.extend(struct.pack('<IIQQQQIIQQ', 1, 3, 0, 0, names_offset, len(names), 0, 0, 1, 0))
    data.extend(struct.pack('<IIQQQQIIQQ', 11, 1, flags, marker_offset, marker_offset, len(marker), 0, 0, 1, 0))
    struct.pack_into('<Q', data, 40, table)
    struct.pack_into('<HH', data, 60, 3, 1)
    struct.pack_into('<IIQQQQQQ', data, 64, 1, load_flags, 0, 0, 0, len(data), len(data), 1)
    return bytes(data)


def check_native_temp(module):
    """成对来源与最终libjvm实物同时成立；历史无标记包不产生新能力字段。"""
    for major in ('8', '17', '21', '25'):
        name = ('jre/lib/aarch64/' if major == '8' else 'lib/') + 'server/libjvm.so'
        patches = {module.NATIVE_TEMP_PATCH: 'a' * 64, module.PERFDATA_UID_PATCH: 'b' * 64}
        identity = {'patches': patches, 'inputClosure': {'files': {
            'prebuilt/jdk/' + major + '/patches/' + patch: sha for patch, sha in patches.items()}}}
        for flags in (2, 0x200002):
            facts = module.elf_facts(native_temp_elf(module.NATIVE_TEMP_MARKER, flags))
            module.validate_native_temp_contract({name: facts}, major, identity)
        legacy = module.elf_facts(synthetic_elf([]))
        previous = json.dumps(legacy, sort_keys=True)
        module.validate_native_temp_contract({name: legacy}, major, {})
        assert json.dumps(legacy, sort_keys=True) == previous
        negatives = [({name: legacy}, identity), ({name: facts}, {}),
            ({name: facts}, {'patches': {module.NATIVE_TEMP_PATCH: 'a' * 64}}),
            ({name: facts}, {'patches': {module.PERFDATA_UID_PATCH: 'b' * 64}}),
            ({name: facts}, {'patches': patches, 'inputClosure': {'files': {}}}),
            ({name: legacy, 'lib/wrong.so': facts}, identity)]
        for data in (native_temp_elf(b'AMCL_OHOS_NATIVE_TMPDIR_V2\0'),
                     native_temp_elf(module.NATIVE_TEMP_MARKER, 3),
                     native_temp_elf(module.NATIVE_TEMP_MARKER, 6),
                     native_temp_elf(module.NATIVE_TEMP_MARKER, load_flags=6)):
            negatives.append(({name: module.elf_facts(data)}, identity))
        unmapped = bytearray(native_temp_elf(module.NATIVE_TEMP_MARKER))
        section = struct.unpack_from('<Q', unmapped, 40)[0] + 128
        struct.pack_into('<Q', unmapped, section + 16, 0x100000)
        negatives.append(({name: module.elf_facts(unmapped)}, identity))
        duplicate = dict(facts); duplicate['ohosNativeTempMarkers'] = facts['ohosNativeTempMarkers'] * 2
        negatives.append(({name: duplicate}, identity))
        for libraries, source in negatives:
            try:
                module.validate_native_temp_contract(libraries, major, source)
            except ValueError:
                pass
            else:
                raise AssertionError('native temp错误来源/标记被接受：' + major)


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
    # weak 和缓存刷新保留；C++ TLS 注册必须有真实 ABI 依赖，不能借宿主豁免。
    libs['lib/server/libjvm.so'] = module.elf_facts(synthetic_elf([
        ('optional_profiler', 2, 0, 0, 0), ('__clear_cache', 1, 0, 0, 0)]))
    audit = module.validate_jvm_symbols(libs, 'lib/server/libjvm.so', sdk)
    assert audit['hostSymbolsUsed'] == ['__clear_cache']
    libs['lib/server/libjvm.so'] = module.elf_facts(synthetic_elf([
        ('__cxa_thread_atexit', 1, 0, 0, 0)]))
    try:
        module.validate_jvm_symbols(libs, 'lib/server/libjvm.so', sdk)
    except ValueError as error:
        assert '__cxa_thread_atexit' in str(error)
    else:
        raise AssertionError('C++ TLS 错误依赖被宿主豁免')


def check_sound_closure(module, sdk):
    """完整JNU/JVM/JNI强引用必须经真实依赖满足；不把弱入口或动态MIDI当强引用。"""
    sound='lib/libjsound.so'
    sdk.joinpath('libc.so').write_bytes(synthetic_elf([]))
    required=[('JNU_ThrowByName',1,0,0,0),('JVM_SoundProbe',1,0,0,0),
              ('JNI_SoundProbe',1,0,0,0),('optional_audio_probe',2,0,0,0)]
    java=module.elf_facts(synthetic_elf([('JNU_ThrowByName',1,1,0,512)],['libjvm.so']))
    vm=module.elf_facts(synthetic_elf([('JVM_SoundProbe',1,1,0,512),('JNI_SoundProbe',1,1,0,768)],['libc.so']))
    libs={sound:module.elf_facts(synthetic_elf(required,['libc.so'])),
          'lib/libjava.so':java,'lib/server/libjvm.so':vm}
    try:module.validate_sound_symbols(libs,sound,sdk)
    except ValueError as error:assert all(name in str(error) for name in ('JNU_ThrowByName','JVM_SoundProbe','JNI_SoundProbe'))
    else:raise AssertionError('未声明的包内Java/JVM导出被错误借用')
    libs[sound]=module.elf_facts(synthetic_elf(required,['libjava.so','libc.so']))
    audit=module.validate_sound_symbols(libs,sound,sdk)
    assert audit['requiredSymbolCount']==3 and audit['hostSymbolsUsed']==[]
    assert audit['scope']=='libjsound-dt-needed-closure' and 'libjvm.so' in audit['suppliers']
    for visibility,value in ((2,512),(0,0)):
        libs['lib/libjava.so']=module.elf_facts(synthetic_elf([('JNU_ThrowByName',1,1,visibility,value)],['libjvm.so']))
        try:module.validate_sound_symbols(libs,sound,sdk)
        except ValueError as error:assert 'JNU_ThrowByName' in str(error)
        else:raise AssertionError('hidden或零地址JNU导出被接受')
    libs['lib/libjava.so']=java
    libs[sound]=module.elf_facts(synthetic_elf([('__clear_cache',1,0,0,0)],['libc.so']))
    try:module.validate_sound_symbols(libs,sound,sdk)
    except ValueError as error:assert '__clear_cache' in str(error)
    else:raise AssertionError('音频错误继承JVM宿主豁免')


def check_executable(module):
    """正确的最小结构作阳性；逐项损坏机器/入口/段，避免只测试坏魔数。"""
    module.validate_tool(b'#!/bin/sh\nexec java sun.rmi.transport.proxy.CGIHandler\n', 'bin/java-rmi.cgi')
    for name, data in [('bin/java', b'#!/bin/sh\nexit 0\n'),
                       ('bin/java-rmi.cgi', b'#!/bin/sh\n\0'),
                       ('bin/java-rmi.cgi', b'not a script')]:
        try:
            module.validate_tool(data, name)
        except ValueError as error:
            assert name in str(error)
        else:
            raise AssertionError('错误工具格式被接受：' + name)
    valid = bytearray(512)
    valid[:7] = b'\x7fELF\x02\x01\x01'
    struct.pack_into('<HHIQQ', valid, 16, 3, 183, 1, 256, 64)
    struct.pack_into('<HHH', valid, 52, 64, 56, 3)
    interpreter = b'/lib/ld-musl-aarch64.so.1\0'
    struct.pack_into('<IIQQQQQQ', valid, 64, 1, 5, 0, 0, 0, 512, 512, 4096)
    struct.pack_into('<IIQQQQQQ', valid, 120, 3, 4, 320, 320, 0, len(interpreter), len(interpreter), 1)
    struct.pack_into('<IIQQQQQQ', valid, 176, 2, 6, 384, 384, 0, 16, 16, 8)
    valid[320:320 + len(interpreter)] = interpreter
    module.validate_helper(valid)
    # 每个修改都基于独立的正例，异常必须由真实解析器抛出。
    for offset, format_, value in [(16, '<H', 1), (18, '<H', 62), (20, '<I', 2),
                                  (24, '<Q', 4096), (24, '<Q', 257), (56, '<H', 0),
                                  (64 + 32, '<Q', 513), (64 + 40, '<Q', 128),
                                  (64 + 48, '<Q', 3), (120, '<I', 0), (176, '<I', 0)]:
        bad = bytearray(valid)
        struct.pack_into(format_, bad, offset, value)
        try:
            module.validate_helper(bad)
        except ValueError:
            pass
        else:
            raise AssertionError('坏辅助程序被接受：' + repr((offset, value)))


def main():
    """使用工作区外置临时目录；不读取用户安装，不执行目标 ELF。"""
    root = Path(__file__).resolve().parent.parent
    script = root / 'docker/scripts/package_runtime.py'
    # 库式加载须与直接CLI相同地解析同目录的真实产物门，不能因测试loader丢路径假失败。
    sys.path.insert(0, str(script.parent))
    spec = importlib.util.spec_from_file_location('runtime_packaging', script)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    check_native_temp(module)
    check_executable(module)
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
        check_sound_closure(module, sdk)
        image = area / 'image'; image.mkdir()
        identity = area / 'identity.json'
        identity.write_text(json.dumps({'major': '17', 'head': 'a' * 40}))
        output = area / 'bad.zip'
        result = subprocess.run([sys.executable, '-B', str(script), '--major', '17', '--source', str(image),
            '--identity', str(identity), '--system-library-dir', str(sdk), '--output', str(output)],
            capture_output=True, text=True)
        assert result.returncode != 0 and not output.exists(), '缺少关键文件必须非零失败且不发布 ZIP'
        assert '缺少关键文件' in result.stderr, '负例必须命中内容检查而非 CLI 缺参'
    print('PASS runtime packaging: ELF bounds, image completeness, JVM/sound closure and native-temp paired-source/readonly marker')


if __name__ == '__main__':
    main()
