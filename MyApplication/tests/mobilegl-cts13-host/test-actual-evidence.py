"""仅用已实取的两backend及污染副本核薄层拒绝；不执行CTS、不新增GPU资格。

所有路径显式给定，positive先用原始QPA/provider校准；negative只复制原证据后
破坏完成/身份或必需core地址。生成输出必须仓外且新建，原件和原评分永不改写。
"""
from pathlib import Path
from datetime import datetime,timezone
import argparse,copy,importlib.util,json,shutil

def main():
    """执行真实原件解析与最小身份/截断反控，结果只描述parser资格。"""
    parser=argparse.ArgumentParser(description=__doc__)
    for key in ('source','cts-source','library','glcts','gles','vulkan','expectations','output'):
        parser.add_argument('--'+key,type=Path,required=True)
    args=parser.parse_args();output=args.output.resolve()
    if output.exists():raise ValueError('test output already exists')
    for original in (args.source,args.cts_source,args.gles,args.vulkan):
        if original.resolve() in output.parents:raise ValueError('output inside original source/evidence')
    module_path=Path(__file__).with_name('qualify.py')
    spec=importlib.util.spec_from_file_location('qualification_under_test',module_path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    expectations=json.loads(args.expectations.read_text());output.mkdir(parents=True)
    rows=[]
    def check(name,directory,expected,pass_expected):
        """输入例外也属于拒绝，不让损坏文档跳过断言。"""
        try:
            result=module.qualify(directory,args.source.resolve(),args.cts_source.resolve(),args.library.resolve(),args.glcts.resolve(),expected)
            accepted=result['qualified'];detail=result['issues'];(output/(name+'.json')).write_text(json.dumps(result,indent=2)+'\n')
        except (ValueError,KeyError,TypeError,OSError) as error:accepted=False;detail=[str(error)]
        if accepted!=pass_expected:raise ValueError(name+' did not enforce expected boundary: '+str(detail))
        rows.append({'name':name,'accepted':accepted,'expectedAccepted':pass_expected,'detail':detail})
    for backend,original in [('DirectGLES',args.gles),('DirectVulkan',args.vulkan)]:
        check('actual-'+backend,original.resolve(),expectations[backend],True)
    original=args.gles.resolve();expected=expectations['DirectGLES']
    controls=['qpa-tail','qpa-last-case','provider-tail','provider-old-pid','provider-old-run',
              'forced-kill','wrong-library','wrong-run','wrong-backend','required-missing','mixed-image','write-error',
              'case-fail','case-not-supported','malformed-driver-array',
              'required-address-one','required-address-data','wrong-base-all','wrong-exec-inode',
              'unbound-qpa','earlier-fail-later-pass']
    for name in controls:
        target=output/name;target.mkdir();shutil.copytree(original/'cases',target/'cases');shutil.copytree(original/'native-processes',target/'native-processes')
        process_path=target/'native-processes/0000.json';process=json.loads(process_path.read_text());pid=process['pid']
        for suffix in ('jsonl','maps'):shutil.copyfile(original/f'provider.{pid}.{suffix}',target/f'provider.{pid}.{suffix}')
        qpa=target/'cases'/Path(process['qpaPath']).name;provider=target/f'provider.{pid}.jsonl'
        independent=copy.deepcopy(expected)
        if name=='qpa-tail':qpa.write_text(qpa.read_text().replace('#endSession',''))
        elif name=='qpa-last-case':
            text=qpa.read_text();cut=text.rfind('#beginTestCaseResult ');qpa.write_text(text[:cut]+'#endSession\n')
        elif name=='forced-kill':process['forcedKill']=True
        elif name=='wrong-library':process['librarySha256']='0'*64
        elif name=='wrong-run':independent['runId']='independent-other-run'
        elif name=='wrong-backend':independent['backend']='DirectVulkan'
        elif name in ('case-fail','case-not-supported'):
            text=qpa.read_text();status='Fail' if name=='case-fail' else 'NotSupported'
            if 'StatusCode="Pass"' not in text:raise ValueError('positive raw QPA PASS calibration missing')
            qpa.write_text(text.replace('StatusCode="Pass"','StatusCode="'+status+'"',1))
        elif name=='malformed-driver-array':independent['mappedDriverPaths']=None
        elif name=='wrong-exec-inode':
            mapped=target/f'provider.{pid}.maps';lines=[]
            for line in mapped.read_text().splitlines():
                fields=line.split(None,5)
                if len(fields)==6 and fields[5]==expected['providerPath'] and 'x' in fields[1]:fields[4]=str(int(fields[4])+1);line=' '.join(fields)
                lines.append(line)
            mapped.write_text('\n'.join(lines)+'\n')
        elif name=='unbound-qpa':shutil.copyfile(qpa,target/'cases/chunk0001.qpa')
        elif name=='earlier-fail-later-pass':
            text=qpa.read_text();qpa.write_text(text.replace('StatusCode="Pass"','StatusCode="Fail"',1));(target/'cases/chunk0001.qpa').write_text(text)
            second=copy.deepcopy(process);second['pid']=pid+1;second['qpaPath']=process['qpaPath'].replace('chunk0000.qpa','chunk0001.qpa')
            second['command']=[x.replace('chunk0000.qpa','chunk0001.qpa') for x in process['command']]
            (target/'native-processes/0001.json').write_text(json.dumps(second)+'\n')
            events=[json.loads(x) for x in provider.read_text().splitlines()]
            for event in events:event['pid']=pid+1
            (target/f'provider.{pid+1}.jsonl').write_text(''.join(json.dumps(x)+'\n' for x in events));shutil.copyfile(target/f'provider.{pid}.maps',target/f'provider.{pid+1}.maps')
        else:
            events=[json.loads(x) for x in provider.read_text().splitlines()]
            if name=='provider-tail':events=events[:-1]
            elif name=='provider-old-pid':events[1]['pid']=pid+1
            elif name=='provider-old-run':events[1]['runId']='old-run'
            elif name=='required-missing':
                row=next(x for x in events if x.get('symbol')=='glReadPixels');row.update(verdict='MISSING',address='(nil)',imageBase='(nil)',library='');events[-1]['missing']+=1
            elif name=='mixed-image':
                row=next(x for x in events if x.get('symbol')=='glReadPixels');row['imageBase']='0x1'
            elif name=='write-error':events[-1]['writeErrors']=1
            elif name in ('required-address-one','required-address-data'):
                row=next(x for x in events if x.get('symbol')=='glReadPixels');row['address']='0x1' if name=='required-address-one' else row['imageBase']
            elif name=='wrong-base-all':
                for row in events:
                    if row.get('verdict')=='OWN':row['imageBase']=hex(int(row['imageBase'],16)+4096)
            provider.write_text(''.join(json.dumps(x)+'\n' for x in events))
        process_path.write_text(json.dumps(process,indent=2)+'\n')
        check(name,target,independent,False)
    receipt={'finishedAt':datetime.now(timezone.utc).isoformat(),'qualificationModuleSha256':module.sha(module_path),
             'expectationsSha256':module.sha(args.expectations),'rows':rows,'scope':'two actual archived positives + twenty-one poisoned raw-evidence parser controls only; no CPU/GPU execution'}
    (output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps({'controls':len(rows),'passed':True}));return 0

if __name__=='__main__':raise SystemExit(main())
