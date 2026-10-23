#!/usr/bin/env python3
"""校验JDK25真实安全点源码，阻止历史绕过以换名补丁或生成器修改的方式回生。

本轮最小修复要求两个安全点文件保持锁定上游原字节。守卫在应用series后、编译前
以及记录构建来源前各执行一次；不修改源码，不通过“有NONE字符串”接纳条件分支绕过。
其他JDK版本不调用本入口，未来确需改动这两个文件时必须先重新审查本契约。
"""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path


SAFEPOINT_FILES = (
    'src/hotspot/share/runtime/safepointMechanism.cpp',
    'src/hotspot/os_cpu/linux_aarch64/os_linux_aarch64.cpp',
)
RETIRED_PREFIXES = ('0006-', '0007-')


def verify_generator_contract(generator):
    """检查现有生成器的Python编辑块和补丁输出，拒绝重新生成两个历史安全点绕过。

这里只约束本仓生成器的已知结构，不充当通用Shell解释器；编译前的完整源码比较
仍是最终裁决。编译Python块但不执行，避免静态检查修改外部JDK工作树。
"""
    text = Path(generator).read_text(encoding='utf-8')
    for index, block in enumerate(re.findall(r"python3 << 'PYEOF'\n(.*?)\nPYEOF", text, re.S)):
        compile(block, str(generator) + ':python-block-' + str(index), 'exec')
        if any(relative in block for relative in SAFEPOINT_FILES):
            raise ValueError('JDK25生成器重新编辑了上游安全点文件')
    if re.search(r'git diff\s*>[^\n]*(?:0006|0007)-', text):
        raise ValueError('JDK25生成器重新输出了已退役安全点补丁')
    # 旧的最终枚举也会把上次输出中的历史文件应用回来，不能只删生成块。
    for match in re.finditer(r'^for p in ([^;\n]+); do', text, re.M):
        if {'0006', '0007'} & set(match.group(1).split()):
            raise ValueError('JDK25生成器仍枚举已退役安全点补丁')


def active_patches(patch_dir):
    """读取唯一活动清单并拒绝越界/重复条目；留存历史文件本身不代表仍在应用。"""
    names = []
    for raw in (Path(patch_dir) / 'series').read_text(encoding='utf-8').splitlines():
        name = raw.strip()
        if not name or name.startswith('#'):
            continue
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts or name in names:
            raise ValueError('JDK25 series存在越界或重复条目：' + name)
        if name.startswith(RETIRED_PREFIXES):
            raise ValueError('JDK25活动series重新启用了已退役安全点补丁：' + name)
        if not (Path(patch_dir) / name).is_file():
            raise ValueError('JDK25活动补丁缺失：' + name)
        names.append(name)
    if not names:
        raise ValueError('JDK25活动series为空，不能跳过必要兼容补丁')
    return names


def verify_source_bytes(source, originals):
    """比对两个完整文件而非局部标记，拒绝条件编译、换名补丁和保留NONE的旁路修改。

originals只由已核验HEAD的git show取得；独立回归可用同一真实上游正文重放旧补丁。
源码使用LF是上游契约，读写均不做规范化，避免把真实修改隐藏为换行修复。
"""
    digests = {}
    for relative in SAFEPOINT_FILES:
        actual = (Path(source) / relative).read_bytes()
        expected = originals[relative]
        if actual != expected:
            raise ValueError('JDK25安全点源码偏离锁定上游，禁止绕过轮询：' + relative)
        digests[relative] = hashlib.sha256(actual).hexdigest()
    return digests


def verify_source_contract(source, patch_dir, inputs):
    """绑定正式源码锁与真实Git HEAD，返回可写入来源收据的只读证据。

只允许固定官方25输入；HEAD不符、关键文件缺失或任何完整正文变化均失败关闭。
目录名、注释或旧patch存在不能替代已经应用series后的真实源码检查。
"""
    source = Path(source).resolve()
    item = json.loads(Path(inputs).read_text(encoding='utf-8'))['runtimes']['25']
    expected_head = item['commit']
    if item['repository'] != 'https://github.com/openjdk/jdk25u.git' or not re.fullmatch(r'[0-9a-f]{40}', expected_head):
        raise ValueError('JDK25源码锁不是受审官方仓库或完整commit')
    head = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if head != expected_head:
        raise ValueError('JDK25安全点检查的HEAD与源码锁不一致')
    names = active_patches(patch_dir)
    originals = {relative: subprocess.check_output(['git', '-C', str(source), 'show', 'HEAD:' + relative])
                 for relative in SAFEPOINT_FILES}
    digests = verify_source_bytes(source, originals)
    return {'contract': 'jdk25-upstream-safepoint-v1', 'head': head,
            'activePatches': names, 'sourceSha256': digests}


def main():
    """供构建配方和人工定向检查调用；只输出校验身份，不产生临时源码或编译产物。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--patch-dir', type=Path, required=True)
    parser.add_argument('--inputs', type=Path, required=True)
    args = parser.parse_args()
    evidence = verify_source_contract(args.source, args.patch_dir, args.inputs)
    print('PASS JDK25 upstream safepoint source: ' + json.dumps(evidence, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
