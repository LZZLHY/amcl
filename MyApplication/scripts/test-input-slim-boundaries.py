"""轻量输入边界回归：提取生产函数，只替换平台API；成功回收自己的编译夹具，保留小收据。"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from lib.host_cpp import compile_cpp
from lib.workspace_paths import external_output_path, temporary_directory

ROOT = Path(__file__).resolve().parents[1]
CPP = ROOT / 'entry/src/main/cpp'

def function(source, signature):
    """按唯一函数签名取得原正文；本组函数不含字符串大括号，防止把前置声明当实现。"""
    begin = source.index(signature)
    opening = source.index('{', begin)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[begin:end]

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out', required=True)
args = parser.parse_args()
out = external_output_path(args.out)
out.mkdir(parents=True, exist_ok=True)
cursor = (CPP/'platform/cursor_lock.cpp').read_text(encoding='utf-8')
gamepad = (CPP/'platform/desktop_gamepad.cpp').read_text(encoding='utf-8')
glfw = (CPP/'glfw/glfw_callbacks.cpp').read_text(encoding='utf-8')
body = (CPP/'tests/host/input_slim_boundaries.cpp.in').read_text(encoding='utf-8')
body = body.replace('@CPP@', CPP.as_posix()).replace('@CURSOR@', '\n'.join(function(cursor,s) for s in [
    'AmclCursorLockResult ReleaseCursorLocked(', 'extern "C" AmclCursorLockResult amcl_cursor_lock_set(',
    'extern "C" void amcl_cursor_lock_note_focus_lost(']))
body = body.replace('@GAMEPAD@', '\n'.join(function(gamepad, s) for s in [
    'int Find(', 'void PublishGamepadChange(', 'void Neutral(', 'bool UpdateGamepadConnection(', 'void ApplyGamepadButton(', 'void ApplyGamepadAxis(',
    'bool SetNativeGamepadMode(', 'void SetGamepadFocus(', 'int ReadGamepadTopology(', 'int ReadGamepadChanges(', 'int32_t amclGamepadRead(',
    'int ReadGamepad(']))
body = body.replace('@GAMEPAD_READER@', function(glfw, 'static AmclGamepadReadFn gamepadReader('))
# 直接编译游戏调用的 GLFW 公共接口与实际结构，平台读端使用同一生产快照。
glfw_header = (CPP/'glfw/glfw_compat.h').read_text(encoding='utf-8')
start = glfw_header.index('typedef struct GLFWgamepadstate {')
gamepad_type = glfw_header[start:glfw_header.index('} GLFWgamepadstate;',start)+len('} GLFWgamepadstate;')]
public_queries = ['static bool readGamepad(', 'int glfwJoystickPresent(', 'const float* glfwGetJoystickAxes(',
                  'const unsigned char* glfwGetJoystickButtons(', 'const unsigned char* glfwGetJoystickHats(',
                  'const char* glfwGetJoystickName(', 'const char* glfwGetJoystickGUID(', 'int glfwJoystickIsGamepad(',
                  'const char* glfwGetGamepadName(', 'int glfwGetGamepadState(']
body = body.replace('@GLFW_PAD_QUERIES@', gamepad_type+'\n'+'\n'.join(function(glfw,s) for s in public_queries))
body = body.replace('@GAMEPAD_POLL@', function(glfw, 'void glfwOHOS_PollGamepads('))
with temporary_directory(prefix='input-slim-boundaries-') as fixture:
    source = Path(fixture)/'boundary.cpp'
    source.write_text(body,encoding='utf-8')
    binary = Path(fixture)/'boundary.exe'
    try:
        compile_cpp(source,binary,includes=[CPP/'tests/host/stubs'])
    except Exception:
        (out/'failed-fixture.cpp').write_text(body,encoding='utf-8')
        raise
    result = subprocess.run([str(binary)],capture_output=True,text=True)
    (out/'result.log').write_text(result.stdout+result.stderr,encoding='utf-8')
    print(result.stdout+result.stderr)
    if result.returncode:
        (out/'failed-fixture.cpp').write_text(body,encoding='utf-8')
        raise RuntimeError('input boundary regression failed; minimal fixture preserved')
(out/'receipt.json').write_text(json.dumps({'passed':True,'fixtureSha256':hashlib.sha256(body.encode()).hexdigest(),
    'scope':'production boundary code; no device/performance qualification','generatedFixtureReclaimed':True},indent=2),encoding='utf-8')
