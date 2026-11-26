"""从原模组的子类加载器调用真实 JNI/JNA。宿主动态库随原绑定获取，不能证明 OHOS 设备行为。"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile
from lib.game_compat_inputs import jdk_tool
from lib.workspace_paths import external_output_path

ROOT = Path(__file__).resolve().parents[1]
AGENT = ROOT/'entry/src/main/resources/rawfile/amcl-cpu-agent.jar'
SOURCES = ROOT/'prebuilt/mod-natives/sdl2/sources.json'
MODERN = ('https://edge.forgecdn.net/files/7943/200/controllable-forge-1.20.1-0.21.9.jar',
          '937f628547fb077ac207ecf1180541c707c26beafa3e98b1ab239ef22bdf2b80')
JNA = ('https://repo.maven.apache.org/maven2/net/java/dev/jna/jna/5.12.1/jna-5.12.1.jar',
       '91a814ac4f40d60dee91d842e1a8ad874c62197984403d0e3c30d39e55cf53b3')


# 真实 1.12.2 发布环境使用 LaunchWrapper 1.12 + Forge 14.23.5.2860。这些依赖只在回归运行。
MC_LIBS = 'https://libraries.minecraft.net/'
MAVEN = 'https://repo.maven.apache.org/maven2/'
FORGE_FOR_TEST = [
    (MC_LIBS+'net/minecraft/launchwrapper/1.12/launchwrapper-1.12.jar','57f402b626d16cc2705bf2a37add7adbb074f0ca3b3102fa6e23aa303dae682f'),
    ('https://files.minecraftforge.net/maven/net/minecraftforge/forge/1.12.2-14.23.5.2860/forge-1.12.2-14.23.5.2860-universal.jar','cd3fbf85d7ca744507fd6a37a41b90122d43e616a4f8962332b1b658655e8a64'),
    (MAVEN+'org/ow2/asm/asm-debug-all/5.2/asm-debug-all-5.2.jar','254b82bec9da4f8efbc8b1f93ab2b87f7465227a82b36cf3d05d9e77a0e8dd2e'),
    (MAVEN+'com/google/guava/guava/21.0/guava-21.0.jar','972139718abc8a4893fa78cba8cf7b2c903f35c97aaf44fa3031b0669948b480'),
    (MC_LIBS+'lzma/lzma/0.0.1/lzma-0.0.1.jar','0c3085cb93c3ef95d731c274b6f2dd195aa0405fe9328d69cab7f5e899d5e124'),
    (MC_LIBS+'org/apache/logging/log4j/log4j-api/2.8.1/log4j-api-2.8.1.jar','1205ab764b1326f7d96d99baa4a4e12614599bf3d735790947748ee116511fa2'),
    (MC_LIBS+'org/apache/logging/log4j/log4j-core/2.8.1/log4j-core-2.8.1.jar','815a73e20e90a413662eefe8594414684df3d5723edcd76070e1a5aee864616e'),
    (MC_LIBS+'net/sf/jopt-simple/jopt-simple/5.0.3/jopt-simple-5.0.3.jar','6f45c00908265947c39221035250024f2caec9a15c1c8cf553ebeecee289f342'),
]


def probe_forge(inputs, work, classes, natives, old, java8, download):
    deps = [verified(inputs, url.rsplit('/',1)[1], (url,sha), download) for url,sha in FORGE_FOR_TEST]
    classpath = os.pathsep.join(str(p) for p in [classes,*deps])
    subprocess.run([jdk_tool('javac',minimum=17),'--release','8','-proc:none','-encoding','UTF-8','-cp',classpath,
                    '-d',str(classes),str(ROOT/'JavaCpuAgent/test/com/amcl/gamepad/ForgeModLoadProbe.java')],check=True)
    results = []
    for mode, agent in [('gdx',False),('gdx',True),('jamepad',True)]:
        # 令原版旧装载器按 Linux/aarch64 查找，精确复现与 OHOS 一样的首次 native 调用边界。
        args = [java8,'-Xverify:all','-Djava.io.tmpdir='+str(work),'-Dos.name=Linux','-Dos.arch=aarch64','-Djava.library.path=',
                '-Damcl.gamepad.sdl2.dir='+str(natives)]
        if agent: args.append('-javaagent:'+str(AGENT))
        args.extend(['-cp',classpath,'com.amcl.gamepad.ForgeModLoadProbe',mode,str(old[mode])])
        result = subprocess.run(args,cwd=work,text=True,errors='replace',capture_output=True,timeout=45)
        details = result.stdout+'\n'+result.stderr
        if not agent:
            if result.returncode==0 or 'UnsatisfiedLinkError: org.libsdl.SDL.SDL_INIT_TIMER()I' not in details:
                raise RuntimeError('未得到原始首次 JNI 调用失败：'+details)
            results.append('Forge112 negative: SDL_INIT_TIMER()I unavailable without bridge')
        else:
            marker='[AMCL] SDL2 binding '+('org/libsdl/SDL' if mode=='gdx' else 'com/studiohartman/jamepad/ControllerManager')+' -> '
            matches=[line for line in result.stdout.splitlines() if line.startswith('SDL2_BINDING_OK Forge112 ')]
            if result.returncode or marker not in result.stderr or len(matches)!=1:
                raise RuntimeError(details)
            results.append(matches[0])
    return results


def verified(directory, filename, source, download):
    """仅显式允许时获取缺少的测试输入；每次核对原始 JAR 的 SHA256。"""
    file = directory/filename
    if not file.exists() and download:
        with urllib.request.urlopen(source[0], timeout=60) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != source[1]:
            raise ValueError('Download digest mismatch: '+filename)
        file.write_bytes(data)
    if hashlib.sha256(file.read_bytes()).hexdigest() != source[1]:
        raise ValueError('JAR identity mismatch: '+filename)
    return file


def run(inputs, output, download, java8, jna_inputs, forge112):
    """每个绑定以全新 JVM 和类加载器执行；额外撤回精确类身份，拒绝同名未知绑定。"""
    if platform.machine().lower() not in ('amd64','x86_64') or platform.system() not in ('Windows','Linux','Darwin'):
        raise ValueError('Locked upstream desktop JNI fixtures require x86_64')
    inputs = external_output_path(inputs)
    output = external_output_path(output)
    inputs.mkdir(parents=True,exist_ok=True)
    output.mkdir(parents=True,exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='mod-load-',dir=output)).resolve()
    classes = work/'classes'
    natives = work/'natives'
    classes.mkdir()
    natives.mkdir()
    sources = json.loads(SOURCES.read_text(encoding='utf8'))
    old = {key: verified(inputs,'controllable-'+key+'.jar',sources['controllable-'+key+'.jar'],download)
           for key in ('gdx','jamepad')}
    mod = verified(inputs,'controllable-modern.jar',MODERN,download)
    jna = verified(inputs,'jna-5.12.1.jar',JNA,download)
    with zipfile.ZipFile(mod) as jar:
        inner = work/'controllable-sdl.jar'
        inner.write_bytes(jar.read('META-INF/jarjar/controllable-sdl-2.30.12-1.1.0.jar'))
    # 操作系统加载器由文件内容辨认宿主库，文件名固定成 HAP 所提供的 ABI；测试绝不加载目标 ELF。
    linux = platform.system()=='Linux'
    mac = platform.system()=='Darwin'
    for mode,library in [('gdx','sdl2gdx'),('jamepad','jamepad')]:
        entry = 'lib'+library+'64.'+('dylib' if mac else 'so') if mac or linux else library+'64.dll'
        with zipfile.ZipFile(old[mode]) as jar:
            (natives/('lib'+library+'.so')).write_bytes(jar.read(entry))
    native = 'darwin-x86-64/libSDL2.dylib' if mac else 'linux-x86-64/libSDL2.so' if linux else 'win32-x86-64/SDL2.dll'
    with zipfile.ZipFile(inner) as jar:
        (natives/'libSDL2.so').write_bytes(jar.read(native))
    java = jdk_tool('java',minimum=17)
    subprocess.run([jdk_tool('javac',minimum=17),'--release','8','-encoding','UTF-8','-d',str(classes),
                    str(ROOT/'JavaCpuAgent/test/com/amcl/gamepad/ModLoadProbe.java')],check=True)
    results = []
    def probe(mode, runtime, jars, transformed, properties=()):
        args=[runtime,'-Xverify:all','-Djava.io.tmpdir='+str(work),'-Djna.tmpdir='+str(work),'-javaagent:'+str(AGENT),'-Damcl.gamepad.sdl2.dir='+str(natives),
              *properties,'-cp',str(classes),'com.amcl.gamepad.ModLoadProbe',mode,*map(str,jars)]
        result=subprocess.run(args,text=True,errors='replace',capture_output=True,timeout=45)
        if result.returncode or any(line.startswith('[AMCL] SDL2 binding ') and ' -> ' in line for line in result.stderr.splitlines())!=transformed or 'SDL2_BINDING_OK' not in result.stdout:
            raise RuntimeError(result.stdout+'\n'+result.stderr)
        results.append(result.stdout.strip()+' input='+jars[0].name+' transformed='+str(transformed))
    for mode,file in old.items():
        probe(mode,java8 or java,[file],True)
    if forge112:
        if not java8: raise ValueError('--forge-112 requires an explicit Java 8 runtime')
        results.extend(probe_forge(inputs,work,classes,natives,old,java8,download))
    probe('jna',java,[inner,jna],True)
    probe('unknown',java8 or java,[old['jamepad']],False)
    # 同一 SDL2 裸名在不同 JNA 插件和用户指定目录下必须找到正确库；只从已锁的游戏依赖取样。
    public_name = 'libSDL2.dylib' if mac else 'libSDL2.so' if linux else 'SDL2.dll'
    unrelated = 'libamcl_unrelated_compat.dylib' if mac else 'libamcl_unrelated_compat.so' if linux else 'amcl_unrelated_compat.dll'
    userdir = work/'user-override'
    userdir.mkdir()
    data = (natives/'libSDL2.so').read_bytes()
    (natives/public_name).write_bytes(data)
    (userdir/public_name).write_bytes(data)
    (natives/unrelated).write_bytes(data)
    versions=json.loads((ROOT/'JavaCpuAgent/oshi-test-inputs.json').read_text(encoding='utf8'))['versions']
    libraries={l['path']:l for v in versions for l in v['libraries'] if '/jna/jna/' in l['path']}
    if len(libraries)!=6: raise ValueError('Reconcile the six verified JNA class identities with the dependency lock')
    cache=external_output_path(jna_inputs) if jna_inputs else inputs/'libraries'
    for key,entry in libraries.items():
        jar = cache/key
        if not jar.exists() and download:
            jar.parent.mkdir(parents=True,exist_ok=True)
            with urllib.request.urlopen(entry['url'],timeout=60) as response: contents=response.read()
            if hashlib.sha1(contents).hexdigest()!=entry['sha1']: raise ValueError('Unpinned JNA '+key)
            jar.write_bytes(contents)
        contents=jar.read_bytes()
        if len(contents)!=entry['size'] or hashlib.sha1(contents).hexdigest()!=entry['sha1']: raise ValueError('Unpinned JNA '+key)
        runtime=java8 or java
        probe('jna-name',runtime,[jar],True,['-Damcl.test.expected='+str(natives/public_name)])
        paths=str(work/'missing')+os.pathsep+str(userdir)
        probe('jna-user',runtime,[jar],True,['-Djna.library.path='+paths,'-Damcl.test.expected='+str(userdir/public_name)])

    receipt = {'agentSha256':hashlib.sha256(AGENT.read_bytes()).hexdigest(),'cases':results}
    (output/(work.name+'.json')).write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf8')
    if work.parent!=output.resolve() or work.is_symlink(): raise ValueError('Unexpected test directory')
    shutil.rmtree(work)
    for line in results: print(line)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs',required=True)
    parser.add_argument('--output',required=True)
    parser.add_argument('--forge-112',action='store_true',help='实际 Forge 1.12.2 Side/Deobfuscation + Java 8')
    parser.add_argument('--java8',help='实际 Java 8 可执行文件，用于两种旧式 JNI 绑定')
    parser.add_argument('--jna-inputs',help='可选的 OSHI/JNA Maven 缓存根')
    parser.add_argument('--download',action='store_true')
    args=parser.parse_args()
    run(args.inputs,args.output,args.download,args.java8,args.jna_inputs,args.forge_112)
