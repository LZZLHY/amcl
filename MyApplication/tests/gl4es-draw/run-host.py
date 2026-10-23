#!/usr/bin/env python3
"""链接完整锁定 gl4es，运行独立像素/状态负例和修复回归；所有输出显式外置。

源码种子必须是相同 pin 的干净 Git checkout。每次从 git archive 生成独立源码，
测试只读消费种子；baseline/不完整修复变体不能被当作正式候选的通过结果。
"""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tarfile
import time

PIN = '144d0dc79855b392e5256dd15fb2dbdedb17141a'
CASES = ['arrays-merge', 'arrays-no-merge', 'elements-direct', 'elements-list',
         'basevertex', 'zero', 'display-list', 'pending', 'bounds', 'errors',
         'wide', 'compact', 'vao-bindings', 'topology', 'wire', 'alpha', 'texture', 'allocation',
         'lazy-error', 'lazy-string', 'lazy-integer', 'lazy-float', 'lazy-stringi', 'hot-cache', 'texture-bindings',
         'boolean-shim-error','boolean-driver-error']

# profile值对应生产init.c的真实开关；maxbatch=100来自LIBGL_BATCH=1，不能写标签后
# 在测试里再覆为0。旧case内部会有自己的限定开关，实际热资格仅由hot-cache验证。
PROFILES={'baseline':{'LIBGL_BATCH':'0','LIBGL_USEVBO':'0'},
          'batch':{'LIBGL_BATCH':'1','LIBGL_USEVBO':'0'},
          'gpu-vbo':{'LIBGL_BATCH':'0','LIBGL_USEVBO':'1'},
          'batch-gpu':{'LIBGL_BATCH':'1','LIBGL_USEVBO':'1'}}


def run(command, directory, log, environment=None, timeout=300):
    """原始输出保留，构建前台显示；进程失败由调用方按正例/负例身份解释。"""
    with log.open('w', encoding='utf-8') as stream:
        process = subprocess.Popen(command, cwd=directory, env=environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        start = time.monotonic()
        for line in process.stdout:
            stream.write(line)
            if 'build' in log.name:
                print(line, end='', flush=True)
            if time.monotonic()-start > timeout:
                process.kill()
                raise RuntimeError('Timed out: '+str(command))
        return process.wait()


def inspect_success_log(body, case, profile, iterations, scene_source):
    """只检查实际成功日志的身份/完整性/开关，不重算任何像素或名字的语义oracle。

    phase清单来自C的唯一调用点；初始化与末尾实取都必须存在。旧case有意改开关，
    只要求初始化对应profile并如实保留最终值；hot-cache则全过程冻结profile。
    完成marker不能独自补足缺查询、缺phase或截断文件。
    """
    issues,observed=[],{}
    expected={'maxbatch':int(PROFILES[profile]['LIBGL_BATCH'])*100,
              'usevbo':int(PROFILES[profile]['LIBGL_USEVBO'])}
    options={}
    for phase in ('INITIAL','FINAL'):
        records=list(re.finditer(r'QA_'+phase+r' case=(\S+) maxbatch=(\d+) usevbo=(\d+) merge=(\d+)',body))
        if len(records)!=1 or body.count('QA_'+phase)!=1 or records[0].group(1)!=case:
            issues.append('missing/duplicate/wrong-case '+phase+' actual options');continue
        options[phase]=records[0]
        observed[phase.lower()]=dict(zip(('maxbatch','usevbo','merge'),map(int,records[0].groups()[1:])))
    if not body.endswith('\n') or body.rstrip().splitlines()[-1:]!=['PASS '+case+': production library + actual GLES pixels/state']:
        issues.append('truncated or missing actual successful process footer')
    initial=observed.get('initial',{})
    if any(initial.get(key)!=value for key,value in expected.items()): issues.append('INITIAL options differ from profile')
    if case=='hot-cache':
        names=set(re.findall(r'hot_phase\("([^\"]+)",n\)',scene_source))
        records=list(re.finditer(r'HOT_PASS iteration=(\d+) phase=([^ ]+) maxbatch=(\d+) usevbo=(\d+) merge=(\d+)',body))
        if not names: issues.append('shared C hot phase list is empty')
        if len(records)!=iterations*len(names) or body.count('HOT_PASS')!=len(records) or any(
            sum(int(record.group(1))==n and record.group(2)==name for record in records)!=1
            for n in range(iterations) for name in names): issues.append('missing/duplicate hot phase record')
        if observed.get('final')!=initial: issues.append('FINAL hot options differ from profile')
        if any(dict(zip(('maxbatch','usevbo','merge'),map(int,record.groups()[2:])))!=initial for record in records):
            issues.append('hot phase actual options differ from profile')
        terminal=list(re.finditer(r'HOT_RESULT completed=(\d+) iterations=(\d+) steps=(\d+) expectedSteps=(\d+) maxbatch=(\d+) usevbo=(\d+) merge=(\d+)',body))
        if len(terminal)!=1 or body.count('HOT_RESULT')!=1 or tuple(map(int,terminal[0].groups()[:4]))!=(1,iterations,iterations*len(names),iterations*len(names)):
            issues.append('missing/duplicate/incomplete HOT_RESULT')
        elif dict(zip(('maxbatch','usevbo','merge'),map(int,terminal[0].groups()[4:])))!=initial:
            issues.append('HOT_RESULT options differ from profile')
        elif records and (records[-1].end()>terminal[0].start() or options.get('FINAL') is None or terminal[0].end()>options['FINAL'].start()):
            issues.append('HOT_RESULT not at end of actual hot evidence')
    elif case=='texture-bindings':
        records=list(re.finditer(r'BINDING_QUERY token=(\d+) expected=(\d+) integer=(-?\d+) float=(-?\d+) double=(-?\d+) boolean=(\d+)',body))
        if len(records)!=45 or body.count('BINDING_QUERY')!=45: issues.append('missing/duplicate/partial original binding query record')
        terminal=list(re.finditer(r'BINDING_RESULT completed=(\d+) queries=(\d+) targets=(\d+) units=(\d+) integer64=(\S+)',body))
        if len(terminal)!=1 or body.count('BINDING_RESULT')!=1 or tuple(map(int,terminal[0].groups()[:4]))!=(1,45,5,2):
            issues.append('missing/duplicate/incomplete BINDING_RESULT')
        elif records and (records[-1].end()>terminal[0].start() or options.get('FINAL') is None or terminal[0].end()>options['FINAL'].start()):
            issues.append('BINDING_RESULT not at end of actual binding evidence')
    elif case in ('boolean-shim-error','boolean-driver-error'):
        # 这两个case先以公开GetError校准注入，再重注入/查询/取错。footer不能
        # 替代原始两次取错和一次pair诊断；本层只冻结已经由C断言的值及记录顺序。
        kind='shim' if case=='boolean-shim-error' else 'driver'
        records=list(re.finditer(r'^BOOLEAN_PENDING kind=(shim|driver) queried=([01]) expected=(\d+) actual=(\d+)$',body,re.MULTILINE))
        pair=list(re.finditer(r'^BOOLEAN_PAIR kind=(shim|driver) oldShim=(\d+) actualShim=(\d+) oldError=(\d+) actualError=(\d+)$',body,re.MULTILINE))
        expected_pair=(1,1,1280,1280) if kind=='shim' else (0,0,0,0)
        if len(records)!=2 or body.count('BOOLEAN_PENDING')!=2 or any(
            record.group(1)!=kind or tuple(map(int,record.groups()[1:]))!=(queried,1280,1280)
            for queried,record in enumerate(records)):
            issues.append('missing/duplicate/wrong Boolean pending record')
        if len(pair)!=1 or body.count('BOOLEAN_PAIR')!=1 or pair[0].group(1)!=kind or tuple(map(int,pair[0].groups()[1:]))!=expected_pair:
            issues.append('missing/duplicate/wrong Boolean error pair record')
        terminal=list(re.finditer(r'^PASS '+re.escape(case)+r': production library \+ actual GLES pixels/state$',body,re.MULTILINE))
        if len(terminal)!=1 or body.count('PASS '+case+':')!=1:
            issues.append('missing/duplicate Boolean process terminal')
        if len(records)==2 and len(pair)==1 and len(terminal)==1 and all(phase in options for phase in ('INITIAL','FINAL')):
            if not (options['INITIAL'].end()<records[0].start()<pair[0].start()<records[1].start()<options['FINAL'].start()<terminal[0].start()):
                issues.append('Boolean evidence is outside the expected process order')
    return not issues,observed,issues


def main():
    """真实库构建与场景隔离，结果中同时保存 pin、补丁身份和实际退出码。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--variant', choices=['candidate', 'baseline', 'guard-only', 'keep-only', 'indices-only', 'without-lazy', 'without-texture-query', 'boolean-delegate-control', 'controls'], default='candidate')
    parser.add_argument('--cases', nargs='+', choices=CASES, default=CASES)
    parser.add_argument('--profiles',nargs='+',choices=PROFILES,default=['baseline'])
    parser.add_argument('--oracle-control',choices=['none','stale-texture','stale-uniform'],default='none')
    parser.add_argument('--hot-iterations',type=int,choices=range(1,33),default=8)
    args = parser.parse_args()
    if args.oracle_control!='none' and args.cases!=['hot-cache']: raise ValueError('Oracle controls require only hot-cache')
    if args.variant=='boolean-delegate-control' and args.cases!=['boolean-shim-error']: raise ValueError('Boolean delegate control requires the directly failing shim case only')
    root = Path(__file__).resolve().parents[2]
    if args.variant=='controls':
        # 控制组必须产生有可核对原因的失败，编译失败/环境失败不能冒充成功检出缺陷。
        args.output.mkdir(parents=True,exist_ok=False)
        controls=[('baseline',['arrays-merge','arrays-no-merge','elements-direct','basevertex','zero']),
                  ('guard-only',['arrays-no-merge']),('keep-only',['arrays-no-merge']),
                  ('indices-only',['elements-list','basevertex']),
                  ('without-lazy',['lazy-error','lazy-string','lazy-integer','lazy-float','lazy-stringi'])]
        rows=[]
        for variant,cases in controls:
            directory=args.output/variant
            subprocess.run([sys.executable,'-B',str(Path(__file__).resolve()),'--source',str(args.source),
                            '--output',str(directory),'--variant',variant,'--cases',*cases],check=False)
            results=json.loads((directory/'results.json').read_text())
            for result in results['cases']:
                diagnostic=Path(result['log']).read_text()
                detected=result['exitCode']!=0 and any(token in diagnostic for token in
                    ['drawing.c:820','drawing.c:995','drawing.c:1075','AddressSanitizer','independent pixel expectation'])
                # 首入口会被 UBSan 先行终止，不能只等 ASan 的标记。限定此负控的具体
                # null glstate 诊断和真实 getter 栈，其他环境/编译错误仍不能冒充检出。
                if variant=='without-lazy':
                    detected=(result['exitCode']!=0 and
                              "member access within null pointer of type 'struct glstate_t'" in diagnostic and
                              ('gl4es_glGet' in diagnostic or 'BuildExtensionsList' in diagnostic))
                rows.append({'variant':variant,**result,'expectedFailureDetected':detected})
        (args.output/'controls.json').write_text(json.dumps(rows,indent=2)+'\n')
        return 0 if all(row['expectedFailureDetected'] for row in rows) else 1
    source = args.source.resolve()
    if subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() != PIN:
        raise ValueError('Source pin mismatch')
    # Windows bind 的执行位与 CRLF 是检出表示差异；只在该命令归一化，不改种子或全局 Git 配置。
    if subprocess.check_output(['git', '-c', 'core.filemode=false', '-c', 'core.autocrlf=true',
                                '-C', str(source), 'status', '--porcelain'], text=True).strip():
        raise ValueError('Source seed must be clean; preserve modified seeds separately')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    tree = output/'source'
    tree.mkdir()
    archive = output/'source.tar'
    with archive.open('wb') as stream:
        subprocess.run(['git', '-C', str(source), 'archive', PIN], stdout=stream, check=True)
    with tarfile.open(archive) as stream:
        stream.extractall(tree, filter='data')
    patches = []
    if args.variant in ('candidate','without-lazy','without-texture-query','boolean-delegate-control'):
        directory = root/'prebuilt/gl4es/patches'
        for name in (directory/'series').read_text().splitlines():
            if not name.strip() or name.startswith('#'):
                continue
            patch = directory/name.strip()
            if args.variant=='without-texture-query' and name.startswith('0006-'): continue
            subprocess.run(['git', 'apply', '--unsafe-paths', str(patch)], cwd=tree, check=True)
            patches.append({'name': patch.name, 'sha256': hashlib.sha256(patch.read_bytes()).hexdigest()})
        if args.variant=='without-lazy':
            # 故意删除五个实际首入口的初始化，证明新启动回归能检出本次导出失误。
            # 只改测试构造树，绝不改正式补丁；每个首入口由独立被测进程消费。
            path=tree/'src/gl/getter.c'
            body=path.read_text()
            if body.count('    gl4es_ensure_init();')!=5:
                raise ValueError('Unexpected OHOS first-entry guard layout')
            path.write_text(body.replace('    gl4es_ensure_init();\n',''))
        if args.variant=='boolean-delegate-control':
            # 精确恢复复审前的生产boolean委派，检验会清旧错的真实getter调用。
            # 只改本次构造树；环境失败/崩溃不能代替pending错误断言失败。
            path=tree/'src/gl/wrap/gles.c';body=path.read_text()
            needle='GLuint name=0; if(amcl_texture_binding_name(pname,&name)) { *params=name?GL_TRUE:GL_FALSE; return; }'
            if body.count(needle)!=1: raise ValueError('Unexpected private boolean helper layout')
            path.write_text(body.replace(needle,'GLint name=0; gl4es_glGetIntegerv(pname,&name); *params=name?GL_TRUE:GL_FALSE; return;'))
    elif args.variant in ('guard-only', 'keep-only','indices-only'):
        path = tree/'src/gl/drawing.c'
        body = path.read_text()
        # 审查中两种故意不完整的修复保留为反控制：真实列表不能仅靠判空/传链过关。
        if args.variant!='indices-only':
            body = body.replace('if(globals4es.mergelist && list->stage>=STAGE_DRAW',
                                'if(list && globals4es.mergelist && list->stage>=STAGE_DRAW')
        if args.variant == 'keep-only':
            first = body.index('void gl4es_glMultiDrawArrays(')
            last = body.index('void glMultiDrawArrays(', first)
            body = body[:first]+body[first:last].replace('arrays_to_renderlist(NULL,', 'arrays_to_renderlist(list,')+body[last:]
        if args.variant=='indices-only':
            first=body.index('void gl4es_glMultiDrawElements(')
            last=body.index('void gl4es_glDrawElementsBaseVertex(',first)
            segment=body[first:last].replace('(uintptr_t)indices','(uintptr_t)indices[i]')
            segment=segment.replace(':indices,',':indices[i],').replace('(GLvoid*)indices;','(GLvoid*)indices[i];')
            body=body[:first]+segment+body[last:]
        path.write_text(body)
    if args.variant not in ('candidate','without-lazy','without-texture-query','boolean-delegate-control'):
        # 独立的 FPE/Shader C 边界修正同样用于控制组，避免其先行 UB 遮住原始 Draw 反例。
        support=root/'prebuilt/gl4es/patches/0004-fpe-zero-texture-and-empty-uniform-cache.patch'
        subprocess.run(['git','apply','--unsafe-paths',str(support)],cwd=tree,check=True)
        patches.append({'name':support.name,'sha256':hashlib.sha256(support.read_bytes()).hexdigest(),'role':'shared-non-Draw-boundaries'})
    # ASan 拒绝 RTLD_DEEPBIND；仅在测试的系统库加载边界去掉此标志，真实 Draw/list/FPE 不替换。
    loader = tree/'src/gl/loader.c'
    loader.write_text(loader.read_text().replace('flags |= RTLD_DEEPBIND;', 'flags |= 0; /* sanitizer: system boundary */'))
    flags = '-g -O1 -fno-omit-frame-pointer -fsanitize=address,undefined -DAMCL_DRAW_TESTING'
    build = output/'build'
    command = ['cmake', '-S', str(tree), '-B', str(build), '-G', 'Ninja',
               '-DNOX11=ON', '-DNOEGL=ON', '-DNO_INIT_CONSTRUCTOR=ON',
               '-DCMAKE_BUILD_TYPE=Debug', '-DCMAKE_C_FLAGS='+flags,
               '-DCMAKE_SHARED_LINKER_FLAGS=-fsanitize=address,undefined']
    subprocess.run(command, check=True)
    if run(['cmake', '--build', str(build), '--target', 'GL', '-j', '8'], output, output/'build.log'):
        raise RuntimeError('Production library build failed')
    executable = output/'draw-test'
    subprocess.run(['cc', '-std=gnu11', '-g', '-O1', '-fno-omit-frame-pointer',
                    '-fsanitize=address,undefined', '-I'+str(tree/'include'), '-I'+str(tree/'src'),
                    '-I'+str(tree/'src/util'), str(root/'tests/gl4es-draw/draw_test.c'),
                    '-lEGL', '-ldl', '-lm', '-o', str(executable)], check=True)
    environment = dict(os.environ, EGL_PLATFORM='surfaceless', LIBGL_ALWAYS_SOFTWARE='1',
                       ASAN_OPTIONS='detect_leaks=1:halt_on_error=1',
                       UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1',
                       LIBGL_GLES='libGLESv2.so.2', LIBGL_GL='21', LIBGL_BATCH='0',
                       LIBGL_FB='0', LIBGL_NOTEST='0', LIBGL_NOINTOVLHACK='1')
    results = []
    for profile in args.profiles:
        configured=dict(environment,**PROFILES[profile],AMCL_QA_HOT_CONTROL=args.oracle_control,
                        AMCL_QA_HOT_ITERATIONS=str(args.hot_iterations))
        for case in args.cases:
            log = output/(profile+'-'+case+'.log')
            code = run([str(executable), str(tree/'lib/libGL.so.1'), case], output, log, configured)
            body=log.read_text()
            complete,observed,completeness_issues=inspect_success_log(body,case,profile,args.hot_iterations,
                (root/'tests/gl4es-draw/draw_test.c').read_text())
            expected_stage='texture-recreated' if args.oracle_control=='stale-texture' else 'uniform-green'
            # 校准缺setter不能被编译、驱动、ASan或别的错误当成通过；必须失败于既有独立像素oracle。
            accepted=(code==2 and case=='texture-bindings' and 'FAIL: desktop texture binding query name/width invariant' in body) if args.variant=='without-texture-query' else (code==0 and complete) if args.oracle_control=='none' else (
                code==2 and 'phase='+expected_stage in body and 'FAIL: independent pixel expectation' in body)
            if args.variant=='boolean-delegate-control':
                accepted=case=='boolean-shim-error' and code==2 and 'FAIL: boolean binding preserves pending shim error' in body
            results.append({'case':case,'profile':profile,'configuredOptions':PROFILES[profile],
                'observedOptions':observed,'completenessIssues':completeness_issues,
                'oracleControl':args.oracle_control,'exitCode':code,'accepted':accepted,'log':str(log)})
            print(f'{args.variant}/{profile}: {case}: exit={code} accepted={accepted}',flush=True)
    result = {'variant': args.variant, 'pin': PIN, 'patches': patches, 'cases': results,
              'librarySha256': hashlib.sha256((tree/'lib/libGL.so.1').read_bytes()).hexdigest()}
    (output/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    return 0 if all(row['accepted'] for row in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
