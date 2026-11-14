#pragma once
#include "render_scale.h"
#include <cmath>
#include <cstdint>

namespace amcl::renderscale {

/** 一次政策计算的候选；它不代表平台已分配图像。所有尺寸均为当前组件局部物理px。 */
struct ResolutionTarget {
    int displayWidth = 0, displayHeight = 0;
    int width = 0, height = 0;
    double scale = 1.0;
};

enum class ResolutionPhase { kIdle, kPending, kAwaitingDrawable, kConfirmed, kRejected, kRestoring, kRestartRequired, kSuspended };

/**
 * 无平台依赖的分辨率事务状态。由XComponent的surface gate串行调用；本类不拥有窗口、
 * 不设置环境变量、不调用游戏回调。generation绑定平台发布，revision绑定用户请求。
 * 显式请求最多合并为一项；实际图像不匹配时最多请求一次重新建立旧的确认尺寸，
 * 不能把旧句柄可用当作回滚证明。恢复也必须重新收到同代实际drawable观测。
 */
class ResolutionState {
public:
    static constexpr uint32_t kMaxObservationAttempts = 30;

    void beginLaunch(double scale) {
        *this = ResolutionState{};
        desiredScale_ = validScale(scale) ? scale : 1.0;
        virtualWindowManaged_ = desiredScale_ < 1.0;
    }

    bool request(double scale, int width, int height) {
        if (!validScale(scale) || width <= 0 || height <= 0 || revision_ == UINT64_MAX) return false;
        if (phase_ == ResolutionPhase::kPending && target_.scale == scale &&
            target_.displayWidth == width && target_.displayHeight == height) return true;
        ++revision_;
        desiredScale_ = scale;
        // 游戏可能保存了进入全屏前的旧L尺寸；恢复100%也不能把旧L当物理窗口尺寸。
        // 本局一旦使用虚拟分辨率，显示区域始终由宿主/系统窗口管理，下一局重新判定。
        virtualWindowManaged_ = virtualWindowManaged_ || scale < 1.0;
        target_ = makeTarget(scale, width, height);
        restoring_ = false;
        reason_ = "";
        phase_ = ResolutionPhase::kPending;
        return true;
    }

    /** 平台尺寸变化重算同一用户政策；零尺寸只暂停，后续可恢复时重新计算。 */
    void displayChanged(int width, int height) {
        if (width <= 0 || height <= 0) { suspend(); return; }
        // 重复平台回调不能重试失败请求，也不取消正在确认的事务。
        if (target_.displayWidth == width && target_.displayHeight == height &&
            phase_ != ResolutionPhase::kIdle && phase_ != ResolutionPhase::kSuspended) return;
        request(desiredScale_, width, height);
    }

    /** 首次配置失败时回到原生候选；实际原生图像确认前不声称已恢复。 */
    void nativeFallback(int width, int height, const char* reason) {
        target_ = makeTarget(1.0, width, height);
        restoring_ = true;
        reason_ = reason;
    }

    void requireRestart(const char* reason) {
        reason_ = reason;
        phase_ = ResolutionPhase::kRestartRequired;
    }

    /** SET成功且窗口/input同代发布后调用；实际图像资格清空，等待owner读回。 */
    bool configured(uint64_t generation, uint64_t revision) {
        if (generation == 0 || revision != revision_ || phase_ != ResolutionPhase::kPending) return false;
        applied_ = target_;
        generation_ = generation;
        actualWidth_ = actualHeight_ = 0;
        observationSource_ = attempts_ = 0;
        phase_ = restoring_ ? ResolutionPhase::kRestoring : ResolutionPhase::kAwaitingDrawable;
        return true;
    }

    /**
     * SET失败没有发布候选。原确认图像仍属于旧几何；若失败的是恢复请求则要求重启，
     * 不能声称已回滚。调用方继续保持旧映射或在物理区域已变化时停止输入。
     */
    void rejected(const char* reason) {
        reason_ = reason;
        phase_ = restoring_ ? ResolutionPhase::kRestartRequired : ResolutionPhase::kRejected;
    }

    /** 仅接受成功EGL查询/成功VkSwapchain创建的同代尺寸；过时代次不得确认新事务。 */
    bool observe(uint64_t generation, int width, int height, uint32_t source) {
        const bool actual = (source == 1u || source == 2u) && width > 0 && height > 0;
        const bool queryFailed = source == 0u && width == 0 && height == 0;
        if (!(flags() & 2u) || generation != generation_ || (!actual && !queryFailed)) return false;
        if (actual) {
            actualWidth_ = width;
            actualHeight_ = height;
            observationSource_ = source;
        }
        if (actual && width == applied_.width && height == applied_.height) {
            confirmed_ = applied_;
            haveConfirmed_ = true;
            launchConfirmed_ = true;
            phase_ = restoring_ ? ResolutionPhase::kRejected : ResolutionPhase::kConfirmed;
            return true;
        }
        if (++attempts_ < kMaxObservationAttempts) return true;
        reason_ = queryFailed ? "drawable-query-failed" : "drawable-size-mismatch";
        if (!restoring_ && haveConfirmed_) {
            // 恢复遵守当前物理区域；重新申请旧比例，不重用已退休的GPU对象。
            target_ = makeTarget(confirmed_.scale, applied_.displayWidth, applied_.displayHeight);
            restoring_ = true;
            phase_ = ResolutionPhase::kPending;
        } else phase_ = ResolutionPhase::kRestartRequired;
        return true;
    }

    /** 表面消失后撤销图像证据与待执行事务；保留用户政策供新资源恢复，不保留旧确认。 */
    void suspend() {
        phase_ = ResolutionPhase::kSuspended;
        generation_ = 0;
        actualWidth_ = actualHeight_ = 0;
        observationSource_ = attempts_ = 0;
        haveConfirmed_ = restoring_ = false;
        // 保留最后一次SET接受的尺寸，仅供同一NativeWindow从零面积恢复时唤醒前端；
        // generation/actual均已撤销，不能把这份配置当成恢复后的图像或回滚资格。
    }

    uint32_t flags() const {
        if (phase_ == ResolutionPhase::kPending) return 1u;
        if (phase_ == ResolutionPhase::kAwaitingDrawable || phase_ == ResolutionPhase::kRestoring) return 2u;
        return 0u;
    }
    double desiredScale() const { return desiredScale_; }
    uint64_t revision() const { return revision_; }
    uint64_t generation() const { return generation_; }
    ResolutionPhase phase() const { return phase_; }
    const ResolutionTarget& target() const { return target_; }
    const ResolutionTarget& applied() const { return applied_; }
    const char* reason() const { return reason_; }
    int actualWidth() const { return actualWidth_; }
    int actualHeight() const { return actualHeight_; }
    uint32_t observationSource() const { return observationSource_; }
    bool hasConfirmedDrawable() const {
        return generation_ != 0 && observationSource_ != 0 && actualWidth_ > 0 && actualHeight_ > 0 &&
            actualWidth_ == applied_.width && actualHeight_ == applied_.height;
    }
    bool restoring() const { return restoring_; }
    /** 本局曾按目标尺寸完成 actual 确认；surface 暂停不重置，下一局 beginLaunch 才重置。
     * 用于区分首帧前的长加载与运行期恢复，不表示当前资源仍有效，也不能用于恢复输入。
     */
    bool hasConfirmedDuringLaunch() const { return launchConfirmed_; }
    bool virtualWindowManaged() const { return virtualWindowManaged_; }

    static bool validScale(double scale) { return std::isfinite(scale) && scale >= kMinScale && scale <= 1.0; }
    static ResolutionTarget makeTarget(double scale, int width, int height) {
        return {width, height, ScaledDimension(width, scale), ScaledDimension(height, scale), scale};
    }
private:
    double desiredScale_ = 1.0;
    uint64_t revision_ = 0, generation_ = 0;
    ResolutionPhase phase_ = ResolutionPhase::kIdle;
    ResolutionTarget target_{}, applied_{}, confirmed_{};
    bool haveConfirmed_ = false, restoring_ = false;
    bool launchConfirmed_ = false;
    bool virtualWindowManaged_ = false;
    int actualWidth_ = 0, actualHeight_ = 0;
    uint32_t observationSource_ = 0, attempts_ = 0;
    const char* reason_ = "";
};
}
