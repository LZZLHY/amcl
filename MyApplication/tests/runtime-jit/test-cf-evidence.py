"""用真实已通过的CF运行材料验证拒绝边界；派生反例单独落盘，不覆盖原始证据。

没有C2、仅在测量后编译、测量前退役、错PID/工作量/JAR和截断日志均不能取得资格。
"""
from pathlib import Path
import argparse
import copy
import json
import shutil
import sys
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
from cf_evidence import CF, external, fields, sha, verify
from cf_policy import POLICY, RESTORE

parser = argparse.ArgumentParser()
parser.add_argument('--full',type=Path,required=True)
parser.add_argument('--broad',type=Path,required=True)
parser.add_argument('--c2-only',type=Path,required=True)
parser.add_argument('--legacy-full',type=Path,required=True,
                    help='旧matching-only full真实完整材料；只读复制，不能重写旧证据')
parser.add_argument('--legacy-c2-only',type=Path,required=True,
                    help='旧matching-only C2-only真实完整材料；用于C1内联残留反例')
parser.add_argument('--output',type=Path,required=True)
args = parser.parse_args()
output = external(args.output); output.mkdir(parents=True,exist_ok=False)
work = (4,50000,1000000,1200)
assert verify(args.full,'full',*work)['passed']
assert verify(args.broad,'broad',*work)['passed']
assert verify(args.c2_only,'c2-only',*work)['passed']
results = []


def changed_text(path, function):
    path.write_text(function(path.read_text(encoding='utf-8')),encoding='utf-8')


def derive(name, source, mutate, reason, parse_failure=False, arm='full'):
    """每次完整复制只读输入；反例必须命中特定拒绝理由，意外异常不算通过。"""
    directory = output/name; directory.mkdir()
    for filename in ('cf-progress.log','cf-result.properties','cf-qualification.jar','compilation.xml','stdout.log'):
        shutil.copyfile(source/filename,directory/filename)
    if (source/'directives.json').is_file():
        shutil.copyfile(source/'directives.json',directory/'directives.json')
    mutate(directory)
    try:
        result = verify(directory,arm,*work)
        assert not parse_failure and not result['passed'] and any(reason in item for item in result['problems']),result
    except ET.ParseError as error:
        assert parse_failure
        result = dict(passed=False,problems=['expected XML ParseError:'+str(error)])
    results.append(dict(name=name,source=str(source),sourceCompilationSha256=sha(source/'compilation.xml'),
                        expectedReason=reason,verification=result))
    print('PASS rejection',name,flush=True)


def xml_change(directory, change):
    path = directory/'compilation.xml'; tree = ET.parse(path); change(tree.getroot())
    tree.write(path,encoding='utf-8',xml_declaration=True)


def no_cf_c2(directory):
    # 保留夹具和所有其它库的C2，验证“只有无关hotLoop/C2”不能冒充CF本身C2。
    def alter(root):
        for parent in root.iter():
            for node in list(parent):
                if node.tag == 'nmethod' and node.get('compiler') == 'c2' and node.get('method','').startswith(CF):
                    parent.remove(node)
    xml_change(directory,alter)


def retired(directory):
    def alter(root):
        for node in list(root.iter('nmethod')):
            if node.get('compiler') == 'c2' and node.get('method','').startswith(CF):
                ET.SubElement(root,'make_not_entrant',dict(compile_id=node.get('compile_id'),stamp='0.001'))
    xml_change(directory,alter)


def remove_external_inline(directory, compiler):
    """保留CF独立nmethod和其它内联，只移除指定tier外部CF成功记录以测新覆盖门。"""
    def alter(root):
        emitted = {node.get('compile_id'):node.attrib for node in root.iter('nmethod')}
        changed = 0
        for task in root.iter('task'):
            native = emitted.get(task.get('compile_id'),{})
            if native.get('compiler') != compiler or native.get('method','').replace('/','.').startswith(CF):
                continue
            classes = {node.get('id'):node.get('name','').replace('/','.') for node in task.iter('klass')}
            methods = {node.get('id'):node.attrib for node in task.iter('method')}
            for parent in task.iter():
                previous = None
                for node in list(parent):
                    if node.tag == 'call': previous = methods.get(node.get('method'))
                    elif node.tag in ('inline_success','inline_fail'):
                        if node.tag == 'inline_success' and previous and classes.get(previous.get('holder')) == CF.strip():
                            parent.remove(node); changed += 1
                        previous = None
                    elif node.tag not in ('klass','method','type','dependency','intrinsic'): previous = None
        assert changed > 0,'negative control did not change its intended evidence'
    xml_change(directory,alter)


def inject_real_external_c2(directory):
    """把真实full的一组已发码C2 task/nmethod复制入反例，证明只看CF独立方法不够。

    task内编号表原样保留，仅改全局compile_id避免碰撞；输入原件不变，派生材料
    明确是故障注入，不能用于任何正向编译或性能资格。
    """
    source = ET.parse(args.full/'compilation.xml').getroot()
    observed = verify(args.full,'full',*work)['externalCfInlining']['parses']
    selected = next(item['compile_id'] for item in observed if item['compiler'] == 'c2')
    task = copy.deepcopy(next(node for node in source.iter('task') if node.get('compile_id') == selected))
    native = copy.deepcopy(next(node for node in source.iter('nmethod') if node.get('compile_id') == selected))
    task.set('compile_id','987654321'); native.set('compile_id','987654321')
    xml_change(directory,lambda root:(root.append(native),root.append(task)))


derive('no-cf-c2',args.full,no_cf_c2,'no active CF C2')
derive('late-cf-c2',args.full,lambda directory: xml_change(directory,lambda root:
    [node.set('stamp','999.0') for node in root.iter('nmethod') if node.get('compiler') == 'c2' and node.get('method','').startswith(CF)]),'no active CF C2')
derive('retired-cf-c2',args.full,retired,'no active CF C2')
derive('wrong-pid',args.full,lambda directory: xml_change(directory,lambda root: root.set('process','0')),'another PID')
derive('wrong-count',args.full,lambda directory: changed_text(directory/'cf-progress.log',lambda text:
    text.replace('CF_PHASE_DONE name=measure completed=4000000','CF_PHASE_DONE name=measure completed=3999999')),'phase work/checksum')
derive('wrong-jar',args.full,lambda directory: (directory/'cf-qualification.jar').write_bytes(b'wrong-jar'),'artifact mismatch')
derive('wrong-result',args.full,lambda directory: changed_text(directory/'cf-result.properties',lambda text:
    text.replace('checksum=','checksum=9',1)),'result/progress mismatch')
derive('truncated-xml',args.full,lambda directory: changed_text(directory/'compilation.xml',lambda text: text[:-40]),'XML ParseError',True)
derive('broad-mislabeled-full',args.broad,lambda directory: [changed_text(directory/name,lambda text:
    text.replace('arm=broad','arm=full')) for name in ('cf-progress.log','cf-result.properties')],'no active CF C2')

# 两个真实旧运行不是模拟输出：它们曾满足v1，但仍有已证实的外部CF inline残留。
derive('legacy-full-actual',args.legacy_full,lambda directory:None,
       'full still blocks external CF inlining by CompileCommand')
derive('legacy-c2-only-actual',args.legacy_c2_only,lambda directory:None,
       'C2-only still blocks external CF C1 inlining',arm='c2-only')
derive('missing-oracle-override',args.full,lambda directory:changed_text(directory/'cf-progress.log',
       lambda text:text.replace('CF_ARG '+RESTORE+'\n','')),
       'requires exact ordered Oracle override')
derive('spoof-legacy-version',args.full,lambda directory:changed_text(directory/'cf-progress.log',
       lambda text:__import__('re').sub(r'(CF_ID [^\n]* version=)[^ ]+',r'\g<1>1.8.0_452-b09',text)),
       'VM specification/identity version mismatch')
derive('full-no-external-c2-inline',args.full,lambda directory:remove_external_inline(directory,'c2'),
       'full lacks active external CF C2 inline coverage')
derive('c2-no-external-c1-inline',args.c2_only,lambda directory:remove_external_inline(directory,'c1'),
       'C2-only lacks actual external CF C1 inline coverage',arm='c2-only')
derive('c2-with-real-external-c2-inline',args.c2_only,inject_real_external_c2,
       'C2-only lacks active CF C1 or contains CF C2',arm='c2-only')
derive('c2-wrong-directive',args.c2_only,lambda directory:(directory/'directives.json').write_text('[]\n',encoding='utf-8'),
       'C2-only fixed v2 directive bytes differ',arm='c2-only')
(output/'receipt.json').write_text(json.dumps(dict(schemaVersion=2,compilerPolicy=POLICY,passed=True,
    verifierSha256=sha(Path(__file__).resolve().parent/'cf_evidence.py'),cases=results),indent=2),encoding='utf-8')
