#ifndef AMCL_CURSOR_CAPTURE_CONTEXT_H
#define AMCL_CURSOR_CAPTURE_CONTEXT_H

namespace amcl::input {
/**
 * 平台捕获的准入状态。Unknown focus 在新surface上允许请求，由WindowManager作最终
 * 授权，避免未派发初始focus的设备永久无鼠标；明确Blurred、无surface或暂停则拒绝。
 * 此类无锁无平台调用，宿主在cursor mutex内使用，host测试可穷举整个生命周期。
 */
class CursorCaptureContext final {
public:
    enum class Focus { Unknown, Focused, Blurred };
    void Surface(bool available) {
        if (available && !surface_) focus_ = Focus::Unknown;
        surface_ = available;
    }
    void Focused(bool focused) { focus_ = focused ? Focus::Focused : Focus::Blurred; }
    void Paused(bool paused) { paused_ = paused; }
    // Ability前台与组件焦点是正交事实。调用方传入唯一foreground OR-mask的快照，
    // 后台/前台翻转不得把Unknown焦点改成一个永远等不到恢复边沿的Blurred。
    bool CanLock(bool foreground = true) const {
        return foreground && surface_ && !paused_ && focus_ != Focus::Blurred;
    }
private:
    bool surface_ = false;
    bool paused_ = false;
    Focus focus_ = Focus::Unknown;
};
}
#endif
