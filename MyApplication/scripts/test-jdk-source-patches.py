#!/usr/bin/env python3
"""通过真实临时 Git 仓验证 JDK series 的新增文件与拒绝覆盖契约。

测试输出必须由调用者指定在仓外；不改用户 Git 配置，不清理失败现场。
每个拒绝案例同时核对旧文件未被部分修改，防止仅看到非零退出就误判成功。
"""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    """创建独立案例并保存命令输出，目录已存在时拒绝覆盖上一轮证据。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    root = Path(__file__).resolve().parents[1]
    if output.is_relative_to(root):
        raise ValueError('Test output must be outside the source repository')
    output.mkdir(parents=True, exist_ok=False)
    runner = root / 'docker/scripts/apply_jdk_patches.py'
    environment = dict(os.environ, PYTHONUTF8='1', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)
    results = []

    def command(cwd, *arguments, expected=0):
        """记录完整 stdout/stderr；失败退出码和预期结果必须逐次匹配。"""
        result = subprocess.run(arguments, cwd=cwd, env=environment, text=True,
                                encoding='utf-8', errors='replace', capture_output=True)
        with (cwd / 'commands.log').open('a', encoding='utf-8') as log:
            log.write(repr(arguments) + '\n' + result.stdout + result.stderr + '\n')
        if expected is not None:
            assert result.returncode == expected, result.stdout + result.stderr
        return result

    def fixture(name):
        """两份补丁先新增再修改同一文件，覆盖以往 reverse-check 处理不了的状态。"""
        directory = output / name
        directory.mkdir()
        command(directory, 'git', 'init', '-q')
        command(directory, 'git', 'config', 'core.autocrlf', 'false')
        # Git 对象正文使用上游源码的 LF；Windows 工作树的等价 CRLF 由后续案例
        # 独立覆盖，不能在 core.autocrlf=false 时误把 CRLF 固化到模拟上游提交。
        (directory / 'existing.c').write_bytes(b'int value = 1;\n')
        command(directory, 'git', 'add', '--', 'existing.c')
        command(directory, 'git', '-c', 'user.name=AMCL source tests', '-c', 'user.email=tests@invalid',
                'commit', '-qm', 'Recorded test fixture, not an upstream commit')
        patches = directory / 'patches'
        patches.mkdir()
        (patches / 'series').write_text('one.patch\ntwo.patch\n')
        (patches / 'one.patch').write_text('''diff --git a/existing.c b/existing.c
--- a/existing.c
+++ b/existing.c
@@ -1 +1 @@
-int value = 1;
+int value = 2;
diff --git a/new/service.c b/new/service.c
new file mode 100644
--- /dev/null
+++ b/new/service.c
@@ -0,0 +1 @@
+int service = 3;
''')
        (patches / 'two.patch').write_text('''diff --git a/new/service.c b/new/service.c
--- a/new/service.c
+++ b/new/service.c
@@ -1 +1 @@
-int service = 3;
+int service = 4;
''')
        return directory, patches

    def apply(directory, patches, accepted):
        result = command(directory, sys.executable, '-B', str(runner), '--target', str(directory),
                         '--patch-dir', str(patches), expected=None)
        assert (result.returncode == 0) == accepted, result.stdout + result.stderr
        return result

    directory, patches = fixture('first-and-repeat')
    apply(directory, patches, True)
    assert (directory / 'existing.c').read_text() == 'int value = 2;\n'
    assert (directory / 'new/service.c').read_text() == 'int service = 4;\n'
    apply(directory, patches, True)
    results += ['new-file-and-overlapping-followup', 'identical-repeat']

    directory, patches = fixture('known-intermediate')
    (directory / 'new').mkdir()
    (directory / 'new/service.c').write_text('int service = 3;\n')
    apply(directory, patches, True)
    assert (directory / 'new/service.c').read_text() == 'int service = 4;\n'
    results.append('known-intermediate-new-file')

    for label, content in [('unknown-existing', 'unowned source\n'), ('empty-is-not-absent', '')]:
        directory, patches = fixture(label)
        (directory / 'new').mkdir()
        (directory / 'new/service.c').write_text(content)
        apply(directory, patches, False)
        assert (directory / 'existing.c').read_text() == 'int value = 1;\n'
        assert (directory / 'new/service.c').read_text() == content
        results.append(label + '-refused-without-partial-write')

    directory, patches = fixture('unknown-tracked')
    (directory / 'existing.c').write_text('int value = 91;\n')
    apply(directory, patches, False)
    assert not (directory / 'new/service.c').exists()
    results.append('unknown-tracked-refused-without-new-file')

    # OpenJDK按目录发现源码，Git未跟踪/忽略均不能作为编译输入隐身。用真实Git忽略
    # 规则和带空格路径验证，且拒绝发生在任何正式patch写入之前，原未知字节仍保留。
    for label, ignored in [('extra-source', False), ('ignored-source', True)]:
        directory, patches = fixture(label)
        extra = directory / 'src/java.base/share/native/extra input.cpp'
        extra.parent.mkdir(parents=True)
        extra.write_bytes(b'int hidden_input = 91;\n')
        if ignored: (directory / '.gitignore').write_text('src/**/*.cpp\n')
        rejection = apply(directory, patches, False)
        assert 'extra input.cpp' in rejection.stderr + rejection.stdout
        assert (directory / 'existing.c').read_bytes() == b'int value = 1;\n'
        assert extra.read_bytes() == b'int hidden_input = 91;\n'
        assert not (directory / 'new/service.c').exists()
        results.append(label + '-refused-before-patch-with-bytes-preserved')

    directory, patches = fixture('directory-not-file')
    (directory / 'new/service.c').mkdir(parents=True)
    apply(directory, patches, False)
    assert (directory / 'existing.c').read_text() == 'int value = 1;\n'
    results.append('directory-refused')

    directory, patches = fixture('deletion-not-supported')
    (patches / 'series').write_text('delete.patch\n')
    (patches / 'delete.patch').write_text('''diff --git a/existing.c b/existing.c
deleted file mode 100644
--- a/existing.c
+++ /dev/null
@@ -1 +0,0 @@
-int value = 1;
''')
    apply(directory, patches, False)
    assert (directory / 'existing.c').read_text() == 'int value = 1;\n'
    results.append('deletion-refused')

    # 创建 symlink 可能需要 Windows 开发者模式。若环境不允许，报告明确未覆盖，
    # 不能把创建失败当成源码入口已经拒绝链接；Linux CI 应完整执行此案例。
    skipped = []
    directory, patches = fixture('symlink-outside')
    outside = output / 'outside.c'
    outside.write_text('external preserved\n')
    (directory / 'new').mkdir()
    try:
        (directory / 'new/service.c').symlink_to(outside)
    except OSError as error:
        skipped.append({'case': 'symlink-outside', 'reason': str(error)})
    else:
        apply(directory, patches, False)
        assert outside.read_text() == 'external preserved\n'
        assert (directory / 'existing.c').read_text() == 'int value = 1;\n'
        results.append('symlink-refused')
    report = {'passed': True, 'timestamp': datetime.now().astimezone().isoformat(),
              'cases': results, 'skipped': skipped}
    (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('JDK source patch tests PASS:', len(results), 'cases;', len(skipped), 'not covered')


if __name__ == '__main__':
    main()
