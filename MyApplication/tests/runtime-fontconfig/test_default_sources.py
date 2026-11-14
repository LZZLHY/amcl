#!/usr/bin/env python3
"""验证真实锁定 Fontconfig 源片段的受控适配/复用/拒绝未知状态；所有现场保留在仓外。"""
import argparse
from datetime import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    if args.output.resolve().is_relative_to(root):
        raise ValueError('测试输出必须外置')
    args.output.mkdir(parents=True, exist_ok=False)
    spec_path = root / 'prebuilt/fontconfig/build-inputs.json'
    adaptation = json.loads((spec_path.parent / 'ohos-defaults.json').read_text())
    original = {name: subprocess.check_output(['git', '-C', str(args.source), 'show', adaptation['commit'] + ':' + name])
                for name in adaptation['before']}
    assert {name: hashlib.sha256(data).hexdigest() for name, data in original.items()} == adaptation['before']
    imported = importlib.util.spec_from_file_location('font_inputs', root / 'docker/scripts/fontconfig_inputs.py')
    module = importlib.util.module_from_spec(imported)
    imported.loader.exec_module(module)
    environment = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)
    outcomes, skipped = [], []

    def fixture(name):
        """小型 Git 夹具保存实际上游字节；假提交只服务工具分支测试，不冒充上游提交。"""
        directory = args.output / name / 'source'
        directory.mkdir(parents=True)
        for relative, data in original.items():
            path = directory / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        commands = [['git', 'init', '-q'], ['git', 'config', 'core.autocrlf', 'false'],
                    ['git', 'add', '--', *original], ['git', '-c', 'user.name=AMCL test', '-c',
                    'user.email=test@invalid', 'commit', '-qm', 'Real upstream file bytes, synthetic fixture commit']]
        for command in commands:
            subprocess.run(command, cwd=directory, env=environment, check=True, stdout=subprocess.DEVNULL)
        (directory.parent / 'evidence').mkdir()
        # 不把日志放入被核验源码树；否则入口必须把该未知 untracked 文件拒绝。
        log = args.output / (name + '.log')
        def logged_run(*command):
            with log.open('ab') as stream:
                result = subprocess.run(command, env=environment, stdout=stream, stderr=subprocess.STDOUT)
            if result.returncode:
                raise subprocess.CalledProcessError(result.returncode, command)
        module.run = logged_run
        return directory

    def apply(directory, accepted):
        """原件与所有已存在未知文件均记录；拒绝案例不得被入口静默覆盖。"""
        state = {name: (directory / name).read_bytes() for name in original}
        try:
            value = module.apply_fontconfig_defaults(directory, spec_path, directory.parent / 'evidence')
        except (ValueError, subprocess.CalledProcessError):
            if accepted:
                raise
            assert state == {name: (directory / name).read_bytes() for name in original}
            return None
        if not accepted:
            raise AssertionError('Unknown source state accepted')
        return value

    directory = fixture('first-repeat')
    record = apply(directory, True)
    apply(directory, True)
    outcomes += ['locked-source-first-apply', 'identical-repeat']
    assert record['after'] == adaptation['after']
    for name, digest in adaptation['after'].items():
        assert hashlib.sha256((directory / name).read_bytes()).hexdigest() == digest
    # 将真实 Git 原文/实际受控补后文作为独立 QA 输入；其余故障夹具不能冒充候选源。
    pairs = {}
    for variant, data in [('before', original['src/fccfg.c']),
                          ('after', (directory / 'src/fccfg.c').read_bytes())]:
        name = 'fccfg-' + variant + '.c'
        (args.output / name).write_bytes(data)
        pairs[variant] = {'file': name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
    inputs = {'schemaVersion': 1, 'kind': 'fontconfig-default-sources', 'commit': adaptation['commit'],
              'patchSha256': adaptation['patchSha256'], 'files': pairs}
    (args.output / 'default-sources.json').write_text(json.dumps(inputs, indent=2) + '\n')

    directory = fixture('unknown-tracked')
    changed = directory / 'src/fccfg.c'
    changed.write_bytes(changed.read_bytes() + b'\n/* unrelated edit preserved */\n')
    apply(directory, False); outcomes.append('unknown-tracked-preserved')
    directory = fixture('unknown-header')
    header = directory / 'src/amcl-generic-fonts.h'
    header.write_text('unknown header preserved\n')
    apply(directory, False)
    assert header.read_text() == 'unknown header preserved\n'; outcomes.append('unknown-header-preserved')
    directory = fixture('unknown-untracked')
    unknown = directory / 'src/unowned.c'
    unknown.write_text('unowned\n')
    apply(directory, False)
    assert unknown.read_text() == 'unowned\n'; outcomes.append('unknown-untracked-preserved')
    directory = fixture('header-directory')
    (directory / 'src/amcl-generic-fonts.h').mkdir()
    apply(directory, False); outcomes.append('header-directory-refused')
    directory = fixture('header-symlink')
    outside = args.output / 'outside-header'
    outside.write_text('outside preserved\n')
    try:
        (directory / 'src/amcl-generic-fonts.h').symlink_to(outside)
    except OSError as error:
        skipped.append({'case': 'header-symlink', 'reason': str(error)})
    else:
        apply(directory, False)
        assert outside.read_text() == 'outside preserved\n'; outcomes.append('symlink-refused')
    report = {'finishedAt': datetime.now().astimezone().isoformat(), 'sourceCommit': adaptation['commit'],
              'patchSha256': adaptation['patchSha256'], 'cases': outcomes, 'skipped': skipped,
              'scope': 'source transformation only; no target provider execution'}
    (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS controlled Fontconfig defaults:', len(outcomes), 'cases;', len(skipped), 'not covered')


if __name__ == '__main__':
    main()
