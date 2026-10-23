"""以显式stock Linux JVM、现役JAR及匹配Linux native验证真实capabilities消费者。

此脚本不下载、安装或伪造依赖。Java类须先由stock javac编译；JNI桥由本脚本使用
官方JNI头编译。runtime-dir必须有完整生产runtime与GL host，输出为新的仓外目录。
GL API创建/退休仍由同线程production owner负责，Java算法与字段均不替换。
"""
from pathlib import Path
import argparse,datetime,hashlib,json,os,re,subprocess,sys

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def now():return datetime.datetime.now().astimezone().isoformat()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['java','classes','core-jar','opengl-jar','native-dir','jni-include','runtime-dir','output']:
        p.add_argument('--'+name,required=True,type=Path)
    p.add_argument('--driver-dir',type=Path)
    p.add_argument('--expected-mg-commit',required=True)
    p.add_argument('--no-core-tokens',action='store_true',help='候选扩展集不得含OpenGLxx，并核低grant字段不越界')
    args=p.parse_args()
    if os.name=='nt':
        # 宿主JNI为Linux/x64；不将OHOS ARM64或Windows DLL装入该JVM。
        command=['wsl','-d','Ubuntu','--exec','python3',subprocess.check_output(
            ['wsl','-d','Ubuntu','--exec','wslpath','-a',str(Path(__file__).resolve())],text=True).strip()]
        for name in ['java','classes','core_jar','opengl_jar','native_dir','jni_include','runtime_dir','output','driver_dir']:
            value=getattr(args,name)
            if value is not None:command.extend(['--'+name.replace('_','-'),subprocess.check_output(
                ['wsl','-d','Ubuntu','--exec','wslpath','-a',str(value.resolve())],text=True).strip()])
        command.extend(['--expected-mg-commit',args.expected_mg_commit])
        if args.no_core_tokens:command.append('--no-core-tokens')
        return subprocess.run(command,check=False,timeout=300).returncode
    project=Path(__file__).resolve().parents[3]
    sys.path.insert(0,str(project/'scripts'))
    from lib.workspace_paths import external_output_path
    output=external_output_path(args.output,project);output.mkdir(parents=True,exist_ok=False)
    source=Path(__file__).with_name('owner_jni.cpp');binary=output/'libfrontend_owner_jni.so'
    command=['g++','-std=c++17','-shared','-fPIC','-pthread','-I'+str(args.jni_include),
      '-I'+str(project/'entry/src/main/cpp/platform'),'-I'+str(project/'prebuilt/khronos-egl-headers'),str(source),
      '-L'+str(args.runtime_dir),'-lamcl_graphics_runtime','-Wl,-rpath,'+str(args.runtime_dir),
      '-Wl,--no-undefined','-ldl','-o',str(binary)]
    with (output/'compile.log').open('w')as log:subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=90)
    inputs=[args.java,args.core_jar,args.opengl_jar,args.classes/'FrontendLwjglConsumer.class',
      args.native_dir/'liblwjgl.so',args.native_dir/'liblwjgl_opengl.so',args.jni_include/'jni.h',args.jni_include/'jni_md.h',
      args.runtime_dir/'libamcl_graphics_runtime.so',args.runtime_dir/'libamcl_gl_host.so',source,Path(__file__).with_name('FrontendLwjglConsumer.java')]
    receipt={'schemaVersion':1,'startedAt':now(),'scope':'stock Linux JVM actual JNI/LWJGL consumer; game/SDK/physical GPU NOT_RUN',
      'inputs':{str(path.resolve()):sha(path)for path in inputs},'jniCompileCommand':command,'jniSha256':sha(binary),'runs':[]}
    classpath=':'.join(map(str,[args.classes,args.core_jar,args.opengl_jar]))
    for version in ['3.0','3.2','3.3','4.0']:
        run=output/version;run.mkdir();(run/'mg').mkdir();(run/'tmp').mkdir()
        (run/'mg/config.json').write_text(json.dumps({'customGLVersion':40,'enableANGLE':2,'enableFSR':0,'hideMG':0,'maxGlslCacheSize':32}))
        env=os.environ.copy()
        for key in ['AMCL_GRAPHICS_RUNTIME_V1','AMCL_GRAPHICS_RUNTIME_SERVICE_V2']:env.pop(key,None)
        env.update({'MG_DIR_PATH':str(run/'mg'),'MG_ANGLE_DIR':'','EGL_PLATFORM':'x11','LIBGL_ALWAYS_SOFTWARE':'1','MESA_LOADER_DRIVER_OVERRIDE':'llvmpipe'})
        if args.driver_dir:env['LD_LIBRARY_PATH']=str(args.runtime_dir)+':'+str(args.driver_dir)
        else:env['LD_LIBRARY_PATH']=str(args.runtime_dir)
        cmd=[str(args.java),'-Dorg.lwjgl.opengl.explicitInit=true','-Dorg.lwjgl.librarypath='+str(args.native_dir),
          '-Djava.io.tmpdir='+str(run/'tmp'),'-Dorg.lwjgl.system.SharedLibraryExtractPath='+str(run/'tmp'),
          '-cp',classpath,'FrontendLwjglConsumer',str(binary),*version.split('.')]
        started=now()
        with (run/'result.log').open('w')as log:r=subprocess.run(cmd,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=120)
        text=(run/'result.log').read_text()
        caps=re.findall(r'^CAPABILITIES requested=([0-9.]+) actualInteger=([0-9.]+) .* OpenGL30=(true|false) OpenGL32=(true|false) OpenGL33=(true|false) OpenGL40=(true|false)$',text,re.M)
        retired='NATIVE_RETIRED context=0 surface=0 parking=0 permit=0 contexts=0 permits=0'
        complete=r.returncode==0 and len(caps)==1 and caps[0][0]==version and caps[0][1]==version and \
          ':source='+args.expected_mg_commit+':'in text and text.count(retired)==1 and text.rstrip().endswith(retired) and \
          'foreign=0'in text and 'EXTENSION_EVIDENCE'in text and 'rawIndexedEqual=1 coldOldError=1280'in text and \
          'CONSUMER_RESULT actual GL.createCapabilities completed; core semantics NOT qualified'in text
        if args.no_core_tokens:
            # 固定输入的禁止项是独立测试判据，真正flags仍由现役Java算法计算；不伪写fields。
            forbidden={'3.0':[3,4,5],'3.2':[4,5],'3.3':[5],'4.0':[]}[version]
            complete=complete and 'syntheticCoreTokens=0'in text and all(caps[0][index]=='false'for index in forbidden)
        receipt['runs'].append({'request':version,'command':cmd,'startedAt':started,'finishedAt':now(),'exitCode':r.returncode,
          'consumerComplete':complete,'actualCapabilities':caps,'logSha256':sha(run/'result.log'),
          'coreFp64Qualification':'FAIL'if 'CORE_FP64 qualification=FAIL'in text else 'NOT_RUN',
          'corePolygonQualification':'FAIL'if 'CORE_POLYGON qualification=FAIL'in text else 'NOT_RUN'})
        print(version,'CONSUMER_PASS'if complete else 'CONSUMER_FAIL','exit='+str(r.returncode),flush=True)
    receipt['finishedAt']=now();(output/'receipt.json').write_text(json.dumps(receipt,indent=2))
    return 0 if all(x['consumerComplete']for x in receipt['runs'])else 1

if __name__=='__main__':raise SystemExit(main())
