"""同一真实宿主JDK、同一JAR与工作量的CF三臂交错对照；不接设备、不修改产品默认。

每臂独立进程并有进程外deadline/真实完成计数监督。只终止本次Popen拥有的进程。
保留全部日志、参数、PID和JVM/JAR SHA；数值只描述该宿主夹具，不换算成设备FPS。
"""
from pathlib import Path
import argparse
import datetime
import json
import random
import shutil
import statistics
import struct
import subprocess
import sys
import time
import zipfile

sys.dont_write_bytecode = True
from cf_evidence import BASE, external, fields, sha, verify
from cf_policy import POLICY, C2_FILE, compiler_options


def stamp():
    return datetime.datetime.now().astimezone().isoformat()


def write(path, value):
    path.write_text(json.dumps(value,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--java-home', type=Path, required=True)
    parser.add_argument('--javac-home', type=Path, help='Java8运行时可用另一个支持--release8的javac构建同一JAR')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--lanes', type=int, default=4)
    parser.add_argument('--warmup', type=int, default=50000)
    parser.add_argument('--measured', type=int, default=1000000)
    parser.add_argument('--stress', type=int, default=1200)
    parser.add_argument('--timeout', type=int, default=180)
    parser.add_argument('--seed', type=int, default=20261021)
    args = parser.parse_args()
    if not 1 <= args.rounds <= 10 or not 30 <= args.timeout <= 300:
        raise ValueError('Unbounded rounds/timeout')
    output = external(args.output); output.mkdir(parents=True,exist_ok=False)
    classes = output/'classes'; classes.mkdir()
    suffix = '.exe' if sys.platform == 'win32' else ''
    java = args.java_home.resolve()/'bin'/('java'+suffix)
    javac = (args.javac_home or args.java_home).resolve()/'bin'/('javac'+suffix)
    version = subprocess.run([str(java),'-version'],capture_output=True,timeout=15)
    (output/'java-version.txt').write_bytes(version.stdout+version.stderr)
    if version.returncode: raise RuntimeError('java -version failed')
    legacy = b'version "1.8.' in version.stdout+version.stderr
    jvm_candidates = ['bin/server/jvm.dll','lib/server/libjvm.so','jre/bin/server/jvm.dll','jre/lib/amd64/server/libjvm.so']
    libraries = [args.java_home/item for item in jvm_candidates if (args.java_home/item).is_file()]
    if len(libraries) != 1: raise ValueError('Need one concrete host JVM library identity')
    source = BASE/'CompletableFutureQualification.java'
    command = [str(javac),'--release','8','-encoding','UTF-8','-d',str(classes),str(source)]
    compiled = subprocess.run(command,capture_output=True,timeout=45)
    (output/'javac.log').write_bytes(compiled.stdout+compiled.stderr)
    if compiled.returncode: raise RuntimeError('fixture compilation failed')
    artifact = output/'cf-qualification.jar'
    # 固定时间和顺序，所有臂消费同一class52字节；实际执行JAR会由Java再次算SHA。
    with zipfile.ZipFile(artifact,'x',zipfile.ZIP_DEFLATED) as jar:
        for file in sorted(classes.rglob('*.class')):
            data = file.read_bytes()
            if data[:4] != b'\xca\xfe\xba\xbe' or struct.unpack('>H',data[6:8])[0] != 52:
                raise ValueError('Fixture is not class52')
            entry = zipfile.ZipInfo(file.relative_to(classes).as_posix(),date_time=(2000,1,1,0,0,0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            jar.writestr(entry,data)
    receipt = dict(startedAt=stamp(),state='running',hostOnly=True,java=str(java),
        jvmLibrary=str(libraries[0]),jvmSha256=sha(libraries[0]),sourceSha256=sha(source),
        jarSha256=sha(artifact),javacCommand=command,seed=args.seed,runs=[],
        compilerPolicy=POLICY,compilerPolicySha256=sha(BASE/'cf_policy.py'),
        c2DirectivesSha256=sha(BASE/C2_FILE),verifierSha256=sha(BASE/'cf_evidence.py'),
        jdk8C2Only='NOT-SUPPORTED: no compiler directives; host full omits broad flag, target needs fixed qualification profile')
    write(output/'receipt.json',receipt)
    generator = random.Random(args.seed)
    try:
        for block in range(args.rounds):
            order = ['broad','full'] if legacy else ['broad','c2-only','full']
            generator.shuffle(order)
            for arm in order:
                directory = output/('%02d-' % (block+1)+arm); directory.mkdir()
                shutil.copyfile(artifact,directory/artifact.name)
                # 除CF编译策略外所有参数相同；保留便携的生产GC/内存/核数/attach/perf策略。
                options = ['-Xms64m','-Xmx256m','-XX:+UseParallelGC','-XX:-UseCompressedOops',
                    '-XX:-UsePerfData','-XX:+DisableAttachMechanism','-XX:ActiveProcessorCount=8',
                    '-XX:+UnlockDiagnosticVMOptions','-XX:+LogCompilation',
                    '-XX:LogFile='+str(directory/'compilation.xml')]
                # v2不只改变CF编译根：必须清除legacy对所有调用者的禁内联。
                # 固定策略模块同时保留8原行为，两个历史JSON不覆写。
                options += compiler_options(arm,legacy,directory)
                command = [str(java),*options,'-cp',str(directory/artifact.name),'CompletableFutureQualification',
                           str(directory),arm,str(args.lanes),str(args.warmup),str(args.measured),str(args.stress)]
                write(directory/'command.json',command)
                record = dict(block=block+1,arm=arm,startedAt=stamp(),command=command,events=[])
                receipt['runs'].append(record); write(output/'receipt.json',receipt)
                started = time.monotonic(); changed = started; previous = None; killed = None
                with (directory/'stdout.log').open('wb') as stdout, (directory/'stderr.log').open('wb') as stderr:
                    process = subprocess.Popen(command,cwd=directory,stdout=stdout,stderr=stderr)
                    record['pid'] = process.pid
                    print('START',block+1,arm,'pid='+str(process.pid),flush=True)
                    while process.poll() is None:
                        now = time.monotonic()
                        progress = directory/'cf-progress.log'
                        if progress.exists():
                            lines = progress.read_text(encoding='utf-8',errors='replace').splitlines()
                            points = [line for line in lines if line.startswith(('CF_PROGRESS ','CF_PHASE_DONE '))]
                            if points:
                                point = fields(points[-1]); key = (point.get('phase',point.get('name')),point.get('completed'))
                                if key != previous:
                                    changed = now; previous = key
                                    record['events'].append(dict(elapsed=now-started,phase=key[0],completed=key[1]))
                        if now-started > args.timeout or now-changed > 25:
                            killed = 'deadline' if now-started > args.timeout else 'no-completed-graph-progress'
                            process.kill()  # 本Popen仍拥有的唯一进程，不按猜测PID终止其他进程。
                            break
                        time.sleep(.2)
                    record['exitCode'] = process.wait(timeout=15)
                record.update(finishedAt=stamp(),termination=killed,elapsed=time.monotonic()-started)
                if killed or record['exitCode'] != 0:
                    raise RuntimeError('CF process failed; preserved '+str(directory))
                result = verify(directory,arm,args.lanes,args.warmup,args.measured,args.stress)
                write(directory/'verification.json',result)
                record['verified'] = result['passed']; record['problems'] = result['problems']
                record['measurement'] = result['result']
                write(output/'receipt.json',receipt)
                print('END',block+1,arm,'PASS' if result['passed'] else result['problems'],flush=True)
                if not result['passed']: raise RuntimeError('CF verification failed')
        # 中位数只描述本机固定图；同时保留每个paired block的原数，不由一轮定产品策略。
        receipt['summary'] = {}
        for arm in sorted({run['arm'] for run in receipt['runs']}):
            runs = [run['measurement'] for run in receipt['runs'] if run['arm'] == arm]
            receipt['summary'][arm] = dict(
                medianWallNsPerGraph=statistics.median(int(run['wallNanos'])/int(run['operations']) for run in runs),
                medianCpuNsPerGraph=statistics.median(int(run['cpuNanos'])/int(run['operations']) for run in runs),
                runs=len(runs))
        receipt['state'] = 'pass'
    finally:
        if receipt['state'] == 'running': receipt['state'] = 'failed'
        receipt['finishedAt'] = stamp(); write(output/'receipt.json',receipt)
    print(json.dumps(receipt['summary'],indent=2),flush=True)


if __name__ == '__main__':
    main()
