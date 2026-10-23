"""真实 MG frontend owner 宿主资格；与普通 preflight 的无 GPU TU 回归互补。

输入必须是完整 Linux GL host DSO（含真实 MG core/生产包装），不能传 OHOS 库或只
有 raw MG 的普通 SO。运行器编译本仓实际冻结 runtime/owner、逐字抽取 GLFW 属性与
零分配 client API 门；X11 窗口仅属于测试进程，EGL/GL 表由唯一 provider 提供。
WindowHost generation 的链接边界是明确宿主桩，因此成功不代表 OHOS broker、HAP、
物理设备或完整 GL 核心资格。每个读取顺序使用独立进程、配置和未复用的输出目录。
"""
from pathlib import Path
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def sha(path):
    """摘要绑定实取字节，不以文件名、存在性或旧收据代替来源。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()

def stamp():
    return datetime.datetime.now().astimezone().isoformat()

def wsl_path(value):
    return subprocess.check_output(['wsl','-d','Ubuntu','--exec','wslpath','-a',str(value)],text=True).strip()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gl-host',required=True,type=Path,help='完整 Linux libamcl_gl_host.so')
    parser.add_argument('--expected-mg-commit',required=True,help='被测 GL host 必须报告的真实 MG commit')
    parser.add_argument('--output',required=True,type=Path,help='仓外新输出目录；已有目录拒绝覆盖')
    parser.add_argument('--x11-include',type=Path,help='Xlib/Xutil 头根，Linux缺省/usr/include，可为外置解包目录')
    parser.add_argument('--driver-dir',type=Path,help='显式 Linux transport 依赖目录，进程期追加到LD_LIBRARY_PATH')
    parser.add_argument('--sanitizers',action='store_true',help='实际主runtime及宿主harness启用ASan/UBSan；外部MG DSO不重编译')
    args=parser.parse_args()
    if len(args.expected_mg_commit)!=40 or any(c not in '0123456789abcdef'for c in args.expected_mg_commit):
        raise ValueError('expected MG commit must be exact lowercase SHA-1')
    if os.name=='nt':
        # 固定 WSL distro，路径通过 wslpath 转换；不拼 shell 命令，不改用户全局环境。
        command=['wsl','-d','Ubuntu','--exec','python3',wsl_path(Path(__file__)),
          '--gl-host',wsl_path(args.gl_host.resolve()),'--output',wsl_path(args.output.resolve()),
          '--expected-mg-commit',args.expected_mg_commit]
        if args.x11_include is not None:
            command.extend(['--x11-include',wsl_path(args.x11_include.resolve())])
        if args.driver_dir is not None:
            command.extend(['--driver-dir',wsl_path(args.driver_dir.resolve())])
        if args.sanitizers:
            command.append('--sanitizers')
        return subprocess.run(command,check=False,timeout=300).returncode
    args.x11_include=args.x11_include or Path('/usr/include')
    sys.path.insert(0,str(ROOT/'scripts'))
    from lib.workspace_paths import external_output_path
    output=external_output_path(args.output,ROOT)
    output.mkdir(parents=True,exist_ok=False)
    if not args.gl_host.is_file() or not (args.x11_include/'X11/Xlib.h').is_file():
        raise ValueError('missing explicit GL host or X11 headers')
    # 生产公共头是错误码唯一来源；独立harness常量曾掩盖真实SDK缺定义。
    # 逐字抽宏并与现役LWJGL上游Java数值校准，缺失/重复/不一致前置拒绝。
    import re
    compat_header=ROOT/'entry/src/main/cpp/glfw/glfw_compat.h'
    declarations=re.findall(r'^#define GLFW_API_UNAVAILABLE\s+(0x[0-9a-fA-F]+)\s*$',compat_header.read_text(encoding='utf-8'),re.M)
    upstream=ROOT/'prebuilt/lwjgl3/lwjgl3_src/modules/lwjgl/glfw/src/generated/java/org/lwjgl/glfw/GLFW.java'
    values=re.findall(r'\bGLFW_API_UNAVAILABLE\s*=\s*(0x[0-9a-fA-F]+)',upstream.read_text(encoding='utf-8'))
    if len(declarations)!=1 or len(values)!=1 or int(declarations[0],16)!=int(values[0],16):
        raise ValueError('production GLFW API error constant missing/duplicated/differs from upstream ABI')
    (output/'glfw_error_constants.inc').write_text('#define GLFW_API_UNAVAILABLE '+declarations[0]+'\n',encoding='utf-8')
    spec=importlib.util.spec_from_file_location('source_recipe',ROOT/'scripts/generate-desktop-review-tests.py')
    recipe=importlib.util.module_from_spec(spec);spec.loader.exec_module(recipe)
    attributes=recipe.function((ROOT/'entry/src/main/cpp/glfw/glfw_callbacks.cpp').read_text(encoding='utf-8'),'glfwGetWindowAttrib')
    (output/'glfw_attribute.inc').write_text(attributes,encoding='utf-8')
    dispatch=(ROOT/'entry/src/main/cpp/glfw/egl_dispatch.h').read_text(encoding='utf-8')
    signatures=['inline bool UsesDesktopOpenGlContext()','inline bool RuntimeProfileIs(const char* id)']
    if any(dispatch.count(signature)!=1 for signature in signatures):
        raise ValueError('frozen runtime predicate production signature changed')
    # 既有 function 抽取器不接受 inline；复用它同一注释/字符串屏蔽的 block，而不
    # 删除 inline 或手写等价函数，仍保留完整生产正文及当前 source/hash 身份。
    predicate='\n'.join(recipe.block(dispatch,dispatch.index(signature))for signature in signatures)
    (output/'desktop_predicate.inc').write_text(predicate,encoding='utf-8')
    creation=recipe.function((ROOT/'entry/src/main/cpp/glfw/glfw_compat.cpp').read_text(encoding='utf-8'),'glfwCreateWindow')
    needle='    if (!admittedVulkanWindow && amcl::desktop::RuntimeProfileIs("mobileglues")'
    if creation.count(needle)!=1:
        raise ValueError('client API production guard changed; update exact extraction')
    start=creation.index(needle);brace=creation.index('{',start);end=brace+1;level=1
    while level:
        if creation[end]=='{':level+=1
        if creation[end]=='}':level-=1
        end+=1
    # 只适配原函数指针返回值为测试前置门整数，正文和 callback 错误码保持逐字生产来源。
    guard=creation[start:end].replace('return nullptr;','return 0;')
    (output/'glfw_client_admission.inc').write_text('int TestClientAdmission(){const bool admittedVulkanWindow=false;\n'+
      guard+'\n++creationTailCalls;return 1;}\n',encoding='utf-8')
    shutil.copyfile(args.gl_host,output/'libamcl_gl_host.so')
    boundary=output/'window_boundary.cpp'
    boundary.write_text('// 非OHOS宿主仅提供链接需要的只读generation；不制造GL/context/NativeWindow。\n'+
      '#include <cstdint>\nextern "C" uint64_t amclWindowHostPeekGeneration(){return 1;}\n',encoding='utf-8')
    production=[ROOT/'entry/src/main/cpp/platform'/name for name in ['graphics_runtime_binding.cpp','graphics_egl_context.cpp',
      'graphics_features.cpp','graphics_gl_lookup.cpp','graphics_observation.cpp']]
    source=ROOT/'tests/graphics-semantics/frontend_owner_host.cpp'
    scene=ROOT/'tests/graphics-semantics/depth_range_scene.cpp'
    runtime=output/'libamcl_graphics_runtime.so'
    binary=output/'frontend_owner'
    commands=[['g++','-std=c++17','-shared','-fPIC','-fvisibility=hidden','-pthread','-Wl,-Bsymbolic-functions',
      '-Wl,--no-undefined','-I'+str(ROOT/'prebuilt/khronos-egl-headers'),*map(str,production),str(boundary),'-ldl','-o',str(runtime)],
      ['g++','-std=c++17','-O0','-g','-pthread','-I'+str(ROOT/'entry/src/main/cpp/platform'),
      '-I'+str(ROOT/'prebuilt/khronos-egl-headers'),'-I'+str(ROOT/'tests/graphics-semantics'),
      '-I'+str(args.x11_include),'-I'+str(output),str(source),str(scene),'-L'+str(output),'-lamcl_graphics_runtime',
      '-Wl,-rpath,'+str(output),'-Wl,-l:libX11.so.6','-ldl','-o',str(binary)]]
    if args.sanitizers:
        for command in commands:
            command[1:1]=['-fsanitize=address,undefined','-fno-omit-frame-pointer']
    evidence={'schemaVersion':1,'startedAt':stamp(),'scope':'Linux real provider/owner; OHOS WindowHost boundary is fixture',
      'mgCommit':args.expected_mg_commit,'glHostInput':str(args.gl_host.resolve()),'glHostSha256':sha(args.gl_host),
      'sanitizedMainRuntimeAndHarness':args.sanitizers,'driverDirectory':str(args.driver_dir.resolve())if args.driver_dir else None,
      'sources':{str(p.relative_to(ROOT)):sha(p)for p in [*production,source,scene,
        ROOT/'entry/src/main/cpp/platform/graphics_profile_mirror.generated.h',ROOT/'entry/src/main/cpp/glfw/glfw_callbacks.cpp',
        ROOT/'entry/src/main/cpp/glfw/glfw_compat.cpp',ROOT/'entry/src/main/cpp/glfw/egl_dispatch.h',compat_header,upstream]},'commands':commands,'runs':[]}
    for index,command in enumerate(commands):
        with (output/f'compile-{index}.log').open('w',encoding='utf-8')as log:
            subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=90)
    for order in ['low-first','high-first']:
        run=output/order;run.mkdir();cfg=run/'mg';cfg.mkdir()
        (cfg/'config.json').write_text('{"customGLVersion":40,"enableANGLE":2,"enableFSR":0,"hideMG":0,"maxGlslCacheSize":32}',encoding='utf-8')
        environment=os.environ.copy()
        for key in ['AMCL_GRAPHICS_RUNTIME_V1','AMCL_GRAPHICS_RUNTIME_SERVICE_V2']:
            environment.pop(key,None)
        environment.update({'MG_DIR_PATH':str(cfg),'MG_ANGLE_DIR':'','EGL_PLATFORM':'x11','LIBGL_ALWAYS_SOFTWARE':'1',
          'MESA_LOADER_DRIVER_OVERRIDE':'llvmpipe','NEED_OPENGL':'1'})
        if args.driver_dir is not None:
            environment['LD_LIBRARY_PATH']=str(args.driver_dir.resolve())+(':'+environment['LD_LIBRARY_PATH']if environment.get('LD_LIBRARY_PATH')else '')
        started=stamp()
        with (run/'result.log').open('w',encoding='utf-8')as log:
            result=subprocess.run([str(binary),order],env=environment,stdout=log,stderr=subprocess.STDOUT,timeout=120)
        text=(run/'result.log').read_text(encoding='utf-8')
        # 执行结果、唯一完整末尾、生产身份、每次标准交叉查询和共享 scene 同时成立才通过。
        # 截断/旧/错库/环境失败都保留真实退出码并阻断，不能靠一个 PASS 字样接受。
        identity=':source='+args.expected_mg_commit+':'
        complete=result.returncode==0 and text.count('FINAL failures=0 contexts=0 permits=0')==1 and \
          text.rstrip().endswith('FINAL failures=0 contexts=0 permits=0') and identity in text and \
          text.count('IDENTITY turn=')==4 and 'SHARED_SCENES depth=83/26/24/0 initializer=16/2/2/0' in text and \
          'LIFECYCLE primary-parking-attach context-retained=1 wrong-thread-refused=1 geometry=64x64' in text
        evidence['runs'].append({'order':order,'startedAt':started,'finishedAt':stamp(),'exitCode':result.returncode,
          'complete':complete,'logSha256':sha(run/'result.log')})
        print(order,'PASS'if complete else 'FAIL','exit='+str(result.returncode),flush=True)
    evidence.update({'finishedAt':stamp(),'runtimeSha256':sha(runtime),'harnessSha256':sha(binary)})
    (output/'receipt.json').write_text(json.dumps(evidence,indent=2),encoding='utf-8')
    return 0 if all(run['complete']for run in evidence['runs'])else 1

if __name__=='__main__':
    raise SystemExit(main())
