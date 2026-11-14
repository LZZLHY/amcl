/**
 * 宿主 Invocation 调用的线程与错误边界。仅使用公开 JNI，不缓存其他线程的 JNIEnv。
 * 类加载、数组准备和 main 执行每一步都检查首个失败；调用者提供局部引用帧，并在帧
 * 结束前消费 Failure::exception。processor 的类加载回退仅接受明确 ClassNotFoundException。
 */
#ifndef AMCL_JNI_INVOCATION_SUPPORT_H
#define AMCL_JNI_INVOCATION_SUPPORT_H
#include "jni.h"
#include "jni_mutf8.h"
#include <climits>
#include <string>
#include <vector>

namespace amcl::jni {

/** 独立launcher在Java main返回后结束其Java线程身份，再等待其他非daemon及shutdown hooks。
 * 与上游libjli LEAVE顺序一致：DestroyJavaVM会为已detach的native线程建立新的等待身份，
 * 因而其他Java线程对原main的join/isAlive不会与销毁等待互锁。调用者须先关闭调用闸门，
 * 释放所有当前JNI局部帧并确认没有Java栈/自有观察者；detach失败时不能继续伪装销毁成功。
 */
struct LauncherCompletion {
    jint detached = JNI_ERR;
    jint destroyed = JNI_ERR;
};
inline LauncherCompletion finishLauncherVm(JavaVM* vm) {
    LauncherCompletion result;
    if (!vm) return result;
    result.detached = vm->DetachCurrentThread();
    if (result.detached == JNI_OK) result.destroyed = vm->DestroyJavaVM();
    return result;
}

/** 获取当前线程环境，仅为本次成功附加负责 detach；失败不能留下可解引用的假指针。 */
class Environment {
public:
    Environment(JavaVM* vm, jint version, bool daemon = false) : vm_(vm) {
        if (!vm_) { status_ = JNI_ERR; return; }
        status_ = vm_->GetEnv(reinterpret_cast<void**>(&env_), version);
        if (status_ == JNI_EDETACHED) {
            env_ = nullptr;
            JavaVMAttachArgs args{version, nullptr, nullptr};
            status_ = daemon ? vm_->AttachCurrentThreadAsDaemon(reinterpret_cast<void**>(&env_), &args)
                             : vm_->AttachCurrentThread(reinterpret_cast<void**>(&env_), &args);
            attached_ = status_ == JNI_OK;
        }
        if (status_ != JNI_OK || !env_) {
            // 即使异常实现返回 OK + null，也不能借用旧 env；已成功附加则仍承担清理责任。
            if (status_ == JNI_OK) status_ = JNI_ERR;
            env_ = nullptr;
        }
    }
    Environment(const Environment&) = delete;
    Environment& operator=(const Environment&) = delete;
    ~Environment() { finish(); }
    JNIEnv* get() const { return env_; }
    jint status() const { return status_; }
    /** 显式结束可让外层记录 detach 失败；析构只作未显式结束时的兜底。 */
    jint finish() {
        if (!attached_) return JNI_OK;
        attached_ = false;
        env_ = nullptr;
        return vm_->DetachCurrentThread();
    }
private:
    JavaVM* vm_ = nullptr;
    JNIEnv* env_ = nullptr;
    jint status_ = JNI_ERR;
    bool attached_ = false;
};

/** native 主动进入 Java 没有自动局部引用帧；逐次建立并只弹出确已建立的帧。 */
class LocalFrame {
public:
    explicit LocalFrame(JNIEnv* env, jint capacity = 32) : env_(env) {
        pushed_ = env_ && env_->PushLocalFrame(capacity) == JNI_OK;
    }
    ~LocalFrame() { if (pushed_) env_->PopLocalFrame(nullptr); }
    bool valid() const { return pushed_; }
    LocalFrame(const LocalFrame&) = delete;
    LocalFrame& operator=(const LocalFrame&) = delete;
private:
    JNIEnv* env_;
    bool pushed_ = false;
};

/** 错误对象属于调用者局部帧。首个错误一旦记录，后续诊断失败不得覆盖它。 */
struct Failure {
    const char* stage = nullptr;
    jthrowable exception = nullptr;
    bool enteredMain = false;
    bool record(JNIEnv* env, const char* operation) {
        if (!stage) {
            stage = operation;
            if (env->ExceptionCheck()) {
                exception = env->ExceptionOccurred();
                env->ExceptionClear();
            }
        }
        return false;
    }
    template<class T> bool require(JNIEnv* env, T value, const char* operation) {
        return (value && !env->ExceptionCheck()) || record(env, operation);
    }
    bool check(JNIEnv* env, const char* operation) {
        return !env->ExceptionCheck() || record(env, operation);
    }
};

/** 一次 loadClass 只有明确找不到目标类才允许回退；OOM、链接/初始化/权限异常立即返回。 */
inline bool acceptClassMiss(JNIEnv* env, jclass missingClass, jclass& result, Failure& failure, const char* stage) {
    if (!env->ExceptionCheck()) return result || failure.record(env, stage);
    jthrowable exception = env->ExceptionOccurred();
    env->ExceptionClear();
    const bool expected = exception && missingClass && env->IsInstanceOf(exception, missingClass);
    if (expected && !env->ExceptionCheck()) {
        env->DeleteLocalRef(exception);
        result = nullptr;
        return true;
    }
    // IsInstanceOf 不应产生 Java 异常；如目标实现违反约定，也优先保留最初 loadClass 异常。
    if (env->ExceptionCheck()) env->ExceptionClear();
    failure.stage = stage; failure.exception = exception;
    return false;
}

/** 按既有独立 processor 契约创建 URLClassLoader；循环中的局部引用逐项释放以支持长 classpath。 */
inline jclass loadProcessorFallback(JNIEnv* env, const std::string& classpath, jstring name,
                                    jclass missingClass, Failure& failure) {
    jclass urlClass = env->FindClass("java/net/URL");
    if (!failure.require(env, urlClass, "FindClass(URL)")) return nullptr;
    jclass fileClass = env->FindClass("java/io/File");
    if (!failure.require(env, fileClass, "FindClass(File)")) return nullptr;
    jclass uriClass = env->FindClass("java/net/URI");
    if (!failure.require(env, uriClass, "FindClass(URI)")) return nullptr;
    jclass loaderClass = env->FindClass("java/net/URLClassLoader");
    if (!failure.require(env, loaderClass, "FindClass(URLClassLoader)")) return nullptr;
    jmethodID fileCtor = env->GetMethodID(fileClass, "<init>", "(Ljava/lang/String;)V");
    if (!failure.require(env, fileCtor, "File.<init>")) return nullptr;
    jmethodID toUri = env->GetMethodID(fileClass, "toURI", "()Ljava/net/URI;");
    if (!failure.require(env, toUri, "File.toURI")) return nullptr;
    jmethodID toUrl = env->GetMethodID(uriClass, "toURL", "()Ljava/net/URL;");
    if (!failure.require(env, toUrl, "URI.toURL")) return nullptr;
    jmethodID loaderCtor = env->GetMethodID(loaderClass, "<init>", "([Ljava/net/URL;Ljava/lang/ClassLoader;)V");
    if (!failure.require(env, loaderCtor, "URLClassLoader.<init>")) return nullptr;
    jmethodID load = env->GetMethodID(loaderClass, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
    if (!failure.require(env, load, "URLClassLoader.loadClass")) return nullptr;
    std::vector<std::string> paths;
    size_t begin = 0;
    while (begin <= classpath.size()) {
        const size_t separator = classpath.find(':', begin);
        const size_t end = separator == std::string::npos ? classpath.size() : separator;
        // Java classpath 的空条目表示当前目录，不能在兼容回退时悄悄丢掉。
        paths.push_back(end == begin ? "." : classpath.substr(begin, end - begin));
        if (separator == std::string::npos) break;
        begin = separator + 1;
    }
    if (paths.size() > INT_MAX) { failure.record(env, "classpath exceeds JNI array range"); return nullptr; }
    jobjectArray urls = env->NewObjectArray(static_cast<jsize>(paths.size()), urlClass, nullptr);
    if (!failure.require(env, urls, "NewObjectArray(URL)")) return nullptr;
    for (size_t index = 0; index < paths.size(); ++index) {
        jstring path = env->NewStringUTF(amcl::toModifiedUtf8(paths[index]).c_str());
        if (!failure.require(env, path, "NewStringUTF(classpath)")) return nullptr;
        jobject file = env->NewObject(fileClass, fileCtor, path);
        if (!failure.require(env, file, "NewObject(File)")) return nullptr;
        jobject uri = env->CallObjectMethod(file, toUri);
        if (!failure.require(env, uri, "File.toURI()")) return nullptr;
        jobject url = env->CallObjectMethod(uri, toUrl);
        if (!failure.require(env, url, "URI.toURL()")) return nullptr;
        env->SetObjectArrayElement(urls, static_cast<jsize>(index), url);
        if (!failure.check(env, "SetObjectArrayElement(URL)")) return nullptr;
        env->DeleteLocalRef(url); env->DeleteLocalRef(uri); env->DeleteLocalRef(file); env->DeleteLocalRef(path);
    }
    jobject loader = env->NewObject(loaderClass, loaderCtor, urls, static_cast<jobject>(nullptr));
    if (!failure.require(env, loader, "NewObject(URLClassLoader)")) return nullptr;
    jclass threadClass = env->FindClass("java/lang/Thread");
    if (!failure.require(env, threadClass, "FindClass(Thread)")) return nullptr;
    jmethodID current = env->GetStaticMethodID(threadClass, "currentThread", "()Ljava/lang/Thread;");
    if (!failure.require(env, current, "Thread.currentThread")) return nullptr;
    jmethodID setContext = env->GetMethodID(threadClass, "setContextClassLoader", "(Ljava/lang/ClassLoader;)V");
    if (!failure.require(env, setContext, "Thread.setContextClassLoader")) return nullptr;
    jobject thread = env->CallStaticObjectMethod(threadClass, current);
    if (!failure.require(env, thread, "Thread.currentThread()")) return nullptr;
    env->CallVoidMethod(thread, setContext, loader);
    if (!failure.check(env, "Thread.setContextClassLoader()")) return nullptr;
    jclass result = static_cast<jclass>(env->CallObjectMethod(loader, load, name));
    if (!acceptClassMiss(env, missingClass, result, failure, "URLClassLoader.loadClass()")) return nullptr;
    return result;
}

/**
 * 在调用者局部帧中准备并执行 main。beforeMain 只在全部 JNI 输入成功后调用；用于现有
 * 可选诊断启动。失败明确区分 main 前和 main 内，不以“类未找到”覆盖任意其他异常。
 */
template<class BeforeMain>
bool callMain(JNIEnv* env, const char* className, int argc, const char** argv, bool processor,
              const std::string& classpath, Failure& failure, BeforeMain&& beforeMain) {
    if (!className || !className[0] || argc < 0 || (argc && !argv)) return failure.record(env, "invalid main arguments");
    for (int index = 0; index < argc; ++index) if (!argv[index]) return failure.record(env, "null main argument");
    std::string dotted(className), slashed(className);
    for (char& c : dotted) if (c == '/') c = '.';
    for (char& c : slashed) if (c == '.') c = '/';
    jclass missingClass = nullptr;
    if (processor) {
        missingClass = env->FindClass("java/lang/ClassNotFoundException");
        if (!failure.require(env, missingClass, "FindClass(ClassNotFoundException)")) return false;
    }
    jclass loaderClass = env->FindClass("java/lang/ClassLoader");
    if (!failure.require(env, loaderClass, "FindClass(ClassLoader)")) return false;
    jmethodID getSystem = env->GetStaticMethodID(loaderClass, "getSystemClassLoader", "()Ljava/lang/ClassLoader;");
    if (!failure.require(env, getSystem, "ClassLoader.getSystemClassLoader")) return false;
    jmethodID load = env->GetMethodID(loaderClass, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
    if (!failure.require(env, load, "ClassLoader.loadClass")) return false;
    jobject system = env->CallStaticObjectMethod(loaderClass, getSystem);
    if (!failure.require(env, system, "ClassLoader.getSystemClassLoader()")) return false;
    jstring name = env->NewStringUTF(amcl::toModifiedUtf8(dotted).c_str());
    if (!failure.require(env, name, "NewStringUTF(main class)")) return false;
    jclass target = static_cast<jclass>(env->CallObjectMethod(system, load, name));
    if (!acceptClassMiss(env, missingClass, target, failure, "ClassLoader.loadClass()")) return false;
    if (!target && processor && !classpath.empty()) {
        target = loadProcessorFallback(env, classpath, name, missingClass, failure);
        if (failure.stage) return false;
    }
    if (!target && processor) {
        target = env->FindClass(amcl::toModifiedUtf8(slashed).c_str());
        if (!failure.require(env, target, "FindClass(main fallback)")) return false;
    }
    if (!failure.require(env, target, "main class missing")) return false;
    jmethodID main = env->GetStaticMethodID(target, "main", "([Ljava/lang/String;)V");
    if (!failure.require(env, main, "GetStaticMethodID(main)")) return false;
    jclass stringClass = env->FindClass("java/lang/String");
    if (!failure.require(env, stringClass, "FindClass(String)")) return false;
    jobjectArray arguments = env->NewObjectArray(argc, stringClass, nullptr);
    if (!failure.require(env, arguments, "NewObjectArray(main arguments)")) return false;
    for (int index = 0; index < argc; ++index) {
        jstring value = env->NewStringUTF(amcl::toModifiedUtf8(argv[index]).c_str());
        if (!failure.require(env, value, "NewStringUTF(main argument)")) return false;
        env->SetObjectArrayElement(arguments, index, value);
        if (!failure.check(env, "SetObjectArrayElement(main argument)")) return false;
        env->DeleteLocalRef(value);
    }
    beforeMain();
    failure.enteredMain = true;
    env->CallStaticVoidMethod(target, main, arguments);
    return failure.check(env, "main() threw");
}
}
#endif
