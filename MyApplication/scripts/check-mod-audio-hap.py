"""独立回读当前HAP的音频/语音交付物；不依赖构建器声称成功，也不执行设备代码。"""
import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def digest(data):
    """内容身份与SDK签名/源码提交分别记录，不将文件名或时间戳当作身份。"""
    return hashlib.sha256(data).hexdigest()


def allocated(data):
    """独立比较实际分配节，允许SDK再次strip非运行节，不忽略代码/符号/依赖/重定位变化。"""
    if len(data) < 64 or data[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', data, 18)[0] != 183:
        raise ValueError('音频库不是little-endian AArch64 ELF64')
    offset = struct.unpack_from('<Q', data, 40)[0]
    size, count, names_index = struct.unpack_from('<HHH', data, 58)
    if size != 64 or not count or names_index >= count or offset + count * size > len(data):
        raise ValueError('ELF节表无效')
    rows = [struct.unpack_from('<IIQQQQIIQQ', data, offset + i * size) for i in range(count)]
    name_row = rows[names_index]
    names = data[name_row[4]:name_row[4] + name_row[5]]
    result = []
    for row in rows:
        if not row[2] & 2:
            continue
        end = names.find(b'\0', row[0])
        if end < row[0] or row[1] != 8 and row[4] + row[5] > len(data):
            raise ValueError('ELF分配节截断')
        result.append((names[row[0]:end].decode(), row[1], row[2], row[3], row[5],
                       None if row[1] == 8 else digest(data[row[4]:row[4] + row[5]])))
    return digest(json.dumps(sorted(result), separators=(',', ':')).encode())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hap', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    if not args.output.is_absolute() or output.is_relative_to(ROOT):
        raise ValueError('核对输出必须显式指定仓库外绝对目录')
    output.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('sherpa_elf_reader', ROOT / 'scripts/check-sherpa-artifacts.py')
    reader = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(reader)
    records = {}
    with zipfile.ZipFile(args.hap) as hap:
        names = [entry.filename for entry in hap.infolist()]
        if len(names) != len(set(names)):
            raise ValueError('HAP含重复ZIP条目')

        def read(name, limit=128 * 1024 * 1024):
            entry = hap.getinfo(name)
            if entry.file_size > limit:
                raise ValueError('HAP条目超限：' + name)
            return hap.read(entry)

        module = json.loads(read('module.json', 1024 * 1024))['module']
        permission = [item for item in module['requestPermissions'] if item['name'] == 'ohos.permission.MICROPHONE']
        assert len(permission) == 1
        assert {'EntryAbility', 'GameAbility'} <= set(permission[0]['usedScene']['abilities'])
        records['microphonePermission'] = permission[0]
        abc = read('ets/modules.abc', 64 * 1024 * 1024)
        for name in (b'audioSetPolicy', b'audioConfigurePolicyRoot', b'modMicrophoneEnabled'):
            assert name in abc, 'ABC缺平台权限接点：' + name.decode()

        launcher = read('resources/rawfile/amcl-launcher.jar', 8 * 1024 * 1024)
        assert digest(launcher) == digest((ROOT / 'entry/src/main/resources/rawfile/amcl-launcher.jar').read_bytes())
        with zipfile.ZipFile(io.BytesIO(launcher)) as jar:
            service = jar.read('META-INF/services/javax.sound.sampled.spi.MixerProvider').decode().strip()
            assert service == 'com.amcl.audio.OhosMixerProvider'
            for name in ('OhosMixerProvider', 'OhosAudioNative', 'OhosClip', 'OhosSourceDataLine', 'OhosTargetDataLine'):
                data = jar.read('com/amcl/audio/' + name + '.class')
                assert struct.unpack_from('>H', data, 6)[0] == 52
            properties = jar.read('com/amcl/launcher/sherpa-bindings.properties').decode('ascii')
            assert 'manifest.sha256=' + digest((ROOT / 'prebuilt/mod-natives/sherpa-onnx/verified-bindings.json').read_bytes()) in properties
        records['launcherSha256'] = digest(launcher)

        agent = read('resources/rawfile/amcl-audio-service-agent.jar', 2 * 1024 * 1024)
        agent_lock = json.loads((ROOT / 'JavaAudioServiceAgent/artifact.json').read_text())
        assert digest(agent) == agent_lock['sha256'] and len(agent) == agent_lock['size']
        # HAR编译后的真实pin须与同包资源一致，不能只检查工作树生成文件。
        assert agent_lock['sha256'].encode() in abc
        records['audioServiceAgent'] = {'sha256': digest(agent), 'bytes': len(agent), 'compiledPinFound': True}

        required = {
            'libamcl_audio_runtime.so': ['amclAudioHostPublishEarlyV1', 'amclAudioHostBeginV1', 'amclAudioHostGetV1'],
            'libamcl_audio_jni.so': ['Java_com_amcl_audio_OhosAudioNative_nOpen',
                                    'Java_com_amcl_audio_OhosAudioNative_nRequestFinish',
                                    'Java_com_amcl_audio_OhosAudioNative_nRead', 'Java_com_amcl_audio_OhosAudioNative_nWrite'],
            'libentry.so': [], 'libopenal.so': [],
        }
        lock = json.loads((ROOT / 'prebuilt/mod-natives/sherpa-onnx/artifacts.json').read_text())
        for artifact in lock['artifacts']:
            required[artifact['filename']] = artifact.get('requiredSymbols', [])
        for name, symbols in required.items():
            data = read('libs/arm64-v8a/' + name)
            target = output / name
            target.write_bytes(data)
            elf = reader.read_elf(target)
            assert set(symbols) <= set(elf['exports']), '缺实际音频导出：' + name
            if name in ('libentry.so', 'libopenal.so', 'libamcl_audio_jni.so'):
                assert b'AMCL_AUDIO_HOST_V1' in data or name == 'libentry.so'
            if name == 'libentry.so':
                assert 'libamcl_audio_runtime.so' in elf['needed']
                assert 'OH_AT_CheckSelfPermission' in elf['undefined']
            artifact = next((item for item in lock['artifacts'] if item['filename'] == name), None)
            if artifact:
                source = (ROOT / 'prebuilt/mod-natives/sherpa-onnx/arm64-v8a' / name).read_bytes()
                assert digest(source) == artifact['sha256']
                assert allocated(data) == allocated(source), 'SDK运行节与锁定制品不同：' + name
                assert elf['needed'] == sorted(artifact['needed'])
            records[name] = {'sha256': digest(data), 'bytes': len(data), 'needed': elf['needed'],
                             'lockedRuntimeImageMatch': True if artifact else None}
    hap_hash = hashlib.file_digest(args.hap.open('rb'), 'sha256').hexdigest()
    result = {'schemaVersion': 1, 'state': 'PASS', 'hap': str(args.hap.resolve()), 'sha256': hap_hash,
              'scope': 'actual packaged resources, compiled pin, native ABI and locked runtime images; no device execution',
              'records': records}
    (output / 'verification.json').write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    print('PASS actual HAP microphone/ABC/SPI/compiled agent pin/audio native/Sherpa runtime images: ' + hap_hash)


if __name__ == '__main__':
    main()
