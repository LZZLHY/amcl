"""实际 SDL2_PumpEvents 在游戏线程初始化、Mod 工作线程取样时必须交付手柄，不运行主泵。"""
import argparse
import ctypes as C
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
from lib.host_cpp import configure_host_cmake, find_host_cmake
from lib.host_test_lifecycle import HostTestScope
from lib.workspace_paths import external_output_path

ROOT = Path(__file__).resolve().parents[1]
DEVICE = b'AMCL worker test pad'


def api(dll, name, result, *arguments):
    fn = getattr(dll, name)
    fn.restype, fn.argtypes = result, list(arguments)
    return fn


def exercise(stage):
    """同一进程内运行真实 SDL2 + 独立 SDL3，只有鸿蒙设备读回由夹具控制。"""
    # 固定已经加载的实际 shared library，不允许误取主机先前安装的 SDL。
    sdk = C.CDLL(str(stage/'SDL3.dll'))
    compat = C.CDLL(str(stage/'SDL2.dll'))
    publish = api(sdk,'amclTestPublishController',None,C.c_int,C.c_float,C.c_int)
    init = api(compat,'SDL_Init',C.c_int,C.c_uint32)
    pump = api(compat,'SDL_PumpEvents',None)
    count = api(compat,'SDL_NumJoysticks',C.c_int)
    name = api(compat,'SDL_JoystickNameForIndex',C.c_char_p,C.c_int)
    opened = api(compat,'SDL_GameControllerOpen',C.c_void_p,C.c_int)
    attached = api(compat,'SDL_GameControllerGetAttached',C.c_int,C.c_void_p)
    axis = api(compat,'SDL_GameControllerGetAxis',C.c_int16,C.c_void_p,C.c_int)
    button = api(compat,'SDL_GameControllerGetButton',C.c_uint8,C.c_void_p,C.c_int)
    close = api(compat,'SDL_GameControllerClose',None,C.c_void_p)
    quit_sdl = api(compat,'SDL_Quit',None)
    was_init = api(compat,'SDL_WasInit',C.c_uint32,C.c_uint32)
    is_main = api(sdk,'SDL_IsMainThread',C.c_bool)
    callback_type = C.CFUNCTYPE(None,C.c_void_p)
    schedule = api(sdk,'SDL_RunOnMainThread',C.c_bool,callback_type,C.c_void_p,C.c_bool)
    api(sdk,'SDL_SetMainReady',None)()
    # 测试机可以有其它物理手柄，始终按具名夹具找当前 index。
    def index():
        return next((i for i in range(count()) if name(i)==DEVICE),-1)
    publish(1,0,0)
    assert init(0x6200)==0 and is_main() and index()>=0
    original = opened(index())
    assert original and axis(original,0)==0
    callbacks, errors = [], []
    owner = threading.get_ident()

    @callback_type
    def owner_callback(_):
        callbacks.append(threading.get_ident())

    def poll_on_worker():
        try:
            assert not is_main() and schedule(owner_callback,None,False)
            # 对应 Controllable 的轮询顺序，worker 只会 PumpEvents，不替它直接调用 UpdateGamepads。
            publish(1,0.75,1);pump()
            assert axis(original,0)>22000 and button(original,0)==1, 'worker failed to deliver first input'
            publish(1,-0.8,0);pump()
            assert axis(original,0)<-22500 and button(original,0)==0, 'continuous axis/button changes lost'
            publish(1,0,0);pump()
            assert axis(original,0)==0, 'neutral input lost'
            publish(0,0,0);pump()
            assert not attached(original) and index()<0, 'worker failed to see disconnection'
            publish(1,0.5,1);pump()
            assert not attached(original) and index()>=0
            reconnected=opened(index())
            assert reconnected and axis(reconnected,0)>14500 and button(reconnected,0)==1
            close(reconnected)
            quit_sdl()
            assert not callbacks, 'worker ran the full SDL event pump/main-thread callback'
        except BaseException as exc:
            errors.append(exc)

    worker=threading.Thread(target=poll_on_worker,name='Controller Input',daemon=True)
    worker.start();worker.join(8)
    assert not worker.is_alive(), 'controller worker hung'
    if errors:
        raise errors[0]
    assert not callbacks and was_init(0x200)==0x200, 'worker took ownership or quit the owner'
    pump()
    assert callbacks==[owner], 'original owner did not service its own event pump'
    close(original)
    # 真实重叠下，owner 不得与在途 SDL_UpdateJoysticks 并发销毁；也不能吞掉引用或禁止合法重开。
    hold=api(sdk,'amclTestHoldRead',None,C.c_int)
    entered=api(sdk,'amclTestReadEntered',C.c_int)
    quit_sub=api(compat,'SDL_QuitSubSystem',None,C.c_uint32)
    init_sub=api(compat,'SDL_InitSubSystem',C.c_int,C.c_uint32)
    assert init_sub(0x2200)==0
    quit_sub(0x2200)
    assert was_init(0x2200)==0x2200
    retained=opened(index());publish(1,0.65,1)
    keeper=threading.Thread(target=pump,daemon=True);keeper.start();keeper.join(2)
    assert not keeper.is_alive() and axis(retained,0)>19000
    close(retained)
    hold(1)
    pending=threading.Thread(target=pump,daemon=True)
    pending.start()
    deadline=time.monotonic()+3
    while not entered() and time.monotonic()<deadline:
        time.sleep(.001)
    if not entered():
        hold(0)
        raise AssertionError('worker failed to enter the actual SDK reader')
    release=threading.Timer(.08,lambda:hold(0));release.start()
    quit_sub(0x2200);pending.join(3);release.join(3)
    assert not pending.is_alive() and was_init(0x2200)==0
    pump_stopped=threading.Thread(target=pump,daemon=True)
    pump_stopped.start();pump_stopped.join(2)
    assert not pump_stopped.is_alive() and was_init(0x2200)==0
    assert init_sub(0x2200)==0 and index()>=0
    reopened=opened(index())
    publish(1,-0.6,1)
    resumed=threading.Thread(target=pump,daemon=True);resumed.start();resumed.join(2)
    assert not resumed.is_alive() and axis(reopened,0)<-17500
    close(reopened);quit_sdl()
    assert was_init(0x200)==0
    print('PASS SDL2 worker axes/buttons/neutral, disconnect/reconnect, owner-only callbacks/quit, concurrent shutdown and owner reinit',flush=True)


def build_and_test(args):
    if os.name!='nt':
        raise ValueError('This real dual-DLL fixture requires Windows')
    sdk = args.source.resolve(strict=True)
    if not (sdk/'src/joystick/SDL_amclgamepad_c.h').is_file() or 'SDL_AMCL_ControllerHostProtocolV1' not in (sdk/'src/SDL.c').read_text(encoding='utf8'):
        raise ValueError('Supply the applied controller SDL3 source used by build-sdl3-ohos.ps1 -Controller')
    src = args.compat_archive.resolve(strict=True)
    lock=json.loads((ROOT/'prebuilt/mod-natives/sdl2/sources.json').read_text(encoding='utf8'))
    if hashlib.sha256(src.read_bytes()).hexdigest()!=lock['sdl2-compat.zip'][1]:
        raise ValueError('SDL2-compat upstream archive mismatch')
    spec=importlib.util.spec_from_file_location('sdl2_gamepad_build',ROOT/'scripts/build-sdl2-gamepads.py')
    recipe=importlib.util.module_from_spec(spec);spec.loader.exec_module(recipe)
    out=external_output_path(args.out);out.mkdir(parents=True,exist_ok=True)
    scope=HostTestScope('sdl2-worker-',parent=out);folder=scope.directory;passed=False
    try:
        compat=folder/'compat';recipe.archive_tree(src,compat,'sdl2-compat-release-2.32.74/')
        path=compat/'src/sdl2_compat.c'
        path.write_text(recipe.adapt_controller_threads(compat,path.read_text(encoding='utf8')),encoding='utf8')
        fixture=ROOT/'scripts/fixtures/input-consumer/sdl2_worker_reader.c'
        (folder/'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.20)
project(AmclControllerWorker C CXX)
set(SDL_SHARED ON CACHE BOOL "" FORCE)
set(SDL_STATIC OFF CACHE BOOL "" FORCE)
set(SDL_TESTS OFF CACHE BOOL "" FORCE)
set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
set(SDL_HIDAPI OFF CACHE BOOL "" FORCE)
set(SDL_GPU OFF CACHE BOOL "" FORCE)
set(SDL_AMCL_DESKTOP_HOST ON CACHE BOOL "" FORCE)
set(SDL2COMPAT_TESTS OFF CACHE BOOL "" FORCE)
set(SDL2COMPAT_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory("{sdk.as_posix()}" sdk)
target_sources(SDL3-shared PRIVATE "{fixture.as_posix()}")
target_compile_definitions(SDL3-shared PRIVATE AMCL_SDL_GAMEPAD_HOST_TEST)
target_include_directories(SDL3-shared PRIVATE "{sdk.as_posix()}/src/video/openharmony")
add_subdirectory("{compat.as_posix()}" sdl2)
''',encoding='utf8')
        cmake=find_host_cmake();build=folder/'build';configure_host_cmake(cmake,folder,build)
        subprocess.run([cmake,'--build',str(build),'--config','Release','--target','SDL3-shared','SDL2','--parallel','6'],check=True)
        stage=folder/'dll';stage.mkdir()
        shutil.copyfile(build/'sdk/Release/amcl_sdl_controller.dll',stage/'SDL3.dll')
        shutil.copyfile(build/'sdl2/Release/SDL2.dll',stage/'SDL2.dll')
        env=dict(os.environ,PATH=str(stage)+os.pathsep+os.environ['PATH'],SDL_JOYSTICK_RAWINPUT='0',SDL_JOYSTICK_GAMEINPUT='0')
        subprocess.run([sys.executable,'-B',__file__,'--stage',str(stage)],cwd=stage,env=env,timeout=30,check=True)
        passed=True
    finally:
        scope.close(success=passed)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,help='完整应用 controller patch 序列的 SDL3 源')
    parser.add_argument('--compat-archive',type=Path,help='sources.json 锁定的 SDL2-compat archive')
    parser.add_argument('--out',type=Path,help='任务内外置测试目录')
    parser.add_argument('--stage',type=Path,help=argparse.SUPPRESS)
    args=parser.parse_args()
    if args.stage: exercise(args.stage.resolve(strict=True))
    elif args.source and args.compat_archive and args.out:build_and_test(args)
    else:parser.error('supply --source, --compat-archive and --out')
