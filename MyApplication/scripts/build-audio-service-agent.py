"""构建 Java8 的限定音频 SPI Agent；复用锁定 ASM，所有中间输出写外部任务目录。"""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import struct
import subprocess
import zipfile
from lib.game_compat_inputs import jdk_tool
from lib.game_compat_sessions import new_compat_session

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'JavaAudioServiceAgent/src'
PROFILES = ROOT / 'JavaAudioServiceAgent/supported-loaders.json'
LOCK = ROOT / 'scripts/lwjgl-stack-backfill/lib/sources.json'
PREFIX = b'org/objectweb/asm'
PRIVATE = b'com/amcl/audioagent/internal/asm'


def digest(data):
    """构建配方、来源资源和最终 JAR 全部绑定实际 SHA256 字节身份。"""
    return hashlib.sha256(data).hexdigest()


def relocate(data):
    """沿用 CPU Agent 常量池重定位，只改 UTF8 项，不改指令偏移或常量池索引。"""
    if data[:4] != b'\xca\xfe\xba\xbe':
        raise ValueError('Invalid audio service agent class')
    result, offset, index = bytearray(data[:10]), 10, 1
    count = int.from_bytes(data[8:10], 'big')
    sizes = {3: 4, 4: 4, 5: 8, 6: 8, 7: 2, 8: 2, 9: 4, 10: 4, 11: 4,
             12: 4, 15: 3, 16: 2, 17: 4, 18: 4, 19: 2, 20: 2}
    while index < count:
        tag = data[offset]; result.append(tag); offset += 1
        if tag == 1:
            length = int.from_bytes(data[offset:offset + 2], 'big'); offset += 2
            value = data[offset:offset + length].replace(PREFIX, PRIVATE).replace(
                b'org.objectweb.asm', b'com.amcl.audioagent.internal.asm')
            result.extend(struct.pack('>H', len(value))); result.extend(value); offset += length
        else:
            size = sizes[tag]; result.extend(data[offset:offset + size]); offset += size
            if tag in (5, 6): index += 1
        index += 1
    result.extend(data[offset:]); return bytes(result)


def profile_resource():
    """白名单固定进 Agent，仅接受已核完整 class 摘要，不用同名方法推断未知版本兼容。"""
    profiles = json.loads(PROFILES.read_text(encoding='utf-8'))
    service = 'META-INF/services/javax.sound.sampled.spi.MixerProvider'
    if profiles['schemaVersion'] != 1 or profiles['service'] != service or not profiles['profiles']:
        raise RuntimeError('Audio service loader profiles invalid')
    lines = ['schema=1', 'service=' + service]; seen = set()
    for profile in profiles['profiles']:
        if profile['className'] != 'cpw/mods/cl/ModuleClassLoader' or profile['method'] != 'getResources' \
                or profile['descriptor'] != '(Ljava/lang/String;)Ljava/util/Enumeration;' \
                or profile.get('classDelegationMethod') != 'loadClass' \
                or profile.get('classDelegationDescriptor') != '(Ljava/lang/String;Z)Ljava/lang/Class;':
            raise RuntimeError('Unsupported audio service loader ABI')
        sha = profile['classSha256']
        if len(sha) != 64 or any(c not in '0123456789abcdef' for c in sha) or sha in seen:
            raise RuntimeError('Invalid or duplicate audio service class hash')
        seen.add(sha); lines.append('sha256.' + sha + '=' + profile['id'])
    return ('\n'.join(lines) + '\n').encode('ascii')


def build(output=None):
    """可重复生成独立 JAR/部署 pin；中间物沿用 CPU 外部 invocation 契约，不复制依赖缓存。"""
    record = next(item for item in json.loads(LOCK.read_text(encoding='utf-8'))['files'] if item['file'] == 'asm-9.9.jar')
    asm = LOCK.parent / record['file']; asm_bytes = asm.read_bytes()
    if len(asm_bytes) != record['size'] or digest(asm_bytes) != record['sha256']:
        raise RuntimeError('Audio service agent ASM identity mismatch')
    sources = sorted(SOURCE.rglob('*.java')); license_file = ROOT / 'JavaCpuAgent/ASM-LICENSE.txt'
    recipe = [Path(__file__), LOCK, PROFILES, license_file, *sources]
    inputs = [{'path': path.relative_to(ROOT).as_posix(), 'sha256': digest(path.read_text(encoding='utf-8').encode('utf-8'))} for path in recipe]
    resource = profile_resource(); identity = digest(json.dumps(inputs, sort_keys=True).encode() + asm_bytes + resource)
    artifact = ROOT / 'entry/src/main/resources/rawfile/amcl-audio-service-agent.jar'
    contract = ROOT / 'launch/src/main/ets/AudioServiceCompatibilityArtifact.ets'
    receipt = ROOT / 'JavaAudioServiceAgent/artifact.json'
    if receipt.exists() and artifact.exists() and contract.exists():
        previous = json.loads(receipt.read_text(encoding='utf-8'))
        if previous.get('inputSha256') == identity and previous.get('sha256') == digest(artifact.read_bytes()) \
                and previous.get('contractSha256') == digest(contract.read_text(encoding='utf-8').encode('utf-8')):
            print('[audio-service-agent] UP-TO-DATE sha256=' + previous['sha256']); return artifact
    directory = new_compat_session('audio-service-agent-build', output); classes = directory / 'classes'; classes.mkdir()
    subprocess.run([jdk_tool('javac', minimum=17), '--release', '8', '-encoding', 'UTF-8', '-proc:none',
                    '-cp', str(asm), '-d', str(classes), *map(str, sources)], check=True)
    entries = {'META-INF/MANIFEST.MF': b'Manifest-Version: 1.0\r\nPremain-Class: com.amcl.audioagent.AudioServiceAgent\r\n\r\n',
               'com/amcl/audioagent/supported-loaders.properties': resource,
               'META-INF/AMCL-SUPPORTED-LOADERS.json': PROFILES.read_text(encoding='utf-8').encode('utf-8'),
               'META-INF/ASM-LICENSE.txt': license_file.read_text(encoding='utf-8').encode('utf-8')}
    for path in sorted(classes.rglob('*.class')):
        entries[path.relative_to(classes).as_posix()] = relocate(path.read_bytes())
    with zipfile.ZipFile(asm) as archive:
        for name in archive.namelist():
            if name.startswith('org/objectweb/asm/') and name.endswith('.class'):
                entries[name.replace('org/objectweb/asm/', 'com/amcl/audioagent/internal/asm/')] = relocate(archive.read(name))
    temporary = directory / artifact.name
    with zipfile.ZipFile(temporary, 'w') as archive:
        for name, data in sorted(entries.items()):
            archive.writestr(zipfile.ZipInfo(name, (2000, 1, 1, 0, 0, 0)), data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    data = temporary.read_bytes(); checksum = digest(data); artifact.parent.mkdir(parents=True, exist_ok=True); artifact.write_bytes(data)
    text = '/** 由 build-audio-service-agent.py 生成；按固定摘要交付限定 Java Sound SPI Agent。 */\n'
    text += "export const AUDIO_SERVICE_AGENT_JAR = 'amcl-audio-service-agent.jar';\n"
    text += f"export const AUDIO_SERVICE_AGENT_RUNTIME_JAR = 'amcl-audio-service-agent-{checksum}.jar';\n"
    text += f"export const AUDIO_SERVICE_AGENT_SIZE = {len(data)};\nexport const AUDIO_SERVICE_AGENT_SHA256 = '{checksum}';\n"
    contract.write_text(text, encoding='utf-8')
    result = {'schema': 1, 'javaOutputRelease': 8, 'inputSha256': identity, 'sha256': checksum, 'size': len(data),
              'asmSha256': record['sha256'], 'contractSha256': digest(text.encode('utf-8')), 'sources': inputs,
              'classes': sorted(name for name in entries if name.endswith('.class'))}
    receipt.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    # 成功后只保留源码/制品身份与小型收据；仅回收本轮亲建的 classes 与临时 JAR，不碰共享 ASM。
    # 先核验两个真实绝对目标都直属本次 invocation，避免外部输出/符号链接把递归清理引到别处。
    physical = directory.resolve()
    if classes.resolve().parent != physical or temporary.resolve().parent != physical:
        raise RuntimeError('Refusing audio service fixture cleanup outside owned invocation')
    shutil.rmtree(classes); temporary.unlink()
    external_receipt = dict(result, storageStatus='success-fixtures-retired')
    (directory / 'build-receipt.json').write_text(json.dumps(external_receipt, indent=2) + '\n', encoding='utf-8')
    print('[audio-service-agent] built sha256=' + checksum + ' output=' + str(directory)); return artifact


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', help='New external build session directory')
    build(parser.parse_args().output)
