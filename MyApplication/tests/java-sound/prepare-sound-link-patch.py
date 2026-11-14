#!/usr/bin/env python3
"""在锁定25原Makefile上逐份重放现役series，生成最小OHOS libjsound→libjava依赖补丁。
不重写旧0023/26/27/28，不操作loader；候选逐字节重放成功后才可供完整JDK构建消费。
"""
import argparse,difflib,hashlib,json,re,shutil,subprocess
from datetime import datetime
from pathlib import Path

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def once(text,old,new):
    if text.count(old)!=1:raise ValueError('expected unique make anchor: '+old)
    return text.replace(old,new,1)
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--write-patch',action='store_true');args=parser.parse_args()
    root=Path(__file__).resolve().parents[2];out=args.output.resolve()
    if out==root or root in out.parents:raise ValueError('output must be external')
    out.mkdir(parents=True,exist_ok=False)
    relative='make/modules/java.desktop/Lib.gmk';reference=root/'tests/java-sound-ports/reference'
    record=next(row for row in json.loads((reference/'source.json').read_text())['files']
                if row['major']=='25' and row['path']==relative)
    source=reference/record['file'];assert sha(source)==record['sha256']
    before=out/'before';target=before/relative;target.parent.mkdir(parents=True);shutil.copyfile(source,target)
    patchdir=root/'prebuilt/jdk/25/patches';previous=[]
    for line in (patchdir/'series').read_text().splitlines():
        name=line.strip()
        if not name or name.startswith('#') or int(name[:4])>28:continue
        patch=patchdir/name;previous.append({'file':name,'sha256':sha(patch)})
        if relative not in re.findall(r'^\+\+\+ b/(.+)$',patch.read_text(),re.M):continue
        result=subprocess.run(['git','-c','core.autocrlf=false','apply','--whitespace=nowarn','--include='+relative,str(patch)],cwd=before,capture_output=True)
        (out/(name+'.apply.log')).write_bytes(result.stdout+result.stderr)
        if result.returncode:raise RuntimeError('predecessor failed: '+name)
    old=target.read_text();new=once(old,'  LIBJSOUND_LINUX_LIBS := $(ALSA_LIBS)',
        '  LIBJSOUND_LINUX_LIBS := $(ALSA_LIBS)\n  LIBJSOUND_JDK_LIBS :=')
    new=once(new,'    LIBJSOUND_LINUX_LIBS := -lohaudio',
        '    LIBJSOUND_LINUX_LIBS := -lohaudio\n    # AMCL：JNU_ThrowByName来自libjava；头文件目录不能替代真实动态依赖。\n    LIBJSOUND_JDK_LIBS := java.base:libjava')
    # 后续其它库也可能使用相同头目录，因此只在唯一jsound NAME锚点加入链接参数。
    new=once(new,'      NAME := jsound, \\\n',
        '      NAME := jsound, \\\n      JDK_LIBS := $(LIBJSOUND_JDK_LIBS), \\\n')
    after=out/'after';shutil.copytree(before,after);(after/relative).write_text(new,encoding='utf-8',newline='\n')
    name='0029-ohos-javasound-explicit-java-link.patch';patch=out/name
    patch.write_text(''.join(difflib.unified_diff(old.splitlines(True),new.splitlines(True),'a/'+relative,'b/'+relative)),encoding='utf-8',newline='\n')
    replay=out/'replay';shutil.copytree(before,replay)
    result=subprocess.run(['git','-c','core.autocrlf=false','apply','--whitespace=nowarn',str(patch)],cwd=replay,capture_output=True)
    (out/'candidate-apply.log').write_bytes(result.stdout+result.stderr)
    assert result.returncode==0 and (replay/relative).read_bytes()==(after/relative).read_bytes()
    if args.write_patch:shutil.copyfile(patch,patchdir/name)
    receipt={'at':datetime.now().astimezone().isoformat(),'upstream':record,'predecessors':previous,
        'patch':str(patch),'patchSha256':sha(patch),'beforeSha256':sha(target),'afterSha256':sha(after/relative),
        'scope':'exact locked25 Makefile+current0001..0028 replay only; full JDK build and target load remain required'}
    (out/'receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(receipt,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
