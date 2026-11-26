"""为实际使用 SDL2 的手柄模组重建 OHOS SDL2、sdl2gdx 和 Jamepad。原模组仅作签名输入。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import urllib.request
import zipfile

from lib.workspace_paths import external_output_path

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / 'prebuilt/mod-natives/sdl2'


def archive_tree(archive, target, prefix):
    """仅展开锁定归档指定的源目录，不借用宿主上的系统 SDL 头。"""
    with zipfile.ZipFile(archive) as source:
        for member in source.infolist():
            if member.is_dir() or not member.filename.startswith(prefix):
                continue
            path = (target / member.filename[len(prefix):]).resolve()
            if not path.is_relative_to(target):
                raise ValueError('Invalid source path')
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(source.read(member))


def checked_inputs(directory, download):
    """所有入口在消费前验证内容。只有显式请求时才下载编译输入。"""
    directory.mkdir(parents=True, exist_ok=True)
    for name, (url, digest) in json.loads((RECIPE/'sources.json').read_text(encoding='utf8')).items():
        path = directory/name
        if not path.exists() and download:
            with urllib.request.urlopen(url, timeout=90) as response:
                data = response.read()
            if hashlib.sha256(data).hexdigest() != digest:
                raise ValueError('Unpinned download: '+name)
            path.write_bytes(data)
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError('Unpinned input: '+name)


def adapt_controller_threads(compat, body):
    """独立 SDL 的窗口/系统事件泵及销毁归初始化线程；手柄状态允许 Mod 从轮询线程刷新。"""
    table = compat/'src/sdl3_syms.h'
    symbols = table.read_text(encoding='utf8')
    previous = 'SDL3_SYM(Uint64,GetCurrentThreadID,(void),(),return)'
    if symbols.count(previous) != 1 or 'IsMainThread,' in symbols:
        raise ValueError('SDL3 controller thread lookup changed')
    symbols = symbols.replace(previous,previous+'\nSDL3_SYM(bool,IsMainThread,(void),(),return)')
    # 原 passthrough 会直接生成 SDL2_PumpEvents；只保留 SDL3 符号加载，让下面的入口按线程分流。
    pump = 'SDL3_SYM_PASSTHROUGH(void,PumpEvents,(void),(),)'
    if symbols.count(pump)!=1:
        raise ValueError('SDL2 event pump dispatch changed')
    table.write_text(symbols.replace(pump,'SDL3_SYM(void,PumpEvents,(void),(),)'),encoding='utf8')
    # 宿主本地的同一无窗口配方也使用实际 OS PID；fork 后不调用任何 SDL 线程或锁 API。
    gate = RECIPE/'controller-thread.h'
    (compat/'src/amcl_controller_thread.h').write_bytes(gate.read_bytes())
    loader = 'static int\nLoadSDL3(void)'
    loaded = '        okay = LoadSDL3Library();'
    ready = '    PostInitSubsystem(new_flags);'
    if any(body.count(x)!=1 for x in (loader,loaded,ready)):
        raise ValueError('SDL2 controller process or lifecycle entry changed')
    body = body.replace(loader,'#include "amcl_controller_thread.h"\n\n'+loader)
    body = body.replace(loaded,loaded+'\n        if (okay && !amcl_loaded_pid) amcl_loaded_pid = AMCL_PID();')
    init = 'static int InitSubsystemInternal(SDL_InitFlags flags)\n{\n'
    if body.count(init)!=1:
        raise ValueError('SDL2 init entry changed')
    body = body.replace(init,init+'    if (!AMCL_CurrentProcess()) return -1;\n')
    body = body.replace(ready,ready+'\n    if (result == 0) AMCL_PublishJoystickState();')
    entry = 'SDL_DECLSPEC int SDLCALL\nSDL_PollEvent(SDL2_Event *event2)'
    if body.count(entry)!=1:
        raise ValueError('SDL2 event entry changed')
    body = body.replace(entry, '''SDL_DECLSPEC void SDLCALL
SDL_PumpEvents(void)
{
    /* 无窗口 SDK 在成功 Init 时锁定实际 owner；完整泵仍由 SDK 再核 PID、会话、线程。
     * 工作线程只同步已初始化的手柄快照，不能消费窗口队列或执行主线程回调。 */
    if (!AMCL_CurrentProcess()) return;
    if (SDL3_IsMainThread()) {
        SDL3_PumpEvents();
    } else {
        AMCL_RefreshGamepads();
    }
}

''' + entry)

    # 全局退出会先释放 SDL2 设备表；单子系统退出也先改 timer 引用。
    # AudioQuit/VideoQuit 会循环降低引用计数，错线程若进入循环而 SDL3 拒绝退出会永久等待。
    for signature in ('SDL_Quit(void)','SDL_QuitSubSystem(Uint32 flags)','SDL_AudioQuit(void)','SDL_VideoQuit(void)'):
        entry = '\n'+signature+'\n{\n'
        if body.count(entry) != 1:
            raise ValueError('SDL2 controller shutdown entry changed: '+signature)
        begin = body.index(entry)+len(entry)
        end = body.index('\n}\n',begin)
        original = body[begin:end]
        if 'return;' in original:
            raise ValueError('SDL2 shutdown gained an early return: '+signature)
        resume = 'false' if signature=='SDL_Quit(void)' else 'true'
        body = (body[:begin]+'    if (!AMCL_CurrentProcess() || !SDL3_IsMainThread || !SDL3_IsMainThread()) return;\n'
                +'    AMCL_BeginShutdown();\n'+original+'\n    AMCL_EndShutdown('+resume+');'+body[end:])
    return body


def build(args):
    inputs = external_output_path(args.inputs)
    out = external_output_path(args.out)
    if out.exists():
        raise ValueError('Select a new output directory')
    out.mkdir(parents=True)
    checked_inputs(inputs,args.download)
    sdk = args.native_sdk.resolve()
    jdk = args.jdk8.resolve()
    env = dict(os.environ, PATH=str(jdk/'bin') + os.pathsep + os.environ['PATH'])
    def run(argv, cwd=out):
        subprocess.run([str(x) for x in argv],cwd=cwd,env=env,check=True)

    compat = out/'compat'
    archive_tree(inputs/'sdl2-compat.zip',compat,'sdl2-compat-release-2.32.74/')
    # 对应上游 SDL2COMPAT_X11=OFF 的 configure_file；OHOS 没有 X11 窗口。
    config = compat/'include/SDL2/SDL_config_unix.h.cmake'
    header = config.read_text(encoding='utf8').replace('#cmakedefine SDL2COMPAT_DISABLE_X11',
                                                     '#define SDL2COMPAT_DISABLE_X11')
    if '#cmakedefine' in header:
        raise ValueError('Unresolved SDL2 platform configuration')
    config.with_suffix('').write_text(header,encoding='utf8')
    source = compat/'src/sdl2_compat.c'
    body = source.read_text(encoding='utf8')
    # 保留诊断来源，去掉上游写入二进制的主机编译时间，允许不同目录/时间重建。
    date_marker = '"built on " __DATE__ " at " __TIME__ ", "'
    if body.count(date_marker) != 1:
        raise ValueError('SDL2 build identity changed')
    body = body.replace(date_marker,'"AMCL OHOS build from release-2.32.74, "')
    old = '#define LoadSDL3Library() ((Loaded_SDL3 = dlopen(SDL3_LIBNAME, RTLD_LOCAL|RTLD_NOW)) != NULL)'
    if body.count(old) != 1:
        raise ValueError('SDL3 load site changed')
    # 限定到同一 HAP 内的独立手柄 SDL。SDL2 的退出和过滤器只访问这个实例。
    body = body.replace(old, '''static bool LoadSDL3Library(void) {
        Dl_info image;
        char path[4096];
        if (!dladdr((const void *)LoadSDL3Library, &image) || !image.dli_fname) return false;
        const char *slash = strrchr(image.dli_fname, '/');
        const char basename[] = "/libamcl_sdl_controller.so";
        if (!slash || slash - image.dli_fname + sizeof(basename) > sizeof(path)) return false;
        const size_t prefix = (size_t)(slash - image.dli_fname);
        memcpy(path, image.dli_fname, prefix);
        memcpy(path + prefix, basename, sizeof(basename));
        Loaded_SDL3 = dlopen(path, RTLD_LOCAL | RTLD_NOW);
        return Loaded_SDL3 != NULL;
    }''')
    source.write_text(adapt_controller_threads(compat, body),encoding='utf8')
    sdl3 = json.loads((ROOT/'prebuilt/sdl3/build-provenance.json').read_text(encoding='utf8'))['source']['commit']
    archive = out/'headers.zip'
    run(['git','-C',args.sdl3_repo.resolve(),'archive','--format=zip','--output',archive,sdl3,'include/SDL3'])
    headers = out/'headers'
    archive_tree(archive,headers,'include/')
    bin_dir = sdk/'llvm/bin'
    suffix = '.exe' if os.name == 'nt' else ''
    cc = bin_dir/('clang'+suffix)
    cxx = bin_dir/('clang++'+suffix)
    flags = ['--target=aarch64-linux-ohos','--sysroot='+str(sdk/'sysroot'),'-ffile-prefix-map='+str(out)+'=.',
             '-O2','-fPIC','-shared',
             '-Wl,--build-id=sha1','-Wl,--no-undefined','-D_GNU_SOURCE','-I'+str(compat/'include/SDL2')]
    run([cc,*flags,'-I'+str(headers),'-fvisibility=hidden','-DSDL2COMPAT_REVISION="2.32.74-amcl"',
         source,compat/'src/dynapi/SDL_dynapi.c','-Wl,-soname,libSDL2.so','-ldl','-lm','-o',out/'libSDL2.so'])
    cp=os.pathsep.join(str(inputs/v) for v in ['jnigen.jar','javaparser.jar'])
    run([jdk/'bin/javac','-encoding','UTF-8','-cp',cp,'-d',out,RECIPE/'GenerateBindings.java'])
    includes = ROOT/'prebuilt/mod-natives/imgui-java/jni/jni-headers'
    for name, package, prefix, binding, classes in [
        ('sdl2gdx','sdl2gdx.zip','sdl2gdx-1.0.5/src/','controllable-gdx.jar',['org/libsdl/SDL']),
        ('jamepad','jamepad-e1fadd1.zip','Jamepad-e1fadd1bd2a3a4b0bf0b7fd2653a15024b0811cb/src/','controllable-jamepad.jar',
         ['com/studiohartman/jamepad/ControllerManager','com/studiohartman/jamepad/ControllerIndex'])]:
        src = out/(name+'-src')
        generated = out/(name+'-jni')
        generated.mkdir()
        with zipfile.ZipFile(inputs/package) as bundle:
            for class_name in classes:
                file = src/(class_name+'.java')
                file.parent.mkdir(parents=True,exist_ok=True)
                file.write_bytes(bundle.read(prefix+class_name+'.java'))
        run([jdk/'bin/java','-Dfile.encoding=UTF-8','-cp',str(out)+os.pathsep+cp,'GenerateBindings',
             src,inputs/binding,generated])
        objects = sorted(generated.glob('*.cpp'))
        if len(objects) != len(classes):
            raise ValueError('Missing generated JNI for '+name)
        run([cxx,*flags,'-std=c++17','-fvisibility=hidden','-I'+str(includes),'-I'+str(includes/'linux'),
             '-I'+str(generated),*objects,'-L'+str(out),'-lSDL2','-Wl,-soname,lib'+name+'.so','-o',out/('lib'+name+'.so')])
    for so in sorted(out.glob('*.so')):
        run([bin_dir/('llvm-strip'+suffix),'--strip-unneeded',so])
        print(so.name,hashlib.sha256(so.read_bytes()).hexdigest(),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for option in ['inputs','out','jdk8','native-sdk','sdl3-repo']:
        parser.add_argument('--'+option,type=Path,required=True)
    parser.add_argument('--download',action='store_true')
    build(parser.parse_args())
