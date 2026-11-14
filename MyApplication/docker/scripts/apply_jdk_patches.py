#!/usr/bin/env python3
"""按固定 base 重放完整 JDK patch series，安全识别后续 patch 修改早期 patch 的情况。

逐个 reverse-check 不能识别重叠补丁的最终状态。本入口在独立临时目录从 Git
base 取出受影响文件并重放；现有源文件只有属于该 series 的已知中间状态时才更新。
未知修改立即拒绝，既不 reset/clean，也不覆盖用户独有内容。
"""
import argparse
import hashlib
import os
import re
import subprocess
import tempfile
from pathlib import Path
from jdk_source_inputs import extra_source_inputs


def sha(data):
    """比较源码正文时允许 Git 的 CRLF 检出转换；不放宽任何语义字节。

    Windows 全局 core.autocrlf 曾使无仓临时目录中的 git apply 写出 CRLF。
    最终重放显式使用 LF；这里只接纳等价换行，未知代码仍然立即拒绝。
    """
    # None 是“文件明确缺席”，不能与空文件的摘要混同；新增上游文件可从这个
    # 状态进入受控 series，但未知未跟踪文件即使同名也不能被覆盖。
    return None if data is None else hashlib.sha256(data.replace(b'\r\n', b'\n')).hexdigest()


def source_bytes(root, name):
    """只读取树内普通文件或明确缺席，拒绝符号链接/目录伪装新增源码。"""
    path = root / name
    if path.is_symlink() or not path.resolve().is_relative_to(root):
        raise ValueError('补丁目标包含符号链接或逃逸路径：' + name)
    if not path.exists():
        return None
    if not path.is_file():
        raise ValueError('补丁目标不是普通文件：' + name)
    return path.read_bytes()


def base_bytes(root, name):
    """用 Git 树确认真实基线类型；只有树中无该路径才可记为缺席。"""
    entry = subprocess.check_output(['git', '-C', str(root), 'ls-tree', '-z', 'HEAD', '--', name])
    if not entry:
        return None
    mode, kind, _ = entry.split(b'\t', 1)[0].split()
    if mode not in (b'100644', b'100755') or kind != b'blob':
        raise ValueError('补丁基线不是普通源码：' + name)
    return subprocess.check_output(['git', '-C', str(root), 'show', 'HEAD:' + name])


def main():
    """仅处理 series 声明的普通源码文件；原源码和补丁任一不一致都停止构建。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--patch-dir', type=Path, required=True)
    parser.add_argument('--target', type=Path, required=True)
    args = parser.parse_args()
    target = args.target.resolve()
    subprocess.run(['git', '-C', str(target), 'rev-parse', '--verify', 'HEAD^{commit}'],
                   stdout=subprocess.DEVNULL, check=True)
    patches, names = [], set()
    for line in (args.patch_dir / 'series').read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        text = (args.patch_dir / line).read_text().replace('\r\n', '\n')
        # 当前配方只需要修改和新增普通源码。删除、符号链接或二进制补丁不得
        # 混入本入口后绕开已知状态校验；后续需要这些操作时必须独立审查契约。
        if re.search(r'^\+\+\+ /dev/null$|^(?:new|old) mode 120000$|^new file mode 120000$|^GIT binary patch$', text, re.M):
            raise ValueError('series 包含未支持的删除、链接或二进制补丁：' + line)
        patches.append((line, text))
        for name in re.findall(r'^\+\+\+ b/([^\n\t]+)', text, re.M):
            if Path(name).is_absolute() or '..' in Path(name).parts:
                raise ValueError('补丁含越界路径')
            names.add(name)
    # 在任何写入前拒绝 FindFiles 可消费的未知新增源码；不删除或忽略复用卷中的独有字节。
    extra_source_inputs(target, names)
    changed = subprocess.check_output(['git', '-C', str(target), 'diff', '--name-only', 'HEAD'], text=True).splitlines()
    for name in set(changed) - names:
        # configure 会修正 config.guess 的 executable 位；字节相同的模式变化不冒充源码修改。
        original = subprocess.check_output(['git', '-C', str(target), 'show', 'HEAD:' + name])
        if (target / name).read_bytes() != original:
            raise ValueError('源码存在 series 范围外的内容修改：' + name)
    with tempfile.TemporaryDirectory(prefix='jdk-series-', dir=target.parent) as temporary:
        stage = Path(temporary)
        states = {name: set() for name in names}
        for name in names:
            data = base_bytes(target, name)
            p = stage / name
            if data is not None:
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(data)
            states[name].add(sha(data))
        env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(stage.parent))
        for number, (name, text) in enumerate(patches):
            patch = stage / ('input-' + str(number) + '.patch')
            patch.write_text(text, encoding='utf-8', newline='\n')
            git_apply = ['git', '-c', 'core.autocrlf=false', '-c', 'core.eol=lf', 'apply']
            subprocess.run([*git_apply, '--check', str(patch)], cwd=stage, env=env, check=True)
            subprocess.run([*git_apply, str(patch)], cwd=stage, env=env, check=True)
            for relative in names:
                states[relative].add(sha(source_bytes(stage, relative)))
        # 先验证所有文件，全部属于受控状态后再写入，避免发现未知修改时只改了一半。
        for name in names:
            if sha(source_bytes(target, name)) not in states[name]:
                raise ValueError('源码含未知修改，保留现场：' + name)
        for name in names:
            expected = (stage / name).read_bytes()
            if source_bytes(target, name) != expected:
                (target / name).parent.mkdir(parents=True, exist_ok=True)
                (target / name).write_bytes(expected)
        print('PASS controlled JDK series: ' + str(len(patches)) + ' patches / ' + str(len(names)) + ' files', flush=True)


if __name__ == '__main__':
    main()
