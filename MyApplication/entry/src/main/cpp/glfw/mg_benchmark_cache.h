// mg_benchmark_cache.h - Explicit MobileGlues multidraw measurement ABI.
#ifndef AMCL_GLFW_MG_BENCHMARK_CACHE_H
#define AMCL_GLFW_MG_BENCHMARK_CACHE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GLFW_AMCL_MG_BENCHMARK_ABI_VERSION 1u

enum glfwAMCLMobileGluesBenchmarkFlags {
    // Required. The caller confirms that the current MG EGL context is a
    // dedicated measurement context that may be destroyed or lost.
    GLFW_AMCL_MG_BENCHMARK_DISPOSABLE_CONTEXT = 1u << 0,
    // Ignore a valid identity-matched cache entry and measure again.
    GLFW_AMCL_MG_BENCHMARK_FORCE = 1u << 1,
};

// Default-only measurement entry point; absent from other product DSOs. It never runs
// from glfwInit, window creation or the render loop. In addition to this call,
// AMCL_MG_MULTIDRAW_BENCH=1 and DISPOSABLE_CONTEXT are required. The caller
// must own a current MG EGL context that is not a live GLFW game context.
//
// cachePath may be null/empty. Resolution then uses
// AMCL_MG_MULTIDRAW_BENCH_CACHE, followed by MG_DIR_PATH's versioned cache.
// The returned JSON pointer remains valid on the calling thread until its next
// call. Benchmark results are evidence only; this API never rewrites config.json
// or changes MobileGlues' active multidraw order.
const char *glfwAMCLMobileGluesBenchmarkRunV1(int32_t startSections,
                                              int32_t maxSections,
                                              uint32_t flags,
                                              const char *cachePath);

#ifdef __cplusplus
}
#endif

#endif // AMCL_GLFW_MG_BENCHMARK_CACHE_H
