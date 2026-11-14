"""用本机正式 OHOS SDK 交叉编译 Sherpa JNI，输入固定、输出显式外置。

本配方不运行目标二进制，不使用宿主 Windows JNI ABI，不修改全局 TEMP/TMP。
完整第三方源码保留在构建目录；仅跳过归档内链接，并把清单写入证据而不跟随外部路径。
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    """流式摘要避免将源归档、运行库一次性读入内存。"""
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def external(path):
    """拒绝把大输出写回任意 Git 仓库，路径始终由调用者显式传入。"""
    path = path.resolve()
    if any((parent / '.git').exists() for parent in (path, *path.parents)):
        raise ValueError('必须使用仓外目录：' + str(path))
    path.mkdir(parents=True, exist_ok=True)
    return path


def main():
    """校验来源后配置并前台编译，成功失败均留下实际命令与完整日志。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', type=Path, required=True)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sdk', type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    if args.output.exists() and any(args.output.iterdir()):
        raise ValueError('本次输出目录必须为空，不能覆盖既有构建证据')
    build, output = external(args.build), external(args.output)
    spec = json.loads((ROOT / 'prebuilt/mod-natives/sherpa-onnx/build-inputs.json').read_text())
    for key in ('sherpa', 'onnxruntime'):
        record = spec[key]
        if sha(args.inputs / record['archive']) != record['sha256']:
            raise ValueError(key + '归档摘要不匹配')
    source = build / ('sherpa-onnx-' + spec['sherpa']['commit'])
    # 上游测试/Go脚本存在指向作者电脑的绝对链接；本构建不使用它们，也绝不跟随。
    skipped = []
    with tarfile.open(args.inputs / spec['sherpa']['archive']) as archive:
        members = []
        for member in archive.getmembers():
            if member.issym() or member.islnk():
                skipped.append({'name': member.name, 'target': member.linkname})
            else:
                members.append(member)
        archive.extractall(build, members=members, filter='data')
    with zipfile.ZipFile(args.inputs / spec['onnxruntime']['archive']) as archive:
        archive.extractall(build)
    ort = build / 'onnxruntime-ohos-arm64-v8a-1.16.3'
    jni = build / 'jni-home/include'
    jni.mkdir(parents=True, exist_ok=True)
    headers = {}
    for header in spec['jniHeaders']:
        filename = header['path']
        if sha(ROOT / filename) != header['sha256']:
            raise ValueError('目标JNI头与锁定身份不符：' + filename)
        shutil.copyfile(ROOT / filename, jni / Path(filename).name)
        headers[filename] = sha(ROOT / filename)
    temp = external(build / 'temp')
    env = dict(os.environ, JAVA_HOME=str(jni.parent),
               SHERPA_ONNXRUNTIME_INCLUDE_DIR=str(ort / 'include'),
               SHERPA_ONNXRUNTIME_LIB_DIR=str(ort / 'lib'), TEMP=str(temp), TMP=str(temp))
    cmake = args.sdk / 'build-tools/cmake/bin/cmake.exe'
    ninja = args.sdk / 'build-tools/cmake/bin/ninja.exe'
    obj = build / 'ohos-jni'
    commands = [[str(cmake), '-S', str(source), '-B', str(obj), '-G', 'Ninja',
        '-DCMAKE_MAKE_PROGRAM=' + ninja.as_posix(),
        '-DCMAKE_TOOLCHAIN_FILE=' + (args.sdk / 'build/cmake/ohos.toolchain.cmake').as_posix(),
        '-DOHOS_ARCH=arm64-v8a', '-DCMAKE_BUILD_TYPE=Release', '-DBUILD_SHARED_LIBS=ON',
        # 目标均创建后修正上游裸 RPATH 的 Ninja 转义，并限定产物只用 $ORIGIN。
        '-DCMAKE_PROJECT_TOP_LEVEL_INCLUDES=' + (ROOT / 'prebuilt/mod-natives/sherpa-onnx/ohos-adjustments.cmake').as_posix(),
        '-DSHERPA_ONNX_ENABLE_JNI=ON', '-DSHERPA_ONNX_ENABLE_TTS=ON',
        '-DSHERPA_ONNX_ENABLE_C_API=OFF', '-DSHERPA_ONNX_ENABLE_BINARY=OFF',
        '-DSHERPA_ONNX_ENABLE_PYTHON=OFF', '-DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF',
        '-DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF', '-DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF',
        '-DSHERPA_ONNX_ENABLE_TESTS=OFF', '-DSHERPA_ONNX_ENABLE_CHECK=OFF',
        '-DBUILD_ESPEAK_NG_EXE=OFF', '-DBUILD_ESPEAK_NG_TESTS=OFF',
        '-DBUILD_PIPER_PHONMIZE_EXE=OFF', '-DBUILD_PIPER_PHONMIZE_TESTS=OFF',
        '-DCMAKE_INSTALL_PREFIX=' + (obj / 'install').as_posix()],
        [str(cmake), '--build', str(obj), '--target', 'sherpa-onnx-jni', '--parallel', str(args.jobs)]]
    receipt = {'startedAt': datetime.now().astimezone().isoformat(), 'spec': spec,
               'commands': commands, 'jniHeaders': headers, 'skippedArchiveLinks': skipped,
               'sdk': str(args.sdk.resolve()), 'cmakeSha256': sha(cmake), 'state': 'running'}
    try:
        with (output / 'build.log').open('a', encoding='utf-8') as log:
            for command in commands:
                print(subprocess.list2cmdline(command), flush=True)
                with subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                      text=True, encoding='utf-8', errors='replace') as process:
                    for line in process.stdout:
                        print(line, end='', flush=True)
                        log.write(line)
                        log.flush()
                    if process.wait():
                        raise RuntimeError('构建命令失败：' + command[0])
        artifacts = []
        for file in list((obj / 'lib').glob('*.so')) + list((ort / 'lib').glob('libonnxruntime.so*')):
            target = output / file.name
            shutil.copyfile(file, target)
            # SDK默认会在HAP打包剥离普通符号；锁定制品先以同一工具剥离，避免
            # 用原始含符号副本摘要冒充最终消费字节。未剥离原件仍在构建树保留。
            if file.name == 'libsherpa-onnx-jni.so':
                subprocess.run([str(args.sdk / 'llvm/bin/llvm-strip.exe'), '--strip-unneeded', str(target)], check=True)
            artifacts.append({'filename': file.name, 'sha256': sha(target), 'size': target.stat().st_size})
        receipt.update(state='built', artifacts=artifacts)
    except BaseException as error:
        receipt.update(state='failed', error=str(error))
        raise
    finally:
        receipt['finishedAt'] = datetime.now().astimezone().isoformat()
        (output / 'build-receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')


if __name__ == '__main__':
    main()
