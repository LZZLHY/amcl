"""验证Native触控UP末样、晚派发终止与退役手势隔离；只装配现有生产fixture。"""
from pathlib import Path
import argparse
import runpy
import subprocess
import sys

sys.dont_write_bytecode = True
from lib.source_host import compile_source_fixture
from lib.workspace_paths import external_output_path, workspace_path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', help='仓库外证据/定向宿主编译目录')
args = parser.parse_args()
output = external_output_path(args.output) if args.output else workspace_path('run', 'touch-terminal')
output.mkdir(parents=True, exist_ok=True)
# 显式recipe模式只取得既有真实生产定义和Source/Core/bridge装配；本脚本执行自己的
# 行为合同及两个可编译撤回负控，不声称已代跑其它脚本的完整旧main。
fixture = runpy.run_path(str(root / 'scripts/test-touch-production.py'),
    init_globals={'AMCL_TOUCH_RECIPE_ONLY': True})
template = (root / 'entry/src/main/cpp/tests/host/touch_terminal_samples.cpp.in').read_text(encoding='utf-8')
visual = fixture['definition']('extern "C" void ohos_touch_interaction_visual(')
production = fixture['production']
source = output / 'terminal.cpp'
binary = output / 'terminal.exe'


def check(body, visual_body, name, expected_failure=''):
    """负控必须真实编译成功，再命中指定行为断言；保留每轮实际退出结果与输出。"""
    source.write_text(template.replace('@FIXTURE@', fixture['prefix'] + body)
                      .replace('@VISUAL@', visual_body), encoding='utf-8', newline='\n')
    compile_source_fixture(source, binary, root / 'entry/src/main/cpp')
    result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=30)
    text = result.stdout + result.stderr
    (output / (name + '.log')).write_text(text, encoding='utf-8')
    if expected_failure:
        assert result.returncode != 0 and expected_failure in text, text
        print('PASS compiled negative: ' + name)
    else:
        assert result.returncode == 0, text
        print(text.strip())


check(production, visual, 'positive')
# 去掉正常UP末段时，首个世界视角断言必须抓住回归。
before = 'ev.type == OH_NATIVEXCOMPONENT_MOVE || normalUp'
assert production.count(before) == 1
check(production.replace(before, 'ev.type == OH_NATIVEXCOMPONENT_MOVE', 1), visual,
      'negative-up', 'looks==1&&lookX==60&&lookY==20')
# 恢复入口先按派发now轮询时，期限前发生的晚派发CANCEL必须暴露新增按下。
before = 'SchemaFingerBinding& binding = s_schemaFingers[fid];'
assert production.count(before) == 1
old_poll = 'schemaPollLongPressLocked();schemaPollTouchHoldsLocked();\n' + before
check(production.replace(before, old_poll, 1), visual,
      'negative-cancel', 'count(OutputKind::Key,65,1)==0&&ledger.ownerCount()==0')
# 最终恢复的源码、可执行文件和日志对应生产正例，避免交付末轮仍为负控的产物。
check(production, visual, 'restored')
