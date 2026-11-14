/**
 * 直接验证生产 watchdog helper：逐个 JNI 调用注入异常/null，确保不会带异常继续
 * 调用、不泄漏 UTF chars 或局部引用。线程测试证明停止可中断长等待、等待真实回调
 * 完成且 join 可重复调用；这些宿主测试不代替 OHOS 实际 JVM 与信号链验收。
 */
#include "../../entry/src/main/cpp/jvm/jni_watchdog_support.h"
#include <cassert>
#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <map>
#include <thread>
#include <vector>

namespace {
struct JniState;
thread_local JniState* current = nullptr;
template<class T> T pointer(uintptr_t number) { return reinterpret_cast<T>(number); }
uintptr_t id(const void* value) { return reinterpret_cast<uintptr_t>(value); }
enum Method { All = 1, Entries, Iterator, HasNext, Next, Key, Value, Name, Text };
struct JniState {
    JNINativeInterface_ functions{};
    JNIEnv env{&functions};
    std::map<uintptr_t, unsigned> references;
    std::vector<int> nullable;
    uintptr_t nextId = 100;
    int operations = 0, failAt = 0, frameCount = 0, chars = 0, threads = 1, visited = 0, depth = 3;
    int live = 0, peak = 0;
    bool pending = false, nullOnly = false;
    bool step(bool canBeNull = true) {
        assert(!pending);
        ++operations;
        if (canBeNull) nullable.push_back(operations);
        if (operations != failAt) return true;
        pending = !nullOnly;
        return false;
    }
    template<class T = jobject> T ref(uintptr_t value = 0) {
        if (!value) value = nextId++;
        ++references[value]; ++live; if (live > peak) peak = live;
        return pointer<T>(value);
    }
    JniState() {
        current = this;
        functions.ExceptionCheck = [](JNIEnv*) -> jboolean { return current->pending; };
        functions.ExceptionOccurred = [](JNIEnv*) -> jthrowable { return current->pending ? current->ref<jthrowable>(9999) : nullptr; };
        functions.ExceptionClear = [](JNIEnv*) { current->pending = false; };
        functions.DeleteLocalRef = [](JNIEnv*, jobject value) {
            if (!value) return;
            auto& count = current->references[id(value)]; assert(count > 0); --count; --current->live;
        };
        functions.PushLocalFrame = [](JNIEnv*, jint) -> jint {
            if (!current->step()) return JNI_ENOMEM;
            ++current->frameCount; return JNI_OK;
        };
        functions.PopLocalFrame = [](JNIEnv*, jobject) -> jobject {
            assert(current->frameCount == 1 && current->chars == 0); --current->frameCount;
            current->live = 0; current->references.clear(); return nullptr;
        };
        functions.FindClass = [](JNIEnv*, const char*) -> jclass {
            return current->step() ? current->ref<jclass>() : nullptr;
        };
        functions.GetStaticMethodID = [](JNIEnv*, jclass, const char*, const char*) -> jmethodID {
            return current->step() ? pointer<jmethodID>(All) : nullptr;
        };
        functions.GetMethodID = [](JNIEnv*, jclass, const char* name, const char*) -> jmethodID {
            if (!current->step()) return nullptr;
            const Method method = !std::strcmp(name, "entrySet") ? Entries : !std::strcmp(name, "iterator") ? Iterator :
                !std::strcmp(name, "hasNext") ? HasNext : !std::strcmp(name, "next") ? Next :
                !std::strcmp(name, "getKey") ? Key : !std::strcmp(name, "getValue") ? Value :
                !std::strcmp(name, "getName") ? Name : Text;
            return pointer<jmethodID>(method);
        };
        functions.CallStaticObjectMethodV = [](JNIEnv*, jclass, jmethodID method, va_list) -> jobject {
            assert(id(method) == All); return current->step() ? current->ref() : nullptr;
        };
        functions.CallObjectMethodV = [](JNIEnv*, jobject object, jmethodID method, va_list) -> jobject {
            assert(object && method);
            if (!current->step()) return nullptr;
            if (id(method) == Next) ++current->visited;
            return current->ref();
        };
        functions.CallBooleanMethodV = [](JNIEnv*, jobject object, jmethodID method, va_list) -> jboolean {
            assert(object && id(method) == HasNext);
            return current->step(false) && current->visited < current->threads;
        };
        functions.GetArrayLength = [](JNIEnv*, jarray object) -> jsize {
            assert(object); return current->step(false) ? current->depth : 0;
        };
        functions.GetObjectArrayElement = [](JNIEnv*, jobjectArray object, jsize index) -> jobject {
            assert(object && index >= 0 && index < current->depth);
            return current->step() ? current->ref() : nullptr;
        };
        functions.GetStringUTFChars = [](JNIEnv*, jstring value, jboolean*) -> const char* {
            assert(value); if (!current->step()) return nullptr;
            ++current->chars; return "diagnostic-text";
        };
        functions.ReleaseStringUTFChars = [](JNIEnv*, jstring value, const char* bytes) {
            assert(value && bytes && current->chars > 0); --current->chars;
        };
    }
    ~JniState() { assert(!frameCount && !live && !chars && !pending); }
};
struct Sink {
    int threads = 0, frames = 0;
    void thread(const char* value, jsize) { assert(value); ++threads; }
    void frame(const char* value) { assert(value); ++frames; }
};
bool invoke(JniState& state, Sink& sink) {
    amcl::jni::LocalFrame frame(&state.env);
    amcl::jni::Failure failure;
    const bool result = frame.valid()
        ? amcl::jni::dumpThreadStacks(&state.env, failure, sink, [] { return false; })
        : failure.record(&state.env, "PushLocalFrame");
    if (!result) {
        assert(failure.stage && failure.exception == (state.nullOnly ? nullptr : pointer<jthrowable>(9999)));
        state.env.DeleteLocalRef(failure.exception);
    }
    assert(!state.pending && !state.chars);
    return result;
}
struct Work {
    std::atomic<bool> entered{false}, finished{false}, release{false};
};
void waiting(void* opaque, amcl::jni::WatchdogWorker& worker) noexcept {
    auto* work = static_cast<Work*>(opaque);
    work->entered.store(true, std::memory_order_release);
    assert(worker.wait(3600000));
    // 模拟无法被 pthread_cancel 截断的在途 JNI；join 必须等待本段真正完成。
    while (!work->release.load(std::memory_order_acquire)) std::this_thread::yield();
    work->finished.store(true, std::memory_order_release);
}
}

int main() {
    int operations = 0; std::vector<int> nullable;
    { JniState state; Sink sink; assert(invoke(state, sink)); assert(sink.threads == 1 && sink.frames == 3);
      operations = state.operations; nullable = state.nullable; }
    for (int fail = 1; fail <= operations; ++fail) {
        JniState state; Sink sink; state.failAt = fail;
        assert(!invoke(state, sink)); assert(state.operations == fail);
    }
    for (const int fail : nullable) {
        JniState state; Sink sink; state.failAt = fail; state.nullOnly = true;
        assert(!invoke(state, sink)); assert(state.operations == fail);
    }
    { JniState state; Sink sink; state.threads = 2000; state.depth = 100;
      assert(invoke(state, sink)); assert(sink.threads == 2000 && sink.frames == 24000 && state.peak < 32); }
    { JniState state; Sink sink; state.threads = 0; assert(invoke(state, sink)); assert(!sink.threads); }
    for (int repeat = 0; repeat < 50; ++repeat) {
        amcl::jni::WatchdogWorker worker; Work work;
        assert(worker.start(waiting, &work) == 0);
        while (!work.entered.load(std::memory_order_acquire)) std::this_thread::yield();
        assert(worker.start(waiting, &work) == EALREADY);
        std::atomic<bool> joined{false};
        std::thread joiner([&] { assert(worker.stopAndJoin() == 0); joined.store(true, std::memory_order_release); });
        while (!worker.stopped()) std::this_thread::yield();
        assert(!joined.load(std::memory_order_acquire) && !work.finished.load(std::memory_order_acquire));
        work.release.store(true, std::memory_order_release);
        assert(worker.stopAndJoin() == 0); joiner.join();
        assert(work.finished.load(std::memory_order_acquire) && joined.load(std::memory_order_acquire));
        assert(worker.start(waiting, &work) == ECANCELED);
    }
    { amcl::jni::WatchdogWorker worker; Work work; worker.requestStop();
      assert(worker.start(waiting, &work) == ECANCELED && worker.stopAndJoin() == 0); }
    { amcl::jni::InvocationGate gate;
      { amcl::jni::InvocationGate::Use active(gate); assert(active); gate.close(); assert(!gate.idle());
        amcl::jni::InvocationGate::Use rejected(gate); assert(!rejected); }
      assert(gate.idle()); }
    std::printf("PASS watchdog: %d exception sites, %zu null-only sites, 2000 thread bounded refs, 50 stop/join races, invocation closing gate\n",
        operations, nullable.size());
}
