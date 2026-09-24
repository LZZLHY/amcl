"""编译并执行独立游戏退出纯核心；POSIX 主机同时执行真实 fd/flock/退出子进程测试。

Windows 不伪称覆盖 POSIX：明确输出 SKIP。所有编译产物都在本次专用临时目录中。
测试子进程只用它自己创建的临时文件；不访问游戏数据、不操作设备、不构建 HAP。
"""
from pathlib import Path
import os
import subprocess
import tempfile
from lib.host_cpp import compile_cpp


def main():
    """直接编译生产核心；失败由返回码传播，不用正则源码匹配代替行为测试。"""
    root = Path(__file__).resolve().parent.parent
    targets = ['game_process_exit_test.cpp']
    if os.name != 'nt':
        targets.append('game_process_exit_posix_test.cpp')
    with tempfile.TemporaryDirectory(prefix='amcl-game-exit-') as directory:
        for name in targets:
            binary = Path(directory) / (Path(name).stem + ('.exe' if os.name == 'nt' else ''))
            compile_cpp(root / 'entry/src/main/cpp/tests/host' / name, binary)
            subprocess.run([str(binary)], check=True, timeout=30)
    if os.name == 'nt':
        print('SKIP POSIX fd/flock/exit integration on Windows; run this script on a POSIX host.', flush=True)


if __name__ == '__main__':
    main()
