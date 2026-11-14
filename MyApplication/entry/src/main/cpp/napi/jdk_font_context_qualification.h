/** 仅限 TestHooks 的独立 NativeChildProcess：测量官方缓存上下文及清空环境后的真实行为。
 * 调用点必须在本次隔离 NCP 的 jvmInit 之前；不得从 UI 进程或生产 JVM 热路径调用。
 * 先观察具名 NDK DSO 是否已加载，再按官方固定库名加载 facade；不创建 Context，
 * 不把 NCP 结果外推成 fresh exec 资格。
 */
#pragma once
#ifdef MC_OHOS_BUILD_TESTS
#include "../platform/jdk_install_io.h"
#include <AbilityKit/ability_runtime/application_context.h>
#include <array>
#include <cstdlib>
#include <dlfcn.h>
#include <limits.h>
#include <type_traits>

namespace amcl::jdkqualification::fontcontext {
namespace io = amcl::jdk::io;

/** 有界诊断字符串的 JSON 转义；不把路径里的换行/引号写成额外结果字段。 */
inline std::string Quote(const std::string& value) {
    static constexpr char hex[] = "0123456789abcdef";
    std::string result = "\"";
    for (unsigned char ch : value) {
        if (ch == '\\' || ch == '"') { result += '\\'; result += static_cast<char>(ch); }
        else if (ch < 0x20) { result += "\\u00"; result += hex[ch >> 4]; result += hex[ch & 15]; }
        else result += static_cast<char>(ch);
    }
    return result + '"';
}

/** 先完整复制原环境，再允许清空。析构兜底恢复；正常路径必须显式检查全部原值已恢复。
 * 只保存本测试相关变量，记录中只写存在性与摘要，不泄露无关环境内容。
 */
class Environment final {
    struct Entry { const char* name; bool present = false; std::string value{}; };
    std::array<Entry, 9> entries_{{{"FONTCONFIG_FILE"}, {"FONTCONFIG_PATH"}, {"HOME"},
        {"XDG_CACHE_HOME"}, {"XDG_CONFIG_HOME"}, {"XDG_DATA_HOME"}, {"XDG_CONFIG_DIRS"},
        {"XDG_DATA_DIRS"}, {"FONTCONFIG_SYSROOT"}}};
    bool changed_ = false;
    bool* restorationStatus_;
public:
    explicit Environment(bool& restorationStatus) : restorationStatus_(&restorationStatus) {
        for (auto& entry : entries_) {
            const char* value = getenv(entry.name);
            entry.present = value != nullptr;
            if (value) entry.value = value;
        }
    }
    Environment(const Environment&) = delete;
    ~Environment() { if (changed_ && !Restore()) *restorationStatus_ = false; }
    std::string Identity() const {
        std::string json = "{";
        for (const auto& entry : entries_) {
            if (json.size() > 1) json += ',';
            json += Quote(entry.name) + ":{\"present\":" + (entry.present ? "true" : "false");
            if (entry.present) json += ",\"sha256\":" + Quote(io::Digest(entry.value));
            json += '}';
        }
        return json + '}';
    }
    void Clear() {
        changed_ = true; // 即使中途 unsetenv 失败，析构仍恢复已经处理的变量。
        for (const auto& entry : entries_) if (unsetenv(entry.name) != 0) io::Error("无法清空隔离字体环境");
    }
    bool Restore() noexcept {
        for (const auto& entry : entries_) {
            if (entry.present) (void)setenv(entry.name, entry.value.c_str(), 1);
            else (void)unsetenv(entry.name);
        }
        bool equal = true;
        for (const auto& entry : entries_) {
            const char* current = getenv(entry.name);
            equal = equal && (entry.present ? current && entry.value == current : current == nullptr);
        }
        changed_ = !equal;
        return equal;
    }
};

/** CWD 与环境一样具有异常安全的恢复责任；即使诊断字符串分配失败，也不能遗留根目录。 */
class WorkingDirectory final {
    io::Fd original_;
    bool changed_ = false;
    bool* restorationStatus_;
public:
    explicit WorkingDirectory(bool& restorationStatus)
        : original_(open(".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)), restorationStatus_(&restorationStatus) {
        if (original_.get() < 0) io::Error("无法保存隔离NCP工作目录");
    }
    ~WorkingDirectory() { if (changed_ && !Restore()) *restorationStatus_ = false; }
    void SelectRoot() {
        if (chdir("/") != 0) io::Error("无法选择隔离缓存探针工作目录");
        changed_ = true;
    }
    bool Restore() noexcept {
        if (!changed_) return true;
        if (fchdir(original_.get()) != 0) return false;
        changed_ = false;
        return true;
    }
};

using CacheDirFunction = AbilityRuntime_ErrorCode (*)(char*, int32_t, int32_t*);
static_assert(std::is_same<CacheDirFunction, decltype(&OH_AbilityRuntime_ApplicationContextGetCacheDir)>::value,
              "cache API signature differs from the installed official SDK");

/** 只对官方 API 的有效绝对返回路径创建本次专属文件。O_EXCL 拒绝旧证据，保留文件供回读，
 * fsync 文件和目录后再次打开比对完整内容；权限错误、符号链接和旧文件不当作可写成功。
 */
inline std::string WriteCacheProbe(const std::string& path, const char* phase) {
    auto directory = io::Directory(path);
    const std::string name = "amcl-font-context-" + std::to_string(getpid()) + "-" + phase + ".probe";
    const std::string payload = "AMCL-FONT-CONTEXT-1:" + std::to_string(getpid()) + ":" + phase + "\n";
    io::Fd file(openat(directory.get(), name.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
    if (file.get() < 0) io::Error("缓存探针无法独占创建");
    io::Write(file.get(), payload.data(), payload.size());
    io::Sync(file.get());
    io::Sync(directory.get());
    struct stat identity{};
    io::Require(fstat(file.get(), &identity) == 0 && S_ISREG(identity.st_mode) && identity.st_nlink == 1,
                "缓存探针不是独占普通文件");
    io::Require(io::SmallFile(directory.get(), name, 8192) == payload, "缓存探针落盘回读不一致");
    return "{\"file\":" + Quote(path + "/" + name) + ",\"sha256\":" + Quote(io::Digest(payload)) +
        ",\"bytes\":" + std::to_string(payload.size()) + ",\"device\":" + std::to_string(identity.st_dev) +
        ",\"inode\":" + std::to_string(identity.st_ino) + ",\"fsyncAndReadback\":true}";
}

/** 精确记录返回码与 writeLength。Context 不存在、缺符号、相对路径均有独立失败身份。 */
inline std::string Observe(CacheDirFunction function, const char* phase) {
    std::array<char, PATH_MAX> buffer{};
    int32_t written = -1;
    const int code = static_cast<int>(function(buffer.data(), static_cast<int32_t>(buffer.size()), &written));
    const size_t length = strnlen(buffer.data(), buffer.size());
    const std::string path = length < buffer.size() ? std::string(buffer.data(), length) : std::string();
    std::string result = "{\"returnCode\":" + std::to_string(code) + ",\"written\":" +
        std::to_string(written) + ",\"pathLength\":" + std::to_string(length) + ",\"path\":" + Quote(path);
    if (code != ABILITY_RUNTIME_ERROR_CODE_NO_ERROR)
        return result + ",\"status\":\"API-FAILED\",\"cacheWriteAttempted\":false}";
    if (path.empty() || path.front() != '/' || written <= 0 || static_cast<size_t>(written) >= buffer.size() ||
        !(length == static_cast<size_t>(written) || length + 1 == static_cast<size_t>(written)))
        return result + ",\"status\":\"INVALID-RESULT\",\"cacheWriteAttempted\":false}";
    try {
        return result + ",\"status\":\"PASS\",\"cacheWriteAttempted\":true,\"write\":" + WriteCacheProbe(path, phase) + "}";
    } catch (const std::exception& error) {
        return result + ",\"status\":\"WRITE-FAILED\",\"cacheWriteAttempted\":true,\"error\":" + Quote(error.what()) + "}";
    }
}

/** 显式句柄覆盖本次 API 调用；普通 dlopen 只取得官方 facade，不手工构造 Context。 */
struct LoadedProvider final {
    void* handle = nullptr;
    ~LoadedProvider() { if (handle) dlclose(handle); }
};
} // namespace amcl::jdkqualification::fontcontext

namespace amcl::jdkqualification {
/** 仅由隔离 NCP 入口调用一次。报告始终独占保存；恢复失败会保存 FAIL 后抛出，禁止继续
 * 初始化 JVM 让被测试改变的环境污染后续结论。普通 API 不可用仅留事实，不伪造 fresh exec。
 */
inline std::string RunFontContextQualification(int run) {
    namespace fc = fontcontext;
    namespace io = amcl::jdk::io;
    std::string observation = "{\"status\":\"NOT-RUN\"}";
    bool restored = true;
    try {
        fc::Environment environment(restored);
        const auto environmentIdentity = environment.Identity();
        fc::WorkingDirectory workingDirectory(restored);
        fc::LoadedProvider provider;
        provider.handle = dlopen("libability_runtime.so", RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
        const bool alreadyLoaded = provider.handle != nullptr;
        std::string noLoadError, loadError;
        if (!alreadyLoaded) {
            const char* error = dlerror();
            noLoadError = error ? error : "<no dlerror>";
            // 官方调用本来需要链接该 NDK 库。未预加载 facade 不能推论 Context API 不可用。
            // 缺库/缺符号/无 Context 仍分别记录，不调用任何 Context 创建或注入接口。
            provider.handle = dlopen("libability_runtime.so", RTLD_NOW | RTLD_LOCAL);
            if (!provider.handle) {
                error = dlerror();
                loadError = error ? error : "<no dlerror>";
            }
        }
        const std::string lookup = std::string(",\"noLoadSucceeded\":") + (alreadyLoaded ? "true" : "false") +
            ",\"noLoadError\":" + fc::Quote(noLoadError) + ",\"ordinaryLoadAttempted\":" +
            (alreadyLoaded ? "false" : "true") + ",\"loadedByProbe\":" +
            (!alreadyLoaded && provider.handle ? "true" : "false") + ",\"ordinaryLoadError\":" + fc::Quote(loadError);
        if (!provider.handle) {
            observation = "{\"status\":\"PROVIDER-LOAD-FAILED\",\"library\":\"libability_runtime.so\"" + lookup + "}";
        } else {
            dlerror();
            void* address = dlsym(provider.handle, "OH_AbilityRuntime_ApplicationContextGetCacheDir");
            Dl_info info{};
            if (!address || !dladdr(address, &info) || !info.dli_fname || !info.dli_fbase) {
                observation = "{\"status\":\"SYMBOL-UNAVAILABLE\",\"library\":\"libability_runtime.so\"" + lookup + "}";
            } else {
                const std::string actualProvider = info.dli_fname;
                const auto leaf = actualProvider.substr(actualProvider.find_last_of('/') + 1);
                if (leaf != "libability_runtime.so") {
                    observation = "{\"status\":\"PROVIDER-MISMATCH\",\"provider\":" + fc::Quote(actualProvider) + lookup + "}";
                } else {
                    auto function = reinterpret_cast<fc::CacheDirFunction>(address);
                    observation = "{\"status\":\"OBSERVED\",\"library\":\"libability_runtime.so\",\"provider\":" +
                        fc::Quote(actualProvider) + ",\"providerBase\":" +
                        std::to_string(reinterpret_cast<uintptr_t>(info.dli_fbase)) + ",\"symbol\":\"OH_AbilityRuntime_ApplicationContextGetCacheDir\","
                        "\"originalEnvironment\":" + environmentIdentity + lookup + ",\"inherited\":" + fc::Observe(function, "inherited");
                    try {
                        environment.Clear();
                        workingDirectory.SelectRoot();
                        errno = 0;
                        const int accessResult = access(".", W_OK);
                        const int accessError = errno;
                        observation += ",\"sanitizedCwd\":\"/\",\"cwdWriteAccess\":" + std::to_string(accessResult) +
                            ",\"cwdAccessErrno\":" + std::to_string(accessError) + ",\"sanitized\":" + fc::Observe(function, "sanitized");
                    } catch (const std::exception& error) {
                        observation += ",\"sanitizedError\":" + fc::Quote(error.what());
                    }
                    const bool cwdRestored = workingDirectory.Restore();
                    const bool environmentRestored = environment.Restore();
                    restored = cwdRestored && environmentRestored;
                    observation += std::string(",\"cwdRestored\":") + (cwdRestored ? "true" : "false") +
                        ",\"environmentRestored\":" + (environmentRestored ? "true" : "false") + "}";
                }
            }
        }
    } catch (const std::exception& error) {
        observation = "{\"status\":\"PROBE-FAILED\",\"error\":" + fc::Quote(error.what()) + "}";
    }
    const std::string report = "{\"schema\":1,\"scope\":\"isolated-native-child-context-only\",\"freshExecQualified\":false,"
        "\"pid\":" + std::to_string(getpid()) + ",\"observation\":" + observation + "}";
    io::Fd output(openat(run, "font-context-report.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
    if (output.get() < 0) io::Error("字体上下文报告已存在或不可创建");
    io::Write(output.get(), report.data(), report.size());
    io::Sync(output.get()); io::Sync(run);
    io::Require(restored, "隔离字体探针未能恢复环境/CWD，禁止继续JVM资格验证");
    return report;
}
} // namespace amcl::jdkqualification
#endif
