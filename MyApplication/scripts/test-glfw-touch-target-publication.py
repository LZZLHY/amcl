"""执行真实GLFW render发布→共享快照→event retain接线，证明三维触控目标保持一致。

窗口/SDK/bridge出口仅作边界替身，发布/复制/退休/retain正文逐字提取；policy使用真实头文件。
负变异必须先编译，再由行为CHECK失败，不能用一份手写发布算法代替生产实现。
"""
from pathlib import Path
import importlib.util
import subprocess
from lib.host_cpp import compile_cpp
from lib.workspace_paths import temporary_directory

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('glfw_target_recipe', ROOT / 'scripts/generate-desktop-review-tests.py')
recipe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipe)
source = (ROOT / 'entry/src/main/cpp/glfw/glfw_compat.cpp').read_text(encoding='utf-8')
start = source.index('struct TypedWindowInputBinding {')
binding_type = source[start:source.index('\n};', start) + len('\n};')]
names = ['publishTypedWindowInputBinding', 'clearTypedWindowInputBinding', 'retainTypedPresentedInputTarget']
production = '\n'.join(recipe.function(source, name) for name in names)
start = source.index('static TypedWindowInputBinding snapshotTypedWindowInputBinding() {')
production += '\n' + recipe.block(source, start)

prefix = r'''
#include "@POLICY@"
#include <atomic>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <shared_mutex>
#include <thread>
#include <vector>
#define CHECK(v) do {if(!(v)){std::cerr<<"CHECK failed "<<__LINE__<<": "<<#v<<'\n';std::exit(1);}} while(0)
struct GLFWwindow {
  void* nativeWindow=reinterpret_cast<void*>(1);
  uint64_t nativeWindowGeneration=77,windowId=42;
  int width=1000,height=800;
  bool auxiliary=false,visible=true,ready=true,contextLostFatal=false;
  struct {uint64_t lifetime=1;} sizeNotifications;
};
@BINDING_TYPE@
static std::shared_mutex g_typedWindowInputBindingMutex;
static TypedWindowInputBinding g_typedWindowInputBinding;
static GLFWwindow* g_currentWindow=nullptr;
struct FakeAdapter {bool consumer=true;bool HasConsumer()const{return consumer;}} g_typedInputAdapter;
void* g_typedInputHost=reinterpret_cast<void*>(1);
struct TargetCall {uint64_t logical,pub,graphics;};
std::vector<TargetCall> targetCalls;
int activeCalls=0,closeCalls=0,reentry=0;
GLFWwindow* replacement=nullptr;
bool isBackendSurfaceReady(const GLFWwindow* window){return window&&window->ready;}
int32_t typedInputAdapterClose(void*){++closeCalls;g_typedInputAdapter.consumer=false;return 0;}
void inputBridge_glfwSetTargetV1(uint64_t,uint64_t,uint64_t);
extern "C" void inputBridge_glfwSetActive(void*,int);
static TypedWindowInputBinding snapshotTypedWindowInputBinding();
'''
boundaries = r'''
// 另一个线程try_lock检测当前调用方是否仍持共享/独占锁，避免同线程递归锁造成未定义行为。
void CheckBridgeRunsOutsideBindingLock(){
  std::atomic<bool> acquired{false};
  std::thread probe([&]{if(g_typedWindowInputBindingMutex.try_lock()){
    acquired=true;g_typedWindowInputBindingMutex.unlock();}});probe.join();
  CHECK(acquired.load());
}
void inputBridge_glfwSetTargetV1(uint64_t logical,uint64_t pub,uint64_t graphics){
  CheckBridgeRunsOutsideBindingLock();targetCalls.push_back({logical,pub,graphics});
}
extern "C" void inputBridge_glfwSetActive(void*,int active){
  CheckBridgeRunsOutsideBindingLock();++activeCalls;
  if(active||!reentry)return;
  const int mode=reentry;reentry=0;
  if(mode==1)g_currentWindow=replacement;
  else {++g_currentWindow->sizeNotifications.lifetime;g_currentWindow->visible=true;}
  publishTypedWindowInputBinding(g_currentWindow,true);
  g_typedInputAdapter.consumer=true; // 只模拟新adapter已创建，不替生产retain作生命周期判断。
}
'''
main = r'''
int main(){
  GLFWwindow a,b;b.nativeWindowGeneration=88;b.windowId=43;b.width=1200;b.height=900;
  g_currentWindow=&a;
  std::thread render([&]{publishTypedWindowInputBinding(&a,true);});render.join();
  CHECK(targetCalls.empty()&&activeCalls==0); // render只发布，不跨线程调用event bridge setter。
  auto frozen=snapshotTypedWindowInputBinding();
  CHECK(frozen.window==&a&&frozen.generation==77&&frozen.graphicsWindowId==42&&frozen.widthPx==1000&&frozen.heightPx==800&&frozen.active);
  a.nativeWindowGeneration=999; // 渲染字段已变化但尚未发布，event线程必须继续使用旧完整快照。
  CHECK(retainTypedPresentedInputTarget());
  CHECK(targetCalls.back().logical==reinterpret_cast<uint64_t>(&a)&&targetCalls.back().pub==77&&targetCalls.back().graphics==42);
  CHECK(retainTypedPresentedInputTarget());
  CHECK(targetCalls[targetCalls.size()-2].pub==targetCalls.back().pub&&targetCalls[targetCalls.size()-2].graphics==targetCalls.back().graphics);
  clearTypedWindowInputBinding(&b);CHECK(snapshotTypedWindowInputBinding().window==&a);
  publishTypedWindowInputBinding(&b,true);CHECK(!retainTypedPresentedInputTarget());
  CHECK(targetCalls.back().logical==0&&targetCalls.back().pub==0&&targetCalls.back().graphics==0);
  g_currentWindow=&b;g_typedInputAdapter.consumer=true;CHECK(retainTypedPresentedInputTarget());
  CHECK(targetCalls.back().logical==reinterpret_cast<uint64_t>(&b)&&targetCalls.back().pub==88&&targetCalls.back().graphics==43);
  // publisher在完整快照里拒绝Native空值/零代次/零尺寸/失活；缺少binding不能借窗口存在取得资格。
  for(int invalid=0;invalid<5;++invalid){
    GLFWwindow bad;g_currentWindow=&bad;g_typedInputAdapter.consumer=true;
    if(invalid==0)bad.nativeWindow=nullptr;if(invalid==1)bad.nativeWindowGeneration=0;
    if(invalid==2)bad.width=0;if(invalid==3)bad.height=0;
    publishTypedWindowInputBinding(&bad,invalid!=4);CHECK(!snapshotTypedWindowInputBinding().active);
    CHECK(!retainTypedPresentedInputTarget()&&targetCalls.back().logical==0);
  }
  // 即使binding已发布，真正的呈现policy还要独立拒绝auxiliary/hidden/surfaceLost/terminal。
  for(int invalid=0;invalid<4;++invalid){
    GLFWwindow bad;g_currentWindow=&bad;g_typedInputAdapter.consumer=true;
    if(invalid==0)bad.auxiliary=true;if(invalid==1)bad.visible=false;
    if(invalid==2)bad.ready=false;if(invalid==3)bad.contextLostFatal=true;
    publishTypedWindowInputBinding(&bad,true);const int before=closeCalls;
    CHECK(!retainTypedPresentedInputTarget()&&closeCalls==before+1&&targetCalls.back().logical==0);
  }
  // 失活回调同步destroy/replace：新adapter不能被外层旧retain关闭；同址重建由lifetime阻止ABA。
  for(int mode:{1,2}){
    a.visible=false;g_currentWindow=&a;replacement=&b;g_typedInputAdapter.consumer=true;
    publishTypedWindowInputBinding(&a,true);reentry=mode;const int before=closeCalls;
    CHECK(!retainTypedPresentedInputTarget()&&g_typedInputAdapter.consumer&&closeCalls==before);
  }
  // 两个真实publisher竞争，snapshot必须复制来自同一window的完整元组，而非拆字段取“最新”。
  a.visible=true;a.nativeWindowGeneration=77;publishTypedWindowInputBinding(&a,true);
  std::atomic<bool> running{true};
  std::thread publisher([&]{for(int i=0;i<500;++i)publishTypedWindowInputBinding(i%2?&a:&b,true);running=false;});
  do{const auto value=snapshotTypedWindowInputBinding();
    CHECK(value.active&&((value.window==&a&&value.generation==77&&value.graphicsWindowId==42&&value.widthPx==1000)||
      (value.window==&b&&value.generation==88&&value.graphicsWindowId==43&&value.widthPx==1200)));
  }while(running.load());publisher.join();
  clearTypedWindowInputBinding(nullptr);CHECK(!snapshotTypedWindowInputBinding().active);
  std::cout<<"PASS GLFW production target publication: frozen tuple, policy, lock-free bridge, reentry lifetime and concurrent snapshot\n";
}
'''
with temporary_directory(prefix='glfw-touch-target-') as directory:
    path, binary = Path(directory) / 'target.cpp', Path(directory) / 'target.exe'
    def check(body, negative=False):
        path.write_text(prefix.replace('@POLICY@', (ROOT / 'entry/src/main/cpp/input/adapters/glfw_backend_lifecycle.h').as_posix())
                        .replace('@BINDING_TYPE@', binding_type) + body + boundaries + main, encoding='utf-8')
        compile_cpp(path, binary)
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
        if negative:
            assert result.returncode != 0 and 'CHECK failed' in result.stderr, result.stdout + result.stderr
        else:
            assert result.returncode == 0, result.stdout + result.stderr
            print(result.stdout.strip())
    check(production)
    for name, before, after in [
        ('event reads unpublished render field', 'published.generation, published.graphicsWindowId', 'window->nativeWindowGeneration, published.graphicsWindowId'),
        ('binding loses actual WSI id', 'static_cast<uint32_t>(window->height), true, window->windowId};', 'static_cast<uint32_t>(window->height), true, 0u};'),
        ('render publisher calls event setter under unique lock',
         'g_typedWindowInputBinding = {\n        window, window->nativeWindowGeneration,',
         'inputBridge_glfwSetTargetV1(reinterpret_cast<uint64_t>(window),window->nativeWindowGeneration,window->windowId);g_typedWindowInputBinding = {\n        window, window->nativeWindowGeneration,'),
        ('event bridge runs under shared binding lock', 'const TypedWindowInputBinding published = snapshotTypedWindowInputBinding();', 'std::shared_lock<std::shared_mutex> wrongLock(g_typedWindowInputBindingMutex);const TypedWindowInputBinding published=g_typedWindowInputBinding;'),
    ]:
        assert production.count(before) == 1, name
        check(production.replace(before, after, 1), True)
        print('PASS negative control: ' + name)
