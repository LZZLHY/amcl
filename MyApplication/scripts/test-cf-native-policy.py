"""编译并运行真实 CF 参数装配、release 读取与固定资格三臂的 POSIX 宿主回归。

在 Linux/WSL 中运行；不创建 JVM，不连接设备，不授予游戏或性能资格。
所有片段、二进制、固定样本和收据写入新的 --out-dir；重复路径明确拒绝覆盖。
默认读取本仓；--project-root 仅供独立候选覆盖树复用原仓的未改依赖，收据记录实际输入。
"""
from pathlib import Path
from datetime import datetime
import argparse
import hashlib
import json
import os
import shlex
import subprocess
import sys


def extract_function(text, signature):
    """提取唯一且花括号平衡的既有小函数；适用正文不含未配对的字符串花括号。"""
    if text.count(signature) != 1:
        raise ValueError('Missing or ambiguous source function: ' + signature)
    begin = text.index(signature)
    end = text.index('{', begin) + 1
    depth = 1
    while depth and end < len(text):
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    if depth:
        raise ValueError('Unbalanced source function: ' + signature)
    return text[begin:end]


def unique_offset(text, marker):
    """边界移动或重复必须失败，防止错误提取与生产无关的另一份实现。"""
    if text.count(marker) != 1:
        raise ValueError('Missing or ambiguous source boundary: ' + marker)
    return text.index(marker)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out-dir', required=True)
    parser.add_argument('--project-root', default='')
    args = parser.parse_args()
    if os.name == 'nt':
        parser.error('POSIX host required; run this entry with Python inside Linux/WSL')
    overlay = Path(__file__).resolve().parents[1]
    project = Path(args.project_root).resolve() if args.project_root else overlay
    sys.path.insert(0, str(project / 'scripts'))
    from lib.workspace_paths import external_output_path
    output = external_output_path(args.out_dir, project)
    external_output_path(args.out_dir, overlay)
    output.mkdir(parents=True, exist_ok=False)
    cpp = overlay / 'entry/src/main/cpp'
    base_cpp = project / 'entry/src/main/cpp'
    launcher = (cpp / 'jvm/jvm_launcher.cpp').read_text(encoding='utf-8')
    qualification = (cpp / 'napi/jdk_java_qualification.cpp').read_text(encoding='utf-8')
    # 与生产 SH 租约、创建认领保持真实顺序；只省略系统服务的宿主替身。
    begin = unique_offset(launcher, '    const auto releaseIdentity = amcl::jvm::ReadReleaseMajor(')
    end = unique_offset(launcher, '    std::string fontsConfiguration, classicFontProperties, fontError;')
    if not unique_offset(launcher, '    if (!directoryLease.acquire(') < begin < end < unique_offset(launcher, '    const int creationClaim ='):
        raise ValueError('Release read must remain inside the shared lease and before VM creation')
    common_begin = unique_offset(launcher, '    std::string gcOverride;')
    common_end = unique_offset(launcher, '    // JavaVMOption 最终')
    if common_begin >= common_end:
        raise ValueError('Common/extra option boundaries are reversed')
    # 同一个工具函数后面另有 CF Java 执行块；只允许从 setExtraArgs 前的装配区提取。
    arm_begin = unique_offset(qualification, '        std::vector<std::string> extraArgs{')
    arm_end = unique_offset(qualification, '        jvmSetExtraArgsList(extraArgs);')
    if arm_begin >= arm_end:
        raise ValueError('Qualification option boundaries are reversed')
    pieces = {
        'cf_release_decision.inc': launcher[begin:end],
        'cf_common_extra_options.inc': launcher[common_begin:common_end],
        'cf_explicit_setter.inc': extract_function(launcher, 'extern "C" int jvmSetQualificationCfExplicit('),
        'cf_explicit_arm.inc': extract_function(qualification[arm_begin:arm_end], '        if (cfProfile(profile)) {'),
    }
    for name, body in pieces.items():
        (output / name).write_text(body, encoding='utf-8')
    receipt = {'state': 'RUNNING', 'startedAt': datetime.now().astimezone().isoformat(),
        'scope': 'actual source host policy only; no target VM, game, performance or full HAP qualification',
        'commands': [], 'inputs': {}, 'extractedSha256': {
            name: hashlib.sha256(body.encode()).hexdigest() for name, body in pieces.items()}}

    def save():
        """每次调用后持久化真实退出信息，失败不留下伪造 PASS。"""
        (output / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

    def run(name, command, timeout):
        """以前台有界子进程执行；stdout/stderr 原样保存，超时和非零退出都使整轮失败。"""
        row = {'name': name, 'command': command, 'startedAt': datetime.now().astimezone().isoformat()}
        receipt['commands'].append(row)
        try:
            result = subprocess.run(command, capture_output=True, timeout=timeout, check=False)
            row['exitCode'] = result.returncode
            stdout, stderr = result.stdout, result.stderr
        except subprocess.TimeoutExpired as error:
            row['timedOut'] = True
            stdout, stderr = error.stdout or b'', error.stderr or b''
        (output / (name + '.stdout.log')).write_bytes(stdout)
        (output / (name + '.stderr.log')).write_bytes(stderr)
        row['finishedAt'] = datetime.now().astimezone().isoformat()
        save()
        print(name, row.get('exitCode', 'TIMEOUT'), flush=True)
        if row.get('exitCode') != 0:
            raise RuntimeError('Host command failed: ' + name + '; see preserved logs')

    try:
        for name, source in (('default', 'cf_default_policy_test.cpp'), ('arms', 'cf_explicit_arms_test.cpp')):
            dependency = output / (name + '.d')
            binary = output / name
            command = [*shlex.split(os.environ.get('CXX', 'c++')), '-std=c++17', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
                '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-MMD', '-MF', str(dependency),
                '-I' + str(cpp), '-I' + str(base_cpp), '-I' + str(base_cpp / 'jvm'), '-I' + str(output),
                str(overlay / 'tests/runtime-jit' / source), '-o', str(binary)]
            run(name + '-build', command, 60)
            # 编译器列出实际本地依赖，包含覆盖树和原仓，避免只记录顶层 C++ 文件。
            dependencies = shlex.split(dependency.read_text().replace('\\\n', ' ').split(': ', 1)[1])
            for value in dependencies:
                path = Path(value).resolve()
                receipt['inputs'][str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
            run(name + '-run', [str(binary), str(output / (name + '-fixture'))], 10)
        for path in (Path(__file__).resolve(), cpp / 'jvm/jvm_launcher.cpp', cpp / 'napi/jdk_java_qualification.cpp'):
            receipt['inputs'][str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
        receipt['state'] = 'PASS'
    except Exception as error:
        receipt['state'] = 'FAIL'
        receipt['failure'] = str(error)
        raise
    finally:
        receipt['finishedAt'] = datetime.now().astimezone().isoformat()
        save()


if __name__ == '__main__':
    main()
