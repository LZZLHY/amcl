#!/usr/bin/env python3
"""强制检查 gl4es 架构、依赖、实现导出、别名地址与符号 BuildID，生成唯一来源清单。"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
from datetime import datetime, timezone


def readelf(tool, path, *arguments):
    """工具失败必须传播；不能把空输出解释成验证成功。"""
    return subprocess.check_output([tool,*arguments,str(path)],text=True)


def main():
    """三份 ELF 的身份配对；输出摘要独立于源码输入，避免递归来源身份。"""
    parser=argparse.ArgumentParser()
    parser.add_argument('--directory',required=True,type=Path)
    parser.add_argument('--readelf',default='ohos-readelf')
    parser.add_argument('--compiler',default='/usr/bin/ohos-clang')
    parser.add_argument('--started',required=True)
    args=parser.parse_args(); directory=args.directory
    filenames=['libgl4es.unstripped.so','libgl4es.so','libgl4es.so.debug']
    libraries=[directory/name for name in filenames]
    build_ids=[]; files={}
    for library in libraries:
        header=readelf(args.readelf,library,'-h')
        if 'ELF64' not in header or 'AArch64' not in header: raise ValueError('Wrong architecture: '+str(library))
        note=readelf(args.readelf,library,'-n')
        build_id=re.search(r'Build ID:\s*([0-9a-f]+)',note)
        if not build_id: raise ValueError('Missing BuildID: '+str(library))
        build_ids.append(build_id.group(1))
        files[library.name]={'sha256':hashlib.sha256(library.read_bytes()).hexdigest(),'bytes':library.stat().st_size,'buildId':build_id.group(1)}
    if len(set(build_ids))!=1: raise ValueError('Strip/debug BuildID mismatch')
    dynamic=readelf(args.readelf,libraries[1],'-d')
    needed=re.findall(r'NEEDED.*?\[([^\]]+)\]',dynamic)
    if not needed or any(name not in ['libc.so','libm.so','libdl.so','libEGL.so','libGLESv3.so'] for name in needed):
        raise ValueError('Unexpected dynamic dependency: '+str(needed))
    symbols=readelf(args.readelf,libraries[1],'--dyn-syms','-W')
    exports={}
    for line in symbols.splitlines():
        fields=line.split()
        if len(fields)>=8 and fields[3]=='FUNC' and fields[6]!='UND': exports[fields[7]]=fields[1]
    required=['glDrawArrays','glDrawElements','glDrawRangeElements','glDrawElementsBaseVertex',
              'glMultiDrawArrays','glMultiDrawElements','glMultiDrawElementsBaseVertex',
              # 本轮查询修复必须真实进入OHOS代码/导出；同名字符串或旧SO不能代替实现。
              'glGetIntegerv','glGetFloatv','glGetDoublev','glGetBooleanv','glBindTexture','glDeleteTextures']
    for name in required:
        implementation='gl4es_'+name
        if name not in exports or implementation not in exports or exports[name]!=exports[implementation]:
            raise ValueError('Missing/wrong implementation or alias: '+name)
    if exports.get('glMultiDrawElementsBaseVertexARB')!=exports['glMultiDrawElementsBaseVertex']:
        raise ValueError('ARB alias mismatch')
    if 'amcl_draw_test_fail_after' in exports: raise ValueError('Test injector leaked into production library')
    # 绑定查询共用helper仅允许同一DSO内部链接，不能成为额外宿主/GL ABI。
    if 'amcl_texture_binding_name' in exports: raise ValueError('Private texture binding helper leaked into production ABI')
    source=json.loads((directory/'source-identity.json').read_text())
    result={'schemaVersion':1,'source':source,'files':files,'needed':needed,
            'exports':{name:exports[name] for name in required},
            'compiler':subprocess.check_output([args.compiler,'--version'],text=True),
            'startedAt':args.started,'finishedAt':datetime.now(timezone.utc).isoformat(),
            'target':'aarch64-linux-ohos','buildType':'RelWithDebInfo',
            'validationScope':'source bytes, ELF implementation/aliases, symbol pairing; device validation recorded separately'}
    (directory/'build-provenance.json').write_text(json.dumps(result,indent=2)+'\n')
    print('gl4es artifact verified: '+build_ids[0]+' '+files['libgl4es.so']['sha256'])


if __name__=='__main__': main()
