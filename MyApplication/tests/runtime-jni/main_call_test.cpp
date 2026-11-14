/**
 * 故障注入直接驱动生产 Invocation helper。替身只实现 JNI 外部接口：每个可失败
 * 操作逐次返回 OOM，禁止 pending exception 下继续普通 JNI，检查 main 未提前执行、
 * 首个异常保持、局部引用与 attach/detach 所有权。它不替代真实 JVM CheckJNI 验证。
 */
#include "../../entry/src/main/cpp/jvm/jni_invocation_support.h"
#include <cassert>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <map>

namespace {
enum Method { SystemLoader = 1, LoadClass, FileCtor, ToUri, ToUrl, LoaderCtor, CurrentThread, ContextLoader, Main };
struct State;
thread_local State* current = nullptr;
template<class T> T pointer(uintptr_t number) { return reinterpret_cast<T>(number); }
uintptr_t id(const void* value) { return reinterpret_cast<uintptr_t>(value); }
struct State {
    JNINativeInterface_ functions{};
    JNIInvokeInterface_ invocation{};
    JNIEnv env{&functions};
    JavaVM vm{&invocation};
    int operations = 0, failAt = 0, mainAt = 0, mainCalls = 0, callbacks = 0;
    int attaches = 0, detaches = 0, destroys = 0, frames = 0, loadCalls = 0;
    jint getStatus = JNI_OK, attachStatus = JNI_OK, detachStatus = JNI_OK, destroyStatus = JNI_OK;
    bool nullEnv = false, pending = false, missing = false, firstMiss = false, secondMiss = false;
    bool failWithoutException = false;
    uintptr_t nextObject = 100;
    std::map<uintptr_t, int> refs;
    std::map<uintptr_t, std::pair<int, int>> arrays;
    std::string lastUtf;
    bool step() {
        assert(!pending); // 普通 JNI 操作不能发生在首个未处理异常之后。
        if (++operations == failAt) { pending = !failWithoutException; missing = false; return false; }
        return true;
    }
    template<class T = jobject> T ref(uintptr_t value = 0) {
        if (!value) value = nextObject++;
        ++refs[value]; return pointer<T>(value);
    }
    State() {
        current = this;
        functions.ExceptionCheck = [](JNIEnv*) -> jboolean { return current->pending; };
        functions.ExceptionOccurred = [](JNIEnv*) -> jthrowable { return current->pending ? current->ref<jthrowable>(9999) : nullptr; };
        functions.ExceptionClear = [](JNIEnv*) { current->pending = false; };
        functions.DeleteLocalRef = [](JNIEnv*, jobject value) {
            if (value) { auto& count = current->refs[id(value)]; assert(count > 0); --count; }
        };
        functions.PushLocalFrame = [](JNIEnv*, jint) -> jint {
            if (!current->step()) return JNI_ENOMEM;
            ++current->frames; return JNI_OK;
        };
        functions.PopLocalFrame = [](JNIEnv*, jobject value) -> jobject {
            assert(current->frames == 1); --current->frames;
            for (auto& item : current->refs) item.second = 0;
            return value;
        };
        functions.FindClass = [](JNIEnv*, const char* name) -> jclass {
            if (!current->step()) return nullptr;
            const uintptr_t tag = std::strcmp(name, "java/lang/ClassNotFoundException") == 0 ? 10 :
                                  std::strcmp(name, "java/net/URLClassLoader") == 0 ? 11 : 12;
            return current->ref<jclass>(tag);
        };
        functions.IsInstanceOf = [](JNIEnv*, jobject, jclass) -> jboolean {
            assert(!current->pending); return current->missing;
        };
        functions.GetStaticMethodID = [](JNIEnv*, jclass, const char* name, const char*) -> jmethodID {
            if (!current->step()) return nullptr;
            return pointer<jmethodID>(std::strcmp(name, "main") == 0 ? Main :
                std::strcmp(name, "currentThread") == 0 ? CurrentThread : SystemLoader);
        };
        functions.GetMethodID = [](JNIEnv*, jclass type, const char* name, const char*) -> jmethodID {
            if (!current->step()) return nullptr;
            return pointer<jmethodID>(std::strcmp(name, "loadClass") == 0 ? LoadClass :
                std::strcmp(name, "toURI") == 0 ? ToUri : std::strcmp(name, "toURL") == 0 ? ToUrl :
                std::strcmp(name, "setContextClassLoader") == 0 ? ContextLoader : id(type) == 11 ? LoaderCtor : FileCtor);
        };
        functions.NewStringUTF = [](JNIEnv*, const char* bytes) -> jstring {
            if (!current->step()) return nullptr;
            assert(bytes); current->lastUtf = bytes; return current->ref<jstring>();
        };
        functions.NewObjectArray = [](JNIEnv*, jsize size, jclass, jobject) -> jobjectArray {
            if (!current->step()) return nullptr;
            const auto array = current->ref<jobjectArray>(); current->arrays[id(array)] = {size, 0}; return array;
        };
        functions.SetObjectArrayElement = [](JNIEnv*, jobjectArray array, jsize index, jobject value) {
            if (!current->step()) return;
            auto& status = current->arrays.at(id(array));
            assert(value && index == status.second && index < status.first); ++status.second;
        };
        functions.NewObjectV = [](JNIEnv*, jclass, jmethodID method, va_list) -> jobject {
            assert(method); if (!current->step()) return nullptr; return current->ref();
        };
        functions.CallStaticObjectMethodV = [](JNIEnv*, jclass, jmethodID method, va_list) -> jobject {
            assert(method); if (!current->step()) return nullptr; return current->ref();
        };
        functions.CallObjectMethodV = [](JNIEnv*, jobject object, jmethodID method, va_list) -> jobject {
            assert(object && method); if (!current->step()) return nullptr;
            if (id(method) == LoadClass) {
                ++current->loadCalls;
                if ((current->loadCalls == 1 && current->firstMiss) || (current->loadCalls == 2 && current->secondMiss)) {
                    current->pending = true; current->missing = true; return nullptr;
                }
            }
            return current->ref();
        };
        functions.CallVoidMethodV = [](JNIEnv*, jobject object, jmethodID method, va_list) {
            assert(object && method); current->step();
        };
        functions.CallStaticVoidMethodV = [](JNIEnv*, jclass type, jmethodID method, va_list args) {
            assert(type && id(method) == Main);
            ++current->mainCalls; current->mainAt = current->operations + 1;
            const auto array = va_arg(args, jobjectArray);
            const auto status = current->arrays.at(id(array)); assert(status.first == status.second);
            current->step();
        };
        invocation.GetEnv = [](JavaVM*, void** env, jint) -> jint {
            *env = current->nullEnv ? nullptr : &current->env;
            return current->getStatus;
        };
        invocation.AttachCurrentThread = [](JavaVM*, void** env, void*) -> jint {
            ++current->attaches; *env = current->nullEnv ? nullptr : &current->env;
            return current->attachStatus;
        };
        invocation.AttachCurrentThreadAsDaemon = invocation.AttachCurrentThread;
        invocation.DetachCurrentThread = [](JavaVM*) -> jint { ++current->detaches; return current->detachStatus; };
        invocation.DestroyJavaVM = [](JavaVM*) -> jint {
            assert(current->detaches == 1); ++current->destroys; return current->destroyStatus;
        };
    }
    ~State() { for (const auto& item : refs) assert(item.second == 0); assert(frames == 0); }
};

/** 调用生产入口，错误对象消费方式与宿主一致；返回实际 main 阶段供负例比较。 */
bool invoke(State& state, bool processor, bool* entered = nullptr) {
    amcl::jni::Environment environment(&state.vm, JNI_VERSION_1_8);
    assert(environment.get() == &state.env);
    amcl::jni::LocalFrame frame(environment.get());
    amcl::jni::Failure failure;
    const char* arguments[] = {"中文", "emoji-\xF0\x9F\x98\x80"};
    const bool success = frame.valid() ? amcl::jni::callMain(&state.env, "test.Main", 2, arguments, processor,
        "/path with spaces/工具.jar::/second.jar", failure, [&] { ++state.callbacks; }) : failure.record(&state.env, "PushLocalFrame");
    if (entered) *entered = failure.enteredMain;
    if (!success) {
        assert(failure.stage && failure.exception == (state.failWithoutException ? nullptr : pointer<jthrowable>(9999)));
        state.env.DeleteLocalRef(failure.exception);
    }
    assert(!state.pending);
    return success;
}
}

int main() {
    // 失败边界不允许把detach错误吞掉继续销毁；Destroy本身错误也须原样返回。
    for (jint detach : {JNI_OK, JNI_ERR}) for (jint destroy : {JNI_OK, JNI_ERR}) {
        State state; state.detachStatus = detach; state.destroyStatus = destroy;
        const auto result = amcl::jni::finishLauncherVm(&state.vm);
        assert(result.detached == detach && state.detaches == 1);
        assert(state.destroys == (detach == JNI_OK ? 1 : 0));
        assert(result.destroyed == (detach == JNI_OK ? destroy : JNI_ERR));
    }
    assert(amcl::jni::finishLauncherVm(nullptr).destroyed == JNI_ERR);
    unsigned injected = 0;
    for (int path = 0; path != 3; ++path) {
        int count = 0, mainAt = 0;
        { State state; state.firstMiss = path > 0; state.secondMiss = path > 1;
          assert(invoke(state, path > 0)); assert(state.mainCalls == 1 && state.callbacks == 1);
          assert(state.lastUtf == "emoji-\xED\xA0\xBD\xED\xB8\x80"); count = state.operations; mainAt = state.mainAt; }
        for (int fail = 1; fail <= count; ++fail) {
            State state; state.firstMiss = path > 0; state.secondMiss = path > 1; state.failAt = fail;
            bool entered = false;
            assert(!invoke(state, path > 0, &entered));
            assert(entered == (fail == mainAt));
            assert(state.mainCalls == (fail == mainAt ? 1 : 0));
            assert(state.operations == fail); // 异常后不再分配/查类/调用 main。
            ++injected;
        }
    }
    for (bool daemon : {false, true}) {
        for (jint get : {JNI_OK, JNI_EDETACHED, JNI_EVERSION, JNI_ERR}) {
            for (jint attach : {JNI_OK, JNI_ENOMEM, JNI_ERR}) for (bool nullEnv : {false, true}) {
                State state; state.getStatus = get; state.attachStatus = attach; state.nullEnv = nullEnv;
                { amcl::jni::Environment env(&state.vm, JNI_VERSION_1_8, daemon);
                  const bool valid = !nullEnv && (get == JNI_OK || (get == JNI_EDETACHED && attach == JNI_OK));
                  assert(bool(env.get()) == valid); }
                assert(state.attaches == (get == JNI_EDETACHED ? 1 : 0));
                assert(state.detaches == (get == JNI_EDETACHED && attach == JNI_OK ? 1 : 0));
            }
        }
    }
    // JNI 合同允许某些分配/查找只返回 null，不抛 Java 异常；不能只检查 ExceptionCheck。
    for (int operation : {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13}) {
        State state; state.failAt = operation; state.failWithoutException = true;
        assert(!invoke(state, false)); assert(state.mainCalls == 0 && state.operations == operation);
    }
    { State state; state.getStatus = JNI_EDETACHED; state.detachStatus = JNI_ERR;
      amcl::jni::Environment env(&state.vm, JNI_VERSION_1_8); assert(env.finish() == JNI_ERR); assert(env.finish() == JNI_OK); }
    std::printf("PASS production JNI invocation: %u injected exceptions, 12 null-only failures, 48 environment cases, first-error/main-stage/local-reference ownership\n", injected);
}
