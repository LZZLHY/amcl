#!/usr/bin/env python3
"""让GNU make实际展开锁定jsound构建块，核原/候选与OHOS/普通Linux四种分支。
只以空编译宏截获SetupJdkLibrary参数，不伪造运行库或替代实际SDK链接/完整JDK构建。
"""
import argparse,hashlib,json,subprocess
from datetime import datetime
from pathlib import Path

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--sources',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True);args=parser.parse_args();out=args.output;out.mkdir(exist_ok=False)
    rows=[]
    for variant in ('before','after'):
        original=args.sources/variant/'make/modules/java.desktop/Lib.gmk';text=original.read_text()
        start=text.index('  LIBJSOUND_CFLAGS :=');end=text.index('\n  TARGETS += $(BUILD_LIBJSOUND)',start)
        block=text[start:end]
        for ohos in (False,True):
            case=out/(variant+('-ohos' if ohos else '-linux'));case.mkdir()
            # 截取完整jsound块保留实际条件；宏记录传入参数，不能仅检查新变量字面量出现。
            # GNU make十位参数必须写$(10)，$10实际是$1后跟字符0；同时去掉call参数的前导空格。
            capture=' '.join('$(strip $('+str(n)+'))' for n in range(2,25))
            content='''OPENJDK_TARGET_OS := linux
OPENJDK_TARGET_OS_UPPERCASE := LINUX
isTargetOs = $(if $(filter $(OPENJDK_TARGET_OS),$1),true,false)
CFLAGS_JDKLIB := '''+('-D__OHOS__' if ohos else '')+'''
SetupJdkLibrary = $(info ACTUAL_SETUP $(strip $(1)) '''+capture+''')
'''+block+'\n.PHONY: all\nall:\n\t@:\n'
            makefile=case/'Makefile';makefile.write_text(content,encoding='utf-8')
            result=subprocess.run(['make','-rR','-f',str(makefile),'all'],capture_output=True,text=True)
            (case/'make.log').write_text(result.stdout+result.stderr,encoding='utf-8');assert result.returncode==0
            lines=[line for line in result.stdout.splitlines() if line.startswith('ACTUAL_SETUP BUILD_LIBJSOUND')];assert len(lines)==1
            has_java='JDK_LIBS := java.base:libjava' in lines[0]
            assert has_java==(variant=='after' and ohos),lines[0]
            if not ohos:assert 'LIBS_linux := -lohaudio' not in lines[0]
            rows.append({'variant':variant,'ohos':ohos,'explicitJavaLink':has_java,
                'sourceSha256':hashlib.sha256(original.read_bytes()).hexdigest(),'actualMakeArguments':lines[0]})
    (out/'receipt.json').write_text(json.dumps({'at':datetime.now().astimezone().isoformat(),'result':'PASS','cases':rows},indent=2)+'\n')
    print('PASS actual GNU make jsound arguments: before/after x OHOS/ordinary Linux')
if __name__=='__main__':main()
