"""只观察所属MobileGL原CTS runner的真实Popen，不改case、恢复或QPA评分。

输入为明确仓外source、新观察输出以及--后的原runner参数。provider观察header
必须已编入glcts；本脚本不构建、不补stub、不引入系统GL fallback。退出码只是
原runner返回值，最终资格由独立QPA/provider校验决定。
"""
from pathlib import Path
from datetime import datetime, timezone
import argparse, hashlib, importlib.util, json, os, subprocess, sys
sys.dont_write_bytecode = True

def digest(path):
    """保留真实文件字节摘要，不把路径或生产者声明当成制品身份。"""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def main():
    """绑定原runner和独占记录目录，再将未经修改的CLI交给原main。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--observations', type=Path, required=True)
    parser.add_argument('--expected-runner-sha', required=True)
    parser.add_argument('runner_args', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    script = args.source.resolve()/'tools/cts/scripts/run_cts_local.py'
    if digest(script) != args.expected_runner_sha:
        raise ValueError('independently selected original runner changed')
    output = args.observations.resolve()
    if output.exists() or args.source.resolve() in output.parents:
        raise ValueError('observations must be new and outside source')
    # 现役C++观察器采用固定JSONL格式；显式路径/runId禁止引号和控制符，避免不合法JSON。
    for key in ('AMCL_RUN_ID','AMCL_CTS_PROVIDER_LOG_PREFIX','AMCL_CTS_EXPECTED_PROVIDER'):
        value = os.environ.get(key, '')
        if not value or any(ord(c)<32 or c in '\\"' for c in value):
            raise ValueError('missing/unsafe observer environment: '+key)
    if Path(os.environ['AMCL_CTS_EXPECTED_PROVIDER']).resolve()!=Path(os.environ.get('MOBILEGL_CTS_LIB','')).resolve():
        raise ValueError('selected loader and independently observed provider differ')
    output.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('original_mobilegl_cts_local', script)
    runner = importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)
    index = 0
    def observe(command, **kwargs):
        """保原argv/env/timeout；收PID、输入摘要和正常/强停边界，失败原样返回。"""
        nonlocal index
        number=index; index+=1; kwargs=dict(kwargs)
        timeout=kwargs.pop('timeout', None); kwargs.pop('check', None)
        kwargs.pop('stdout', None); kwargs.pop('stderr', None)
        environment=kwargs.get('env') or os.environ
        lists=[x.partition('=')[2] for x in command if x.startswith('--deqp-caselist-file=')]
        logs=[x.partition('=')[2] for x in command if x.startswith('--deqp-log-filename=')]
        if len(lists)!=1 or len(logs)!=1:
            raise ValueError('actual original argv lacks unique case/QPA path')
        record={'startedAt':datetime.now(timezone.utc).isoformat(),'command':command,
                'runId':environment['AMCL_RUN_ID'],'backend':environment['MOBILEGL_BACKEND_TYPE'],
                'requestedLibrary':environment['MOBILEGL_CTS_LIB'],
                'selectedLibrary':str(Path(environment['MOBILEGL_CTS_LIB']).resolve()),
                'librarySha256':digest(environment['MOBILEGL_CTS_LIB']),
                'glctsSha256':digest(command[0]),'runnerSha256':digest(script),'forcedKill':False,
                'actualCaselistSha256':digest(lists[0]),
                'actualCases':[x.strip() for x in Path(lists[0]).read_text().splitlines() if x.strip() and not x.lstrip().startswith('#')],
                'qpaPath':logs[0]}
        # 原runner可更新remaining.txt；每个真实Popen保留当次原字节，避免恢复时借下一轮list。
        with (output/f'{number:04d}.caselist.txt').open('xb') as snapshot:
            snapshot.write(Path(lists[0]).read_bytes())
        with (output/f'{number:04d}.native.log').open('xb') as stream:
            process=subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT, **kwargs)
            record['pid']=process.pid
            try: code=process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                record['forcedKill']=True; process.kill(); code=process.wait()
                record.update(exitCode=code,finishedAt=datetime.now(timezone.utc).isoformat())
                with (output/f'{number:04d}.json').open('x') as receipt: json.dump(record,receipt,indent=2)
                raise
        record.update(exitCode=code,finishedAt=datetime.now(timezone.utc).isoformat())
        with (output/f'{number:04d}.json').open('x') as receipt: receipt.write(json.dumps(record,indent=2)+'\n')
        return subprocess.CompletedProcess(command, code)
    runner.subprocess.run=observe
    forwarded=args.runner_args[1:] if args.runner_args[:1]==['--'] else args.runner_args
    sys.argv=[str(script),*forwarded]
    return runner.main()

if __name__=='__main__': raise SystemExit(main())
