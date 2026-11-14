#!/usr/bin/env python3
"""四代真实上游Java候选+同源生产JNI，固定SDK供应者；每项新VM独立进程、有界退出。"""
import argparse
from datetime import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    sys.dont_write_bytecode = True
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=False)
    root=Path(__file__).resolve().parents[2];tests=root/'tests/java-midi';native=root/'entry/src/main/cpp/javasound'
    records=json.loads((tests/'reference/source.json').read_text())['files']
    for row in records:
        assert sha(tests/'reference'/row['file'])==row['sha256'],row['file']
    spec=importlib.util.spec_from_file_location('midi_patcher',tests/'patch-java.py')
    patcher=importlib.util.module_from_spec(spec);spec.loader.exec_module(patcher)
    receipt={'startedAt':datetime.now().astimezone().isoformat(),'scope':'four real host VMs and production Java/JNI with explicit test SDK service; no target or hardware qualification',
        'sources':{str(p.relative_to(root)):sha(p) for p in list(native.glob('midi*.[ch]'))+list(tests.glob('*')) if p.is_file()},'runs':[]}
    def run(command,path,environment=None,negative=None):
        result=subprocess.run([str(x) for x in command],capture_output=True,timeout=30,env=environment)
        path.write_bytes(result.stdout+result.stderr)
        if negative:
            if result.returncode==0 or negative.encode() not in result.stdout+result.stderr:
                raise RuntimeError('negative did not reach intended assertion: '+str(path))
        elif result.returncode:
            print((result.stdout+result.stderr).decode('utf-8','replace'),flush=True)
            raise RuntimeError('command failed: '+str(path))
        if b'WARNING in native method' in result.stdout+result.stderr or b'FATAL ERROR in native method' in result.stdout+result.stderr:
            raise RuntimeError('CheckJNI diagnostic: '+str(path))
        return result
    try:
        provider=out/'provider';provider.mkdir();missing=out/'missing-send';missing.mkdir();empty=out/'empty';empty.mkdir()
        common=['gcc','-std=c11','-O2','-g','-Wall','-Wextra','-Werror','-fPIC','-D_GNU_SOURCE','-D__availability__(...)=',
                '-I'+str(tests/'reference/sdk'),'-pthread']
        run([*common,'-shared',tests/'fake_provider.c','-Wl,--no-undefined','-o',provider/'libohmidi.so'],out/'compile-provider.log')
        run([*common,'-DAMCL_MIDI_TEST_MISSING_SEND','-shared',tests/'fake_provider.c','-Wl,--no-undefined','-o',missing/'libohmidi.so'],out/'compile-missing-send.log')
        for major in ('8','17','21','25'):
            jdk=Path('/usr/lib/jvm/'+('java-'+major+'-openjdk-amd64' if major in ('8','17') else 'temurin-'+major+'-jdk-amd64'))
            work=out/major;work.mkdir();src=work/'source/com/sun/media/sound';src.mkdir(parents=True);classes=work/'classes';classes.mkdir()
            sources={p.name:p.read_text() for p in (tests/'reference'/major).glob('*.java')}
            for name,text in patcher.transform(sources).items():
                (src/name).write_text(text,encoding='utf-8')
            shutil.copyfile(tests/'MidiJavaTest.java',src/'MidiJavaTest.java')
            command=[jdk/'bin/javac','-encoding','UTF-8','-g','-d',classes]
            if major!='8':command+=['--patch-module','java.desktop='+str(work/'source')]
            run([*command,*sorted(src.glob('*.java'))],work/'javac.log')
            build=[*common,'-I'+str(jdk/'include'),'-I'+str(jdk/'include/linux')]
            library=work/'libmidi-test.so'
            run([*build,'-shared',tests/'jni_bridge.c',native/'midi_api.c',native/'midi_core.c',native/'midi_stream.c',native/'midi_ump.c',
                 '-ldl','-Wl,--no-undefined','-o',library],work/'compile-jni.log')
            server=jdk/('jre/lib/amd64/server' if major=='8' else 'lib/server')
            launcher=work/'invoke-main'
            run([*build,tests/'invoke_main.c','-L'+str(server),'-Wl,-rpath,'+str(server),'-ljvm','-o',launcher],work/'compile-invocation.log')
            options=['-Xcheck:jni','-Xbootclasspath/p:'+str(classes)] if major=='8' else ['-Xcheck:jni','--patch-module=java.desktop='+str(classes)]
            base={**os.environ,'LD_LIBRARY_PATH':str(provider)}
            variants=[('positive',base,'positive',None),
                      ('embedded',dict(base,AMCL_MIDI_TEST_EMBEDDED='valid'),'positive',None),
                      ('old-zero',dict(base,AMCL_MIDI_TEST_OLD_ZERO='1'),'positive','real SDK descriptors were suppressed or virtual ones invented'),
                      ('bad-layout',dict(base,AMCL_MIDI_TEST_EMBEDDED='bad-layout'),'reject-host',None),
                      ('foreign-callback',dict(base,AMCL_MIDI_TEST_EMBEDDED='foreign-callback'),'reject-host',None),
                      ('no-provider',dict(base,LD_LIBRARY_PATH=str(empty)),'no-provider',None),
                      ('missing-send',dict(base,LD_LIBRARY_PATH=str(missing)),'missing-send',None)]
            logs=[]
            for name,environment,mode,negative in variants:
                path=work/(name+'.log')
                result=run([launcher,len(options),*options,library,mode],path,environment,negative)
                if not negative and b'PASS ' not in result.stdout:raise RuntimeError('functional pass missing '+name)
                logs.append(dict(name=name,exitCode=result.returncode,logSha256=sha(path),expectedNegative=bool(negative)))
            receipt['runs'].append({'major':major,'libjvmSha256':sha(server/'libjvm.so'),'jniSha256':sha(library),
                'classes':{str(p.relative_to(classes)):sha(p) for p in classes.rglob('*.class')},'logs':logs})
            print('PASS actual MIDI Java/JNI '+major+' (7 isolated profiles)',flush=True)
        for path,expected in receipt['sources'].items():assert sha(root/path)==expected,'input changed during QA: '+path
        receipt['result']='PASS'
    finally:
        receipt['finishedAt']=datetime.now().astimezone().isoformat()
        (out/'receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')


if __name__=='__main__':main()
