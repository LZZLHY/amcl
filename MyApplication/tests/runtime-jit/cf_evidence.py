"""CF夹具的共同只读验证器：检查实际图进展、JAR/PID和完整XML中的outer-CF nmethod。

stdout标签不是编译证明。full臂要求测量前已安装且测量完成前未退役的CF C2完成方法；
c2-only要求真实C1且全程无outer-CF C2；broad要求全程无outer-CF nmethod。
"""
from pathlib import Path
import hashlib
import json
import re
import xml.etree.ElementTree as ET
from cf_policy import POLICY, BROAD, RESTORE, C2_FILE

BASE = Path(__file__).resolve().parent
CF = 'java.util.concurrent.CompletableFuture '
COMPLETION = {'postComplete', 'complete', 'postFire', 'unipush', 'uniCompose', 'uniComposeStage'}


def inline_evidence(root):
    """从实际已发出nmethod的task提取CF内联，不把日志中未成功发码的尝试算通过。

    HotSpot的method/klass编号属于每个task；必须先在该task建表，再按同一父节点的
    call→inline_success/inline_fail关联。记录调用者编译根，明确区分CF自己的编译
    与外部调用者内联CF；后者正是旧full directive遗漏的边界。
    """
    emitted = {node.get('compile_id'): dict(node.attrib) for node in root.iter('nmethod')}
    successes, failures, parses = [], [], []
    for task in root.iter('task'):
        native = emitted.get(task.get('compile_id'))
        if native is None:
            continue
        classes = {node.get('id'): node.get('name','').replace('/','.') for node in task.iter('klass')}
        methods = {node.get('id'): dict(node.attrib) for node in task.iter('method')}
        caller = native.get('method', task.get('method','')).replace('/','.')
        external_caller = not caller.startswith(CF)
        base = dict(compile_id=task.get('compile_id'), compiler=native.get('compiler'),
                    level=native.get('level'), caller=caller, stamp=native.get('stamp'),
                    externalCaller=external_caller)
        for node in task.iter('parse'):
            method = methods.get(node.get('method'),{})
            if external_caller and classes.get(method.get('holder')) == CF.strip():
                parses.append(dict(base,callee=method.get('name')))
        for parent in task.iter():
            previous = None
            for node in parent:
                if node.tag == 'call':
                    previous = methods.get(node.get('method'))
                elif node.tag in ('inline_success','inline_fail'):
                    if external_caller and previous and classes.get(previous.get('holder')) == CF.strip():
                        item = dict(base,callee=previous.get('name'),reason=node.get('reason',''))
                        (successes if node.tag == 'inline_success' else failures).append(item)
                    previous = None
                elif node.tag not in ('klass','method','type','dependency','intrinsic'):
                    previous = None
    return dict(successes=successes,failures=failures,parses=parses)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def external(path):
    """只允许显式新仓外输出；检查祖先身份，不创建或删除调用者指定目录。"""
    path = Path(path)
    if not path.is_absolute(): raise ValueError('Output must be absolute')
    result = path.resolve()
    for parent in (result, *result.parents):
        if (parent/'.git').exists() or ((parent/'AGENTS.md').exists() and (parent/'build-profile.json5').exists()):
            raise ValueError('Output must be outside all repositories')
    return result


def fields(line):
    return dict(part.split('=', 1) for part in line.split()[1:] if '=' in part)


def verify(directory, arm, lanes, warmup, measured, stress):
    """调用方提供预期固定工作量；不信任单一passed字段或完整性不足的编译日志。"""
    directory = Path(directory)
    problems = []
    log = (directory/'cf-progress.log').read_text(encoding='utf-8')
    rows = log.splitlines()
    identities = [fields(line) for line in rows if line.startswith('CF_ID ')]
    passes = [fields(line) for line in rows if line.startswith('CF_PASS ')]
    begins = [fields(line) for line in rows if line.startswith('CF_PHASE ')]
    ends = [fields(line) for line in rows if line.startswith('CF_PHASE_DONE ')]
    if len(identities) != 1 or identities[0].get('arm') != arm:
        problems.append('identity/arm mismatch')
    legacy = len(identities) == 1 and identities[0].get('version','').startswith('1.8.')
    if len(passes) != 1 or passes[0].get('arm') != arm:
        problems.append('missing unique terminal')
    if [row.get('name') for row in begins] != ['warmup','measure','stress'] or [row.get('name') for row in ends] != ['warmup','measure','stress']:
        problems.append('phase sequence incomplete')
    expected_counts = dict(warmup=warmup, measure=measured, stress=stress)
    for begin, end in zip(begins, ends):
        name = begin['name']; count = expected_counts[name]
        seeds = sum(count*(lane << 20) + count*(count-1)//2 for lane in range(lanes))
        expected_sum = seeds if name == 'stress' else 4*seeds + lanes*count
        if int(begin['expected']) != lanes*count or int(end['completed']) != lanes*count or int(end['checksum']) != expected_sum:
            problems.append('phase work/checksum mismatch:'+name)
        if int(end['wallNanos']) <= 0 or int(end['cpuNanos']) <= 0:
            problems.append('phase timing unavailable:'+name)
        progress = [fields(line) for line in rows if line.startswith('CF_PROGRESS phase='+name+' ')]
        last = [0]*lanes
        for point in progress:
            current = [int(value) for value in point['lanes'].strip(',').split(',')]
            if len(current) != lanes or any(not old <= new <= count for old,new in zip(last,current)) or sum(current) != int(point['completed']):
                problems.append('non-monotone driver progress:'+name)
            last = current
    if len(ends) == 3 and int(ends[2]['gc']) <= 0: problems.append('stress observed no completed GC')
    props = dict(line.split('=',1) for line in (directory/'cf-result.properties').read_text().splitlines())
    if props.get('passed') != 'true' or props.get('arm') != arm or int(props.get('operations','-1')) != lanes*measured:
        problems.append('result mismatch')
    if len(ends) == 3:
        for key in ('checksum','wallNanos','cpuNanos'):
            if props.get(key) != ends[1].get(key): problems.append('result/progress mismatch:'+key)
        if props.get('stressOperations') != ends[2].get('completed') or props.get('stressGc') != ends[2].get('gc'):
            problems.append('result/stress mismatch')
    artifact = directory/'cf-qualification.jar'
    if len(identities) == 1 and identities[0].get('jarSha256') != sha(artifact):
        problems.append('executed artifact mismatch')
    root = ET.parse(directory/'compilation.xml').getroot()  # 截断XML直接失败，不能拼接修复。
    if len(identities) == 1 and root.attrib.get('process') != identities[0]['vm'].split('@')[0]:
        problems.append('compiler log belongs to another PID')
    # Java8保留原策略，但不能仅修改CF_ID的版本文案就绕过现代Oracle/inline门。
    # HotSpot日志中的VM规范版本来自实际VM；8的HotSpot release是25.x，不能按它猜major。
    vm_spec = re.search(r'^java\.vm\.specification\.version=([^\r\n]+)',
                        root.findtext('vm_arguments/properties',''),re.M)
    if vm_spec:
        actual_legacy = vm_spec[1].strip() == '1.8'
        if actual_legacy != legacy:
            problems.append('VM specification/identity version mismatch')
        legacy = actual_legacy
    outer = [dict(node.attrib) for node in root.iter('nmethod')
             if node.attrib.get('method','').replace('/','.').startswith(CF)]
    c2 = [node for node in outer if node.get('compiler') == 'c2' or node.get('level') == '4']
    c1 = [node for node in outer if node.get('compiler') == 'c1' and node.get('level') in ('1','2','3')]
    inlining = inline_evidence(root)
    c2_inline_parses = [item for item in inlining['parses'] if item['compiler'] == 'c2']
    # C2已发布但测量前失效不算覆盖；同时保留所有compile_id/address以供复现失败机器码。
    retirements = [dict(node.attrib) for node in root.iter('make_not_entrant')]
    begin_ms = int(begins[1]['uptimeMillis']) if len(begins) == 3 else -1
    end_ms = int(ends[1]['uptimeMillis']) if len(ends) == 3 else -1
    def spans(node):
        return float(node.get('stamp','inf'))*1000 <= begin_ms and not any(
            other.get('compile_id') == node.get('compile_id') and float(other.get('stamp','inf'))*1000 <= end_ms
            for other in retirements)
    active = [node for node in (c2 if arm == 'full' else c1) if spans(node)]
    active_completion = [node for node in active if node['method'].split()[1] in COMPLETION]
    # 本次现代内联更正不把未经本轮8宿主验证的额外门偷偷加到经典布局。
    if arm == 'broad' and (outer or c2_inline_parses or
            (not legacy and (inlining['parses'] or inlining['successes']))):
        problems.append('broad unexpectedly compiled outer CF')
    if arm == 'full' and (len({node['method'].split()[1] for node in active}) < 3 or not active_completion):
        problems.append('no active CF C2 completion coverage across measurement')
    if arm == 'c2-only' and (c2 or c2_inline_parses or
            any(item['compiler'] == 'c2' for item in inlining['successes']) or not active_completion):
        problems.append('C2-only lacks active CF C1 or contains CF C2')
    if int(props.get('wallNanos','0')) < 50000000 or int(props.get('cpuNanos','0')) < 50000000:
        problems.append('measurement too short for a useful CPU comparison')
    arguments = [line[len('CF_ARG '):] for line in rows if line.startswith('CF_ARG ')]
    if any(value == '-Xint' or value.startswith('-XX:TieredStopAtLevel=') for value in arguments):
        problems.append('global compiler restriction')
    active_inline = [item for item in inlining['successes'] if spans(item)]
    policy_rejections = [item for item in inlining['failures'] if item['reason'] == 'disallowed by CompileCommand']
    if not legacy:
        # 现代v2必须在真正VM参数/解析输出中撤销精确legacy条目，而不是只在标签里称full。
        # 原8策略不支持typed false，仍沿用上面既有编译/计数门，不假装提供C2-only。
        controls = [value for value in arguments if value.startswith('-XX:CompileCommand=')]
        expected = [BROAD] if arm == 'broad' else [BROAD,RESTORE]
        if controls != expected:
            problems.append('modern compiler policy requires exact ordered Oracle override')
        xml_controls = re.findall(r'-XX:CompileCommand=[^\s]+',root.findtext('vm_arguments/args',''))
        if xml_controls != controls:
            problems.append('compiler XML/input-arguments control mismatch')
        if any(value.startswith(('-XX:CompileOnly=','-XX:CompileCommandFile=')) for value in arguments):
            problems.append('fixed policy forbids additional compiler control files')
        stdout = (directory/'stdout.log').read_text(encoding='utf-8')
        registered = re.findall(r'CompileCommand: exclude java/util/concurrent/CompletableFuture\.\* bool exclude = (true|false)',stdout)
        if registered != (['true'] if arm == 'broad' else ['true','false']):
            problems.append('effective Oracle override not acknowledged')
        directive_args = [value for value in arguments if value.startswith('-XX:CompilerDirectivesFile=')]
        if arm in ('broad','full') and directive_args:
            problems.append('broad/full must not load legacy matching-only directives')
        if arm == 'c2-only':
            if len(directive_args) != 1 or not (directory/'directives.json').is_file():
                problems.append('C2-only fixed v2 directive absent')
            elif (directory/'directives.json').read_text(encoding='utf-8') != (BASE/C2_FILE).read_text(encoding='utf-8'):
                problems.append('C2-only fixed v2 directive bytes differ')
            # stack按文件顺序打印；C1两条都禁用，继续默认启发式。C2先精确Exclude再禁CF内联。
            blocks = re.findall(r'Directive:\s*matching: ([^\n]+)\s+c1 directives:(.*?)c2 directives:(.*?)(?=Directive:|CF_ID|$)',stdout,re.S)
            if (len(blocks) != 2 or blocks[0][0].strip() != 'java/util/concurrent/CompletableFuture.*'
                    or blocks[1][0].strip() != '*.*' or any('Enable:false' not in block[1] for block in blocks)
                    or 'Exclude:true' not in blocks[0][2]
                    or 'inline: -java/util/concurrent/CompletableFuture.*' not in blocks[1][2]):
                problems.append('effective C2-only v2 directive not acknowledged')
        if arm == 'full':
            if policy_rejections:
                problems.append('full still blocks external CF inlining by CompileCommand')
            if not any(item['compiler'] == 'c2' for item in active_inline):
                problems.append('full lacks active external CF C2 inline coverage')
        if arm == 'c2-only':
            if any(item['compiler'] == 'c1' for item in policy_rejections):
                problems.append('C2-only still blocks external CF C1 inlining')
            # 非CF调用者允许正常晋升C2，因而其C1 nmethod可在预热中正常退役。
            # 这里要求真实发码的C1曾内联CF，不为维持C1存活而限制其它代码优化。
            if not any(item['compiler'] == 'c1' for item in inlining['successes']):
                problems.append('C2-only lacks actual external CF C1 inline coverage')
    return dict(passed=not problems, problems=problems, identity=identities,compilerPolicy=POLICY,
        work=dict(lanes=lanes,warmup=warmup,measured=measured,stress=stress), result=props,
        arguments=arguments, outerNmethods=outer, c2Nmethods=c2, c1Nmethods=c1,
        activeCompletionNmethods=active_completion, c2InlineParses=c2_inline_parses, retirements=retirements,
        externalCfInlining=inlining,activeExternalCfInlining=active_inline,
        jarSha256=sha(artifact), compilationSha256=sha(directory/'compilation.xml'),
        progressSha256=sha(directory/'cf-progress.log'), scope='fixture evidence; not Forge or target deployment proof')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--report', required=True, type=Path)
    parser.add_argument('--arm', required=True, choices=['broad','c2-only','full'])
    parser.add_argument('--lanes', type=int, default=4)
    parser.add_argument('--warmup', type=int, default=50000)
    parser.add_argument('--measured', type=int, default=1000000)
    parser.add_argument('--stress', type=int, default=1200)
    args = parser.parse_args()
    result = verify(args.evidence,args.arm,args.lanes,args.warmup,args.measured,args.stress)
    with external(args.report).open('x',encoding='utf-8') as target:
        json.dump(result,target,indent=2,ensure_ascii=False)
    print(json.dumps(dict(passed=result['passed'],problems=result['problems'])))
    raise SystemExit(0 if result['passed'] else 1)
