/**
 * formal desktop的无视觉IME资源入口。它只声明原UIContext与active意图；运行体统一
 * soft/hard优先、controller串行交接、租约回调围栏和重试，不制造Headless IME能力。
 */
import { getGameSessionHost } from '../runtime/GameSessionHost'
import { EntryTextInputRuntime, EntryTextInputBinding } from '../runtime/EntryTextInputRuntime'

@Component
export struct DesktopPhysicalTextInput {
  @Prop @Watch('onActiveChanged') active: boolean = false
  private mounted: boolean = false
  private runtime: EntryTextInputRuntime | undefined = undefined
  private binding: EntryTextInputBinding | undefined = undefined

  /** 必须来自真实组件UIContext，prepare前声明请求只Pending而无OS attach。 */
  aboutToAppear(): void {
    this.mounted = true; this.runtime = getGameSessionHost().textInputRuntime
    this.binding = this.runtime.bind('physical', { uiContext: this.getUIContext(), onClose: (): void => {} })
    this.onActiveChanged()
  }

  /** 撤销原资源，不以退观察冒充controller已detach，不关闭稳定会话维护。 */
  aboutToDisappear(): void {
    this.mounted = false
    const binding = this.binding; this.binding = undefined
    if (binding !== undefined) this.runtime?.unbind(binding)
  }
  private onActiveChanged(): void {
    const binding = this.binding
    if (binding !== undefined) this.runtime?.request(binding, this.active && this.mounted)
  }

  build() {
    Blank().width(0).height(0).hitTestBehavior(HitTestMode.None)
  }
}
