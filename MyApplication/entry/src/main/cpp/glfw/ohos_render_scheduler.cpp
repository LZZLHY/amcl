// ohos_render_scheduler.cpp - HarmonyOS render-thread scheduling adapter.

#include "ohos_render_scheduler.h"

#include <hilog/log.h>
#include <qos/qos.h>
#include <unistd.h>

#undef LOG_TAG
#define LOG_TAG "AMCL_RENDER_QOS"

namespace amcl::ohos {
namespace {

struct RenderQoSLease {
    bool attempted = false;
    bool active = false;
    bool changedByAmcl = false;
    bool previousLevelValid = false;
    bool releaseFailureLogged = false;
    QoS_Level previousLevel = QOS_DEFAULT;

    ~RenderQoSLease() { Release("thread-exit"); }

    void Enter(const char *renderBackend) {
        if (attempted) {
            return;
        }
        attempted = true;

        QoS_Level currentLevel = QOS_DEFAULT;
        previousLevelValid = OH_QoS_GetThreadQoS(&currentLevel) == 0;
        previousLevel = currentLevel;
        if (previousLevelValid && currentLevel == QOS_USER_INTERACTIVE) {
            // Preserve a QoS lease owned by an embedding/runtime layer. AMCL
            // must not reset scheduling state it did not establish.
            active = true;
            changedByAmcl = false;
            OH_LOG_INFO(
                LOG_APP,
                "Render thread %{public}d already has USER_INTERACTIVE QoS; "
                "preserving owner "
                "(backend=%{public}s)",
                static_cast<int>(gettid()),
                renderBackend != nullptr ? renderBackend : "unknown");
            return;
        }

        const int result = OH_QoS_SetThreadQoS(QOS_USER_INTERACTIVE);
        if (result != 0) {
            // Scheduling hints must never make context creation fail. Keep the
            // attempt idempotent until Leave(), then retry on the next epoch.
            OH_LOG_WARN(
                LOG_APP,
                "OH_QoS_SetThreadQoS(USER_INTERACTIVE) failed on render thread "
                "%{public}d "
                "(result=%{public}d, backend=%{public}s); rendering continues",
                static_cast<int>(gettid()), result,
                renderBackend != nullptr ? renderBackend : "unknown");
            return;
        }

        active = true;
        changedByAmcl = true;
        OH_LOG_INFO(LOG_APP,
                    "Render thread %{public}d entered USER_INTERACTIVE QoS "
                    "(backend=%{public}s, "
                    "previous=%{public}s)",
                    static_cast<int>(gettid()),
                    renderBackend != nullptr ? renderBackend : "unknown",
                    previousLevelValid ? "set" : "unset");
    }

    void Release(const char *reason) {
        if (!attempted) {
            return;
        }
        if (!active || !changedByAmcl) {
            Clear();
            return;
        }

        const int result = previousLevelValid
                               ? OH_QoS_SetThreadQoS(previousLevel)
                               : OH_QoS_ResetThreadQoS();
        if (result != 0) {
            // Keep the lease live so later release paths (destroy/terminate/TLS
            // teardown) can retry instead of silently leaving elevated QoS.
            if (!releaseFailureLogged) {
                releaseFailureLogged = true;
                OH_LOG_WARN(
                    LOG_APP,
                    "Failed to restore render thread %{public}d QoS "
                    "(result=%{public}d, "
                    "reason=%{public}s); a later release path will retry",
                    static_cast<int>(gettid()), result,
                    reason != nullptr ? reason : "unknown");
            }
            return;
        }

        OH_LOG_INFO(LOG_APP,
                    "Render thread %{public}d QoS restored (reason=%{public}s)",
                    static_cast<int>(gettid()),
                    reason != nullptr ? reason : "unknown");
        Clear();
    }

    void Clear() {
        attempted = false;
        active = false;
        changedByAmcl = false;
        previousLevelValid = false;
        releaseFailureLogged = false;
        previousLevel = QOS_DEFAULT;
    }
};

thread_local RenderQoSLease g_renderQoSLease;

} // namespace

void EnterInteractiveRenderQoS(const char *renderBackend) {
    g_renderQoSLease.Enter(renderBackend);
}

void LeaveInteractiveRenderQoS(const char *reason) {
    g_renderQoSLease.Release(reason);
}

} // namespace amcl::ohos
