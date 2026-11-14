#!/usr/bin/env python3
"""独立Ports产物门回归：实际SDK产物正例、原mapfile负控、逐项损坏及旧运行包兼容。
从原始ELF读取事实后才进入门；所有损坏只写本次外置目录，不改SDK或既有ZIP。
"""
import argparse,copy,hashlib,importlib.util,json,shutil,sys,zipfile
from datetime import datetime
from pathlib import Path

def sha(path):
    digest=hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda:stream.read(1024*1024),b''):digest.update(data)
    return digest.hexdigest()

def main():
    sys.dont_write_bytecode=True
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk-libs',type=Path,required=True)
    parser.add_argument('--sdk-audit',type=Path,required=True)
    parser.add_argument('--legacy-ledger',type=Path,action='append',default=[])
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();root=Path(__file__).resolve().parents[2];out=args.output.resolve()
    if root==out or root in out.parents:raise ValueError('output must be external')
    out.mkdir(parents=True,exist_ok=False);inputs=out/'inputs';inputs.mkdir()
    for name in ('package_runtime.py','midi_runtime_gate.py','verify_jdk_ports.py'):
        shutil.copyfile(root/'docker/scripts'/name,inputs/name)
    shutil.copyfile(Path(__file__).with_name('verify-sdk.py'),inputs/'verify-sdk.py')
    sys.path.insert(0,str(inputs));from package_runtime import elf_facts
    from verify_jdk_ports import validate_ports_backend,PORTS_REQUIRED_SYMBOLS,PORTS_REQUIRED_JNI
    spec=importlib.util.spec_from_file_location('ports_sdk_reader',inputs/'verify-sdk.py')
    reader=importlib.util.module_from_spec(spec);spec.loader.exec_module(reader)
    def read(path):
        data=path.read_bytes();facts=elf_facts(data)
        # root尚未接共享parser时，借本模块独立严格ELF节/映射读取器读实际marker，绝非声称字符串。
        actual=reader.marker(data)
        expected={key:value for key,value in actual.items() if key!='section'}
        if 'ohosPortsMarkers' in facts:assert facts['ohosPortsMarkers']==[expected]
        else:facts['ohosPortsMarkers']=[expected]
        return facts
    rows=[]
    def accepted(name,facts,system=args.sdk_libs,required=True):
        value=validate_ports_backend(facts,system,required)
        assert value['requiredSymbols']==sorted(PORTS_REQUIRED_SYMBOLS)
        assert value['controlsExposed'] is False and value['systemControlWrites']=='not-public-api'
        assert value['providerSha256']==sha(args.sdk_libs/'libohaudio.so')
        rows.append({'name':name,'passed':True,'result':value})
    def rejected(name,facts,system=args.sdk_libs,required=True):
        try:validate_ports_backend(facts,system,required)
        except (ValueError,OSError) as error:rows.append({'name':name,'passed':True,'rejected':str(error)});return
        raise AssertionError('invalid artifact accepted: '+name)
    facts=read(args.sdk_audit/'modern.so')
    accepted('real-modern-sdk-link',facts)
    accepted('real-classic-mapfile-link',read(args.sdk_audit/'classic-after.so'))
    rejected('actual-prior-classic-mapfile-hides-new-jni',read(args.sdk_audit/'classic-before.so'))
    for symbol in sorted(PORTS_REQUIRED_SYMBOLS):
        altered=copy.deepcopy(facts);altered['strongImports'].remove(symbol)
        altered['weakImports'].append(symbol)
        rejected('required-api-is-only-weak:'+symbol,altered)
    for symbol in sorted(PORTS_REQUIRED_JNI):
        altered=copy.deepcopy(facts);altered['resolvableExports'].remove(symbol)
        rejected('jni-not-resolvable:'+symbol,altered)
    for key,value in [('type',8),('flags',3),('bytes',32),('valueHex','00'),('mappedReadonly',False),('flags',True)]:
        altered=copy.deepcopy(facts);altered['ohosPortsMarkers'][0][key]=value
        rejected('invalid-marker-'+key+'-'+str(value),altered)
    altered=copy.deepcopy(facts);altered['ohosPortsMarkers']*=2;rejected('duplicate-marker',altered)
    altered=copy.deepcopy(facts);del altered['ohosPortsMarkers'];rejected('missing-marker',altered,required=False)
    altered=copy.deepcopy(facts);altered['needed'].remove('libohaudio.so');rejected('missing-dt-needed',altered)
    altered=copy.deepcopy(facts);altered['imports'].append('OH_AudioInventedUnknownEntry');rejected('unknown-audio-api',altered)
    rejected('missing-sdk-selection',facts,system=None)
    missing=out/'missing-sdk';missing.mkdir();rejected('missing-sdk-file',facts,system=missing)
    bad=out/'invalid-sdk';bad.mkdir();(bad/'libohaudio.so').write_bytes(b'not ELF');rejected('not-target-sdk-elf',facts,system=bad)
    provider=(args.sdk_libs/'libohaudio.so').read_bytes()
    name=b'OH_AudioDeviceDescriptor_GetDeviceAddress\0';assert provider.count(name)==1
    partial=out/'partial-sdk';partial.mkdir()
    (partial/'libohaudio.so').write_bytes(provider.replace(name,b'ZH_AudioDeviceDescriptor_GetDeviceAddress\0'))
    rejected('actual-sdk-export-removed',facts,system=partial)
    old={'needed':['libohaudio.so'],'imports':['OH_AudioManager_GetAudioRoutingManager','OH_AudioRoutingManager_ReleaseDevices'],
         'strongImports':['OH_AudioManager_GetAudioRoutingManager','OH_AudioRoutingManager_ReleaseDevices'],
         'exports':[],'resolvableExports':[]}
    assert validate_ports_backend(old,None,False) is None
    rows.append({'name':'pcm-shared-routing-does-not-invent-ports','passed':True})
    rejected('declared-0027-missing-from-pcm',old,system=None)
    legacy=[]
    for ledger_path in args.legacy_ledger:
        ledger=json.loads(ledger_path.read_text())
        for major,runtime in ledger['runtimes'].items():
            path=Path(runtime['runtime']['file']);assert sha(path)==runtime['runtime']['sha256']
            with zipfile.ZipFile(path) as archive:
                names=[name for name in archive.namelist() if name.endswith('/libjsound.so')]
                assert len(names)==1;data=archive.read(names[0])
            assert validate_ports_backend(elf_facts(data),args.sdk_libs,False) is None
            legacy.append({'buildId':runtime['buildId'],'archiveSha256':runtime['runtime']['sha256'],
                           'libjsoundSha256':hashlib.sha256(data).hexdigest(),'portsBackend':None})
    receipt={'schemaVersion':1,'at':datetime.now().astimezone().isoformat(),'result':'PASS',
        'scope':'producer static artifact gate only; no target hardware qualification',
        'inputs':{p.name:sha(p) for p in inputs.iterdir() if p.is_file()},
        'sdkLinkReceiptSha256':sha(args.sdk_audit/'receipt.json'),'cases':rows,'legacyRuntimes':legacy}
    (out/'receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('PASS Ports producer gate: '+str(len(rows))+' cases and '+str(len(legacy))+' immutable legacy runtimes')

if __name__=='__main__':main()
