"""只读验证新capture解析器与实际Ninja完整直链输入，不重新运行CPU合同或生成资格。

必须给真实Ninja/cache及独立旧proof；输出记录工具/源码/178等实际分母。不存在对象
或摘要变化拒绝，不改proof，不把Windows只读Ninja文本观察冒称Linux重新编译。
"""
from pathlib import Path
from datetime import datetime,timezone
import argparse,hashlib,importlib.util,json,subprocess

def main():
    """读取实际命令并核全直链集合/原字节；仅新增解析控制，不调用任何编译命令。"""
    parser=argparse.ArgumentParser(description=__doc__)
    for key in ('ninja','cache','proof','output'):parser.add_argument('--'+key,type=Path,required=True)
    args=parser.parse_args();output=args.output.resolve()
    if output.exists():raise ValueError('new test receipt required')
    cache=args.cache.resolve();script=Path(__file__).with_name('capture-host-proof.py')
    spec=importlib.util.spec_from_file_location('capture_parser_under_test',script)
    capture=importlib.util.module_from_spec(spec);spec.loader.exec_module(capture)
    proof=json.loads(args.proof.read_text())
    command=[str(args.ninja.resolve()),'-C',str(cache),'-t','commands','MobileGL']
    text=subprocess.check_output(command,text=True)
    names=capture.direct_inputs(text,cache)
    if set(names)!=set(proof['linkInputs']):raise ValueError('actual full direct link set differs from preserved proof')
    for name in names:
        path=cache/name;row=proof['linkInputs'][name]
        if not path.is_file() or capture.sha(path)!=row['sha256'] or path.stat().st_size!=row['bytes']:
            raise ValueError('preserved actual object differs: '+name)
    controls=[]
    for name,invalid in [('empty',''),('no-link-input','c++ -o libMobileGL.so'),('outside-cache','c++ ../foreign.o -o libMobileGL.so'),('response-file','c++ @inputs.rsp local.a -o libMobileGL.so')]:
        try:capture.direct_inputs(invalid,cache)
        except ValueError:controls.append({'name':name,'rejected':True})
        else:raise ValueError('invalid parser input accepted: '+name)
    record={'finishedAt':datetime.now(timezone.utc).isoformat(),'command':command,
            'ninjaSha256':capture.sha(args.ninja),'captureSourceSha256':capture.sha(script),
            'preservedProofSha256':capture.sha(args.proof),'actualDirectInputs':len(names),
            'actualCommandsSha256':hashlib.sha256(text.encode()).hexdigest(),
            'sameCommandsAsHistoricalLinux':hashlib.sha256(text.encode()).hexdigest()==proof['ninjaCommandsSha256'],
            'controls':controls,'scope':'actual full input parser/read-only byte preservation only; no new Linux build/CPU/GPU qualification'}
    output.parent.mkdir(parents=True,exist_ok=True)
    with output.open('x') as stream:stream.write(json.dumps(record,indent=2)+'\n')
    print(json.dumps({'inputs':len(names),'controls':len(controls),'sameCommandsAsHistoricalLinux':record['sameCommandsAsHistoricalLinux']}));return 0

if __name__=='__main__':raise SystemExit(main())
