/**
 * entry的具名触控模态租约。Native按集合控制触控准入；每个页面/覆盖层只释放自己的token，
 * 未确认释放保留pending，由现有活跃页面心跳重试，不通过全域cancel伪造关闭成功。
 */
import testNapi from 'libentry.so'

export class EntryTouchModalLease {
  readonly owner: string
  readonly token: string
  closing: boolean = false
  constructor(owner: string, token: string) { this.owner = owner; this.token = token }
}

const modalLeases: Map<string, EntryTouchModalLease> = new Map<string, EntryTouchModalLease>()

/** 失败不给UI一个假租约；模态入口应保持原状态并显示原因。 */
export function acquireEntryTouchModal(owner: string): EntryTouchModalLease | undefined {
  try {
    const token: string = testNapi.acquireTouchModal(owner)
    if (token.length === 0) return undefined
    const lease = new EntryTouchModalLease(owner, token)
    modalLeases.set(token, lease)
    return lease
  } catch (_) { return undefined }
}

/** Native确认后才删除；迟到旧token不会释放新lease，关闭不补发任何已退休用户输入。 */
export function releaseEntryTouchModal(lease: EntryTouchModalLease): boolean {
  if (modalLeases.get(lease.token) !== lease) return true
  lease.closing = true
  try {
    if (!testNapi.releaseTouchModal(lease.token)) return false
    modalLeases.delete(lease.token)
    return true
  } catch (_) { return false }
}

/** 只重试明确已请求关闭的token；不因别人关闭或后台事件释放仍合法的嵌套模态。 */
export function reconcileEntryTouchModals(): void {
  const pending: EntryTouchModalLease[] = []
  modalLeases.forEach((lease: EntryTouchModalLease): void => { if (lease.closing) pending.push(lease) })
  for (const lease of pending) releaseEntryTouchModal(lease)
}

export function hasEntryTouchModal(): boolean { return modalLeases.size > 0 }
