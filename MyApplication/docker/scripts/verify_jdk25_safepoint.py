#!/usr/bin/env python3
"""校验现代 JDK 的安全点与普通信号入口，阻止历史协议绕过回生。

文件名和缺省主版本保留为 25，兼容已经登记的构建和独立检查入口；--major 显式
选择 17、21 或 25。三个版本分别比较自己的锁定上游，绝不互相复制源文件。
守卫在完整 series 重放后、编译前及来源落盘前执行，不修改源码。安全点坏页、
AArch64 信号处理及普通信号 wrapper 均保持受审上游原字节；搜到 NONE 或删除
某个旧编号不足以证明协议恢复。JDK8 的实现不同，不机械套用此契约。
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
    'src/hotspot/os/posix/signals_posix.cpp',
)
RETIRED_PREFIXES = ('0005-', '0006-', '0007-')
SUPPORTED_MAJORS = ('17', '21', '25')


def verify_generator_contract(generator, major='25'):
    """检查现有生成器的Python编辑块和补丁输出，拒绝重新生成两个历史安全点绕过。

这里只约束本仓生成器的已知结构，不充当通用Shell解释器；编译前的完整源码比较
仍是最终裁决。编译Python块但不执行，避免静态检查修改外部JDK工作树。
"""
    text = Path(generator).read_text(encoding='utf-8')
    for index, block in enumerate(re.findall(r"python3 << 'PYEOF'\n(.*?)\nPYEOF", text, re.S)):
        compile(block, str(generator) + ':python-block-' + str(index), 'exec')
        if any(relative in block for relative in SAFEPOINT_FILES):
            raise ValueError('JDK' + major + '生成器重新编辑了上游安全点或信号文件')
    if re.search(r'git diff\s*>[^\n]*(?:0005|0006|0007)-', text):
        raise ValueError('JDK' + major + '生成器重新输出了已退役协议补丁')
    # 旧的最终枚举也会把上次输出中的历史文件应用回来，不能只删生成块。
    for match in re.finditer(r'^for p in ([^;\n]+); do', text, re.M):
        if {'0005', '0006', '0007'} & set(match.group(1).split()):
            raise ValueError('JDK' + major + '生成器仍枚举已退役协议补丁')


def active_patches(patch_dir, major='25'):
    """读取唯一活动清单并拒绝越界/重复条目；留存历史文件本身不代表仍在应用。"""
    names = []
    for raw in (Path(patch_dir) / 'series').read_text(encoding='utf-8').splitlines():
        name = raw.strip()
        if not name or name.startswith('#'):
            continue
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts or name in names:
            raise ValueError('JDK' + major + ' series存在越界或重复条目：' + name)
        if name.startswith(RETIRED_PREFIXES):
            raise ValueError('JDK' + major + '活动series重新启用了已退役协议补丁：' + name)
        if not (Path(patch_dir) / name).is_file():
            raise ValueError('JDK' + major + '活动补丁缺失：' + name)
        names.append(name)
    if not names:
        raise ValueError('JDK' + major + '活动series为空，不能跳过必要兼容补丁')
    return names


def verify_source_bytes(source, originals, major='25'):
    """比对三个完整文件而非局部标记，拒绝条件编译、换名及保留NONE的旁路修改。

originals只由已核验HEAD的git show取得；独立回归可用同一真实上游正文重放旧补丁。
源码使用LF是上游契约，读写均不做规范化，避免把真实修改隐藏为换行修复。
"""
    digests = {}
    for relative in SAFEPOINT_FILES:
        actual = (Path(source) / relative).read_bytes()
        expected = originals[relative]
        if actual != expected:
            raise ValueError('JDK' + major + '协议源码偏离锁定上游，禁止绕过轮询或吞信号：' + relative)
        digests[relative] = hashlib.sha256(actual).hexdigest()
    return digests


def verify_source_contract(source, patch_dir, inputs, major='25'):
    """绑定正式源码锁与真实Git HEAD，返回可写入来源收据的只读证据。

只允许各 major 固定的官方输入；HEAD不符、关键文件缺失或完整正文变化均失败关闭。
目录名、注释或旧patch存在不能替代已经应用series后的真实源码检查。
"""
    source = Path(source).resolve()
    if major not in SUPPORTED_MAJORS:
        raise ValueError('不支持的现代JDK协议主版本：' + str(major))
    item = json.loads(Path(inputs).read_text(encoding='utf-8'))['runtimes'][major]
    expected_head = item['commit']
    if item['repository'] != 'https://github.com/openjdk/jdk' + major + 'u.git' or not re.fullmatch(r'[0-9a-f]{40}', expected_head):
        raise ValueError('JDK' + major + '源码锁不是受审官方仓库或完整commit')
    head = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if head != expected_head:
        raise ValueError('JDK' + major + '协议检查的HEAD与源码锁不一致')
    names = active_patches(patch_dir, major)
    originals = {relative: subprocess.check_output(['git', '-C', str(source), 'show', 'HEAD:' + relative])
                 for relative in SAFEPOINT_FILES}
    digests = verify_source_bytes(source, originals, major)
    return {'contract': 'jdk' + major + '-upstream-safepoint-signals-v2', 'major': major, 'head': head,
            'activePatches': names, 'sourceSha256': digests}


def main():
    """供构建配方和人工定向检查调用；只输出校验身份，不产生临时源码或编译产物。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--major', choices=SUPPORTED_MAJORS, default='25')
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--patch-dir', type=Path, required=True)
    parser.add_argument('--inputs', type=Path, required=True)
    args = parser.parse_args()
    evidence = verify_source_contract(args.source, args.patch_dir, args.inputs, args.major)
    print('PASS JDK' + args.major + ' upstream safepoint/signal source: '
          + json.dumps(evidence, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
