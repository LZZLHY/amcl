"""设备driver的离线命令/失败边界；subprocess由显式替身接管，绝不连接设备。

基线来自标记为SYNTHETIC的完整pair资料，检验显式身份、USB/TCP、一次launch、owner等待、
HDC零退出[Fail]、屏幕/冻结前置和失败保留。生产driver本身不含跳过验收的测试开关。
"""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
from types import SimpleNamespace

sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
fixture=load('pair_driver_fixture',HERE/'test-vm-pair-verifier.py')
driver=load('pair_driver',HERE/'run-vm-pair-device.py')


class FakeHdc:
    """只返回固定协议；保存真实driver发出的每个参数，不能模拟外部JVM成功执行。"""
    def __init__(self,source,mode):self.source=source;self.mode=mode;self.calls=[];self.owner_attempts=0
    def __call__(self,args,**kwargs):
        self.calls.append(args);command=args[3:];text='OK\n';code=0
        if command[0]=='shell':
            if command[1].startswith('if [ -e '):text='AMCL_PAIR_EXISTS\n' if self.mode=='existing' else 'AMCL_PAIR_FRESH\n'
            elif command[1]=='power-shell wakeup':text='wakeup succeeded\n'
            elif command[1]=='aa':text='start ability successfully.\n'
            elif command[1].startswith('hidumper '):
                text='Current State: '+('ASLEEP' if self.mode=='asleep' else 'AWAKE')+'\nScreenOffTime: Timeout=300000ms\n'
                if self.mode=='override':text+='OverrideTimeout=10000ms\n'
            elif command[1].startswith('cat /proc/'):
                # 使用现场实际出现的根组作为独立正例；相似路径与双记录不能混同合法根组。
                paths = {'root': '/', 'root-neighbor': '/Thawed/other', 'frozen': '/Frozen'}
                text='1:freezer:'+paths.get(self.mode,'/Thawed')+'\n'
                if self.mode=='duplicate-freezer':text+='1:freezer:/\n'
            else:raise AssertionError('unexpected shell command: '+repr(command))
        elif command[:2]==['file','send']:
            if self.mode=='send-fail':text='[Fail] transfer error\n'
        elif command[:2]==['file','recv']:
            remote,target=command[-2],Path(command[-1]);target.parent.mkdir(parents=True,exist_ok=True)
            if remote.endswith('owner-reclaimed.json'):
                self.owner_attempts+=1
                if self.owner_attempts==1 or self.mode=='owner-timeout':text='[Fail] no file yet\n'
                else:shutil.copyfile(self.source/'run-native-temp-vms/owner-reclaimed.json',target)
            elif remote.endswith('run-native-temp-vms'):shutil.copytree(self.source/'run-native-temp-vms',target)
            elif '/jdk-java-' in remote:shutil.copyfile(self.source/'parent-result.json',target)
            else:raise AssertionError('unexpected recv: '+remote)
        else:raise AssertionError('unexpected HDC command')
        return subprocess.CompletedProcess(args,code,text.encode(),b'')


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True);out=parser.parse_args().output
    out.mkdir(exist_ok=False);items=[]
    for mode in ('usb','tcp','root','root-neighbor','duplicate-freezer','existing','send-fail','asleep','override','frozen','owner-timeout','bad-hap','bad-java-root'):
        source,deployment,hap,archive,jar,identity=fixture.golden(out/(mode+'-input'))
        if mode=='tcp':
            identity['device']='192.0.2.10:12345'
            body=json.loads(deployment.read_text());body['device']=identity['device'];fixture.write(deployment,body)
        args=SimpleNamespace(output=out/(mode+'-output'),hap=hap,archive=archive,jar=jar,deployment=deployment,
            hdc=Path('hdc-is-not-executed'),device=identity['device'],major=identity['major'],nonce=identity['nonce'],
            device_files_root='/data/app/el2/100/base/com.amcl.launcher/haps/entry/files',
            expected_native_root=identity['native_root'],expected_java_root=identity['java_root'],
            expected_hap_sha256=identity['hap_sha'],expected_archive_sha256=identity['archive_sha'],expected_jar_sha256=identity['jar_sha'])
        if mode=='bad-hap':args.expected_hap_sha256='0'*64
        if mode=='bad-java-root':args.expected_java_root='/tmp'
        fake=FakeHdc(source,mode);clock=[0]
        def monotonic():clock[0]+=100 if mode=='owner-timeout' else 1;return clock[0]
        error=None
        try:result=driver.execute(args,runner=fake,sleep=lambda _:None,monotonic=monotonic)
        except (ValueError,RuntimeError,FileNotFoundError) as failure:error=str(failure)
        assert (error is None)==(mode in ('usb','tcp','root')),(mode,error)
        launches=[index for index,command in enumerate(fake.calls) if 'amclJdkProfile' in command]
        assert len(launches)==(1 if mode in ('usb','tcp','root','root-neighbor','duplicate-freezer','frozen','owner-timeout') else 0)
        assert not any('force-stop' in command or any('timeout -' in part for part in command) for command in fake.calls)
        if mode in ('usb','tcp','root'):
            assert result['pairQualified'] and fake.owner_attempts==2
            wake=next(i for i,c in enumerate(fake.calls) if 'power-shell wakeup' in c)
            foreground=next(i for i,c in enumerate(fake.calls) if 'aa' in c)
            assert wake<foreground<launches[0]
        if mode.startswith('bad-'):assert not fake.calls and not args.output.exists()
        else:
            assert (args.output/'transfer.json').is_file()
            assert all(command[1:3]==['-t',identity['device']] for command in fake.calls)
        items.append(dict(mode=mode,accepted=error is None,launchCount=len(launches),hdcCalls=len(fake.calls),error=error))
    fixture.write(out/'result.json',dict(protocol='AMCL_PAIR_DRIVER_TEST_V1',syntheticOnly=True,passed=True,cases=items))
    print(json.dumps(dict(passed=True,syntheticOnly=True,cases=len(items))))


if __name__=='__main__':main()
