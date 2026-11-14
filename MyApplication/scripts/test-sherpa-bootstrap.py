"""对最终 launcher JAR 运行精确 Sherpa 绑定选择；模型和桌面 native 正文不解包、不执行。"""
import argparse
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import warnings
import zipfile
from lib.workspace_paths import external_output_path


def main():
    """官方原件保持只读；所有小型正负夹具和运行记录显式落仓外输出。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    parser.add_argument('--official5', required=True)
    parser.add_argument('--official6', required=True)
    parser.add_argument('--launcher-jar', required=True)
    parser.add_argument('--java', required=True)
    parser.add_argument('--javac', required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = external_output_path(args.output)
    output.mkdir(parents=True, exist_ok=False)
    native = output / 'native'
    native.mkdir()
    # 这里只验路径决议；文件从不传给 System.load，更不冒充可以工作的推理库。
    for name in ('libsherpa-onnx-jni.so', 'libonnxruntime.so'):
        (native / name).write_bytes(b'path-selection-fixture-only')
    with zipfile.ZipFile(args.official5) as jar:
        classes = {item.filename: jar.read(item) for item in jar.infolist()
                   if item.filename.startswith('com/k2fsa/sherpa/onnx/') and item.filename.endswith('.class')}
    assert len(classes) == 235
    with zipfile.ZipFile(args.official6) as jar:
        core_path = 'META-INF/jarjar/sherpa-onnx-v1.13.3.jar'
        core = jar.read(core_path)
    with zipfile.ZipFile(io.BytesIO(core)) as jar:
        classes6 = {name: jar.read(name) for name in classes}

    def write(name, entries):
        """仅复制所需 Java 字节/小 metadata，绝不展开官方模型或桌面 SO。"""
        with zipfile.ZipFile(output / (name + '.jar'), 'w', zipfile.ZIP_DEFLATED) as jar:
            for path, data in entries:
                jar.writestr(path, data)

    names = sorted(classes)
    for name in ('changed', 'missing', 'extra', 'mixed', 'mr'):
        items = dict(classes)
        if name == 'changed':
            items[names[0]] = b'changed-class-bytecode'
        if name == 'mixed':
            changed = next(path for path in names if classes[path] != classes6[path])
            items[changed] = classes6[changed]
        if name == 'missing':
            del items[names[0]]
        if name == 'extra':
            items['com/k2fsa/sherpa/onnx/Unknown.class'] = b'new-binding'
        if name == 'mr':
            items['META-INF/versions/17/' + names[0]] = classes[names[0]]
        write(name, items.items())
    write('undeclared', [(core_path, core)])
    metadata = json.dumps({'jars': [{'path': core_path}]}).encode()
    write('declared', [(core_path, core), ('META-INF/jarjar/metadata.json', metadata)])
    with warnings.catch_warnings():
        warnings.simplefilter('ignore', UserWarning)
        write('duplicate', [*classes.items(), (names[0], classes[names[0]])])
    write('metadata-duplicate', [('META-INF/jarjar/metadata.json', b'{"jars":[],"jars":[]}')])
    write('metadata-traversal', [('META-INF/jarjar/metadata.json', b'{"jars":[{"path":"META-INF/jarjar/../evil.jar"}]}')])
    (output / 'truncated.jar').write_bytes(b'PK\x03\x04')
    mods = output / 'game/mods'
    mods.mkdir(parents=True)
    # 同盘 hardlink 不复制约数百 MiB 的官方归档；不支持时明确失败，避免悄悄膨胀夹具。
    os.link(Path(args.official6).resolve(), mods / 'verity.jar')
    os.link(Path(args.official5).resolve(), output / 'without-extension')
    (output / 'class-directory/com/k2fsa/sherpa/onnx').mkdir(parents=True)
    classes_out = output / 'classes'
    classes_out.mkdir()
    source = root / 'JavaApp/test/com/amcl/launcher/SherpaBootstrapContractTest.java'
    subprocess.run([args.javac, '--release', '8', '-encoding', 'UTF-8', '-cp', args.launcher_jar,
                    '-d', str(classes_out), str(source)], check=True)
    command = [args.java, '-cp', os.pathsep.join((args.launcher_jar, str(classes_out))),
               'com.amcl.launcher.SherpaBootstrapContractTest', str(output), args.official5, args.official6]
    result = subprocess.run(command, capture_output=True, text=True, timeout=45)
    (output / 'contract.log').write_text(result.stdout + result.stderr, encoding='utf8')
    print(result.stdout, end='')
    if result.returncode:
        raise RuntimeError(result.stderr)
    (output / 'result.json').write_text(json.dumps({'command': command, 'passed': True,
        'officialInputs': [args.official5, args.official6], 'classesPerProfile': 235}, indent=2))


if __name__ == '__main__':
    main()
