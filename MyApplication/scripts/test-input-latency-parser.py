"""正式离线parser纯规则回归：复用R4旧断言，不运行collector、编译器、SDK或HDC。

全部新日志明确标rule_fixture；原件/Source SHA、捕获寿命、场景/终点是测试输入，
不是伪造真实设备测量。输出统一仓外，规则通过不能作为输入时延或CPU性能PASS。
"""
from pathlib import Path
import argparse,copy,hashlib,importlib.util,itertools,json,subprocess,sys
# 正常Source门依赖下文独立assert判据。优化模式会移除它们，必须在任何输出或CLI子进程前拒绝。
if sys.flags.optimize:
    raise RuntimeError('ILAT规则测试必须在Python optimize=0下执行')
sys.dont_write_bytecode=True
from lib.workspace_paths import external_output_path,workspace_path
SCRIPT=Path(__file__).resolve().with_name('parse-input-latency.py')
spec=importlib.util.spec_from_file_location('input_latency_parser',SCRIPT)
parser=importlib.util.module_from_spec(spec);spec.loader.exec_module(parser)
ONE='id=1 ses=1 stream=1 pfx=1 po=1 seq=1 ro=2 c=1 a=1 tgt=42 ticket=1 ns=10/20/30/40/50/60 mask=63 outcome=1 srcs=1 clockfail=0 sample_range=unknown sdk_clock=unknown'
PULL='b=3 e=1 '+ONE.replace('outcome=1','outcome=9')
# 固定样本以实际原字节SHA绑定；测试生成内容只属于rule_fixture，不能借mtime当证据。
def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
# JSON样本与收据统一UTF-8/LF，均位于本次新建外部目录；不覆写产品或历史输入。
def save(path,value):path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
def main():
    """独立运行原parser的真实CLI/函数；人工变体只击中承重规则，结果全部保留在显式新目录。"""
    options=argparse.ArgumentParser(description=__doc__);options.add_argument('--out',type=Path)
    args=options.parse_args();out=external_output_path(args.out) if args.out else workspace_path('run','ilat-parser-test')
    out.mkdir(parents=True,exist_ok=False)
    receipt=out/'source.rule_fixture.json';save(receipt,{'classification':'rule_fixture','identity':'parser-test-input-only'})
    bound={'path':str(receipt),'sha256':sha(receipt)};checks=[]
    # 显式构造规则样本的捕获寿命和场景；pid空值与无HAP不能升级为真实设备资格。
    def context(name='rule-capture',scene='rule-scene'):
        return {'capture_id':name,'layer':'rule_fixture','pid':None,'source':{'identity':'rule_fixture','receipt':bound},
          'hap':None,'scene':scene,'clock_domain':'HOST_STEADY_NS','sampling_interval':1,'prefix_format':'host_stdout'}
    # 每份日志先保存再实取SHA；调用者传入的上下文决定解析分组，不由文件名推断业务。
    def evidence(name,body,ctx=None):
        path=out/(name+'.rule_fixture.log');path.write_text(body,encoding='utf-8',newline='\n')
        return {'path':str(path),'sha256':sha(path),'binding':ctx or context()}
    # 直接运行正式解析器，强制所有结果保持规则fixture及PARTIAL，不用通过数量授性能结论。
    def execute(name,items):
        manifest=out/(name+'.json');save(manifest,{'schema':'amcl-native-ilat-manifest/v1','classification':'rule_fixture','evidence':items})
        result=parser.run(manifest,out/name)
        assert all(g['layer']=='rule_fixture' for g in result['groups'])
        assert result['status']=='PARTIAL_NATIVE_OBSERVATIONS' and 'game_tick_not_measured' in result['partial_reasons']
        checks.append(name);return result,manifest
    assert parser.quantiles([30,10,20,50,40])=={'n':5,'p50_ns':'30','p95_ns':'50','p99_ns':'50'}
    assert parser.quantiles([])=={'n':0,'p50_ns':None,'p95_ns':None,'p99_ns':None};checks.append('nearest-rank-integer-empty-unknown')
    # ILAT1沿原callback RETURN；两pull ABI各自分组，不能混用callback或SDL内部时间名称。
    l2=PULL.replace('b=3 e=1','b=2 e=2').replace('outcome=9','outcome=10').replace('id=1','id=4',1).replace('pfx=1','pfx=4').replace('seq=1','seq=4').replace('ticket=1','ticket=4')
    result,_=execute('distinct-protocol-backends',[evidence('protocols','ILAT1 '+ONE+'\nILAT2 '+PULL.replace('id=1','id=2',1).replace('pfx=1','pfx=2').replace('seq=1','seq=2').replace('ticket=1','ticket=2')+'\nILAT2 '+l2+'\n')])
    assert result['unique_records']==3 and len(result['groups'])==3
    for group in result['groups']:
        if group.get('protocol')=='ILAT2':assert not any('callback' in k or k=='entry_to_return' for k in group['metrics'])
    # 缺终点时钟与成功终态可并存；保持unknown/null，不补0或从game ACK推时间。
    missing=PULL.replace('50/60','50/-').replace('mask=63','mask=31')
    result,_=execute('missing-terminal-clock',[evidence('missing','ILAT2 '+missing+'\n')])
    assert result['groups'][0]['metrics']['entry_to_sdl_queue_add_receipt_return']['n']==0
    assert result['groups'][0]['metrics']['entry_to_sdl_queue_add_receipt_return']['p95_ns'] is None
    for name,value,issue in [('backend',PULL.replace('b=3','b=2',1),'backend_terminal_conflict'),
      ('endpoint',PULL.replace('e=1','e=0',1),'endpoint_terminal_conflict'),
      ('no-success-with-clock',PULL.replace('e=1','e=0',1).replace('outcome=9','outcome=11'),'terminal_return_conflict'),
      ('mask',PULL.replace('mask=63','mask=31'),'mask_ns_conflict'),
      ('origin',PULL.replace('sdk_clock=unknown','sdk_clock=known'),'unsupported_origin_contract')]:
        assert issue in parser.record_v2(value)[1];checks.append('reject-'+name)
    # uint64和原formatter预算按原R4处理，整数永不经float；JSON身份/时点保持字符串。
    extreme=PULL
    import re
    for key in ['id','ses','stream','pfx','po','seq','ro','c','a','tgt','ticket']:
        extreme=re.sub(r'(?<!\S)'+key+r'=\d+',key+'='+str(parser.U64-(1 if key=='po' else 0)),extreme)
    extreme=extreme.replace('10/20/30/40/50/60','/'.join([str(parser.U64)]*6))
    assert not parser.record_v2(extreme)[1]
    _,mf=execute('u64-exact',[evidence('uint64','ILAT2 '+extreme+'\n')])
    row=json.loads((out/'u64-exact/records.jsonl').read_text())['row'];assert row['id']==str(parser.U64) and row['ns'][0]==str(parser.U64)
    for value in [PULL.replace('id=1','id=18446744073709551616',1),PULL+' id=1',PULL.replace('ns=10','ns=0x10')]:
        try:parser.record_v2(value);raise AssertionError('畸形/越界整数被接受')
        except ValueError:pass
    assert 'record_budget_conflict' in parser.record_v2(PULL+' '*512)[1];checks.append('u64-overflow-fields-budget')
    # 同capture的互斥variant保完整tuple闭包，六种原行顺序均隔离，不择好记录提高n。
    two=ONE.replace('pfx=1','pfx=2').replace('po=1','po=3').replace('seq=1','seq=2').replace('ro=2','ro=4').replace('ticket=1','ticket=2')
    three=two.replace('id=1','id=2',1)
    for index,order in enumerate(itertools.permutations([ONE,two,three])):
        r,_=execute('closure-'+str(index),[evidence('closure-'+str(index),''.join('ILAT1 '+v+'\n' for v in order))]);assert r['unique_records']==0
    first=evidence('duplicate','ILAT1 '+ONE+'\n');r,_=execute('deduplicate-original',[first,copy.deepcopy(first)]);assert r['unique_records']==1 and r['duplicate_count']==1
    # SUM原行不能按相同正文消重；换scene后的同原件隔离，不得推drop/累计回退或实际SUM存在。
    summary='n=1 bytes=200 exportfail=1 sampled=100 skipped=800 full=3 busy=2 unbound=1 clockfail=2 count_uncertain=1 record_bytes=152 capacity=512'
    item=evidence('sum','ILAT1_SUM '+summary+'\n');other=copy.deepcopy(item);other['binding']['scene']='rule-other-scene'
    r,_=execute('sum-quarantine',[item,other]);assert r['summaries'][0]['excluded_from_diagnostic_inferences'] and not any(k.startswith('summary_') for k in r['issue_counts'])
    assert 'no_actual_ILAT1_SUM' in r['partial_reasons']
    r,_=execute('sum-two-lines',[evidence('sum-two','ILAT1_SUM '+summary+'\nILAT1_SUM '+summary+'\n')]);assert len(r['summaries'])==2
    # 日志只用二进制LF数原行，Unicode分隔符不改变line_start；hilog PID必须整个字段匹配。
    carrier='10-11 12:00:00.000 45 46 I A00000/com.rule.fixture/NAPI_INPUT: '
    ctx=context();ctx.update(pid=45,prefix_format='hilog')
    r,_=execute('hilog-pid',[evidence('pid',carrier+'ILAT2 '+PULL+'\n',ctx)]);assert r['unique_records']==1
    r,_=execute('pid-substring',[evidence('wrong-pid',carrier.replace(' 45 46 ',' 450 46 ')+'ILAT2 '+PULL+'\n',ctx)]);assert r['unique_records']==0 and 'pid_binding_mismatch' in r['issue_counts']
    item=evidence('binary-lf','rule\x1eextra unicode separator\nILAT1 '+ONE+'\n');item['line_start']=2
    r,_=execute('binary-lf',[item]);assert r['unique_records']==1
    # 新外部目录CLI可成功；坏SHA退出2留下错误类型，既有目录及仓内路径不能覆盖/创建。
    item=evidence('cli','ILAT1 '+ONE+'\n');manifest=out/'cli.json';save(manifest,{'schema':'amcl-native-ilat-manifest/v1','evidence':[item]})
    commands=[]
    # 用真实Python CLI检查路径/绑定失败与退出码，并保留stdout/stderr；这些子进程不接设备。
    def cli(manifest,destination,expected):
        argv=[sys.executable,'-B',str(SCRIPT),'--manifest',str(manifest),'--out',str(destination)];p=subprocess.run(argv,capture_output=True)
        assert p.returncode==expected;(out/('cli-'+str(len(commands))+'.log')).write_bytes(p.stdout+p.stderr);commands.append({'argv':argv,'exitCode':p.returncode})
    cli(manifest,out/'cli-success',0);before=(out/'cli-success/report.json').read_bytes();cli(manifest,out/'cli-success',2);assert (out/'cli-success/report.json').read_bytes()==before
    bad=copy.deepcopy(item);bad['sha256']='0'*64;broken=out/'bad.json';save(broken,{'schema':'amcl-native-ilat-manifest/v1','evidence':[bad]})
    cli(broken,out/'bad-sha',2);assert json.loads((out/'bad-sha/report.json').read_text())['status']=='BINDING_ERROR'
    forbidden=SCRIPT.parent/'ilat-test-output-forbidden';assert not forbidden.exists();cli(manifest,forbidden,2);assert not forbidden.exists();checks.append('CLI-binding-and-new-external-output')
    save(out/'receipt.json',{'checks':checks,'checkCount':len(checks),'commands':commands,'classification':'rule_fixture_only',
      'parserSha256':sha(SCRIPT),'actualDeviceRows':0,'SDK':0,'Compiler':0,'HDC':0,'performancePass':False})
    print(json.dumps({'passed':True,'checkCount':len(checks),'classification':'rule_fixture_only','out':str(out)}))
if __name__=='__main__':main()
