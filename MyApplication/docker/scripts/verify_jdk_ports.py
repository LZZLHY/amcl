#!/usr/bin/env python3
"""JavaSound Ports专属产物门：只从实际ELF标记、强导入、可解析JNI与本次SDK授权能力。
此模块不解析发布清单中的声称，不修改通用依赖白名单，也不授予设备资格。
elf_facts的公共读取器由package_runtime提供；函数内导入避免主打包器接线时循环初始化。
"""
import hashlib
from pathlib import Path

PORTS_MARKER = b'AMCL_PORTS_OHOS_API20_DEVICES_V1\0'
PORTS_REQUIRED_SYMBOLS = frozenset({
    'OH_AudioManager_GetAudioRoutingManager',
    'OH_AudioRoutingManager_GetDevices',
    'OH_AudioRoutingManager_ReleaseDevices',
    'OH_AudioDeviceDescriptor_GetDeviceRole',
    'OH_AudioDeviceDescriptor_GetDeviceType',
    'OH_AudioDeviceDescriptor_GetDeviceId',
    'OH_AudioDeviceDescriptor_GetDeviceName',
    'OH_AudioDeviceDescriptor_GetDeviceAddress',
})
PORTS_REQUIRED_JNI = frozenset({
    'Java_com_sun_media_sound_PortMixerProvider_nGetNumDevices',
    'Java_com_sun_media_sound_PortMixerProvider_nGetGeneration',
    'Java_com_sun_media_sound_PortMixerProvider_nNewPortMixerInfo',
    'Java_com_sun_media_sound_PortMixerProvider_nNewPortMixerInfoSnapshot',
    'Java_com_sun_media_sound_PortMixer_nOpen',
    'Java_com_sun_media_sound_PortMixer_nOpenSnapshot',
    'Java_com_sun_media_sound_PortMixer_nClose',
    'Java_com_sun_media_sound_PortMixer_nGetPortCount',
    'Java_com_sun_media_sound_PortMixer_nGetPortType',
    'Java_com_sun_media_sound_PortMixer_nGetPortName',
    'Java_com_sun_media_sound_PortMixer_nGetControls',
    'Java_com_sun_media_sound_PortMixer_nControlSetIntValue',
    'Java_com_sun_media_sound_PortMixer_nControlGetIntValue',
    'Java_com_sun_media_sound_PortMixer_nControlSetFloatValue',
    'Java_com_sun_media_sound_PortMixer_nControlGetFloatValue',
})


def validate_ports_backend(facts, system_library_dir, require_ports=False):
    """返回精确设备Ports后端合同，旧无后端返回None，残缺/身份不符直接拒绝。

    两个OHAudio路由API也由PCM消费，旧音频库只有它们不意味着缺Ports标记；新增
    Ports专属入口却没有标记则属于残缺实现。非OHOS的兼容nGetGeneration=0也不
    单独授予能力。所有8个入口必须强导入且由同一本次SDK文件实际导出。
    """
    markers = facts.get('ohosPortsMarkers', [])
    imports = set(facts.get('imports', []))
    exports = set(facts.get('resolvableExports', []))
    exclusive = PORTS_REQUIRED_SYMBOLS - {
        'OH_AudioManager_GetAudioRoutingManager', 'OH_AudioRoutingManager_ReleaseDevices'}
    new_exports = {'Java_com_sun_media_sound_PortMixerProvider_nNewPortMixerInfoSnapshot',
                   'Java_com_sun_media_sound_PortMixer_nOpenSnapshot'}
    if not markers and not (imports & exclusive) and not (exports & new_exports):
        if require_ports:
            raise ValueError('构建身份声明0027，但实际libjsound缺少Ports后端')
        return None
    expected = {'type': 1, 'flags': 2, 'bytes': len(PORTS_MARKER),
                'valueHex': PORTS_MARKER.hex(), 'mappedReadonly': True}
    if (not isinstance(markers, list) or len(markers) != 1 or not isinstance(markers[0], dict) or
            any(type(markers[0].get(key)) is not type(value) or markers[0].get(key) != value
                for key, value in expected.items())):
        raise ValueError('libjsound Ports标记必须是唯一精确33B只读PROGBITS/PT_LOAD')
    if 'libohaudio.so' not in facts.get('needed', []):
        raise ValueError('Ports后端缺少真实libohaudio.so依赖')
    missing = PORTS_REQUIRED_SYMBOLS - set(facts.get('strongImports', []))
    if missing:
        raise ValueError('Ports后端缺少必需强入口：' + ', '.join(sorted(missing)))
    missing = PORTS_REQUIRED_JNI - exports
    if missing:
        raise ValueError('Ports后端缺少可解析JNI导出：' + ', '.join(sorted(missing)))
    if system_library_dir is None:
        raise ValueError('Ports后端需要本次明确SDK供应者目录')
    path = Path(system_library_dir) / 'libohaudio.so'
    data = path.read_bytes()
    from package_runtime import elf_facts
    provider = elf_facts(data)
    # 同库还可有PCM入口；都必须由这个SDK供应者满足，未知OH_Audio名字不能被Ports白名单遮蔽。
    used = {name for name in imports if name.startswith('OH_Audio')} | PORTS_REQUIRED_SYMBOLS
    missing = used - set(provider['resolvableExports'])
    if missing:
        raise ValueError('SDK libohaudio未提供Ports入口：' + ', '.join(sorted(missing)))
    return {'backend': 'ohos-device-ports-v1', 'minimumApi': 20,
            'qualification': 'implemented-requires-device-test',
            'systemControlWrites': 'not-public-api', 'controlsExposed': False,
            'provider': 'libohaudio.so', 'providerSha256': hashlib.sha256(data).hexdigest(),
            'requiredSymbols': sorted(PORTS_REQUIRED_SYMBOLS)}
