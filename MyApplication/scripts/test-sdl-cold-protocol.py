"""只读加载完整宿主SDK的实际共享制品，校准标准导出、cold协议与真实Init拒坏owner。

无来源、无consumer、无假Ready。输入消费的正例仍由完整静态SDK+生产neutral闭包证明；
本入口只证明此共享映像的协议是实际导出，而且cold getter不会初始化SDK。
"""
from pathlib import Path
import argparse
import ctypes
import hashlib
import json
import os
import shutil
import threading

def host_descriptor():
    """按真实宿主合同编码实际pid/tid/session，不把一个非空字符串当host身份。"""
    if os.name=='nt':
        get_tid=ctypes.WinDLL('kernel32').GetCurrentThreadId;get_tid.restype=ctypes.c_uint32;tid=get_tid()
    else:tid=threading.get_native_id()
    return '1:'+str(os.getpid())+':'+str(tid)+':1'

def check(value,label):
    """失败保留实际判据，不使用“加载成功”代替协议或状态验证。"""
    if not value:raise AssertionError('CHECK failed: '+label)

def verify(path):
    path=path.resolve();original={name:os.environ.get(name) for name in ['AMCL_SDL_HOST_RUNTIME','AMCL_CONTROL_DELIVERY_V1']}
    try:
        for name in original:os.environ.pop(name,None)
        sdk=ctypes.CDLL(str(path))
        version=sdk.SDL_GetVersion;version.argtypes=[];version.restype=ctypes.c_int
        marker=sdk.SDL_AMCL_InputControlProtocolV1;marker.argtypes=[];marker.restype=ctypes.c_uint32
        look=sdk.SDL_AMCL_InputLookProtocolV1;look.argtypes=[];look.restype=ctypes.c_uint32
        was_init=sdk.SDL_WasInit;was_init.argtypes=[ctypes.c_uint32];was_init.restype=ctypes.c_uint32
        init=sdk.SDL_InitSubSystem;init.argtypes=[ctypes.c_uint32];init.restype=ctypes.c_bool
        standard=version();check(standard>=3000000,'standard SDL_GetVersion calibration')
        # Windows核实际标准与私有导出的module；POSIX由相同CDLL handle取符号并经dladdr校准。
        addresses=[ctypes.cast(function,ctypes.c_void_p).value for function in [version,marker,look]]
        if os.name=='nt':
            get_module=ctypes.WinDLL('kernel32',use_last_error=True).GetModuleHandleExA
            get_module.argtypes=[ctypes.c_uint32,ctypes.c_void_p,ctypes.POINTER(ctypes.c_void_p)];get_module.restype=ctypes.c_int
            modules=[]
            for address in addresses:
                module=ctypes.c_void_p();check(get_module(6,address,ctypes.byref(module))!=0,'symbol module query');modules.append(module.value)
            check(modules[0]==modules[1]==modules[2]==sdk._handle,'actual standard/control/look same selected SDK module')
        else:
            class DlInfo(ctypes.Structure):
                _fields_=[('name',ctypes.c_char_p),('base',ctypes.c_void_p),('symbol',ctypes.c_char_p),('address',ctypes.c_void_p)]
            dladdr=ctypes.CDLL(None).dladdr;dladdr.argtypes=[ctypes.c_void_p,ctypes.POINTER(DlInfo)];dladdr.restype=ctypes.c_int
            images=[]
            for address in addresses:
                info=DlInfo();check(dladdr(address,ctypes.byref(info))!=0,'symbol image query');images.append(info.base)
            check(images[0] and images[0]==images[1]==images[2],'actual standard/control/look same selected SDK image')
        before=was_init(0);protocol=marker();lookProtocol=look();after=was_init(0)
        check(protocol==1 and lookProtocol==1 and before==after==0,'independent cold protocols without SDL init')
        os.environ['AMCL_SDL_HOST_RUNTIME']=host_descriptor()
        missing=init(0x4000);check(not missing and was_init(0)==0,'actual SDK Init rejects absent common Core owner')
        os.environ['AMCL_CONTROL_DELIVERY_V1']='AMCLCONTROL:1:bad'
        malformed=init(0x4000);check(not malformed and was_init(0)==0,'actual SDK Init rejects malformed common Core owner')
        check(marker()==1 and was_init(0)==0,'cold getter still no-init after failed actual Init')
        print(json.dumps({'layer':'host-sdk-cold-contract','library':str(path),'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
            'standardVersion':standard,'protocol':protocol,'beforeWasInit':before,'afterWasInit':after,
            'initMissingOwner':missing,'initBadOwner':malformed,'finalWasInit':was_init(0)},ensure_ascii=False))
        print('PASS actual SDK shared marker/standard image, no cold init, and actual Init missing/bad owner rejection')
    finally:
        for name,value in original.items():
            if value is None:os.environ.pop(name,None)
            else:os.environ[name]=value

def dynapi_test(path,mode,owner_library,label):
    """真实两个完整SDK映像证明override有实际作用、host内部表冻结与late外表拒绝。"""
    path=path.resolve();copy=path.parent/('SDK-copy-'+mode+'-'+label+path.suffix)
    if copy.exists():raise ValueError('Refuse replacing SDK copy proof')
    shutil.copyfile(path,copy)
    os.environ.pop('AMCL_SDL_HOST_RUNTIME',None);os.environ.pop('AMCL_CONTROL_DELIVERY_V1',None)
    os.environ['SDL3_DYNAMIC_API']=str(copy)
    if mode=='host':os.environ['AMCL_SDL_HOST_RUNTIME']=host_descriptor()
    sdk=ctypes.CDLL(str(path));other=ctypes.CDLL(str(copy))
    def configure(library,name,args,result):
        function=getattr(library,name);function.argtypes=args;function.restype=result;return function
    version=configure(sdk,'SDL_GetVersion',[],ctypes.c_int)
    init=configure(sdk,'SDL_InitSubSystem',[ctypes.c_uint32],ctypes.c_bool)
    other_was=configure(other,'SDL_WasInit',[ctypes.c_uint32],ctypes.c_uint32)
    error=configure(sdk,'SDL_GetError',[],ctypes.c_char_p)
    check(sdk._handle!=other._handle,'actual two separately mapped SDK modules')
    check(version()>=3000000 and other_was(0)==0,'both real SDK standard calibration')
    first=init(0x4000);other_state=other_was(0)
    if mode=='host':
        check(not first and other_state==0 and b'sdl_runtime_core_owner' in (error() or b''),'host internal table remains actual SDK despite real override')
    else:
        check(first and other_state&0x4000,'standalone actual override initializes the other SDK')
        if mode=='late':
            check(owner_library,'late host test requires actual neutral owner shared library')
            owner=ctypes.CDLL(str(owner_library.resolve()))
            publish=owner.amclControlDeliveryPublishV1;publish.argtypes=[];publish.restype=None;publish()
            # 当前SDK分别核control/look冷身份。late场必须发布同一个真实owner的完整前提，
            # 否则缺look会先拒绝Init，让撤去late source guard的错误SDK也假装通过。
            publish_look=owner.amclLookExecutionPublishV1;publish_look.argtypes=[];publish_look.restype=None;publish_look()
            os.environ.pop('SDL3_DYNAMIC_API',None);os.environ['AMCL_SDL_HOST_RUNTIME']=host_descriptor()
            check(not init(0x4000) and other_was(0)==other_state,'late host cannot initialize through borrowed external SDK table')
    print(json.dumps({'layer':'host-sdk-dynapi-source','mode':mode,'sdk':str(path),'copy':str(copy),
        'sdkSha256':hashlib.sha256(path.read_bytes()).hexdigest(),'copySha256':hashlib.sha256(copy.read_bytes()).hexdigest(),
        'firstInit':first,'otherWasInit':other_state,'actualDistinctModules':True},ensure_ascii=False))
    print('PASS actual two-SDK dynapi '+mode)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--library',type=Path,required=True)
    parser.add_argument('--dynapi',choices=['standalone','host','late'])
    parser.add_argument('--owner-library',type=Path)
    parser.add_argument('--copy-label',default='production')
    options=parser.parse_args()
    if options.dynapi:dynapi_test(options.library,options.dynapi,options.owner_library,options.copy_label)
    else:verify(options.library)
