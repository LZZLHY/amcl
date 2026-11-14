/**
 * 开发版线程转储的 JNI 与线程所有权。只供显式启用的诊断使用，不介入游戏热路径。
 * JNI helper 由调用者持有当前线程环境和局部帧；每个失败立即停止，首个异常仍在该帧。
 * Worker 的控制块必须存活到 join 完成；产品使用进程寿命静态控制块，进程直接退出时
 * 由 OS 收尾，不注册可能在 HotSpot 已结束后再次进入 JNI 的 C++ 静态析构器。
 */
#ifndef AMCL_JNI_WATCHDOG_SUPPORT_H
#define AMCL_JNI_WATCHDOG_SUPPORT_H
#include "jni_invocation_support.h"
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <pthread.h>
#include <time.h>

namespace amcl::jni {

/** 单个局部引用的栈所有者；清理不分配对象，也允许在异常路径执行。 */
template<class T> class LocalReference {
public:
    LocalReference(JNIEnv* env, T value) : env_(env), value_(value) {}
    ~LocalReference() { if (value_) env_->DeleteLocalRef(value_); }
    T get() const { return value_; }
    LocalReference(const LocalReference&) = delete;
    LocalReference& operator=(const LocalReference&) = delete;
private:
    JNIEnv* env_;
    T value_;
};

/** GetStringUTFChars 的精确配对；null 失败由外层 Failure 记录，不向日志传空指针。 */
class StringCharacters {
public:
    StringCharacters(JNIEnv* env, jstring value) : env_(env), value_(value), bytes_(env->GetStringUTFChars(value, nullptr)) {}
    ~StringCharacters() { if (bytes_) env_->ReleaseStringUTFChars(value_, bytes_); }
    const char* get() const { return bytes_; }
private:
    JNIEnv* env_;
    jstring value_;
    const char* bytes_;
};

/**
 * 转储一次当前 Java 线程快照，每线程保留原有最多 12 帧策略。sink 只有 thread/ frame
 * 两个同步文本回调，不接收 JNI 引用；shouldStop 在条目/帧之间提供退出机会。
 * 不能强行取消正在执行的 JVM 调用：停止及 join 会等待该调用正常返回。
 */
template<class Sink, class Stop>
bool dumpThreadStacks(JNIEnv* env, Failure& failure, Sink& sink, Stop&& shouldStop) {
    jclass threadClass = env->FindClass("java/lang/Thread");
    if (!failure.require(env, threadClass, "watchdog FindClass(Thread)")) return false;
    jclass mapClass = env->FindClass("java/util/Map");
    if (!failure.require(env, mapClass, "watchdog FindClass(Map)")) return false;
    jclass entryClass = env->FindClass("java/util/Map$Entry");
    if (!failure.require(env, entryClass, "watchdog FindClass(Map.Entry)")) return false;
    jclass setClass = env->FindClass("java/util/Set");
    if (!failure.require(env, setClass, "watchdog FindClass(Set)")) return false;
    jclass iteratorClass = env->FindClass("java/util/Iterator");
    if (!failure.require(env, iteratorClass, "watchdog FindClass(Iterator)")) return false;
    jclass frameClass = env->FindClass("java/lang/StackTraceElement");
    if (!failure.require(env, frameClass, "watchdog FindClass(StackTraceElement)")) return false;
    jmethodID allStacks = env->GetStaticMethodID(threadClass, "getAllStackTraces", "()Ljava/util/Map;");
    if (!failure.require(env, allStacks, "watchdog Thread.getAllStackTraces")) return false;
    jmethodID entries = env->GetMethodID(mapClass, "entrySet", "()Ljava/util/Set;");
    if (!failure.require(env, entries, "watchdog Map.entrySet")) return false;
    jmethodID iterator = env->GetMethodID(setClass, "iterator", "()Ljava/util/Iterator;");
    if (!failure.require(env, iterator, "watchdog Set.iterator")) return false;
    jmethodID hasNext = env->GetMethodID(iteratorClass, "hasNext", "()Z");
    if (!failure.require(env, hasNext, "watchdog Iterator.hasNext")) return false;
    jmethodID next = env->GetMethodID(iteratorClass, "next", "()Ljava/lang/Object;");
    if (!failure.require(env, next, "watchdog Iterator.next")) return false;
    jmethodID key = env->GetMethodID(entryClass, "getKey", "()Ljava/lang/Object;");
    if (!failure.require(env, key, "watchdog Entry.getKey")) return false;
    jmethodID value = env->GetMethodID(entryClass, "getValue", "()Ljava/lang/Object;");
    if (!failure.require(env, value, "watchdog Entry.getValue")) return false;
    jmethodID name = env->GetMethodID(threadClass, "getName", "()Ljava/lang/String;");
    if (!failure.require(env, name, "watchdog Thread.getName")) return false;
    jmethodID text = env->GetMethodID(frameClass, "toString", "()Ljava/lang/String;");
    if (!failure.require(env, text, "watchdog StackTraceElement.toString")) return false;
    jobject all = env->CallStaticObjectMethod(threadClass, allStacks);
    if (!failure.require(env, all, "watchdog Thread.getAllStackTraces()")) return false;
    jobject set = env->CallObjectMethod(all, entries);
    if (!failure.require(env, set, "watchdog Map.entrySet()")) return false;
    jobject cursor = env->CallObjectMethod(set, iterator);
    if (!failure.require(env, cursor, "watchdog Set.iterator()")) return false;
    while (!shouldStop()) {
        const jboolean more = env->CallBooleanMethod(cursor, hasNext);
        if (!failure.check(env, "watchdog Iterator.hasNext()")) return false;
        if (!more) break;
        LocalReference<jobject> entry(env, env->CallObjectMethod(cursor, next));
        if (!failure.require(env, entry.get(), "watchdog Iterator.next()")) return false;
        LocalReference<jobject> thread(env, env->CallObjectMethod(entry.get(), key));
        if (!failure.require(env, thread.get(), "watchdog Entry.getKey()")) return false;
        LocalReference<jobjectArray> stack(env, static_cast<jobjectArray>(env->CallObjectMethod(entry.get(), value)));
        if (!failure.require(env, stack.get(), "watchdog Entry.getValue()")) return false;
        LocalReference<jstring> threadName(env, static_cast<jstring>(env->CallObjectMethod(thread.get(), name)));
        if (!failure.require(env, threadName.get(), "watchdog Thread.getName()")) return false;
        StringCharacters threadBytes(env, threadName.get());
        if (!failure.require(env, threadBytes.get(), "watchdog GetStringUTFChars(name)")) return false;
        const jsize depth = env->GetArrayLength(stack.get());
        if (!failure.check(env, "watchdog GetArrayLength(stack)")) return false;
        sink.thread(threadBytes.get(), depth);
        const jsize limit = depth < 12 ? depth : 12;
        for (jsize index = 0; index < limit && !shouldStop(); ++index) {
            LocalReference<jobject> frame(env, env->GetObjectArrayElement(stack.get(), index));
            if (!failure.require(env, frame.get(), "watchdog GetObjectArrayElement(frame)")) return false;
            LocalReference<jstring> frameText(env, static_cast<jstring>(env->CallObjectMethod(frame.get(), text)));
            if (!failure.require(env, frameText.get(), "watchdog StackTraceElement.toString()")) return false;
            StringCharacters frameBytes(env, frameText.get());
            if (!failure.require(env, frameBytes.get(), "watchdog GetStringUTFChars(frame)")) return false;
            sink.frame(frameBytes.get());
        }
    }
    return true;
}

/**
 * 可中断等待、只能启动一次的线程所有者。requestStop 不等待 Java，供游戏退休调用；
 * stopAndJoin 必须先于 DestroyJavaVM，成功后保证回调和其 JNI detach 都已结束。
 * 不使用 pthread_cancel，也不把 daemon Java 线程当作可随意丢弃的 native 线程。
 */
class WatchdogWorker {
public:
    using Function = void (*)(void*, WatchdogWorker&) noexcept;
    int start(Function function, void* context) {
        pthread_mutex_lock(&mutex_);
        if (started_ || stop_) { pthread_mutex_unlock(&mutex_); return stop_ ? ECANCELED : EALREADY; }
        pthread_condattr_t attributes;
        int error = pthread_condattr_init(&attributes);
        if (error == 0) {
            error = pthread_condattr_setclock(&attributes, CLOCK_MONOTONIC);
            if (error == 0) error = pthread_cond_init(&condition_, &attributes);
            pthread_condattr_destroy(&attributes);
        }
        if (error == 0) {
            conditionReady_ = true; function_ = function; context_ = context;
            error = pthread_create(&thread_, nullptr, [](void* opaque) -> void* {
                auto* self = static_cast<WatchdogWorker*>(opaque);
                self->function_(self->context_, *self);
                return nullptr;
            }, this);
            started_ = error == 0;
            if (error != 0) { pthread_cond_destroy(&condition_); conditionReady_ = false; }
        }
        pthread_mutex_unlock(&mutex_);
        return error;
    }
    void requestStop() {
        pthread_mutex_lock(&mutex_); stop_ = true;
        if (conditionReady_) pthread_cond_broadcast(&condition_);
        pthread_mutex_unlock(&mutex_);
    }
    bool stopped() {
        pthread_mutex_lock(&mutex_); const bool result = stop_; pthread_mutex_unlock(&mutex_); return result;
    }
    /** 返回 true 表示已停止或等待出现错误；使用单调时钟，不受系统时间校准影响。 */
    bool wait(unsigned milliseconds) {
        timespec deadline{};
        if (clock_gettime(CLOCK_MONOTONIC, &deadline) != 0) { requestStop(); return true; }
        deadline.tv_sec += milliseconds / 1000;
        deadline.tv_nsec += static_cast<long>(milliseconds % 1000) * 1000000;
        if (deadline.tv_nsec >= 1000000000) { ++deadline.tv_sec; deadline.tv_nsec -= 1000000000; }
        pthread_mutex_lock(&mutex_);
        while (!stop_) {
            const int error = pthread_cond_timedwait(&condition_, &mutex_, &deadline);
            if (error == ETIMEDOUT) break;
            if (error != 0) { stop_ = true; break; }
        }
        const bool result = stop_; pthread_mutex_unlock(&mutex_); return result;
    }
    int stopAndJoin() {
        pthread_mutex_lock(&mutex_); stop_ = true;
        if (conditionReady_) pthread_cond_broadcast(&condition_);
        while (joining_) pthread_cond_wait(&condition_, &mutex_);
        if (!started_ || joined_) { pthread_mutex_unlock(&mutex_); return 0; }
        // JNI 回调不能销毁自己；不把 EDEADLK 写成已 join，从而冒险销毁 VM。
        if (pthread_equal(thread_, pthread_self())) { pthread_mutex_unlock(&mutex_); return EDEADLK; }
        joining_ = true; pthread_mutex_unlock(&mutex_);
        const int result = pthread_join(thread_, nullptr);
        pthread_mutex_lock(&mutex_); joined_ = result == 0; joining_ = false;
        pthread_cond_broadcast(&condition_); pthread_mutex_unlock(&mutex_);
        return result;
    }
    WatchdogWorker() = default;
    WatchdogWorker(const WatchdogWorker&) = delete;
    WatchdogWorker& operator=(const WatchdogWorker&) = delete;
private:
    pthread_mutex_t mutex_ = PTHREAD_MUTEX_INITIALIZER;
    pthread_cond_t condition_{};
    pthread_t thread_{};
    Function function_ = nullptr;
    void* context_ = nullptr;
    bool conditionReady_ = false, started_ = false, stop_ = false, joining_ = false, joined_ = false;
};

/** 自有 JNI 入口的关闭闸门：只在入口/出口执行原子操作，不持锁跨 Java。 */
class InvocationGate {
public:
    class Use {
    public:
        explicit Use(InvocationGate& gate) : gate_(gate) {
            unsigned value = gate_.state_.load(std::memory_order_acquire);
            while ((value & Closing) == 0 && (value & ~Closing) != Closing - 1) {
                if (gate_.state_.compare_exchange_weak(value, value + 1, std::memory_order_acquire)) {
                    acquired_ = true; break;
                }
            }
        }
        ~Use() { if (acquired_) gate_.state_.fetch_sub(1, std::memory_order_release); }
        explicit operator bool() const { return acquired_; }
        Use(const Use&) = delete;
        Use& operator=(const Use&) = delete;
    private:
        InvocationGate& gate_;
        bool acquired_ = false;
    };
    /** 退休后保持关闭；在途调用仍可完成，销毁方不能把非零计数当成可强杀的线程。 */
    void close() { state_.fetch_or(Closing, std::memory_order_acq_rel); }
    bool idle() const { return state_.load(std::memory_order_acquire) == Closing; }
private:
    static constexpr unsigned Closing = 1u << 31;
    std::atomic<unsigned> state_{0};
};

} // namespace amcl::jni
#endif
