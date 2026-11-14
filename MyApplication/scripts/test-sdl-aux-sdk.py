"""编译已应用完整series的真实SDK入口与host块，包含初始化回滚和有界源码负控。

调用者提供SDL完整源码或精确补丁展开目录，输出必须显式外置；不下载、不改SDK输入。
这里只替代driver/系统线程/graphics owner边界，不把宿主测试当作OHOS整库或设备通过。
"""
from pathlib import Path
from datetime import datetime
import argparse,hashlib,json,subprocess,re
from lib.host_cpp import compile_cpp
p=argparse.ArgumentParser();p.add_argument('--sdk-source',required=True);p.add_argument('--output',required=True);a=p.parse_args()
repo=Path(__file__).resolve().parents[1];work=Path(a.sdk_source).resolve();out=Path(a.output).resolve();out.mkdir(exist_ok=False)
core=(work/'src/SDL.c').read_text();start=core.index('static AMCL_SdlHostRuntime SDL_amclHostRuntime;');end=core.index('// Private helper to increment a subsystem',start)
block=core[start:end].rsplit('#endif',1)[0]
def prefix(path,signature,stop,name,tail):
    s=path.read_text();i=s.index(signature);j=s.index(stop,i);original=re.search(r'([A-Za-z_]\w*)\s*\(',signature)[1]
    return s[i:j].replace(signature,signature.replace(original,name,1),1)+tail
finish=core[core.index('    (void)flags_initialized;'):core.index('\nbool SDL_Init(SDL_InitFlags flags)')]
init=prefix(work/'src/SDL.c','bool SDL_InitSubSystem(SDL_InitFlags flags)','    if (!SDL_MainIsReady)','TestInit',
    '    ++subsystemEffects;flags_initialized=flags;\n    if(retireDuringDriver)retireRoot();\n'+finish)
cleanup=prefix(work/'src/SDL.c','void SDL_QuitSubSystem(SDL_InitFlags flags)','    // Shut down requested initialized subsystems','TestCleanup','    ++cleanupEffects;\n}\n')
video=prefix(work/'src/video/SDL_video.c','bool SDL_VideoInit(const char *driver_name)','    SDL_VideoDevice *video;','TestVideo','    ++videoEffects;return true;\n}\n')
gpu=prefix(work/'src/gpu/SDL_gpu.c','SDL_GPUDevice *SDL_CreateGPUDeviceWithProperties(SDL_PropertiesID props)','#ifndef SDL_GPU_DISABLED','TestGpu','    ++gpuEffects;static SDL_GPUDevice device{};return &device;\n}\n')
text=(repo/'entry/src/main/cpp/tests/host/sdl_aux_sdk.cpp.in').read_text()
for key,value in {'POLICY':(repo/'entry/src/main/cpp/platform/sdl_aux_runtime_policy.h').as_posix(),
    'GRAPHICS_ABI':(work/'src/video/openharmony/graphics_runtime_abi.h').as_posix(),
    'HOST_HEADER':(work/'src/core/openharmony/SDL_amclhostruntime.h').as_posix(),
    'HOST_BLOCK':block,'INIT_GATE':init,'CLEANUP_GATE':cleanup,'VIDEO_GATE':video,'GPU_GATE':gpu}.items():text=text.replace('@'+key+'@',value)
variants=[('production',text,0)]
for name,before,after in [
    ('missing-cleanup-guard','if (!SDL_AMCL_AllowCleanup())','if (false)'),
    ('mutable-fork-identity','if(bound)return (uint64_t)bound==pid;','/* negative: trust mutable environment */'),
    ('missing-final-init-check','if (!SDL_AMCL_InitCommit())','if (false)'),
    ('missing-precommit-active','result=SDL_AMCL_AuxOperation(&identity,AMCL_SDL_AUX_PEEK_ACTIVE,pid,tid);','result=AMCL_SDL_AUX_READY;'),
    ('missing-postcommit-active','const int active=SDL_AMCL_AuxOperation(&identity,AMCL_SDL_AUX_PEEK_ACTIVE,pid,tid);','const int active=AMCL_SDL_AUX_READY;'),
    ('early-fork-video','bool SDL_AMCL_AllowVideo(void)\n{\n    if(!SDL_AMCL_CheckProcess())return false;', 'bool SDL_AMCL_AllowVideo(void)\n{'),
    ('early-fork-events','/* Init已锁PID但尚未发布mode时，fork child也必须在SDK错误TLS/锁前拒绝。 */\n    if(!SDL_AMCL_CheckProcess())return false;', '/* negative: no immutable PID before event state */')]:
    assert before in text,name;variants.append((name,text.replace(before,after,1),7))
results=[]
for name,body,wanted in variants:
    source=out/(name+'.cpp');binary=out/(name+'.exe');source.write_text(body,encoding='utf-8')
    compile_cpp(source,binary);run=subprocess.run([str(binary)],capture_output=True,timeout=20)
    (out/(name+'.stdout')).write_bytes(run.stdout);(out/(name+'.stderr')).write_bytes(run.stderr)
    results.append({'case':name,'exitCode':run.returncode,'expected':wanted,'passed':run.returncode==wanted,'sourceSha256':hashlib.sha256(source.read_bytes()).hexdigest()})
    print(name,run.returncode,run.stdout.decode(),run.stderr.decode())
    if run.returncode==wanted:binary.unlink();binary.with_suffix('.obj').unlink(missing_ok=True)
(out/'receipt.json').write_text(json.dumps({'at':datetime.now().astimezone().isoformat(),'results':results,'scope':'verbatim SDK gates; fake driver/owner; not full SDK or device'},indent=2)+'\n')
assert all(r['passed']for r in results)
