"""直接编译固定JDK8原文与本仓0020补丁，验证JNI失败传播和成功缓存。

输入原文按上游commit/SHA核对；每次只写全新仓外目录，不触碰活动JDK树或Docker。
Linux可直接运行gcc；Windows可显式使用WSL已有gcc。目标SDK只做真实源码的C编译和
未定义符号检查，不把宿主JNI替身或单文件目标编译宣称为真实JVM/设备资格。
"""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import shutil
import subprocess

repo = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--source-manifest', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--cc', default='gcc')
parser.add_argument('--wsl', help='Windows上的现有WSL发行版；不安装工具或修改其设置')
parser.add_argument('--sdk-cc', type=Path)
parser.add_argument('--sdk-sysroot', type=Path)
parser.add_argument('--sdk-nm', type=Path)
args = parser.parse_args()
output = args.output.resolve()
if not args.output.is_absolute() or output == repo or repo in output.parents:
    raise SystemExit('Output must be an absolute external directory')
if args.wsl and os.name != 'nt':
    raise SystemExit('--wsl is only supported by the Windows runner')
if any((args.sdk_cc, args.sdk_sysroot, args.sdk_nm)) and not all((args.sdk_cc, args.sdk_sysroot, args.sdk_nm)):
    raise SystemExit('Provide all three SDK arguments or none')
output.mkdir(parents=True, exist_ok=False)


def stamp():
    return datetime.datetime.now().astimezone().isoformat()


def identity(path):
    data = path.read_bytes()
    return dict(path=str(path.resolve()), bytes=len(data), sha256=hashlib.sha256(data).hexdigest())


receipt = dict(startedAt=stamp(), state='running', inputs=[], commands=[], targetQualified=False)


def save():
    (output/'receipt.json').write_text(json.dumps(receipt, indent=2, ensure_ascii=False), encoding='utf-8')


def run(command, name, expected=0, cwd=None):
    """原样保留stdout/stderr，避免WSL的UTF16诊断污染UTF8测试输出；异常退出不当作负例。"""
    started = stamp()
    result = subprocess.run(list(map(str, command)), cwd=cwd, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=90)
    stdout = output/(name+'.stdout.log')
    stderr = output/(name+'.stderr.bin')
    stdout.write_bytes(result.stdout)
    stderr.write_bytes(result.stderr)
    receipt['commands'].append(dict(command=list(map(str, command)), name=name, cwd=str(cwd) if cwd else None,
        startedAt=started, finishedAt=stamp(), exitCode=result.returncode, expectedExit=expected,
        stdout=str(stdout), stderr=str(stderr)))
    save()
    text = result.stdout.decode('utf-8', errors='replace')
    print(name, 'exit='+str(result.returncode), text, flush=True)
    if result.returncode != expected:
        raise RuntimeError('Unexpected exit; retained '+str(stdout)+' and '+str(stderr))
    return text


def host_path(path):
    """仅转换Windows本地绝对路径为WSL挂载路径；命令参数逐项传递，不拼shell。"""
    path = path.resolve()
    if not args.wsl:
        return str(path)
    if len(path.drive) != 2 or path.drive[1] != ':':
        raise ValueError('WSL input must be on a local drive')
    return '/mnt/'+path.drive[0].lower()+path.as_posix()[2:]


try:
    pinned = json.loads((repo/'prebuilt/jdk/build-inputs.json').read_text(encoding='utf-8'))['runtimes']['8']['commit']
    records = json.loads(args.source_manifest.read_text(encoding='utf-8'))['sources']
    source_name = 'jdk/src/solaris/native/sun/awt/awt_LoadLibrary.c'
    # 只取被测真实C文件和它实际包含的固定头，不扫描整个SDK或JDK源码树。
    needed = {source_name, 'jdk/src/share/native/common/jni_util.h',
        'jdk/src/share/javavm/export/jni.h', 'jdk/src/solaris/javavm/export/jni_md.h',
        'jdk/src/share/native/common/gdefs.h', 'jdk/src/solaris/native/common/gdefs_md.h',
        'jdk/src/share/native/common/jlong.h', 'jdk/src/solaris/native/common/jlong_md.h',
        'jdk/src/share/javavm/export/jvm.h', 'jdk/src/solaris/javavm/export/jvm_md.h',
        'jdk/src/share/javavm/export/classfile_constants.h'}
    selected = [record for record in records if record['source'] in needed]
    if len(selected) != len(needed) or {row['source'] for row in selected} != needed:
        raise ValueError('Exactly one pinned record is required for every source/header')
    headers = output/'headers'; headers.mkdir()
    original = output/'original'/source_name
    patched = output/'patched'/source_name
    original.parent.mkdir(parents=True); patched.parent.mkdir(parents=True)
    receipt['inputs'] = [identity(args.source_manifest)]
    for record in selected:
        source = Path(record['savedPath'])
        if record['revision'] != pinned or identity(source)['sha256'] != record['sha256']:
            raise ValueError('Source identity mismatch: '+record['source'])
        receipt['inputs'].append(dict(**identity(source), source=record['source'], revision=pinned))
        if record['source'] == source_name:
            # 固定已复现的上游实现，防止把已修正源码误作原版负控。
            if record['sha256'] != 'ef23d0adc67243ea5215c07609cf95a68f44c2f3c4650eee62f4f9b2883fea7e':
                raise ValueError('Unexpected JDK8 AWT baseline')
            shutil.copyfile(source, original); shutil.copyfile(source, patched)
        else:
            shutil.copyfile(source, headers/Path(record['source']).name)
    patch = repo/'prebuilt/jdk/8/patches/0020-jni-font-library-exception-check.patch'
    fixture = output/'awt_jni_check_test.c'
    harness = repo/'tests/runtime-permissions/awt_jni_check_test.c'
    shutil.copyfile(harness, fixture)
    receipt['inputs'] += [identity(patch), identity(harness), identity(Path(__file__))]
    run(['git','apply','--check',patch], 'apply-check', cwd=output/'patched')
    run(['git','apply',patch], 'apply', cwd=output/'patched')
    receipt['patchedSource'] = identity(patched)
    prefix = ['wsl.exe','-d',args.wsl,'--exec'] if args.wsl else []
    run(prefix+[args.cc,'--version'], 'host-compiler')
    common = [args.cc,'-std=gnu99','-pthread','-O1','-g','-I',host_path(headers)]
    positive = output/'positive'; negative = output/'negative'
    run(prefix+common+['-fsanitize=address,undefined','-fno-omit-frame-pointer',
        '-DAMCL_AWT_SOURCE="'+host_path(patched)+'"',host_path(fixture),'-o',host_path(positive)], 'compile-positive')
    # 单轮故障矩阵使用真实候选C控制流。ASan/UBSan/LSan报告必须导致非零退出。
    positive_text = run(prefix+['env','ASAN_OPTIONS=detect_leaks=1:halt_on_error=1',
        'UBSAN_OPTIONS=halt_on_error=1','timeout','30',host_path(positive)], 'positive')
    if 'PASS JDK8 AWT JNI:' not in positive_text:
        raise RuntimeError('Missing positive qualification marker')
    run(prefix+common+['-DAMCL_AWT_OLD','-DAMCL_AWT_SOURCE="'+host_path(original)+'"',
        host_path(fixture),'-o',host_path(negative)], 'compile-negative')
    for mode, marker in [('unchecked','REPRO old AWTIsHeadless returns without checking CallStaticBooleanMethod'),
                         ('poison','REPRO old failed AWT headless lookup poisons cache with false')]:
        text = run(prefix+['timeout','30',host_path(negative),mode], 'negative-'+mode, expected=77)
        if marker not in text:
            raise RuntimeError('Missing exact original negative marker: '+mode)
    if args.sdk_cc:
        run([args.sdk_cc,'--version'], 'sdk-compiler')
        obj = output/'awt-ohos.o'
        run([args.sdk_cc,'--target=aarch64-linux-ohos','--sysroot='+str(args.sdk_sysroot),
            '-std=gnu99','-D_GNU_SOURCE','-fPIC','-O2','-Werror=implicit-function-declaration',
            '-I',headers,'-c',patched,'-o',obj], 'sdk-compile')
        undefined = run([args.sdk_nm,'--undefined-only',obj], 'sdk-undefined')
        # 当前SDK必须直接生成AArch64原子指令；否则需核对链接依赖，不能默许新libatomic需求。
        if '__atomic_' in undefined or '__aarch64_' in undefined or '__sync_' in undefined:
            raise RuntimeError('Target atomic code generated an unverified runtime helper')
        receipt['sdkObject'] = identity(obj)
        receipt['sdkStatus'] = 'C99 compilation and no new atomic runtime helper PASS; full JDK link remains separate'
    else:
        receipt['sdkStatus'] = 'NOT-RUN'
    receipt['state'] = 'pass'
finally:
    receipt['finishedAt'] = stamp()
    if receipt['state'] == 'running': receipt['state'] = 'failed'
    save()
