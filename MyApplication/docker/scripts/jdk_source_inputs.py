#!/usr/bin/env python3
"""补齐 Git diff 不包含的 JDK 源码输入身份；只检查消费源，不清理未知文件。

上游 make 的 FindFiles 会自动发现未跟踪甚至被忽略的源码。只校验 tracked diff
会让复用卷中的实验文件进入产品却不改变来源摘要。本模块同时核对两类额外文件，
仅允许活动 series 声明且由 applier 校验过正文的新增文件，并记录其原字节身份。
"""
import hashlib
import subprocess
from pathlib import Path


def git_paths(root, *args):
    """使用 NUL 分隔，支持空格/换行文件名，避免行解析漏掉实际输入。"""
    data = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z', *args])
    return {value.decode('utf-8', 'strict') for value in data.split(b'\0') if value}


def extra_source_inputs(root: Path, allowed: set[str]):
    """拒绝额外消费源码并返回合法 patch 新增文件摘要；不把 build 产物当源码。

    旧八代独立子仓布局与现代 src/make/test 布局均覆盖。所有普通未跟踪文件受检；
    ignored 只在上游消费目录内枚举，configure/build 的已知生成目录保持工具契约。
    允许集合不是路径放行：applier 另核已知中间状态，来源步骤记录实际每个字节。
    """
    root = root.resolve()
    roots = ('src', 'make', 'test', 'hotspot', 'jdk', 'langtools', 'nashorn',
             'jaxp', 'jaxws', 'corba', 'common')
    # 根级日志、外置测试 fixture 的 patches 等不参与 OpenJDK 编译；识别消费树中的
    # 全部文件，以及其它位置的可编译/构建源码。避免把 diagnostics.log 当污染源码。
    code_suffixes = {'.c', '.cc', '.cpp', '.cxx', '.h', '.hh', '.hpp', '.s', '.java',
                     '.gmk', '.mk', '.m4', '.sh', '.py', '.cmake'}
    ordinary = {name for name in git_paths(root, '--others', '--exclude-standard')
                if name in allowed or Path(name).parts[0] in roots or
                Path(name).suffix.lower() in code_suffixes or Path(name).name in ('Makefile', 'configure')}
    ignored = git_paths(root, '--others', '--ignored', '--exclude-standard', '--', *roots)
    extras = ordinary | ignored
    unknown = sorted(extras - allowed)
    if unknown:
        raise ValueError('JDK 源码存在未登记输入，原件保留：' + ', '.join(unknown[:24]))
    manifest = {}
    for name in sorted(extras):
        path = root / name
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
            raise ValueError('新增 JDK 源码必须为树内普通文件：' + name)
        data = path.read_bytes()
        manifest[name] = {'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
    return manifest
