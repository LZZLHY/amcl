/**
 * 平台IME回调的原始attach资格。OS已经排队的回调可能晚于off/detach返回，不能在执行时
 * 借用组件当前文本租约。本对象只做身份判断与退休，不拥有controller或产生文本命令。
 */
import { TextInputSessionLease } from './TextInputSessionCoordinator'

export class ImeCallbackLease {
  private readonly originalLease: TextInputSessionLease
  private readonly originalOwner: string
  private readonly originalGeneration: number
  private readonly role: string
  private retired: boolean = false

  /** 冻结实际tryBegin返回的原对象与数值；不按同名owner猜测另一次attach仍是原会话。 */
  constructor(lease: TextInputSessionLease, role: string) {
    this.originalLease = lease
    this.originalOwner = lease.owner
    this.originalGeneration = lease.generation
    this.role = role
  }

  /**
   * 只在原attach实例、原租约对象和原角色全部仍有效时接受。额外比较冻结数值，避免外部
   * 修改同一可写lease对象后绕过围栏。Native RESET可在同UI lease中重建host号，不由这里
   * 伪造新Native会话；真正文本提交仍须经过既有Coordinator和Native资格检查。
   */
  accepts(current: ImeCallbackLease | undefined, lease: TextInputSessionLease | undefined,
    role: string): boolean {
    return !this.retired && current === this && lease !== undefined && lease === this.originalLease &&
      lease.owner === this.originalOwner && lease.generation === this.originalGeneration &&
      role === this.role
  }

  /** off/detach或失败开始时立即退休；重复调用幂等，不等待平台Promise或新组件确认。 */
  retire(): void { this.retired = true }
}
