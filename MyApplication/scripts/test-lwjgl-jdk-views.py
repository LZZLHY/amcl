"""执行真实派生配方的正反测试，可额外用标准 JarFile 与固定旧扫描器验证整个所选槽。

默认离线测试检查可重现性、保留字节、MR/FFM 内容与畸形输入拒绝。
--java-home/--scanner-dir 打开真实 Java 探针；原始问题包必须失败，派生整槽必须通过。
宿主编译树和收据显式外置，独立公开克隆默认使用仓库外系统临时目录。
"""
import argparse
import datetime
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import warnings
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('lwjgl_views', ROOT / 'scripts/build-lwjgl-jdk-views.py')
views_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(views_module)
SCANNER_SHA256 = {
    'device-tiny-remapper.jar': '160c436c19707b4ae9e87502e5f04d733d8e09b4143735400c3464cb04163476',
    'device-asm.jar': 'b62e84b5980729751b0458c534cf1366f727542bb8d158621335682a460f0353',
    'device-asm-tree.jar': '3c33a648191079aeaeaeb7c19a49b153952f9e40fe86fbac5205554ddd9acd94',
    'device-asm-commons.jar': '72eee9fbafb9de8d9463f20dd584a48ceeb7e5152ad4c987bfbe17dd4811c9ae',
}


def fixture(entries):
    """小型输入仅用于转换边界测试；运行行为始终使用完整锁定制品和真实扫描器。"""
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w') as jar:
        jar.writestr('META-INF/MANIFEST.MF', 'Manifest-Version: 1.0\nMulti-Release: true\n\n')
        # 重复项是有意制造的负例；只在构造该夹具时收口 zipfile 的重复名称提示。
        with warnings.catch_warnings():
            warnings.filterwarnings('ignore', message='Duplicate name:', category=UserWarning)
            for name, data in entries:
                jar.writestr(name, data)
    return output.getvalue()


def rejected(entries, reason):
    """每个错误输入必须由真实转换器拒绝，而不是用独立复制的判据返回预期结果。"""
    try:
        views_module.cap_jar(fixture(entries), 17)
    except RuntimeError as error:
        assert reason in str(error), str(error)
    else:
        raise AssertionError('未拒绝错误输入：' + reason)


def offline_tests():
    """核对全槽派生配方、有效保留项与未来层范围，验证更新源后的缓存不能误复用。"""
    manifest = views_module.check_or_update()
    repeated, assets = views_module.make_views()
    assert manifest == repeated and assets == views_module.make_views()[1], '配方不可重现'
    identities = [view['manifestSha256'] for view in manifest['views']]
    assert len(set(identities)) == 3, '各 feature 的身份必须独立'
    for view in manifest['views']:
        feature = view['javaFeature']
        for item in view['jars']:
            original = ROOT / 'prebuilt/lwjgl3/jars' / item['name']
            derived = views_module.RAW_ROOT / item['resourcePath']
            with zipfile.ZipFile(original) as before, zipfile.ZipFile(derived) as after:
                expected = {name for name in before.namelist() if views_module.mr_layer(name) <= feature}
                assert set(after.namelist()) == expected, '未来子树裁剪集合错误'
                for name in expected - {'META-INF/INDEX.LIST'}:
                    assert before.read(name) == after.read(name), '可用层字节改变：' + name
                assert item['maxClassMajor'] <= feature + 44
                if item['name'] == 'lwjgl.jar':
                    assert (25 in item['mrLayers']) == (feature == 25)
                    ffm = 'META-INF/versions/25/org/lwjgl/system/MemoryBackendFFM.class'
                    assert (ffm in after.namelist()) == (feature == 25), 'JDK 25 的 FFM 被误删或泄漏'
    core = lambda feature: next(item for view in manifest['views'] if view['javaFeature'] == feature
                               for item in view['jars'] if item['name'] == 'lwjgl.jar')
    assert core(17)['resourcePath'] == core(21)['resourcePath'], '相同输出未按摘要复用'
    assert core(17)['resourcePath'] != core(25)['resourcePath']
    low_class = b'\xca\xfe\xba\xbe' + struct.pack('>HH', 0, 52)
    high_class = b'\xca\xfe\xba\xbe' + struct.pack('>HH', 0, 69)
    rejected([('org/example/A.class', high_class)], '保留类超出')
    rejected([('org/example/A.class', low_class), ('org/example/A.class', low_class)], '重复 ZIP')
    rejected([('META-INF/versions/017/A.class', low_class)], '非法 MR')
    rejected([('META-INF/versions/11/META-INF/services/example', b'value')], '不能版本化')
    rejected([('META-INF/SIGNER.SF', b'signature')], '签名输入')
    rejected([('org/example/A.class', b'bad')], '无效类头')
    preview = b'\xca\xfe\xba\xbe' + struct.pack('>HH', 65535, 61)
    rejected([('org/example/A.class', preview)], '预览字节码')
    resource_input = fixture([('versioned.txt', b'base'), ('META-INF/versions/11/versioned.txt', b'11'),
                              ('META-INF/versions/25/versioned.txt', b'25'), ('A.class', low_class)])
    data, _, _ = views_module.cap_jar(resource_input, 17)
    with zipfile.ZipFile(io.BytesIO(data)) as jar:
        assert jar.read('META-INF/versions/11/versioned.txt') == b'11'
        assert 'META-INF/versions/25/versioned.txt' not in jar.namelist()
    print('[lwjgl-jdk-views test] PASS: 全槽保留字节/可重现/独立身份/FFM/资源/畸形输入')
    return manifest


def external(directory):
    """宿主构建和收据不能回流到源码仓库，包括由 junction 指向工程的目录。"""
    result = Path(directory).resolve()
    assert not result.is_relative_to(ROOT.resolve()), '测试输出必须在仓库外'
    result.mkdir(parents=True, exist_ok=True)
    return result


def java_tests(args, manifest):
    """运行标准有效视图比较及真实旧扫描器；每条命令保存实际时间、返回码和完整输出。"""
    build = external(args.work_dir or tempfile.mkdtemp(prefix='amcl-mr-java-'))
    reports = external(args.report_dir or build)
    suffix = '.exe' if os.name == 'nt' else ''
    java = Path(args.java_home) / 'bin' / ('java' + suffix)
    javac = java.with_name('javac' + suffix)
    receipts = []

    def run(label, command, expected=0):
        started = datetime.datetime.now().astimezone().isoformat()
        process = subprocess.run([str(value) for value in command], capture_output=True, text=True,
                                 encoding='utf-8', errors='replace', timeout=60)
        output = process.stdout + process.stderr
        (reports / (label + '.txt')).write_text(output, encoding='utf-8')
        receipts.append({'label': label, 'startedAt': started,
                         'endedAt': datetime.datetime.now().astimezone().isoformat(),
                         'exitCode': process.returncode, 'expectedExitCode': expected})
        assert process.returncode == expected, label + '\n' + output
        print(label + ' PASS ' + output.splitlines()[0] if output else label + ' PASS')
        return output

    effective_source = ROOT / 'scripts/fixtures/lwjgl-mr/JarEffectiveViewProbe.java'
    run('compile-effective', [javac, '--release', '17', '-encoding', 'UTF-8', '-d', build, effective_source])
    for view in manifest['views']:
        for jar in view['jars']:
            if jar['resourcePath'].startswith('lwjgl-jdk/'):
                run('effective-' + str(view['javaFeature']) + '-' + jar['name'],
                    [java, '-cp', build, 'JarEffectiveViewProbe', ROOT / 'prebuilt/lwjgl3/jars' / jar['name'],
                     views_module.RAW_ROOT / jar['resourcePath'], view['javaFeature']])
    if args.scanner_dir:
        scanner = Path(args.scanner_dir)
        for name, digest in SCANNER_SHA256.items():
            assert views_module.sha((scanner / name).read_bytes()) == digest, '扫描器身份错误：' + name
        cp = os.pathsep.join(str(scanner / name) for name in SCANNER_SHA256)
        run('compile-scanner', [javac, '--release', '17', '-encoding', 'UTF-8', '-cp', cp, '-d', build,
                               ROOT / 'scripts/fixtures/lwjgl-mr/RemapperClasspathProbe.java'])
        cp = os.pathsep.join([str(build), cp])
        original = run('scanner-original-negative', [java, '-cp', cp, 'RemapperClasspathProbe',
                         ROOT / 'prebuilt/lwjgl3/jars/lwjgl.jar'], expected=2)
        assert 'Unsupported class file major version 71' in original, '负对照未观察已知故障'
        for view in manifest['views']:
            if view['javaFeature'] in (17, 21):
                run('scanner-selected-slot-' + str(view['javaFeature']), [java, '-cp', cp, 'RemapperClasspathProbe',
                    *[views_module.RAW_ROOT / jar['resourcePath'] for jar in view['jars']]])
    (reports / 'java-result.json').write_text(json.dumps({'scope': 'host-only; no native/game execution',
                 'receipts': receipts}, ensure_ascii=False, indent=2), encoding='utf-8')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--java-home')
    parser.add_argument('--scanner-dir')
    parser.add_argument('--work-dir')
    parser.add_argument('--report-dir')
    args = parser.parse_args()
    assert not args.scanner_dir or args.java_home, '真实扫描器需要 --java-home'
    manifest = offline_tests()
    if args.java_home:
        java_tests(args, manifest)
