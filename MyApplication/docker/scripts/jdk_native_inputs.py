#!/usr/bin/env python3
"""锁定 JDK 真正消费的目标 SDK，并复制为本次只读构建输入。

sysroot 的三个哨兵只能检测少量漂移，不能代表 C++ 头、ABI 库和 compiler-rt。
这里枚举实际目标输入；复制时核对清单摘要，拒绝预检后的变化。宿主编译器与
boot JDK 由不可变 Docker image ID 绑定，不从宿主 PATH 猜测供应者。
"""
import hashlib
import re
from pathlib import Path


def digest(path):
    """流式计算摘要，避免完整 SDK 库同时进入 Python 内存。"""
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def native_inputs(sysroot):
    """从标准 native/sysroot 布局取得同一 SDK 的头、共享 ABI 与目标运行库。"""
    native = Path(sysroot).resolve().parent
    include = native / 'llvm/include/libcxx-ohos/include/c++/v1'
    config = include / '__config_site'
    if not config.is_file() or not re.search(
            r'^\s*#\s*define\s+_LIBCPP_ABI_NAMESPACE\s+__n1\s*$', config.read_text(), re.M):
        raise ValueError('JDK requires the application SDK libc++ __n1 headers')
    versions = list((native / 'llvm/lib/clang').glob('*/lib/aarch64-linux-ohos/libclang_rt.builtins.a'))
    if len(versions) != 1:
        raise ValueError('Expected exactly one target compiler-rt input in selected native SDK')
    resource = versions[0].parents[2]
    required = [native / 'oh-uni-package.json', native / 'NOTICE.txt',
                native / 'llvm/lib/aarch64-linux-ohos/libc++_shared.so',
                versions[0], versions[0].parent / 'clang_rt.crtbegin.o',
                versions[0].parent / 'clang_rt.crtend.o']
    for path in required:
        if not path.is_file():
            raise ValueError('Missing target SDK input: ' + str(path))
    files = set(required)
    for directory in (native / 'sysroot', include, resource / 'include'):
        if not directory.is_dir():
            raise ValueError('Missing target SDK directory: ' + str(directory))
        files.update(path for path in directory.rglob('*') if path.is_file())
    # 链接的最终目标仍须属于该 SDK，不能收进任意宿主路径。
    for path in files:
        if not path.resolve().is_relative_to(native):
            raise ValueError('Target SDK link escapes selected native root: ' + str(path))
    return {'root': str(native), 'resourceVersion': resource.name,
            'files': {path.relative_to(native).as_posix(): digest(path) for path in sorted(files)}}


def freeze_files(root, expected, destination):
    """逐文件独占创建快照并读回核对；失败保留现场而不替换旧快照。"""
    root, destination = Path(root).resolve(), Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    for name, sha in sorted(expected.items()):
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Invalid frozen input path: ' + name)
        source, target = root / relative, destination / relative
        if not source.resolve().is_relative_to(root):
            raise ValueError('Frozen input escapes its root: ' + name)
        target.parent.mkdir(parents=True, exist_ok=True)
        with source.open('rb') as incoming, target.open('xb') as outgoing:
            while chunk := incoming.read(1024 * 1024):
                outgoing.write(chunk)
        if digest(target) != sha:
            raise ValueError('Input changed while freezing: ' + name)
