#ifndef AMCL_PLATFORM_INPUT_CHANNEL_POLICY_H
#define AMCL_PLATFORM_INPUT_CHANNEL_POLICY_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 同一个物理输入端内的通道仲裁，不仲裁触控/手柄/键鼠三个并列输入端。
 *
 * 鼠标全部按钮按已观测通道的固定优先级选择：ArkUI > Native > TouchMirror。
 * 能力按按钮记录；持有按(deviceId,nativeButton,DOWN channel)记录，不用静默时长
 * 猜测owner死亡。单通道多个已知设备可以同时持有同键；其它通道不得抢走在途DOWN。
 * Native与Mirror缺少设备身份时保留0桶，不编造与ArkUI设备的映射。
 *
 * 滚轮保持 NativeAxis > ArktsAxis > AxisPan > TouchWheel 的单通道策略。
 * 全局surface gate将策略准入与typed/legacy投递包成事务；模块自己的mutex只保护
 * 配对表，在设备释放回调之前已解锁，禁止形成policy→ingress的反向锁链。
 */

/** 数值同时进入ArkTS/NAPI ABI；不得因重排优先级而修改这些值。 */
typedef enum {
    AMCL_INPUT_CHANNEL_NONE = 0,
    AMCL_INPUT_CHANNEL_ARKUI_MOUSE = 1,
    AMCL_INPUT_CHANNEL_NATIVE_MOUSE = 2,
    AMCL_INPUT_CHANNEL_TOUCH_MIRROR = 3,
    AMCL_INPUT_CHANNEL_NATIVE_AXIS = 4,
    AMCL_INPUT_CHANNEL_ARKTS_AXIS = 5,
    AMCL_INPUT_CHANNEL_AXIS_PAN = 6,
    AMCL_INPUT_CHANNEL_TOUCH_WHEEL = 7,
} AmclInputChannel;

/** 左键兼容诊断入口；新生产者直接调用button_begin即可完成能力登记。 */
void amcl_input_policy_note_left_channel(AmclInputChannel channel);
/** 滚轮必须先登记真实样本，再询问wheel_accepts，注册成功不等于样本已存在。 */
void amcl_input_policy_note_wheel_channel(AmclInputChannel channel);
AmclInputChannel amcl_input_policy_wheel_owner(void);
bool amcl_input_policy_wheel_accepts(AmclInputChannel channel);

/**
 * nativeButton为平台位值1/2/4/8/16；组合位和未来未知位拒绝。DOWN成功只代表取得
 * 下游提交的预留；提交失败必须abort。UP仅接受原设备、原按钮、原channel，不重新
 * 选择优先级。没有DOWN的UP不得清别的设备或未知桶。
 */
bool amcl_input_policy_button_begin(AmclInputChannel channel,
    uint64_t deviceId, uint32_t nativeButton);
bool amcl_input_policy_button_end(AmclInputChannel channel,
    uint64_t deviceId, uint32_t nativeButton);
void amcl_input_policy_button_abort(AmclInputChannel channel,
    uint64_t deviceId, uint32_t nativeButton);

/**
 * 拔除先摘指定device配对，再在策略锁外回调原始DOWN身份。includeUnknown用于已知
 * 指针移除或明确保守降级，只附加释放0桶，不触碰任何其它已知device。调用方必须
 * 完成typed/legacy UP；不能把这个接口替换成全局reset或按整个PhysicalKbm端释放。
 */
typedef void (*AmclPhysicalButtonReleaseFn)(uint64_t deviceId,
    uint32_t nativeButton, void* context);
void amcl_input_policy_release_pointer_device(uint64_t deviceId,
    bool includeUnknown, AmclPhysicalButtonReleaseFn release, void* context);

/**
 * 老的未知身份左键接口仅保留兼容和已有host断言，等价device=0/button=1。它们要求
 * 调用方先note；带deviceId的生产事件禁止走这两条，否则又会合并两个真实设备。
 */
bool amcl_input_policy_left_begin(AmclInputChannel channel);
bool amcl_input_policy_left_end(AmclInputChannel channel);
/** 任一设备左键尚未配对UP时为true；仅诊断，不能据此选择或释放具体owner。 */
bool amcl_input_policy_left_held(void);
/** 当前左键能力优先级快照，不代表某个在途DOWN的实际持有通道。 */
AmclInputChannel amcl_input_policy_left_owner(void);
/** 完整生命周期取消后清全部按钮配对，保留各按钮的已观测通道能力。 */
void amcl_input_policy_reset_pairing(void);
/** 只读诊断，不参与准入，不生成输入。 */
void amcl_input_policy_log_state(void);

#ifdef __cplusplus
}
#endif
#endif
