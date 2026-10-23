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


def sha(data):
    """用字节摘要识别补丁状态，避免凭文件名或已应用标记放行未知源码。"""
    return hashlib.sha256(data).hexdigest()


def main():
    """仅处理 series 声明的普通源码文件；原源码和补丁任一不一致都停止构建。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--patch-dir', type=Path, required=True)
    parser.add_argument('--target', type=Path, required=True)
    args = parser.parse_args()
    target = args.target.resolve()
    patches, names = [], set()
    for line in (args.patch_dir / 'series').read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        text = (args.patch_dir / line).read_text().replace('\r\n', '\n')
        patches.append((line, text))
        for name in re.findall(r'^\+\+\+ b/([^\n\t]+)', text, re.M):
            if Path(name).is_absolute() or '..' in Path(name).parts:
                raise ValueError('补丁含越界路径')
            names.add(name)
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
            data = subprocess.check_output(['git', '-C', str(target), 'show', 'HEAD:' + name])
            p = stage / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
            states[name].add(sha(data))
        env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(stage.parent))
        for number, (name, text) in enumerate(patches):
            patch = stage / ('input-' + str(number) + '.patch')
            patch.write_text(text, encoding='utf-8', newline='\n')
            subprocess.run(['git', 'apply', '--check', str(patch)], cwd=stage, env=env, check=True)
            subprocess.run(['git', 'apply', str(patch)], cwd=stage, env=env, check=True)
            for relative in names:
                states[relative].add(sha((stage / relative).read_bytes()))
        # 先验证所有文件，全部属于受控状态后再写入，避免发现未知修改时只改了一半。
        for name in names:
            if sha((target / name).read_bytes()) not in states[name]:
                raise ValueError('源码含未知修改，保留现场：' + name)
        for name in names:
            expected = (stage / name).read_bytes()
            if (target / name).read_bytes() != expected:
                (target / name).write_bytes(expected)
        print('PASS controlled JDK series: ' + str(len(patches)) + ' patches / ' + str(len(names)) + ' files', flush=True)


if __name__ == '__main__':
    main()
