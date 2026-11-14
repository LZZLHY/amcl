#!/usr/bin/env python3
"""验证宿主工具复用时的正文身份，并对真实已下载工具归档做首次/重复展开。

故障只施加到本轮外部测试树；检查失败后原修改仍保留，确保入口没有静默修复
或删除用户状态。此测试不下载/执行 Meson 或 gperf，不建立额外容器。
"""
import argparse
from datetime import datetime
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import zipfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--meson-wheel', type=Path, required=True)
    parser.add_argument('--gperf-source', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    path = Path(__file__).resolve().parents[2] / 'docker/scripts/fontconfig_inputs.py'
    spec = importlib.util.spec_from_file_location('fontconfig_inputs', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    results = []

    def refuse(action, label):
        """只收预期 ValueError；无关异常、意外成功都使测试失败。"""
        try:
            action()
        except ValueError:
            results.append(label)
        else:
            raise AssertionError('Unexpectedly accepted: ' + label)

    wheel = args.output / 'example.whl'
    with zipfile.ZipFile(wheel, 'w') as archive:
        archive.writestr('package/tool.py', 'print("recorded source")\n')
    for change in ('modified', 'missing', 'extra'):
        target = args.output / change
        module.extract_meson(wheel, target)
        module.extract_meson(wheel, target)
        member = target / 'package/tool.py'
        if change == 'modified':
            member.write_text('preserve this unexpected edit\n')
        elif change == 'missing':
            # 这里只删除上面本测试刚写的单个已知文件，没有递归或用户源码路径。
            member.unlink()
        else:
            (target / 'package/unknown.py').write_text('unexpected source\n')
        refuse(lambda: module.extract_meson(wheel, target), 'wheel-' + change + '-refused')
        if change == 'modified':
            assert member.read_text() == 'preserve this unexpected edit\n'
        elif change == 'missing':
            assert not member.exists()
        else:
            assert (target / 'package/unknown.py').exists()
    results.append('wheel-identical-repeat-and-preserved-failure-state')
    for index, name in enumerate(('../escape.py', '/absolute.py', 'back\\slash.py')):
        bad = args.output / ('bad-' + str(index) + '.whl')
        with zipfile.ZipFile(bad, 'w') as archive:
            # Windows 的 ZipInfo 构造器会自动把反斜杠正规化。明确在构造后
            # 设置原始 filename，保证负例归档本身确实保留待拒绝的字节。
            entry = zipfile.ZipInfo('placeholder')
            entry.filename = name
            archive.writestr(entry, 'bad')
        refuse(lambda: module.extract_meson(bad, args.output / ('bad-' + str(index))),
               'wheel-path-' + str(index) + '-refused-before-extraction')

    archive_path = args.output / 'example.tar.gz'
    with tarfile.open(archive_path, 'w:gz') as archive:
        entry = tarfile.TarInfo('gperf-test/tool.c')
        contents = b'int main(void) { return 0; }\n'
        entry.size = len(contents)
        archive.addfile(entry, io.BytesIO(contents))
    target = args.output / 'gperf-synthetic'
    target.mkdir()
    module.extract_gperf(archive_path, target, 'gperf-test')
    module.extract_gperf(archive_path, target, 'gperf-test')
    (target / 'gperf-test/tool.c').write_text('preserve this unexpected C edit\n')
    refuse(lambda: module.extract_gperf(archive_path, target, 'gperf-test'), 'gperf-modified-refused')
    assert (target / 'gperf-test/tool.c').read_text() == 'preserve this unexpected C edit\n'
    results.append('gperf-identical-repeat-and-preserved-failure-state')

    # 使用真实且已锁定 SHA 的工具归档，避免安全检查误拒绝合法上游布局。
    locked = json.loads((path.parents[2] / 'prebuilt/fontconfig/build-inputs.json').read_text())
    assert module.hashlib.sha256(args.meson_wheel.read_bytes()).hexdigest() == locked['meson']['sha256']
    assert module.hashlib.sha256(args.gperf_source.read_bytes()).hexdigest() == locked['gperf']['sha256']
    module.extract_meson(args.meson_wheel, args.output / 'real-meson')
    module.extract_meson(args.meson_wheel, args.output / 'real-meson')
    module.extract_gperf(args.gperf_source, args.output, 'gperf-' + locked['gperf']['version'])
    module.extract_gperf(args.gperf_source, args.output, 'gperf-' + locked['gperf']['version'])
    results += ['real-meson-first-and-repeat', 'real-gperf-first-and-repeat']
    report = {'passed': True, 'finishedAt': datetime.now().astimezone().isoformat(), 'cases': results,
              'qualification': 'host source integrity only; target binaries were not executed'}
    (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS font tool source reuse:', len(results), 'cases')


if __name__ == '__main__':
    main()
