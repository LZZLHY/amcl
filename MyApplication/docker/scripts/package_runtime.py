#!/usr/bin/env python3
"""验证并确定性打包嵌入式 JDK；缺输入、错误 ELF 或未适配 ALSA 立即失败。

只读取构建 image，不执行目标程序。输出 ZIP 内带文件身份与能力清单；原子发布
到调用者明确指定的候选文件，不覆盖既有产物。Python 标准库即可运行。
"""
import argparse
import hashlib
import json
import os
import re
import struct
import subprocess
import zipfile
from pathlib import Path
from midi_runtime_gate import REQUIRED_MIDI_SYMBOLS, validate_midi_backend
from verify_jdk_ports import validate_ports_backend


def elf_facts(data):
    """读取 ELF64 小端节表中的依赖/导入/导出；所有切片先检查范围。"""
    def read(offset, length):
        if offset < 0 or length < 0 or offset + length > len(data):
            raise ValueError('ELF 表项越界或文件截断')
        return data[offset:offset + length]
    if len(data) < 64 or data[:7] != b'\x7fELF\x02\x01\x01':
        raise ValueError('不是 ELF64 小端文件')
    kind, machine = struct.unpack_from('<HH', data, 16)
    if kind != 3 or machine != 183:
        raise ValueError('不是 AArch64 ET_DYN')
    shoff = struct.unpack_from('<Q', data, 40)[0]
    shsize, shnum = struct.unpack_from('<HH', data, 58)
    if shsize != 64 or not shnum:
        raise ValueError('发行库缺少可审计的 ELF 节表')
    sections = [struct.unpack('<IIQQQQIIQQ', read(shoff + i * 64, 64)) for i in range(shnum)]
    needed, imports, exports, strong_imports, weak_imports, resolvable_exports = [], [], [], [], [], []
    function_exports = []
    # 同一有界程序头事实供只读能力数据、动态API名字与实际函数导出核对，不从尾部字符串授予能力。
    phoff = struct.unpack_from('<Q', data, 32)[0]
    phsize, phnum = struct.unpack_from('<HH', data, 54)
    if phnum and phsize != 56:
        raise ValueError('ELF 程序头长度无效')
    segments = [struct.unpack('<IIQQQQQQ', read(phoff + i * phsize, phsize)) for i in range(phnum)]
    readonly = []
    executable = []
    for ph in segments:
        if ph[0] != 1:
            continue
        payload = read(ph[2], ph[5])
        if ph[5] > ph[6]:
            raise ValueError('ELF PT_LOAD文件尺寸大于内存尺寸')
        if ph[1] & 4 and not ph[1] & 2:
            readonly.append(payload)
        if ph[1] & 1:
            executable.append((ph[3], ph[3] + ph[5]))
    def string_at(table, offset):
        if offset >= len(table):
            raise ValueError('ELF 字符串越界')
        end = table.find(b'\0', offset)
        if end < 0:
            raise ValueError('ELF 字符串未终止')
        return table[offset:end].decode('utf-8')
    # 复用同一有边界的 ELF 读取器识别明确后端标记；普通字符串出现不授予能力。
    # 标记必须是实际只读 PT_LOAD 内的只读 PROGBITS 节，正常 strip 后仍能审计。
    markers = {'.amcl.daudio': [], '.amcl.midi': [], '.amcl.ports': [], '.amcl.nativetemp': []}
    names_index = struct.unpack_from('<H', data, 62)[0]
    if names_index >= len(sections):
        raise ValueError('ELF 节名表索引无效')
    names_section = sections[names_index]
    # ELF 允许没有节名表；旧无音频标记的合法库不能因此被本次专属门禁误拒。
    names_table = read(names_section[4], names_section[5]) if names_index else b''
    for marker in sections:
        section_name = string_at(names_table, marker[0]) if names_table else ''
        if section_name not in markers:
            continue
        phoff = struct.unpack_from('<Q', data, 32)[0]
        phsize, phnum = struct.unpack_from('<HH', data, 54)
        if phsize != 56 or not phnum:
            raise ValueError('音频后端标记缺少可审计程序头')
        mapped_readonly = False
        for index in range(phnum):
            ph = struct.unpack('<IIQQQQQQ', read(phoff + index * phsize, phsize))
            if (ph[0] == 1 and ph[1] & 4 and not ph[1] & 2 and
                    marker[4] >= ph[2] and marker[4] + marker[5] <= ph[2] + ph[5] and
                    ph[2] + ph[5] <= len(data) and marker[3] >= ph[3] and
                    marker[3] - ph[3] == marker[4] - ph[2]):
                mapped_readonly = True
        markers[section_name].append({'type': marker[1], 'flags': marker[2], 'bytes': marker[5],
                              'valueHex': read(marker[4], marker[5]).hex(),
                              'mappedReadonly': mapped_readonly})
    for section in sections:
        if section[1] not in (6, 11):
            continue
        if section[6] >= len(sections):
            raise ValueError('ELF 字符串节索引无效')
        strings = sections[section[6]]
        table = read(strings[4], strings[5])
        entries = read(section[4], section[5])
        stride = 16 if section[1] == 6 else 24
        if len(entries) % stride:
            raise ValueError('ELF 表长度无效')
        for offset in range(0, len(entries), stride):
            if section[1] == 6:
                tag, value = struct.unpack_from('<qQ', entries, offset)
                if tag == 1:
                    needed.append(string_at(table, value))
            else:
                name, info, other, index, value, size = struct.unpack_from('<IBBHQQ', entries, offset)
                if name and info >> 4 in (1, 2):
                    symbol = string_at(table, name)
                    (imports if index == 0 else exports).append(symbol)
                    if index == 0:
                        # weak 未定义引用可以合法地保持为空；GLOBAL 引用必须有实际供应者。
                        (strong_imports if info >> 4 == 1 else weak_imports).append(symbol)
                    elif other & 3 in (0, 3) and value != 0:
                        # 全局依赖查询只能使用 default/protected 的实际定义；hidden 定义
                        # 或零地址不得用来证明另一个 DSO 的外部强引用已满足。
                        resolvable_exports.append(symbol)
                        if info & 15 in (2, 10) and any(begin <= value < end for begin, end in executable):
                            function_exports.append(symbol)
    return {'needed': sorted(set(needed)), 'imports': sorted(set(imports)),
            'exports': sorted(set(exports)), 'strongImports': sorted(set(strong_imports)),
            'weakImports': sorted(set(weak_imports)),
            'resolvableExports': sorted(set(resolvable_exports)),
            'resolvableFunctionExports': sorted(set(function_exports)),
            **({field: markers[section] for section, field in (
                ('.amcl.daudio', 'ohosDaudioMarkers'), ('.amcl.midi', 'ohosMidiMarkers'),
                ('.amcl.ports', 'ohosPortsMarkers'), ('.amcl.nativetemp', 'ohosNativeTempMarkers')) if markers[section]}),
            **({'ohosMidiDynamicSymbols': sorted(name for name in REQUIRED_MIDI_SYMBOLS
                if any(name.encode('ascii') + b'\0' in payload for payload in readonly))}
               if markers['.amcl.midi'] else {})}



def validate_sound_backend(facts, system_library_dir, require_playback=False, require_duplex=False, require_timeline=False):
    """只由实际 libjsound 后端标记/依赖/SDK逐符号供应者三者联合授予已实现状态。

    旧无后端 libjsound 保持 None/unavailable-safe；本门不授予任何设备或录音资格。
    libohaudio 不进入通用系统白名单，仅对经本函数验证的 libjsound 放行。
    """
    markers = facts.get('ohosDaudioMarkers', [])
    used = {name for name in facts['imports'] if name.startswith('OH_Audio')}
    needed = 'libohaudio.so' in facts['needed']
    if not markers and not used and not needed:
        if require_playback or require_duplex or require_timeline:
            raise ValueError('构建身份声明了 OHOS DAUDIO 补丁，但实际 libjsound 缺少后端')
        return None
    playback_marker = b'AMCL_DAUDIO_OHOS_API20_PLAYBACK_V1\0'
    duplex_marker = b'AMCL_DAUDIO_OHOS_API20_DUPLEX_V2\0'
    timeline_marker = b'AMCL_DAUDIO_OHOS_API20_DUPLEX_V3\0'
    timeline = len(markers) == 1 and markers[0]['valueHex'] == timeline_marker.hex()
    duplex = timeline or (len(markers) == 1 and markers[0]['valueHex'] == duplex_marker.hex())
    marker = timeline_marker if timeline else duplex_marker if duplex else playback_marker
    if (len(markers) != 1 or markers[0]['type'] != 1 or markers[0]['flags'] != 2 or
            markers[0]['bytes'] != len(marker) or markers[0]['valueHex'] != marker.hex() or
            not markers[0]['mappedReadonly'] or not needed):
        raise ValueError('libjsound OHOS DAUDIO 标记/只读映射/真实依赖不完整')
    if require_duplex and not duplex:
        raise ValueError('构建身份声明了0025，但实际libjsound缺少双向/宿主回调后端')
    if require_timeline and not timeline:
        raise ValueError('构建身份声明了0028，但实际libjsound缺少精确呈现映射/宿主ABI2后端')
    required = {'OH_AudioStreamBuilder_GenerateRenderer',
                'OH_AudioStreamBuilder_SetRendererWriteDataCallbackAdvanced',
                'OH_AudioStreamBuilder_SetRendererErrorCallback',
                'OH_AudioStreamBuilder_SetRendererInterruptCallback',
                'OH_AudioRenderer_Start', 'OH_AudioRenderer_Pause', 'OH_AudioRenderer_Flush',
                'OH_AudioRenderer_Release', 'OH_AudioRenderer_GetTimestamp',
                'OH_AudioRenderer_GetFramesWritten', 'OH_AudioRenderer_SetVolume',
                'OH_AudioRenderer_GetSamplingRate', 'OH_AudioRenderer_GetChannelCount',
                'OH_AudioRenderer_GetSampleFormat', 'OH_AudioRenderer_GetEncodingType',
                'OH_AudioManager_GetAudioRoutingManager', 'OH_AudioRoutingManager_GetPreferredOutputDevice'}
    if timeline:
        # V1/V2历史原合同保留；V3使用API15实际呈现位置，累计写入量不再参与完成判定。
        required -= {'OH_AudioRenderer_GetTimestamp', 'OH_AudioRenderer_GetFramesWritten'}
        required |= {'OH_AudioRenderer_GetAudioTimestampInfo'}
    if duplex:
        required |= {'OH_AudioRoutingManager_GetPreferredInputDevice', 'OH_AudioStreamBuilder_SetCapturerInfo',
            'OH_AudioStreamBuilder_GenerateCapturer', 'OH_AudioStreamBuilder_SetCapturerReadDataCallback',
            'OH_AudioStreamBuilder_SetCapturerErrorCallback', 'OH_AudioStreamBuilder_SetCapturerInterruptCallback',
            'OH_AudioCapturer_Start', 'OH_AudioCapturer_Pause', 'OH_AudioCapturer_Flush', 'OH_AudioCapturer_Release',
            'OH_AudioCapturer_GetCurrentState', 'OH_AudioCapturer_GetSamplingRate', 'OH_AudioCapturer_GetChannelCount',
            'OH_AudioCapturer_GetSampleFormat', 'OH_AudioCapturer_GetEncodingType', 'OH_AudioCapturer_GetFrameSizeInCallback'}
    if not required <= set(facts['strongImports']):
        raise ValueError('libjsound OHOS DAUDIO 缺少必需强音频入口')
    if system_library_dir is None:
        raise ValueError('OHOS DAUDIO 需要本次明确 SDK libohaudio 供应者')
    path = Path(system_library_dir) / 'libohaudio.so'
    data = path.read_bytes()
    provider = elf_facts(data)
    missing = used - set(provider['resolvableExports'])
    if missing:
        raise ValueError('SDK libohaudio 未提供必需入口：' + ', '.join(sorted(missing)))
    return {'backend': 'ohos-daudio-duplex-v3' if timeline else 'ohos-daudio-duplex-v2' if duplex else 'ohos-daudio-playback-v1', 'minimumApi': 20,
            'qualification': 'implemented-requires-device-test',
            'capture': 'implemented-requires-permission-and-device-test' if duplex else 'not-implemented',
            **({'embeddedCallbacks': 'signed-host-data-abi-v2-required' if timeline else
                                    'signed-host-data-abi-v1-required'} if duplex else {}),
            'provider': 'libohaudio.so',
            'providerSha256': hashlib.sha256(data).hexdigest(), 'requiredSymbols': sorted(used)}


def _validate_native_symbols(libraries, root_name, system_library_dir, host_symbols, scope):
    """复用真实DT_NEEDED闭包检查一个加载根的强引用，不借发行包其它未依赖DSO的导出。

    系统供应者来自明确SDK；host_symbols由具体入口显式指定，不能给音频继承JVM专属豁免。
    weak引用及通过dlsym按平台能力可选解析的MIDI名称不属于strongImports，不作伪强依赖。
    """
    if system_library_dir is None:
        raise ValueError('Native强符号审计需要明确的 AArch64 SDK 系统库目录')
    system_library_dir = Path(system_library_dir)
    by_name = {}
    for name in libraries:
        short = Path(name).name
        by_name.setdefault(short, []).append(name)
    provided, visited, suppliers = set(), set(), {}

    def visit(name):
        """按 DT_NEEDED 递归解析，依赖环只访问一次，拒绝缺文件或非目标 ELF。"""
        if name in visited:
            return
        visited.add(name)
        if name in by_name:
            # 经典 image 会同时携带根目录与 server/ 下的 libjsig 等库；它们若不在
            # JVM 依赖链中，不能导致误拒。仅对本次真正访问的依赖要求唯一供应者。
            candidates = by_name[name]
            if name == Path(root_name).name:
                relative = root_name
            elif len(candidates) == 1:
                relative = candidates[0]
            else:
                raise ValueError('Native依赖供应者名称不唯一：' + name)
            facts = libraries[relative]
            suppliers[name] = {'kind': 'bundled', 'path': relative}
        else:
            path = system_library_dir / name
            if not path.is_file():
                raise ValueError('Native系统符号供应者不存在：' + str(path))
            data = path.read_bytes()
            facts = elf_facts(data)
            suppliers[name] = {'kind': 'sdk', 'sha256': hashlib.sha256(data).hexdigest()}
        provided.update(facts['resolvableExports'])
        for dependency in facts['needed']:
            visit(dependency)

    visit(Path(root_name).name)
    required = set(libraries[root_name]['strongImports'])
    missing = required - provided - host_symbols
    if missing:
        raise ValueError(root_name + ' 缺少必需符号供应者：' + ', '.join(sorted(missing)))
    return {'scope': scope, 'requiredSymbolCount': len(required),
            'hostSymbolsUsed': sorted(required & host_symbols), 'suppliers': suppliers}


def validate_jvm_symbols(libraries, jvm_name, system_library_dir):
    """保持原JVM启动根合同及既有收据形状；只有缓存刷新可由明确宿主入口提供。"""
    return _validate_native_symbols(libraries, jvm_name, system_library_dir,
                                    {'__clear_cache'}, 'libjvm-dt-needed-closure')


def validate_sound_symbols(libraries, sound_name, system_library_dir):
    """libjsound的JNU/JVM/JNI及系统强引用必须来自真实依赖链，不能依赖碰巧已加载libjava。"""
    return _validate_native_symbols(libraries, sound_name, system_library_dir,
                                    set(), 'libjsound-dt-needed-closure')


def validate_image(root, major, system_library_dir=None, require_playback=False, require_duplex=False,
                   require_timeline=False, require_midi=False, require_ports=False):
    """验证最终 image 的关键内容及依赖闭合；系统库允许列表不包含 ALSA。"""
    if major not in ('8', '17', '21', '25'):
        raise ValueError('没有已审核的目标主版本打包配方')
    classic = major == '8'
    native = 'jre/lib/aarch64/' if classic else 'lib/'
    required = ['release', 'jre/lib/rt.jar', 'jre/lib/security/cacerts', 'jre/lib/tzdb.dat',
                native + 'server/libjvm.so', native + 'jli/libjli.so', native + 'libfreetype.so.6'] if classic else [
                'release', 'lib/modules', 'lib/server/libjvm.so', 'lib/libjli.so',
                'lib/libjava.so', 'lib/libzip.so', 'lib/libverify.so', 'lib/libnet.so',
                'lib/libnio.so', 'lib/libjsound.so', 'lib/libcxxabi_shim.so',
                'lib/security/cacerts', 'lib/tzdb.dat', 'lib/jspawnhelper']
    required.extend(native + name for name in ('libjava.so', 'libzip.so', 'libverify.so',
                    'libnet.so', 'libnio.so', 'libjsound.so', 'libcxxabi_shim.so',
                    'libc++_shared.so', 'libfontmanager.so', 'libawt.so', 'libawt_headless.so'))
    # 完整 JDK 必须保留真实工具，不能以只有运行时数据和共享库的 ZIP 冒充。
    required.extend('bin/' + name for name in ('java', 'javac', 'jar', 'keytool'))
    if classic:
        required.append('lib/tools.jar')
    for name in required:
        p = root / name
        if not p.is_file() or p.stat().st_size == 0:
            raise ValueError('缺少关键文件或为空：' + name)
    if classic:
        # JDK8 没有 JIMAGE。检查真实 ZIP 目录与核心类，不能只看开头 PK 字节。
        with zipfile.ZipFile(root / 'jre/lib/rt.jar') as boot:
            for name in ('java/lang/Object.class', 'javax/sound/midi/MidiSystem.class',
                         'javax/sound/sampled/AudioSystem.class', 'sun/security/util/ManifestEntryVerifier.class',
                         'sun/applet/AppletViewer.class', 'sun/applet/AppletPanel.class'):
                data = boot.read(name)
                if data[:8] != b'\xca\xfe\xba\xbe\x00\x00\x00\x34':
                    raise ValueError('rt.jar 核心类不是 Java8 字节码：' + name)
    else:
        with (root / 'lib/modules').open('rb') as f:
            valid = f.read(4) == b'\xda\xda\xfe\xca' and (root / 'lib/modules').stat().st_size >= 1000000
        if not valid:
            raise ValueError('lib/modules 不是完整 JIMAGE')
    release = (root / 'release').read_text()
    version = re.search(r'^JAVA_VERSION="([^\"]+)', release, re.M)
    if not version or (not version[1].startswith('1.8.0') if classic else version[1].split('.')[0] != major):
        raise ValueError('JAVA_VERSION 与目标主版本不一致')
    # 辅助进程由系统执行，不能套用 SO 自定义装载器的成功结论。
    helper_path = root / (native + 'jspawnhelper' if classic else 'lib/jspawnhelper')
    # 8u452 的 UnixProcess 使用 fork/exec，没有要求生成 jspawnhelper；若将来有则仍需校验。
    if helper_path.exists():
        validate_helper(helper_path.read_bytes())
    files = {}
    # 从最终完整 image 收集全部文件，包括 bin、include、jmods、tools.jar 和许可。
    # 内部链接按原字节展开；指向 image 外的链接不能把构建机文件带入发行包。
    for p in sorted(root.rglob('*')):
        if p.is_file():
            if not p.resolve().is_relative_to(root.resolve()):
                raise ValueError('image 含指向外部的文件链接：' + str(p))
            name = p.relative_to(root).as_posix()
            files[name] = p
            if name.startswith(('bin/', 'jre/bin/')):
                validate_tool(p.read_bytes(), name)
    files['release'] = root / 'release'
    # 经典 image 的许可位于根，跟随运行时分发；不能只收集现代 legal/ 目录。
    for name in ('LICENSE', 'ASSEMBLY_EXCEPTION', 'THIRD_PARTY_README'):
        if (root / name).is_file(): files[name] = root / name
    names = {Path(name).name for name in files}
    system = {'libc.so', 'libm.so', 'libdl.so', 'libpthread.so', 'librt.so', 'libz.so', 'ld-musl-aarch64.so.1'}
    libraries = {}
    for name, p in files.items():
        if '.so' not in p.name:
            continue
        facts = elf_facts(p.read_bytes())
        allowed = system
        if name == native + 'libjsound.so':
            audio = validate_sound_backend(facts, system_library_dir, require_playback, require_duplex, require_timeline)
            midi = validate_midi_backend(facts, system_library_dir, require_midi)
            ports = validate_ports_backend(facts, system_library_dir, require_ports)
            if midi:
                if 'libohmidi.so' in names:
                    raise ValueError('可选MIDI的系统供应者不得被包内同名库遮蔽')
                facts['javaSoundMidiBackend'] = midi
            if ports:
                facts['javaSoundPortsBackend'] = ports
            if audio:
                if 'libohaudio.so' in names:
                    raise ValueError('OHOS DAUDIO 的系统 libohaudio 不得被包内同名库遮蔽')
                facts['javaSoundBackend'] = audio
            if audio or ports:
                allowed = system | {'libohaudio.so'}
        elif any(facts.get(key) for key in ('ohosDaudioMarkers', 'ohosMidiMarkers', 'ohosPortsMarkers')):
            raise ValueError('JavaSound后端标记出现在libjsound之外：' + name)
        missing = set(facts['needed']) - names - allowed
        if missing:
            raise ValueError(name + ' 缺少依赖提供者：' + ', '.join(sorted(missing)))
        if any(s.startswith('snd_') for s in facts['imports']):
            raise ValueError(name + ' 保留未实现的 ALSA 符号')
        libraries[name] = facts
    # 先证明启动根能够解析全部强引用，再允许进入 ZIP 打包；坏产物不能形成候选。
    jvm_name = native + 'server/libjvm.so'
    libraries[jvm_name]['linkAudit'] = validate_jvm_symbols(libraries, jvm_name, system_library_dir)
    # JDK25只有头文件依赖并不产生libjava的动态依赖；在完整包形成前检查真实强引用闭包。
    sound_name = native + 'libjsound.so'
    libraries[sound_name]['linkAudit'] = validate_sound_symbols(libraries, sound_name, system_library_dir)
    from verify_jdk_abi import verify
    libraries[native + 'libcxxabi_shim.so']['abiAudit'] = verify(
        files[native + 'libc++_shared.so'].read_bytes(),
        files[native + 'libcxxabi_shim.so'].read_bytes())
    sound = libraries[native + 'libjsound.so']
    if classic:
        # 8 的 Java provider 先经过 Platform 位掩码门控，四个现代 provider JNI 不是它的契约。
        if 'libjsoundalsa.so' in names:
            raise ValueError('JDK8 包不可携带未适配的 ALSA 后端')
        required_exports = ['Java_com_sun_media_sound_Platform_' + n for n in
                            ('nGetExtraLibraries', 'nGetLibraryForFeature', 'nIsBigEndian', 'nIsSigned8')]
    else:
        required_exports = ['Java_com_sun_media_sound_' + provider + '_nGetNumDevices' for provider in
                            ('MidiInDeviceProvider', 'MidiOutDeviceProvider', 'DirectAudioDeviceProvider', 'PortMixerProvider')]
    for symbol in required_exports:
        if symbol not in sound['exports']:
            raise ValueError('缺少音频平台 JNI：' + symbol)
    return files, libraries


def validate_tool(data, name):
    """区分上游真实 native 工具和经典版 CGI 脚本，完整保留其可执行内容。

    JDK8 的 java-rmi.cgi 是 /bin/sh 脚本。不能把全部 bin 文件强制当成 ELF，
    也不能通配允许任意非 ELF 文件冒充 java/javac 等启动器。
    """
    if name in ('bin/java-rmi.cgi', 'jre/bin/java-rmi.cgi'):
        if not data.startswith(b'#!/bin/sh\n') or b'\0' in data:
            raise ValueError(name + ' 不是上游 shell 工具格式')
        return
    validate_helper(data, name)


NATIVE_TEMP_PATCH = '0030-ohos-native-temp-contract.patch'
PERFDATA_UID_PATCH = '0031-ohos-perfdata-uid-identity.patch'
NATIVE_TEMP_MARKER = b'AMCL_OHOS_NATIVE_TMPDIR_V1\0'


def validate_native_temp_contract(libraries, major, identity):
    """只绑定新配方的实际libjvm合同，不将marker或源码存在升级为目标Attach/PerfData资格。

    0030/0031共同构成本轮完整实现；不允许缺UID补丁的包省略保守默认。旧来源且无marker
    保持原输出，发现marker却无对应来源必须拒绝，不能借legacy分支隐藏来源缺口。
    """
    if str(major) not in ('8', '17', '21', '25'):
        raise ValueError('native temp contract has an unknown major')
    jvm_path = ('jre/lib/aarch64/' if str(major) == '8' else 'lib/') + 'server/libjvm.so'
    if jvm_path not in libraries:
        raise ValueError('native temp contract has no selected libjvm')
    for name, facts in libraries.items():
        if name != jvm_path and facts.get('ohosNativeTempMarkers'):
            raise ValueError('native temp marker outside selected libjvm: ' + name)
    markers = libraries[jvm_path].get('ohosNativeTempMarkers', [])
    patches = identity.get('patches', {})
    if not isinstance(patches, dict):
        raise ValueError('native temp source patch identity must be an object')
    required = NATIVE_TEMP_PATCH in patches or PERFDATA_UID_PATCH in patches
    if not required and not markers:
        return
    if any(not isinstance(patches.get(name), str) or not re.fullmatch(r'[0-9a-f]{64}', patches[name])
           for name in (NATIVE_TEMP_PATCH, PERFDATA_UID_PATCH)):
        raise ValueError('native temp marker requires paired frozen0030/0031 source identities')
    frozen = identity.get('inputClosure', {}).get('files', {})
    if any(frozen.get('prebuilt/jdk/' + str(major) + '/patches/' + name) != patches[name]
           for name in (NATIVE_TEMP_PATCH, PERFDATA_UID_PATCH)):
        raise ValueError('native temp patches differ from complete frozen source inputs')
    # GNU_RETAIN可保留，也可被合法strip移除；write/execute/其它未知section属性不接受。
    if not isinstance(markers, list) or len(markers) != 1 or not isinstance(markers[0], dict):
        raise ValueError('native temp source requires one actual readonly libjvm marker')
    marker = markers[0]
    if (type(marker.get('type')) is not int or marker['type'] != 1 or
        type(marker.get('flags')) is not int or marker['flags'] not in (2, 0x200002) or
        type(marker.get('bytes')) is not int or marker['bytes'] != len(NATIVE_TEMP_MARKER) or
        marker.get('valueHex') != NATIVE_TEMP_MARKER.hex() or marker.get('mappedReadonly') is not True):
        raise ValueError('native temp marker is not the exact readonly LOAD contract')


def validate_process_backend(libraries, major, identity):
    """0024现代默认选择必须有同包Native实现；旧image和8不凭新门伪造已适配状态。

    只核对真实可解析JNI导出，不把符号存在当作默认选择/exec行为通过，后者由目标验证。
    """
    if major == '8' or '0024-ohos-childproc-safe-fork.patch' not in identity.get('patches', {}):
        return
    symbol = 'Java_java_lang_ProcessImpl_isOhosPlatform'
    if symbol not in libraries['lib/libjava.so']['resolvableExports']:
        raise ValueError('0024现代进程选择缺少实际Native实现：' + symbol)


def validate_helper(helper, name='jspawnhelper'):
    """校验目标可执行 ELF、装载边界和实际入口；系统 exec 资格另由设备验证。"""
    if helper[:7] != b'\x7fELF\x02\x01\x01' or len(helper) < 64:
        raise ValueError(name + ' 不是 ELF64 小端程序')
    kind, machine, version = struct.unpack_from('<HHI', helper, 16)
    entry = struct.unpack_from('<Q', helper, 24)[0]
    if kind not in (2, 3) or machine != 183 or version != 1 or entry % 4:
        raise ValueError(name + ' 不是有效 AArch64 可执行程序')
    phoff = struct.unpack_from('<Q', helper, 32)[0]
    phsize, phnum = struct.unpack_from('<HH', helper, 54)
    if phsize != 56 or not phnum or phoff < 64 or phoff + phnum * phsize > len(helper):
        raise ValueError(name + ' 程序头无效')
    interpreters, executable_entry, dynamic = [], False, False
    for index in range(phnum):
        ph = struct.unpack_from('<IIQQQQQQ', helper, phoff + index * phsize)
        if ph[2] + ph[5] > len(helper):
            raise ValueError(name + ' 程序段文件范围越界')
        if ph[0] == 1:
            if ph[5] > ph[6] or ph[3] + ph[6] > 2**64:
                raise ValueError(name + ' PT_LOAD 内存范围无效')
            if ph[7] > 1 and (ph[7] & (ph[7] - 1) or (ph[3] - ph[2]) % ph[7]):
                raise ValueError(name + ' PT_LOAD 对齐无效')
            executable_entry |= bool(ph[1] & 1) and ph[3] <= entry < ph[3] + ph[5]
        if ph[0] == 2:
            dynamic = True
        if ph[0] == 3:
            interpreters.append(helper[ph[2]:ph[2] + ph[5]])
    if not executable_entry or not dynamic:
        raise ValueError(name + ' 缺少可执行入口或动态装载表')
    if interpreters != [b'/lib/ld-musl-aarch64.so.1\0']:
        raise ValueError(name + ' 解释器与当前 OHOS SDK 不一致：' + repr(interpreters))


def main():
    """使用固定 ZIP 元数据；写临时文件后 rename，异常不覆盖既有候选包。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--major', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--identity', type=Path, required=True)
    parser.add_argument('--system-library-dir', type=Path, required=True,
                        help='本次构建 SDK 的 usr/lib/aarch64-linux-ohos，供 JVM 强引用供应者核验')
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError('输出已存在，不能覆盖候选产物：' + str(args.output))
    identity = json.loads(args.identity.read_text())
    if identity['major'] != args.major or not identity.get('head'):
        raise ValueError('构建身份与主版本不一致')
    # 新配方若误选回旧无设备分支，必须失败；不能安静打出 unavailable-safe 包冒充本轮实现。
    require_playback = '0023-ohos-javasound-daudio-playback.patch' in identity.get('patches', {})
    require_duplex = '0025-ohos-javasound-duplex-host-callbacks.patch' in identity.get('patches', {})
    require_timeline = '0028-ohos-javasound-presentation-timeline.patch' in identity.get('patches', {})
    require_midi = '0026-ohos-javasound-native-midi.patch' in identity.get('patches', {})
    require_ports = '0027-ohos-javasound-device-ports.patch' in identity.get('patches', {})
    files, libraries = validate_image(args.source, args.major, args.system_library_dir, require_playback,
        require_duplex, require_timeline, require_midi, require_ports)
    validate_process_backend(libraries, args.major, identity)
    validate_native_temp_contract(libraries, args.major, identity)
    # 宿主要求属于包内容契约；即使离线导入丢失目录receipt，也不能抹去typed回调要求。
    manifest = {'schema': 1, 'requiredHostProtocol': 2 if require_duplex or require_midi else 1,
        'build': identity, 'capabilities': {
        'javaSound.nativeMidi': 'unavailable-safe', 'javaSound.nativePcm': 'unavailable-safe',
        'javaSound.ports': 'unavailable-safe', 'javaSound.fileParsing': 'requires-runtime-test',
        'awt': 'headless', 'processHelper': 'requires-device-validation'}, 'files': {},
        'nativeLibraries': libraries}
    sound_path = ('jre/lib/aarch64/' if args.major == '8' else 'lib/') + 'libjsound.so'
    if libraries[sound_path].get('javaSoundMidiBackend'):
        manifest['capabilities']['javaSound.nativeMidi'] = 'ohmidi-api24-optional-midi1'
    if libraries[sound_path].get('javaSoundPortsBackend'):
        manifest['capabilities']['javaSound.ports'] = 'device-ports-requires-device-test'
    audio = libraries[sound_path].get('javaSoundBackend')
    if audio:
        # 旧包无明确后端仍保留原能力；新代码存在也不能冒充设备已经播放通过。
        manifest['capabilities']['javaSound.nativePcm'] = ('duplex-requires-permission-and-device-test'
            if audio['backend'] in ('ohos-daudio-duplex-v2', 'ohos-daudio-duplex-v3') else 'playback-only-requires-device-test')
        manifest['capabilities']['javaSound.nativePlayback'] = audio['qualification']
        manifest['capabilities']['javaSound.nativeCapture'] = audio['capture']
    for name, p in files.items():
        manifest['files'][name] = {'bytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + '.partial')
    if temporary.exists():
        raise ValueError('存在未结束的临时包，请保留现场并选择新输出')
    def info(name):
        z = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
        z.compress_type = zipfile.ZIP_DEFLATED
        z.external_attr = (0o100644 << 16)
        return z
    with zipfile.ZipFile(temporary, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name, p in sorted(files.items()):
            entry = info(name)
            if name.endswith('/jspawnhelper') or name.startswith(('bin/', 'jre/bin/')):
                entry.external_attr = (0o100755 << 16)
            z.writestr(entry, p.read_bytes())
        z.writestr(info('amcl-runtime.json'), json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2).encode())
    # 重新读 ZIP 并按清单核对，避免把压缩成功当成内容仍一致。
    with zipfile.ZipFile(temporary) as z:
        for name, expected in manifest['files'].items():
            data = z.read(name)
            if len(data) != expected['bytes'] or hashlib.sha256(data).hexdigest() != expected['sha256']:
                raise ValueError('打包读回不一致：' + name)
    os.rename(temporary, args.output)
    receipt = {'file': str(args.output), 'bytes': args.output.stat().st_size,
               'sha256': hashlib.sha256(args.output.read_bytes()).hexdigest(), 'build': identity}
    args.output.with_suffix('.manifest.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
    # 完整输入闭包保存在旁路收据和包内；控制台只输出可定位本次产物的身份，
    # 避免数千个 SDK 文件摘要淹没真正的编译/审核诊断。
    print(json.dumps({'file': receipt['file'], 'bytes': receipt['bytes'],
                      'sha256': receipt['sha256'], 'major': args.major,
                      'inputDigest': identity.get('inputClosure', {}).get('digest'),
                      'receipt': str(args.output.with_suffix('.manifest.json'))},
                     ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__':
    main()
