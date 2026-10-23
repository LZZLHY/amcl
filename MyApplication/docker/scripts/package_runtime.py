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
    def string_at(table, offset):
        if offset >= len(table):
            raise ValueError('ELF 字符串越界')
        end = table.find(b'\0', offset)
        if end < 0:
            raise ValueError('ELF 字符串未终止')
        return table[offset:end].decode('utf-8')
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
    return {'needed': sorted(set(needed)), 'imports': sorted(set(imports)),
            'exports': sorted(set(exports)), 'strongImports': sorted(set(strong_imports)),
            'weakImports': sorted(set(weak_imports)),
            'resolvableExports': sorted(set(resolvable_exports))}


def validate_jvm_symbols(libraries, jvm_name, system_library_dir):
    """在打包前验证 JVM 的强引用，仅从实际依赖闭包与明确宿主入口取供应者。

    libjvm 在其他 JNI 库加载前建立 JVM，因此不能把发行包里任意同名导出当成供应者。
    其他 JNI 库可能按 JVM 全局入口反向链接，不能机械套用这个启动根的规则。
    系统供应者来自本次显式 SDK 目录，摘要记入包内；可选 weak 引用不参与否决。
    """
    if system_library_dir is None:
        raise ValueError('JVM 强符号审计需要明确的 AArch64 SDK 系统库目录')
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
            if name == Path(jvm_name).name:
                relative = jvm_name
            elif len(candidates) == 1:
                relative = candidates[0]
            else:
                raise ValueError('JVM 依赖供应者名称不唯一：' + name)
            facts = libraries[relative]
            suppliers[name] = {'kind': 'bundled', 'path': relative}
        else:
            path = system_library_dir / name
            if not path.is_file():
                raise ValueError('JVM 系统符号供应者不存在：' + str(path))
            data = path.read_bytes()
            facts = elf_facts(data)
            suppliers[name] = {'kind': 'sdk', 'sha256': hashlib.sha256(data).hexdigest()}
        provided.update(facts['resolvableExports'])
        for dependency in facts['needed']:
            visit(dependency)

    visit(Path(jvm_name).name)
    # AArch64 指令缓存刷新由 AMCL ELF 装载器的既有 __clear_cache 入口实现，
    # 当前 JDK17 会强引用它。21/25 的线程局部析构注册则由 resolve_global 既有
    # 系统 libc++.so 查询提供 __cxa_thread_atexit，SDK libc++ 动态导出已核对。
    # 只声明这两个真实宿主入口，不通配放行内部 C++ 模板或任意未知导入。
    host_symbols = {'__clear_cache', '__cxa_thread_atexit'}
    required = set(libraries[jvm_name]['strongImports'])
    missing = required - provided - host_symbols
    if missing:
        raise ValueError(jvm_name + ' 缺少必需符号供应者：' + ', '.join(sorted(missing)))
    return {'scope': 'libjvm-dt-needed-closure', 'requiredSymbolCount': len(required),
            'hostSymbolsUsed': sorted(required & host_symbols), 'suppliers': suppliers}


def validate_image(root, major, system_library_dir=None):
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
                    'libfontmanager.so', 'libawt.so', 'libawt_headless.so'))
    for name in required:
        p = root / name
        if not p.is_file() or p.stat().st_size == 0:
            raise ValueError('缺少关键文件或为空：' + name)
    if classic:
        # JDK8 没有 JIMAGE。检查真实 ZIP 目录与核心类，不能只看开头 PK 字节。
        with zipfile.ZipFile(root / 'jre/lib/rt.jar') as boot:
            for name in ('java/lang/Object.class', 'javax/sound/midi/MidiSystem.class',
                         'javax/sound/sampled/AudioSystem.class', 'sun/security/util/ManifestEntryVerifier.class'):
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
    for dirname in (('jre', 'legal') if classic else ('lib', 'conf', 'legal')):
        directory = root / dirname
        if not directory.exists():
            continue
        for p in sorted(directory.rglob('*')):
            if p.is_file():
                if not p.resolve().is_relative_to(root.resolve()):
                    raise ValueError('image 含指向外部的文件链接：' + str(p))
                files[p.relative_to(root).as_posix()] = p
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
        missing = set(facts['needed']) - names - system
        if missing:
            raise ValueError(name + ' 缺少依赖提供者：' + ', '.join(sorted(missing)))
        if any(s.startswith('snd_') for s in facts['imports']):
            raise ValueError(name + ' 保留未实现的 ALSA 符号')
        libraries[name] = facts
    # 先证明启动根能够解析全部强引用，再允许进入 ZIP 打包；坏产物不能形成候选。
    jvm_name = native + 'server/libjvm.so'
    libraries[jvm_name]['linkAudit'] = validate_jvm_symbols(libraries, jvm_name, system_library_dir)
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


def validate_helper(helper):
    """存在的辅助进程校验系统解释器；与 SO 自定义装载器分开验证。"""
    if helper[:7] != b'\x7fELF\x02\x01\x01' or len(helper) < 64:
        raise ValueError('jspawnhelper 不是 ELF64 小端程序')
    phoff = struct.unpack_from('<Q', helper, 32)[0]
    phsize, phnum = struct.unpack_from('<HH', helper, 54)
    if phsize != 56 or phoff + phnum * phsize > len(helper):
        raise ValueError('jspawnhelper 程序头无效')
    interpreters = []
    for index in range(phnum):
        ph = struct.unpack_from('<IIQQQQQQ', helper, phoff + index * phsize)
        if ph[0] == 3:
            if ph[2] + ph[5] > len(helper):
                raise ValueError('jspawnhelper 解释器字段越界')
            interpreters.append(helper[ph[2]:ph[2] + ph[5]].rstrip(b'\0'))
    if interpreters != [b'/lib/ld-musl-aarch64.so.1']:
        raise ValueError('jspawnhelper 解释器与当前 OHOS SDK 不一致：' + repr(interpreters))


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
    files, libraries = validate_image(args.source, args.major, args.system_library_dir)
    manifest = {'schema': 1, 'build': identity, 'capabilities': {
        'javaSound.nativeMidi': 'unavailable-safe', 'javaSound.nativePcm': 'unavailable-safe',
        'javaSound.ports': 'unavailable-safe', 'javaSound.fileParsing': 'requires-runtime-test',
        'awt': 'headless', 'processHelper': 'requires-device-validation'}, 'files': {},
        'nativeLibraries': libraries}
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
            if name.endswith('/jspawnhelper'):
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
    print(json.dumps(receipt, ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__':
    main()
