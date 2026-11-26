"""构建 Java 8 生产 CPU Agent，复用锁定 ASM 并重定位到私有包名。"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import struct
import subprocess
import zipfile
from lib.game_compat_inputs import jdk_tool
from lib.game_compat_sessions import new_compat_session

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'JavaCpuAgent/src'
LOCK = ROOT / 'scripts/lwjgl-stack-backfill/lib/sources.json'
PREFIX = b'org/objectweb/asm'
PRIVATE = b'com/amcl/cpu/internal/asm'


def digest(data):
    """源码、依赖和最终制品统一以实际字节的 SHA256 绑定。"""
    return hashlib.sha256(data).hexdigest()


def relocate(data):
    """只改 class 常量池 UTF8 的包名前缀，保持索引、指令、栈图与其他字节不变。

    包名均为 ASCII，可直接在 modified UTF8 字节里替换，不对任意字符串重编码。
    替换包括描述符与数组类型；常量池索引不变，因此不涉及字节码偏移重写。
    """
    if data[:4] != b'\xca\xfe\xba\xbe':
        raise ValueError('Invalid CPU agent class')
    result, offset, index = bytearray(data[:10]), 10, 1
    count = int.from_bytes(data[8:10], 'big')
    sizes = {3: 4, 4: 4, 5: 8, 6: 8, 7: 2, 8: 2, 9: 4, 10: 4, 11: 4,
             12: 4, 15: 3, 16: 2, 17: 4, 18: 4, 19: 2, 20: 2}
    while index < count:
        tag = data[offset]
        result.append(tag); offset += 1
        if tag == 1:
            length = int.from_bytes(data[offset:offset + 2], 'big'); offset += 2
            value = data[offset:offset + length].replace(PREFIX, PRIVATE).replace(
                b'org.objectweb.asm', b'com.amcl.cpu.internal.asm')
            result.extend(struct.pack('>H', len(value))); result.extend(value); offset += length
        else:
            size = sizes[tag]
            result.extend(data[offset:offset + size]); offset += size
            if tag in (5, 6): index += 1
        index += 1
    result.extend(data[offset:])
    return bytes(result)


def build(output=None):
    """核对已有 ASM，按输入身份复用制品；编译中间物与收据仅落到外部独立会话。"""
    record = next(item for item in json.loads(LOCK.read_text(encoding='utf-8'))['files']
                  if item['file'] == 'asm-9.9.jar')
    asm = LOCK.parent / record['file']
    asm_bytes = asm.read_bytes()
    if len(asm_bytes) != record['size'] or digest(asm_bytes) != record['sha256']:
        raise RuntimeError('CPU agent ASM identity mismatch')
    sources = sorted(SOURCE.rglob('*.java'))
    recipe = [Path(__file__), LOCK, ROOT / 'JavaCpuAgent/ASM-LICENSE.txt', *sources]
    inputs = [{'path': path.relative_to(ROOT).as_posix(), 'sha256': digest(path.read_text(encoding='utf-8').encode('utf-8'))} for path in recipe]
    identity = digest(json.dumps(inputs, sort_keys=True).encode() + asm_bytes)
    artifact = ROOT / 'entry/src/main/resources/rawfile/amcl-cpu-agent.jar'
    contract = ROOT / 'launch/src/main/ets/CpuCompatibilityArtifact.ets'
    receipt = ROOT / 'JavaCpuAgent/artifact.json'
    old = json.loads(receipt.read_text(encoding='utf-8')) if receipt.exists() else {}
    locked = old.get('inputSha256') == identity
    if locked and artifact.exists() and contract.exists() and old['sha256'] == digest(artifact.read_bytes()) \
            and old['contractSha256'] == digest(contract.read_text(encoding='utf-8').encode('utf-8')):
        print('[cpu-agent] UP-TO-DATE sha256=' + old['sha256']); return artifact
    directory = new_compat_session('cpu-agent-build', output)
    classes = directory / 'classes'; classes.mkdir()
    # --release 8 固定 API 和字节码版本，匿名类捕获字段的输出次序仍取决于实际 javac。
    javac = jdk_tool('javac', minimum=17)
    version_output = subprocess.check_output([javac, '-version'], stderr=subprocess.STDOUT, text=True)
    compiler_version = re.search(r'^javac ([0-9][^\s]*)$', version_output, flags=re.M)
    if not compiler_version:
        raise RuntimeError('Cannot identify CPU agent javac')
    compiler = 'javac ' + compiler_version.group(1)
    subprocess.run([javac, '--release', '8', '-encoding', 'UTF-8', '-proc:none',
                    '-cp', str(asm), '-d', str(classes), *map(str, sources)], check=True)
    entries = {'META-INF/MANIFEST.MF': b'Manifest-Version: 1.0\r\nPremain-Class: com.amcl.cpu.CpuAgent\r\n\r\n'}
    for path in sorted(classes.rglob('*.class')):
        entries[path.relative_to(classes).as_posix()] = relocate(path.read_bytes())
    with zipfile.ZipFile(asm) as archive:
        for name in archive.namelist():
            if name.startswith('org/objectweb/asm/') and name.endswith('.class'):
                entries[name.replace('org/objectweb/asm/', 'com/amcl/cpu/internal/asm/')] = relocate(archive.read(name))
    # ASM 采用 BSD-3-Clause；保留原始许可证及其来源，避免重定位丢失许可归属。
    entries['META-INF/ASM-LICENSE.txt'] = (ROOT / 'JavaCpuAgent/ASM-LICENSE.txt').read_text(encoding='utf-8').encode('utf-8')
    temporary = directory / artifact.name
    with zipfile.ZipFile(temporary, 'w') as archive:
        for name, data in sorted(entries.items()):
            archive.writestr(zipfile.ZipInfo(name, (2000, 1, 1, 0, 0, 0)), data,
                             compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    data = temporary.read_bytes(); checksum = digest(data)
    # 同一来源的制品已经冻结。不同工具链即便编译成功，也不能在构包途中改写已提交的 HAR 摘要。
    if locked and old['sha256'] != checksum:
        raise RuntimeError('CPU agent rebuild differs from frozen artifact: expected ' + old['sha256']
                           + ' (' + old.get('compiler', 'unknown javac') + '), got ' + checksum + ' (' + compiler
                           + '). Select the recorded JDK with AMCL_COMPAT_JAVA_HOME. Candidate retained at ' + str(temporary))
    artifact.parent.mkdir(parents=True, exist_ok=True); artifact.write_bytes(data)
    text = '/** 由 build-cpu-agent.py 生成；运行时按摘要交付独立的生产 CPU Agent。 */\n'
    text += "export const CPU_AGENT_JAR = 'amcl-cpu-agent.jar';\n"
    text += f"export const CPU_AGENT_RUNTIME_JAR = 'amcl-cpu-agent-{checksum}.jar';\n"
    text += f"export const CPU_AGENT_SIZE = {len(data)};\nexport const CPU_AGENT_SHA256 = '{checksum}';\n"
    contract.write_text(text, encoding='utf-8')
    result = {'schema': 1, 'javaOutputRelease': 8, 'compiler': old.get('compiler', compiler) if locked else compiler, 'inputSha256': identity, 'sha256': checksum,
              'size': len(data), 'asmSha256': record['sha256'], 'contractSha256': digest(contract.read_text(encoding='utf-8').encode('utf-8')),
              'sources': inputs, 'classes': sorted(name for name in entries if name.endswith('.class'))}
    receipt.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    (directory / 'build-receipt.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print('[cpu-agent] built sha256=' + checksum + ' output=' + str(directory))
    return artifact


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', help='New external build session directory')
    build(parser.parse_args().output)
