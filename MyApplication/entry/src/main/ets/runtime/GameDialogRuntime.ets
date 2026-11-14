/**
 * TinyFD同步提示的鸿蒙UI端。窗口挂接和回包均在本GameAbility事件线程；只复用现有
 * Host维护时钟，不新建worker/轮询时钟。窗口销毁先退休Native请求，迟到按钮不得
 * 借用新窗口代次；正文只显示为文本，不执行URL、shell或自动替用户作选择。
 */
import { UIContext } from '@kit.ArkUI'
import testNapi, { GameDialogRequest } from 'libentry.so'
import { AppLogger, LOG_DOMAIN_LAUNCH } from 'commons'

export class GameDialogRuntime {
  private static context: UIContext | undefined = undefined
  private static generation: string = ''
  private static session: number = 0
  private static active: GameDialogRequest | undefined = undefined
  /** 对话框已消失但Native尚未接受回包时，原Host节拍重试原选择，不再次显示UI。 */
  private static completion: (() => boolean) | undefined = undefined

  /** 在页面/JVM启动前挂接真实窗口；重建只允许显式detach后建立新租约。 */
  static attach(context: UIContext, session: number): void {
    // 同一窗口的页面重建不退休正在显示的提示；旧UIContext属于原窗口且仍有效。
    if (GameDialogRuntime.context !== undefined && GameDialogRuntime.session === session) return
    if (GameDialogRuntime.generation.length > 0) throw new Error('游戏对话框窗口已挂接')
    const generation: string = testNapi.gameDialogAttach(session)
    if (generation.length === 0) throw new Error('无法建立游戏对话框窗口租约')
    GameDialogRuntime.context = context
    GameDialogRuntime.session = session
    GameDialogRuntime.generation = generation
  }

  /** 同步撤销先于丢弃UI引用，确保Native等待者不会因页面/Ability消失永久阻塞。 */
  static detach(): void {
    const generation: string = GameDialogRuntime.generation
    GameDialogRuntime.context = undefined
    GameDialogRuntime.active = undefined
    GameDialogRuntime.completion = undefined
    // 回执之前保留原代次墓碑。NAPI抛错时后续Host/窗口/Ability清理仍能重试原请求，
    // 不能因为先清字符串而把原生阻塞线程永久遗弃。
    if (generation.length > 0 && !testNapi.gameDialogDetach(generation))
      throw new Error('原生游戏对话框退休未确认')
    GameDialogRuntime.generation = ''
  }

  /** 只显示一个已绑定请求；旧回包、重复点击和退出动画都不会弹出下一条重叠提示。 */
  static maintain(): void {
    const completion: (() => boolean) | undefined = GameDialogRuntime.completion
    if (completion !== undefined) {
      if (completion()) { GameDialogRuntime.completion = undefined; GameDialogRuntime.active = undefined }
      return
    }
    const context: UIContext | undefined = GameDialogRuntime.context
    const generation: string = GameDialogRuntime.generation
    if (context === undefined || generation.length === 0 || GameDialogRuntime.active !== undefined) return
    const request: GameDialogRequest | undefined = testNapi.gameDialogTake(generation)
    if (request === undefined || request.generation !== generation) return
    GameDialogRuntime.active = request
    let replied: boolean = false
    let intent: number | undefined = undefined
    let fromUser: boolean = false
    const reply = (result: number, userResponse: boolean): boolean => {
      if (replied) return true
      if (generation !== GameDialogRuntime.generation || GameDialogRuntime.active !== request) return false
      // 第一次真实用户选择优先于后续消失事件的兜底取消。只有Native回执成功才置完成。
      if (intent === undefined) { intent = result; fromUser = userResponse }
      try { replied = testNapi.gameDialogReply(generation, request.requestId, intent, fromUser) }
      catch (_) { /* 原意图保留，由消失后的原Host节拍重试；不得伪记已完成。 */ }
      return replied
    }
    const finish = (): void => {
      if (reply(0, false)) GameDialogRuntime.active = undefined
      else GameDialogRuntime.completion = (): boolean => reply(0, false)
    }
    try {
      if (request.kind === 5) {
        context.getPromptAction().showToast({ message: request.title + '\n' + request.message })
        finish()
        return
      }
      const buttons: AlertDialogButtonOptions[] = []
      const add = (value: string, result: number): void => {
        buttons.push({ value: value, defaultFocus: request.defaultButton === result,
          action: (): void => { reply(result, true) } })
      }
      if (request.kind === 1 || request.kind === 2) add('确定', 1)
      else add('是', 1)
      if (request.kind === 2) add('取消', 0)
      else if (request.kind === 3) add('否', 0)
      else if (request.kind === 4) { add('否', 2); add('取消', 0) }
      context.showAlertDialog({ title: request.title, message: request.message,
        autoCancel: true, buttons: buttons,
        onWillDismiss: (action: DismissDialogAction): void => { reply(0, true); action.dismiss() },
        onDidDisappear: (): void => {
          if (GameDialogRuntime.active === request) finish()
        } })
      AppLogger.info('GameDialog', '已显示原生游戏提示 kind=' + request.kind, LOG_DOMAIN_LAUNCH)
    } catch (error) {
      if (GameDialogRuntime.active === request) finish()
      AppLogger.warn('GameDialog', '无法显示原生游戏提示，返回取消', error, LOG_DOMAIN_LAUNCH)
    }
  }
}
