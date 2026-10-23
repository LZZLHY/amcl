// 触控策略与无平台依赖的手势状态机。
// 所有方法由宿主在同一 schema 锁内调用；本层只产生语义结果，不持有窗口、线程或全局按键账本。
// TouchController 后续只能在认领 DOWN 前选择解释器；已认领触点必须在同一会话内完成或取消。
#ifndef AMCL_TOUCH_INTERACTION_H
#define AMCL_TOUCH_INTERACTION_H
#include <array>
#include <cstdint>
#include <functional>

namespace amcl::input {

// 下标与 gamecontrol/TouchActionBindings.ets 保持一致；0 作为输出值表示解除绑定。
enum TouchAction : int {
    TouchForward, TouchLeft, TouchBack, TouchRight, TouchSprint, TouchSwap, TouchDrop,
    TouchHotbar1, TouchHotbar2, TouchHotbar3, TouchHotbar4, TouchHotbar5, TouchHotbar6,
    TouchHotbar7, TouchHotbar8, TouchHotbar9, TouchAttack, TouchUse, TouchActionCount
};

// 完整、校验后的 schema v3 配置；旧 v2 发布使用同样的兼容缺省。
struct TouchInteractionConfig {
    int version = 1;
    bool touchpad = false;
    double menuSensitivity = 1.0;
    bool menuScroll = false;
    int menuHoldMs = 350;
    bool floatingJoystick = false;
    bool sprint = false;
    bool autoWalk = false; // 历史协议字段；运行不再建立自动前进锁存。
    double sprintThreshold = 0.9;
    bool hotbarSwap = false;
    bool hotbarDrop = false;
    int holdMs = 500;
    int gestureMode = 0; // 历史协议字段；空白区域始终只转视角。
    std::array<int, TouchActionCount> actions{{87,65,83,68,341,70,81,49,50,51,52,53,54,55,56,57,-1,-2}};
};

// 发布前统一验证；Same 忽略结构填充字节，避免相同配置重发导致手势退休。
bool ValidTouchInteractionConfig(const TouchInteractionConfig& config);
bool SameTouchInteractionConfig(const TouchInteractionConfig& a, const TouchInteractionConfig& b);

enum class TouchPhase { Down, Move, Up, Cancel };
// 前五项保留原内部含义；尾部显式表达pointer事务及relative位移，不把反馈absolute缓存冒充传输权威。
enum class MenuTouchAction { Position, Down, Up, Cancel, Scroll,
    Begin, End, RelativeBegin, RelativePosition, RelativeDown, RelativeUp, RelativeEnd, RelativeCancel };
/** 只读教学反馈的累计值；由平台实际接受输入后更新，读取方不参与手势或持有仲裁。 */
struct TouchGuideSignals {
    uint64_t movement=0,hotbar=0,scroll=0,mouseMove=0,mouseButton=0;
    double scrollAmount=0;
    int slot=-1,mouseCode=0;
};
// absolute动作使用surface px；Relative动作使用真实采样delta×sensitivity，绝不从clamp后的投影反算。
// Begin/End仅生命周期不按LEFT；Scroll整格。宿主负责同快照缩放与有序事务token，consumer负责relative累加。
using MenuTouchEmitter = std::function<void(MenuTouchAction, double, double)>;

/**
 * 菜单策略：点击候选与滚动加入资格独立；只移动相对指针不会禁止第二指加入。
 * 拖动已经开始后不转换角色；滚动结束的残留手指一直抑制到本轮触点全部离开。
 * Tick 只推动真实长按期限，绝不使用固定延时替代消费者的 present 屏障。
 */
class MenuTouchInteraction final {
public:
    void Configure(double width, double height, double density, const TouchInteractionConfig& config,
                   const MenuTouchEmitter& emit);
    void Event(TouchPhase phase, int finger, double x, double y, int64_t timeNs, const MenuTouchEmitter& emit);
    void Tick(int64_t timeNs, const MenuTouchEmitter& emit);
    void Cancel(const MenuTouchEmitter& emit);
    // 辅助按钮/实体鼠标已按住时，当前手指只移动指针；候选被取消后不会因按钮释放重新变成点击。
    void SetExternalButtonsHeld(bool held);
    // 空闲时承接已确认的外部菜单位置，切回触摸板从当前光标开始；不打断已经认领的触控手势。
    void AdoptCursor(double x,double y);
    // 精细鼠标面板只移动菜单指针，不认领真实屏幕触点，也不产生按键或游戏视角。
    bool MoveCursor(double dx,double dy,const MenuTouchEmitter& emit);
    int64_t Deadline() const { return deadline_; }
    double X() const { return cursorX_; }
    double Y() const { return cursorY_; }
    bool Active() const { return primary_ >= 0; }
    // 直接绝对手势时ACK不得移动冻结指针；relative模式的反馈缓存可以承接已消费point而不改变采样delta。
    bool DirectActive() const { return Active() && !config_.touchpad; }
    void AdoptConsumedCursor(double x,double y);
private:
    struct Pointer { bool down = false; double x = 0, y = 0; };
    std::array<Pointer, 10> pointers_{};
    TouchInteractionConfig config_{};
    double width_ = 0, height_ = 0, density_ = 1;
    double cursorX_ = 0, cursorY_ = 0, startX_ = 0, startY_ = 0;
    double scrollX_ = 0, scrollY_ = 0;
    int primary_ = -1, secondary_ = -1;
    int64_t startNs_ = 0, deadline_ = 0;
    bool candidate_ = false, dragging_ = false, scrolling_ = false, suppressed_ = false;
    bool gesture_ = false; // first DOWN即有pointer事务，candidate/scroll/CANCEL同样拥有可撤销身份。
    // 首指建立、真实拖动或外部按钮持有时退休；不使用固定落指时间窗推断用户意图。
    bool scrollEligible_ = false;
    bool externalButtons_ = false;
    bool AnyDown() const;
    void StartDrag(const MenuTouchEmitter& emit);
    void Position(double x, double y, const MenuTouchEmitter& emit);
};

/** 摇杆中心只在 Begin 建立，移动不改 schema 几何；真实Up和Cancel都归零，不保留松手移动。 */
class TouchJoystickInteraction final {
public:
    void Begin(double x, double y, double left, double top, double width, double height,
               const TouchInteractionConfig& config, double deadZone);
    void Move(double x, double y);
    void End(bool cancelled);
    void Reset();
    double X() const { return x_; }
    double Y() const { return y_; }
    double CenterX() const { return centerX_; }
    double CenterY() const { return centerY_; }
    bool Sprint() const { return sprint_; }
    bool Armed() const { return armed_; }
    bool Locked() const { return locked_; }
private:
    TouchInteractionConfig config_{};
    double centerX_ = 0, centerY_ = 0, radius_ = 1, deadZone_ = .18, x_ = 0, y_ = 0;
    bool sprint_ = false, armed_ = false, locked_ = false;
};
}
#endif
