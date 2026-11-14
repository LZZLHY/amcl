/**
 * 在每个显式指定的真实宿主 JVM 中运行生产 JNI 调用核心，开启 -Xcheck:jni。
 * 分别覆盖已有环境、由本层附加的两个并发 native 线程、受限 processor 回退和真实
 * main 异常。宿主 Java 资格不替代 OHOS 自加载/JIT 或设备 namespace 资格。
 */
#include "../../entry/src/main/cpp/jvm/jni_invocation_support.h"
#include "../../entry/src/main/cpp/jvm/jni_watchdog_support.h"
#include "../../entry/src/main/cpp/jvm/hello_world_class.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <iterator>
#include <thread>
#include <unistd.h>

static void call(JavaVM* vm, jint version, const std::string& path, bool fallback, bool throws = false) {
    amcl::jni::Environment environment(vm, version);
    JNIEnv* env = environment.get(); assert(env);
    {
        amcl::jni::LocalFrame frame(env); assert(frame.valid());
        amcl::jni::Failure failure;
        const char* args[] = {"中文", "emoji-\xF0\x9F\x98\x80"};
        const char* throwing[] = {"throw"};
        const bool ok = amcl::jni::callMain(env, "InvocationFixture", throws ? 1 : 2,
            throws ? throwing : args, fallback, path, failure, [] {});
        assert(ok == !throws && failure.enteredMain);
        if (throws) {
            assert(failure.exception && !env->ExceptionCheck());
            jclass expected = env->FindClass("java/lang/IllegalStateException");
            assert(expected && !env->ExceptionCheck());
            assert(env->IsInstanceOf(failure.exception, expected));
        }
    }
    assert(environment.finish() == JNI_OK);
}

/** 用真实 HotSpot 复用生产转储及线程控制器；只在 native 线程正常 detach 后允许销毁。 */
struct RealWatchdog {
    JavaVM* vm;
    jint version;
    std::atomic<unsigned> rounds{0}, threads{0}, frames{0};
    std::atomic<bool> detached{false};
    void thread(const char* name, jsize) { assert(name && name[0]); threads.fetch_add(1); }
    void frame(const char* value) { assert(value && value[0]); frames.fetch_add(1); }
    static void run(void* opaque, amcl::jni::WatchdogWorker& worker) noexcept {
        auto& self = *static_cast<RealWatchdog*>(opaque);
        amcl::jni::Environment environment(self.vm, self.version, true);
        JNIEnv* env = environment.get(); assert(env);
        while (!worker.stopped()) {
            {
                amcl::jni::LocalFrame frame(env, 32); assert(frame.valid());
                amcl::jni::Failure failure;
                assert(amcl::jni::dumpThreadStacks(env, failure, self, [&] { return worker.stopped(); }));
                assert(!failure.exception && !env->ExceptionCheck());
            }
            self.rounds.fetch_add(1, std::memory_order_release);
            if (worker.wait(1)) break;
        }
        assert(environment.finish() == JNI_OK);
        self.detached.store(true, std::memory_order_release);
    }
};

int main(int argc, char** argv) {
    assert(argc == 6);
    void* library = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
    if (!library) { std::fprintf(stderr, "%s\n", dlerror()); return 2; }
    auto create = reinterpret_cast<jint (*)(JavaVM**, void**, void*)>(dlsym(library, "JNI_CreateJavaVM"));
    assert(create);
    const jint version = std::atoi(argv[2]) == 8 ? JNI_VERSION_1_8 : JNI_VERSION_10;
    const bool fallback = std::string(argv[5]) == "fallback";
    std::string classpath = "-Djava.class.path=" + std::string(fallback ? "/output/empty-classpath" : argv[3]);
    JavaVMOption options[]{{const_cast<char*>("-Xcheck:jni"), nullptr}, {const_cast<char*>(classpath.c_str()), nullptr}};
    JavaVMInitArgs args{version, 2, options, JNI_FALSE};
    JavaVM* vm = nullptr; JNIEnv* env = nullptr;
    assert(create(&vm, reinterpret_cast<void**>(&env), &args) == JNI_OK && vm && env);
    const std::string mode(argv[5]);
    if (mode == "launcher-completion" || mode == "legacy-attached-destroy") {
        {
            amcl::jni::LocalFrame frame(env); assert(frame.valid());
            amcl::jni::Failure failure;
            const char* parameters[] = {argv[4]};
            assert(amcl::jni::callMain(env, "MainThreadCompletionFixture", 1, parameters,
                false, argv[3], failure, [] {}) && !env->ExceptionCheck());
        }
        // 明确main已经返回，旧负例随后必须被独立进程期限拒绝；不把VM初始化慢当互锁。
        std::puts("MAIN_RETURN_BEFORE_COMPLETION"); std::fflush(stdout);
        if (mode == "legacy-attached-destroy") {
            vm->DestroyJavaVM();
            return 77;
        }
        const auto completion = amcl::jni::finishLauncherVm(vm);
        assert(completion.detached == JNI_OK && completion.destroyed == JNI_OK);
        for (const std::string suffix : {".worker", ".hook"}) {
            std::ifstream file(std::string(argv[4]) + suffix);
            const std::string value{std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
            assert(value == (suffix == ".worker" ? "main-ended\n" : "hook-after-main-join\n"));
        }
        std::printf("PASS launcher completion VM=%s: original main join/isAlive, worker, ordered hook and Destroy\n", argv[2]);
        return 0;
    }
    if (mode == "watchdog") {
        RealWatchdog work{vm, version}; amcl::jni::WatchdogWorker worker;
        assert(worker.start(RealWatchdog::run, &work) == 0);
        while (work.rounds.load(std::memory_order_acquire) < 3) std::this_thread::yield();
        assert(worker.stopAndJoin() == 0 && work.detached.load(std::memory_order_acquire));
        assert(work.threads > 0 && work.frames > 0);
        assert(vm->DestroyJavaVM() == JNI_OK);
        std::printf("PASS watchdog real VM=%s: rounds=%u threads=%u frames=%u detach/join before destroy\n",
            argv[2], work.rounds.load(), work.threads.load(), work.frames.load());
        return 0;
    }
    if (mode == "completion" || mode == "completion-throws" || mode == "legacy-immediate-exit") {
        const bool throws = mode == "completion-throws";
        {
            amcl::jni::LocalFrame frame(env); assert(frame.valid());
            amcl::jni::Failure failure;
            const char* parameters[] = {argv[4], throws ? "throw" : "return"};
            const bool result = amcl::jni::callMain(env, "InvocationCompletionFixture", 2, parameters,
                false, argv[3], failure, [] {});
            assert(result == !throws && failure.enteredMain);
            assert(!env->ExceptionCheck());
        }
        if (mode == "legacy-immediate-exit") _exit(0); // 精确旧行为负例：main 返回即直接结束进程。
        assert(vm->DestroyJavaVM() == JNI_OK);
        for (const std::string suffix : {".worker", ".hook"}) {
            std::ifstream file(std::string(argv[4]) + suffix);
            const std::string value{std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
            assert(value == (suffix == ".worker" ? "worker\n" : "hook-after-worker\n"));
        }
        std::printf("PASS complete VM=%s mainThrows=%d: non-daemon result and ordered shutdown hook\n", argv[2], int(throws));
        return throws ? 1 : 0;
    }
    call(vm, version, argv[3], fallback);
    std::thread first([&] { call(vm, version, argv[3], fallback); });
    std::thread second([&] { call(vm, version, argv[3], fallback); });
    first.join(); second.join();
    call(vm, version, argv[3], fallback, true);
    // 同一进程重复定义诊断类时用独立 loader，不落盘到游戏 classpath，也不缓存全局类引用。
    std::ifstream input(argv[4], std::ios::binary);
    std::vector<char> bytes{std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
    assert(bytes.size() > 8 && static_cast<unsigned char>(bytes[7]) == 52);
    assert(bytes.size() == static_cast<size_t>(kHelloWorldClassLen) &&
           std::memcmp(bytes.data(), kHelloWorldClass, bytes.size()) == 0);
    for (int repeat = 0; repeat < 2; ++repeat) {
        amcl::jni::LocalFrame frame(env); assert(frame.valid());
        jclass urlsClass = env->FindClass("java/net/URL"); assert(urlsClass && !env->ExceptionCheck());
        jclass loaderClass = env->FindClass("java/net/URLClassLoader"); assert(loaderClass && !env->ExceptionCheck());
        jmethodID ctor = env->GetMethodID(loaderClass, "<init>", "([Ljava/net/URL;Ljava/lang/ClassLoader;)V"); assert(ctor && !env->ExceptionCheck());
        jobjectArray urls = env->NewObjectArray(0, urlsClass, nullptr); assert(urls && !env->ExceptionCheck());
        jobject loader = env->NewObject(loaderClass, ctor, urls, static_cast<jobject>(nullptr)); assert(loader && !env->ExceptionCheck());
        jclass hello = env->DefineClass("HelloWorld", loader, reinterpret_cast<const jbyte*>(bytes.data()), static_cast<jsize>(bytes.size()));
        assert(hello && !env->ExceptionCheck());
        jmethodID main = env->GetStaticMethodID(hello, "main", "([Ljava/lang/String;)V"); assert(main && !env->ExceptionCheck());
        jclass strings = env->FindClass("java/lang/String"); assert(strings && !env->ExceptionCheck());
        jobjectArray empty = env->NewObjectArray(0, strings, nullptr); assert(empty && !env->ExceptionCheck());
        env->CallStaticVoidMethod(hello, main, empty); assert(!env->ExceptionCheck());
    }
    assert(vm->DestroyJavaVM() == JNI_OK);
    std::printf("PASS real JNI VM=%s mode=%s: attached/native-thread/Unicode/main-exception/repeated isolated diagnostic\n", argv[2], argv[5]);
}
