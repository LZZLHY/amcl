"""仅验证新proof套件CLI前置边界；读取真实clean源/cache，不启动Docker或CPU。

Docker image/忙态是隔离接口替身，不能据此给运行资格。真实Git保持原生查询，
正例只到plan-only，错source/缺cache必须在输出创建与任何容器动作之前拒绝。
"""
from pathlib import Path
from datetime import datetime,timezone
from unittest.mock import patch
import argparse,contextlib,hashlib,importlib.util,io,json,os,sys

def main():
    """测试显式candidate/project路径与仓外新receipt，保留真实源码和缓存为只读输入。"""
    parser=argparse.ArgumentParser(description=__doc__)
    for key in ('project','helper-root','source','cache','producer-manifest','output'):parser.add_argument('--'+key,type=Path,required=True)
    for key in ('expected-source','expected-image','producer-sha','producer-compose-sha','producer-log-sha'):parser.add_argument('--'+key,required=True)
    parser.add_argument('--copied-producer-manifest',type=Path,required=True,help='actual same-byte producer copy in a different directory; must be refused')
    args=parser.parse_args();out=args.output.resolve()
    if out.exists():raise ValueError('new receipt required')
    sys.path.insert(0,str(args.helper_root.resolve()/'scripts/lib'))
    spec=importlib.util.spec_from_file_location('candidate_project_under_test',args.project.resolve())
    project=importlib.util.module_from_spec(spec);spec.loader.exec_module(project)
    base=dict(action='test',state_dir=str(out.parent/'unused-plan-state'),image=None,qa_image=None,
              sysroot=None,component='smoke',suite='mobilegl-cpu-proof',jobs=2,fresh=False,
              plan_only=True,reuse_manifest=None,recipe_arg=[],test_arg=[],mobilegl_source=str(args.source.resolve()),
              mobilegl_expected_source=args.expected_source,mobilegl_host_cache=str(args.cache.resolve()),
              mobilegl_qa_image=args.expected_image,mobilegl_host_proof=None,mobilegl_host_proof_sha=None,
              mobilegl_producer_manifest=str(args.producer_manifest.resolve()),mobilegl_producer_sha=args.producer_sha,
              mobilegl_producer_compose_sha=args.producer_compose_sha,mobilegl_producer_log_sha=args.producer_log_sha)
    rows=[]
    # image解引用/服务忙态使用隔离替身；producer/source/cache/全部SHA仍实读。
    # 错readerimage必须与真实producer比对拒绝，不能mock成固定正确值掩盖缺口。
    with patch.object(project,'image_id',side_effect=lambda name:name),patch.object(project,'check_service'),patch.dict(os.environ,{'AMCL_WORKSPACE_ROOT':str(out.parent/'unused-output')}):
        for name,changes,expected in [('actual-clean-plan',{},True),('wrong-full-source',{'mobilegl_expected_source':'0'*40},False),
                                      ('missing-cache',{'mobilegl_host_cache':None},False),
                                      ('missing-producer',{'mobilegl_producer_manifest':None},False),
                                      ('wrong-producer-sha',{'mobilegl_producer_sha':'0'*64},False),
                                      ('wrong-producer-compose-sha',{'mobilegl_producer_compose_sha':'0'*64},False),
                                      ('wrong-producer-log-sha',{'mobilegl_producer_log_sha':'0'*64},False),
                                      ('copied-producer-directory',{'mobilegl_producer_manifest':str(args.copied_producer_manifest.resolve())},False),
                                      ('wrong-reader-image',{'mobilegl_qa_image':'sha256:'+'0'*64},False)]:
            log=io.StringIO()
            try:
                with contextlib.redirect_stdout(log):code=project.run(argparse.Namespace(**{**base,**changes}))
                accepted=code==0
            except ValueError as error:accepted=False;log.write(str(error))
            if accepted!=expected:raise ValueError('candidate QA precondition did not enforce '+name)
            rows.append({'name':name,'accepted':accepted,'expected':expected,'detail':log.getvalue()})
    if (out.parent/'unused-plan-state').exists() or (out.parent/'unused-output').exists():raise ValueError('plan-only unexpectedly created state/output')
    record={'finishedAt':datetime.now(timezone.utc).isoformat(),'candidateSha256':hashlib.sha256(args.project.read_bytes()).hexdigest(),
            'rows':rows,'scope':'actual native source/cache plan guards with Docker boundary substitutes only; no engine/build/CPU qualification'}
    out.parent.mkdir(parents=True,exist_ok=True)
    with out.open('x') as stream:stream.write(json.dumps(record,indent=2)+'\n')
    print(json.dumps({'controls':len(rows),'passed':True}));return 0

if __name__=='__main__':raise SystemExit(main())
