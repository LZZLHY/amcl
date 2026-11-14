"""OHOS可选MIDI产物门：验证实际ELF事实与本次SDK供应者，独立于共享打包入口。
实现身份只授予源码/产物能力，不授予任何外设收发或目标设备CFI资格。
"""
import hashlib
from pathlib import Path
import struct

MIDI_MARKER = b'AMCL_MIDI_OHOS_API24_OPTIONAL_V1\0'
REQUIRED_MIDI_SYMBOLS = (
    'OH_MIDIClient_Create', 'OH_MIDIClient_Destroy', 'OH_MIDIClient_GetDeviceCount',
    'OH_MIDIClient_GetDeviceInfos', 'OH_MIDIClient_GetPortCount', 'OH_MIDIClient_GetPortInfos',
    'OH_MIDIClient_OpenDevice', 'OH_MIDIClient_CloseDevice', 'OH_MIDIDevice_OpenInputPort',
    'OH_MIDIDevice_OpenOutputPort', 'OH_MIDIDevice_CloseInputPort', 'OH_MIDIDevice_CloseOutputPort',
    'OH_MIDIDevice_Send', 'OH_MIDIDevice_FlushOutputPort',
)
REQUIRED_MIDI_JNI_EXPORTS = (
    'Java_com_sun_media_sound_MidiInDeviceProvider_nGetDeviceInfos',
    'Java_com_sun_media_sound_MidiOutDeviceProvider_nGetDeviceInfos',
    'Java_com_sun_media_sound_MidiInDevice_nOpen', 'Java_com_sun_media_sound_MidiInDevice_nClose',
    'Java_com_sun_media_sound_MidiInDevice_nStart', 'Java_com_sun_media_sound_MidiInDevice_nStop',
    'Java_com_sun_media_sound_MidiInDevice_nGetMessages', 'Java_com_sun_media_sound_MidiInDevice_nGetTimeStamp',
    'Java_com_sun_media_sound_MidiOutDevice_nOpen', 'Java_com_sun_media_sound_MidiOutDevice_nClose',
    'Java_com_sun_media_sound_MidiOutDevice_nSendShortMessage', 'Java_com_sun_media_sound_MidiOutDevice_nSendLongMessage',
    'Java_com_sun_media_sound_MidiOutDevice_nGetTimeStamp', 'JNI_OnUnload', 'AMCL_Midi_BackendIdentity',
)
REQUIRED_MIDI_FUNCTION_EXPORTS = tuple(name for name in REQUIRED_MIDI_JNI_EXPORTS if name != 'AMCL_Midi_BackendIdentity')


def _provider_exports(data):
    """仅解析供应者需要的ELF64/AArch64动态函数定义；边界、可见性、类型和实际
    可执行PT_LOAD归属同时成立。与package_runtime不互相导入，避免生产入口循环。
    """
    def read(offset, size):
        if offset < 0 or size < 0 or offset + size > len(data):
            raise ValueError('SDK MIDI provider ELF table is truncated')
        return data[offset:offset + size]
    if len(data) < 64 or data[:7] != b'\x7fELF\x02\x01\x01' or struct.unpack_from('<HH', data, 16) != (3, 183):
        raise ValueError('SDK MIDI provider is not AArch64 ELF64 ET_DYN')
    phoff, shoff = struct.unpack_from('<QQ', data, 32)
    phsize, phnum, shsize, shnum = struct.unpack_from('<HHHH', data, 54)
    if phsize != 56 or not phnum or shsize != 64 or not shnum:
        raise ValueError('SDK MIDI provider has no auditable ELF tables')
    executable = []
    for i in range(phnum):
        ph = struct.unpack('<IIQQQQQQ', read(phoff + i * phsize, phsize))
        if ph[0] == 1 and ph[1] & 1:
            read(ph[2], ph[5])
            if ph[5] > ph[6]:
                raise ValueError('SDK MIDI provider has invalid PT_LOAD size')
            executable.append((ph[3], ph[3] + ph[6]))
    sections = [struct.unpack('<IIQQQQIIQQ', read(shoff + i * shsize, shsize)) for i in range(shnum)]
    exports = set()
    for section in sections:
        if section[1] != 11:
            continue
        if section[9] != 24 or section[5] % 24 or section[6] >= len(sections):
            raise ValueError('SDK MIDI provider has invalid dynamic symbols')
        strings = sections[section[6]]
        if strings[1] != 3:
            raise ValueError('SDK MIDI provider dynamic string table is invalid')
        table = read(strings[4], strings[5])
        symbols = read(section[4], section[5])
        for i in range(0, len(symbols), 24):
            name, info, other, index, value, size = struct.unpack_from('<IBBHQQ', symbols, i)
            if not name:
                continue
            if name >= len(table) or (end := table.find(b'\0', name)) < 0:
                raise ValueError('SDK MIDI provider symbol name is invalid')
            if (index and info >> 4 in (1, 2) and info & 15 in (2, 10) and other & 3 in (0, 3)
                    and value and any(begin <= value < limit for begin, limit in executable)):
                exports.add(table[name:end].decode('utf-8'))
    return exports


def validate_midi_backend(facts, system_library_dir, require_midi):
    """facts由实际libjsound的有界ELF读法生成。ohosMidiMarkers的形状与DAUDIO相同；
    ohosMidiDynamicSymbols只包含在R&&!W PT_LOAD中找到的固定NUL结尾API名字。
    无标记的旧运行包仍返回None；声明0026或只落了一部分后端的包不能误降级成旧包。
    """
    markers = facts.get('ohosMidiMarkers', [])
    imports = {name for name in facts.get('imports', []) if name.startswith('OH_MIDI')}
    needed = 'libohmidi.so' in facts.get('needed', [])
    dynamic = set(facts.get('ohosMidiDynamicSymbols', []))
    if not markers:
        if require_midi or imports or needed or dynamic:
            raise ValueError('libjsound MIDI backend marker is missing')
        return None
    if (len(markers) != 1 or any(type(markers[0].get(key)) is not int for key in ('type', 'flags', 'bytes')) or
            markers[0].get('type') != 1 or markers[0].get('flags') != 2 or
            markers[0].get('bytes') != len(MIDI_MARKER) or markers[0].get('valueHex') != MIDI_MARKER.hex() or
            markers[0].get('mappedReadonly') is not True):
        raise ValueError('libjsound MIDI backend marker is not the exact readonly identity')
    if needed or imports:
        raise ValueError('optional OH_MIDI must not create DT_NEEDED or direct imports')
    if not set(REQUIRED_MIDI_SYMBOLS) <= dynamic:
        raise ValueError('libjsound MIDI optional symbol names are incomplete')
    missing = set(REQUIRED_MIDI_JNI_EXPORTS) - set(facts.get('resolvableExports', []))
    if missing:
        raise ValueError('libjsound MIDI JNI/lifecycle exports are missing: ' + ', '.join(sorted(missing)))
    missing_functions = set(REQUIRED_MIDI_FUNCTION_EXPORTS) - set(facts.get('resolvableFunctionExports', []))
    if missing_functions:
        raise ValueError('libjsound MIDI JNI/lifecycle definitions are not executable functions: ' + ', '.join(sorted(missing_functions)))
    if system_library_dir is None:
        raise ValueError('MIDI backend requires the explicit SDK provider')
    provider = Path(system_library_dir) / 'libohmidi.so'
    data = provider.read_bytes()
    missing = set(REQUIRED_MIDI_SYMBOLS) - _provider_exports(data)
    if missing:
        raise ValueError('SDK libohmidi cannot resolve required functions: ' + ', '.join(sorted(missing)))
    return {'backend': 'ohos-midi1-ump-v1', 'minimumApi': 20, 'providerMinimumApi': 24,
            'binding': 'optional-dlopen', 'qualification': 'implemented-requires-device-test',
            'embeddedCallbacks': 'signed-host-midi-abi-v1-required', 'provider': 'libohmidi.so',
            'providerSha256': hashlib.sha256(data).hexdigest(), 'requiredSymbols': sorted(REQUIRED_MIDI_SYMBOLS)}
