#!/usr/bin/env python3
"""四代锁定Java原类补后回归；明确用RegisterNatives注入同源JNI和受控SDK供应者。"""
import argparse
from datetime import datetime
import hashlib,importlib.util,json,os,shutil,subprocess,sys
from pathlib import Path

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    sys.dont_write_bytecode=True
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();out=args.output.resolve();out.mkdir(parents=True,exist_ok=False)
    project=Path(__file__).resolve().parents[2];frozen=out/'inputs/project'
    originals=list((project/'tests/java-sound-ports').rglob('*'))
    originals += [project/'entry/src/main/cpp/javasound'/name for name in ('ports_ohos.c','ports_ohos.h','ports_jni.c')]
    identities={}
    for source in originals:
        if not source.is_file() or '__pycache__' in source.parts:continue
        rel=source.relative_to(project);target=frozen/rel;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,target)
        identities[rel.as_posix()]=sha(source);assert sha(target)==identities[rel.as_posix()]
    tests=frozen/'tests/java-sound-ports';native=frozen/'entry/src/main/cpp/javasound'
    spec=importlib.util.spec_from_file_location('patcher',tests/'patch-java.py');patcher=importlib.util.module_from_spec(spec);spec.loader.exec_module(patcher)
    reference=tests/'reference';records=json.loads((reference/'source.json').read_text())
    for record in records['files']:assert sha(reference/record['file'])==record['sha256']
    receipt={'schemaVersion':1,'startedAt':datetime.now().astimezone().isoformat(),'scope':'real four-version PortMixer classes and production JNI; host SDK supplier and RegisterNatives are test injection, not target device qualification',
             'execution':'standard JNI Invocation with explicit exception checks; host java CLI is separately retained as a diagnostic reference',
             'inputs':identities,'runs':[]}
    def command(argv,path,expect=0):
        actual=subprocess.run([str(x) for x in argv],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
        path.write_bytes(actual.stdout)
        if actual.returncode!=expect:raise RuntimeError('unexpected exit '+str(actual.returncode)+': '+str(path))
        return actual
    try:
        for major in ('8','17','21','25'):
            jdk=Path('/usr/lib/jvm/'+('java-'+major+'-openjdk-amd64' if major in ('8','17') else 'temurin-'+major+'-jdk-amd64'))
            work=out/major;work.mkdir();src=work/'source/com/sun/media/sound';src.mkdir(parents=True);classes=work/'classes';classes.mkdir()
            provider,mixer=patcher.transform((reference/major/'PortMixerProvider.java').read_text(),(reference/major/'PortMixer.java').read_text())
            for name,text in [('PortMixerProvider.java',provider),('PortMixer.java',mixer)]: (src/name).write_text(text,encoding='utf-8')
            shutil.copyfile(tests/'PortsJavaTest.java',src/'PortsJavaTest.java')
            shutil.copyfile(tests/'PortsLaunchBaseline.java',src/'PortsLaunchBaseline.java')
            java_files=sorted(src.glob('*.java'))
            compile=[jdk/'bin/javac','-encoding','UTF-8','-g','-d',classes]
            if major!='8':compile+=['--patch-module','java.desktop='+str(work/'source')]
            command([*compile,*java_files],work/'javac.log')
            lib=work/'libports-test.so';old=work/'libports-old-zero.so'
            common=['cc','-shared','-fPIC','-O1','-g','-std=c11','-Wall','-Wextra','-Werror','-DAMCL_PORTS_TEST',
                    '-I'+str(tests/'stubs'),'-I'+str(jdk/'include'),'-I'+str(jdk/'include/linux'),
                    native/'ports_ohos.c',tests/'ports_jni_bridge.c',tests/'ports_fake_device.c','-pthread','-Wl,--no-undefined']
            command([*common,'-o',lib],work/'compile-jni.log')
            server=jdk/('jre/lib/amd64/server' if major=='8' else 'lib/server')
            launcher=work/'ports-vm-launcher'
            command(['cc','-std=c11','-Wall','-Wextra','-Werror','-I'+str(jdk/'include'),
                     '-I'+str(jdk/'include/linux'),tests/'ports_vm_launcher.c','-L'+str(server),
                     '-Wl,-rpath,'+str(server),'-ljvm','-o',launcher],work/'compile-launcher.log')
            options=['-Xcheck:jni']
            if major=='8':options+=['-Xbootclasspath/p:'+str(classes), 'com.sun.media.sound.PortsJavaTest']
            else:options+=['--patch-module','java.desktop='+str(classes),'-m','java.desktop/com.sun.media.sound.PortsJavaTest']
            # 空main以完全相同VM/类路径启动，不装载我们的JNI；独立记录启动器基线，
            # 仍对实际正例保留全部CheckJNI拒绝门，不能把基线告警直接当自动豁免。
            baseline_options=[value.replace('PortsJavaTest','PortsLaunchBaseline') for value in options]
            baseline=command([jdk/'bin/java',*baseline_options],work/'launch-baseline.log')
            receipt.setdefault('launchBaselines',[]).append({'major':major,'exitCode':baseline.returncode,
                'logSha256':sha(work/'launch-baseline.log'),'checkJniDiagnostic':b'WARNING in native method' in baseline.stdout})
            # 8宿主java的实际测试main前出现过CallStaticObjectMethod诊断，独立留原输出。
            # 真正正/负例一律使用同一标准Invocation入口，并继续拒绝任何CheckJNI告警。
            if major=='8':
                cli_reference=command([jdk/'bin/java',*options,lib],work/'java-cli-reference.log')
                receipt['hostJava8CliReference']={'exitCode':cli_reference.returncode,
                    'logSha256':sha(work/'java-cli-reference.log'),'targetCliQualified':False}
            invoke=[launcher,major,classes,'com/sun/media/sound/PortsJavaTest']
            invocation_baseline=command([launcher,major,classes,'com/sun/media/sound/PortsLaunchBaseline'],work/'invocation-baseline.log')
            if b'WARNING in native method' in invocation_baseline.stdout or b'FATAL ERROR in native method' in invocation_baseline.stdout:
                raise RuntimeError('Invocation baseline CheckJNI diagnostic: '+major)
            result=command([*invoke,lib],work/'positive.log')
            if b'PASS real PortMixer Java/JNI' not in result.stdout or b'WARNING in native method' in result.stdout or b'FATAL ERROR in native method' in result.stdout:
                raise RuntimeError('missing actual pass or CheckJNI diagnostic: '+major)
            command([*common,'-DAMCL_PORTS_OLD_STUB','-o',old],work/'compile-old.log')
            negative=command([*invoke,old],work/'old-zero.log',1)
            if b'WARNING in native method' in negative.stdout or b'FATAL ERROR in native method' in negative.stdout:
                raise RuntimeError('negative case CheckJNI diagnostic: '+major)
            if b'AssertionError: real SDK descriptors were suppressed or virtual ones invented' not in negative.stdout:
                raise RuntimeError('old zero-device boundary did not fail the functional assertion: '+major)
            row={'major':major,'java':str(jdk/'bin/java'),'javaSha256':sha(jdk/'bin/java'),'positiveExit':result.returncode,
                 'oldZeroBoundaryExit':negative.returncode,'nativeSha256':sha(lib),'oldNativeSha256':sha(old),
                 'invocationLauncherSha256':sha(launcher),'libjvmSha256':sha(server/'libjvm.so'),
                 'classes':{p.relative_to(classes).as_posix():sha(p) for p in classes.rglob('*.class')},
                 'positiveLogSha256':sha(work/'positive.log'),'negativeLogSha256':sha(work/'old-zero.log')}
            receipt['runs'].append(row);print('PASS four-version ports Java/JNI '+major,flush=True)
        for name,identity in identities.items():assert sha(project/name)==identity,'source changed during QA: '+name
        receipt['result']='PASS'
    finally:
        receipt['finishedAt']=datetime.now().astimezone().isoformat()
        (out/'jni-receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

if __name__=='__main__':main()
