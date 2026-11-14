"""编译同版 Sherpa/候选 ORT 的真实宿主 JNI，并使用 Verity 原绑定和原模型推理。

此验证不经过 Java Sound，避免把音频设备或占位识别器混入引擎契约。输出限于显式E目录；
MSVC环境仅作用于子进程，所有配置/编译/推理前台记录，失败不会变成通过。
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    """准备精确宿主依赖和JDK头，分别运行两份原绑定而不替换它们的class。"""
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('inputs', 'build', 'output', 'evidence', 'sdk', 'visual-studio', 'java-home'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=6)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    build = args.build.resolve()
    source = build / 'sherpa-onnx-330609dab49be6ee8b30702918ca7abbbad1286a'
    locked = json.loads((ROOT / 'prebuilt/mod-natives/sherpa-onnx/build-inputs.json').read_text())
    ort_archive = args.inputs / 'onnxruntime-win-x64-1.16.3.zip'
    if hashlib.sha256(ort_archive.read_bytes()).hexdigest() != locked['hostOnnxruntime']['sha256']:
        raise ValueError('宿主ORT归档与正式输入锁不符')
    with zipfile.ZipFile(ort_archive) as archive:
        for entry in archive.infolist():
            if entry.is_dir():
                continue
            destination = build / entry.filename
            data = archive.read(entry)
            # 内容相同就不改mtime，让真实Ninja缓存判定增量；不重新复制整个SDK。
            if not destination.exists() or destination.read_bytes() != data:
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
    ort = build / 'onnxruntime-win-x64-1.16.3'
    # 编译目标为Windows x64时必须使用Windows JNI export定义，而不是OHOS头。
    jni = build / 'host-jni-home/include'
    (jni / 'win32').mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / 'entry/src/main/cpp/jvm/jni.h', jni / 'jni.h')
    shutil.copyfile(ROOT / 'prebuilt/mod-natives/imgui-java/jni/jni-headers/win32/jni_md.h', jni / 'win32/jni_md.h')
    setup = args.visual_studio / 'VC/Auxiliary/Build/vcvars64.bat'
    # 只在内存中读取vcvars的子进程环境，不向工具输出凭据或整个环境正文。
    # cmd /s /c 需要外层和批处理路径各一层双引号；不能让list2cmdline把它们
    # 转成cmd并不认识的反斜杠引号。路径来自已验证Visual Studio目录，不接受引号。
    if not setup.is_file() or '"' in str(setup):
        raise ValueError('Visual Studio vcvars64 路径无效')
    values = subprocess.check_output('cmd.exe /d /s /c ""' + str(setup) + '" >nul && set"',
                                     text=True, encoding='utf-8', errors='replace')
    env = dict(os.environ)
    for line in values.splitlines():
        if '=' in line and not line.startswith('='):
            key, value = line.split('=', 1)
            env[key] = value
    temp = build / 'host-temp'
    temp.mkdir(exist_ok=True)
    env.update(JAVA_HOME=str(jni.parent), SHERPA_ONNXRUNTIME_INCLUDE_DIR=str(ort / 'include'),
               SHERPA_ONNXRUNTIME_LIB_DIR=str(ort / 'lib'), TEMP=str(temp), TMP=str(temp))
    cmake = args.sdk / 'build-tools/cmake/bin/cmake.exe'
    obj = build / 'host-jni'
    commands = [[str(cmake), '-S', str(source), '-B', str(obj), '-G', 'Ninja',
        '-DCMAKE_MAKE_PROGRAM=' + (args.sdk / 'build-tools/cmake/bin/ninja.exe').as_posix(),
        '-DCMAKE_C_COMPILER=cl', '-DCMAKE_CXX_COMPILER=cl', '-DCMAKE_BUILD_TYPE=Release',
        '-DCMAKE_INSTALL_PREFIX=' + (obj / 'install').as_posix(),
        # 上游Windows CPU的预装ORT分支未赋import-lib第二变量，但仍把它展开到
        # set_target_properties。显式给同一官方导入库，不启用GPU来绕过该错误。
        '-Dlocation_onnxruntime_lib2=' + (ort / 'lib/onnxruntime.lib').as_posix(),
        '-DCMAKE_PROJECT_TOP_LEVEL_INCLUDES=' + (ROOT / 'prebuilt/mod-natives/sherpa-onnx/ohos-adjustments.cmake').as_posix(),
        '-DBUILD_SHARED_LIBS=ON', '-DSHERPA_ONNX_ENABLE_JNI=ON', '-DSHERPA_ONNX_ENABLE_TTS=ON',
        '-DSHERPA_ONNX_ENABLE_C_API=OFF', '-DSHERPA_ONNX_ENABLE_BINARY=OFF',
        '-DSHERPA_ONNX_ENABLE_PYTHON=OFF', '-DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF',
        '-DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF', '-DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF',
        '-DBUILD_ESPEAK_NG_EXE=OFF', '-DBUILD_ESPEAK_NG_TESTS=OFF',
        '-DBUILD_PIPER_PHONMIZE_EXE=OFF', '-DBUILD_PIPER_PHONMIZE_TESTS=OFF'],
        [str(cmake), '--build', str(obj), '--target', 'sherpa-onnx-jni', '--parallel', str(args.jobs)]]
    receipt = {'startedAt': datetime.now().astimezone().isoformat(), 'state': 'running', 'commands': commands}
    def run(command, logfile):
        """附着真实前台子进程；日志和失败退出码一同保留，禁止mock成功。"""
        with logfile.open('x', encoding='utf-8') as log:
            with subprocess.Popen(command, env=env, cwd=output, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  text=True, encoding='utf-8', errors='replace') as child:
                for line in child.stdout:
                    log.write(line)
                    log.flush()
                    print(line, end='', flush=True)
                if child.wait():
                    raise RuntimeError('真实宿主阶段失败：' + str(logfile))
    try:
        run(commands[0], output / 'configure.log')
        run(commands[1], output / 'compile.log')
        native = output / 'native'
        native.mkdir()
        shutil.copyfile(ort / 'lib/onnxruntime.dll', native / 'onnxruntime.dll')
        shutil.copyfile(obj / 'bin/sherpa-onnx-jni.dll', native / 'sherpa-onnx-jni.dll')
        receipt['nativeSha256'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in native.glob('*.dll')}
        receipt['sherpaSourceCommit'] = '330609dab49be6ee8b30702918ca7abbbad1286a'
        receipt['ortVersion'] = '1.16.3'
        receipt['ortArchiveSha256'] = hashlib.sha256(ort_archive.read_bytes()).hexdigest()
        classes = output / 'probe-classes'
        classes.mkdir()
        run([str(args.java_home / 'bin/javac.exe'), '-encoding', 'UTF-8', '-cp',
             str(args.evidence / '5.7.3/original-sherpa-bindings.jar'), '-d', str(classes),
             str(ROOT / 'scripts/fixtures/sherpa/VeritySherpaProbe.java')], output / 'javac.log')
        for version in ('5.7.3', '6.0.0'):
            run([str(args.java_home / 'bin/java.exe'), '-XX:ErrorFile=' + str(output / 'hs_err_pid%p.log'),
                 '-Dsherpa_onnx.native.path=' + str(native), '-cp', str(classes) + ';' +
                 str(args.evidence / version / 'original-sherpa-bindings.jar'), 'VeritySherpaProbe',
                 str(args.evidence / version), str(native)], output / ('inference-' + version + '.log'))
        receipt['state'] = 'PASS'
    except BaseException as error:
        receipt.update(state='failed', error=str(error))
        raise
    finally:
        receipt['finishedAt'] = datetime.now().astimezone().isoformat()
        (output / 'host-receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')


if __name__ == '__main__':
    main()
