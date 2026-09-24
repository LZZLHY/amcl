import { describe, it, expect } from '@ohos/hypium'
import { GameLaunchGate } from '../main/ets/runtime/GameLaunchGate'

class DeferredPreparation {
  promise: Promise<void>
  ready: () => void = (): void => {}
  fail: (error: Error) => void = (_error: Error): void => {}
  constructor() {
    this.promise = new Promise<void>((resolve, reject) => {
      this.ready = (): void => { resolve() }
      this.fail = (error: Error): void => { reject(error) }
    })
  }
}

export default function gameLaunchGateTest(): void {
  describe('GameLaunchGate', () => {
    it('重复 surface load 共用启动准备，窗口就绪后只启动一次', 0, async () => {
      const gate: GameLaunchGate = new GameLaunchGate()
      const window: DeferredPreparation = new DeferredPreparation()
      let preparations: number = 0
      let nativeLaunches: number = 0
      const operation = async (): Promise<void> => {
        preparations++
        await window.promise
        nativeLaunches++
      }
      const first: Promise<void> = gate.run(operation)
      const second: Promise<void> = gate.run(operation)
      expect(first === second).assertTrue()
      await Promise.resolve()
      expect(preparations).assertEqual(1)
      expect(nativeLaunches).assertEqual(0)
      window.ready()
      await first
      expect(nativeLaunches).assertEqual(1)
      await gate.run(operation)
      expect(preparations).assertEqual(1)
    })
    it('窗口准备失败不得越过 await 启动 JVM，也不被重复 load 重试', 0, async () => {
      const gate: GameLaunchGate = new GameLaunchGate()
      const window: DeferredPreparation = new DeferredPreparation()
      let nativeLaunches: number = 0
      const result: Promise<void> = gate.run(async (): Promise<void> => {
        await window.promise
        nativeLaunches++
      })
      window.fail(new Error('window unavailable'))
      let rejected: boolean = false
      try { await result } catch (_) { rejected = true }
      expect(rejected).assertTrue()
      expect(nativeLaunches).assertEqual(0)
      try { await gate.run(async (): Promise<void> => { nativeLaunches++ }) } catch (_) {}
      expect(nativeLaunches).assertEqual(0)
    })
    it('同步抛出与重入同样不能创建第二次启动', 0, async () => {
      const gate: GameLaunchGate = new GameLaunchGate()
      let calls: number = 0
      let first: Promise<void> = Promise.resolve()
      let reused: boolean = false
      first = gate.run((): Promise<void> => {
        calls++
        const nested: Promise<void> = gate.run(async (): Promise<void> => { calls++ })
        reused = nested === first
        throw new Error('preparation failed')
      })
      try { await first } catch (_) {}
      expect(reused).assertTrue()
      expect(calls).assertEqual(1)
    })
  })
}
