import { AmclInputSource } from './InputSourceRegistry'

/** 原生复位域的只读快照。代次保持十进制字符串，不用 number 比较大小或承担64位精度。 */
export class InputResetSnapshot {
  epoch: string = ''
  touch: string = ''
  gamepad: string = ''
  physical: string = ''
  text: string = ''
}

export function parseInputResetSnapshot(encoded: string): InputResetSnapshot | undefined {
  const fields: string[] = encoded.split(':')
  if (fields.length !== 6 || fields[0] !== 'IRS1') return undefined
  for (let i: number = 1; i < fields.length; i++) {
    if (!/^[0-9]{1,20}$/.test(fields[i])) return undefined
  }
  const snapshot: InputResetSnapshot = new InputResetSnapshot()
  snapshot.epoch = fields[1]; snapshot.touch = fields[2]; snapshot.gamepad = fields[3]
  snapshot.physical = fields[4]; snapshot.text = fields[5]
  return snapshot
}

export interface InputSessionResetPort {
  resetSource: (source: AmclInputSource, reason: string) => boolean
  resetText: () => boolean
}

/** 会话对账不依赖虚拟控件是否挂载。每域保存已确认代次；一个端失败不阻止其它端恢复，
 * 失败域留待下一次事件/心跳重试。不同域在两次观测之间连续复位，也不会被最后一个mask覆盖。
 */
export class InputSessionCoordinator {
  private port: InputSessionResetPort
  private applied: InputResetSnapshot | undefined = undefined
  private reconciling: boolean = false
  constructor(port: InputSessionResetPort) { this.port = port }

  reconcile(encoded: string): boolean {
    const desired: InputResetSnapshot | undefined = parseInputResetSnapshot(encoded)
    if (desired === undefined || this.reconciling) return false
    const applied: InputResetSnapshot | undefined = this.applied
    if (applied === undefined) { this.applied = desired; return true }
    this.reconciling = true
    try {
      applied.touch = this.reconcileSource(AmclInputSource.TouchControls, desired.touch, applied.touch)
      applied.gamepad = this.reconcileSource(AmclInputSource.Gamepad, desired.gamepad, applied.gamepad)
      applied.physical = this.reconcileSource(AmclInputSource.PhysicalKbm, desired.physical, applied.physical)
      if (desired.text !== applied.text) {
        try { if (this.port.resetText()) applied.text = desired.text } catch (_) {}
      }
      const complete: boolean = applied.touch === desired.touch && applied.gamepad === desired.gamepad &&
        applied.physical === desired.physical && applied.text === desired.text
      if (complete) applied.epoch = desired.epoch
      return complete
    } finally { this.reconciling = false }
  }

  private reconcileSource(source: AmclInputSource, desired: string, applied: string): string {
    if (desired === applied) return applied
    try { return this.port.resetSource(source, 'native-domain-reset') ? desired : applied }
    catch (_) { return applied }
  }
}
