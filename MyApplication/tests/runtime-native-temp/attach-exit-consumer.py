"""消费明确JDK源码树的真实Attach终结正文；Linux宿主测试，不授完整JDK/设备资格。

准备模式只生成并记录输入；执行模式使用已有g++/ASan/UBSan。输出、源码和短socket fixture父根
均显式可配置，不修改全局临时目录，不清理未知文件。仅在成功后回收本测试创建的精确叶子。
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile


def extract(text,signature):
    """锁定函数/类正文提取；保留原语句、预处理和RAII，不复制生产生命周期算法。"""
    start=text.index(signature);brace=text.index('{',start);level=1;end=brace+1
    while level:
        if text[end]=='{':level+=1
        elif text[end]=='}':level-=1
        end+=1
    return text[start:end]


def prepare(source_root,major,output):
    platform=('hotspot/src/os/linux/vm/attachListener_linux.cpp' if major=='8' else
              'src/hotspot/os/posix/attachListener_posix.cpp' if major=='25' else 'src/hotspot/os/linux/attachListener_linux.cpp')
    path=source_root/platform;raw=path.read_bytes();source=raw.decode('utf-8').replace('\r\n','\n')
    owner='PosixAttachListener' if major=='25' else 'LinuxAttachListener'
    declarations='class '+('PosixAttachOperation' if major=='25' else 'LinuxAttachOperation')+';\n'+extract(source,'class '+owner+':')+';\n'
    for line in source.splitlines():
        if re.match(r'(char|bool|volatile int) '+owner+r'::_',line):declarations+=line+'\n'
    start=source.index('#ifdef __OHOS__\n#include <pthread.h>');init=extract(source,'int '+owner+'::init()')
    end=source.index(init)+len(init);body=source[start:end]
    if body.count('  set_path(path);')!=1:raise ValueError('init final publication anchor changed')
    body=body.replace('  set_path(path);','  test_before_publish();\n  set_path(path);')
    body+='\n'+extract(source,'void AttachListener::abort()')+'\n#ifdef __OHOS__\n'+extract(source,'void AttachListener::vm_shutdown()')+'\n#endif\n'+extract(source,'bool AttachListener::check_socket_file()')
    preamble='''#include <cerrno>
#include <cstdio>
#include <cstdarg>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#define UNIX_PATH_MAX 108
'''
    fixture=Path(__file__).with_name('attach_exit_consumer.cpp.inc')
    text=fixture.read_text(encoding='utf-8').replace('// GENERATED_OWNER_AND_PRODUCTION_FUNCTIONS',declarations+body).replace('OWNER',owner)
    generated=output/'consumer.cpp';generated.write_text(preamble+text,encoding='utf-8',newline='\n')
    return {'major':major,'source':str(path),'sourceSha256':hashlib.sha256(raw).hexdigest(),
            'fixtureSha256':hashlib.sha256(fixture.read_bytes()).hexdigest(),'consumerSha256':hashlib.sha256(generated.read_bytes()).hexdigest()}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root',type=Path,required=True);parser.add_argument('--major',choices=['8','17','21','25'],required=True)
    parser.add_argument('--output',type=Path,required=True);parser.add_argument('--fixture-parent',type=Path,default=Path('/tmp'))
    parser.add_argument('--prepare-only',action='store_true');args=parser.parse_args()
    out=args.output.resolve();out.mkdir(parents=True,exist_ok=False);receipt=prepare(args.source_root.resolve(),args.major,out)
    receipt.update(startedAt=datetime.now().astimezone().isoformat(),scope='actual source consumer only; not target VM or complete JDK qualification',commands=[])
    def save():
        (out/'receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    if args.prepare_only:
        receipt['state']='PREPARED_ONLY';save();print(json.dumps(receipt,ensure_ascii=False));return
    # 明确短路径避免AF_UNIX长度影响；失败保留此私有fixture根并在收据记录，不递归清理。
    temporary=Path(tempfile.mkdtemp(prefix='amcl-att-',dir=args.fixture_parent.resolve()))
    receipt['fixtureRoot']=str(temporary)
    def run(name,command):
        cp=subprocess.run(list(map(str,command)),capture_output=True,timeout=20)
        (out/(name+'.stdout.log')).write_bytes(cp.stdout);(out/(name+'.stderr.log')).write_bytes(cp.stderr)
        receipt['commands'].append({'name':name,'command':list(map(str,command)),'exitCode':cp.returncode});save()
        if cp.returncode:raise RuntimeError(name+': '+cp.stderr.decode(errors='replace'))
        return cp
    try:
        flags=['g++','-std=c++17','-O1','-g','-pthread','-Wall','-Wextra','-Wno-unused-function','-Werror',
               '-fsanitize=address,undefined','-fno-omit-frame-pointer']
        run('build',flags+['-D__OHOS__',out/'consumer.cpp','-o',out/'consumer'])
        cases=['normal-repeated','stop-before-init','init-race','fatal-self','restart-live','restart-stop','unlink-eintr','unlink-failure','quick-exit','atexit']
        for index,case in enumerate(cases):
            directory=temporary/str(index);run(case,['timeout','-k','1s','5s',out/'consumer',case,directory])
            if case in ('quick-exit','atexit'):directory.rmdir() # 非空即失败，不删除隐藏的残留文件。
        run('build-nonohos',flags+[out/'consumer.cpp','-o',out/'legacy'])
        directory=temporary/'legacy';cp=run('legacy-quick',['timeout','-k','1s','5s',out/'legacy','legacy-quick',directory])
        path=Path(cp.stdout.decode().strip())
        if path.parent!=directory or not re.fullmatch(r'\.java_pid[0-9]+',path.name):raise ValueError('legacy fixture path identity mismatch')
        run('legacy-survives',['test','-S',path]);path.unlink();directory.rmdir();temporary.rmdir()
        receipt['state']='PASS';receipt['cases']=cases
    except Exception as error:
        receipt['state']='FAIL';receipt['error']=str(error);raise
    finally:
        receipt['finishedAt']=datetime.now().astimezone().isoformat();save()
    print(json.dumps({'major':args.major,'state':receipt['state'],'sourceSha256':receipt['sourceSha256']}))


if __name__=='__main__':main()
