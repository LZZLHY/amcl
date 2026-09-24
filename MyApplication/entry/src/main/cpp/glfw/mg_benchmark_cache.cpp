// mg_benchmark_cache.cpp - Opt-in, identity-keyed MobileGlues benchmark cache.

#include "mg_benchmark_cache.h"
#include "../utils/product_diagnostics.h"
#include "../platform/gl_host.h"
#include "../platform/graphics_runtime_binding.h"

#if AMCL_DIAGNOSTICS_MASK & 1
#include "mg_benchmark_cache_policy.h"
#include "amcl_mg_source_identity.h"

#include "glfw_compat.h"

#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <cJSON.h>
#include <hilog/log.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <strings.h>
#include <unistd.h>
#include "egl_dispatch.h"

#undef LOG_TAG
#define LOG_TAG "AMCL_MG_BENCH"

// Historical dlsym(libglfw.so, "mg_multidraw_bench_*") ABI forwards to one provider DSO.
extern "C" const char* mg_multidraw_bench_run(int startSections, int maxSections) {
    // 诊断入口只能借用已选择 MG 的函数表，不能因查询进度而装载或切换另一图形实现。
    const auto* runtime = amcl::graphics::BoundGraphicsRuntime();
    using Run = const char* (*)(int, int);
    const auto run = runtime && runtime->is("mobileglues") ?
        reinterpret_cast<Run>(runtime->providerProc("amclGlHostMobileGluesBenchmarkRunV1")) : nullptr;
    return run ? run(startSections, maxSections) : nullptr;
}
extern "C" int mg_multidraw_bench_progress(void) {
    const auto* runtime = amcl::graphics::BoundGraphicsRuntime();
    using Progress = int (*)();
    const auto progress = runtime && runtime->is("mobileglues") ?
        reinterpret_cast<Progress>(runtime->providerProc("amclGlHostMobileGluesBenchmarkProgressV1")) : nullptr;
    return progress ? progress() : 0;
}

#ifndef AMCL_MG_SOURCE_COMMIT
#error "AMCL_MG_SOURCE_COMMIT must identify the exact embedded MG source"
#endif
#ifndef AMCL_MG_BUILD_IDENTITY
#error "AMCL_MG_BUILD_IDENTITY must include the exact MG worktree and build options"
#endif
#ifndef AMCL_MG_SEMANTIC_VERSION
#error "AMCL_MG_SEMANTIC_VERSION must identify the embedded MG version"
#endif
#ifndef AMCL_HOST_BUILD_IDENTITY
#error "AMCL_HOST_BUILD_IDENTITY must identify the host source/toolchain state"
#endif

extern "C" const char *mg_multidraw_bench_run(int startSections,
                                                int maxSections);

namespace {

constexpr int kCacheSchemaVersion = 3;
constexpr int kUpstreamBenchmarkReportVersion = 3;
constexpr const char kHostBenchmarkAbi[] = "glfw-amcl-mg-benchmark-v3";
constexpr size_t kMaximumCacheBytes = 8U * 1024U * 1024U;
constexpr uint32_t kKnownFlags =
    GLFW_AMCL_MG_BENCHMARK_DISPOSABLE_CONTEXT |
    GLFW_AMCL_MG_BENCHMARK_FORCE;

struct BenchmarkIdentity {
    std::string renderer;
    std::string driver;
    std::string frontendVersion;
    std::string mgVersion;
    std::string mgCommit;
    std::string mgBuildIdentity;
    std::string hostBuildIdentity;
    std::string hostAbi;
    std::string cacheKey;
};

enum class CacheState {
    Miss,
    Hit,
    IdentityMismatch,
    Malformed,
    Unavailable,
};

struct CacheLookup {
    CacheState state = CacheState::Miss;
    std::string benchmarkJson;
};

amcl::mgbench::CacheProbeState ToProbeState(CacheState state) {
    switch (state) {
    case CacheState::Miss:
        return amcl::mgbench::CacheProbeState::Missing;
    case CacheState::Hit:
        return amcl::mgbench::CacheProbeState::ValidIdentity;
    case CacheState::IdentityMismatch:
        return amcl::mgbench::CacheProbeState::IdentityMismatch;
    case CacheState::Malformed:
        return amcl::mgbench::CacheProbeState::Malformed;
    case CacheState::Unavailable:
    default:
        return amcl::mgbench::CacheProbeState::Unavailable;
    }
}

std::mutex g_benchmarkMutex;
thread_local std::string g_threadResponse;

bool EnvEnabled(const char *name) {
    const char *value = std::getenv(name);
    if (value == nullptr || value[0] == '\0') {
        return false;
    }
    return std::strcmp(value, "1") == 0 || strcasecmp(value, "true") == 0 ||
           strcasecmp(value, "yes") == 0 || strcasecmp(value, "on") == 0 ||
           strcasecmp(value, "enabled") == 0;
}

std::string MgVersionString() {
    return AMCL_MG_SEMANTIC_VERSION;
}

const char *SafeString(const char *value) {
    return value != nullptr && value[0] != '\0' ? value : "<unavailable>";
}

BenchmarkIdentity ReadIdentity(EGLDisplay display) {
    BenchmarkIdentity identity;
    using GetString = const unsigned char* (*)(unsigned);
    const auto getString = reinterpret_cast<GetString>(amclGraphicsGlProcV1("glGetString"));
    identity.renderer = SafeString(reinterpret_cast<const char *>(
        getString ? getString(GL_RENDERER) : nullptr));
    identity.frontendVersion = SafeString(reinterpret_cast<const char *>(
        getString ? getString(GL_VERSION) : nullptr));

    const char *eglVendor = eglQueryString(display, EGL_VENDOR);
    const char *eglVersion = eglQueryString(display, EGL_VERSION);
    const char *eglApis = eglQueryString(display, EGL_CLIENT_APIS);
    identity.driver = std::string("vendor=") + SafeString(eglVendor) +
                      ";version=" + SafeString(eglVersion) +
                      ";apis=" + SafeString(eglApis);
    identity.mgVersion = MgVersionString();
    identity.mgCommit = AMCL_MG_SOURCE_COMMIT;
    identity.mgBuildIdentity = AMCL_MG_BUILD_IDENTITY;
    identity.hostBuildIdentity = AMCL_HOST_BUILD_IDENTITY;
    identity.hostAbi = kHostBenchmarkAbi;

    amcl::mgbench::IdentityFields fields;
    fields.cacheSchema = kCacheSchemaVersion;
    fields.benchmarkReportVersion = kUpstreamBenchmarkReportVersion;
    fields.renderer = identity.renderer;
    fields.driver = identity.driver;
    fields.frontendVersion = identity.frontendVersion;
    fields.mobileGluesVersion = identity.mgVersion;
    fields.mobileGluesCommit = identity.mgCommit;
    fields.mobileGluesBuildIdentity = identity.mgBuildIdentity;
    fields.hostBuildIdentity = identity.hostBuildIdentity;
    fields.hostAbi = identity.hostAbi;
    identity.cacheKey = amcl::mgbench::IdentityCacheKey(fields);
    return identity;
}

void AddIdentity(cJSON *parent, const BenchmarkIdentity &identity) {
    cJSON *object = cJSON_AddObjectToObject(parent, "identity");
    cJSON_AddStringToObject(object, "gpuRenderer", identity.renderer.c_str());
    cJSON_AddStringToObject(object, "driver", identity.driver.c_str());
    cJSON_AddStringToObject(object, "frontendVersion",
                            identity.frontendVersion.c_str());
    cJSON_AddStringToObject(object, "mobileGluesVersion",
                            identity.mgVersion.c_str());
    cJSON_AddStringToObject(object, "mobileGluesCommit",
                             identity.mgCommit.c_str());
    cJSON_AddStringToObject(object, "mobileGluesBuildIdentity",
                            identity.mgBuildIdentity.c_str());
    cJSON_AddStringToObject(object, "hostBuildIdentity",
                            identity.hostBuildIdentity.c_str());
    cJSON_AddStringToObject(object, "hostAbi", identity.hostAbi.c_str());
}

bool JsonStringEquals(const cJSON *object, const char *name,
                      const std::string &expected) {
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(object, name);
    return cJSON_IsString(item) && item->valuestring != nullptr &&
           expected == item->valuestring;
}

bool IdentityMatches(const cJSON *root, const BenchmarkIdentity &identity) {
    const cJSON *schema =
        cJSON_GetObjectItemCaseSensitive(root, "schemaVersion");
    const cJSON *report =
        cJSON_GetObjectItemCaseSensitive(root, "benchmarkReportVersion");
    const cJSON *storedIdentity =
        cJSON_GetObjectItemCaseSensitive(root, "identity");
    if (!cJSON_IsNumber(schema) || schema->valueint != kCacheSchemaVersion ||
        !cJSON_IsNumber(report) ||
        report->valueint != kUpstreamBenchmarkReportVersion ||
        !JsonStringEquals(root, "cacheKey", identity.cacheKey) ||
        !cJSON_IsObject(storedIdentity)) {
        return false;
    }
    return JsonStringEquals(storedIdentity, "gpuRenderer", identity.renderer) &&
           JsonStringEquals(storedIdentity, "driver", identity.driver) &&
           JsonStringEquals(storedIdentity, "frontendVersion",
                            identity.frontendVersion) &&
           JsonStringEquals(storedIdentity, "mobileGluesVersion",
                            identity.mgVersion) &&
           JsonStringEquals(storedIdentity, "mobileGluesCommit",
                             identity.mgCommit) &&
           JsonStringEquals(storedIdentity, "mobileGluesBuildIdentity",
                            identity.mgBuildIdentity) &&
           JsonStringEquals(storedIdentity, "hostBuildIdentity",
                            identity.hostBuildIdentity) &&
           JsonStringEquals(storedIdentity, "hostAbi", identity.hostAbi);
}

bool ReadWholeFile(const std::string &path, std::string *output,
                   bool *exists) {
    *exists = false;
    FILE *file = std::fopen(path.c_str(), "rb");
    if (file == nullptr) {
        return errno == ENOENT;
    }
    *exists = true;
    if (std::fseek(file, 0, SEEK_END) != 0) {
        std::fclose(file);
        return false;
    }
    const long length = std::ftell(file);
    if (length <= 0 || static_cast<unsigned long>(length) > kMaximumCacheBytes ||
        std::fseek(file, 0, SEEK_SET) != 0) {
        std::fclose(file);
        return false;
    }
    output->resize(static_cast<size_t>(length));
    const size_t read =
        std::fread(output->data(), 1, output->size(), file);
    const bool closed = std::fclose(file) == 0;
    return read == output->size() && closed;
}

CacheLookup ReadCache(const std::string &path,
                      const BenchmarkIdentity &identity) {
    CacheLookup lookup;
    if (path.empty()) {
        lookup.state = CacheState::Unavailable;
        return lookup;
    }

    std::string text;
    bool exists = false;
    if (!ReadWholeFile(path, &text, &exists)) {
        lookup.state = exists ? CacheState::Malformed : CacheState::Unavailable;
        return lookup;
    }
    if (!exists) {
        lookup.state = CacheState::Miss;
        return lookup;
    }

    cJSON *root = cJSON_ParseWithLength(text.c_str(), text.size());
    if (!cJSON_IsObject(root)) {
        cJSON_Delete(root);
        lookup.state = CacheState::Malformed;
        return lookup;
    }
    if (!IdentityMatches(root, identity)) {
        cJSON_Delete(root);
        lookup.state = CacheState::IdentityMismatch;
        return lookup;
    }
    const cJSON *benchmark =
        cJSON_GetObjectItemCaseSensitive(root, "benchmark");
    const cJSON *error = cJSON_IsObject(benchmark)
                             ? cJSON_GetObjectItemCaseSensitive(benchmark,
                                                                "error")
                             : nullptr;
    const cJSON *version = cJSON_IsObject(benchmark)
                               ? cJSON_GetObjectItemCaseSensitive(benchmark,
                                                                  "version")
                               : nullptr;
    if (!cJSON_IsObject(benchmark) || error != nullptr ||
        !cJSON_IsNumber(version) ||
        version->valueint != kUpstreamBenchmarkReportVersion) {
        cJSON_Delete(root);
        lookup.state = CacheState::Malformed;
        return lookup;
    }

    char *printed = cJSON_PrintUnformatted(benchmark);
    if (printed == nullptr) {
        cJSON_Delete(root);
        lookup.state = CacheState::Malformed;
        return lookup;
    }
    lookup.benchmarkJson = printed;
    cJSON_free(printed);
    cJSON_Delete(root);
    lookup.state = CacheState::Hit;
    return lookup;
}

std::string PrintJson(cJSON *root) {
    char *printed = cJSON_PrintUnformatted(root);
    std::string result = printed != nullptr ? printed :
                                             "{\"status\":\"json-error\"}";
    cJSON_free(printed);
    cJSON_Delete(root);
    return result;
}

std::string BuildCacheDocument(const BenchmarkIdentity &identity,
                               const std::string &benchmarkJson) {
    cJSON *root = cJSON_CreateObject();
    cJSON_AddNumberToObject(root, "schemaVersion", kCacheSchemaVersion);
    cJSON_AddNumberToObject(root, "benchmarkReportVersion",
                            kUpstreamBenchmarkReportVersion);
    cJSON_AddStringToObject(root, "cacheKey", identity.cacheKey.c_str());
    AddIdentity(root, identity);
    cJSON *benchmark =
        cJSON_ParseWithLength(benchmarkJson.c_str(), benchmarkJson.size());
    if (!cJSON_IsObject(benchmark)) {
        cJSON_Delete(benchmark);
        benchmark = cJSON_CreateObject();
        cJSON_AddStringToObject(benchmark, "error", "invalid-benchmark-json");
    }
    cJSON_AddItemToObject(root, "benchmark", benchmark);
    return PrintJson(root);
}

bool WriteCacheAtomically(const std::string &path, const std::string &contents) {
    if (path.empty() || path.size() > 4096U) {
        return false;
    }
    const std::string temporary =
        path + ".tmp." + std::to_string(static_cast<long long>(getpid()));
    FILE *file = std::fopen(temporary.c_str(), "wb");
    if (file == nullptr) {
        return false;
    }
    const size_t written =
        std::fwrite(contents.data(), 1, contents.size(), file);
    const bool flushed = std::fflush(file) == 0;
    const bool synced = flushed && fsync(fileno(file)) == 0;
    const bool closed = std::fclose(file) == 0;
    if (written != contents.size() || !synced || !closed ||
        std::rename(temporary.c_str(), path.c_str()) != 0) {
        const int savedErrno = errno;
        std::remove(temporary.c_str());
        errno = savedErrno;
        return false;
    }
    return true;
}

std::string ResolveCachePath(const char *requested) {
    if (requested != nullptr && requested[0] != '\0') {
        return requested;
    }
    const char *overridePath =
        std::getenv("AMCL_MG_MULTIDRAW_BENCH_CACHE");
    if (overridePath != nullptr && overridePath[0] != '\0') {
        return overridePath;
    }
    const char *mgDir = std::getenv("MG_DIR_PATH");
    if (mgDir == nullptr || mgDir[0] == '\0') {
        return {};
    }
    return std::string(mgDir) + "/amcl-multidraw-bench-v1.json";
}

bool BenchmarkSucceeded(const std::string &benchmarkJson) {
    cJSON *root =
        cJSON_ParseWithLength(benchmarkJson.c_str(), benchmarkJson.size());
    const cJSON *version = cJSON_IsObject(root)
                               ? cJSON_GetObjectItemCaseSensitive(root,
                                                                  "version")
                               : nullptr;
    const cJSON *error = cJSON_IsObject(root)
                             ? cJSON_GetObjectItemCaseSensitive(root, "error")
                             : nullptr;
    const bool success = cJSON_IsNumber(version) &&
                         version->valueint == kUpstreamBenchmarkReportVersion &&
                         error == nullptr;
    cJSON_Delete(root);
    return success;
}

std::string BuildResponse(const char *status, const char *error,
                          const BenchmarkIdentity *identity,
                          const std::string &cachePath, bool cacheHit,
                          bool cacheInvalidated, bool cacheWritten,
                          bool forced, const std::string &benchmarkJson) {
    cJSON *root = cJSON_CreateObject();
    cJSON_AddNumberToObject(root, "abiVersion",
                            GLFW_AMCL_MG_BENCHMARK_ABI_VERSION);
    cJSON_AddNumberToObject(root, "schemaVersion", kCacheSchemaVersion);
    cJSON_AddStringToObject(root, "status", status);
    if (error != nullptr) {
        cJSON_AddStringToObject(root, "error", error);
    }
    if (identity != nullptr) {
        cJSON_AddStringToObject(root, "cacheKey",
                                identity->cacheKey.c_str());
        AddIdentity(root, *identity);
    }
    cJSON *cache = cJSON_AddObjectToObject(root, "cache");
    cJSON_AddStringToObject(cache, "path",
                            cachePath.empty() ? "" : cachePath.c_str());
    cJSON_AddBoolToObject(cache, "hit", cacheHit);
    cJSON_AddBoolToObject(cache, "invalidated", cacheInvalidated);
    cJSON_AddBoolToObject(cache, "written", cacheWritten);
    cJSON_AddBoolToObject(cache, "forced", forced);
    cJSON_AddBoolToObject(root, "selectionApplied", false);
    cJSON_AddStringToObject(root, "fallback", "upstream-config");
    if (!benchmarkJson.empty()) {
        cJSON *benchmark =
            cJSON_ParseWithLength(benchmarkJson.c_str(), benchmarkJson.size());
        if (cJSON_IsObject(benchmark)) {
            cJSON_AddItemToObject(root, "benchmark", benchmark);
        } else {
            cJSON_Delete(benchmark);
            cJSON_AddStringToObject(root, "benchmarkParseError",
                                    "invalid-json");
        }
    }
    return PrintJson(root);
}

void LogBenchmarkMetrics(const BenchmarkIdentity &identity,
                         const std::string &benchmarkJson, bool cacheWritten,
                         bool cacheInvalidated) {
    cJSON *root =
        cJSON_ParseWithLength(benchmarkJson.c_str(), benchmarkJson.size());
    const cJSON *elapsed =
        cJSON_GetObjectItemCaseSensitive(root, "elapsedMs");
    const cJSON *budget = cJSON_GetObjectItemCaseSensitive(root, "budgetMs");
    const cJSON *sections = cJSON_GetObjectItemCaseSensitive(root, "sections");
    const cJSON *attempts = cJSON_GetObjectItemCaseSensitive(root, "attempts");
    const cJSON *noisy = cJSON_GetObjectItemCaseSensitive(root, "noisy");
    OH_LOG_INFO(LOG_APP,
                "event=mg-benchmark-complete key=%{public}s "
                "renderer=%{public}s driver=%{public}s mg=%{public}s "
                "elapsedMs=%{public}.3f budgetMs=%{public}.3f "
                "sections=%{public}d attempts=%{public}d noisy=%{public}d "
                "cacheWritten=%{public}d cacheInvalidated=%{public}d",
                identity.cacheKey.c_str(), identity.renderer.c_str(),
                identity.driver.c_str(), identity.mgVersion.c_str(),
                cJSON_IsNumber(elapsed) ? elapsed->valuedouble : -1.0,
                cJSON_IsNumber(budget) ? budget->valuedouble : -1.0,
                cJSON_IsNumber(sections) ? sections->valueint : -1,
                cJSON_IsNumber(attempts) ? attempts->valueint : -1,
                cJSON_IsTrue(noisy) ? 1 : 0, cacheWritten ? 1 : 0,
                cacheInvalidated ? 1 : 0);
    cJSON_Delete(root);
}

} // namespace

extern "C" const char *glfwAMCLMobileGluesBenchmarkRunV1(
    int32_t startSections, int32_t maxSections, uint32_t flags,
    const char *cachePath) {
    const bool force = (flags & GLFW_AMCL_MG_BENCHMARK_FORCE) != 0;
    const std::string resolvedCachePath = ResolveCachePath(cachePath);
    const bool disposable =
        (flags & GLFW_AMCL_MG_BENCHMARK_DISPOSABLE_CONTEXT) != 0;
    const bool flagsKnown = (flags & ~kKnownFlags) == 0;
    const amcl::mgbench::GateDecision gate = amcl::mgbench::DecideGate(
        EnvEnabled("AMCL_MG_MULTIDRAW_BENCH"), disposable, flagsKnown);

    if (gate == amcl::mgbench::GateDecision::Disabled) {
        g_threadResponse = BuildResponse(
            "disabled", "AMCL_MG_MULTIDRAW_BENCH is not enabled", nullptr,
            resolvedCachePath, false, false, false, force, {});
        return g_threadResponse.c_str();
    }
    if (gate == amcl::mgbench::GateDecision::Rejected) {
        g_threadResponse = BuildResponse(
            "rejected", "a disposable benchmark context must be acknowledged",
            nullptr, resolvedCachePath, false, false, false, force, {});
        return g_threadResponse.c_str();
    }
    if (startSections < 0 || maxSections < 0) {
        g_threadResponse = BuildResponse(
            "rejected", "section limits must be non-negative", nullptr,
            resolvedCachePath, false, false, false, force, {});
        return g_threadResponse.c_str();
    }

    std::unique_lock<std::mutex> lock(g_benchmarkMutex, std::try_to_lock);
    if (!lock.owns_lock()) {
        g_threadResponse = BuildResponse(
            "busy", "another benchmark is already running", nullptr,
            resolvedCachePath, false, false, false, force, {});
        return g_threadResponse.c_str();
    }

    AmclGlHostInitReportV1 initReport = {sizeof(AmclGlHostInitReportV1), 1u, 0, 0, {0}};
    const auto* runtime = amcl::graphics::BoundGraphicsRuntime();
    using ReadReport = int (*)(AmclGlHostInitReportV1*);
    const auto readReport = runtime && runtime->is("mobileglues") ?
        reinterpret_cast<ReadReport>(runtime->providerProc("amclGlHostGetInitReportV1")) : nullptr;
    if (!readReport || readReport(&initReport) != 2) {
        g_threadResponse = BuildResponse(
            "not-ready", "MobileGlues is not initialized and ready", nullptr,
            resolvedCachePath, false, false, false, force, {});
        return g_threadResponse.c_str();
    }
    if (glfwGetCurrentContext() != nullptr) {
        g_threadResponse = BuildResponse(
            "rejected", "live GLFW contexts cannot be benchmark contexts",
            nullptr, resolvedCachePath, false, false, false, force, {});
        return g_threadResponse.c_str();
    }

    const EGLContext context = eglGetCurrentContext();
    const EGLDisplay display = eglGetCurrentDisplay();
    if (context == EGL_NO_CONTEXT || display == EGL_NO_DISPLAY) {
        g_threadResponse = BuildResponse(
            "rejected", "no current MG EGL benchmark context", nullptr,
            resolvedCachePath, false, false, false, force, {});
        return g_threadResponse.c_str();
    }

    const BenchmarkIdentity identity = ReadIdentity(display);
    const CacheLookup cache = ReadCache(resolvedCachePath, identity);
    const bool invalidated =
        cache.state == CacheState::IdentityMismatch ||
        cache.state == CacheState::Malformed;
    const amcl::mgbench::CacheDecision cacheDecision =
        amcl::mgbench::DecideCache(ToProbeState(cache.state), force);
    if (cacheDecision == amcl::mgbench::CacheDecision::Hit) {
        OH_LOG_INFO(LOG_APP,
                    "event=mg-benchmark-cache-hit key=%{public}s "
                    "renderer=%{public}s driver=%{public}s mg=%{public}s",
                    identity.cacheKey.c_str(), identity.renderer.c_str(),
                    identity.driver.c_str(), identity.mgVersion.c_str());
        g_threadResponse = BuildResponse(
            "cache-hit", nullptr, &identity, resolvedCachePath, true, false,
            false, false, cache.benchmarkJson);
        return g_threadResponse.c_str();
    }

    OH_LOG_INFO(LOG_APP,
                "event=mg-benchmark-start key=%{public}s renderer=%{public}s "
                "driver=%{public}s mg=%{public}s startSections=%{public}d "
                "maxSections=%{public}d forced=%{public}d "
                "cacheInvalidated=%{public}d",
                identity.cacheKey.c_str(), identity.renderer.c_str(),
                identity.driver.c_str(), identity.mgVersion.c_str(),
                startSections, maxSections, force ? 1 : 0,
                invalidated ? 1 : 0);

    const char *rawResult =
        mg_multidraw_bench_run(startSections, maxSections);
    const std::string benchmarkJson =
        rawResult != nullptr ? rawResult : "{\"error\":\"null-result\"}";
    const bool succeeded = BenchmarkSucceeded(benchmarkJson);
    bool cacheWritten = false;
    if (succeeded && !resolvedCachePath.empty()) {
        const std::string cacheDocument =
            BuildCacheDocument(identity, benchmarkJson);
        cacheWritten =
            WriteCacheAtomically(resolvedCachePath, cacheDocument);
        if (!cacheWritten) {
            OH_LOG_WARN(LOG_APP,
                        "event=mg-benchmark-cache-write-failed "
                        "path=%{public}s errno=%{public}d error=%{public}s",
                        resolvedCachePath.c_str(), errno, std::strerror(errno));
        }
    }

    if (succeeded) {
        LogBenchmarkMetrics(identity, benchmarkJson, cacheWritten, invalidated);
    } else {
        OH_LOG_WARN(LOG_APP,
                    "event=mg-benchmark-failed key=%{public}s "
                    "cacheWritten=0; upstream defaults remain active",
                    identity.cacheKey.c_str());
    }
    g_threadResponse = BuildResponse(
        succeeded ? "measured" : "benchmark-error",
        succeeded ? nullptr : "upstream benchmark did not produce a usable result",
        &identity, resolvedCachePath, false, invalidated, cacheWritten, force,
        benchmarkJson);
    return g_threadResponse.c_str();
}
#endif
