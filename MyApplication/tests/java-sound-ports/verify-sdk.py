#!/usr/bin/env python3
"""用真实OHOS SDK编译/链接生产Ports，再读回实际依赖、JNI导出和只读能力节。
8的原/候选version-script分别实际链接，原表必须隐藏新入口，候选必须完整导出。
这里只授静态SDK/源码边界资格，不执行AArch64产物、不模拟硬件或提高最低API。
"""
import argparse,hashlib,importlib.util,json,shutil,struct,subprocess,sys
from datetime import datetime
from pathlib import Path

MARKER=b'AMCL_PORTS_OHOS_API20_DEVICES_V1\0'
REQUIRED={'OH_AudioManager_GetAudioRoutingManager','OH_AudioRoutingManager_GetDevices',
          'OH_AudioRoutingManager_ReleaseDevices','OH_AudioDeviceDescriptor_GetDeviceRole',
          'OH_AudioDeviceDescriptor_GetDeviceType','OH_AudioDeviceDescriptor_GetDeviceId',
          'OH_AudioDeviceDescriptor_GetDeviceName','OH_AudioDeviceDescriptor_GetDeviceAddress'}
NEW_JNI={'Java_com_sun_media_sound_PortMixerProvider_nGetGeneration',
         'Java_com_sun_media_sound_PortMixerProvider_nNewPortMixerInfoSnapshot',
         'Java_com_sun_media_sound_PortMixer_nOpenSnapshot'}
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def marker(data):
    """对本轮成功编译ELF的节/映射再核，只接受唯一精确只读PROGBITS标记。"""
    def read(at,size):
        if at<0 or size<0 or at+size>len(data):raise ValueError('ELF out of range')
        return data[at:at+size]
    shoff=struct.unpack_from('<Q',data,40)[0];stride,count,names=struct.unpack_from('<HHH',data,58)
    if stride!=64 or not count or names>=count:raise ValueError('invalid ELF section table')
    sections=[struct.unpack('<IIQQQQIIQQ',read(shoff+i*stride,stride)) for i in range(count)]
    table=read(sections[names][4],sections[names][5]);found=[]
    for section in sections:
        if section[0]>=len(table):raise ValueError('bad ELF name offset')
        end=table.find(b'\0',section[0])
        if end<0:raise ValueError('unterminated ELF name')
        if table[section[0]:end]==b'.amcl.ports':found.append(section)
    if len(found)!=1:raise ValueError('expected one ports section')
    section=found[0];assert section[1]==1 and section[2]==2 and read(section[4],section[5])==MARKER
    phoff=struct.unpack_from('<Q',data,32)[0];stride,count=struct.unpack_from('<HH',data,54)
    assert stride==56
    readonly=False
    for i in range(count):
        ph=struct.unpack('<IIQQQQQQ',read(phoff+i*stride,stride))
        if (ph[0]==1 and ph[1]&4 and not ph[1]&2 and ph[2]<=section[4] and
            section[4]+section[5]<=ph[2]+ph[5]<=len(data) and
            section[3]>=ph[3] and section[3]-ph[3]==section[4]-ph[2]):readonly=True
    assert readonly
    return {'section':'.amcl.ports','type':1,'flags':2,'bytes':len(MARKER),'valueHex':MARKER.hex(),'mappedReadonly':True}

def main():
    sys.dont_write_bytecode=True
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk',type=Path,required=True)
    parser.add_argument('--jni-headers',type=Path,required=True)
    parser.add_argument('--patches',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();root=Path(__file__).resolve().parents[2];out=args.output.resolve()
    if root==out or root in out.parents:raise ValueError('output must be external')
    out.mkdir(parents=True,exist_ok=False);inputs=out/'inputs';inputs.mkdir()
    sdk=args.sdk.resolve();suffix='.exe' if sys.platform=='win32' else ''
    clang=sdk/'llvm/bin'/('clang'+suffix);readelf=sdk/'llvm/bin'/('llvm-readelf'+suffix)
    sysroot=sdk/'sysroot';provider=sysroot/'usr/lib/aarch64-linux-ohos/libohaudio.so'
    for name in ('ports_ohos.c','ports_ohos.h','ports_jni.c'):
        shutil.copyfile(root/'entry/src/main/cpp/javasound'/name,inputs/name)
    # 只读复用现有有边界ELF符号读取器，并冻结本轮实际helper字节；不修改发布packager。
    # packager的顶层导入也属于执行闭包；全部从同一快照加载，不能借共享工作树中的活文件。
    for name in ('package_runtime.py','midi_runtime_gate.py','verify_jdk_ports.py'):
        shutil.copyfile(root/'docker/scripts'/name,inputs/name)
    sys.path.insert(0,str(inputs));helper=inputs/'package_runtime.py'
    spec=importlib.util.spec_from_file_location('ports_elf_helper',helper);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    def run(argv,name):
        argv=[str(x) for x in argv];result=subprocess.run(argv,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
        (out/(name+'.log')).write_bytes(result.stdout)
        if result.returncode:raise RuntimeError(name+' exit '+str(result.returncode))
        return argv
    common=[clang,'--target=aarch64-linux-ohos','--sysroot='+str(sysroot),'-D__OHOS__',
            '-std=c11','-Wall','-Wextra','-Werror','-fPIC','-shared','-O1','-I'+str(args.jni_headers.resolve()),
            inputs/'ports_ohos.c',inputs/'ports_jni.c','-pthread','-Wl,--no-undefined','-Wl,-soname,libports-qualification.so','-lohaudio']
    runs=[]
    for kind,part in [('modern',None),('classic-before','before'),('classic-after','after')]:
        target=out/(kind+'.so');argv=list(common)
        if part:
            source=args.patches/'8'/part/'jdk/make/mapfiles/libjsound/mapfile-vers'
            frozen=inputs/(kind+'.map');shutil.copyfile(source,frozen)
            # 本专项目只链接Ports两TU；允许map表列出不在本专项内的PCM/MIDI符号。
            # 新Ports三符号是否真正导出仍逐个读回，不能因--undefined-version误判成功。
            argv+=['-Wl,--undefined-version','-Wl,--version-script='+str(frozen)]
        command=run([*argv,'-o',target],kind+'-compile')
        data=target.read_bytes();facts=module.elf_facts(data)
        imports={s for s in facts['strongImports'] if s.startswith('OH_Audio')}
        assert imports==REQUIRED
        assert set(facts['needed'])=={'libohaudio.so','libc.so'}
        supplied=set(module.elf_facts(provider.read_bytes())['resolvableExports']);assert REQUIRED<=supplied
        actual=set(facts['resolvableExports'])
        missing=NEW_JNI-actual
        if kind=='classic-before':assert missing==NEW_JNI
        else:assert not missing
        assert 'Java_com_sun_media_sound_PortMixer_nClose' in actual
        run([readelf,'--wide','--sections','--program-headers','--dynamic','--dyn-syms',target],kind+'-readelf')
        runs.append({'kind':kind,'file':str(target),'sha256':sha(target),'command':command,
                     'needed':facts['needed'],'requiredSdkImports':sorted(imports),'newJniMissing':sorted(missing),
                     'marker':marker(data),'sdkProviderSha256':sha(provider)})
    headers=['native_audio_routing_manager.h','native_audio_device_base.h','native_audio_common.h','native_audio_volume_manager.h']
    receipt={'schemaVersion':1,'at':datetime.now().astimezone().isoformat(),'scope':'actual SDK AArch64 link/static identity only; no device qualification',
             'sdk':str(sdk),'compilerSha256':sha(clang),'readelfSha256':sha(readelf),'sdkProvider':str(provider),
             'jniHeaders':{p.name:sha(p) for p in args.jni_headers.iterdir() if p.is_file()},
             'sdkHeaders':{name:sha(sysroot/'usr/include/ohaudio'/name) for name in headers},
             'inputs':{p.name:sha(p) for p in inputs.iterdir() if p.is_file()},'runs':runs,'result':'PASS'}
    (out/'receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('PASS real OHOS SDK / readonly marker / 8 exact imports / classic version-script positive and negative')

if __name__=='__main__':main()
