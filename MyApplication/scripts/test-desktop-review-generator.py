"""校验桌面回归生成器的精确 hunk 偏移及真实 SDL 补丁链，所有输出位于系统临时目录。

默认从现役 series 重放稀疏源并生成/执行三个 SDL 宿主目标；--repo 显式提供只读 SDL
仓库时，再从 deps.lock pin 导出被补丁引用的原始文件，以真正的 git apply 逐个重放，
逐已知行核对生成器结果。此测试不修改 SDL checkout、patch 或 pin，也不构建 HAP。
"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import argparse
import re
import runpy
import subprocess
import tempfile
from lib.host_cpp import compile_cpp

root = Path(__file__).resolve().parent.parent
generator = runpy.run_path(str(root / 'scripts/generate-desktop-review-tests.py'))
locate = generator['locate_hunk']


def rejected(old, before, cursor=0):
    """负例须明确失败；不能把无匹配/多匹配/未知上下文变成忽略该 hunk。"""
    try:
        locate(old, before, 0, cursor, 'negative-fixture')
    except ValueError:
        return
    raise AssertionError('invalid hunk location accepted')


def verify_offsets():
    """偏移正控保持逐字匹配，反例覆盖重复、变化、空白和稀疏未知行。"""
    assert locate(['old line', 'a', 'b'], ['a', 'b'], 0, 0, 'offset') == 1
    assert locate(['a', 'b'], ['a', 'b'], 0, 0, 'unchanged') == 0
    # 上一 hunk 已合法右移时，下一段声明行号可能落在已消费区；真实唯一正文仍可前移定位。
    assert locate(['x', 'x', 'x', 'a', 'b'], ['a', 'b'], 2, 3, 'continued-offset') == 3
    rejected(['old line', 'a', 'b', 'separator', 'a', 'b'], ['a', 'b'])
    rejected(['old line', 'a', 'changed'], ['a', 'b'])
    rejected(['old line', ' a', 'b'], ['a', 'b'])
    rejected(['old line', 'a', None], ['a', 'b'])
    rejected(['old line', None, None], ['a', 'b'])
    rejected(['old line', 'a', 'b'], ['a', 'b'], cursor=2)
    rejected(['old line'], [], cursor=1)


def replay_pinned(repo, output):
    """只读 Git 对象，在临时目录应用现役完整 series；显式仓库缺 pin 或坏补丁直接失败。"""
    lock = (root / 'deps.lock').read_text(encoding='utf-8')
    match = re.search(r'^\[sdl3-native\]\s*$[\s\S]*?^commit\s*=\s*([a-f0-9]{40})', lock, re.M)
    assert match is not None, 'missing pinned SDL commit'
    pin = match[1]
    subprocess.run(['git', '-C', str(repo), 'cat-file', '-e', pin + '^{commit}'], check=True)
    folder = root / 'prebuilt/sdl3/patches'
    series = [line.strip() for line in (folder / 'series').read_text(encoding='utf-8').splitlines()
              if line.strip() and not line.lstrip().startswith('#')]
    paths = sorted(set(name for patch in series for name in re.findall(
        r'^--- a/(.+)$', (folder / patch).read_text(encoding='utf-8'), re.M)))
    output.mkdir()
    copied = 0
    for name in paths:
        target = (output / name).resolve()
        assert target.is_relative_to(output.resolve()), 'patch source path escapes temporary directory'
        content = subprocess.run(['git', '-C', str(repo), 'show', pin + ':' + name], capture_output=True)
        if content.returncode:
            # 前序 patch 新建的文件在上游 pin 中没有 blob；稍后的真实 git apply 必须创建它。
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content.stdout)
        copied += 1
    assert copied > 0, 'no pinned original files loaded'
    for patch in series:
        subprocess.run(['git', 'apply', '--check', str(folder / patch)], cwd=output, check=True)
        subprocess.run(['git', 'apply', str(folder / patch)], cwd=output, check=True)
    print(f'PASS pinned SDL replay: commit={pin} originals={copied} patches={len(series)}')


parser = argparse.ArgumentParser()
parser.add_argument('--repo', type=Path, help='只读 SDL 仓库；显式输入不允许回退或跳过')
args = parser.parse_args()
verify_offsets()
with workspace_temporary_directory(prefix='amcl-desktop-generator-') as directory:
    temporary = Path(directory)
    applied = None
    if args.repo:
        applied = temporary / 'sdl'
        replay_pinned(args.repo.resolve(), applied)
    generated = temporary / 'generated'
    generator['generate'](generated, applied)
    for unit in ['sdl_profile', 'sdl_owner', 'sdl_hide']:
        binary = temporary / (unit + '.exe')
        compile_cpp(generated / (unit + '.cpp'), binary, defines=['AMCL_NATIVE_DESKTOP_ONLY=0'])
        subprocess.run([str(binary)], check=True, timeout=20)
        print('PASS amcl_review_' + unit + '_test')
print('PASS desktop review generator: exact offsets, ambiguous/changed/unknown context rejection and actual SDL host assertions')
