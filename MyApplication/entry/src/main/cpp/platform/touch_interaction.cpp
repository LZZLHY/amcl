// 菜单与摇杆策略的生产实现；测试直接链接本文件，不复制状态转换。
#include "touch_interaction.h"
#include <algorithm>
#include <cmath>

namespace amcl::input {
namespace {
// 参数验证与 NAPI/ArkTS 同范围；浮点必须先检查有限，才能安全参与坐标/期限计算。
bool InRange(double value, double low, double high) {
    return std::isfinite(value) && value >= low && value <= high;
}
/**
 * 已认领两指滚动的唯一delta归约。caller仍持原down/scrolling角色，dx/dy是本指相对
 * 上次真实采样的surface像素；每指按两指平均及6vp/density转换，保原同号方向与余量。
 * MOVE与正常UP末段都走这里，UP同坐标的零delta不重复输出；CANCEL不调用本函数。
 * emit沿原gesture/source/prefix与interaction order链发布，不在此新建owner或模拟click。
 */
void AccumulateMenuScroll(double dx,double dy,double density,double& scrollX,double& scrollY,
                          const MenuTouchEmitter& emit) {
    scrollX += dx / (2 * 6 * density); scrollY += dy / (2 * 6 * density);
    const double sx = std::trunc(scrollX), sy = std::trunc(scrollY);
    if (sx != 0 || sy != 0) { emit(MenuTouchAction::Scroll,sx,sy); scrollX -= sx; scrollY -= sy; }
}
}
bool ValidTouchInteractionConfig(const TouchInteractionConfig& c) {
    if (c.version != 1 || !InRange(c.menuSensitivity,.3,3) || c.menuHoldMs < 150 || c.menuHoldMs > 1000 ||
        !InRange(c.sprintThreshold,.5,1.5) || c.holdMs < 200 || c.holdMs > 1500 ||
        c.gestureMode < 0 || c.gestureMode > 2) return false;
    for (const int code : c.actions) if (code < -16 || code > 512) return false;
    return true;
}
bool SameTouchInteractionConfig(const TouchInteractionConfig& a, const TouchInteractionConfig& b) {
    return a.version == b.version && a.touchpad == b.touchpad && a.menuSensitivity == b.menuSensitivity &&
        a.menuScroll == b.menuScroll && a.menuHoldMs == b.menuHoldMs &&
        a.floatingJoystick == b.floatingJoystick && a.sprint == b.sprint &&
        a.sprintThreshold == b.sprintThreshold && a.hotbarSwap == b.hotbarSwap && a.hotbarDrop == b.hotbarDrop &&
        a.holdMs == b.holdMs && a.actions == b.actions;
}

// 配置切换是明确的会话边界，取消旧拖动后再替换。初次显示居中，后续尺寸变化保留可见范围内的位置。
void MenuTouchInteraction::Configure(double width, double height, double density,
                                     const TouchInteractionConfig& config, const MenuTouchEmitter& emit) {
    Cancel(emit);
    if (width_ == 0 || height_ == 0) { cursorX_ = width / 2; cursorY_ = height / 2; }
    width_ = std::max(1.0, width); height_ = std::max(1.0, height);
    density_ = InRange(density,.1,100) ? density : 1;
    config_ = config;
    cursorX_ = std::clamp(cursorX_,0.0,width_ - 1);
    cursorY_ = std::clamp(cursorY_,0.0,height_ - 1);
}
bool MenuTouchInteraction::AnyDown() const {
    for (const auto& p : pointers_) if (p.down) return true;
    return false;
}
void MenuTouchInteraction::Position(double x, double y, const MenuTouchEmitter& emit) {
    cursorX_ = std::clamp(x,0.0,std::max(0.0,width_ - 1));
    cursorY_ = std::clamp(y,0.0,std::max(0.0,height_ - 1));
    emit(MenuTouchAction::Position,cursorX_,cursorY_);
}
void MenuTouchInteraction::StartDrag(const MenuTouchEmitter& emit) {
    if (dragging_ || primary_ < 0 || suppressed_ || externalButtons_) return;
    dragging_ = true; candidate_ = false; scrollEligible_ = false; deadline_ = 0;
    emit(config_.touchpad ? MenuTouchAction::RelativeDown : MenuTouchAction::Down,
         config_.touchpad ? 0 : cursorX_,config_.touchpad ? 0 : cursorY_);
}
void MenuTouchInteraction::Tick(int64_t timeNs, const MenuTouchEmitter& emit) {
    if (deadline_ > 0 && timeNs >= deadline_ && candidate_ && !scrolling_) StartDrag(emit);
}
void MenuTouchInteraction::SetExternalButtonsHeld(bool held) {
    externalButtons_ = held;
    if (held) scrollEligible_ = false;
    if (held && !dragging_) { candidate_ = false; deadline_ = 0; }
}
void MenuTouchInteraction::AdoptCursor(double x,double y) {
    if (Active() || width_<=0 || height_<=0 || !std::isfinite(x) || !std::isfinite(y)) return;
    cursorX_=std::clamp(x,0.0,width_-1); cursorY_=std::clamp(y,0.0,height_-1);
}
/** 仅反馈承接：relative动作使用pointer采样差分，因此ACK更新不会污染下一笔真实delta。 */
void MenuTouchInteraction::AdoptConsumedCursor(double x,double y) {
    if(DirectActive() || width_<=0 || height_<=0 || !std::isfinite(x) || !std::isfinite(y)) return;
    cursorX_=std::clamp(x,0.0,width_-1);cursorY_=std::clamp(y,0.0,height_-1);
}
bool MenuTouchInteraction::MoveCursor(double dx,double dy,const MenuTouchEmitter& emit) {
    if (DirectActive() || width_<=0 || height_<=0 || !std::isfinite(dx) || !std::isfinite(dy) ||
        std::abs(dx)>1048576 || std::abs(dy)>1048576) return false;
    // 缓存只作反馈投影，窗口边缘clamp不能吞掉真实delta；最终基线和边界在有序consumer应用。
    const double mx=dx*config_.menuSensitivity,my=dy*config_.menuSensitivity;
    cursorX_=std::clamp(cursorX_+mx,0.0,width_-1);cursorY_=std::clamp(cursorY_+my,0.0,height_-1);
    emit(MenuTouchAction::RelativePosition,mx,my);
    return true;
}
void MenuTouchInteraction::Cancel(const MenuTouchEmitter& emit) {
    // 尚未按键的candidate、pointer-only和scroll也有事务；CANCEL必须撤 queued cursor/wheel，不能只补UP。
    if (gesture_) emit(config_.touchpad ? MenuTouchAction::RelativeCancel : MenuTouchAction::Cancel,
                       config_.touchpad ? 0 : cursorX_,config_.touchpad ? 0 : cursorY_);
    pointers_ = {}; primary_ = secondary_ = -1;
    deadline_ = startNs_ = 0;
    candidate_ = dragging_ = scrolling_ = suppressed_ = scrollEligible_ = false;
    gesture_ = false;
    scrollX_ = scrollY_ = 0;
}

void MenuTouchInteraction::Event(TouchPhase phase, int finger, double x, double y, int64_t timeNs,
                                const MenuTouchEmitter& emit) {
    if (phase == TouchPhase::Cancel) { Cancel(emit); return; }
    // 首次合法Configure前没有可解释的viewport，不建立假中心或无界pointer事务。
    if (width_<=0 || height_<=0 || finger < 0 || finger >= static_cast<int>(pointers_.size()) || !std::isfinite(x) ||
        !std::isfinite(y) || std::abs(x) > 1048576 || std::abs(y) > 1048576 ||
        timeNs <= 0 || timeNs > INT64_MAX - 2000000000LL) return;
    Pointer& p = pointers_[static_cast<size_t>(finger)];
    if (phase == TouchPhase::Down) {
        // 重复 DOWN 不能继承旧候选；释放旧会话，再把本事件视为新的起点。
        if (p.down) Cancel(emit);
        const bool empty = !AnyDown();
        p = {true,x,y};
        // 长按期限由同一个事件时间复核，不让第二指和deadline线程的调度先后改变拖动解释。
        if (!empty) Tick(timeNs,emit);
        if (empty) {
            primary_ = finger; startX_ = x; startY_ = y; startNs_ = timeNs;
            candidate_ = !externalButtons_; suppressed_ = false;
            scrollEligible_ = config_.menuScroll && !externalButtons_;
            gesture_=true;
            if (!config_.touchpad) {
                cursorX_=std::clamp(x,0.0,width_-1);cursorY_=std::clamp(y,0.0,height_-1);
                emit(MenuTouchAction::Begin,cursorX_,cursorY_);
            } else emit(MenuTouchAction::RelativeBegin,0,0);
            deadline_ = candidate_ ? timeNs + static_cast<int64_t>(config_.menuHoldMs) * 1000000 : 0;
            if (!config_.touchpad && !config_.menuScroll) StartDrag(emit);
        } else if (scrollEligible_ && primary_ >= 0 && secondary_ < 0 &&
                   !dragging_ && !suppressed_ && timeNs >= startNs_) {
            secondary_ = finger; scrolling_ = true; candidate_ = false; deadline_ = 0;
            scrollX_ = scrollY_ = 0;
        }
        return;
    }
    if (!p.down) return;
    if (phase == TouchPhase::Move) {
        const double dx = x - p.x, dy = y - p.y;
        p.x = x; p.y = y;
        if (suppressed_) return;
        if (scrolling_ && (finger == primary_ || finger == secondary_)) {
            // 两指平均位移以6vp为一格，保留小幅精调余量。正dy给正wheel，使列表内容跟手向下，
            // 而上滑给负wheel、查看下面的项目；不能沿用世界快捷栏滚轮条的反向约定。
            AccumulateMenuScroll(dx,dy,density_,scrollX_,scrollY_,emit);
        } else if (finger == primary_) {
            // 直接模式为等待第二指而延后按下；一旦识别成拖动，必须先在原始落点按下，
            // 再移动到本次采样位置。否则首个MOVE跨过物品格时会拿起目标格而不是源格。
            const bool beyondSlop = std::hypot(x - startX_,y - startY_) > 6 * density_;
            if (!config_.touchpad && candidate_ && beyondSlop && !dragging_) {
                Position(startX_,startY_,emit);
                StartDrag(emit);
            }
            if (config_.touchpad) {
                const double mx=dx*config_.menuSensitivity,my=dy*config_.menuSensitivity;
                cursorX_=std::clamp(cursorX_+mx,0.0,width_-1);cursorY_=std::clamp(cursorY_+my,0.0,height_-1);
                emit(MenuTouchAction::RelativePosition,mx,my);
            }
            else Position(x,y,emit);
            if (beyondSlop) {
                candidate_ = false; deadline_ = 0;
            }
            Tick(timeNs,emit);
        }
        return;
    }
    // 正常UP也是最后一份真实位置样本。必须在原down/scrolling角色仍成立时先采末段，
    // 再抑制残余指；否则平台合并/省略最后MOVE会丢这段wheel。相同坐标UP自然为零。
    // CANCEL已在入口独立返回，不能借取消占位坐标追加滚动；未参与的残余指也不采样。
    if (scrolling_ && !suppressed_ && (finger == primary_ || finger == secondary_)) {
        const double dx = x - p.x, dy = y - p.y;
        p.x = x; p.y = y;
        AccumulateMenuScroll(dx,dy,density_,scrollX_,scrollY_,emit);
    }
    // UP 只完成自己的角色；滚动任一指抬起后，残留触点都不得重新成为点击或移动候选。
    p.down = false;
    if (scrolling_ && (finger == primary_ || finger == secondary_)) {
        scrolling_ = false; suppressed_ = true; candidate_ = false; scrollEligible_ = false; deadline_ = 0;
    } else if (finger == primary_ && !suppressed_) {
        // 平台可以合并或不投递中间MOVE。直接模式的单指仍可由真实UP终点确认拖动，
        // 必须先在冻结源点按下，再发布终点、释放；不能因缺MOVE把整次跨格操作静默丢掉。
        // 相对触摸板的滑动只移动指针，不能借终点距离补出用户没有认领的左键。
        if (!config_.touchpad && candidate_ && !dragging_ &&
            std::hypot(x-startX_,y-startY_) > 6*density_) {
            Position(startX_,startY_,emit);
            StartDrag(emit);
        }
        const double endDx=(x-p.x)*config_.menuSensitivity,endDy=(y-p.y)*config_.menuSensitivity;
        if (!config_.touchpad) Position(x,y,emit);
        else {
            cursorX_=std::clamp(cursorX_+endDx,0.0,width_-1);cursorY_=std::clamp(cursorY_+endDy,0.0,height_-1);
        }
        if (dragging_) {
            emit(config_.touchpad ? MenuTouchAction::RelativeUp : MenuTouchAction::Up,
                 config_.touchpad ? endDx : cursorX_,config_.touchpad ? endDy : cursorY_);
        } else if (candidate_ && std::hypot(x-startX_,y-startY_) <= 6*density_) {
            // relative tap把终点未采样delta与DOWN放进同一语义，随后UP0；按键起点由consumer当时指针决定。
            emit(config_.touchpad ? MenuTouchAction::RelativeDown : MenuTouchAction::Down,
                 config_.touchpad ? endDx : cursorX_,config_.touchpad ? endDy : cursorY_);
            emit(config_.touchpad ? MenuTouchAction::RelativeUp : MenuTouchAction::Up,
                 config_.touchpad ? 0 : cursorX_,config_.touchpad ? 0 : cursorY_);
        } else if(config_.touchpad && gesture_) {
            // pointer-only终点仍先贡献真实末段delta；END只是生命周期完成，不能后移或倒退cursor。
            emit(MenuTouchAction::RelativePosition,endDx,endDy);
        }
        dragging_ = candidate_ = false; deadline_ = 0; suppressed_ = true;
    }
    if (!AnyDown()) {
        // scroll残留指全离开才正常END；完成END不等于CANCEL，下一笔BEGIN不得撤已经完成的快速tap。
        if(gesture_) emit(config_.touchpad ? MenuTouchAction::RelativeEnd : MenuTouchAction::End,0,0);
        gesture_=false;primary_ = secondary_ = -1; suppressed_ = scrolling_ = false;
    }
}

void TouchJoystickInteraction::Begin(double x, double y, double left, double top, double width, double height,
                                     const TouchInteractionConfig& config, double deadZone) {
    Reset(); config_ = config; deadZone_ = deadZone;
    centerX_ = config.floatingJoystick ? x : left + width / 2;
    centerY_ = config.floatingJoystick ? y : top + height / 2;
    radius_ = std::max(1.0,std::min(width,height) * .34);
    Move(x,y);
}
void TouchJoystickInteraction::Move(double x, double y) {
    if (!std::isfinite(x) || !std::isfinite(y)) return;
    const double dx = (x - centerX_) / radius_, dy = (y - centerY_) / radius_;
    const double length = std::hypot(dx,dy);
    x_ = dx / std::max(1.0,length); y_ = dy / std::max(1.0,length);
    const bool forward = -dy > deadZone_ && -dy >= std::abs(dx);
    // 进入/退出阈值相差少量比例，避免手指静置在疾跑边缘反复发送修饰键。
    const double threshold = config_.sprintThreshold * (sprint_ ? .85 : 1.0);
    const bool extended = forward && length >= threshold;
    sprint_ = config_.sprint && extended;
    armed_ = false; // 旧autoWalk字段只作协议兼容，运行中不再建立松手锁存。
    locked_ = false;
}
void TouchJoystickInteraction::End(bool /*cancelled*/) {
    Reset();
}
void TouchJoystickInteraction::Reset() {
    x_ = y_ = 0; sprint_ = armed_ = locked_ = false;
}
}
