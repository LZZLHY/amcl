"""在WSL编译运行真实Native政策实现；输出必须显式落到外部任务目录，不编译整个应用。"""
import argparse
from pathlib import Path, PureWindowsPath
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def linux(path):
    """只转换实际绝对Windows路径；不把路径插进shell字符串或跨shell拼接命令。"""
    value = PureWindowsPath(str(path.resolve()))
    return '/mnt/' + value.drive[0].lower() + '/' + '/'.join(value.parts[1:])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    if not args.output.is_absolute() or output.is_relative_to(ROOT):
        raise ValueError('测试输出必须是仓库外绝对目录')
    output.mkdir(parents=True, exist_ok=True)
    fixture = output / 'policy-files'
    fixture.mkdir(exist_ok=True)
    binary = output / 'mod-audio-policy-test'
    cpp = ROOT / 'entry/src/main/cpp'
    subprocess.run(['wsl.exe', '--exec', 'g++', '-std=c++17', '-DNDEBUG', '-pthread', '-Wall', '-Wextra',
                    '-I' + linux(cpp / 'tests/host/mod-audio-sdk-stub'),
                    linux(cpp / 'audio_host_policy.cpp'), linux(cpp / 'tests/host/mod_audio_policy_test.cpp'),
                    '-o', linux(binary)], check=True)
    for case in ('local', 'missing', 'off-on', 'epoch', 'empty', 'zero', 'overflow', 'trailing', 'flag', 'negative'):
        subprocess.run(['wsl.exe', '--exec', linux(binary), linux(fixture), case], check=True, timeout=30)


if __name__ == '__main__':
    main()
