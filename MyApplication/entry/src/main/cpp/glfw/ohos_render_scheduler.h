// ohos_render_scheduler.h - scoped QoS lease for the actual OHOS render thread.
#ifndef AMCL_OHOS_RENDER_SCHEDULER_H
#define AMCL_OHOS_RENDER_SCHEDULER_H

namespace amcl::ohos {

// Must be called on the thread after its EGL/Zink context was made current.
// Repeated calls in one context-current epoch are idempotent.
void EnterInteractiveRenderQoS(const char *renderBackend);

// Must be called on the same thread when its context is logically released.
// A thread-local destructor provides a final safety net for abrupt thread exit.
void LeaveInteractiveRenderQoS(const char *reason);

} // namespace amcl::ohos

#endif // AMCL_OHOS_RENDER_SCHEDULER_H
