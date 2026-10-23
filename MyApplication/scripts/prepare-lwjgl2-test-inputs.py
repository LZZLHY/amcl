"""准备真实 LWJGL2 宿主测试的锁定源码 ZIP，并校验专用 JDK8。

本工具只恢复测试材料，不重建 OHOS .so、不修改锁或 JAVA_HOME/PATH。缓存已有时
必须重新核 SHA，损坏缓存直接失败，不能自动换包掩盖异常；缺席时才从 manifest
的精确 sourceUrl 下载。下载、收据及子进程临时输出全部使用仓外位置。
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

from lib.workspace_paths import external_output_path, workspace_path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'prebuilt/lwjgl2/build-inputs.json'
ARCHIVE_NAME = 'lwjgl-2df01dd.zip'
MAX_ARCHIVE_BYTES = 256 * 1024 * 1024


def digest(path):
    """流式核真实文件内容，不用名称、存在性或缓存命中作为材料资格。"""
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def source_spec():
    """只消费现有锁定 manifest；限制下载 URL 必须指向同一个上游完整 commit。"""
    spec = json.loads(MANIFEST.read_text(encoding='utf-8'))
    commit = spec.get('sourceCommit', '')
    expected = spec.get('files', {}).get(ARCHIVE_NAME, '')
    url = spec.get('sourceUrl', '')
    if not re.fullmatch(r'[0-9a-f]{40}', commit) or not re.fullmatch(r'[0-9a-f]{64}', expected):
        raise ValueError('Invalid locked LWJGL2 source identity')
    if url != 'https://codeload.github.com/LWJGL/lwjgl/zip/' + commit:
        raise ValueError('LWJGL2 sourceUrl does not identify the locked upstream commit')
    return spec, commit, expected, url


def verify_source(archive, spec, commit, expected):
    """SHA 通过后再读实际生成器/JNI和消费类；不使用 stub 或只验一个标记成员。"""
    actual = digest(archive)
    if actual != expected:
        raise ValueError('LWJGL2 source checksum mismatch: expected=' + expected + ' actual=' + actual)
    prefix = 'lwjgl-' + commit + '/'
    required = ['src/java/org/lwjgl/input/Keyboard.java', 'src/java/org/lwjgl/input/Mouse.java',
                'src/java/org/lwjgl/opengl/Display.java', 'src/native/common/common_tools.c']
    with zipfile.ZipFile(archive) as source:
        for name in required:
            if not source.read(prefix + name):
                raise ValueError('Locked source member is empty: ' + name)
        context = source.read(prefix + 'src/java/org/lwjgl/opengl/ContextGL.java')
        if hashlib.sha256(context).hexdigest() != spec['sourceFixtures']['source-fixtures/ContextGL.java']:
            raise ValueError('Locked ContextGL source fixture identity mismatch')
    return actual


def prepare_source(inputs, offline=False):
    """复用校验已存在的 ZIP；下载只写唯一同目录暂存，校验完成后才原子发布。"""
    spec, commit, expected, url = source_spec()
    inputs = external_output_path(inputs)
    inputs.mkdir(parents=True, exist_ok=True)
    archive = inputs / ARCHIVE_NAME
    reused = archive.exists()
    if not reused:
        if offline:
            raise FileNotFoundError('Offline preparation requires locked archive: ' + str(archive))
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(prefix='lwjgl2-source-', suffix='.part', dir=inputs, delete=False) as output:
                temporary = Path(output.name)
                request = urllib.request.Request(url, headers={'User-Agent': 'AMCL-input-consumer-materials'})
                with urllib.request.urlopen(request, timeout=60) as response:
                    if response.geturl() != url:
                        raise ValueError('Locked LWJGL2 download redirected to another source URL')
                    count = 0
                    while True:
                        chunk = response.read(1024 * 1024)
                        if not chunk:
                            break
                        count += len(chunk)
                        if count > MAX_ARCHIVE_BYTES:
                            raise ValueError('LWJGL2 source download exceeds the material budget')
                        output.write(chunk)
            verify_source(temporary, spec, commit, expected)
            # 同一缓存的另一调用已经写入时，先核其身份，绝不覆盖异常的现存文件。
            if archive.exists():
                verify_source(archive, spec, commit, expected)
            else:
                os.replace(temporary, archive)
        finally:
            if temporary is not None and temporary.exists():
                temporary.unlink()
    actual = verify_source(archive, spec, commit, expected)
    return {'inputs': str(inputs), 'archive': str(archive), 'sourceCommit': commit,
            'sourceUrl': url, 'sourceSha256': actual, 'reused': reused}


def verify_jdk8(jdk, scratch):
    """执行指定的真实 java/javac 并核 JNI 头；不修改用户或默认 JDK21 环境。"""
    jdk = Path(jdk).resolve()
    suffix = '.exe' if os.name == 'nt' else ''
    platform = 'win32' if os.name == 'nt' else ('darwin' if sys.platform == 'darwin' else 'linux')
    required = [jdk / 'bin' / ('java' + suffix), jdk / 'bin' / ('javac' + suffix),
                jdk / 'include/jni.h', jdk / 'include' / platform / 'jni_md.h']
    for item in required:
        if not item.is_file():
            raise FileNotFoundError('LWJGL2 JDK8 material is missing: ' + str(item))
    child_env = dict(os.environ)
    # 只限定版本探针子进程的临时输出；专用 JDK8 不写入父进程 JAVA_HOME/PATH。
    scratch = external_output_path(scratch)
    scratch.mkdir(parents=True, exist_ok=True)
    child_env.update(TEMP=str(scratch), TMP=str(scratch), TMPDIR=str(scratch))
    versions = []
    for tool in required[:2]:
        result = subprocess.run([str(tool), '-version'], cwd=scratch, env=child_env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30, text=True)
        if result.returncode:
            raise ValueError('JDK version probe failed: ' + tool.name)
        pattern = r'version\s+"(1\.8\.[^"\s]+)"' if tool == required[0] else r'javac\s+(1\.8\.[^\s]+)'
        match = re.search(pattern, result.stdout)
        if not match:
            raise ValueError('LWJGL2 real consumers require JDK8: ' + str(tool))
        versions.append(match.group(1))
    return {'jdk8': str(jdk), 'javaVersion': versions[0], 'javacVersion': versions[1]}


def github_outputs(path, values):
    """只写该 step 的显式输出文件，供后续 step 设置专用变量，不改 job 默认 JAVA_HOME。"""
    output = external_output_path(path)
    for key in ('inputs', 'jdk8'):
        if '\n' in values[key] or '\r' in values[key]:
            raise ValueError('Material path cannot contain a GitHub output separator')
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('a', encoding='utf-8') as stream:
        for key in ('inputs', 'jdk8'):
            stream.write(key + '=' + values[key] + '\n')


def main(options):
    """完整材料通过后才发布收据和 CI 输出；错误明确失败，不静默下载替代缓存或跳测试。"""
    receipt = external_output_path(options.receipt or workspace_path('run', 'lwjgl2-test-inputs') / 'receipt.json')
    if receipt.exists():
        raise ValueError('Preparation receipt must be a new file: ' + str(receipt))
    receipt.parent.mkdir(parents=True, exist_ok=True)
    jdk = options.jdk8 or os.environ.get('AMCL_LWJGL2_JDK8') or os.environ.get('AMCL_LWJGL2_JDK')
    if not jdk:
        raise FileNotFoundError('Pass --jdk8 or AMCL_LWJGL2_JDK8 with a real JDK8; default JDK21 is retained')
    java = verify_jdk8(jdk, receipt.parent / 'temp')
    source = prepare_source(options.inputs_dir or workspace_path('build', 'lwjgl2-test-inputs'), options.offline)
    result = {'schema': 1, 'recordedAt': datetime.now(timezone.utc).isoformat(),
              'manifestSha256': digest(MANIFEST), **source, **java}
    receipt.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    if options.github_output:
        github_outputs(options.github_output, result)
    print(json.dumps(result, ensure_ascii=False))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs-dir', type=Path, help='仓外 ZIP 缓存目录；缺省沿 workspace helper')
    parser.add_argument('--jdk8', type=Path, help='专用真实 JDK8；不改变默认 JDK/JAVA_HOME')
    parser.add_argument('--offline', action='store_true', help='只核现有材料，任何缺席均失败且不联网')
    parser.add_argument('--receipt', type=Path, help='显式仓外 JSON 收据；缺省沿 workspace helper')
    parser.add_argument('--github-output', type=Path, help='GitHub step 的输出文件，写 inputs/jdk8 两个路径')
    try:
        main(parser.parse_args())
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + '\n')
