"""执行实际菜单工具NAPI入口，验证publication、真实panel prefix和取消/UP的不同准入。

SDK值/窗口mode/Native出口仅作边界；正文及UTF8/uint64解析使用当前产品源码。
Native canonical prefix与watermark由另一个真实producer套件验证，此处不复制其仲裁算法。
"""
from pathlib import Path
import ast
import hashlib
import importlib.util
import json
import subprocess
from lib.host_cpp import compile_cpp
from lib.workspace_paths import temporary_directory, workspace_path

ROOT = Path(__file__).resolve().parents[1]
CPP = ROOT / 'entry/src/main/cpp'
spec = importlib.util.spec_from_file_location('menu_napi_extract', ROOT / 'scripts/generate-desktop-review-tests.py')
recipe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipe)
napi = (CPP / 'napi/napi_input.cpp').read_text(encoding='utf-8')

# 复用已验证的SDK Value环境，直接求值该夹具PREFIX声明，不重新执行其整个schema套件。
# 此处只共享边界替身，不读取/生成任何产品行为模型或正式认知索引。
schema_ast = ast.parse((ROOT / 'scripts/test-touch-schema-napi.py').read_text(encoding='utf-8'))
prefix_node = next(node.value for node in schema_ast.body if isinstance(node, ast.Assign)
                   and any(isinstance(target, ast.Name) and target.id == 'PREFIX' for target in node.targets))
prefix = eval(compile(ast.Expression(prefix_node), '<schema SDK PREFIX>', 'eval'), {'CPP': CPP})

def definition(signature):
    import re
    match = re.search(re.escape(signature) + r'[^;{]*\{', napi)
    assert match, signature
    return recipe.block(napi, match.start())

production = '\n'.join(definition(name) for name in ['bool ReadBoundedUtf8String(', 'bool ReadTouchIdentity(',
    'static napi_value MoveTouchMenuPointer(', 'static napi_value SetTouchOverlayBounds(',
    'static napi_value SetTouchMenuMouseBounds(', 'static napi_value TouchMenuButton(',
    'static napi_value CancelTouchMenuMouse(', 'static napi_value TouchMenuScroll('])
prefix += r'''
#include <limits>
'''+ '\n#include "'+(CPP/'platform/touch_publication_state.h').as_posix()+'"\n'+r'''
bool gateReady=true,modeReady=true,grabbed=false,nativeAccept=true;
amcl::input::TouchPublicationState uiState;amcl::input::TouchPublicationContext uiContext;uint64_t issued=0;
void resetUi(){uiState=amcl::input::TouchPublicationState{};uiContext={};uiContext.surface=7;uiContext.session=3;
 auto pending=uiState.Begin("initial-ui","layout",uiContext,uiContext);uiState.Complete(uiContext,false);
 if(!uiState.Confirm("initial-ui",pending.token,uiContext))std::abort();issued=pending.token;}
int moveCalls=0,scrollCalls=0,panelCalls=0,geometryCalls=0,cancelCalls=0,buttonCalls=0;
std::string forwardedPrefix;uint64_t forwardedToken=0;double forwardedDx=0,forwardedDy=0;int forwardedSteps=0;
namespace amcl::napi {napi_value MakeBoolResult(napi_env,bool b){return boolean(b);}}
int napi_get_value_int32(napi_env,napi_value v,int32_t* out){
    if(!v||v->type!=napi_number||!std::isfinite(v->number)||v->number<INT32_MIN||v->number>INT32_MAX)return napi_invalid_arg;
    *out=static_cast<int32_t>(v->number);return napi_ok;
}
namespace amcl::input {
class SurfaceInputGateTransaction {public:explicit operator bool()const{return gateReady;}};
class AuthoritativeGrabInputTransaction {bool available;public:explicit AuthoritativeGrabInputTransaction(bool gate):available(gate&&modeReady){}
    explicit operator bool()const{return available;}bool grabbed()const{return ::grabbed;}};
// 两种资格都用真实State，SDK gate/mode仍是受控平台事实，不能用uiReady布尔替代pending/commit证明。
bool AcceptTouchUiPublication(uint64_t token){uiState.Query(uiContext);return uiState.AcceptsUiToken(token);}
bool AcceptTouchUiContinuation(uint64_t token){uiState.Query(uiContext);return uiState.AcceptsUiContinuation(token,uiContext);}
bool OwnsTouchUiPublicationToken(uint64_t token){const auto receipt=uiState.Query(uiContext);return token!=0&&token==receipt.token&&receipt.context.surface!=0&&
 (receipt.status==TouchPublicationStatus::Committed||receipt.status==TouchPublicationStatus::Unchanged||(receipt.status==TouchPublicationStatus::Idle&&!receipt.fenced));}
}
// Native边界只记录参数及可编程结果；真实prefix注册/旧实例拒绝另执行touch_input生产函数。
bool ohos_move_touch_menu_pointer(double dx,double dy,const char* prefix,uint64_t token){++moveCalls;forwardedPrefix=prefix;forwardedDx=dx;forwardedDy=dy;forwardedToken=token;return nativeAccept;}
bool ohos_touch_menu_scroll(int steps,const char* prefix,uint64_t token){++scrollCalls;forwardedPrefix=prefix;forwardedSteps=steps;forwardedToken=token;return nativeAccept;}
bool ohos_set_menu_mouse_bounds(double,double,double,double){++geometryCalls;return nativeAccept;}
bool ohos_set_menu_mouse_bounds_for_panel(double,double,double,double,const char* prefix,uint64_t token){++panelCalls;forwardedPrefix=prefix;forwardedToken=token;return nativeAccept;}
bool ohos_cancel_touch_menu_mouse(const char* prefix){++cancelCalls;forwardedPrefix=prefix;return nativeAccept;}
bool ohos_touch_menu_button(const char* id,int,bool,uint64_t token){++buttonCalls;forwardedPrefix=id;forwardedToken=token;return nativeAccept;}
'''
main = r'''
bool result(napi_value value){return value&&value->type==napi_boolean&&value->boolean;}
int main(){
    resetUi();uint64_t parsed=0;
    CHECK(ReadTouchIdentity(nullptr,text("9007199254740993"),&parsed)&&parsed==9007199254740993ULL);
    const auto token=text(std::to_string(issued)),prefix=text("mouse-panel-2"),oldToken=text("1");
    Call move{{number(12),number(-34),token,prefix}};
    CHECK(result(MoveTouchMenuPointer(nullptr,&move))&&moveCalls==1&&forwardedPrefix=="mouse-panel-2"&&forwardedDx==12&&forwardedDy==-34&&forwardedToken==issued);
    Call missingMove{{number(12),number(-34),token}};CHECK(!result(MoveTouchMenuPointer(nullptr,&missingMove))&&moveCalls==1);
    for(auto invalid:{oldToken,number(static_cast<double>(issued)),text("0"),text("-1"),text("18446744073709551616")}){
        auto bad=move;bad.args[2]=invalid;CHECK(!result(MoveTouchMenuPointer(nullptr,&bad))&&moveCalls==1);
    }
    // 无prefix、NUL和超长输入在NAPI拒绝；合法旧prefix由Native最终认领后返回明确失败。
    for(auto invalid:{text(""),text(std::string("mouse-panel-2\0old",17)),text(std::string(193,'x')),number(2)}){
        auto bad=move;bad.args[3]=invalid;CHECK(!result(MoveTouchMenuPointer(nullptr,&bad))&&moveCalls==1);
    }
    grabbed=true;CHECK(!result(MoveTouchMenuPointer(nullptr,&move))&&moveCalls==1);grabbed=false;
    gateReady=false;CHECK(!result(MoveTouchMenuPointer(nullptr,&move))&&moveCalls==1);gateReady=true;
    modeReady=false;CHECK(!result(MoveTouchMenuPointer(nullptr,&move))&&moveCalls==1);modeReady=true;
    uiContext.surface=8;CHECK(!result(MoveTouchMenuPointer(nullptr,&move))&&moveCalls==1);resetUi();
    nativeAccept=false;CHECK(!result(MoveTouchMenuPointer(nullptr,&move))&&moveCalls==2);nativeAccept=true;

    Call wheel{{number(3),token,prefix}};CHECK(result(TouchMenuScroll(nullptr,&wheel))&&scrollCalls==1&&forwardedSteps==3&&forwardedPrefix=="mouse-panel-2"&&forwardedToken==issued);
    Call missingWheel{{number(3),token}};CHECK(!result(TouchMenuScroll(nullptr,&missingWheel))&&scrollCalls==1);
    auto badWheel=wheel;badWheel.args[2]=text("");CHECK(!result(TouchMenuScroll(nullptr,&badWheel))&&scrollCalls==1);
    grabbed=true;CHECK(!result(TouchMenuScroll(nullptr,&wheel))&&scrollCalls==1);grabbed=false;
    uiContext.surface=8;CHECK(!result(TouchMenuScroll(nullptr,&wheel))&&scrollCalls==1);resetUi();

    Call panel{{number(1),number(2),number(300),number(200),token,prefix}};
    CHECK(result(SetTouchMenuMouseBounds(nullptr,&panel))&&panelCalls==1&&forwardedToken==issued&&forwardedPrefix=="mouse-panel-2");
    Call legacy{{number(1),number(2),number(300),number(200),token}};
    CHECK(result(SetTouchMenuMouseBounds(nullptr,&legacy))&&geometryCalls==1&&panelCalls==1);
    // owned几何更新允许publication尚未确认；move/wheel的accept资格与之分别验证。
    uiState.Begin("unconfirmed","new-layout",uiContext,uiContext);uiState.Complete(uiContext,true);
    CHECK(!result(SetTouchMenuMouseBounds(nullptr,&panel))&&panelCalls==1);
    auto newPanel=panel;newPanel.args[4]=text(std::to_string(uiState.Query(uiContext).token));
    CHECK(result(SetTouchMenuMouseBounds(nullptr,&newPanel))&&panelCalls==2);resetUi();
    uiContext.surface=8;CHECK(!result(SetTouchMenuMouseBounds(nullptr,&panel))&&panelCalls==2);resetUi();
    auto badPanel=panel;badPanel.args[5]=text("");CHECK(!result(SetTouchMenuMouseBounds(nullptr,&badPanel))&&panelCalls==2);

    Call cancel{{prefix}};uiState.Begin("cancel-fence","new-layout",uiContext,uiContext);gateReady=false;grabbed=true;
    CHECK(result(CancelTouchMenuMouse(nullptr,&cancel))&&cancelCalls==1&&forwardedPrefix=="mouse-panel-2");
    Call missingCancel{{}};CHECK(!result(CancelTouchMenuMouse(nullptr,&missingCancel))&&cancelCalls==1);
    Call emptyCancel{{text("")}};CHECK(!result(CancelTouchMenuMouse(nullptr,&emptyCancel))&&cancelCalls==1);
    nativeAccept=false;CHECK(!result(CancelTouchMenuMouse(nullptr,&cancel))&&cancelCalls==2);nativeAccept=true;
    // 正常UP仍只释放自己的id，不要求当前publication；取消必须走独立Native取消口。
    Call up{{text("mouse-panel-2:contact-1"),number(-1),boolean(false)}};
    CHECK(result(TouchMenuButton(nullptr,&up))&&buttonCalls==1&&cancelCalls==2&&forwardedToken==0);
    Call down{{text("mouse-panel-2:contact-2"),number(-1),boolean(true),token}};
    CHECK(!result(TouchMenuButton(nullptr,&down))&&buttonCalls==1);
    resetUi();gateReady=true;grabbed=false;CHECK(result(TouchMenuButton(nullptr,&down))&&buttonCalls==2&&forwardedToken==issued);
    // 旧confirmed UI的真实等待期间MOVE/wheel可继续，动态NativeTouches不属于身份，NEW DOWN/注册仍关。
    uiContext.nativeTouches=1;const auto pending=uiState.Begin("waiting-contact","pending-layout",uiContext,uiContext);
    CHECK(pending.status==amcl::input::TouchPublicationStatus::Waiting);
    const int movesBefore=moveCalls,scrollBefore=scrollCalls,buttonsBefore=buttonCalls,panelsBefore=panelCalls;
    CHECK(result(MoveTouchMenuPointer(nullptr,&move))&&moveCalls==movesBefore+1);
    CHECK(result(TouchMenuScroll(nullptr,&wheel))&&scrollCalls==scrollBefore+1);
    CHECK(!result(TouchMenuButton(nullptr,&down))&&buttonCalls==buttonsBefore);
    CHECK(!result(SetTouchMenuMouseBounds(nullptr,&panel))&&panelCalls==panelsBefore);
    auto newMove=move;newMove.args[2]=text(std::to_string(pending.token));CHECK(!result(MoveTouchMenuPointer(nullptr,&newMove)));
    auto oldUp=up;CHECK(result(TouchMenuButton(nullptr,&oldUp))&&buttonCalls==buttonsBefore+1);
    uiContext.nativeTouches=0;CHECK(uiState.Prepare("waiting-contact",uiContext).status==amcl::input::TouchPublicationStatus::Fenced);
    CHECK(result(MoveTouchMenuPointer(nullptr,&move)));
    uiState.Complete(uiContext,true);CHECK(!result(MoveTouchMenuPointer(nullptr,&move))&&!result(MoveTouchMenuPointer(nullptr,&newMove)));
    CHECK(uiState.Confirm("waiting-contact",pending.token,uiContext)&&result(MoveTouchMenuPointer(nullptr,&newMove)));
    std::cout<<"PASS real menu NAPI: bounded prefix, uint64 publication, gate/mode, native result, legacy geometry, independent CANCEL and UP\n";
    return 0;
}
'''
evidence_root=workspace_path('run','touch-menu-napi');evidence_root.mkdir(parents=True,exist_ok=False)
checks=[]
with temporary_directory(prefix='touch-menu-napi-') as directory:
    path,binary=Path(directory)/'menu.cpp',Path(directory)/'menu.exe'
    def check(body,negative=False,name='positive'):
        path.write_text(prefix+body+main,encoding='utf-8')
        compile_cpp(path,binary)
        result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30)
        (evidence_root/(name+'.log')).write_text(result.stdout+result.stderr,encoding='utf-8')
        checks.append({'name':name,'negative':negative,'exit':result.returncode,
                       'source_sha256':hashlib.sha256((prefix+body+main).encode()).hexdigest()})
        if negative:
            assert result.returncode!=0 and 'CHECK failed' in result.stderr,result.stdout+result.stderr
        else:
            assert result.returncode==0,result.stdout+result.stderr
            print(result.stdout.strip())
    check(production)
    for name,before,after in [
        ('empty panel prefix reaches Native','prefix.empty() ||','false ||'),
        ('publication does not gate move or wheel','amcl::input::AcceptTouchUiContinuation(token)','true'),
        ('new DOWN reuses existing continuation','amcl::input::AcceptTouchUiPublication(token)','amcl::input::AcceptTouchUiContinuation(token)'),
        ('old geometry interface claims panel','if(argc==5) return SetTouchOverlayBounds(env,info,ohos_set_menu_mouse_bounds);','if(argc==5) return amcl::napi::MakeBoolResult(env,ohos_set_menu_mouse_bounds_for_panel(1,2,300,200,"mouse-panel-2",issued));'),
    ]:
        assert before in production,name
        check(production.replace(before,after),True,name.replace(' ','-'))
        print('PASS negative control: '+name)
receipt={'files':{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in [
    'scripts/test-touch-menu-napi.py','entry/src/main/cpp/napi/napi_input.cpp',
    'entry/src/main/cpp/platform/touch_publication_state.h']},'checks':checks,
    'scope':'actual NAPI body + real publication state; SDK/mode facts and Native parameter sink are host seams, not device proof'}
(evidence_root/'evidence.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('NAPI continuation receipts: '+str(evidence_root))
