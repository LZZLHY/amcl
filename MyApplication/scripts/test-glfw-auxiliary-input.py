"""逐字执行GLFW生产输入setter，验证辅助窗口不修改呈现owner；系统桥仅记录实际调用。"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import importlib.util
import os
import subprocess
import sys
import tempfile
root = Path(__file__).resolve().parent.parent
if os.name == 'nt':
    source = subprocess.check_output(['wsl', '-d', 'Ubuntu', '--exec', 'wslpath', '-a', Path(__file__).resolve().as_posix()], text=True).strip()
    subprocess.run(['wsl', '-d', 'Ubuntu', '--exec', 'python3', source], check=True, timeout=120)
    sys.exit(0)
spec = importlib.util.spec_from_file_location('recipe', root/'scripts/generate-desktop-review-tests.py')
recipe = importlib.util.module_from_spec(spec); spec.loader.exec_module(recipe)
callbacks = (root/'entry/src/main/cpp/glfw/glfw_callbacks.cpp').read_text(encoding='utf-8')
functions = []
for signature in ['GLFWcharfun glfwSetCharCallback', 'GLFWcharmodsfun glfwSetCharModsCallback',
    'GLFWcursorenterfun glfwSetCursorEnterCallback', 'void glfwSetInputMode', 'int glfwGetInputMode', 'void glfwSetCursorPos',
    'void glfwSetWindowMonitor']:
    functions.append(recipe.block(callbacks, callbacks.index(signature+'(')))
with workspace_temporary_directory(prefix='amcl-aux-input-') as temp:
    file = Path(temp)/'test.cpp'
    prefix = '#include "'+(root/'entry/src/main/cpp/glfw/glfw_compat.h').as_posix()+'"\n'
    prefix += '#include "'+(root/'entry/src/main/cpp/input/adapters/glfw_backend_lifecycle.h').as_posix()+'"\n'
    file.write_text(prefix+r'''
#include <cassert>
#include <iostream>
#define OH_LOG_INFO(...) ((void)0)
struct GLFWwindow {
    bool auxiliary=false, cursorModeAssigned=false; int cursorMode=GLFW_CURSOR_NORMAL; double cursorX=0,cursorY=0;
    amcl::input::GlfwBackendCaptureState inputCapture{};
    GLFWcharfun charCb=nullptr; GLFWcharmodsfun charModsCb=nullptr; GLFWcursorenterfun cursorEnterCb=nullptr;
    bool charCallbackAssigned=false,charModsCallbackAssigned=false,cursorEnterCallbackAssigned=false;
};
GLFWwindow* g_currentWindow=nullptr;
GLFWerrorfun g_errorCallback=nullptr;
struct GLFWmonitor { uint64_t desktopId=1; };
enum { AMCL_DESKTOP_FULLSCREEN=1, AMCL_DESKTOP_MOVE=2, AMCL_DESKTOP_RESIZE=3 };
int promotionCalls=0, systemCommands=0, errors=0;
bool promotionAllowed=true;
// 这里只记录跨到窗口事务/系统服务边界的请求；真实promotion事务另由设备与资源核心验收。
bool glfwOHOS_PromoteWindow(GLFWwindow* value){++promotionCalls;if(!promotionAllowed)return false;value->auxiliary=false;return true;}
bool desktopCommand(int,int=0,int=0,int=0,int=0){++systemCommands;return true;}
int g_cursorMode=GLFW_CURSOR_NORMAL, bridgeWrites=0, envWrites=0, lookWrites=0;
void* character=nullptr; void* characterMods=nullptr; void* cursorEnter=nullptr;
void* inputBridge_replaceCharCallback(void* value){auto old=character;character=value;++bridgeWrites;return old;}
void* inputBridge_replaceCharModsCallback(void* value){auto old=characterMods;characterMods=value;++bridgeWrites;return old;}
void* inputBridge_replaceCursorEnterCallback(void* value){auto old=cursorEnter;cursorEnter=value;++bridgeWrites;return old;}
void inputBridge_setGrabState(int){++bridgeWrites;}
void inputBridge_setLookCursor(double,double){++lookWrites;}
bool api26RawMouseMotionSupported(){return true;}
int SetTestEnvironment(const char*,const char*,int){++envWrites;return 0;}
#define setenv SetTestEnvironment
void callbackA(GLFWwindow*,unsigned){} void callbackB(GLFWwindow*,unsigned){}
void modsA(GLFWwindow*,unsigned,int){} void modsB(GLFWwindow*,unsigned,int){}
void enterA(GLFWwindow*,int){} void enterB(GLFWwindow*,int){}
'''+'\n'.join(functions)+r'''
int main(){
    g_errorCallback=[](int,const char*){++errors;};
    GLFWwindow hidden; hidden.auxiliary=true; GLFWmonitor monitor;
    glfwSetWindowMonitor(&hidden,nullptr,0,0,640,480,60);
    assert(!errors && !promotionCalls && !systemCommands && hidden.auxiliary);
    glfwSetWindowMonitor(&hidden,&monitor,0,0,640,480,60);
    assert(!errors && promotionCalls==1 && systemCommands==1 && !hidden.auxiliary);
    hidden.auxiliary=true; promotionAllowed=false;
    glfwSetWindowMonitor(&hidden,&monitor,0,0,640,480,60);
    assert(promotionCalls==2 && systemCommands==1 && hidden.auxiliary);
    GLFWwindow presented, auxiliary; auxiliary.auxiliary=true; g_currentWindow=&presented;
    assert(!glfwSetCharCallback(&presented,callbackA)); glfwSetCharModsCallback(&presented,modsA); glfwSetCursorEnterCallback(&presented,enterA);
    assert(bridgeWrites==3);
    assert(!glfwSetCharCallback(&auxiliary,callbackB)); glfwSetCharModsCallback(&auxiliary,modsB); glfwSetCursorEnterCallback(&auxiliary,enterB);
    glfwSetInputMode(&auxiliary,GLFW_CURSOR,GLFW_CURSOR_DISABLED); glfwSetCursorPos(&auxiliary,12,34);
    assert(bridgeWrites==3 && !envWrites && !lookWrites && character==reinterpret_cast<void*>(callbackA));
    assert(glfwGetInputMode(&auxiliary,GLFW_CURSOR)==GLFW_CURSOR_DISABLED && glfwGetInputMode(&presented,GLFW_CURSOR)==GLFW_CURSOR_NORMAL);
    assert(auxiliary.cursorX==12 && auxiliary.cursorY==34 && !auxiliary.inputCapture.requested);
    glfwSetInputMode(&presented,GLFW_CURSOR,GLFW_CURSOR_DISABLED); glfwSetCursorPos(&presented,2,3);
    assert(envWrites==1 && lookWrites==1 && presented.inputCapture.requested && bridgeWrites==4);
    // 调用实际promotion所用setter组合：取得呈现权后才发布隐藏阶段保存的callback/grab。
    g_currentWindow=&auxiliary; auxiliary.auxiliary=false;
    glfwSetCharCallback(&auxiliary,auxiliary.charCb); glfwSetCharModsCallback(&auxiliary,auxiliary.charModsCb);
    glfwSetCursorEnterCallback(&auxiliary,auxiliary.cursorEnterCb); glfwSetInputMode(&auxiliary,GLFW_CURSOR,auxiliary.cursorMode);
    assert(character==reinterpret_cast<void*>(callbackB) && characterMods==reinterpret_cast<void*>(modsB) && cursorEnter==reinterpret_cast<void*>(enterB));
    assert(auxiliary.inputCapture.requested && envWrites==2);
    std::cout<<"GLFW production input setters PASS: per-window callbacks/cursor intent, no auxiliary input authority, promotion publication\n";
}
''', encoding='utf-8')
    binary = str(Path(temp)/'test')
    subprocess.run(['g++','-std=c++17','-Wall','-Wextra',str(file),'-o',binary],check=True,timeout=60)
    subprocess.run([binary],check=True,timeout=10)
