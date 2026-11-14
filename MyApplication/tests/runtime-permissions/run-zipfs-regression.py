"""以精确上游原文和本仓0019补丁运行完整zipfs原版/候选对照。

不下载工具、不修改SDK或活动JDK树。source-manifest来自已核验的上游获取记录，所有原文
按SHA复核，补丁用git apply精确应用。输出要求全新仓外目录；Java8/25实际宿主可选，缺失时
分别在Java17/21运行这些版本的源码，并在收据明确区别源码major与宿主VM，不授予目标资格。
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
parser.add_argument('--jdk8-support-jar', required=True, type=Path)
parser.add_argument('--java17', required=True, type=Path, help='Java17 home')
parser.add_argument('--java21', required=True, type=Path, help='Java21 home')
parser.add_argument('--java8', type=Path, help='optional actual Java8 home')
parser.add_argument('--java25', type=Path, help='optional actual Java25 home')
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
output = args.output.resolve()
if not args.output.is_absolute() or output == repo or repo in output.parents:
    raise SystemExit('Output must be an absolute external directory')
output.mkdir(parents=True, exist_ok=False)

def stamp():
    return datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat()

def identity(file):
    data = file.read_bytes()
    return dict(path=str(file.resolve()), bytes=len(data), sha256=hashlib.sha256(data).hexdigest())

receipt = dict(startedAt=stamp(), state='running', inputs=[], commands=[], cases=[], targetQualified=False)
counter = 0

def run(command, cwd=None):
    global counter
    counter += 1
    log = output / ('command-%02d.log' % counter)
    started = stamp()
    result = subprocess.run([str(value) for value in command], cwd=cwd,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write_bytes(result.stdout)
    receipt['commands'].append(dict(command=[str(value) for value in command], cwd=str(cwd) if cwd else None,
        startedAt=started, finishedAt=stamp(), exitCode=result.returncode, log=str(log)))
    text = result.stdout.decode('utf-8', errors='replace')
    print(text, end='')
    if result.returncode:
        raise RuntimeError('Command failed; retained '+str(log))
    return text

def tool(home, name):
    return home / 'bin' / (name + ('.exe' if os.name == 'nt' else ''))

try:
    entries = json.loads(args.source_manifest.read_text(encoding='utf-8'))['sources']
    pinned = json.loads((repo/'prebuilt/jdk/build-inputs.json').read_text(encoding='utf-8'))['runtimes']
    records = {entry['major']: entry for entry in entries if entry['major'] in pinned}
    if set(records) != {'8','17','21','25'}:
        raise ValueError('Source manifest must contain all four exact upstream files')
    harness = repo/'tests/runtime-permissions/ZipfsPermissionRegression.java'
    receipt['inputs'] = [identity(args.source_manifest), identity(args.jdk8_support_jar), identity(harness)]
    harness_classes = output/'harness'; harness_classes.mkdir()
    run([tool(args.java17,'javac'),'--release','8','-encoding','UTF-8','-d',harness_classes,harness])
    for major in ('8','17','21','25'):
        entry = records[major]
        if entry['revision'] != pinned[major]['commit']:
            raise ValueError('Source commit does not match product build input: '+major)
        expected_path = ('jdk/src/share/demo/nio/zipfs/src/com/sun/nio/zipfs/ZipFileSystem.java' if major == '8'
                         else 'src/jdk.zipfs/share/classes/jdk/nio/zipfs/ZipFileSystem.java')
        if entry['source'] != expected_path:
            raise ValueError('Unexpected zipfs source path: '+major)
        original = Path(entry['savedPath']).read_bytes()
        if hashlib.sha256(original).hexdigest() != entry['sha256']:
            raise ValueError('Upstream bytes changed: '+major)
        patch = repo/'prebuilt/jdk'/major/'patches/0019-zipfs-permission-copy-transaction.patch'
        receipt['inputs'].append(identity(patch))
        home = (args.java8 or args.java17) if major == '8' else args.java17 if major == '17' else (
               args.java25 or args.java21) if major == '25' else args.java21
        version = run([tool(home,'java'),'-version'])
        for variant in ('old','patched'):
            tree = output/(major+'-'+variant); tree.mkdir()
            source = tree/expected_path; source.parent.mkdir(parents=True)
            source.write_bytes(original)
            if variant == 'patched':
                run(['git','apply','--check',patch],tree)
                run(['git','apply',patch],tree)
            classes = tree/'classes'; classes.mkdir()
            if major == '8':
                compile_flags = ['-source','8','-target','8'] if args.java8 else ['--release','8']
                run([tool(home,'javac'),*compile_flags,'-encoding','UTF-8','-cp',args.jdk8_support_jar,
                     '-d',classes,source])
                if args.java8:
                    runtime_flags = ['-Xbootclasspath/p:'+os.pathsep.join(map(str,[classes,args.jdk8_support_jar])),
                                     '-cp',harness_classes]
                else:
                    runtime_flags = ['--add-exports','java.base/sun.nio.cs=ALL-UNNAMED','-cp',
                                     os.pathsep.join(map(str,[classes,args.jdk8_support_jar,harness_classes]))]
                prefix = 'com.sun.nio.zipfs'
            else:
                run([tool(home,'javac'),'-encoding','UTF-8','--patch-module','jdk.zipfs='+str(source.parent),
                     '-d',classes,source])
                runtime_flags = ['--patch-module','jdk.zipfs='+str(classes),
                                 '--add-opens','jdk.zipfs/jdk.nio.zipfs=ALL-UNNAMED','-cp',harness_classes]
                prefix = 'jdk.nio.zipfs'
            evidence = tree/'cases'
            text = run([tool(home,'java'),*runtime_flags,'ZipfsPermissionRegression',prefix,evidence,variant])
            expected = 'ZIPFS_PERMISSION_REGRESSION_COMPLETE mode='+variant+' cases=11'
            if expected not in text:
                raise AssertionError('Missing exact completed-case marker: '+major+' '+variant)
            receipt['cases'].append(dict(sourceMajor=major, variant=variant, hostJavaHome=str(home.resolve()),
                hostVersion=version, source=identity(source), caseCount=11, evidenceDirectory=str(evidence),
                injectedBoundary='POSIX attributes/fileKey/permission failures only; actual ZIP bytes use host filesystem'))
    receipt['state'] = 'PASS'
except Exception as error:
    receipt['state'] = 'FAIL'; receipt['error'] = str(error)
    raise
finally:
    receipt['finishedAt'] = stamp()
    (output/'receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2),encoding='utf-8')
