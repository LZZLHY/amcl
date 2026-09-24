/**
 * HapticUtil.ets — 触觉反馈封装（R6 落地）
 *
 * 用 @ohos.vibrator 实现虚拟按键的短促振动。第三方应用可用，需要在 module.json5
 * 声明 ohos.permission.VIBRATE（system_grant，无需用户弹窗）。
 *
 * 设计：
 *   - startVibration 是 Promise，按键路径不 await（fire-and-forget），避免阻塞触摸主线程。
 *   - 失败（设备无振动马达 / 权限缺失 / 高频触发被限流）只打一次 warn，不影响游戏。
 *   - 调用方根据 LayoutProfile.haptic 决定是否调用本函数。
 */

import { hilog } from '@kit.PerformanceAnalysisKit'
import vibrator from '@ohos.vibrator'

const TAG = 'Haptic'

let s_warned: boolean = false
// 振动不可用时短路，避免每次按键都进 try/catch + 触发 SDK 调用
let s_disabled: boolean = false

/**
 * 短促按键反馈。durationMs 默认 8ms。
 * 调用方应自行根据 LayoutProfile.haptic 判断是否调用本函数。
 */
export function hapticTap(durationMs: number = 8): void {
  if (s_disabled) return
  try {
    // fire-and-forget：不 await，避免阻塞 onTouch / NAPI 派发
    vibrator.startVibration(
      { type: 'time', duration: durationMs },
      { usage: 'touch' }
    ).catch((err: Object) => {
      handleFailure(err)
    })
  } catch (err) {
    handleFailure(err as Object)
  }
}

function handleFailure(err: Object): void {
  if (!s_warned) {
    s_warned = true
    hilog.warn(0x0000, TAG, 'hapticTap failed, disabling haptics: %{public}s', JSON.stringify(err))
  }
  // 首次失败即关闭后续调用（设备不支持 / 无权限是稳定状态，不会自己恢复）
  s_disabled = true
}
