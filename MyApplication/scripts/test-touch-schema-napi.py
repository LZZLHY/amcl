"""重放实际控件 schema NAPI 解析与发布回执，保留真实发布状态机和 SDK 值类型。

两条 v3 解析失败分支必须沿 publication 的结构化出口返回当前操作身份；旧接口仍返回
数值 0。测试只替换 NAPI SDK 对象读写及已知窗口/安装出口，不复制解析、拒绝或发布
状态算法。分别撤回 touch-options / swipe-group 修复，只有编译成功后在对应行为
CHECK 失败才算负对照成立。生成源码、二进制及编译中间物统一留在仓库外临时目录。
"""
from pathlib import Path
import re
import subprocess

from lib.host_cpp import compile_cpp
from lib.workspace_paths import temporary_directory

ROOT = Path(__file__).resolve().parents[1]
CPP = ROOT / 'entry/src/main/cpp'
SOURCE = (CPP / 'napi/napi_input.cpp').read_text(encoding='utf-8')
SOURCE += '\n' + (CPP / 'napi/napi_touch_groups.inc').read_text(encoding='utf-8')


def definition(signature):
    """逐字抽取正式函数；跳过注释与字符串中的括号，不能用副本代替生产判据。

    同名声明以分号结束，不会匹配函数体。函数体内的 lambda 也计入真实括号深度；
    字符串、字符常量和注释只影响定位，不对实际抽取内容做任何重写。
    """
    match = re.search(re.escape(signature) + r'[^;{]*\{', SOURCE)
    assert match, signature
    depth = 0
    position = match.end() - 1
    token = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[{}]')
    for item in token.finditer(SOURCE, position):
        if item.group() == '{':
            depth += 1
        elif item.group() == '}':
            depth -= 1
            if depth == 0:
                return SOURCE[match.start():item.end()]
    raise AssertionError('函数体未完整结束: ' + signature)


# 顺序仅解决本夹具的声明依赖；每个 helper、parser 及入口的实现均来自当前正式源码。
PRODUCTION = '\n\n'.join(definition(name) for name in [
    'bool ReadBoundedUtf8String(', 'napi_value TouchReceiptResult(',
    'static napi_value SchemaResult(', 'static napi_value RejectSchema(',
    'static bool NamedValue(', 'static bool StrictInt(', 'static bool NamedInt(',
    'static bool NamedDouble(', 'static bool NamedBool(', 'static bool ReadTouchSchemaOptions(',
    'static bool GroupFields(', 'static bool GroupArray(', 'static bool GroupText(', 'static bool ReadGroupSchema(',
    'napi_value SetControlSchemaImpl(', 'napi_value SetControlSchema(', 'napi_value PublishTouchSchema('
])

PREFIX = '\n'.join('#include "' + (CPP / name).as_posix() + '"' for name in [
    'platform/touch_publication.h', 'platform/touch_interaction.cpp'
]) + r'''
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <map>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

#define CHECK(condition) do { if (!(condition)) { std::cerr << "CHECK failed " << __LINE__ << " " << #condition << "\n"; return 1; } } while (0)
constexpr int napi_ok = 0, napi_invalid_arg = 1, LOG_APP = 0;
constexpr size_t NAPI_AUTO_LENGTH = static_cast<size_t>(-1);
enum napi_valuetype { napi_undefined, napi_object, napi_number, napi_boolean, napi_string };

// SDK 边界保持真实类型：数组是 object，StrictInt 不能把文本或小数自动转换为整数。
// 每个 Value 由本进程的 unique_ptr 容器持有，回执及入参不会因临时 SDK 句柄悬空。
struct Value {
    napi_valuetype type = napi_undefined;
    double number = 0;
    bool boolean = false, array = false;
    std::string text;
    std::map<std::string, Value*> fields;
    std::vector<Value*> elements;
};
using napi_value = Value*;
using napi_env = void*;
struct Call { std::vector<napi_value> args; };
using napi_callback_info = Call*;
std::vector<std::unique_ptr<Value>> values;
std::string lastRejection;
napi_value value(napi_valuetype type) {
    values.emplace_back(new Value()); values.back()->type = type; return values.back().get();
}
napi_value number(double n) { auto out = value(napi_number); out->number = n; return out; }
napi_value boolean(bool n) { auto out = value(napi_boolean); out->boolean = n; return out; }
napi_value text(const std::string& n) { auto out = value(napi_string); out->text = n; return out; }
napi_value object() { return value(napi_object); }
napi_value array() { auto out = object(); out->array = true; return out; }
int napi_get_property_names(napi_env,napi_value input,napi_value* out) {
    if (!input || input->type != napi_object || !out) return napi_invalid_arg;
    *out=array(); for (const auto& field : input->fields) (*out)->elements.push_back(text(field.first)); return napi_ok;
}
int napi_get_cb_info(napi_env, napi_callback_info info, size_t* count, napi_value* out, void*, void*) {
    if (!info || !count) return napi_invalid_arg;
    const size_t copied = std::min(*count, info->args.size());
    for (size_t i = 0; i < copied; ++i) out[i] = info->args[i];
    *count = copied; return napi_ok;
}
int napi_typeof(napi_env, napi_value v, napi_valuetype* out) {
    if (!v || !out) return napi_invalid_arg; *out = v->type; return napi_ok;
}
int napi_get_value_double(napi_env, napi_value v, double* out) {
    if (!v || v->type != napi_number || !out) return napi_invalid_arg; *out = v->number; return napi_ok;
}
int napi_get_value_bool(napi_env, napi_value v, bool* out) {
    if (!v || v->type != napi_boolean || !out) return napi_invalid_arg; *out = v->boolean; return napi_ok;
}
int napi_has_named_property(napi_env, napi_value v, const char* name, bool* out) {
    if (!v || v->type != napi_object || !out) return napi_invalid_arg;
    *out = v->fields.find(name) != v->fields.end(); return napi_ok;
}
int napi_get_named_property(napi_env, napi_value v, const char* name, napi_value* out) {
    if (!v || v->type != napi_object || !out) return napi_invalid_arg;
    const auto found = v->fields.find(name); if (found == v->fields.end()) return napi_invalid_arg;
    *out = found->second; return napi_ok;
}
int napi_is_array(napi_env, napi_value v, bool* out) {
    if (!v || !out) return napi_invalid_arg; *out = v->array; return napi_ok;
}
int napi_get_array_length(napi_env, napi_value v, uint32_t* out) {
    if (!v || !v->array || !out) return napi_invalid_arg; *out = static_cast<uint32_t>(v->elements.size()); return napi_ok;
}
int napi_get_element(napi_env, napi_value v, uint32_t index, napi_value* out) {
    if (!v || !v->array || !out || index >= v->elements.size()) return napi_invalid_arg;
    *out = v->elements[index]; return napi_ok;
}
int napi_get_value_string_utf8(napi_env, napi_value v, char* out, size_t capacity, size_t* copied) {
    if (!v || v->type != napi_string || !copied) return napi_invalid_arg;
    if (!out) { *copied = v->text.size(); return napi_ok; }
    if (capacity == 0) return napi_invalid_arg;
    *copied = std::min(v->text.size(), capacity - 1);
    std::memcpy(out, v->text.data(), *copied); out[*copied] = '\0'; return napi_ok;
}
int napi_create_double(napi_env, double n, napi_value* out) { *out = number(n); return napi_ok; }
int napi_create_object(napi_env, napi_value* out) { *out = object(); return napi_ok; }
int napi_create_string_utf8(napi_env, const char* n, size_t length, napi_value* out) {
    *out = text(length == NAPI_AUTO_LENGTH ? std::string(n) : std::string(n, length)); return napi_ok;
}
int napi_set_named_property(napi_env, napi_value v, const char* name, napi_value field) {
    if (!v || v->type != napi_object) return napi_invalid_arg; v->fields[name] = field; return napi_ok;
}
int napi_get_boolean(napi_env, bool n, napi_value* out) { *out = boolean(n); return napi_ok; }
namespace amcl::napi { napi_value MakeUndefined(napi_env) { return value(napi_undefined); } }
// 只观察正式拒绝日志的 reason，确保坏参数到达指定分支，没有在更早字段检查时失败。
void warn(int, const char*, const char* reason) { lastRejection = reason; }
#define OH_LOG_WARN(...) warn(__VA_ARGS__)
#define OH_LOG_ERROR(...) do {} while (0)

amcl::input::TouchPublicationState publicationState;
amcl::input::TouchPublicationContext current;
int installs = 0, legacyInstalls = 0, publicationCalls = 0, installedCount = -1, installedSwipe = -1;
bool installedNull = false;

namespace amcl::input {
TouchPublicationReceipt QueryTouchPublication() { return publicationState.Query(current); }
// 窗口与安装出口替身只提供已知上下文和成功安装计数；准入、等待、幂等和完成状态均
// 由真实 TouchPublicationState 决定。未取得 Fenced 许可时不会模拟安装，也不会改代次。
TouchPublicationReceipt PublishTouchSchema(const std::string& operation, const AmclCtrlEntry* entries,
        int count, float, float, int, float, int version, const TouchInteractionConfig* config, const TouchGroupSchema* groups) {
    ++publicationCalls;
    auto ready = publicationState.Prepare(operation, current);
    if (ready.status != TouchPublicationStatus::Fenced) return ready;
    if (!config || !ValidTouchInteractionConfig(*config)) throw std::runtime_error("夹具收到未校验配置");
    if (version == 4 && (!groups || !groups->Enabled() || !ValidTouchGroupSchema(*groups,count)))
        throw std::runtime_error("夹具收到未校验组定义");
    ++installs; installedCount = count; installedNull = entries == nullptr;
    if (count > 0) installedSwipe = entries[0].swipeGroup;
    ++current.schema;
    return publicationState.Complete(current, false);
}
}
uint64_t ohos_set_control_schema_v3(const AmclCtrlEntry*, int, float, float, int, float, int,
        const amcl::input::TouchInteractionConfig*) {
    ++legacyInstalls; return ++current.schema;
}
'''

MAIN = r'''
// 入参由生产 TouchInteractionConfig 的合法缺省值构造；零控件及一个合法 BUTTON 都
// 先走成功链路，证明错误用例不会因缺字段、rect 或 action 配置先被其它分支截获。
napi_value schema(bool withButton = false) {
    using amcl::input::TouchInteractionConfig;
    const TouchInteractionConfig config;
    auto root = object(), touch = object();
    root->fields = {{"schemaVersion", number(AMCL_CONTROL_SCHEMA_VERSION)}, {"compWidth", number(640)},
        {"compHeight", number(360)}, {"grabbed", boolean(false)}, {"deadZone", number(.18)},
        {"contextDensity", number(current.density)}, {"contextTransform", number(current.transform)}, {"touch", touch}};
    touch->fields = {{"version", number(config.version)}, {"touchpad", boolean(config.touchpad)},
        {"menuSensitivity", number(config.menuSensitivity)}, {"menuScroll", boolean(config.menuScroll)},
        {"menuHoldMs", number(config.menuHoldMs)}, {"floatingJoystick", boolean(config.floatingJoystick)},
        {"sprint", boolean(config.sprint)}, {"autoWalk", boolean(config.autoWalk)},
        {"sprintThreshold", number(config.sprintThreshold)}, {"hotbarSwap", boolean(config.hotbarSwap)},
        {"hotbarDrop", boolean(config.hotbarDrop)}, {"holdMs", number(config.holdMs)},
        {"gestureMode", number(config.gestureMode)}};
    auto actions = array(); for (const auto key : config.actions) actions->elements.push_back(number(key));
    touch->fields["actions"] = actions;
    auto controls = array(); root->fields["controls"] = controls;
    if (withButton) {
        auto button = object(), keys = array(); keys->elements.push_back(number(32));
        button->fields = {{"id", text("button")}, {"kind", number(0)}, {"handledBy", number(0)},
            {"trigger", number(0)}, {"keyOrMouse", number(32)}, {"x", number(10)}, {"y", number(20)},
            {"w", number(40)}, {"h", number(40)}, {"hitSlop", number(8)}, {"dragLook", boolean(false)},
            {"haptic", boolean(true)}, {"swipeGroup", number(1)}, {"keys", keys}};
        controls->elements.push_back(button);
    }
    return root;
}

amcl::input::TouchPublicationReceipt begin(const std::string& name, int contacts = 0) {
    publicationState = amcl::input::TouchPublicationState();
    current = amcl::input::TouchPublicationContext();
    // 大于 JS 安全整数的身份必须作为字符串完整回传，回执检查不会先转换为 double。
    current.surface = 9007199254740993ULL; current.session = 9007199254740995ULL;
    current.policy = 9007199254740997ULL; current.schema = 9007199254740999ULL;
    current.grabEpoch = 9007199254741001ULL; current.density = 2; current.transform = 1;
    current.nativeTouches = contacts;
    installs = legacyInstalls = publicationCalls = 0; installedCount = installedSwipe = -1;
    installedNull = false; lastRejection.clear();
    return publicationState.Begin(name, "candidate-" + name, current, current);
}

napi_value field(napi_value value, const char* key) {
    if (!value || value->type != napi_object) return nullptr;
    const auto found = value->fields.find(key); return found == value->fields.end() ? nullptr : found->second;
}
bool textField(napi_value value, const char* key, const std::string& expected) {
    auto found = field(value, key); return found && found->type == napi_string && found->text == expected;
}
bool numberField(napi_value value, const char* key, double expected) {
    auto found = field(value, key); return found && found->type == napi_number && found->number == expected;
}
bool boolField(napi_value value, const char* key, bool expected) {
    auto found = field(value, key); return found && found->type == napi_boolean && found->boolean == expected;
}
// 此处只比对真实状态的可观测回执字段，不生成状态或推导任何发布资格。
bool receiptMatches(napi_value value, const amcl::input::TouchPublicationReceipt& expected, const char* status) {
    return numberField(value, "version", 1) && textField(value, "status", status) &&
        textField(value, "operationId", expected.operationId) && textField(value, "candidateId", expected.candidateId) &&
        textField(value, "token", std::to_string(expected.token)) &&
        textField(value, "surface", std::to_string(expected.context.surface)) &&
        textField(value, "session", std::to_string(expected.context.session)) &&
        textField(value, "policy", std::to_string(expected.context.policy)) &&
        textField(value, "schemaGeneration", std::to_string(expected.context.schema)) &&
        textField(value, "grabEpoch", std::to_string(expected.context.grabEpoch)) &&
        numberField(value, "nativeTouches", expected.context.nativeTouches) &&
        numberField(value, "density", expected.context.density) && numberField(value, "transform", expected.context.transform) &&
        numberField(value, "modalCount", expected.modalCount) && boolField(value, "fenced", expected.fenced) &&
        boolField(value, "grabbed", expected.context.grabbed);
}

int valid(bool withButton) {
    const auto started = begin(withButton ? "valid-button" : "valid-zero");
    CHECK(started.fenced && started.token != 0);
    Call call{{schema(withButton), text(started.operationId)}};
    auto result = PublishTouchSchema(nullptr, &call);
    const auto committed = publicationState.Query(current);
    CHECK(result && result->type == napi_object);
    CHECK(receiptMatches(result, committed, "committed"));
    CHECK(lastRejection.empty() && installs == 1 && publicationCalls == 1 && legacyInstalls == 0);
    CHECK(installedCount == (withButton ? 1 : 0) && installedNull == !withButton);
    CHECK(!withButton || installedSwipe == 1);
    CHECK(committed.context.schema == started.context.schema + 1 && committed.token == started.token);
    CHECK(committed.fenced && publicationState.BlocksNewTouch());
    // 同操作重复送达由实际 Prepare 返回原提交；不能借 SDK 替身重复安装表。
    CHECK(receiptMatches(PublishTouchSchema(nullptr, &call), committed, "committed"));
    CHECK(installs == 1 && publicationCalls == 2);
    CHECK(publicationState.Confirm(started.operationId, started.token, current));
    CHECK(!publicationState.BlocksNewTouch());
    std::cout << "PASS valid " << (withButton ? "button/swipe" : "zero-controls") << " committed receipt and idempotence\n";
    return 0;
}

int invalid(const std::string& reason) {
    const auto started = begin(reason);
    auto message = schema(reason == "swipe-group");
    if (reason == "touch-options") message->fields["touch"]->fields["holdMs"] = text("500");
    if (reason == "swipe-group") message->fields["controls"]->elements[0]->fields["swipeGroup"] = number(.5);
    if (reason == "context-policy") message->fields["contextDensity"] = number(current.density + .25);
    std::cout << "CASE " << reason << "\n";
    Call call{{message, text(started.operationId)}};
    auto result = PublishTouchSchema(nullptr, &call);
    CHECK(lastRejection == reason);
    CHECK(result && result->type == napi_object);
    CHECK(receiptMatches(result, started, "invalid"));
    CHECK(installs == 0 && legacyInstalls == 0 && publicationCalls == 0);
    const auto after = publicationState.Query(current);
    // parser 的 invalid 是本次响应；真实操作仍在 Begin 的 fence 下，身份和 token 完整保留。
    CHECK(after.status == amcl::input::TouchPublicationStatus::Fenced && after.fenced);
    CHECK(after.operationId == started.operationId && after.candidateId == started.candidateId && after.token == started.token);
    CHECK(after.context.SameIdentity(started.context) && publicationState.BlocksNewTouch());
    CHECK(!publicationState.Confirm(started.operationId, started.token, current));
    if (reason != "context-policy") {
        // 相同坏对象调用旧接口时仍为数值 0，兼容 ABI 不能被 publication 修复一并改写。
        lastRejection.clear(); Call legacy{{message}};
        auto oldResult = SetControlSchema(nullptr, &legacy);
        CHECK(lastRejection == reason);
        CHECK(oldResult && oldResult->type == napi_number && oldResult->number == 0);
        CHECK(installs == 0 && legacyInstalls == 0 && publicationCalls == 0);
        const auto retained = publicationState.Query(current);
        CHECK(retained.fenced && retained.token == started.token && retained.operationId == started.operationId);
    }
    std::cout << "PASS invalid " << reason << " exact operation receipt, no install and retained fence\n";
    return 0;
}

int waiting() {
    const auto started = begin("waiting", 1);
    CHECK(started.status == amcl::input::TouchPublicationStatus::Waiting && started.fenced);
    Call call{{schema(), text(started.operationId)}};
    CHECK(receiptMatches(PublishTouchSchema(nullptr, &call), started, "waiting"));
    CHECK(installs == 0 && publicationCalls == 1 && publicationState.BlocksNewTouch());
    current.nativeTouches = 0;
    auto result = PublishTouchSchema(nullptr, &call);
    CHECK(receiptMatches(result, publicationState.Query(current), "committed"));
    CHECK(installs == 1 && publicationCalls == 2);
    std::cout << "PASS native contact waiting then zero-contact committed\n";
    return 0;
}

/** 合法新表先过真实解析器，再逐项注入未知字段、坏引用和错误枚举。 */
napi_value groupMessage() {
    auto root=schema(true);root->fields["schemaVersion"]=number(4);
    auto group=object(),definitions=array(),members=array(),definition=object(),member=object(),bindings=array();
    definition->fields={{"id",text("base")},{"initialVisible",boolean(true)}};definitions->elements.push_back(definition);
    for(int phase=0;phase<4;++phase){auto binding=object(),keys=array(),actions=array();
        if(phase==0){auto action=object();action->fields={{"target",number(0)},{"operation",number(0)}};actions->elements.push_back(action);}
        binding->fields={{"keys",keys},{"actions",actions},{"autoKeep",boolean(false)}};bindings->elements.push_back(binding);}
    member->fields={{"group",number(0)},{"phases",boolean(true)},{"fcl",boolean(false)},{"mouseTool",boolean(false)},
        {"rank",number(0)},{"bindings",bindings}};members->elements.push_back(member);
    group->fields={{"profile",text("profile")},{"groups",definitions},{"controls",members}};
    root->fields["groupSchema"]=group;return root;
}
int groupParsing() {
    for(int variant=0;variant<8;++variant){auto started=begin("group-"+std::to_string(variant));auto root=groupMessage();
        auto group=root->fields["groupSchema"], member=group->fields["controls"]->elements[0];
        if(variant==1)group->fields["unknownBehavior"]=boolean(true);
        if(variant==2)member->fields["group"]=number(10);
        if(variant==3)member->fields["bindings"]->elements[0]->fields["actions"]->elements[0]->fields["operation"]=number(3);
        if(variant==4)member->fields["bindings"]->elements[0]->fields["actions"]->elements[0]->fields["target"]=number(1);
        if(variant==5)group->fields.erase("groups");
        if(variant==6)group->fields["editorSession"]=number(1);
        if(variant==7)group->fields["trial"]=boolean(true);
        Call call{{root,text(started.operationId)}};auto result=PublishTouchSchema(nullptr,&call);
        if(variant==0){CHECK(installs==1&&result->fields["status"]->text=="committed");}
        else {CHECK(installs==0&&result->fields["status"]->text=="invalid"&&lastRejection=="group-schema");}
    }
    // 已退役的编辑身份不能借空组扩展复活；有方案身份但无组定义的表明确拒绝。
    { auto root=groupMessage(),group=root->fields["groupSchema"];
      group->fields["groups"]->elements.clear();group->fields["controls"]->elements.clear();
      amcl::input::TouchGroupSchema decoded;
      CHECK(!ReadGroupSchema(nullptr,root,1,decoded));
      group->fields["controls"]->elements.push_back(object());amcl::input::TouchGroupSchema invalid;
      CHECK(!ReadGroupSchema(nullptr,root,1,invalid)); }
    begin("old-api");Call old{{groupMessage()}};auto rejected=SetControlSchema(nullptr,&old);
    CHECK(rejected->type==napi_number&&rejected->number==0&&legacyInstalls==0);
    std::cout<<"PASS v4 group parser: complete extension, closed fields, references/enums and old API refusal\n";return 0;
}
int main() {
    int result = valid(false); if (result) return result;
    result = valid(true); if (result) return result;
    for (const auto reason : {"touch-options", "swipe-group", "context-policy"}) {
        result = invalid(reason); if (result) return result;
    }
    result = waiting(); if (result) return result;
    result = groupParsing(); if (result) return result;
    std::cout << "PASS production schema NAPI parser and real publication state\n";
    return 0;
}
'''


with temporary_directory(prefix='touch-schema-napi-') as directory:
    path, binary = Path(directory) / 'schema.cpp', Path(directory) / 'schema.exe'

    def check(body, negative_reason=None):
        """编译每个实际变体；负例必须命中指定分支的对象类型断言而非工具失败。

        不捕获 compile_cpp 的异常，编译错误直接使测试失败。运行超时也直接失败；只有
        指定 reason 已走到、正确 schema 先提交成功，再出现回执类型 CHECK 才接受负例。
        """
        path.write_text(PREFIX + body + MAIN, encoding='utf-8', newline='\n')
        compile_cpp(path, binary)
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
        if negative_reason:
            assert result.returncode != 0, result.stdout + result.stderr
            assert 'CASE ' + negative_reason in result.stdout, result.stdout + result.stderr
            assert 'PASS valid zero-controls' in result.stdout and 'PASS valid button/swipe' in result.stdout
            assert 'CHECK failed' in result.stderr and 'result && result->type == napi_object' in result.stderr, result.stdout + result.stderr
            print('PASS negative control: ' + negative_reason + ' restored numeric RejectSchema -> ' + result.stderr.strip())
        else:
            assert result.returncode == 0, result.stdout + result.stderr
            print(result.stdout.strip())

    check(PRODUCTION)
    for reason in ['touch-options', 'swipe-group']:
        before = 'return reject("' + reason + '");'
        after = 'return RejectSchema(env, "' + reason + '");'
        assert PRODUCTION.count(before) == 1, reason
        check(PRODUCTION.replace(before, after, 1), negative_reason=reason)
