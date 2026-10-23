/** Native反馈注册的页面租约；每次注册生成独立闭包，旧TSFN排空不会投递给新页面。 */
import testNapi, { TouchFeedbackIdentity, TouchPublicationReceipt } from 'libentry.so'

export class EntryControlFeedbackLease {
  id: number = 0
}

class EntryControlFeedbackClient {
  id: number = 0
  onButton: (controlId: string, pressed: boolean) => void =
    (_controlId: string, _pressed: boolean): void => {}
  onHaptic: (strength: number) => void = (_strength: number): void => {}
  /** 回调固定指向创建它的client；active检查只决定拒绝，绝不转发到最新client。 */
  buttonCallback: (controlId: string, pressed: boolean) => void =
    (_controlId: string, _pressed: boolean): void => {}
  hapticCallback: (strength: number, identity: TouchFeedbackIdentity) => void =
    (_strength: number, _identity: TouchFeedbackIdentity): void => {}
  registration: string = ''
  acceptsControl: (id: string) => boolean = (_id: string): boolean => true
}

let nextFeedbackLeaseId: number = 1
let activeFeedbackClient: EntryControlFeedbackClient | undefined = undefined

/** 最新页面取得两个反馈槽；失败尝试只恢复旧页面的闭包，销毁只归还自己的lease。 */
export function acquireEntryControlFeedback(
  onButton: (controlId: string, pressed: boolean) => void,
  onHaptic: (strength: number) => void,
  acceptsControl: (id: string) => boolean = (_id: string): boolean => true
): EntryControlFeedbackLease | undefined {
  const previous: EntryControlFeedbackClient | undefined = activeFeedbackClient
  // 达到安全整数上限后拒绝新租约，不能复用身份令旧页面释放新的注册。
  if (nextFeedbackLeaseId >= 9007199254740991) return undefined
  const client = new EntryControlFeedbackClient()
  client.id = nextFeedbackLeaseId
  if (nextFeedbackLeaseId < 9007199254740991) nextFeedbackLeaseId++
  client.onButton = onButton
  client.onHaptic = onHaptic
  client.acceptsControl = acceptsControl
  client.buttonCallback = (controlId: string, pressed: boolean): void => {
    if (activeFeedbackClient === client) client.onButton(controlId, pressed)
  }
  client.hapticCallback = (strength: number, identity: TouchFeedbackIdentity): void => {
    if (activeFeedbackClient !== client || identity === undefined || identity.version !== 1 ||
      typeof identity.registration !== 'string' || identity.registration.length === 0 ||
      typeof identity.grabEpoch !== 'string' || identity.grabEpoch.length === 0 ||
      typeof identity.generatedNs !== 'string' || identity.generatedNs.length === 0) return
    if (!client.acceptsControl(identity.controlId)) return
    if (client.registration.length === 0) client.registration = identity.registration
    if (identity.registration !== client.registration) return
    try {
      const current: TouchPublicationReceipt = testNapi.touchPublicationState()
      // 只比较精确字符串，不把Native uint64代次转成可能丢精度的number。
      if (current.version !== 1 || current.fenced || current.modalCount !== 0 ||
        current.schemaGeneration !== identity.schemaGeneration || current.session !== identity.session || current.grabEpoch !== identity.grabEpoch) return
    } catch (_) { return }
    client.onHaptic(strength)
  }
  try {
    const buttonReady: boolean = testNapi.onButtonPressed(client.buttonCallback)
    const hapticReady: boolean = testNapi.onHaptic(client.hapticCallback)
    if (!buttonReady || !hapticReady) throw new Error('native feedback registration rejected')
  } catch (_) {
    let restored: boolean = true
    try {
      if (!testNapi.onButtonPressed(previous?.buttonCallback)) restored = false
    } catch (_) { restored = false }
    try {
      if (!testNapi.onHaptic(previous?.hapticCallback)) restored = false
    } catch (_) { restored = false }
    activeFeedbackClient = restored ? previous : undefined
    if (restored && previous !== undefined) previous.registration = ''
    return undefined
  }
  activeFeedbackClient = client
  const lease = new EntryControlFeedbackLease()
  lease.id = client.id
  return lease
}

export function releaseEntryControlFeedback(lease: EntryControlFeedbackLease): boolean {
  const active: EntryControlFeedbackClient | undefined = activeFeedbackClient
  if (active === undefined || lease.id === 0 || active.id !== lease.id) return false
  activeFeedbackClient = undefined
  let cleared: boolean = true
  try { if (!testNapi.onButtonPressed()) cleared = false } catch (_) { cleared = false }
  try { if (!testNapi.onHaptic()) cleared = false } catch (_) { cleared = false }
  return cleared
}
