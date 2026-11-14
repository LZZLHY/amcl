/**
 * 真实应用环境中的平台前置验证。使用官方 NativeChildProcess 启动独立进程，
 * 不在 ArkTS/UI 线程等待；不把 hdc shell 或 QEMU 资格外推到应用沙箱。
 * 本进程只允许一次运行，退出回调与报告同时收取，失败证据保留原始错误。
 */
#include "napi_jdk_probe.h"
#ifdef MC_OHOS_BUILD_TESTS
#include "napi_helpers.h"
#include "jdk_tls_lifecycle_probe.h"
#include "../jvm/elf_loader.h"
#include "../jvm/thread_terminal_token.h"
#include "../platform/jdk_font_resources.h"
#include "../platform/jdk_install_io.h"
#include "../platform/jdk_install_store.h"
#include "../../../../../prebuilt/jdk/25/shims/cpu_time_timer_ohos.hpp"
#include <AbilityKit/native_child_process.h>
#include <atomic>
#include <chrono>
#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <memory>
#include <new>
#include <poll.h>
#include <spawn.h>
#include <sstream>
#include <string>
#include <stdexcept>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/statvfs.h>
#include <sys/vfs.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

extern char** environ;
// 编译器把 __clear_cache 识别为 builtin 并禁止取地址；别名只指定同一 ELF 符号，
// 保证探针调用本项目真实导出，既不生成另一实现，也不被替换成编译器内部展开。
extern "C" void amclProbeClearCache(void* start, void* end) __asm__("__clear_cache");
extern "C" __attribute__((visibility("default")))
void AmclJdkProbeMain(NativeChildProcess_Args args);

// 只供 TestHooks 原生子进程中的固定 C++ 夹具调用。计数属于当前线程，不能把
// 加载成功日志当作构造/异常清理已经执行；正式非测试产品没有这些导出。
static thread_local int unwindCleanupCount = 0;
static thread_local int unwindConstructorCount = 0;
extern "C" __attribute__((visibility("default"))) void unwind_mark(int value) { unwindCleanupCount += value; }
extern "C" __attribute__((visibility("default"))) void unwind_initialized() { ++unwindConstructorCount; }

namespace {
/** 只在本次新建的专属根运行真实安装事务。小型夹具不执行目标代码，也不接触用户JDK槽；
 * 夹具由维护者明确发送到固定文件名，完整摘要在同一次打开文件的边界重新核验。 */
void installStorageProbe(const std::string& files, std::ostringstream& report) {
    namespace io = amcl::jdk::io;
    const std::string fixture = "jdk-install-probe.zip";
    std::string step = "fixture";
    std::string rootPath;
    try {
        auto filesRoot = io::Directory(files);
        if (!io::Exists(filesRoot.get(), fixture)) {
            report << "installStorage fixtureAvailable=0\n"; return;
        }
        const auto archiveSha = io::Digest(io::SmallFile(filesRoot.get(), fixture, 1024 * 1024));
        rootPath = files + "/jdk-install-qa-" + std::to_string(getpid());
        step = "isolated-root";
        io::Require(mkdir(rootPath.c_str(), 0700) == 0, "测试根已存在或无法创建，拒绝复用");
        auto root = io::Directory(rootPath);
        auto jdk = io::ChildDirectory(root.get(), "jdk", true);
        auto locks = io::ChildDirectory(jdk.get(), ".locks", true);
        auto openLease = [&](const char* name) {
            io::Fd value(openat(locks.get(), name, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600));
            if (value.get() < 0) io::Error("无法建立测试租约");
            return value;
        };
        auto writer = openLease("17.writer");
        io::Require(flock(writer.get(), LOCK_EX | LOCK_NB) == 0, "测试writer失败");
        report << "installStorage root=" << rootPath << " archiveSha=" << archiveSha << '\n';
        for (int iteration = 0; iteration < 2; ++iteration) {
            step = "stage";
            const auto stage = amcl::jdk::CreateInstallStage(rootPath, "17", writer.get());
            step = "extract";
            amcl::jdk::ExtractInstallArchive(files + "/" + fixture, stage, archiveSha, 5000);
            step = "seal";
            amcl::jdk::SealInstallStage(stage, "17", archiveSha);
            auto staged = io::Directory(stage);
            struct stat before{};
            io::Require(fstat(staged.get(), &before) == 0, "无法读取staging身份");
            auto reader = openLease("17.use");
            io::Require(flock(reader.get(), LOCK_SH | LOCK_NB) == 0, "测试reader失败");
            auto use = openLease("17.use");
            step = "reader-exclusion";
            bool refused = false;
            try { amcl::jdk::PublishInstallStage(rootPath, "17", stage, writer.get(), use.get()); }
            catch (const std::exception&) { refused = true; }
            io::Require(refused, "已有独立OFD读者时发布未拒绝");
            reader = io::Fd();
            step = "publish";
            io::Require(flock(use.get(), LOCK_EX | LOCK_NB) == 0, "读者退出后测试use.EX失败");
            amcl::jdk::PublishInstallStage(rootPath, "17", stage, writer.get(), use.get());
            amcl::jdk::DiscardInstallStage(rootPath, "17", stage, writer.get());
            auto installed = io::ChildDirectory(jdk.get(), "17");
            struct stat after{}, helper{};
            io::Require(fstat(installed.get(), &after) == 0 &&
                        fstatat(installed.get(), "lib/jspawnhelper", &helper, AT_SYMLINK_NOFOLLOW) == 0,
                        "无法回读发布后的身份/权限");
            io::Require(before.st_dev == after.st_dev && before.st_ino == after.st_ino,
                        "同目录rename改变了staging身份");
            io::Require(S_ISREG(helper.st_mode) && (helper.st_mode & 07777) == 0755,
                        "helper执行权限未真实生效");
            const auto payload = io::SmallFile(installed.get(), "conf/中文 空格.txt");
            io::Require(payload == "configuration\n" && !amcl::jdk::InstallRecoveryRequired(rootPath, "17"),
                        "载荷或journal回读不一致");
            report << "installStorage iteration=" << iteration << " readerExcluded=" << refused
                   << " renameIdentity=1 helperMode=0755 payload=1 journalAbsent=1\n";
            if (iteration == 1) {
                step = "delete";
                amcl::jdk::DeleteInstallSlot(rootPath, "17", writer.get(), use.get());
                io::Require(!io::Exists(jdk.get(), "17") && !amcl::jdk::InstallRecoveryRequired(rootPath, "17"),
                            "测试删除事务没有完成");
            }
        }
        io::Require(io::Digest(io::SmallFile(filesRoot.get(), fixture, 1024 * 1024)) == archiveSha,
                    "测试原ZIP被改变");
        report << "installStorage passed=1 scope=target-filesystem-small-fixture-no-power-loss\n";
    } catch (const std::exception& error) {
        report << "installStorage passed=0 step=" << step << " root=" << rootPath
               << " error=" << error.what() << '\n';
    }
}

// fontconfig 的公开 C API 使用不透明对象；不读取库私有结构，也不把库名存在当字体可用。
struct FcConfig;
struct FcPattern;
struct FcCharSet;
struct FcStrList;
enum FcResult { FcResultMatch = 0, FcResultNoMatch, FcResultTypeMismatch, FcResultNoId, FcResultOutOfMemory };

struct FontCacheSnapshot { size_t files = 0; uint64_t bytes = 0; std::string identity; };
/** 只观察宿主自己的缓存文件元数据；读回稳定inode/大小/纳秒修改时间以识别热加载重写。 */
FontCacheSnapshot fontCacheSnapshot(const std::string& path) {
    auto root = amcl::jdk::io::Directory(path);
    auto names = amcl::jdk::io::Names(root.get());
    std::sort(names.begin(), names.end());
    std::ostringstream identity;
    FontCacheSnapshot result;
    for (const auto& name : names) {
        const auto marker = name.rfind(".cache-");
        if (marker == std::string::npos || marker + 7 == name.size() ||
            !std::all_of(name.begin() + marker + 7, name.end(), [](char value) { return value >= '0' && value <= '9'; })) continue;
        struct stat value{};
        if (fstatat(root.get(), name.c_str(), &value, AT_SYMLINK_NOFOLLOW)) amcl::jdk::io::Error("无法观察字体缓存");
        if (!S_ISREG(value.st_mode)) continue;
        ++result.files; result.bytes += value.st_size;
        identity << name << ':' << value.st_ino << ':' << value.st_size << ':'
                 << value.st_mtim.tv_sec << ':' << value.st_mtim.tv_nsec << '\n';
    }
    result.identity = amcl::jdk::io::Digest(identity.str());
    return result;
}

/** 当前真实应用 namespace 中完成配置→字体匹配→可读文件→中文字符覆盖；不改 JDK 槽。 */
void fontProviderProbe(const std::string& files, std::ostringstream& report) {
    std::string configPath, classicPath, error;
    if (!amcl::jdk::PrepareFontResources(files, configPath, classicPath, error)) {
        report << "fontConfiguration prepared=0 error=" << error << '\n'; return;
    }
    if (setenv("FONTCONFIG_FILE", configPath.c_str(), 1) != 0) {
        report << "fontConfiguration prepared=1 environmentError=" << errno << '\n'; return;
    }
    report << "fontConfiguration prepared=1 path=" << configPath << '\n';
    for (const char* name : {"libfontconfig.so.1", "libfontconfig.so"}) {
        void* library = dlopen(name, RTLD_NOW | RTLD_LOCAL);
        if (!library) {
            const char* failure = dlerror();
            report << "fontProvider name=" << name << " loaded=0 error=" << (failure ? failure : "unknown") << '\n';
            continue;
        }
        std::unique_ptr<void, decltype(&dlclose)> owned(library, dlclose);
        auto version = reinterpret_cast<int(*)()>(dlsym(library, "FcGetVersion"));
        auto initialize = reinterpret_cast<FcConfig*(*)()>(dlsym(library, "FcInitLoadConfigAndFonts"));
        auto parse = reinterpret_cast<FcPattern*(*)(const unsigned char*)>(dlsym(library, "FcNameParse"));
        auto substitute = reinterpret_cast<int(*)(FcConfig*, FcPattern*, int)>(dlsym(library, "FcConfigSubstitute"));
        auto defaults = reinterpret_cast<void(*)(FcPattern*)>(dlsym(library, "FcDefaultSubstitute"));
        auto match = reinterpret_cast<FcPattern*(*)(FcConfig*, FcPattern*, FcResult*)>(dlsym(library, "FcFontMatch"));
        auto string = reinterpret_cast<FcResult(*)(const FcPattern*, const char*, int, unsigned char**)>(dlsym(library, "FcPatternGetString"));
        auto charset = reinterpret_cast<FcResult(*)(const FcPattern*, const char*, int, FcCharSet**)>(dlsym(library, "FcPatternGetCharSet"));
        auto hasCharacter = reinterpret_cast<int(*)(const FcCharSet*, unsigned int)>(dlsym(library, "FcCharSetHasChar"));
        auto destroyPattern = reinterpret_cast<void(*)(FcPattern*)>(dlsym(library, "FcPatternDestroy"));
        auto destroyConfig = reinterpret_cast<void(*)(FcConfig*)>(dlsym(library, "FcConfigDestroy"));
        auto cacheDirs = reinterpret_cast<FcStrList*(*)(FcConfig*)>(dlsym(library, "FcConfigGetCacheDirs"));
        auto nextString = reinterpret_cast<unsigned char*(*)(FcStrList*)>(dlsym(library, "FcStrListNext"));
        auto destroyList = reinterpret_cast<void(*)(FcStrList*)>(dlsym(library, "FcStrListDone"));
        const bool api = version && initialize && parse && substitute && defaults && match && string &&
                         charset && hasCharacter && destroyPattern && destroyConfig && cacheDirs && nextString && destroyList;
        Dl_info origin{};
        if (version) dladdr(reinterpret_cast<void*>(version), &origin);
        report << "fontProvider name=" << name << " loaded=1 api=" << api
               << " origin=" << (origin.dli_fname ? origin.dli_fname : "unknown");
        if (!api) { report << " passed=0\n"; continue; }
        report << " version=" << version() << '\n';
        const auto cachePath = files + "/runtime-fonts/cache";
        const auto beforeCache = fontCacheSnapshot(cachePath);
        const auto firstStarted = std::chrono::steady_clock::now();
        std::unique_ptr<FcConfig, decltype(destroyConfig)> configuration(initialize(), destroyConfig);
        const auto firstUs = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - firstStarted).count();
        size_t actualCacheDirs = 0;
        bool correctCache = false;
        if (configuration) {
            std::unique_ptr<FcStrList, decltype(destroyList)> directories(cacheDirs(configuration.get()), destroyList);
            if (directories) for (unsigned char* directory; (directory = nextString(directories.get())) != nullptr;) {
                if (++actualCacheDirs > 32) { correctCache = false; break; }
                const std::string actual(reinterpret_cast<const char*>(directory));
                correctCache = actual == cachePath && access(actual.c_str(), W_OK) == 0;
                report << "fontCacheDirectory value=" << actual << " expected=" << correctCache << '\n';
            }
        }
        std::unique_ptr<FcPattern, decltype(destroyPattern)> pattern(parse(reinterpret_cast<const unsigned char*>("sans:lang=zh-cn")), destroyPattern);
        if (!configuration || !pattern || !substitute(configuration.get(), pattern.get(), 0)) {
            report << "fontMatch initialized=" << bool(configuration) << " pattern=" << bool(pattern) << " passed=0\n";
            continue;
        }
        defaults(pattern.get());
        FcResult result = FcResultNoMatch;
        std::unique_ptr<FcPattern, decltype(destroyPattern)> selected(match(configuration.get(), pattern.get(), &result), destroyPattern);
        unsigned char* filename = nullptr;
        FcCharSet* characters = nullptr;
        const bool named = selected && string(selected.get(), "file", 0, &filename) == FcResultMatch && filename;
        const int readable = named ? access(reinterpret_cast<const char*>(filename), R_OK) : -1;
        const bool chinese = selected && charset(selected.get(), "charset", 0, &characters) == FcResultMatch &&
                             characters && hasCharacter(characters, 0x4e2d);
        report << "fontMatch result=" << int(result) << " file=" << (named ? reinterpret_cast<const char*>(filename) : "none")
               << " readable=" << (readable == 0) << " containsU4E2D=" << chinese
               << " passed=" << (result == FcResultMatch && named && readable == 0 && chinese) << '\n';
        const auto firstCache = fontCacheSnapshot(cachePath);
        selected.reset(); pattern.reset(); configuration.reset();
        const auto hotStarted = std::chrono::steady_clock::now();
        std::unique_ptr<FcConfig, decltype(destroyConfig)> hot(initialize(), destroyConfig);
        const auto hotUs = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - hotStarted).count();
        const auto hotCache = fontCacheSnapshot(cachePath);
        report << "fontCache beforeFiles=" << beforeCache.files << " afterFiles=" << firstCache.files
               << " bytes=" << firstCache.bytes << " firstWasCold=" << (beforeCache.files == 0)
               << " firstUs=" << firstUs << " hotUs=" << hotUs
               << " unchangedOnHot=" << (firstCache.identity == hotCache.identity)
               << " passed=" << (hot && actualCacheDirs == 1 && correctCache && firstCache.files > 0 &&
                   firstCache.identity == hotCache.identity) << '\n';
        // 只释放本次拥有的对象，不调用全局 FcFini 破坏同进程其他字体使用者。
        return;
    }
}

using UnwindFrame = void (*)(void (*)());
thread_local UnwindFrame secondUnwindFrame = nullptr;
/** 固定异常从宿主发起；必须穿过夹具的 RAII 清理帧后被当前探针捕获。 */
void throwUnwindFixture() { throw std::runtime_error("device-unwind-ok"); }
/** 在两个自加载帧之间插入宿主帧，覆盖自加载/系统/自加载的真实混合调用链。 */
void nestedUnwindFixture() { secondUnwindFrame(throwUnwindFixture); }

/**
 * 真正从应用沙箱加载固定编译夹具，经生产 loader 自动登记后跨越两个 native 帧。
 * 文件由负责人按 SHA 发送，入口不接收可变命令/库名；只记录已实际发生的计数。
 */
void unwindProbe(const std::string& files, std::ostringstream& report) {
    const std::string directory = files + "/jdk-unwind-probes";
    if (access((directory + "/libelf_unwind_subject.so").c_str(), R_OK) != 0) {
        report << "unwindFixturesAvailable=0\n"; return;
    }
    Dl_info provider{};
    using SystemHandle = std::unique_ptr<void, decltype(&dlclose)>;
    SystemHandle providerHandle(dlopen("libc++_shared.so", RTLD_NOW | RTLD_NOLOAD), dlclose);
    void* registeredApi = providerHandle ? dlsym(providerHandle.get(), "amcl_unwind_register_image") : nullptr;
    report << "unwindProviderApi=" << (registeredApi != nullptr);
    if (registeredApi && dladdr(registeredApi, &provider) && provider.dli_fname)
        report << " path=" << provider.dli_fname;
    report << '\n';
    elf_set_search_path(directory.c_str());
    unwindCleanupCount = unwindConstructorCount = 0;
    bool passed = registeredApi != nullptr;
    using Handle = std::unique_ptr<elf_handle_t, decltype(&elf_close)>;
    for (const char* name : {"badheader", "badcie"}) {
        Handle rejected(elf_open((directory + "/libelf_unwind_" + name + ".so").c_str()), elf_close);
        if (rejected || unwindConstructorCount != 0) passed = false;
        report << "unwindReject kind=" << name << " rejected=" << !rejected << " constructors=" << unwindConstructorCount << '\n';
    }
    auto callAndCatch = [&](UnwindFrame frame, void (*callback)()) {
        if (!frame) { passed = false; return; }
        try { frame(callback); passed = false; }
        catch (const std::runtime_error& error) { if (strcmp(error.what(), "device-unwind-ok") != 0) passed = false; }
        catch (...) { passed = false; }
    };
    {
        Handle first(elf_open((directory + "/libelf_unwind_subject.so").c_str()), elf_close);
        Handle second(elf_open((directory + "/libelf_unwind_second.so").c_str()), elf_close);
        Handle extra(elf_open((directory + "/libelf_unwind_subject.so").c_str()), elf_close);
        const bool sameInstance = first && extra && first.get() == extra.get();
        first.reset(); // 消费一个引用，另一个公开引用必须继续支撑下方真实异常调用。
        first = std::move(extra);
        passed = passed && sameInstance;
        report << "unwindRepeatedOpen=" << sameInstance << '\n';
        if (!first || !second) {
            report << "unwindLoadError=" << elf_error() << '\n'; passed = false;
        } else {
            auto frame = reinterpret_cast<UnwindFrame>(elf_sym(first.get(), "frame_call"));
            secondUnwindFrame = reinterpret_cast<UnwindFrame>(elf_sym(second.get(), "frame_call"));
            callAndCatch(frame, throwUnwindFixture);
            if (secondUnwindFrame) callAndCatch(frame, nestedUnwindFixture);
            else passed = false;
        }
        secondUnwindFrame = nullptr;
    }
    for (const char* name : {"noheader", "stripped"}) {
        Handle handle(elf_open((directory + "/libelf_unwind_" + name + ".so").c_str()), elf_close);
        if (!handle) { report << "unwindLoadError=" << elf_error() << '\n'; passed = false; }
        else callAndCatch(reinterpret_cast<UnwindFrame>(elf_sym(handle.get(), "frame_call")), throwUnwindFixture);
    }
    passed = passed && unwindCleanupCount == 5 && unwindConstructorCount == 4;
    report << "unwindCleanup=" << unwindCleanupCount << " constructors=" << unwindConstructorCount
           << " expectedCleanup=5 expectedConstructors=4 passed=" << passed << '\n';
}
/** FD 在全部早退/异常路径自动关闭；不转移所有权、不隐式复制句柄。 */
struct Fd {
    int value;
    explicit Fd(int fd = -1) : value(fd) {}
    ~Fd() { if (value >= 0) close(value); }
    Fd(const Fd&) = delete;
    Fd& operator=(const Fd&) = delete;
};

/**
 * 四组独立写者/执行者在真实 AArch64 上更新并执行机器码，触发生产导出 cache flush。
 * release/acquire 仅负责发布和禁止并发改写正在执行的代码；指令可见性由被测入口保证。
 * 不调用编译器 builtin 替代入口。线程创建失败会释放启动屏障并回收已创建的线程和映射。
 */
void cacheFlushProbe(std::ostringstream& report) {
    struct Pair {
        void* memory = MAP_FAILED;
        unsigned group = 0;
        std::atomic<bool>* start = nullptr;
        std::atomic<bool>* cancel = nullptr;
        std::atomic<unsigned> published{0}, consumed{0};
        unsigned executed = 0, mismatches = 0;
        static void* writeCode(void* opaque) {
            auto& pair = *static_cast<Pair*>(opaque);
            while (!pair.start->load(std::memory_order_acquire)) std::this_thread::yield();
            if (pair.cancel->load(std::memory_order_acquire)) return nullptr;
            void (*volatile flush)(void*, void*) = &amclProbeClearCache;
            for (unsigned round = 1; round <= 256; ++round) {
                // 指令范围改变起点，包含非缓存行对齐及跨行位置。
                auto* code = reinterpret_cast<uint32_t*>(static_cast<char*>(pair.memory) + ((round * 7) % 64) * 4);
                const unsigned expected = pair.group * 256 + round;
                code[0] = 0x52800000U | (expected << 5); // movz w0, #expected
                code[1] = 0xd65f03c0U;                 // ret
                flush(code, code + 2);
                pair.published.store(round, std::memory_order_release);
                while (pair.consumed.load(std::memory_order_acquire) != round) std::this_thread::yield();
            }
            return nullptr;
        }
        static void* executeCode(void* opaque) {
            auto& pair = *static_cast<Pair*>(opaque);
            while (!pair.start->load(std::memory_order_acquire)) std::this_thread::yield();
            if (pair.cancel->load(std::memory_order_acquire)) return nullptr;
            for (unsigned round = 1; round <= 256; ++round) {
                while (pair.published.load(std::memory_order_acquire) != round) std::this_thread::yield();
                // 执行侧同步自身的取指上下文；写者的 ISB 不能替另一个 PE 刷新预取状态。
#if defined(__aarch64__)
                __asm__ volatile("isb" ::: "memory");
#endif
                auto function = reinterpret_cast<unsigned (*)()>(static_cast<char*>(pair.memory) + ((round * 7) % 64) * 4);
                if (function() != pair.group * 256 + round) ++pair.mismatches;
                ++pair.executed;
                pair.consumed.store(round, std::memory_order_release);
            }
            return nullptr;
        }
    } pairs[4];
    std::atomic<bool> start{false}, cancel{false};
    pthread_t threads[8]{};
    unsigned created = 0, executed = 0, mismatches = 0;
    int error = 0;
    for (unsigned index = 0; index < 4 && !error; ++index) {
        auto& pair = pairs[index];
        pair.group = index; pair.start = &start; pair.cancel = &cancel;
        pair.memory = mmap(nullptr, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (pair.memory == MAP_FAILED) { error = errno; break; }
        error = pthread_create(&threads[created], nullptr, Pair::writeCode, &pair);
        if (!error) { ++created; error = pthread_create(&threads[created], nullptr, Pair::executeCode, &pair); }
        if (!error) ++created;
    }
    cancel.store(error != 0, std::memory_order_release);
    start.store(true, std::memory_order_release);
    for (unsigned index = 0; index < created; ++index) pthread_join(threads[index], nullptr);
    for (auto& pair : pairs) {
        executed += pair.executed; mismatches += pair.mismatches;
        if (pair.memory != MAP_FAILED) munmap(pair.memory, 4096);
    }
    report << "cacheFlush threads=" << created << " executed=" << executed << " mismatches=" << mismatches
           << " error=" << error << " passed=" << (!error && executed == 1024 && mismatches == 0) << '\n';
}

/**
 * 仅测目标内核接口，不根据 uname 或一次 ESRCH 宣布完整 TLS 终止协议合格。
 * Linux 公开 UAPI 中 PIDFD_THREAD 等于 O_EXCL；SDK 已公开 SYS_pidfd_open 编号。
 * 线程 token 在被测线程存活时取得，观察方不抢 join，最后只 join 自己创建的测试线程。
 */
void threadTerminalProbe(std::ostringstream& report) {
    struct TokenState {
        std::atomic<bool> ready{false}, finish{false};
        std::atomic<bool> dtorEntered{false}, dtorRelease{false};
        int tid = 0, pidfd = -1, pidfdError = 0, procfd = -1, procError = 0;
        int plainPidfd = -1, plainPidfdError = 0;
        amcl::threadterminal::Token checked;
        amcl::threadterminal::ExistenceProbe existence;
        int existenceError = 0;
        bool existenceCallbacksLive = true;
        int tokenError = 0;
        pthread_key_t key{};
        int keyError = 0, setspecificError = 0, tsdCalls = 0;
        bool callbacksLive = true;
        static void tsdDestructor(void* opaque) {
            auto* self = static_cast<TokenState*>(opaque);
            int error = 0;
            if (self->checked.observe(error) != amcl::threadterminal::Observation::Live) self->callbacksLive = false;
            if (self->existence.observe(error) != amcl::threadterminal::Observation::Live) self->existenceCallbacksLive = false;
            ++self->tsdCalls;
            if (self->tsdCalls < 2 && pthread_setspecific(self->key, self) != 0) self->callbacksLive = false;
        }
        ~TokenState() {
            if (!keyError) pthread_key_delete(key);
            if (pidfd >= 0) close(pidfd);
            if (plainPidfd >= 0) close(plainPidfd);
            if (procfd >= 0) close(procfd);
        }
    } state;
    state.keyError = pthread_key_create(&state.key, TokenState::tsdDestructor);
    std::thread worker([&] {
        struct DtorBarrier {
            TokenState* state = nullptr;
            ~DtorBarrier() {
                state->dtorEntered.store(true, std::memory_order_release);
                while (!state->dtorRelease.load(std::memory_order_acquire)) std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
        };
        thread_local DtorBarrier barrier;
        barrier.state = &state;
        state.tid = static_cast<int>(syscall(SYS_gettid));
        errno = 0;
        state.pidfd = static_cast<int>(syscall(SYS_pidfd_open, state.tid, O_EXCL));
        state.pidfdError = state.pidfd < 0 ? errno : 0;
        state.plainPidfd = static_cast<int>(syscall(SYS_pidfd_open, state.tid, 0));
        state.plainPidfdError = state.plainPidfd < 0 ? errno : 0;
        state.procfd = open("/proc/thread-self/stat", O_RDONLY | O_CLOEXEC);
        state.procError = state.procfd < 0 ? errno : 0;
        state.tokenError = state.checked.openCurrent();
        state.existenceError = state.existence.openCurrent();
        if (!state.keyError) state.setspecificError = pthread_setspecific(state.key, &state);
        state.ready.store(true, std::memory_order_release);
        while (!state.finish.load(std::memory_order_acquire)) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    });
    // 此区间只执行无分配的查询和同步，输出拼接安排在 join 之后，避免异常留下 joinable thread。
    while (!state.ready.load(std::memory_order_acquire)) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    pollfd event{state.pidfd, POLLIN, 0};
    const int livePoll = state.pidfd >= 0 ? poll(&event, 1, 0) : -2;
    const int liveEvents = event.revents;
    pollfd plain{state.plainPidfd, POLLIN, 0};
    const int plainLive = state.plainPidfd >= 0 ? poll(&plain, 1, 0) : -2;
    int checkedLiveError = 0;
    const auto checkedLive = state.checked.observe(checkedLiveError);
    int existenceLiveError = 0;
    const auto existenceLive = state.existence.observe(existenceLiveError);
    char live[8192], dead[8192];
    errno = 0;
    const ssize_t liveBytes = state.procfd >= 0 ? pread(state.procfd, live, sizeof(live), 0) : -1;
    const int liveError = liveBytes < 0 ? errno : 0;
    struct statfs fs{};
    const int fsStatus = state.procfd >= 0 ? fstatfs(state.procfd, &fs) : -1;
    state.finish.store(true, std::memory_order_release);
    const auto dtorDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(1);
    while (!state.dtorEntered.load(std::memory_order_acquire) && std::chrono::steady_clock::now() < dtorDeadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    int checkedDtorError = 0;
    const auto checkedDtor = state.checked.observe(checkedDtorError);
    int existenceDtorError = 0;
    const auto existenceDtor = state.existence.observe(existenceDtorError);
    const bool dtorObserved = state.dtorEntered.load(std::memory_order_acquire);
    state.dtorRelease.store(true, std::memory_order_release);
    event.revents = 0;
    const int exitPoll = state.pidfd >= 0 ? poll(&event, 1, 1000) : -2;
    const int exitEvents = event.revents;
    worker.join();
    plain.revents = 0;
    const int plainExited = state.plainPidfd >= 0 ? poll(&plain, 1, 0) : -2;
    errno = 0;
    const ssize_t deadBytes = state.procfd >= 0 ? pread(state.procfd, dead, sizeof(dead), 0) : -1;
    const int deadError = deadBytes < 0 ? errno : 0;
    int checkedExitError = 0;
    const auto checkedExit = state.checked.observe(checkedExitError);
    int existenceExitError = 0;
    const auto existenceExit = state.existence.observe(existenceExitError);
    report << "threadExistence openError=" << state.existenceError << " live=" << int(existenceLive)
           << " liveError=" << existenceLiveError << " duringDtor=" << int(existenceDtor)
           << " dtorError=" << existenceDtorError << " callbacksLive=" << state.existenceCallbacksLive
           << " afterJoin=" << int(existenceExit) << " exitError=" << existenceExitError << '\n';
    report << "threadTerminal tid=" << state.tid << " pidfdError=" << state.pidfdError
           << " livePoll=" << livePoll << " liveEvents=" << liveEvents
           << " exitPoll=" << exitPoll << " exitEvents=" << exitEvents
           << " procOpenError=" << state.procError << " fsStatus=" << fsStatus << " fsType=" << fs.f_type
           << " liveBytes=" << liveBytes << " liveError=" << liveError
           << " afterJoinBytes=" << deadBytes << " afterJoinError=" << deadError << '\n';
    report << "threadToken openError=" << state.tokenError << " live=" << static_cast<int>(checkedLive)
           << " liveError=" << checkedLiveError << " afterJoin=" << static_cast<int>(checkedExit)
           << " afterJoinError=" << checkedExitError << '\n';
    report << "threadPidfdPlain error=" << state.plainPidfdError << " live=" << plainLive
           << " afterJoin=" << plainExited << " events=" << plain.revents << '\n';
    report << "threadCallbacks dtorObserved=" << dtorObserved << " duringDtor=" << static_cast<int>(checkedDtor)
           << " duringDtorError=" << checkedDtorError << " tsdCalls=" << state.tsdCalls
           << " callbacksLive=" << state.callbacksLive << " keyError=" << state.keyError
           << " setspecificError=" << state.setspecificError << '\n';
    if (liveBytes > 0) report << "threadStatLive=" << std::string(live, static_cast<size_t>(liveBytes));
    if (deadBytes > 0) report << "threadStatAfterJoin=" << std::string(dead, static_cast<size_t>(deadBytes));
}

/**
 * 分离线程没有 join 观察者；先用同一 token 观察终止，再让局部记录结束生命。
 * 高周转仅报告实际完成量和是否遇到数字 TID 重用，未遇到重用不能冒称 ABA 已覆盖。
 */
template<class TokenType>
void threadTokenChurnProbe(std::ostringstream& report, const char* method) {
    using amcl::threadterminal::Observation;
    struct Detached {
        TokenType token;
        std::atomic<bool> ready{false}, release{false}, bodyDone{false};
        int openError = 0;
        static void* run(void* opaque) {
            auto* state = static_cast<Detached*>(opaque);
            state->openError = state->token.openCurrent();
            state->ready.store(true, std::memory_order_release);
            while (!state->release.load(std::memory_order_acquire)) std::this_thread::yield();
            // 最后一次访问局部记录；外层即使不能证明内核终止，也可以安全结束测试记录。
            state->bodyDone.store(true, std::memory_order_release);
            return nullptr;
        }
    };
    unsigned detachedCompleted = 0, detachedTerminal = 0, failures = 0;
    int lastDetachedOpen = 0, lastDetachedError = 0, lastDetachedState = -1;
    amcl::threadterminal::Failure detachedFailure = amcl::threadterminal::Failure::None;
    for (unsigned attempt = 0; attempt < 64; ++attempt) {
        Detached state;
        pthread_attr_t attributes;
        const int initialized = pthread_attr_init(&attributes);
        if (initialized) { ++failures; break; }
        const int detached = pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
        pthread_t thread{};
        const int created = detached ? detached : pthread_create(&thread, &attributes, Detached::run, &state);
        pthread_attr_destroy(&attributes);
        if (created) { ++failures; break; }
        while (!state.ready.load(std::memory_order_acquire)) std::this_thread::yield();
        int error = 0;
        if (state.openError || state.token.observe(error) != Observation::Live) ++failures;
        state.release.store(true, std::memory_order_release);
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(1);
        Observation observed = Observation::Unknown;
        do {
            observed = state.token.observe(error, &detachedFailure);
            if (observed == Observation::Terminal) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        } while (std::chrono::steady_clock::now() < deadline);
        while (!state.bodyDone.load(std::memory_order_acquire)) std::this_thread::yield();
        ++detachedCompleted;
        if (observed == Observation::Terminal) ++detachedTerminal;
        else {
            lastDetachedOpen = state.openError; lastDetachedError = error; lastDetachedState = static_cast<int>(observed);
            ++failures; break;
        }
    }
    std::unique_ptr<TokenType> retained;
    unsigned completed = 0, terminal = 0, reusedTid = 0;
    int lastJoinedOpen = 0, lastJoinedError = 0, lastJoinedState = -1;
    int retainedError = 0;
    amcl::threadterminal::Failure joinedFailure = amcl::threadterminal::Failure::None;
    amcl::threadterminal::Failure retainedFailure = amcl::threadterminal::Failure::None;
    const auto started = std::chrono::steady_clock::now();
    for (unsigned attempt = 0; attempt < 1000; ++attempt) {
        auto token = std::make_unique<TokenType>();
        int opened = 0;
        std::thread worker([&] { opened = token->openCurrent(); });
        worker.join();
        ++completed;
        int error = 0;
        // pthread_join 保证用户线程终结，并不要求 tgkill 已经不再看到内核退出尾声。
        // 仅等待查询自身给出终态；截止只判实验失败，不充当产品死亡证据。
        auto observed = token->observe(error, &joinedFailure);
        const auto joinedDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(1);
        while (observed != Observation::Terminal && std::chrono::steady_clock::now() < joinedDeadline) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            observed = token->observe(error, &joinedFailure);
        }
        if (opened || observed != Observation::Terminal) {
            lastJoinedOpen = opened; lastJoinedError = error; lastJoinedState = static_cast<int>(observed);
            ++failures; break;
        }
        ++terminal;
        if (!retained) retained = std::move(token);
        else {
            if (retained->tid() == token->tid()) ++reusedTid;
            if (retained->observe(retainedError, &retainedFailure) != Observation::Terminal) { ++failures; break; }
        }
        if (std::chrono::steady_clock::now() - started > std::chrono::seconds(12)) break;
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
    report << "threadTokenChurn method=" << method << " detached=" << detachedCompleted << " detachedTerminal=" << detachedTerminal
           << " joined=" << completed << " joinedTerminal=" << terminal << " failures=" << failures
           << " retainedTidReused=" << reusedTid << " elapsedMs=" << elapsed << '\n';
    report << "threadTokenChurnFailure method=" << method << " detachedOpen=" << lastDetachedOpen << " detachedState=" << lastDetachedState
           << " detachedError=" << lastDetachedError << " joinedOpen=" << lastJoinedOpen
           << " joinedState=" << lastJoinedState << " joinedError=" << lastJoinedError
           << " detachedStep=" << static_cast<int>(detachedFailure) << " joinedStep=" << static_cast<int>(joinedFailure)
           << " retainedError=" << retainedError << " retainedStep=" << static_cast<int>(retainedFailure) << '\n';
}
std::atomic<bool> used{false};
// 一个原子值发布 pid+signal，避免回调并发时拼出两个事件的字段。
std::atomic<unsigned long long> exitEvent{0};
void childExit(int32_t pid, int32_t signal) {
    exitEvent.store((static_cast<unsigned long long>(static_cast<uint32_t>(pid)) << 32) |
                    static_cast<uint32_t>(signal), std::memory_order_release);
}
bool writeAll(int fd, const char* text, size_t length) {
    while (length) {
        ssize_t done = write(fd, text, length);
        if (done < 0 && errno == EINTR) continue;
        if (done <= 0) return false;
        text += done;
        length -= static_cast<size_t>(done);
    }
    return true;
}
/** 独占创建同字节副本；不覆盖旧证据，权限失败不伪装为复制成功。 */
int copyExecutable(const std::string& from, const std::string& to) {
    Fd input(open(from.c_str(), O_RDONLY | O_CLOEXEC));
    if (input.value < 0) return errno;
    Fd output(open(to.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0700));
    if (output.value < 0) return errno;
    char buffer[8192];
    for (;;) {
        ssize_t size = read(input.value, buffer, sizeof(buffer));
        if (size < 0 && errno == EINTR) continue;
        if (size < 0) return errno;
        if (!size) break;
        if (!writeAll(output.value, buffer, static_cast<size_t>(size))) return errno;
    }
    return fsync(output.value) == 0 ? 0 : errno;
}
/** 真正 posix_spawn，使用真实 waitpid 状态；五秒超时只终止尚未回收的自有子进程。 */
void execProbe(const std::string& path, std::ostringstream& report) {
    // 先记录 DAC/挂载条件，不能仅凭 EACCES 就把某条平台执行路线判为不可行。
    struct stat file{};
    const int stated = stat(path.c_str(), &file);
    const int statError = stated ? errno : 0;
    const int executable = access(path.c_str(), X_OK);
    const int accessError = executable ? errno : 0;
    struct statvfs mount{};
    const int mounted = statvfs(path.c_str(), &mount);
    report << "execInput path=" << path << " statError=" << statError
           << " mode=" << std::oct << file.st_mode << std::dec
           << " owner=" << file.st_uid << " accessError=" << accessError
           << " mountFlags=" << (mounted ? 0 : mount.f_flag) << '\n';
    int pipefd[2];
    if (pipe2(pipefd, O_CLOEXEC | O_NONBLOCK) != 0) { report << "pipeError=" << errno << '\n'; return; }
    Fd readEnd(pipefd[0]), writeEnd(pipefd[1]);
    posix_spawn_file_actions_t actions;
    int rc = posix_spawn_file_actions_init(&actions);
    if (rc != 0) { report << "spawnActionsError=" << rc << '\n'; return; }
    rc = posix_spawn_file_actions_adddup2(&actions, writeEnd.value, STDOUT_FILENO);
    if (!rc) rc = posix_spawn_file_actions_adddup2(&actions, writeEnd.value, STDERR_FILENO);
    if (!rc) rc = posix_spawn_file_actions_addclose(&actions, readEnd.value);
    if (!rc) rc = posix_spawn_file_actions_addclose(&actions, writeEnd.value);
    char* argv[] = {const_cast<char*>(path.c_str()), const_cast<char*>("--probe"), nullptr};
    pid_t child = -1;
    if (!rc) rc = posix_spawn(&child, path.c_str(), &actions, nullptr, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    report << "exec path=" << path << " spawn=" << rc << " pid=" << child;
    if (rc) { report << '\n'; return; }
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    int status = 0;
    pid_t waited;
    do {
        waited = waitpid(child, &status, WNOHANG);
        if (waited < 0 && errno == EINTR) continue;
        if (waited != 0) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    } while (std::chrono::steady_clock::now() < deadline);
    if (waited == 0) {
        // waitpid 尚未回收该直接子进程，PID 不可能被重用；不对 ECHILD 的 PID 发信号。
        kill(child, SIGKILL);
        do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
        report << " timeout=1";
    }
    report << " waited=" << waited << " status=" << status;
    if (waited == child && WIFEXITED(status)) report << " exitCode=" << WEXITSTATUS(status);
    if (waited == child && WIFSIGNALED(status)) report << " signal=" << WTERMSIG(status);
    report << '\n';
    char buffer[1024];
    const ssize_t bytes = read(readEnd.value, buffer, sizeof(buffer));
    report << "execOutputBytes=" << (bytes > 0 ? bytes : 0) << '\n';
    if (bytes > 0) report.write(buffer, bytes);
}
/** 子进程只执行 async-signal-safe 的 _exit；单独区分 fork 和 exec 的平台限制。 */
void forkProbe(std::ostringstream& report) {
    const pid_t child = fork();
    if (child == 0) _exit(7);
    const int error = child < 0 ? errno : 0;
    int status = 0;
    pid_t waited = -1;
    if (child > 0) do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
    report << "fork pid=" << child << " errno=" << error << " waited=" << waited
           << " status=" << status << '\n';
}
volatile sig_atomic_t timerSamples = 0;
volatile sig_atomic_t wrongTimerThread = 0;
pid_t timerTid = 0;
void timerSignal(int, siginfo_t* info, void*) {
    if (info->si_code != SI_TIMER) return;
    if (static_cast<pid_t>(syscall(SYS_gettid)) != timerTid) wrongTimerThread = 1;
    ++timerSamples;
}
/** 只在独立探针进程且 SIGPROF 未占用时验证投递；保持原有信号策略。 */
void timerProbe(std::ostringstream& report) {
    struct sigaction original{}, action{};
    if (sigaction(SIGPROF, nullptr, &original) != 0) { report << "timerSignalQuery=" << errno << '\n'; return; }
    if (original.sa_handler != SIG_DFL) { report << "timerSignalConflict=1\n"; return; }
    timerTid = static_cast<pid_t>(syscall(SYS_gettid));
    timer_t timer;
    if (amcl_ohos::create_thread_cpu_timer(pthread_self(), timerTid, SIGPROF, &timer) != 0) {
        report << "timerCreateError=" << errno << '\n'; return;
    }
    action.sa_sigaction = timerSignal;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGPROF, &action, nullptr) != 0) {
        report << "timerSignalInstallError=" << errno << '\n'; timer_delete(timer); return;
    }
    itimerspec period{};
    period.it_interval.tv_nsec = 1000000;
    period.it_value = period.it_interval;
    const int armed = timer_settime(timer, 0, &period, nullptr);
    const int armError = armed ? errno : 0;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    volatile unsigned long work = 0;
    while (!armed && timerSamples < 3 && std::chrono::steady_clock::now() < deadline)
        for (int i = 0; i < 10000; ++i) work += i;
    sigset_t block{}, previous{};
    sigemptyset(&block); sigaddset(&block, SIGPROF);
    pthread_sigmask(SIG_BLOCK, &block, &previous);
    const int deleted = timer_delete(timer);
    timespec noWait{};
    while (sigtimedwait(&block, nullptr, &noWait) >= 0) {}
    sigaction(SIGPROF, &original, nullptr);
    pthread_sigmask(SIG_SETMASK, &previous, nullptr);
    report << "timerSamples=" << timerSamples << " wrongThread=" << wrongTimerThread
           << " armError=" << armError << " delete=" << deleted << '\n';
}
void loadProbe(const std::string& path, std::ostringstream& report) {
    dlerror();
    void* library = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        const char* error = dlerror();
        report << "systemLoad path=" << path << " error=" << (error ? error : "unknown") << '\n';
        return;
    }
    auto value = reinterpret_cast<int(*)(void)>(dlsym(library, "AmclJdkLoadProbe"));
    report << "systemLoad path=" << path << " value=" << (value ? value() : -1);
    report << " close=" << dlclose(library) << '\n';
}
/** 只使用任务投放的两个固定签名样本，检查所有权后设置真实执行位并照常调用系统接口。 */
void signedProbe(const std::string& directory, std::ostringstream& report) {
    const std::string base = directory + "/jdk-signed-probes/";
    for (const char* name : {"libamcl_load_probe.so", "libamcl_exec_probe.so"}) {
        const std::string path = base + name;
        struct stat info{};
        if (lstat(path.c_str(), &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != geteuid()) {
            report << "signedInputUnavailable=" << name << '\n'; continue;
        }
        const int changed = chmod(path.c_str(), 0700);
        const int error = changed ? errno : 0;
        report << "signedInput=" << name << " chmodError=" << error << '\n';
        if (changed) continue;
        if (strstr(name, "_exec_")) execProbe(path, report);
        else loadProbe(path, report);
    }
}

/** SDK 的退出回调只报告信号值，绝不冒充 POSIX waitpid 的退出码。 */
std::string runPlatformProbe(const std::string& directory) {
    if (used.exchange(true)) return "SKIP: 本进程已运行平台探针，请重启应用后再运行。\n";
    std::ostringstream report;
    report << "parentPid=" << getpid() << " uid=" << getuid() << '\n';
    int pipefd[2];
    if (pipe2(pipefd, O_CLOEXEC | O_NONBLOCK) != 0) return "FAIL: report pipe\n";
    Fd readEnd(pipefd[0]), writeEnd(pipefd[1]);
    const int registered = OH_Ability_RegisterNativeChildProcessExitCallback(childExit);
    report << "exitCallbackRegistration=" << registered << '\n';
    if (registered) return report.str();
    struct CallbackCleanup {
        ~CallbackCleanup() { OH_Ability_UnregisterNativeChildProcessExitCallback(childExit); }
    } callbackCleanup;
    char name[] = "report";
    NativeChildProcess_Fd fd{name, writeEnd.value, nullptr};
    NativeChildProcess_Args args{const_cast<char*>(directory.c_str()), {&fd}};
    NativeChildProcess_Options options{NCP_ISOLATION_MODE_NORMAL, 0};
    int32_t child = -1;
    const int started = OH_Ability_StartNativeChildProcess("libentry.so:AmclJdkProbeMain", args, options, &child);
    report << "nativeChildStart=" << started << " childPid=" << child << '\n';
    close(writeEnd.value); writeEnd.value = -1;
    if (started) return report.str();
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
    size_t bytes = 0;
    bool ended = false;
    while (std::chrono::steady_clock::now() < deadline) {
        pollfd pending{readEnd.value, POLLIN | POLLHUP, 0};
        poll(&pending, 1, 50);
        char buffer[2048];
        const ssize_t size = read(readEnd.value, buffer, sizeof(buffer));
        if (size > 0 && bytes + static_cast<size_t>(size) <= 16384) {
            report.write(buffer, size); bytes += static_cast<size_t>(size);
        } else if (size > 0) { report << "reportLimitExceeded=1\n"; break; }
        const auto event = exitEvent.load(std::memory_order_acquire);
        if (static_cast<uint32_t>(event >> 32) == static_cast<uint32_t>(child) && size <= 0) {
            report << "nativeChildExitSignal=" << static_cast<int32_t>(event) << '\n';
            ended = true; break;
        }
    }
    report << "childReportBytes=" << bytes << " exitEventObserved=" << ended << '\n';
    // 原生子进程与应用主进程分开取证；不把同 UID 等同于完全相同的安全上下文。
    report << "parentContext\n";
    forkProbe(report);
    signedProbe(directory, report);
    execProbe("/system/bin/true", report);
    Dl_info parentLocation{};
    if (dladdr(reinterpret_cast<void*>(&AmclJdkProbeMain), &parentLocation) && parentLocation.dli_fname) {
        const std::string library(parentLocation.dli_fname);
        execProbe(library.substr(0, library.find_last_of('/')) + "/libamcl_exec_probe.so", report);
        execProbe(directory + "/jdk-probe-data-" + std::to_string(child) + "/libamcl_exec_probe.so", report);
    }
    return report.str();
}
struct ProbeWork {
    napi_env env{};
    napi_async_work work{};
    napi_ref callback{};
    std::string directory;
    std::string result;
};
void executeProbe(napi_env, void* data) {
    auto* job = static_cast<ProbeWork*>(data);
    try { job->result = runPlatformProbe(job->directory); }
    catch (...) { job->result = "FAIL: native probe exception\n"; }
}
void completeProbe(napi_env env, napi_status status, void* data) {
    auto* job = static_cast<ProbeWork*>(data);
    napi_handle_scope scope{};
    if (status == napi_ok && napi_open_handle_scope(env, &scope) == napi_ok) {
        napi_value callback, receiver, text, ignored;
        if (napi_get_reference_value(env, job->callback, &callback) == napi_ok &&
            napi_get_undefined(env, &receiver) == napi_ok &&
            napi_create_string_utf8(env, job->result.c_str(), job->result.size(), &text) == napi_ok)
            napi_call_function(env, receiver, callback, 1, &text, &ignored);
        napi_close_handle_scope(env, scope);
    }
    napi_delete_reference(env, job->callback);
    napi_delete_async_work(env, job->work);
    delete job;
}
}

extern "C" __attribute__((visibility("default")))
void AmclJdkProbeMain(NativeChildProcess_Args args) {
    int reportFd = -1;
    for (auto* item = args.fdList.head; item; item = item->next)
        if (item->fdName && !strcmp(item->fdName, "report")) reportFd = item->fd;
    Fd output(reportFd);
    if (output.value < 0 || !args.entryParams) return;
    std::ostringstream report;
    try {
        report << "childMainPid=" << getpid() << " ppid=" << getppid() << " uid=" << getuid() << '\n';
        Dl_info location{};
        if (!dladdr(reinterpret_cast<void*>(&AmclJdkProbeMain), &location) || !location.dli_fname) {
            report << "nativeDirectoryUnavailable=1\n";
        } else {
            const std::string library(location.dli_fname);
            const std::string native = library.substr(0, library.find_last_of('/'));
            report << "nativeDirectory=" << native << '\n';
            forkProbe(report);
            execProbe("/system/bin/true", report);
            timerProbe(report);
            cacheFlushProbe(report);
            installStorageProbe(args.entryParams, report);
            fontProviderProbe(args.entryParams, report);
            threadTerminalProbe(report);
            threadTokenChurnProbe<amcl::threadterminal::Token>(report, "proc-stat");
            threadTokenChurnProbe<amcl::threadterminal::ExistenceProbe>(report, "tgkill-zero");
            unwindProbe(args.entryParams, report);
            amcl::jdkprobe::TlsLifecycleProbe(args.entryParams, report);
            // 截止只限制实验等待；真正资源收敛由生产观察者报告的明确OS终态回收来证明。
            const auto tlsDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
            elf_tls_stats tlsStats{};
            int tlsStatsError = 0;
            do {
                tlsStatsError = elf_get_tls_stats(&tlsStats);
                if (tlsStatsError || (tlsStats.residentArenas <= 1 && tlsStats.payloads == 0)) break;
                poll(nullptr, 0, 20);
            } while (std::chrono::steady_clock::now() < tlsDeadline);
            report << "tlsStorage error=" << tlsStatsError << " arenas=" << tlsStats.residentArenas
                   << " registered=" << tlsStats.registeredArenas << " blocks=" << tlsStats.blocks
                   << " payloads=" << tlsStats.payloads << " storageBytes=" << tlsStats.storageBytes
                   << " moduleBytes=" << tlsStats.moduleBytes << " expansionError=" << tlsStats.expansionError
                   << " converged=" << (!tlsStatsError && !tlsStats.expansionError &&
                       tlsStats.residentArenas <= 1 && tlsStats.payloads == 0) << '\n';
            signedProbe(args.entryParams, report);
            loadProbe(native + "/libamcl_load_probe.so", report);
            execProbe(native + "/libamcl_exec_probe.so", report);
            const std::string data = std::string(args.entryParams) + "/jdk-probe-data-" + std::to_string(getpid());
            if (mkdir(data.c_str(), 0700) != 0) report << "dataDirectoryError=" << errno << '\n';
            else {
                for (const char* file : {"libamcl_load_probe.so", "libamcl_exec_probe.so"}) {
                    const int error = copyExecutable(native + "/" + file, data + "/" + file);
                    report << "copy file=" << file << " errno=" << error << '\n';
                    if (!error) {
                        if (strstr(file, "_exec_")) execProbe(data + "/" + file, report);
                        else loadProbe(data + "/" + file, report);
                    }
                }
            }
        }
    } catch (...) { report << "childException=1\n"; }
    const std::string result = report.str();
    writeAll(output.value, result.data(), result.size());
}

napi_value RunJdkPlatformProbeNapi(napi_env env, napi_callback_info info) try {
    size_t count = 2;
    napi_value args[2], resource, unused = nullptr;
    napi_get_undefined(env, &unused);
    if (napi_get_cb_info(env, info, &count, args, nullptr, nullptr) != napi_ok || count != 2) {
        napi_throw_type_error(env, "JDK_PROBE_ARGS", "需要 filesDir 与完成回调"); return unused;
    }
    napi_valuetype type;
    if (napi_typeof(env, args[1], &type) != napi_ok || type != napi_function) {
        napi_throw_type_error(env, "JDK_PROBE_CALLBACK", "完成回调必须是函数"); return unused;
    }
    // 读取输入可能分配 string。直到队列成功接管前始终由本地 RAII 持有，
    // 任何解析异常都不能遗失 job；引用/工作项在其各自失败分支配对释放。
    std::unique_ptr<ProbeWork> job(new (std::nothrow) ProbeWork);
    if (!job) { napi_throw_error(env, "ENOMEM", "无法分配探针任务"); return unused; }
    // execute 的异常回报复用预留空间，避免在已经分配失败时再次申请报告内存。
    job->result.reserve(32768);
    if (!amcl::napi::ReadStringValue(env, args[0], job->directory) || job->directory.empty() ||
        job->directory.size() > 1024 || job->directory[0] != '/' ||
        job->directory.find('\0') != std::string::npos) {
        napi_throw_type_error(env, "JDK_PROBE_PATH", "需要应用 filesDir"); return unused;
    }
    job->env = env;
    napi_status status = napi_create_reference(env, args[1], 1, &job->callback);
    if (status == napi_ok) status = napi_create_string_utf8(env, "JdkPlatformProbe", NAPI_AUTO_LENGTH, &resource);
    if (status == napi_ok) status = napi_create_async_work(env, nullptr, resource, executeProbe, completeProbe, job.get(), &job->work);
    if (status == napi_ok) status = napi_queue_async_work(env, job->work);
    if (status != napi_ok) {
        if (job->work) napi_delete_async_work(env, job->work);
        if (job->callback) napi_delete_reference(env, job->callback);
        napi_throw_error(env, "JDK_PROBE_QUEUE", "无法提交探针任务");
    } else {
        // 此后只有 completeProbe 删除 job；execute 阶段不触碰 NAPI 对象。
        job.release();
    }
    return unused;
} catch (...) {
    napi_throw_error(env, "JDK_PROBE_INPUT", "无法准备探针输入");
    return nullptr;
}
#endif
