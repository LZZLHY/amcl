"""以真实37类原件及有界结构反例检验生产选择器；所有夹具显式外置，不加载native占位文件。"""
import argparse
from datetime import datetime
import io
import json
import os
from pathlib import Path
import subprocess
import warnings
import zipfile
from lib.workspace_paths import external_output_path


def main():
    """只抽取所需Java字节；官方整包通过硬链接供读取，不复制模型/世界或改写原件。"""
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['output', 'standard', 'dh', 'java', 'javac']: parser.add_argument('--' + name, required=True)
    parser.add_argument('--hybrid-fixture')
    args = parser.parse_args(); root = Path(__file__).resolve().parents[1]
    out = external_output_path(args.output); out.mkdir(parents=True, exist_ok=False)
    native = out / 'native'; native.mkdir()
    for name in ['libamcl_zstdjni_std.so', 'libamcl_zstdjni_dh.so']: (native / name).write_bytes(b'path-selection-only-not-native')
    prefix = 'com/github/luben/zstd/'
    with zipfile.ZipFile(args.standard) as z: original = {n: z.read(n) for n in z.namelist() if n.startswith(prefix) and n.endswith('.class')}
    assert len(original) == 37
    def archive(items):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED) as z:
            for name, value in items: z.writestr(name, value)
        return buffer.getvalue()
    def write(name, items): (out / (name + '.jar')).write_bytes(archive(items))
    names = sorted(original)
    for name in ['changed', 'missing', 'extra', 'mr', 'unknown-shading']:
        values = dict(original)
        if name == 'changed': values[names[0]] = b'changed-class'
        if name == 'missing': del values[names[0]]
        if name == 'extra': values[prefix + 'Unexpected.class'] = b'new-class'
        if name == 'mr': values['META-INF/versions/17/' + names[0]] = original[names[0]]
        if name == 'unknown-shading': values['other/zstd/util/Native.class'] = original[prefix + 'util/Native.class']
        write(name, values.items())
    nested = archive(original.items()); forgePath = 'META-INF/jarjar/binding.jar'; fabricPath = 'META-INF/jars/binding.jar'
    forge = [(forgePath, nested), ('META-INF/jarjar/metadata.json', json.dumps({'jars': [{'path': forgePath}]}).encode())]
    write('forge', forge)
    write('fabric', [(fabricPath, nested), ('fabric.mod.json', json.dumps({'schemaVersion': 1, 'jars': [{'file': fabricPath}]}).encode())])
    write('forge-jars-path', [(fabricPath, nested), ('META-INF/jarjar/metadata.json', json.dumps({'jars': [{'path': fabricPath}]}).encode())])
    altered = dict(original); altered[names[0]] = b'changed-binding'; bad = archive(altered.items())
    write('dual-loader', [(fabricPath, nested), (forgePath, bad),
      ('fabric.mod.json', json.dumps({'jars': [{'file': fabricPath}]}).encode()),
      ('META-INF/jarjar/metadata.json', json.dumps({'jars': [{'path': forgePath}]}).encode())])
    write('dual-same', [(fabricPath, nested),
      ('fabric.mod.json', json.dumps({'jars': [{'file': fabricPath}]}).encode()),
      ('META-INF/jarjar/metadata.json', json.dumps({'jars': [{'path': fabricPath}]}).encode())])
    write('fabric-no-jars', [*original.items(), ('fabric.mod.json', b'{"schemaVersion":1,"id":"fixture"}')])
    write('undeclared', [(forgePath, nested)])
    second = archive([(forgePath, archive(forge)), ('META-INF/jarjar/metadata.json', json.dumps({'jars': [{'path': forgePath}]}).encode())])
    (out / 'forge-two-level.jar').write_bytes(second)
    write('too-deep', [(forgePath, second), ('META-INF/jarjar/metadata.json', json.dumps({'jars': [{'path': forgePath}]}).encode())])
    with warnings.catch_warnings():
        warnings.simplefilter('ignore', UserWarning); write('duplicate', [*original.items(), (names[0], original[names[0]])])
    write('metadata-duplicate', [('META-INF/jarjar/metadata.json', b'{"jars":[],"jars":[]}')])
    write('metadata-traversal', [('META-INF/jarjar/metadata.json', b'{"jars":[{"path":"META-INF/jarjar/../evil.jar"}]}')])
    write('fabric-absolute', [('fabric.mod.json', b'{"jars":[{"file":"/evil.jar"}]}')])
    write('fabric-shape', [('fabric.mod.json', b'{"jars":{}}')])
    (out / 'truncated.jar').write_bytes(b'PK\x03\x04')
    (out / 'class-directory' / prefix).mkdir(parents=True)
    mods = out / 'game/mods'; mods.mkdir(parents=True)
    os.link(Path(args.dh).resolve(), mods / 'dh.jar')
    os.link(Path(args.standard).resolve(), out / 'copy.jar'); os.link(Path(args.standard).resolve(), out / 'without-extension')
    classes = out / 'classes'; classes.mkdir()
    package = root / 'JavaApp/src/com/amcl/launcher'
    commands = [[args.javac, '-encoding', 'UTF-8', '--release', '8', '-d', str(classes), str(package / 'JarJarMetadata.java'),
                 str(package / 'NativeBindingInspector.java'), str(package / 'ZstdNativeBootstrap.java'), str(root / 'JavaApp/test/com/amcl/launcher/ZstdBootstrapContractTest.java')]]
    steps = []
    try:
        for i, command in enumerate(commands):
            p = subprocess.run(command, capture_output=True); (out / ('compile-' + str(i) + '.log')).write_bytes(p.stdout + p.stderr)
            steps.append({'command': command, 'exitCode': p.returncode}); assert not p.returncode, p.stderr
        resource = classes / 'com/amcl/launcher/zstd-bindings.properties'
        code = "import {writeFileSync} from 'node:fs'; import {zstdBindingResource} from " + json.dumps((root / 'scripts/zstd-binding-contract.mjs').as_uri()) + "; writeFileSync(process.argv[1],zstdBindingResource(process.argv[2]).bytes);"
        subprocess.run(['node', '--input-type=module', '-e', code, str(resource), str(root)], check=True)
        command = [args.java, '-cp', str(classes), 'com.amcl.launcher.ZstdBootstrapContractTest', str(out), args.standard, args.dh]
        if args.hybrid_fixture: command.append(args.hybrid_fixture)
        p = subprocess.run(command, capture_output=True, timeout=60); (out / 'contract.log').write_bytes(p.stdout + p.stderr)
        steps.append({'command': command, 'exitCode': p.returncode}); print(p.stdout.decode('utf-8', 'replace'))
        assert not p.returncode, p.stderr.decode('utf-8', 'replace')
    finally:
        (out / 'receipt.json').write_text(json.dumps({'at': datetime.now().astimezone().isoformat(), 'steps': steps,
          'passed': len(steps) == 2 and all(s['exitCode'] == 0 for s in steps), 'scope': 'path selection only; no native code'}, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__': main()
