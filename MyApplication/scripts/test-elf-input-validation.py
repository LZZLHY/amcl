"""编译并执行产品 ELF 输入纯核心；可对显式提供的 JDK ZIP 做只读结构兼容性检查。

本脚本不执行 ARM64 文件、不解压/覆盖发布包、不触碰设备。ZIP 里的每个 .so/.so.数字
成员都交给同一宿主探针检查，并输出输入 ZIP 的 SHA-256 供与发布锁对齐；哈希相等须由
调用方核验。ZIP 成员不是已装载的 image，结构通过不等于 JDK 运行通过。
临时目录只保存本次编译产物，退出后清理。
"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import argparse
import hashlib
import os
import re
import subprocess
import tempfile
import zipfile
from lib.host_cpp import compile_cpp


def main():
    """始终运行负例；只有显式指定 --jdk-zip 才消费本地发布包，任一错误直接失败。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jdk-zip', action='append', type=Path, default=[])
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    source = root / 'entry/src/main/cpp/tests/host/elf_input_validation_test.cpp'
    with workspace_temporary_directory(prefix='amcl-elf-input-') as directory:
        binary = Path(directory) / ('test.exe' if os.name == 'nt' else 'test')
        compile_cpp(source, binary)
        subprocess.run([str(binary)], check=True, timeout=20)
        for archive in args.jdk_zip:
            with archive.open('rb') as source_zip:
                digest = hashlib.file_digest(source_zip, 'sha256').hexdigest()
            count = 0
            with zipfile.ZipFile(archive) as package:
                for entry in package.infolist():
                    # libfontconfig.so.1、libfreetype.so.6 等版本化文件同样会被加载。
                    # 只按共享库成员名筛选，避免为探测 magic 额外读取庞大的 lib/modules。
                    if not re.search(r'\.so(?:\.\d+)*$', entry.filename):
                        continue
                    result = subprocess.run([str(binary), '--stdin'], input=package.read(entry),
                                            capture_output=True, timeout=30)
                    if result.returncode != 0:
                        raise RuntimeError(f'{archive.name}/{entry.filename}: {result.stderr.decode(errors="replace")}')
                    count += 1
            if count == 0:
                raise RuntimeError(f'No .so inputs found in {archive}')
            print(f'PASS {archive.name}: {count} ELF inputs; sha256={digest}', flush=True)


if __name__ == '__main__':
    main()
