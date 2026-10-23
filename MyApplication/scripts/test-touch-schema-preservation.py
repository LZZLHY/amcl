"""逐字生产函数验证控件差异退休与连滑有效热区，并分别撤回修正作负对照。"""
from pathlib import Path
import sys
# 递归装载既有测试也只产生外置构建结果，禁止 Python 在正式脚本目录落回缓存。
sys.dont_write_bytecode = True
import runpy
import subprocess
from lib.source_host import compile_source_fixture
from lib.workspace_paths import temporary_directory

root = Path(__file__).resolve().parents[1]
# 执行既有生产回归后复用其提取结果；不依赖用户未纳入版本控制的审计目录。
fixture = runpy.run_path(str(root / 'scripts/test-touch-production.py'))
prefix, production = fixture['prefix'], fixture['production']
marker = 'void amcl_fire_haptic(int){}'
assert prefix.count(marker) == 1
prefix = prefix.replace(marker, 'int hapticCalls=0;void amcl_fire_haptic(int){++hapticCalls;}', 1)
template = (root / 'entry/src/main/cpp/tests/host/touch_schema_preservation.cpp.in').read_text(encoding='utf-8')
with temporary_directory(prefix='touch-preservation-') as output:
    source = Path(output) / 'preservation.cpp'
    binary = Path(output) / 'preservation.exe'
    def check(body, negative=False):
        """每个对照均编译实际生产正文；负对照必须在运行时违反合同，编译失败不能冒充捕获缺陷。"""
        source.write_text(template.replace('@FIXTURE@', prefix + body), encoding='utf-8', newline='\n')
        # Source 现由唯一 neutral owner 持有；沿真实 Core/bridge 装配，不能重新建立本地 ledger 替身。
        compile_source_fixture(source, binary, root / 'entry/src/main/cpp')
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
        if negative:
            assert result.returncode != 0 and 'CHECK failed' in result.stderr, result.stdout + result.stderr
        else:
            assert result.returncode == 0, result.stdout + result.stderr
            print(result.stdout.strip())
    check(production)
    for name, before, after in [
        ('feedback retires old binding', 'SameControlSchemaBinding(control, entries[i])',
         'SameControlSchemaEntry(control, entries[i])'),
        ('feedback retires completed menu prefix', 'if (!sameBindings && nativeFingersBefore == 0',
         'if (nativeFingersBefore == 0'),
        ('new DOWN retains old feedback', 'if (wasEmpty) state.control = hit;',
         "if (state.control.id[0] == '\\0') state.control = hit;"),
        ('new swipe retains old feedback', 'if (empty) state.control = hit;',
         "if (state.control.id[0] == '\\0') state.control = hit;"),
        # 生产samePolicy如今包含菜单/tool完成边界；只撤回实际控件差异退休调用，
        # 保持整个生产分支可编译，再由未变控件持有合同抓住“表变化全退”的错误。
        ('UI update retires all', 'schemaRetireChangedControlsLocked(entries, count);',
         'schemaCancelGenerationLocked();'),
        ('swipe ignores hitSlop', 'binding.control.w,binding.control.h,binding.control.hitSlop)',
         'binding.control.w,binding.control.h,0)'),
        ('UP ignores final endpoint', 'endpointValid &&', 'true &&')
    ]:
        assert production.count(before) == 1, name
        changed = production.replace(before, after, 1)
        if name == 'UP ignores final endpoint':
            # 正常UP现在先经过原MOVE归约，那里会按终点取消candidate；Finish中的
            # endpointValid仍是独立兜底。旧缺陷负控必须同时撤回两层终点判定，
            # 不能因只删一个已有冗余保护仍通过，就把可编译负控误记为捕获成功。
            sample = 'ev.type == OH_NATIVEXCOMPONENT_MOVE || normalUp'
            assert changed.count(sample) == 1
            changed = changed.replace(sample, 'ev.type == OH_NATIVEXCOMPONENT_MOVE', 1)
        check(changed, negative=True)
        print('PASS negative control: ' + name)
