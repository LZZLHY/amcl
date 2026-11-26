import { AmclInputSource, InputEnd } from './InputSourceRegistry'

/** 接收已有输入注册表的生命周期通知。页面显隐与 Ability 前后台分别记录；
 * 设备状态由 Native 采集，本对象仅将会话焦点和复位同步给宿主。 */
export class GameInputRuntime implements InputEnd {
  readonly inputSource: AmclInputSource = AmclInputSource.Gamepad
  readonly endName: string = 'GameInputRuntime'
  private pageSuspended: boolean = false
  private abilitySuspended: boolean = false
  private onReset: () => void
  private onLifecycleChange: () => void

  constructor(onReset: () => void, onLifecycleChange: () => void) {
    this.onReset = onReset
    this.onLifecycleChange = onLifecycleChange
  }

  isLifecycleActive(): boolean { return !this.pageSuspended && !this.abilitySuspended }
  resumeAfterLifecycle(): void { this.pageSuspended = false }

  onAbilityForeground(): void {
    if (!this.abilitySuspended) return
    this.abilitySuspended = false
    this.onLifecycleChange()
  }

  releaseAllInputs(reason: string): void {
    if (reason.endsWith('-background')) this.abilitySuspended = true
    else if (reason === 'page-hide' || reason === 'page-dispose' || reason.endsWith('-destroy')) this.pageSuspended = true
    else return
    this.onLifecycleChange()
  }

  dropHeldStateAfterNativeReset(_reason: string): void { this.onReset() }
}
