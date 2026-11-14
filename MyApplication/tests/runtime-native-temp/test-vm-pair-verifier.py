"""独立pair verifier的协议/篡改回归。合成资料只用于测试校验器，绝不作为设备资格。

每个拒绝用例独立复制基线，并同步相关transport摘要（除专门测试摘要损坏的用例），
因此必须由语义/跨角色关联校验拒绝，不能只依赖一处旧hash恰好不匹配。
"""
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module
v = load('pair_verify_tested', HERE / 'verify-vm-pair.py')
d = load('pair_driver_tested', HERE / 'run-vm-pair-device.py')
ROOT = 'run-native-temp-vms/'
NATIVE = '/data/storage/el2/base/haps/entry/files/tmp'
JAVA = '/data/storage/el2/base/haps/entry/files/jdk-runtime-qualification/synthetic-pair'


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(value, bytes): path.write_bytes(value)
    elif isinstance(value, str): path.write_text(value, encoding='utf-8', newline='\n')
    else: path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')


def property_bytes(props):
    return ('#SYNTHETIC_VERIFIER_TEST_ONLY\n' + ''.join(key+'='+value+'\n' for key,value in props.items())).encode('iso-8859-1')


def synchronize(run):
    """为语义负例重算pipe摘要和完整回读清单，不修改它们要检验的业务字段。"""
    parent = v.parse_json((run/'parent-result.json').read_text())
    stages = v.rows(parent['text'])
    total = 0
    for role in ('target','client'):
        pipe = (run/ROOT/role/'parent-pipe.txt').read_bytes()
        row = v.one(stages,'pair-pipe',role)
        row.update(bytes=len(pipe),retainedBytes=len(pipe),sha256=hashlib.sha256(pipe).hexdigest());total+=len(pipe)
    v.one(stages,'pair-parent-finished')['reportBytes']=total
    parent['text']=''.join(json.dumps(row)+'\n' for row in stages)
    write(run/'parent-result.json',parent);write(run/ROOT/'parent-report.txt',parent['text'])
    files={name:v.sha(run/name) for name in d.inventory_members() if (run/name).is_file()}
    write(run/'readback-inventory.json',{'protocol':'AMCL_NATIVE_TEMP_PAIR_READBACK_V1','files':files})


def mutate_json(path, key, value):
    body=v.parse_json(path.read_text());body[key]=value;write(path,body)


def mutate_props(path,key,value):
    body=v.properties(path.read_bytes());body[key]=value;write(path,property_bytes(body))


def golden(root, major='25'):
    """构造可跨代参数化的最小完整证据；文件均带合成标签，产物不含真实SDK/JDK代码。"""
    run=root/'evidence'; run.mkdir(parents=True)
    jar=root/'fixture.jar';write(jar,b'SYNTHETIC_PAIR_JAR_FOR_VERIFIER_TEST_ONLY')
    archive=root/'runtime.zip';write(archive,b'SYNTHETIC_RUNTIME_ZIP_FOR_VERIFIER_TEST_ONLY')
    hap=root/'test.hap'
    with zipfile.ZipFile(hap,'w') as package: package.writestr('libs/arm64-v8a/libentry.so',b'FAKE_ELF'+jar.read_bytes()+b'END')
    identity=dict(device='59JYD-USB-TEST',major=major,nonce='synthetic-pair',native_root=NATIVE,java_root=JAVA,
                  hap_sha=v.sha(hap),archive_sha=v.sha(archive),jar_sha=v.sha(jar))
    deployed=root/'deployment.json';write(deployed,dict(installed=True,preserveData=True,exitCode=0,device=identity['device'],hapSha256=identity['hap_sha'],finishedAt='2026-10-22T00:00:00+08:00'))
    transfer=dict(protocol='AMCL_NATIVE_TEMP_PAIR_TRANSFER_V1',profile='native-temp-vms',device=identity['device'],major=major,nonce=identity['nonce'],
        hapSha256=identity['hap_sha'],archiveSha256=identity['archive_sha'],jarSha256=identity['jar_sha'],expectedNativeRoot=NATIVE,expectedJavaRoot=JAVA,
        deploymentSha256=v.sha(deployed),parentReportReceived=True,ownerReportReceived=True,pairDirectoryReceived=True,freshNonceObserved=True,
        launchedAt='2026-10-22T00:00:01+08:00',finishedAt='2026-10-22T00:00:03+08:00')
    write(run/'transfer.json',transfer)
    write(run/'power-preflight.txt','Current State: AWAKE\nScreenOffTime: Timeout=300000ms\n')
    write(run/'parent-cgroup-after.txt','1:freezer:/Thawed\n')
    transfer['powerPreflight']=dict(state='AWAKE',overrideTimeoutMillis=None,sha256=v.sha(run/'power-preflight.txt'))
    transfer['parentFreezer']=dict(pid=100,state='Thawed',sha256=v.sha(run/'parent-cgroup-after.txt'))
    write(run/'transfer.json',transfer)
    stages=[dict(stage='native-temp-pair-parent',pid=100,major=major,fixtureSha256=identity['jar_sha'])]
    for role,pid in [('target',101),('client',102)]: stages.append(dict(stage='pair-child-start',role=role,result=0,sdkResult=0,reportedPid=pid,poisonedStart=False,pid=pid))
    stages.append(dict(stage='pair-parent-finished',targetPid=101,clientPid=102,targetExitObserved=True,clientExitObserved=True,
        targetCallbackSignal=0,clientCallbackSignal=0,timedOut=False,cleanupIncomplete=False,environmentClosed=False,poisonedStart=False,
        earlyEventOverflow=False,restartRequiredIfExitMissing=False,postExitFilesAbsent=True,reportBytes=0,error='',osExitStatus=None))
    write(run/ROOT/'installed-sha256.txt',identity['archive_sha']+'\n')
    for role,pid in [('target',101),('client',102)]:
        prefix=run/ROOT/role
        props=dict(schema='AMCL_NATIVE_TEMP_PAIR_V1',role=role,pid=str(pid),targetPid='101',major=major,nonce=identity['nonce'],
            fixtureJarSha256=identity['jar_sha'],nativeTmpdir=NATIVE,environmentTMPDIR=NATIVE,javaTmpdir=JAVA,
            UsePerfData='true',PerfDisableSharedMem='false',DisableAttachMechanism='false',passed='true')
        props.update({'selfPerf.path':NATIVE+'/hsperfdata_app/'+str(pid),'selfPerf.bytes':'32768','selfPerf.magic':'cafec0c0'})
        if role=='target':
            ready=dict(props,passed='false');write(run/ROOT/'target-ready.properties',property_bytes(ready));props['completedProgress']='20'
        else:
            props.update({'attach.propertiesVerified':'true','attach.detached':'true','perf.bodyVerified':'true','perf.detachRequested':'true',
                'perf.first':'5','perf.last':'9','discovery.targetListed':'true','discovery.vmCount':'2','discovery.defaultNativeRoot':NATIVE,
                'targetPerf.path':NATIVE+'/hsperfdata_app/101','targetPerf.bytes':'32768','targetPerf.magic':'cafec0c0'})
        write(prefix/'java-result.properties',property_bytes(props));write(prefix/'qualification.jar',jar.read_bytes())
        native=dict(schema=1,profile='native-temp-vms',role=role,major=major,pid=pid,archiveSha256=identity['archive_sha'],fixtureSha256=identity['jar_sha'],
            installedHere=role=='target',initResult=0,mainResult=0,destroyResult=0,completionProof=True,passed=True,error='')
        write(prefix/'result.json',native)
        child=[dict(stage='pair-child',role=role,pid=pid)]
        if role=='target': child.append(dict(stage='install-complete',archiveSha256=identity['archive_sha']))
        child.extend([dict(stage='pair-java-main'),dict(stage='pair-java-main-return',role=role,result=0),native])
        child_text=''.join(json.dumps(row)+'\n' for row in child)
        write(prefix/'native-stages.jsonl',child_text);write(prefix/'parent-pipe.txt',child_text)
        for name in ('main-completed.txt','main-ended.txt','worker.txt','shutdown.txt'):write(prefix/name,identity['nonce']+'\n')
        write(prefix/'stdout.log','SYNTHETIC_JAVA_STDOUT\n')
        stages.append(dict(stage='pair-pipe',role=role,bytes=0,retainedBytes=0,sha256=''))
    write(run/ROOT/'owner-reclaimed.json',dict(schema=1,stage='pair-owner-reclaimed',targetPid=101,clientPid=102,targetExitObserved=True,clientExitObserved=True,
        lateCleanup=False,environmentClosed=False,reclaimExecutor='napi-loop',unregisterResult=0,restartRequired=False))
    text=''.join(json.dumps(row)+'\n' for row in stages)
    write(run/'parent-result.json',dict(nonce=identity['nonce'],startedAt=1,finishedAt=2,transportOk=True,text=text,error=None))
    write(run/ROOT/'parent-report.txt',text);synchronize(run)
    return run,deployed,hap,archive,jar,identity


def run_tests(output):
    output.mkdir(exist_ok=False)
    inputs=golden(output/'golden')
    run,deployment,hap,archive,jar,identity=inputs
    def verify(target):return v.verify_pair(target,deployment,hap,archive,jar,**identity)
    assert verify(run)['pairQualified']
    cases=[]
    for role in ('target','client'):
        base=ROOT+role+'/'
        for key,bad in [('major','17'),('nonce','wrong'),('pid','999'),('targetPid','999'),('fixtureJarSha256','0'*64),
                        ('UsePerfData','false'),('PerfDisableSharedMem','true'),('DisableAttachMechanism','true'),
                        ('nativeTmpdir','/tmp'),('environmentTMPDIR','/tmp'),('javaTmpdir','/tmp'),('passed','false')]:
            cases.append((role+'-props-'+key,lambda p,k=key,b=bad,f=base+'java-result.properties':mutate_props(p/f,k,b)))
        for key,bad in [('major','17'),('pid',999),('archiveSha256','0'*64),('fixtureSha256','0'*64),('completionProof',False),('destroyResult',-1),('installedHere',role!='target')]:
            cases.append((role+'-native-'+key,lambda p,k=key,b=bad,f=base+'result.json':mutate_json(p/f,k,b)))
        for name in ('qualification.jar','main-completed.txt','main-ended.txt','worker.txt','shutdown.txt','stdout.log','native-stages.jsonl','parent-pipe.txt'):
            cases.append((role+'-missing-'+name,lambda p,f=base+name:(p/f).unlink()))
        cases.append((role+'-checkjni',lambda p,f=base+'stdout.log':write(p/f,'WARNING in native method: test\n')))
        cases.append((role+'-crash',lambda p,f=base+'hs_err_pid999.log':write(p/f,'SYNTHETIC_CRASH')))
    for key,bad in [('attach.propertiesVerified','false'),('attach.detached','false'),('perf.bodyVerified','false'),('perf.detachRequested','false'),
                    ('perf.last','5'),('perf.first','0'),('discovery.targetListed','false'),('discovery.vmCount','0'),('targetPerf.path',NATIVE+'/hsperfdata_app/999')]:
        cases.append(('client-'+key,lambda p,k=key,b=bad:mutate_props(p/ROOT/'client/java-result.properties',k,b)))
    for key,bad in [('targetPid',999),('clientPid',999),('targetExitObserved',False),('clientExitObserved',False),
                    ('unregisterResult',77),('restartRequired',True),('lateCleanup',True),('environmentClosed',True),('reclaimExecutor','one-shot-native')]:
        cases.append(('owner-'+key,lambda p,k=key,b=bad:mutate_json(p/ROOT/'owner-reclaimed.json',k,b)))
    for key,bad in [('postExitFilesAbsent',False),('timedOut',True),('cleanupIncomplete',True),('poisonedStart',True),('earlyEventOverflow',True),('targetCallbackSignal',9),('clientCallbackSignal',9),('osExitStatus',0)]:
        def alter(p,k=key,b=bad):
            parent=v.parse_json((p/'parent-result.json').read_text());items=v.rows(parent['text']);v.one(items,'pair-parent-finished')[k]=b
            parent['text']=''.join(json.dumps(row)+'\n' for row in items);write(p/'parent-result.json',parent)
        cases.append(('parent-'+key,alter))
    cases.extend([
        ('duplicate-properties',lambda p:write(p/ROOT/'client/java-result.properties',(p/ROOT/'client/java-result.properties').read_bytes()+b'nonce=wrong\n')),
        ('duplicate-json',lambda p:write(p/ROOT/'owner-reclaimed.json','{"schema":1,"schema":1}\n')),
        ('owner-missing',lambda p:(p/ROOT/'owner-reclaimed.json').unlink()),
        ('ready-missing',lambda p:(p/ROOT/'target-ready.properties').unlink()),
        ('cleanup-failure-record',lambda p:write(p/ROOT/'owner-cleanup-failed.json','{}')),
        ('wrong-readiness-nonce',lambda p:mutate_props(p/ROOT/'target-ready.properties','nonce','wrong')),
        ('wrong-slot-seal',lambda p:write(p/ROOT/'installed-sha256.txt','0'*64+'\n')),
        ('wrong-transfer-hap',lambda p:mutate_json(p/'transfer.json','hapSha256','0'*64)),
        ('wrong-transfer-device',lambda p:mutate_json(p/'transfer.json','device','other-usb')),
        ('wrong-java-expectation',lambda p:mutate_json(p/'transfer.json','expectedJavaRoot',NATIVE)),
        ('wrong-transfer-deployment',lambda p:mutate_json(p/'transfer.json','deploymentSha256','0'*64))])
    # 不能只相信transfer自报状态；将原始dump和摘要一起篡改仍须被正文状态检查拒绝。
    def altered_power(p):
        write(p/'power-preflight.txt','Current State: ASLEEP\n')
        body=v.parse_json((p/'transfer.json').read_text());body['powerPreflight']['sha256']=v.sha(p/'power-preflight.txt');write(p/'transfer.json',body)
    def altered_freezer(p):
        write(p/'parent-cgroup-after.txt','1:freezer:/Frozen\n')
        body=v.parse_json((p/'transfer.json').read_text());body['parentFreezer']['sha256']=v.sha(p/'parent-cgroup-after.txt');write(p/'transfer.json',body)
    cases.extend([('power-raw-state-tamper',altered_power),('freezer-raw-state-tamper',altered_freezer)])
    rejected=[]
    for number,(name,change) in enumerate(cases):
        target=output/('negative-%03d'%number);shutil.copytree(run,target);change(target)
        try:synchronize(target)
        except (FileNotFoundError,ValueError):pass
        try:verify(target)
        except (ValueError,OSError,KeyError,TypeError) as failure:rejected.append({'name':name,'error':str(failure)})
        else:raise AssertionError('accepted mutation: '+name)
    # 四代正常身份均接受；仍是合成协议测试，不能当成四次设备执行。
    for major in ('8','17','21','25'):
        local=golden(output/('major-'+major),major);assert v.verify_pair(*local[:5],**local[5])['pairQualified']
    assert v.properties(b'k=\\u4e2d\\u6587\npath=a\\:b\n')=={'k':'中文','path':'a:b'}
    report={'protocol':'AMCL_PAIR_VERIFIER_TEST_V1','syntheticOnly':True,'positiveMajors':['8','17','21','25'],
            'negativeCount':len(rejected),'negativeCases':rejected,'verifierSha256':v.sha(HERE/'verify-vm-pair.py')}
    write(output/'result.json',report)
    print(json.dumps({'passed':True,'syntheticOnly':True,'negativeCount':len(rejected)}))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True)
    run_tests(parser.parse_args().output)
