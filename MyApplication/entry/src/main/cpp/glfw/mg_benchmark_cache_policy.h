// mg_benchmark_cache_policy.h - Host-testable benchmark/cache decisions.
#ifndef AMCL_GLFW_MG_BENCHMARK_CACHE_POLICY_H
#define AMCL_GLFW_MG_BENCHMARK_CACHE_POLICY_H

#include <cstdint>
#include <cstdio>
#include <string>

namespace amcl::mgbench {

enum class GateDecision {
    Disabled,
    Rejected,
    Continue,
};

enum class CacheProbeState {
    Missing,
    ValidIdentity,
    IdentityMismatch,
    Malformed,
    Unavailable,
};

enum class CacheDecision {
    Hit,
    Run,
};

constexpr GateDecision DecideGate(bool optIn, bool disposableContext,
                                  bool flagsKnown) {
    return !optIn ? GateDecision::Disabled
                  : ((!disposableContext || !flagsKnown)
                         ? GateDecision::Rejected
                         : GateDecision::Continue);
}

constexpr CacheDecision DecideCache(CacheProbeState state, bool force) {
    return !force && state == CacheProbeState::ValidIdentity
               ? CacheDecision::Hit
               : CacheDecision::Run;
}

struct IdentityFields {
    int cacheSchema = 0;
    int benchmarkReportVersion = 0;
    std::string renderer;
    std::string driver;
    std::string frontendVersion;
    std::string mobileGluesVersion;
    std::string mobileGluesCommit;
    std::string mobileGluesBuildIdentity;
    std::string hostBuildIdentity;
    std::string hostAbi;
};

inline void AppendIdentityField(std::string *canonical, const char *name,
                                const std::string &value) {
    canonical->append(name);
    canonical->push_back('=');
    canonical->append(std::to_string(value.size()));
    canonical->push_back(':');
    canonical->append(value);
    canonical->push_back('\n');
}

inline std::string CanonicalIdentity(const IdentityFields &identity) {
    std::string canonical;
    AppendIdentityField(&canonical, "schema",
                        std::to_string(identity.cacheSchema));
    AppendIdentityField(&canonical, "benchmarkReport",
                        std::to_string(identity.benchmarkReportVersion));
    AppendIdentityField(&canonical, "renderer", identity.renderer);
    AppendIdentityField(&canonical, "driver", identity.driver);
    AppendIdentityField(&canonical, "frontend", identity.frontendVersion);
    AppendIdentityField(&canonical, "mobileglues",
                        identity.mobileGluesVersion);
    AppendIdentityField(&canonical, "mobilegluesCommit",
                        identity.mobileGluesCommit);
    AppendIdentityField(&canonical, "mobilegluesBuild",
                        identity.mobileGluesBuildIdentity);
    AppendIdentityField(&canonical, "hostBuild", identity.hostBuildIdentity);
    AppendIdentityField(&canonical, "hostAbi", identity.hostAbi);
    return canonical;
}

inline uint64_t Fnv1a64(const std::string &value) {
    uint64_t hash = UINT64_C(14695981039346656037);
    for (const unsigned char byte : value) {
        hash ^= static_cast<uint64_t>(byte);
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

inline std::string IdentityCacheKey(const IdentityFields &identity) {
    char key[17] = {};
    std::snprintf(key, sizeof(key), "%016llx",
                  static_cast<unsigned long long>(
                      Fnv1a64(CanonicalIdentity(identity))));
    return key;
}

} // namespace amcl::mgbench

#endif // AMCL_GLFW_MG_BENCHMARK_CACHE_POLICY_H
