"""执行生产 C++ JNA 契约，覆盖真实上游常量及 ZIP/class 反例；输出仅在外部测试目录。

Windows 使用已安装 WSL 的 C++ 与系统 libz，NDK 只提供有许可证的 zlib 声明头；
不运行游戏、下载类或网络脚本。Linux CI 直接用系统工具链，不跳过失败或缺失依赖。
"""
from pathlib import Path
import argparse
import base64
import io
import json
import os
import shutil
import struct
import subprocess
import sys
import zipfile
from lib.workspace_paths import temporary_directory

ROOT = Path(__file__).resolve().parent.parent
ARGS = argparse.ArgumentParser()
ARGS.add_argument('--real-jars', type=Path)
OPTIONS = ARGS.parse_args()
if os.name == 'nt':
    # Windows盘符冒号不能作为Linux classpath输入；整个测试在WSL使用实际/mnt路径运行。
    def wsl_path(value):
        return subprocess.check_output(['wsl', '-e', 'wslpath', '-a', str(value)], text=True).strip()
    command = ['wsl', '-e', 'env']
    configured_headers = os.environ.get('AMCL_JNA_ZLIB_HEADERS')
    if configured_headers:
        translated_headers = configured_headers if configured_headers.startswith('/') else wsl_path(Path(configured_headers).resolve())
        command.append('AMCL_JNA_ZLIB_HEADERS=' + translated_headers)
    elif subprocess.run(['wsl', '-e', 'test', '-f', '/usr/include/zlib.h']).returncode != 0:
        # 本机默认只是最后回退；独立公开克隆可通过变量指定任意SDK/上游zlib声明头目录。
        default_headers = Path('D:/Huawei/command-line-tools/sdk/default/openharmony/native/sysroot/usr/include')
        if not (default_headers / 'zlib.h').is_file():
            raise RuntimeError('WSL缺少zlib开发头：请安装宿主zlib开发包，或设置AMCL_JNA_ZLIB_HEADERS到含zlib.h/zconf.h的目录')
        command.append('AMCL_JNA_ZLIB_HEADERS=' + wsl_path(default_headers))
    command += ['python3', wsl_path(Path(__file__).resolve())]
    if OPTIONS.real_jars:
        command += ['--real-jars', wsl_path(OPTIONS.real_jars.resolve())]
    sys.exit(subprocess.run(command).returncode)

records = json.loads((ROOT / 'scripts/fixtures/jna-runtime/version-constants.json').read_text('utf-8'))['versions']
with temporary_directory(prefix='amcl-jna-contract-') as raw:
    directory = Path(raw)
    includes = []
    if not Path('/usr/include/zlib.h').is_file():
        # 只复制两个声明头，避免把NDK完整sysroot头置于宿主libc头之前。
        sdk = Path(os.environ['AMCL_JNA_ZLIB_HEADERS'])
        headers = directory / 'headers'
        headers.mkdir()
        for name in ('zlib.h', 'zconf.h'):
            shutil.copyfile(sdk / name, headers / name)
        includes = ['-I' + str(headers)]
    executable = directory / 'jna-test'
    subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-Werror', *includes,
                    str(ROOT / 'entry/src/main/cpp/tests/host/jna_runtime_contract_test.cpp'),
                    str(ROOT / 'entry/src/main/cpp/jvm/jna_runtime_contract.cpp'),
                    '-Wl,-l:libz.so.1', '-o', str(executable)], check=True)
    native = directory / 'native'
    native.mkdir()
    for name in ('libjnidispatch.so', 'libjnidispatch_v5.so', 'libjnidispatch_v6.so'):
        (native / name).write_bytes(b'fixture: file presence only; native artifact bytes verified by separate gate')
    count = 0

    def run(*values):
        return subprocess.check_output([str(executable), *map(str, values)], text=True).split('|')

    def archive(data, method=zipfile.ZIP_DEFLATED, entry='com/sun/jna/Version.class', duplicate=False):
        output = io.BytesIO()
        with zipfile.ZipFile(output, 'w', compression=method) as jar:
            jar.writestr(entry, data)
            if duplicate:
                jar.writestr(entry, data)
        return output.getvalue()

    first = base64.b64decode(records[0]['classBase64'])
    target = directory / 'jna-test.jar'
    for row in records:
        data = base64.b64decode(row['classBase64'])
        for method in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            target.write_bytes(archive(data, method))
            read = run('read', target)
            assert read == ['1', row['protocol'], 'jna_protocol_read'], read
            choice = run('resolve', target, native)
            assert choice[:5] == ['1', 'selected', row['libraryName'], row['protocol'], 'jna_protocol_selected'], choice
            count += 1
    # 同名属性字节不构成合法ConstantValue，魔改类、缺失字段与截断必须defer。
    def invalid(name, payload, reason):
        global count
        target.write_bytes(payload)
        result = run('resolve', target, native)
        assert result[0:2] == ['1', 'deferred'] and result[4] == reason and result[5] == '', (name, result)
        count += 1
    invalid('duplicate', archive(first, duplicate=True), 'jna_zip_duplicate_version')
    invalid('wrong path', archive(first, entry='../com/sun/jna/Version.class'), 'jna_zip_version_missing')
    invalid('oversized class', archive(b'x' * 4097), 'jna_class_too_large')
    invalid('bad class', archive(b'x' * 225), 'jna_class_invalid_magic')
    invalid('truncated class', archive(first[:-1]), 'jna_class_truncated_or_trailing')
    invalid('wrong class identity', archive(first.replace(b'com/sun/jna/Version', b'com/sun/jna/VersioX')), 'jna_class_identity_mismatch')
    future = first.replace(b'5.1.0', b'8.1.0')
    invalid('future protocol', archive(future), 'jna_protocol_unbundled')
    # 合法MR-JAR可能在JDK9+覆盖base的协议声明/Native内联期望；不猜测其实际加载层。
    def multi_release(entry):
        output = io.BytesIO()
        with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as jar:
            jar.writestr('META-INF/MANIFEST.MF', 'Manifest-Version: 1.0\r\nMulti-Release: true\r\n\r\n')
            jar.writestr('com/sun/jna/Version.class', first)
            jar.writestr(entry, base64.b64decode(records[4]['classBase64']))
        return output.getvalue()
    invalid('MR Version override', multi_release('META-INF/versions/9/com/sun/jna/Version.class'), 'jna_multi_release_core_deferred')
    invalid('MR Native override', multi_release('META-INF/versions/17/com/sun/jna/Native.class'), 'jna_multi_release_core_deferred')
    target.write_bytes(multi_release('META-INF/versions/9/example/Unrelated.class'))
    assert run('resolve', target, native)[:5] == ['1', 'selected', 'jnidispatch_v5', '5.1.0', 'jna_protocol_selected']
    count += 1
    # ZIP故障来自实际中央/本地头，CRC负例同时保持两头一致，避免只测到较早的头检查。
    basic = bytearray(archive(first, zipfile.ZIP_STORED))
    central = basic.index(b'PK\x01\x02')
    for label, changes, reason in [
        ('CRC', [(14, struct.pack('<I', 42)), (central + 16, struct.pack('<I', 42))], 'jna_zip_crc_mismatch'),
        ('method', [(8, b'\x63\0'), (central + 10, b'\x63\0')], 'jna_zip_compression_deferred'),
        ('encrypt', [(6, b'\x01\0'), (central + 8, b'\x01\0')], 'jna_zip_encrypted_deferred'),
        ('local name', [(30, b'X')], 'jna_zip_local_mismatch'),
        ('bad central offset', [(len(basic) - 6, b'\xff\xff\xff\x7f')], 'jna_zip_central_invalid'),
        ('ZIP64', [(len(basic) - 12, b'\xff\xff')], 'jna_zip64_deferred'),
        ('multidisk', [(len(basic) - 18, b'\x01\0')], 'jna_zip_multidisk_deferred'),
    ]:
        changed = bytearray(basic)
        for offset, value in changes:
            changed[offset:offset + len(value)] = value
        invalid(label, bytes(changed), reason)
    invalid('truncated ZIP', bytes(basic[:-3]), 'jna_zip_eocd_missing')
    target.write_bytes(archive(first))
    assert run('resolve', str(target) + ':' + str(target), native)[4] == 'jna_multiple_candidates_deferred'
    assert run('resolve', str(target) + ':' + str(directory / 'jna-platform.jar'), native)[1] == 'selected'
    assert run('resolve', str(directory / 'anything.jar'), native)[4] == 'jna_not_identified'
    (native / 'libjnidispatch_v5.so').unlink()
    assert run('resolve', target, native)[:5] == ['0', 'selected', 'jnidispatch_v5', '5.1.0', 'jna_runtime_artifact_missing']
    count += 4
    if OPTIONS.real_jars:
        for row in records:
            jar = OPTIONS.real_jars / row['version'] / ('jna-' + row['version'] + '.jar')
            assert run('read', jar) == ['1', row['protocol'], 'jna_protocol_read']
            count += 1
    print('JNA runtime contract PASS:', count, 'production ZIP/class/selection/freeze cases; real zlib; no JVM execution')
