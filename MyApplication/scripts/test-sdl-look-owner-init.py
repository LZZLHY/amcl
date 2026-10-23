"""实际完整共享 SDL SDK 的 Init 与实际 neutral DLL/so：拒绝旧控制单能力和坏 look 表。

本探针不创建 consumer、不模拟 Ready，不用微型 SDL 函数替身。SDK 的标准 Init、
状态与错误 getter 全部来自指定真实 SDK；neutral Core/control/look 也须为真实生产共享库。
"""
from pathlib import Path
from datetime import datetime
import argparse
import ctypes
import hashlib
import json
import os
import sys
import threading
sys.dont_write_bytecode=True
from lib.workspace_paths import external_output_path
def check(value,label):
    """所有负例须落到 SDK 自身拒绝，而非以库载入失败冒充 failclosed。"""
    if not value:raise AssertionError('CHECK failed: '+label)
def verify(sdk_path,owner_path,out):
    """同一进程从有效 control/缺 look 推进到完整 owner，确认失败不半初始化 SDK。"""
    out=external_output_path(out)
    if out.exists():raise ValueError('Refuse existing receipt: '+str(out))
    started=datetime.now().astimezone().isoformat();sdk_path=sdk_path.resolve();owner_path=owner_path.resolve()
    saved={name:os.environ.get(name) for name in ['AMCL_SDL_HOST_RUNTIME','AMCL_CONTROL_DELIVERY_V1','AMCL_LOOK_EXECUTION_V1']}
    try:
        for name in saved:os.environ.pop(name,None)
        sdk=ctypes.CDLL(str(sdk_path));owner=ctypes.CDLL(str(owner_path))
        tid=threading.get_native_id()
        if os.name=='nt':
            get_tid=ctypes.WinDLL('kernel32').GetCurrentThreadId;get_tid.restype=ctypes.c_uint32;tid=get_tid()
        os.environ['AMCL_SDL_HOST_RUNTIME']='1:'+str(os.getpid())+':'+str(tid)+':1'
        control=owner.amclControlDeliveryPublishV1;control.argtypes=[];control.restype=None;control()
        was=sdk.SDL_WasInit;was.argtypes=[ctypes.c_uint32];was.restype=ctypes.c_uint32
        init=sdk.SDL_InitSubSystem;init.argtypes=[ctypes.c_uint32];init.restype=ctypes.c_bool
        error=sdk.SDL_GetError;error.restype=ctypes.c_char_p
        check(was(0)==0,'before actual SDK Init')
        missing=init(0x4000);missing_error=error()
        check(not missing and was(0)==0 and b'sdl_runtime_look_owner' in missing_error,'valid control but missing look rejects actual SDK Init')
        os.environ['AMCL_LOOK_EXECUTION_V1']='AMCLLOOK:1:bad';malformed=init(0x4000)
        check(not malformed and was(0)==0,'malformed look owner rejects actual SDK Init')
        publish=owner.amclLookExecutionPublishV1;publish.argtypes=[];publish.restype=None;publish()
        # 进入 actual Init 阶段后走 SDL 标准宿主入口；上面的 cold/拒绝检查未调用它。
        ready=sdk.SDL_SetMainReady;ready.argtypes=[];ready.restype=None;ready()
        valid=init(0x4000);check(valid and was(0)&0x4000,'same actual neutral owner admits actual SDK Init')
        receipt={'startedAt':started,'finishedAt':datetime.now().astimezone().isoformat(),'layer':'actual-shared-SDL-Init-and-neutral-owner',
            'sdk':str(sdk_path),'sdkSha256':hashlib.sha256(sdk_path.read_bytes()).hexdigest(),'owner':str(owner_path),
            'ownerSha256':hashlib.sha256(owner_path.read_bytes()).hexdigest(),'initValidControlMissingLook':missing,
            'missingLookError':missing_error.decode(),'initBadLook':malformed,'initCompleteOwner':valid,'finalWasInit':was(0)}
        out.write_text(json.dumps(receipt,indent=2),encoding='utf-8');print(json.dumps(receipt))
        print('PASS actual full shared SDL Init rejects old/malformed look owner and admits real same neutral owner')
    finally:
        for name,value in saved.items():
            if value is None:os.environ.pop(name,None)
            else:os.environ[name]=value
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--sdk-library',type=Path,required=True)
    parser.add_argument('--owner-library',type=Path,required=True);parser.add_argument('--receipt',type=Path,required=True)
    args=parser.parse_args();verify(args.sdk_library,args.owner_library,args.receipt)
