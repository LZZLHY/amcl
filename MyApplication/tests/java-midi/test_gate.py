#!/usr/bin/env python3
"""MIDI独立产物门的原始ELF/事实正负例；所有生成物和收据明确写仓外保留。"""
import argparse
from copy import deepcopy
from datetime import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import struct


def provider_elf(names, mutation=None):
    """生成有可执行映射和真正dynsym/dynstr的AArch64 ELF元数据夹具，不执行其文本。"""
    strings = bytearray(b'\0'); offsets=[]
    for name in names:
        offsets.append(len(strings)); strings += name.encode() + b'\0'
    text_offset=256;string_offset=512
    symbol_offset=(string_offset+len(strings)+7)&~7
    section_offset=(symbol_offset+(len(names)+1)*24+7)&~7
    total=section_offset+4*64
    data=bytearray(total)
    struct.pack_into('<16sHHIQQQIHHHHHH',data,0,b'\x7fELF\x02\x01\x01'+b'\0'*9,3,183,1,0,64,section_offset,0,64,56,1,64,4,0)
    struct.pack_into('<IIQQQQQQ',data,64,1,5,0,4096,4096,total,total,4096)
    data[string_offset:string_offset+len(strings)]=strings
    for i,name in enumerate(names):
        other=2 if mutation=='hidden' and i==0 else 0
        index=0 if mutation=='undefined' and i==0 else 3
        value=0 if mutation=='zero-address' and i==0 else 4096+text_offset+i*4
        info=17 if mutation=='data-symbol' and i==0 else 18
        struct.pack_into('<IBBHQQ',data,symbol_offset+(i+1)*24,offsets[i],info,other,index,value,4)
    struct.pack_into('<IIQQQQIIQQ',data,section_offset+64,0,11,2,4096+symbol_offset,symbol_offset,(len(names)+1)*24,2,1,8,24)
    struct.pack_into('<IIQQQQIIQQ',data,section_offset+128,0,3,2,4096+string_offset,string_offset,len(strings),0,0,1,0)
    struct.pack_into('<IIQQQQIIQQ',data,section_offset+192,0,1,6,4096+text_offset,text_offset,128,0,0,4,0)
    if mutation=='non-executable':struct.pack_into('<I',data,68,4)
    if mutation=='wrong-machine':struct.pack_into('<H',data,18,62)
    if mutation=='bad-dynsym-stride':struct.pack_into('<Q',data,section_offset+64+56,16)
    if mutation=='bad-string-offset':struct.pack_into('<I',data,symbol_offset+24,len(strings)+1)
    if mutation=='truncated':return bytes(data[:-1])
    return bytes(data)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--sdk-library-dir',type=Path)
    args=parser.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=False)
    root=Path(__file__).resolve().parents[2]
    spec=importlib.util.spec_from_file_location('midi_gate',root/'docker/scripts/midi_runtime_gate.py')
    gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)
    header=(root/'entry/src/main/cpp/javasound/midi_api.h').read_text()
    names=set(re.findall(r'X\(\w+, (OH_MIDI\w+)\)',header))
    assert names==set(gate.REQUIRED_MIDI_SYMBOLS) and len(names)==14
    facts={'needed':['libc.so'],'imports':['dlopen','dlsym','pthread_mutex_lock'],
           'strongImports':['dlopen','dlsym','pthread_mutex_lock'],'weakImports':[],
           'resolvableExports':list(gate.REQUIRED_MIDI_JNI_EXPORTS),
           'resolvableFunctionExports':list(gate.REQUIRED_MIDI_FUNCTION_EXPORTS),
           'ohosMidiDynamicSymbols':sorted(names),
           'ohosMidiMarkers':[{'type':1,'flags':2,'bytes':len(gate.MIDI_MARKER),
                              'valueHex':gate.MIDI_MARKER.hex(),'mappedReadonly':True}]}
    records=[]
    def check(label,current,data,accept=False,required=True):
        directory=out/label;directory.mkdir();(directory/'libohmidi.so').write_bytes(data)
        try:
            result=gate.validate_midi_backend(current,directory,required)
            if not accept:raise AssertionError('false acceptance: '+label)
            assert result['minimumApi']==20 and result['providerMinimumApi']==24
            assert result['providerSha256']==hashlib.sha256(data).hexdigest()
            records.append({'case':label,'result':'PASS','accepted':True,'metadata':result})
        except ValueError as error:
            if accept:raise
            records.append({'case':label,'result':'PASS','accepted':False,'reason':str(error)})
    valid=provider_elf(sorted(names))
    try:
        check('complete',facts,valid,True)
        legacy={'needed':['libc.so'],'imports':[],'resolvableExports':[]}
        assert gate.validate_midi_backend(legacy,None,False) is None
        records.append({'case':'legacy-unavailable','result':'PASS','acceptedLegacy':True})
        check('required-missing',legacy,valid)
        for field,value in [('type',8),('flags',3),('bytes',1),('valueHex',b'wrong\0'.hex()),('mappedReadonly',False)]:
            row=deepcopy(facts);row['ohosMidiMarkers'][0][field]=value;check('marker-'+field,row,valid)
        row=deepcopy(facts);row['ohosMidiMarkers']*=2;check('duplicate-marker',row,valid)
        row=deepcopy(facts);row['needed'].append('libohmidi.so');check('hard-dependency',row,valid)
        for strength in ('strong','weak'):
            row=deepcopy(facts);row['imports'].append('OH_MIDIClient_Create');row[strength+'Imports'].append('OH_MIDIClient_Create');check(strength+'-import',row,valid)
        for name in sorted(names):
            row=deepcopy(facts);row['ohosMidiDynamicSymbols'].remove(name);check('missing-dynamic-'+name,row,valid)
        for name in gate.REQUIRED_MIDI_JNI_EXPORTS:
            row=deepcopy(facts);row['resolvableExports'].remove(name);check('missing-export-'+name,row,valid)
        for name in gate.REQUIRED_MIDI_FUNCTION_EXPORTS:
            row=deepcopy(facts);row['resolvableFunctionExports'].remove(name);check('non-function-'+name,row,valid)
        for mutation in ('hidden','undefined','zero-address','data-symbol','non-executable','wrong-machine','bad-dynsym-stride','bad-string-offset','truncated'):
            check('provider-'+mutation,facts,provider_elf(sorted(names),mutation))
        check('provider-missing-symbol',facts,provider_elf(sorted(names)[1:]))
        if args.sdk_library_dir:
            data=(args.sdk_library_dir/'libohmidi.so').read_bytes()
            check('actual-sdk-provider',facts,data,True)
        result='PASS'
    finally:
        receipt={'time':datetime.now().astimezone().isoformat(),'result':locals().get('result','FAIL'),
            'moduleSha256':hashlib.sha256((root/'docker/scripts/midi_runtime_gate.py').read_bytes()).hexdigest(),
            'records':records,'scope':'gate facts/ELF fault fixtures and optional actual SDK provider; no runtime device transport'}
        (out/'receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('PASS MIDI producer gate:',len(records),'positive/negative cases')


if __name__=='__main__':main()
