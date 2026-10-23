"""编译真实production冷态publisher正文，验证缺值/封存/已加载/真实写入边界。"""
from pathlib import Path
import importlib.util,subprocess,os
from lib.workspace_paths import temporary_directory
from lib.host_cpp import compile_cpp
root=Path(__file__).resolve().parents[1]
# publisher为实际POSIX/OHOS getenv/setenv合同；Windows没有该libc入口，明确
# 通过固定WSL跑同一生产正文，不能用MSVC或伪环境模型冒充已测。
if os.name=='nt':
    path=subprocess.check_output(['wsl','-d','Ubuntu','--exec','wslpath','-u',str(Path(__file__).resolve())],text=True).strip()
    raise SystemExit(subprocess.run(['wsl','-d','Ubuntu','--exec','python3',path],timeout=90).returncode)
spec=importlib.util.spec_from_file_location('source_recipe',root/'scripts/generate-desktop-review-tests.py')
recipe=importlib.util.module_from_spec(spec);spec.loader.exec_module(recipe)
source=(root/'entry/src/main/cpp/platform/mobilegl_capability_driver.cpp').read_text(encoding='utf-8')
body=recipe.function(source,'PublishMobileGlDirectVulkanBeforeLoad')
template=(root/'entry/src/main/cpp/tests/host/mobilegl_cold_publication_test.cpp.in').read_text(encoding='utf-8')
with temporary_directory(prefix='mobilegl-cold-pub-') as directory:
    cpp=Path(directory)/'test.cpp';binary=Path(directory)/('test.exe'if os.name=='nt'else'test')
    cpp.write_text(template.replace('@PUBLISHER@',body),encoding='utf-8')
    compile_cpp(cpp,binary);subprocess.run([str(binary)],check=True,timeout=30)
    # 原缺少shared publisher的行为真实等价于没有发布：同一缺值判据必须失败。
    old=body[:body.index('{')+1]+' return true; }'
    cpp.write_text(template.replace('@PUBLISHER@',old),encoding='utf-8')
    compile_cpp(cpp,binary);result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30)
    if result.returncode==0 or 'missing-value-before-load-published'not in result.stderr:raise RuntimeError('old missing-publication control unexpectedly passed')
    print('PASS old missing-publication behavior rejected by the same actual environment assertion')
