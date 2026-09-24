// ohos_native_window_telemetry.h - Side-effect-free NativeWindow inspection.
#ifndef AMCL_OHOS_NATIVE_WINDOW_TELEMETRY_H
#define AMCL_OHOS_NATIVE_WINDOW_TELEMETRY_H

struct NativeWindow;
typedef struct NativeWindow OHNativeWindow;

namespace amcl::ohos {

// Must be called from OnSurfaceCreated before the window is published to the
// render side. NativeWindowHandleOpt is not thread-safe even for GET operations,
// so active resize/destroy callbacks must not query while EGL may be swapping.
// EGL remains the sole owner of buffer dequeue/queue and all mutation.
void LogNativeWindowSnapshot(OHNativeWindow *window, int expectedWidth,
                             int expectedHeight, const char *lifecycleStage);

} // namespace amcl::ohos

#endif // AMCL_OHOS_NATIVE_WINDOW_TELEMETRY_H
