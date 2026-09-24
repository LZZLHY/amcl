// ohos_native_window_telemetry.cpp - Low-risk NativeWindow capability probe.

#include "ohos_native_window_telemetry.h"
#include "../utils/product_diagnostics.h"

#include <hilog/log.h>
#include <native_window/external_window.h>

#include <cstdlib>
#include <cstring>
#include <strings.h>

#undef LOG_TAG
#define LOG_TAG "AMCL_NATIVE_WINDOW"

namespace amcl::ohos {
namespace {

bool SnapshotDisabled() {
    const char *value = std::getenv("AMCL_OHOS_NATIVE_WINDOW_QUERY");
    if (value == nullptr || value[0] == '\0') {
        return false;
    }
    return std::strcmp(value, "0") == 0 || strcasecmp(value, "off") == 0 ||
           strcasecmp(value, "false") == 0 || strcasecmp(value, "no") == 0 ||
           strcasecmp(value, "disabled") == 0;
}

const char *SafeStage(const char *lifecycleStage) {
    return lifecycleStage != nullptr ? lifecycleStage : "unknown";
}

} // namespace

void LogNativeWindowSnapshot(OHNativeWindow *window, int expectedWidth,
                             int expectedHeight, const char *lifecycleStage) {
    if (!(AMCL_DIAGNOSTICS_MASK & 1)) return;
    if (window == nullptr || SnapshotDisabled()) {
        OH_LOG_INFO(LOG_APP,
                    "event=native-window-query-skipped stage=%{public}s "
                    "reason=%{public}s",
                    SafeStage(lifecycleStage),
                    window == nullptr ? "null-window" : "env-disabled");
        return;
    }

    // GET_BUFFER_GEOMETRY's documented vararg order is height, then width.
    int32_t queriedHeight = 0;
    int32_t queriedWidth = 0;
    int32_t format = 0;
    uint64_t usage = 0;
    int32_t swapInterval = 0;
    int32_t queueSize = 0;

    const int32_t geometryResult = OH_NativeWindow_NativeWindowHandleOpt(
        window, GET_BUFFER_GEOMETRY, &queriedHeight, &queriedWidth);
    const int32_t formatResult =
        OH_NativeWindow_NativeWindowHandleOpt(window, GET_FORMAT, &format);
    const int32_t usageResult =
        OH_NativeWindow_NativeWindowHandleOpt(window, GET_USAGE, &usage);
    const int32_t swapResult = OH_NativeWindow_NativeWindowHandleOpt(
        window, GET_SWAP_INTERVAL, &swapInterval);
    // GET_BUFFERQUEUE_SIZE was introduced in API 12, below AMCL's API 20
    // compatibility baseline. A non-zero result remains a supported fallback.
    const int32_t queueResult = OH_NativeWindow_NativeWindowHandleOpt(
        window, GET_BUFFERQUEUE_SIZE, &queueSize);

    OH_LOG_INFO(
        LOG_APP,
        "event=native-window-query stage=%{public}s ptr=%{public}p "
        "expected=%{public}dx%{public}d geometryRc=%{public}d "
        "geometry=%{public}dx%{public}d formatRc=%{public}d "
        "format=%{public}d usageRc=%{public}d usage=0x%{public}llx "
        "swapRc=%{public}d swapInterval=%{public}d queueRc=%{public}d "
        "queueSize=%{public}d",
        SafeStage(lifecycleStage), window, expectedWidth, expectedHeight,
        geometryResult, queriedWidth, queriedHeight, formatResult, format,
        usageResult, static_cast<unsigned long long>(usage), swapResult,
        swapInterval, queueResult, queueSize);
}

} // namespace amcl::ohos
