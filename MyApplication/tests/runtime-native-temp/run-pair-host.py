"""在项目既有QA中编译真实PairOwner/session正文；输出必须显式外置，不复制生产算法。"""
from pathlib import Path
import argparse,hashlib,json,subprocess
from datetime import datetime

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root',type=Path,required=True);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();root=args.source_root.resolve();out=args.output.resolve();out.mkdir(parents=True,exist_ok=False)
    source=root/'entry/src/main/cpp/napi/jdk_native_temp_vm_pair.inc'
    text=source.read_text(encoding='utf-8').split('/** Properties仅提取固定ASCII身份键；')[0]
    (out/'actual-session.inc').write_text(text,encoding='utf-8')
    test=root/'tests/runtime-native-temp';commands=[]
    def run(name,argv,timeout=60):
        started=datetime.now().astimezone().isoformat();cp=subprocess.run(list(map(str,argv)),capture_output=True,timeout=timeout)
        (out/(name+'.stdout.log')).write_bytes(cp.stdout);(out/(name+'.stderr.log')).write_bytes(cp.stderr)
        commands.append(dict(name=name,command=list(map(str,argv)),startedAt=started,finishedAt=datetime.now().astimezone().isoformat(),exitCode=cp.returncode))
        (out/'commands.json').write_text(json.dumps(commands,indent=2),encoding='utf-8')
        print(cp.stdout.decode(errors='replace'),end='',flush=True)
        if cp.returncode:raise RuntimeError(name+': '+cp.stderr.decode(errors='replace'))
    flags=['g++','-std=c++17','-O1','-g','-pthread','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-fno-omit-frame-pointer']
    run('build-owner',flags+[test/'pair_owner_test.cpp','-o',out/'pair-owner'])
    run('owner',['timeout','-k','1s','10s',out/'pair-owner'])
    run('build-session',flags+['-I'+str(root/'entry/src/main/cpp'),'-DAMCL_PAIR_SESSION_BODY="'+str(out/'actual-session.inc')+'"',test/'pair_session_lifecycle_test.cpp','-o',out/'pair-session'])
    (out/'work').mkdir();run('session',['timeout','-k','1s','25s',out/'pair-session',out/'work'])
    run('verifier',['python3','-B',test/'test-vm-pair-verifier.py','--output',out/'verifier'],240)
    run('driver',['python3','-B',test/'test-vm-pair-driver.py','--output',out/'driver'],120)
    receipt=dict(state='PASS',scope='host lifecycle and synthetic protocol verification only',commands=commands,
        sourceSha256=hashlib.sha256(source.read_bytes()).hexdigest(),ownerSha256=hashlib.sha256((root/'entry/src/main/cpp/napi/jdk_native_temp_pair_owner.h').read_bytes()).hexdigest())
    (out/'receipt.json').write_text(json.dumps(receipt,indent=2),encoding='utf-8')

if __name__=='__main__':main()
