#!/usr/bin/env python3
"""从受控补丁提取新增的真实数学头，编译并执行边界测试；便宜门禁不冒充完整 GLES 验收。"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def main():
    """Linux 使用系统 CC；Windows 使用已安装的 LLVM 生成无 CRT 依赖的本机测试程序。"""
    root=Path(__file__).resolve().parents[1]
    patch=(root/'prebuilt/gl4es/patches/0003-draw-submission-lifetime-and-wide-indices.patch').read_text()
    match=re.search(r'diff --git a/src/gl/draw_math.h b/src/gl/draw_math.h\n(.*?)(?=\ndiff --git |\Z)',patch,re.S)
    if not match: raise ValueError('Production draw_math.h is missing from controlled patch')
    header='\n'.join(line[1:] for line in match[1].splitlines() if line.startswith('+') and not line.startswith('+++'))+'\n'
    compiler=os.environ.get('AMCL_HOST_CC') or shutil.which('clang') or shutil.which('cc')
    if os.name=='nt' and not compiler:
        tools=next((parent/'.codex/harmonyos-toolchain.json' for parent in root.parents if (parent/'.codex/harmonyos-toolchain.json').is_file()), root.parent/'.codex/harmonyos-toolchain.json')
        if tools.is_file():
            import json
            config=json.loads(tools.read_text(encoding='utf-8-sig'))
            candidate=Path(config['sdk'])/'default/openharmony/native/llvm/bin/clang.exe'
            if candidate.is_file(): compiler=str(candidate)
    if not compiler: raise RuntimeError('Host C compiler required for real production integer tests')
    # 独立公开克隆使用系统临时目录；维护者可显式指定外置任务容器。
    parent=os.environ.get('AMCL_GL4ES_TEST_OUTPUT')
    if not parent:
        sys.dont_write_bytecode=True
        sys.path.insert(0,str(root/'scripts/lib'))
        from workspace_paths import workspace_path
        parent=workspace_path('run','gl4es-math')
        Path(parent).mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='amcl-gl4es-math-',dir=parent) as directory:
        directory=Path(directory); (directory/'draw_math.h').write_text(header)
        executable=directory/('math-test.exe' if os.name=='nt' else 'math-test')
        command=[compiler,'-std=c11','-O1','-I'+str(directory),str(root/'tests/gl4es-draw/math_test.c'),'-o',str(executable)]
        if os.name=='nt': command[1:1]=['-Dmain=amcl_math_entry','-ffreestanding','-fno-stack-protector','-nostdlib','-fuse-ld=lld','-Wl,--entry=amcl_math_entry','-Wl,--subsystem,console']
        subprocess.run(command,check=True)
        subprocess.run([str(executable)],check=True)
    print('PASS production gl4es integer rules: widening, modulo, negative base, EBO and vertex bounds')
    return 0


if __name__=='__main__': sys.exit(main())
