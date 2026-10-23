#!/usr/bin/env python3
"""回归JDK25安全点防回生政策；可对真实锁定源码追加旧补丁的实际应用负对照。

默认只验证仓内活动清单/生成器和拒绝反例，不请求网络或编译。传入--source时，
先核验已经重放正式series的真实锁定源，再在外置临时副本分别应用旧0006/0007；
不会修改传入源树，也不会把默认静态检查冒充实际C2或设备验收。
"""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
from lib.workspace_paths import temporary_directory


def expect_rejected(operation, phrase):
    """反例必须被指定生产守卫拒绝，防止缺文件或无关异常被误记为有效负对照。"""
    try:
        operation()
    except ValueError as error:
        if phrase not in str(error):
            raise AssertionError('负对照命中错误分支：' + str(error)) from error
    else:
        raise AssertionError('安全点绕过被守卫接受：' + phrase)


def check_static_policy(root, guard, patch_dir, area):
    """覆盖活动旧patch、旧输出枚举、生成器再写关键文件及Python块语法。"""
    generator = root / 'docker/port_jdk25_patches.sh'
    guard.active_patches(patch_dir)
    guard.verify_generator_contract(generator)
    policy = area / 'policy'
    shutil.copytree(patch_dir, policy)
    with (policy / 'series').open('a', encoding='utf-8') as stream:
        stream.write('\n0007-safepoint-mechanism-mem-prot-read.patch\n')
    expect_rejected(lambda: guard.active_patches(policy), '重新启用')

    replay = area / 'bad-generator.sh'
    replay.write_text(generator.read_text(encoding='utf-8') + '\nfor p in 0006 0007; do\n:; done\n', encoding='utf-8')
    expect_rejected(lambda: guard.verify_generator_contract(replay), '仍枚举')
    # 关键文件即使被改名的新生成段重新编辑，也必须拒绝；不用旧编号作唯一判据。
    replay.write_text(generator.read_text(encoding='utf-8') + "\npython3 << 'PYEOF'\n"
                      + "fp = '/build/jdk25u/" + guard.SAFEPOINT_FILES[0] + "'\nPYEOF\n", encoding='utf-8')
    expect_rejected(lambda: guard.verify_generator_contract(replay), '重新编辑')


def check_real_source(root, guard, patch_dir, source, area):
    """在真实base的完整两个文件上重放历史diff，证明守卫不是只搜NONE或patch编号。"""
    evidence = guard.verify_source_contract(source, patch_dir, root / 'prebuilt/jdk/build-inputs.json')
    originals = {relative: subprocess.check_output(['git', '-C', str(source), 'show', 'HEAD:' + relative])
                 for relative in guard.SAFEPOINT_FILES}
    retired = ['0006-aarch64-elf-safepoint-fallback.patch',
               '0007-safepoint-mechanism-mem-prot-read.patch']
    for number, selected in enumerate(([retired[0]], [retired[1]], retired)):
        target = area / ('old-source-' + str(number))
        for relative, data in originals.items():
            path = target / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        # git apply可以在独立普通目录重放diff，不创建伪上游Git历史或修改真实源树。
        for name in selected:
            subprocess.run(['git', 'apply', '--check', str(patch_dir / name)], cwd=target, check=True)
            subprocess.run(['git', 'apply', str(patch_dir / name)], cwd=target, check=True)
        expect_rejected(lambda: guard.verify_source_bytes(target, originals), '偏离锁定上游')

    # 把真实旧0007改名为新编号：活动编号政策会放行，但实际源守卫仍必须拒绝。
    # 旧diff本来就保留#else下的NONE行，也验证“只搜索NONE字符串”的错误门禁会漏报。
    target = area / 'renamed-source'
    for relative, data in originals.items():
        path = target / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    renamed_policy = area / 'renamed-policy'
    shutil.copytree(patch_dir, renamed_policy)
    renamed = renamed_policy / '0099-renamed-poll.patch'
    shutil.copyfile(patch_dir / retired[1], renamed)
    with (renamed_policy / 'series').open('a', encoding='utf-8') as stream:
        stream.write('\n' + renamed.name + '\n')
    guard.active_patches(renamed_policy)
    subprocess.run(['git', 'apply', str(renamed)], cwd=target, check=True)
    expect_rejected(lambda: guard.verify_source_bytes(target, originals), '偏离锁定上游')

    # 固定源码检查先验HEAD，不能拿相似分支或人工替代树冒充锁定上游。
    wrong_lock = json.loads((root / 'prebuilt/jdk/build-inputs.json').read_text(encoding='utf-8'))
    wrong_lock['runtimes']['25']['commit'] = '0' * 40
    lock = area / 'wrong-inputs.json'
    lock.write_text(json.dumps(wrong_lock), encoding='utf-8')
    expect_rejected(lambda: guard.verify_source_contract(source, patch_dir, lock), 'HEAD与源码锁不一致')
    return evidence


def main():
    """仅向工作区外置临时目录写负对照；正式源码、历史patch原件均为只读输入。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, help='已经应用当前series的锁定JDK25源树；不在本脚本中改写')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    path = root / 'docker/scripts/verify_jdk25_safepoint.py'
    spec = importlib.util.spec_from_file_location('jdk25_safepoint_guard', path)
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)
    patch_dir = root / 'prebuilt/jdk/25/patches'
    with temporary_directory(prefix='jdk25-safepoint-contract-') as temporary:
        area = Path(temporary)
        check_static_policy(root, guard, patch_dir, area)
        if args.source:
            evidence = check_real_source(root, guard, patch_dir, args.source, area)
            print('PASS actual pinned JDK25 source and applied retired-patch negative controls: '
                  + json.dumps(evidence, ensure_ascii=False))
        else:
            print('PASS JDK25 static series/generator policies; real source replay NOT RUN (use --source)')


if __name__ == '__main__':
    main()
