import testNapi from 'libentry.so'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { hasEntryTouchModal } from './EntryTouchModalBroker'
import {
  GLFW_PRESS,
  GLFW_RELEASE,
  TextInputKeyTapResult,
  TextInputSessionCoordinator,
  TextInputSessionLease,
  TextInputSessionSink,
  isPrintableUnicodeCodepoint,
  textInputKeyTapResultFromNative,
  parseInputResetSnapshot
} from 'gamecontrol'

const TAG: string = 'EntryTextSession'
/** textInputKeyTap调用未知计数饱和于MAX_SAFE_INTEGER；饱和后永久拒绝以此计数授权reset重试。 */
let keyTapUnavailableCount: number = 0
/** 提交未知计数同样饱和并永久拒绝reset重试，不以同值/新epoch猜原命令未交付。 */
let commitOutcomeUncertainCount: number = 0
/** legacy ring 回退按键对调用抛错的累计次数，按 2 的幂节流告警。 */
let legacyKeyTapFailureCount: number = 0

/** 诊断节流：第 1、2、4、8… 次返回 true。 */
function isPowerOfTwoCount(count: number): boolean {
  return count > 0 && (count & (count - 1)) === 0
}

/** Process-wide typed text sink. No accepted session writes legacy char events. */
class EntryTextInputSessionSink implements TextInputSessionSink {
  begin(_owner: string, generation: number): boolean {
    try {
      if (!testNapi.textInputSessionSupported() ||
          !testNapi.beginTextInputSession(generation)) return false
      // Do not count candidate degradation at BEGIN time. InputMethodController
      // may not expose a candidate-list callback, but a session that never
      // receives candidate data has not exercised that unsupported path. The
      // metric is recorded only by candidates(), where the capability gap is
      // observed explicitly.
      return true
    } catch (_) {
      return false
    }
  }

  end(_owner: string, generation: number, _reason: string): boolean {
    try {
      return testNapi.endTextInputSession(generation)
    } catch (_) {
      return false
    }
  }

  abort(_owner: string, generation: number, _reason: string): void {
    try {
      testNapi.abortTextInputSession(generation)
    } catch (_) {
      hilog.warn(0x0000, TAG,
        'native text-session abort failed generation=%{public}d', generation)
    }
  }

  /** 可打印scalar验证失败是明确未调用；Native调用后异常只报未知并围栏本命令的reset重试。 */
  commit(_owner: string, generation: number, text: string): boolean {
    const scalars: number[] = EntryTextInputSessionSink.toCodePoints(text)
    for (let i: number = 0; i < scalars.length; i++) {
      if (!isPrintableUnicodeCodepoint(scalars[i])) return false
    }
    try {
      return testNapi.commitTextInput(generation, text)
    } catch (_) {
      if (commitOutcomeUncertainCount < Number.MAX_SAFE_INTEGER) commitOutcomeUncertainCount++
      if (isPowerOfTwoCount(commitOutcomeUncertainCount)) {
        hilog.warn(0x0000, TAG, '文本提交结果不确定，禁止同命令重试 count=%{public}d', commitOutcomeUncertainCount)
      }
      return false
    }
  }

  /**
   * 入口实取缺席时尚未调用Native，可明确NotTypedRoute保兼容；显式Native返回1也保原合同。
   * 调用已发生后异常无法证明未交付，必须Rejected停止，不另发legacy产生重复副作用。
   */
  keyTap(_owner: string, generation: number, ohosKeyCode: number,
    glfwKey: number): TextInputKeyTapResult {
    try {
      if (typeof testNapi.textInputKeyTap !== 'function') return TextInputKeyTapResult.NotTypedRoute
      return textInputKeyTapResultFromNative(
        testNapi.textInputKeyTap(generation, ohosKeyCode, glfwKey))
    } catch (e) {
      if (keyTapUnavailableCount < Number.MAX_SAFE_INTEGER) keyTapUnavailableCount++
      if (isPowerOfTwoCount(keyTapUnavailableCount)) {
        hilog.warn(0x0000, TAG,
          'textInputKeyTap outcome uncertain, refusing alternate key taps count=%{public}d err=%{public}s',
          keyTapUnavailableCount, String(e))
      }
      return TextInputKeyTapResult.Rejected
    }
  }

  editing(
    _owner: string,
    generation: number,
    text: string,
    selectionStart: number,
    selectionLength: number
  ): boolean {
    try {
      return testNapi.updateTextInputEditing(
        generation, text, selectionStart, selectionLength)
    } catch (_) {
      return false
    }
  }

  selection(
    _owner: string,
    generation: number,
    selectionStart: number,
    selectionLength: number
  ): boolean {
    try {
      return testNapi.updateTextInputSelection(
        generation, selectionStart, selectionLength)
    } catch (_) {
      return false
    }
  }

  candidates(
    _owner: string,
    _generation: number,
    _items: string[],
    _selected: number,
    _pageStart: number,
    _pageSize: number
  ): boolean {
    // InputMethodController exposes no candidate-list producer. If a future
    // caller reaches this seam, record the degradation and never fabricate it.
    try {
      testNapi.noteTextInputCandidatesUnsupported()
    } catch (_) {
      hilog.warn(0x0000, TAG,
        'candidate unsupported counter unavailable generation=%{public}d', _generation)
    }
    return false
  }

  private static toCodePoints(text: string): number[] {
    const output: number[] = []
    let index: number = 0
    while (index < text.length) {
      const codepoint: number = text.codePointAt(index) ?? 0
      output.push(codepoint)
      index += codepoint > 65535 ? 2 : 1
    }
    return output
  }
}

const entryTextSession = new TextInputSessionCoordinator(
  new EntryTextInputSessionSink())
const availabilityListeners: Set<() => void> = new Set<() => void>()
/** 软键盘请求优先于自动硬键盘客户端；等待前一个controller真正detach后才转交lease。 */
const softRequests: Set<string> = new Set<string>()
let nativeResetEpoch: string = ''
/** 旧宿主或瞬时NAPI故障只报告一次；成功恢复读取后允许报告下一次独立故障。 */
let nativeEpochReadFailed: boolean = false
/**
 * native reset epoch 已变化、但还没通知可用性订阅者。命令入口里的对账只置位不通知
 * （它们可能正处在某个 IME 回调栈里，同步通知会重入组件）；页面心跳那次对账负责送达，
 * 让重试预算已耗尽的客户端重新武装一轮 attach，不需要额外定时器。
 */
let sessionRearmPending: boolean = false

export function setEntrySoftTextInputRequested(owner: string, requested: boolean): void {
  if (requested === softRequests.has(owner)) return
  if (requested) softRequests.add(owner)
  else softRequests.delete(owner)
  notifyTextSessionAvailability()
}

/** 回调可以同步退订；遍历快照并隔离异常，不能让一个失效UI阻断controller交接。 */
function notifyTextSessionAvailability(): void {
  const snapshot: (() => void)[] = []
  availabilityListeners.forEach((listener: () => void): void => { snapshot.push(listener) })
  for (let i = 0; i < snapshot.length; i++) {
    try { snapshot[i]() }
    catch (_) { hilog.warn(0x0000, TAG, '文本会话订阅者更新失败') }
  }
}

export function isEntrySoftTextInputRequested(): boolean { return softRequests.size > 0 }

/**
 * 页面runtime和每条文本命令共用同一个epoch对账，失效只清宿主号，不撤销UI attach。
 *
 * deliverRearm=true（默认，页面心跳与 runtime 钩子的调用形式）时，把积攒的“epoch 已变化”
 * 同步通知给可用性订阅者：宿主 reset 可能正是此前 BEGIN 被拒的原因（例如恢复后 surface
 * 绑定恢复、孤儿会话被清），客户端据此重新给自己一轮有界重试。命令入口传 false，只记账。
 */
export function reconcileEntryTextInputSession(deliverRearm: boolean = true): boolean {
  try {
    // 新宿主只在文本权威变化时重建会话；触控/手柄队列恢复不应撤销正在编辑的文本。
    // 旧宿主缺少域快照时仍使用原有单epoch兼容合同，不对存在但坏格式的扩展猜测。
    let epoch: string = ''
    if (typeof testNapi.getInputResetDomains === 'function') {
      const snapshot = parseInputResetSnapshot(testNapi.getInputResetDomains())
      if (snapshot === undefined) throw new Error('Invalid native input reset snapshot')
      epoch = snapshot.text
    } else { epoch = testNapi.getInputResetEpoch() }
    nativeEpochReadFailed = false
    if (epoch.length > 0 && epoch !== nativeResetEpoch) {
      const hadBaseline: boolean = nativeResetEpoch.length > 0
      nativeResetEpoch = epoch
      if (hadBaseline) {
        entryTextSession.invalidateHostSession()
        sessionRearmPending = true
      }
    }
  } catch (_) {
    if (!nativeEpochReadFailed) {
      nativeEpochReadFailed = true
      hilog.warn(0x0000, TAG, 'Native文本epoch读取失败，等待显式会话边界恢复')
    }
    return false
  }
  if (deliverRearm && sessionRearmPending) {
    sessionRearmPending = false
    notifyTextSessionAvailability()
  }
  return true
}

export function getEntryTextInputSession(): TextInputSessionCoordinator {
  reconcileEntryTextInputSession(false)
  return entryTextSession
}

/** 确切false且失败期间新RESET才重试一次；成功或已调用后异常都不因epoch变化重复发送。 */
export function commitEntryTextInput(lease: TextInputSessionLease, text: string): boolean {
  reconcileEntryTextInputSession(false)
  const before: string = nativeResetEpoch
  const uncertainBefore: number = commitOutcomeUncertainCount
  if (entryTextSession.commit(lease, text)) return true
  if (commitOutcomeUncertainCount >= Number.MAX_SAFE_INTEGER || uncertainBefore !== commitOutcomeUncertainCount) return false
  reconcileEntryTextInputSession(false)
  return before !== nativeResetEpoch && entryTextSession.commit(lease, text)
}

/**
 * 文本会话内的有序编辑键（I27-09），与 commitEntryTextInput 同一套 epoch 对账：
 * 只有被拒、且失败期间确实出现新的 native reset 时才重试一次——那说明宿主会话刚被
 * 作废，重试会先重建会话再发键；门禁、失焦、键不合法等普通拒绝不重试。
 * 已调用后抛错是结果不确定，不受换代重试授权；否则旧动作可能已接受而再次发送。
 * Submitted/NotTypedRoute 原样返回，调用方在 NotTypedRoute 时自行回退 ring。
 */
export function tapEntryTextInputKey(lease: TextInputSessionLease, ohosKeyCode: number,
  glfwKey: number): TextInputKeyTapResult {
  reconcileEntryTextInputSession(false)
  const before: string = nativeResetEpoch
  const uncertainBefore: number = keyTapUnavailableCount
  const first: TextInputKeyTapResult = entryTextSession.keyTap(lease, ohosKeyCode, glfwKey)
  if (first !== TextInputKeyTapResult.Rejected || keyTapUnavailableCount >= Number.MAX_SAFE_INTEGER ||
      uncertainBefore !== keyTapUnavailableCount) return first
  reconcileEntryTextInputSession(false)
  if (before === nativeResetEpoch) return first
  return entryTextSession.keyTap(lease, ohosKeyCode, glfwKey)
}

/**
 * 编辑键的 legacy ring 回退：以调用方的端身份紧邻发出 PRESS 与 RELEASE，持有记录不跨帧。
 * 只在有序入口回答 NotTypedRoute、或调用方根本没有文本租约时使用。ring 记录没有 core
 * 序号，这条路径不保证与提交文本的相对顺序（legacy 路由的既有限制，见 I27-09）。
 * 返回 false 只表示 NAPI 调用本身抛错（已节流告警）；ring 侧是否改变持有记录不影响轻击。
 */
export function sendLegacyEntryKeyTap(source: number, glfwKey: number): boolean {
  // 模态内只允许Native已核验的owned text session入口；无lease或NotTypedRoute不能改走普通输入落底。
  // 当前Native textInputKeyTap会在合法会话的legacy路由内完成tap并返回Submitted。
  if (hasEntryTouchModal()) return false
  try {
    testNapi.sendSourceKeyEvent(source, glfwKey, 0, GLFW_PRESS, 0)
    testNapi.sendSourceKeyEvent(source, glfwKey, 0, GLFW_RELEASE, 0)
    return true
  } catch (e) {
    legacyKeyTapFailureCount++
    if (isPowerOfTwoCount(legacyKeyTapFailureCount)) {
      hilog.warn(0x0000, TAG, 'legacy key tap failed key=%{public}d count=%{public}d err=%{public}s',
        glfwKey, legacyKeyTapFailureCount, String(e))
    }
    return false
  }
}

export function endEntryTextInputSession(
  lease: TextInputSessionLease,
  reason: string
): boolean {
  let ended: boolean = entryTextSession.end(lease, reason)
  if (!ended) ended = entryTextSession.abort(lease, `abort-after-${reason}`)
  if (ended) {
    // Never notify synchronously from an attach/detach failure stack. A listener
    // may immediately try to acquire and fail again; synchronous recursion would
    // turn one platform error into a stack overflow.
    setTimeout((): void => {
      notifyTextSessionAvailability()
    }, 0)
  }
  return ended
}

export function addEntryTextSessionAvailabilityListener(listener: () => void): void {
  availabilityListeners.add(listener)
}

export function removeEntryTextSessionAvailabilityListener(listener: () => void): void {
  availabilityListeners.delete(listener)
}
