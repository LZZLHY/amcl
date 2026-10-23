"""Java Sound宿主QA的实际输入/载荷/工具来源收据及独立故障校验。

只读取本套件固定/source、/work、/output路径。未知Git身份保持null/unknown；不从
build-inputs.json猜填旧发行源码，也不宣称本x86_64桥接为OHOS最终包验证。
"""
from pathlib import Path
from datetime import datetime, timezone, timedelta
import argparse
import hashlib
import json
import os
import re
import subprocess
import shutil
import sys

def sha(path):
    """摘要实际文件字节，缺少必需输入立即失败，不能把文件名当作来源。"""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def command(arguments):
    """只读工具查询；返回错误时保留unknown，不改源码卷或用户环境。"""
    result=subprocess.run(arguments,capture_output=True,text=True,env=dict(os.environ,GIT_OPTIONAL_LOCKS='0'))
    return result.stdout.strip() if result.returncode==0 else None

def host_version(host):
    """从实际宿主release文件读版本；8使用1.8前缀，现代版本使用第一分量。"""
    matched=re.search(r'^JAVA_VERSION="([^"]+)"', (Path(host)/'release').read_text(),re.M)
    if not matched: raise RuntimeError('Host JDK release lacks JAVA_VERSION')
    version=matched.group(1); major=int(version.split('.')[1] if version.startswith('1.') else version.split('.')[0])
    return version,major

def capture(major, source, host, native):
    """记录所有声明编译C/header输入、实际目标Platform.class和宿主JDK，不认领整包。"""
    source, host, native=Path(source),Path(host),Path(native)
    classic=major==8
    version,host_major=host_version(host)
    if host_major!=major: raise RuntimeError('Actual host JDK major differs from requested Sound suite')
    build=source/('build/linux-aarch64-normal-server-release' if classic else 'build/linux-aarch64-server-release')
    native_root=source/('jdk/src/share/native/com/sun/media/sound' if classic else 'src/java.desktop/share/native/libjsound')
    # 8的配方明确只编这两文件；现代配方编整个共享native C目录。
    files=[native_root/name for name in ('Platform.c','Utilities.c')] if classic else sorted(native_root.glob('*.c'))
    roots=[native_root,build/('jdk/gensrc_headers' if classic else 'support/headers/java.desktop'),host/'include']
    if not classic: roots += [source/'src/java.base/share/native/libjava',source/'src/java.base/unix/native/libjava']
    for root in roots: files+=sorted(root.rglob('*.h'))
    platform=build/('jdk/classes/com/sun/media/sound/Platform.class' if classic else 'jdk/modules/java.desktop/com/sun/media/sound/Platform.class')
    files.append(platform)
    diff=command(['git','-C',str(source),'diff','--binary','HEAD','--'])
    commit=command(['git','-C',str(source),'rev-parse','HEAD'])
    # 被装载路径位于容器临时层；保留同一字节副本，后续换qa容器仍可独立审计载荷。
    recorded_native=Path('/output/libjsound.host.so')
    shutil.copyfile(native,recorded_native)
    result={'schema':'amcl-java-sound-host-provenance/v1','major':major,
        'capturedAt':datetime.now(timezone(timedelta(hours=8))).isoformat(timespec='seconds'),
        'scope':'host JNI/SPI only; not final OHOS runtime or hardware audio',
        'source':{'root':str(source),'gitCommit':commit,'gitStatus':'known' if commit else 'unknown',
            'trackedDiffSha256':hashlib.sha256(diff.encode()).hexdigest() if diff is not None else None,
            'volume':os.environ.get('AMCL_QA_SOURCE_VOLUME'),'declaredInputsDigest':os.environ.get('AMCL_QA_SOURCE_INPUTS_DIGEST')},
        'compiler':command(['cc','--version']),
        'hostJdk':{'home':str(host),'version':version,'major':host_major,'releaseSha256':sha(host/'release'),'jniHeaderSha256':sha(host/'include/jni.h'),
            'jvmSha256':sha(host/('jre/lib/amd64/server/libjvm.so' if classic else 'lib/server/libjvm.so'))},
        'recipeSha256':sha('/workspace/tests/java-sound/'+('run-host8.sh' if classic else 'run-host.sh')),
        'files':[{'path':str(p),'sha256':sha(p),'bytes':p.stat().st_size} for p in sorted(set(files))],
        'payload':{'native':str(recorded_native),'loadedNativePath':str(native),'nativeSha256':sha(native),'platform':str(Path('/output/platform/com/sun/media/sound/Platform.class')),
            'platformSha256':sha(platform)},
        'testSourceSha256':sha('/workspace/tests/java-sound/RuntimeSoundSmoke.java')}
    if sha(result['payload']['platform'])!=result['payload']['platformSha256']: raise RuntimeError('Copied target Platform.class differs')
    return result

def verify(value):
    """重新读实际文件验证收据，坏SHA/缺header/错Platform或native均不得接受。"""
    if value.get('schema')!='amcl-java-sound-host-provenance/v1' or value.get('major') not in (8,17,21,25): raise RuntimeError('Invalid sound provenance schema/major')
    records=value.get('files',[])
    if not any(p.get('path','').endswith('/jni.h') for p in records) or not any(p.get('path','').endswith('.c') for p in records): raise RuntimeError('Required native C/JNI header identities absent')
    for record in records:
        if sha(record['path'])!=record['sha256'] or Path(record['path']).stat().st_size!=record['bytes']: raise RuntimeError('Actual source/header bytes differ: '+record['path'])
    payload=value['payload']
    if sha(payload['native'])!=payload['nativeSha256']: raise RuntimeError('Actual native bytes differ')
    if sha(payload['platform'])!=payload['platformSha256']: raise RuntimeError('Actual target Platform bytes differ')
    jdk=value['hostJdk']; version,major=host_version(jdk['home'])
    if major!=value['major'] or major!=jdk['major'] or version!=jdk['version']: raise RuntimeError('Actual host JDK version differs')
    for relative,key in [('release','releaseSha256'),('include/jni.h','jniHeaderSha256'),
        ('jre/lib/amd64/server/libjvm.so' if major==8 else 'lib/server/libjvm.so','jvmSha256')]:
        if sha(Path(jdk['home'])/relative)!=jdk[key]: raise RuntimeError('Actual host JDK bytes differ: '+key)
    if not value['source'].get('volume') or not value['source'].get('declaredInputsDigest'): raise RuntimeError('Source workspace identity absent')

def main():
    """每次实际编译后校验正例及五项只污染收据的负例，原文件和原收据不改写。"""
    parser=argparse.ArgumentParser();parser.add_argument('--major',type=int,required=True)
    for name in ('source','host','native'): parser.add_argument('--'+name,required=True)
    args=parser.parse_args(); result=capture(args.major,args.source,args.host,args.native);verify(result)
    for kind in ('native','platform','header','host-jvm','missing-source-volume'):
        wrong=json.loads(json.dumps(result))
        if kind=='header': next(p for p in wrong['files'] if p['path'].endswith('/jni.h'))['sha256']='0'*64
        elif kind=='host-jvm': wrong['hostJdk']['jvmSha256']='0'*64
        elif kind=='missing-source-volume': wrong['source']['volume']=None
        else: wrong['payload'][kind+'Sha256']='0'*64
        try: verify(wrong)
        except RuntimeError: pass
        else: raise RuntimeError('Provenance negative control accepted: '+kind)
    Path('/output/sound-provenance.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print('PASS sound provenance: actual source/C/header/Platform/native/host JDK; five wrong/missing identities rejected')

if __name__=='__main__': main()
