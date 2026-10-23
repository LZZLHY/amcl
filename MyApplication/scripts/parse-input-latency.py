"""正式离线工具：严格解析ILAT1与具名pull终点ILAT2，不混backend跨度。

保留R3原tuple冲突闭包、SUM资格隔离、原ILAT1规则及指标；新增SDL posted
receipt-return与L2 poll-view-copy，真实成功终态可以缺终点时钟，不能填0或猜钟。
复用已经独审的R4算法。调用者显式给manifest和全新仓外out；不启动SDK/Native/设备。

调用者显式绑定capture/PID/Source/HAP/scene和原件SHA；不读mtime、不选“当前活动”。
已有缺失/冲突保留为partial，不填0、不乘采样率，不设置性能PASS门槛。
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import sys
from collections import Counter,defaultdict

from lib.workspace_paths import external_output_path

PROJECT_ROOT=Path(__file__).resolve().parents[1]
U64=(1<<64)-1;U32=(1<<32)-1
STAGES=['ENTRY','ACCEPT','ENQUEUE','READ','CACHE','RETURN']
OUTCOMES={1:'CALLBACK',2:'CACHE_ONLY',3:'RETIRED',4:'REJECTED',5:'INCOMPLETE',6:'CALLBACK_RETIRED',8:'SKIPPED'}
PULL_OUTCOMES={9:'SDL_QUEUE_ADD_RECEIPT_RETURN',10:'L2_POLL_VIEW_COPIED',
  11:'SDL_CACHE_ONLY',12:'L2_CACHE_UNOBSERVED',13:'SDL_RETIRED',14:'L2_RETIRED',
  15:'SDL_INCOMPLETE',16:'L2_INCOMPLETE',17:'SDL_REJECTED',18:'L2_REJECTED'}
RECORD_KEYS=['id','ses','stream','pfx','po','seq','ro','c','a','tgt','ticket','ns','mask','outcome','srcs','clockfail','sample_range','sdk_clock']
PULL_RECORD_KEYS=['b','e',*RECORD_KEYS]
SUMMARY_KEYS=['n','bytes','exportfail','sampled','skipped','full','busy','unbound','clockfail','count_uncertain','record_bytes','capacity']
IDS=['ses','pfx','po','seq','ro','c','a','tgt','ticket']
PAIR_SPECS=[('entry_to_accept',0,1),('accept_to_enqueue',1,2),('queue_dwell',2,3),('read_to_cache',3,4),
 ('cache_to_return_including_state_complete',4,5),('entry_to_enqueue',0,2),('entry_to_read',0,3),('entry_to_cache',0,4),('entry_to_return',0,5)]
HILOG=re.compile(r'^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+\s+(\d+)\s+(\d+)\s+[A-Z]\s+\S+/NAPI_INPUT:\s+$')


def observation_model(row):
    """协议/ABI/终点是三个独立分组维度。SDL第六点只授原adapter取得posted
    回执后的Native观察，L2只授原坐标view复制，均不借callback RETURN名字。"""
    if row.get('protocol')!='ILAT2':
        # 旧wire没有backend编码。RETURN合同沿原GLFW Source解释，但parser不单凭
        # marker授调用者所选ABI；旧组输出完全保持，实际Source关联仍由原绑定负责。
        return 'ILAT1','LEGACY_ABI_NOT_ENCODED','CALLBACK_RETURN' if row['outcome'] in [1,6] else 'NO_CALLBACK_ENDPOINT',PAIR_SPECS
    backend='SDL3' if row['b']==3 else 'LWJGL2'
    terminal='SDL_QUEUE_ADD_RECEIPT_RETURN' if row['e']==1 else 'L2_POLL_VIEW_COPY' if row['e']==2 else 'NO_SUCCESS_ENDPOINT'
    suffix='sdl_queue_add_receipt_return' if row['b']==3 else 'l2_poll_view_copy'
    pairs=[('entry_to_accept',0,1),('accept_to_neutral_enqueue',1,2),('neutral_transport_wait',2,3),
      ('neutral_read_to_cache',3,4),('cache_to_'+suffix,4,5),('entry_to_neutral_enqueue',0,2),
      ('entry_to_neutral_read',0,3),('entry_to_cache',0,4),('entry_to_'+suffix,0,5)]
    return 'ILAT2',backend,terminal,pairs


def sha(path):
    """流式读取实际原字节摘要，不以转码/LF或文件mtime替代原件身份。"""
    value=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):value.update(block)
    return value.hexdigest()


def original_file(item,base):
    """要求调用者声明原件SHA并精确读回；不存在/摘要不符为绑定错误，不能猜替代路径。"""
    path=Path(item['path']);path=(base/path).resolve() if not path.is_absolute() else path.resolve()
    digest=item.get('sha256','')
    if not re.fullmatch('[0-9a-f]{64}',digest) or not path.is_file() or sha(path)!=digest:raise ValueError('original file SHA mismatch: '+str(path))
    return path,digest


def uint(text,bits=64,missing=False,positive=False):
    """formatter整数必须规范十进制；缺身份/时点用-，不把0或float当未知。"""
    if missing and text=='-':return None
    if not re.fullmatch('0|[1-9][0-9]*',text):raise ValueError('invalid canonical unsigned integer')
    value=int(text)
    if value>((1<<bits)-1) or (positive and value==0):raise ValueError('unsigned range/zero identity error')
    return value


def tokens(payload,keys):
    """字段集合/顺序与现役formatter一致；重复、缺字段、额外字段、截断均不静默接纳。"""
    result={};seen=[]
    for token in payload.split():
        if token.count('=')!=1:raise ValueError('invalid field token')
        key,value=token.split('=');seen.append(key)
        if key in result:raise ValueError('duplicate field')
        result[key]=value
    if seen!=keys:raise ValueError('field set/order mismatch')
    return result


def record(payload,protocol=1):
    """验证六时点、原身份和终态。缺段可观察且不补造；互相矛盾才禁止入统计。"""
    raw=tokens(payload,PULL_RECORD_KEYS if protocol==2 else RECORD_KEYS)
    if raw['sample_range']!='unknown' or raw['sdk_clock']!='unknown':return None,['unsupported_origin_contract']
    out={key:uint(raw[key],missing=True,positive=True) for key in IDS}
    out.update(id=uint(raw['id'],positive=True),stream=uint(raw['stream']),mask=uint(raw['mask'],32),
               outcome=uint(raw['outcome'],32),srcs=uint(raw['srcs'],32),clockfail=uint(raw['clockfail'],32),
               sample_range=raw['sample_range'],sdk_clock=raw['sdk_clock'])
    values=raw['ns'].split('/')
    if len(values)!=6:raise ValueError('ns must contain six native points')
    out['ns']=[uint(value,missing=True,positive=True) for value in values]
    issues=[]
    outcomes=PULL_OUTCOMES if protocol==2 else OUTCOMES
    if protocol==2:
        out.update(protocol='ILAT2',b=uint(raw['b'],32),e=uint(raw['e'],32))
        expected_backend=3 if out['outcome']%2 else 2
        if out['b'] not in [2,3] or out['b']!=expected_backend:issues.append('backend_terminal_conflict')
        expected_endpoint=1 if out['outcome']==9 else 2 if out['outcome']==10 else 0
        if out['e']!=expected_endpoint:issues.append('endpoint_terminal_conflict')
        # 512是Native formatter包含NUL的原固定容量，hilog前缀不算Native正文。
        # 非ASCII/额外空白不能借解码后的字符数规避原字节预算；旧ILAT1规则不改变。
        if len(('ILAT2 '+payload).encode('utf-8'))>=512:issues.append('record_budget_conflict')
    if out['mask']&~63:issues.append('unsupported_mask')
    if out['outcome'] not in outcomes:issues.append('non_exportable_wait_terminal' if protocol==1 and out['outcome']==7 else 'unsupported_terminal')
    for index,ns in enumerate(out['ns']):
        if bool(out['mask']&(1<<index))!=(ns is not None):issues.append('mask_ns_conflict');break
    known=[value for value in out['ns'] if value is not None]
    if any(right<left for left,right in zip(known,known[1:])):issues.append('non_monotonic')
    for names in [['ses','pfx','po'],['seq','ro'],['c','a','tgt','ticket']]:
        count=sum(out[name] is not None for name in names)
        if count not in [0,len(names)]:issues.append('partial_identity_tuple')
    if (out['seq'] is not None and out['pfx'] is None) or ((out['mask']&62) and out['pfx'] is None):issues.append('stage_without_prefix_identity')
    if out['ro'] is not None and (out['po'] is None or out['ro']<=out['po']):issues.append('prefix_ring_order_conflict')
    if out['mask']&12 and out['seq'] is None:issues.append('ring_stage_without_original_sequence')
    if out['mask']&48 and out['ticket'] is None:issues.append('cache_return_without_original_ticket')
    if protocol==2:
        # outcome9/10是真终点事实，note忙/clock失败允许ns5缺失；其它pull终态
        # e0没有成功终点，不能携第六点。SDK拒绝可以发生在真实cache已更新之后。
        if out['outcome'] not in [9,10] and out['mask']&32:issues.append('terminal_return_conflict')
    else:
        if out['outcome'] in [2,3,4,5,8] and out['mask']&32:issues.append('terminal_return_conflict')
        if out['outcome']==4 and out['mask']&16:issues.append('rejected_with_cache_conflict')
    out['terminal']=outcomes.get(out['outcome'],'UNSUPPORTED')
    return out,sorted(set(issues))


def record_v2(payload):
    """ILAT2明确入口，人工fixture与实际formatter正例共用同一生产解析规则。"""
    return record(payload,2)


def summary(payload):
    """SUM只是无batch编号的诊断累计/导出情况，不提供输入时间或可靠总体丢失率。"""
    raw=tokens(payload,SUMMARY_KEYS);out={key:uint(value,32 if key in ['n','bytes','exportfail','count_uncertain','record_bytes','capacity'] else 64) for key,value in raw.items()}
    issues=[]
    if out['n']>7 or out['bytes']>3584 or out['exportfail']>out['n'] or out['count_uncertain']>1:issues.append('summary_budget_conflict')
    if out['record_bytes']!=152 or out['capacity']!=512:issues.append('unsupported_summary_layout')
    return out,issues


def quantiles(values):
    """nearest-rank：ceil(p*n)的原整数ns，不插值/平均；n小仍如实显示，无性能通过阈值。"""
    values=sorted(values);size=len(values)
    if not size:return {'n':0,'p50_ns':None,'p95_ns':None,'p99_ns':None}
    return {'n':size,**{'p'+str(p)+'_ns':str(values[(p*size+99)//100-1]) for p in [50,95,99]}}


def binding(item,base):
    """Source/HAP/PID/scene由调用者明确提供；只核文件SHA，不擅自证明这些材料的因果关系。"""
    required=['capture_id','layer','pid','source','hap','scene','clock_domain','sampling_interval','prefix_format']
    if any(key not in item for key in required):raise ValueError('binding requires explicit '+','.join(required))
    if item['layer'] not in ['host','device','rule_fixture'] or not isinstance(item['scene'],str) or not item['scene']:raise ValueError('invalid explicit layer/scene')
    if not isinstance(item['capture_id'],str) or not item['capture_id']:raise ValueError('explicit process lifetime capture_id required')
    if item['pid'] is not None and (type(item['pid']) is not int or item['pid']<1):raise ValueError('invalid PID')
    if type(item['sampling_interval']) is not int or item['sampling_interval']<1:raise ValueError('explicit positive compile sampling interval required')
    source=item['source']
    if not isinstance(source,dict) or not source.get('identity'):raise ValueError('explicit Source identity required')
    if 'adopted' in source and type(source['adopted']) is not bool:raise ValueError('source adopted must be explicit boolean')
    if 'evidence_kind' in item and (not isinstance(item['evidence_kind'],str) or not item['evidence_kind']):raise ValueError('explicit nonempty evidence_kind required')
    _,source_sha=original_file(source['receipt'],base)
    item={**item,'source_receipt_sha256':source_sha}
    gaps=[]
    if item['layer']=='device':
        if item['pid'] is None:gaps.append('missing_original_pid')
        if item['prefix_format']!='hilog' or item['clock_domain']!='CLOCK_MONOTONIC_NS':gaps.append('device_clock_or_carrier_unqualified')
        hap=item['hap']
        if not isinstance(hap,dict) or not re.fullmatch('[0-9a-f]{64}',hap.get('sha256','')):gaps.append('missing_original_hap')
        elif hap.get('path'):original_file(hap,base)
    else:
        if item['clock_domain'] not in ['HOST_STEADY_NS','HOST_MSVC_STEADY_CLOCK_NS','CLOCK_MONOTONIC_NS']:gaps.append('unknown_clock_domain')
        if item['pid'] is None:gaps.append('host_original_pid_not_recorded')
        if item['layer']=='host' and item['hap'] is None:gaps.append('host_evidence_has_no_device_hap')
    if source.get('adopted') is False:gaps.append('candidate_source_not_adopted')
    if item.get('evidence_kind')=='native_formatter_interop':
        if item['layer']!='host':raise ValueError('formatter interop requires explicit host layer')
        gaps.append('literal_host_slots_not_actual_input_propagation')
    return item,gaps


def semantic_binding(context,scene=True):
    """同SHA材料换路径不能创造新样本；只比较调用者声明的原资格，不把路径当进程身份。"""
    value={key:context[key] for key in ['capture_id','layer','pid','clock_domain','sampling_interval','prefix_format']}
    value.update(source_identity=context['source']['identity'],source_receipt_sha256=context['source_receipt_sha256'],
                 hap_sha256=context['hap'].get('sha256') if isinstance(context['hap'],dict) else None,
                 source_adopted=context['source'].get('adopted'),evidence_kind=context.get('evidence_kind'))
    if scene:value['scene']=context['scene']
    return value


def actual_summaries(sums):
    """原资格隔离完成后才判断实际SUM存在；规则fixture和冲突SUM均不能补资格。"""
    return [item for item in sums if item['binding']['layer']!='rule_fixture' and not item['excluded_from_diagnostic_inferences']]


def run(manifest_path,out):
    """同capture/id去重，冲突双方隔离；按显式scene/终态统计各有证端点，保完整排除理由。"""
    manifest_path=manifest_path.resolve();base=manifest_path.parent;data=json.loads(manifest_path.read_text(encoding='utf-8-sig'))
    if data.get('schema')!='amcl-native-ilat-manifest/v1' or not data.get('evidence'):raise ValueError('manifest schema/evidence missing')
    # 所属仓的统一helper解析链接/Git边界；公开克隆或任意工作区可显式传仓外输出。
    # 目录已存在即拒绝，正常/错误产物均不得覆盖旧证据；没有D/E或任务Root硬锁。
    out=external_output_path(out,PROJECT_ROOT)
    if out.exists():raise ValueError('output must be a NEW directory outside source repositories')
    out.mkdir(parents=True)
    issues=[];events={};claims=[];sums=[];origins={};duplicates=[];bindings=[];conflicted=set();file_receipts=[];capture_bindings={};bad_captures=set()
    def issue(kind,ref,detail=None):issues.append({'kind':kind,'ref':ref,**({'detail':detail} if detail else {})})
    for evidence in data['evidence']:
        path,digest=original_file(evidence,base);context,gaps=binding(evidence['binding'],base)
        bindings.append({'binding':context,'qualification_gaps':gaps})
        start=evidence.get('line_start',1);end=evidence.get('line_end')
        if type(start) is not int or start<1 or (end is not None and (type(end) is not int or end<start)):raise ValueError('invalid explicit line range')
        semantic=semantic_binding(context);namespace=(context['capture_id'],context['pid'],context['source']['identity'],
          context['source_receipt_sha256'],semantic['hap_sha256'])
        scope=json.dumps(semantic,sort_keys=True);lifetime=semantic_binding(context,scene=False)
        if context['capture_id'] in capture_bindings and capture_bindings[context['capture_id']]!=lifetime:
            bad_captures.add(context['capture_id']);issue('capture_binding_conflict',{'capture_id':context['capture_id']})
        capture_bindings[context['capture_id']]=lifetime
        with path.open('rb') as stream:
            for number,line in enumerate(stream,1):
                if number<start or (end is not None and number>end):continue
                if b'ILAT' not in line:continue
                ref={'sha256':digest,'path':str(path),'line':number,'capture_id':context['capture_id'],'scene':context['scene']}
                try:text=line.decode('utf-8').rstrip('\r\n')
                except UnicodeDecodeError:issue('malformed_utf8',ref);continue
                marker=re.search(r'(?<!\S)(ILAT\d+(?:_SUM)?)\s+',text)
                if not marker:continue
                origin=(digest,number)
                if origin in origins:
                    previous=origins[origin]
                    if previous['scope']==scope:duplicates.append({'kind':'duplicate_original','ref':ref});continue
                    issue('original_binding_conflict',ref);previous['conflict']=True
                    if previous.get('key'):conflicted.add(previous['key'])
                    continue
                state={'scope':scope,'conflict':False};origins[origin]=state
                if marker[1] not in ['ILAT1','ILAT1_SUM','ILAT2']:issue('unsupported_protocol',ref);continue
                prefix=text[:marker.start()];observed_pid=None
                if context['prefix_format']=='hilog':
                    match=HILOG.fullmatch(prefix)
                    if not match:issue('unverified_hilog_carrier',ref);continue
                    observed_pid=int(match[1])
                    if context['pid'] is None or observed_pid!=context['pid']:issue('pid_binding_mismatch',ref);continue
                elif context['prefix_format']=='host_stdout' and context['layer']!='device':
                    if prefix:issue('unverified_host_carrier',ref);continue
                else:issue('unsupported_carrier',ref);continue
                payload=text[marker.end():]
                try:row,errors=summary(payload) if marker[1].endswith('_SUM') else record_v2(payload) if marker[1]=='ILAT2' else record(payload)
                except ValueError as error:issue('malformed_record',ref,str(error));continue
                if errors:
                    for error in errors:issue(error,ref)
                    continue
                if marker[1].endswith('_SUM'):
                    sums.append({'binding':context,'row':row,'ref':ref,'origin':origin});continue
                key=(*namespace,row['id']);state['key']=key
                # 每个合法原variant都保原tuple认领。即使同id已冲突，其后续variant
                # 也不能从prefix/ring/ticket索引消失，否则别的id可借该tuple进入n。
                # events只承载规范化首行；claims用于所有原variant的冲突闭包，不择优。
                claims.append({'key':key,'row':row,'namespace':namespace,'ref':ref})
                if key in events:
                    previous=events[key]
                    if previous['row']==row and semantic_binding(previous['binding'])==semantic:duplicates.append({'kind':'duplicate_record','ref':ref});continue
                    issue('record_identity_conflict',ref);conflicted.add(key);continue
                events[key]={'row':row,'binding':context,'gaps':gaps,'ref':ref,'origin':origin,'namespace':namespace}
        if sha(path)!=digest:raise ValueError('original changed while parsing: '+str(path))
        file_receipts.append({'path':str(path),'sha256':digest,'bytes':path.stat().st_size,'line_start':start,'line_end':end})
    # 原prefix/ring/ticket若被两个id认领，不能任选一条凑n。该关系只在同一显式进程生命期内核。
    indexes=defaultdict(dict)
    for claim in claims:
        key=claim['key'];row=claim['row'];space=claim['namespace']
        for kind,identity in [('prefix',row['pfx']),('ring_sequence',row['seq']),('ticket',tuple(row[name] for name in ['c','a','tgt','ticket']) if row['ticket'] else None)]:
            if identity is None:continue
            index=indexes[(space,kind)]
            if identity in index and index[identity]!=key:
                conflicted.update([key,index[identity]]);issue('original_'+kind+'_conflict',claim['ref'])
            index[identity]=key
    # SUM无batch身份，不能按相同正文去重不同原行；仅按同一原件/原行去重。累计倒退分列，
    # 不跨scene计算“本场景丢失率”，skipped/unbound也不能当生产输入丢失。
    previous_sums={}
    for item in sums:
        ctx=item['binding']
        # 原SUM与绑定原样保留；只有诊断推论被隔离。原件同一行被换scene/
        # capture重新声明时，origins在全部原件读完后已标冲突；同capture的
        # Source/PID等资格A→B→A也必须保持bad_captures，不因最后回到A恢复。
        # 不能让这类SUM证明“实际SUM已存在”，或污染正常累计基线和drop证据。
        reasons=[]
        if origins[item['origin']]['conflict']:reasons.append('quarantined_original_binding_conflict')
        if ctx['capture_id'] in bad_captures:reasons.append('quarantined_capture_binding_conflict')
        item['excluded_from_diagnostic_inferences']=bool(reasons)
        item['exclusion_reasons']=reasons
        if reasons:continue
        key=(ctx['capture_id'],ctx['pid'],ctx['source_receipt_sha256']);old=previous_sums.get(key)
        if old and any(item['row'][field]<old[field] for field in ['sampled','skipped','full','busy','unbound','clockfail']):issue('summary_counter_regression',item['ref'])
        previous_sums[key]=item['row']
        for field in ['full','busy','unbound','clockfail','exportfail','count_uncertain']:
            if item['row'][field]:issue('summary_'+field,item['ref'])
    metrics=defaultdict(lambda:defaultdict(list));counts=Counter();records=[];group_contexts={}
    for key,event in events.items():
        row=event['row'];ctx=event['binding'];excluded=key in conflicted or origins[event['origin']]['conflict'] or ctx['capture_id'] in bad_captures
        notes=[]
        is_pull=row.get('protocol')=='ILAT2'
        if (not is_pull or row['outcome'] in [9,10]) and row['mask']!=63:
            notes.append('missing_segments');issue('missing_segments',event['ref'])
        elif is_pull and row['e']==0:
            # e0明确没有成功终点，第六点缺席符合合同；不把正常cache-only误说成
            # callback缺RETURN。未取到的其它时点仍在ns/mask和unobserved_stages列明。
            notes.append('no_success_endpoint')
        if row['clockfail']:notes.append('clock_failure');issue('clock_failure',event['ref'])
        if excluded:notes.append('quarantined_conflict')
        layer=ctx['layer'] if ctx['layer']!='device' or not event['gaps'] else 'unqualified_device_binding'
        protocol,backend,endpoint,pairs=observation_model(row)
        # 原session也分列，不能由显式capture名字把两个原scope的时钟混成分位数。
        group=(ctx['capture_id'],ctx['scene'],layer,protocol,backend,endpoint,str(row['ses']) if row['ses'] is not None else '-',row['terminal']);counts[group]+=not excluded
        group_contexts[group]=ctx
        prefix_ok=all(row[field] is not None for field in ['ses','pfx','po'])
        ring_ok=prefix_ok and row['seq'] is not None and row['ro'] is not None
        ticket_ok=prefix_ok and all(row[field] is not None for field in ['c','a','tgt','ticket'])
        if not excluded and not any(gap=='unknown_clock_domain' for gap in event['gaps']):
            for name,left,right in pairs:
                needed=prefix_ok and (ring_ok if right>=2 else True) and (ticket_ok if right>=4 else True)
                if right==5 and row['outcome'] not in ([9,10] if protocol=='ILAT2' else [1,6]):continue
                if needed and row['ns'][left] is not None and row['ns'][right] is not None:metrics[group][name].append(row['ns'][right]-row['ns'][left])
        record_value={'binding':ctx,'ref':event['ref'],'row':row,'excluded_from_metrics':excluded,'notes':notes}
        if is_pull:
            names=['ENTRY','ACCEPT','ENQUEUE','READ','CACHE','TERMINAL_OBSERVATION']
            record_value['unobserved_stages']=[names[i] for i,value in enumerate(row['ns']) if value is None]
        records.append(record_value)
    groups=[]
    for group,n in sorted(counts.items()):
        capture,scene,layer,protocol,backend,endpoint,session,terminal=group
        # 原GLFW指标字面名与规则保持；pull指标不包含callback或SDL队列内部跨度。
        pairs=PAIR_SPECS if protocol=='ILAT1' else observation_model({'protocol':'ILAT2','b':3 if backend=='SDL3' else 2,'e':1 if endpoint=='SDL_QUEUE_ADD_RECEIPT_RETURN' else 2 if endpoint=='L2_POLL_VIEW_COPY' else 0})[3]
        group_value={'capture_id':capture,'scene':scene,'layer':layer,'terminal':terminal,'unique_records':n,
          'metrics':{name:quantiles(metrics[group][name]) for name,_,_ in pairs}}
        if protocol=='ILAT2':
            context=group_contexts[group];kind=context.get('evidence_kind','unspecified')
            group_value.update(protocol=protocol,backend=backend,endpoint=endpoint,game_session=session,
              evidence_kind=kind,metric_scope='literal host collector/formatter call points only; no Look Core, SDK, L2 poll or Java input path' if kind=='native_formatter_interop' else 'Native point spans per caller binding; endpoint origin is not independently proven')
        # 旧ILAT1组的字段/指标及原断言逐字保持；只有新协议加明确的ABI/终点scope。
        groups.append(group_value)
    categories=Counter(item['kind'] for item in issues)
    qualification=[gap for item in bindings for gap in item['qualification_gaps']]
    actual_sums=actual_summaries(sums)
    partial_reasons=sorted(set([*categories,*qualification,*([] if actual_sums else ['no_actual_ILAT1_SUM']),
      *(['host_or_rule_fixture_only'] if all(item['binding']['layer']!='device' for item in bindings) else []),
      'sampled_population_not_all_input_events','sdk_sample_origin_unknown','game_tick_not_measured']))
    report={'schema':'amcl-native-ilat-report/v1','status':'PARTIAL_NATIVE_OBSERVATIONS','manifest':{'path':str(manifest_path),'sha256':sha(manifest_path)},
      'parser_sha256':sha(Path(__file__)),'source_contracts':[{'path':str(original_file(item,base)[0]),'sha256':item['sha256']} for item in data.get('source_contracts',[])],
      'evidence':file_receipts,'bindings':bindings,'unique_records':sum(not item['excluded_from_metrics'] for item in records),
      'duplicate_count':len(duplicates),'duplicates':duplicates,'issue_counts':dict(categories),'groups':groups,'summaries':sums,
      'partial_reasons':partial_reasons,'quantile_method':'nearest rank ceil(p*n), integer ns; no inverse-sampling weights',
      'scope':'Native point spans only. ILAT1 declares STATE_ONLY/callback return; ILAT2 declares SDL posted receipt-return or L2 poll-view-copy semantics. Actual endpoint origin requires separate Source/consumer proof; formatter interop measures literal host call points only, never queue internals/Java/game ACK',
      'forbidden_inferences':['SDK latency','Core processing latency','pure callback time','SDL queue internal latency','Java/game consumption ACK','actual game tick','touch-to-photon','performance PASS','CPU root cause'],
      'binding_limit':'caller-provided capture/PID/Source/HAP/scene association; SHA checked files do not independently prove association'}
    # uint64字段保持十进制字符串，JSON消费者不能用double损失身份/时点精度。
    def exact(value,key=''):
        if isinstance(value,dict):return {k:exact(v,k) for k,v in value.items()}
        if isinstance(value,list):return [exact(v,key) for v in value]
        if type(value) is int and (key in ['id','ses','stream','pfx','po','seq','ro','c','a','tgt','ticket','ns','sampled','skipped','full','busy','unbound','clockfail']):return str(value)
        return value
    (out/'report.json').write_text(json.dumps(exact(report),ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
    for filename,values in [('records.jsonl',records),('issues.jsonl',issues)]:
        (out/filename).write_text(''.join(json.dumps(exact(value),ensure_ascii=False)+'\n' for value in values),encoding='utf-8',newline='\n')
    return report


def main():
    """固定CLI输出；解析可用但partial退出0，绑定/原件漂移错误退出2，绝不以退出0称性能PASS。"""
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--manifest',type=Path,required=True);parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    output=None;already_exists=True
    try:
        # 越仓/越Git边界在创建任何错误产物之前失败；拒绝路径保持不存在。
        output=external_output_path(args.out,PROJECT_ROOT);already_exists=output.exists()
        report=run(args.manifest,output);print(json.dumps({'status':report['status'],'unique_records':report['unique_records'],
          'duplicates':report['duplicate_count'],'issue_counts':report['issue_counts'],'out':str(args.out.resolve())},ensure_ascii=False))
    except (ValueError,KeyError,TypeError,OSError,json.JSONDecodeError) as error:
        # 原件/绑定失败没有可用统计；只在本次新建外置目录留下固定错误产物，禁止覆盖旧输出。
        if output is not None and not already_exists:
            output.mkdir(parents=True,exist_ok=True)
            (output/'report.json').write_text(json.dumps({'schema':'amcl-native-ilat-report/v1','status':'BINDING_ERROR',
              'error':str(error),'metrics':None,'scope':'no qualified statistics; no device/performance claim'},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
            for filename in ['records.jsonl','issues.jsonl']:(output/filename).write_text('',encoding='utf-8')
        print('ILAT binding/parse error: '+str(error),file=sys.stderr);sys.exit(2)


if __name__=='__main__':main()
