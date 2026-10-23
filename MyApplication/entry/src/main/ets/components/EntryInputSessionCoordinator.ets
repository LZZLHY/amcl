import testNapi from 'libentry.so'
import { AppLogger } from 'commons'
import { AmclInputSource, getInputSourceRegistry, InputSessionCoordinator } from 'gamecontrol'
import { reconcileEntryTextInputSession } from './EntryTextInputSession'

// 进程内的会话对账所有者独立于 GameControls。页面心跳、按键入口和mapped视角时钟
// 只是调用者；任一UI组件不挂载，都不影响原生复位事实的消费。
const coordinator: InputSessionCoordinator = new InputSessionCoordinator({
  resetSource: (source: AmclInputSource, reason: string): boolean => {
    return getInputSourceRegistry().dropSourceStateAfterNativeReset(source, reason)
  },
  resetText: (): boolean => { return reconcileEntryTextInputSession() }
})
let failures: number = 0

export function reconcileEntryInputSession(): void {
  let detail: string = 'pending domain acknowledgements'
  try {
    if (coordinator.reconcile(testNapi.getInputResetDomains())) { failures = 0; return }
  } catch (error) { detail = (error as Error).message }
  failures++
  if (failures === 1 || (failures & (failures - 1)) === 0) {
    AppLogger.warn('InputSession', `native reset domain reconciliation pending failures=${failures} reason=${detail}`)
  }
}
