/**
 * LayoutEditorPage.ets — 横屏布局编辑器宿主页（Phase D 键鼠适配重构）
 *
 * 路由：从 LayoutListPage 跳入，params.profileName = 要编辑的方案名。
 * 行为：
 *   - aboutToAppear 强制 LANDSCAPE + 全屏沉浸
 *   - 把目标方案设为 active，再渲染 LayoutEditor 全屏
 *   - 编辑器 onDone 调 router.back()，自动回到 LayoutListPage
 *   - aboutToDisappear 恢复 UNSPECIFIED，避免影响下一个页面
 */
import { router, window } from '@kit.ArkUI'
import { common } from '@kit.AbilityKit'
import { LayoutProfile } from 'gamecontrol'
import { LayoutEditor } from '../components/LayoutEditor'
import { getLayoutStore } from 'gamecontrol'
import { ProductInputProfile } from 'entry/ProductInputProfile'
import { hilog } from '@kit.PerformanceAnalysisKit'

interface EditorPageParams {
  profileName?: string
}

@Entry
@Component
struct LayoutEditorPage {
  @State screenW: number = 720
  @State screenH: number = 360
  @State ready: boolean = false
  @State loadError: string = ''

  private targetProfileName: string = ''
  /** 父页先持租约覆盖 init 后的 clone/setActive，子编辑器显示后另持嵌套租约。 */
  private editorLeaseHeld: boolean = false
  private pageMounted: boolean = false
  private pageGeneration: number = 0
  private pageCompleted: boolean = false
  private preparationTask: Promise<void> | undefined = undefined
  private cleanupTask: Promise<void> | undefined = undefined

  private getAbilityContext(): common.UIAbilityContext {
    return AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!
  }

  async aboutToAppear(): Promise<void> {
    this.pageMounted = true
    this.pageCompleted = false
    this.ready = false
    this.loadError = ''
    const generation: number = ++this.pageGeneration
    if (!ProductInputProfile.supportsTouchLayouts()) {
      this.getUIContext().getRouter().back()
      return
    }
    const previousCleanup: Promise<void> | undefined = this.cleanupTask
    if (previousCleanup !== undefined) await previousCleanup
    if (!this.pageMounted || generation !== this.pageGeneration) return
    this.cleanupTask = undefined
    const task: Promise<void> = this.prepareEditorPage_(generation)
    this.preparationTask = task
    await task
  }

  /**
   * 父页初始化事务：先等服务 ready，再获得拒绝并发导入的租约。每次 await 后检查
   * 页面代次；过期续体不能重新渲染编辑器或修改已离开页面的窗口方向。
   */
  private async prepareEditorPage_(generation: number): Promise<void> {
    const store = getLayoutStore()
    try {
      const params = this.getUIContext().getRouter().getParams() as EditorPageParams
      this.targetProfileName = params?.profileName ?? ''
      const context = this.getAbilityContext()
      await store.init(context)
      if (!this.pageMounted || generation !== this.pageGeneration) return
      if (!store.beginEditorSession()) throw new Error('布局正在同步，请稍后再试')
      this.editorLeaseHeld = true
      store.beginEditorTransaction()
      if (this.targetProfileName.length > 0) {
        const target: LayoutProfile | undefined = store.getAllProfiles().find((profile: LayoutProfile): boolean =>
          profile.name === this.targetProfileName)
        if (target !== undefined) {
          if (target.isPreset) {
            if ((await store.cloneAsUser(this.targetProfileName)) === null) throw new Error('无法创建预设的编辑副本')
          } else {
            await store.setActiveProfile(this.targetProfileName)
          }
        }
      }
      if (!this.pageMounted || generation !== this.pageGeneration) return
      // 窗口 Promise 的拒绝统一收口，不把布局已初始化误报成存储失败。
      await this.applyEditorWindowStyle_(true, generation)
      if (this.pageMounted && generation === this.pageGeneration) this.ready = true
    } catch (error) {
      this.reportEditorPageError_('无法打开布局编辑器：' + (error as Error).message)
      await this.restorePageTransaction_()
    }
  }

  /** 进入失败或未完成编辑即销毁时恢复原事务；失败必须可见，不能假装取消已成功。 */
  private async restorePageTransaction_(): Promise<void> {
    if (!this.editorLeaseHeld) return
    try {
      if (!this.pageCompleted && !(await getLayoutStore().restoreEditorTransaction())) {
        throw new Error('原布局尚未恢复，请重新进入编辑器重试取消')
      }
    } catch (error) {
      this.reportEditorPageError_('恢复原布局失败：' + (error as Error).message)
    } finally {
      this.releaseEditorLease_()
    }
  }

  private releaseEditorLease_(): void {
    if (!this.editorLeaseHeld) return
    this.editorLeaseHeld = false
    getLayoutStore().endEditorSession()
  }

  private reportEditorPageError_(message: string): void {
    hilog.error(0x0000, 'LayoutEditorPage', '%{public}s', message)
    if (this.pageMounted) this.loadError = message
  }

  /** 子编辑器只会在保存或恢复确认后通知完成；这里只退出一次，不重复提交事务。 */
  private finishEditorPage_(): void {
    if (this.pageCompleted || !this.pageMounted) return
    this.pageCompleted = true
    this.releaseEditorLease_()
    this.getUIContext().getRouter().back()
  }

  private async cleanupEditorPage_(): Promise<void> {
    const preparing: Promise<void> | undefined = this.preparationTask
    if (preparing !== undefined) await preparing
    await this.restorePageTransaction_()
  }

  /**
   * 进入时横屏隐藏系统栏、离开时恢复原样；SDK 的三个 setter 都返回 Promise，必须 await。
   * 每次系统调用后核对页面代次，旧页面的迟到续体不得改动重新出现的编辑器窗口。
   * 窗口销毁/权限拒绝仅记录诊断，不影响布局事务回滚，也不向生命周期回调泄漏拒绝。
   */
  private async applyEditorWindowStyle_(editing: boolean, generation: number): Promise<void> {
    try {
      const win = await window.getLastWindow(this.getAbilityContext())
      if (this.pageMounted !== editing || generation !== this.pageGeneration) return
      if (!ProductInputProfile.selection().desktopWindow) {
        await win.setPreferredOrientation(editing ? window.Orientation.LANDSCAPE : window.Orientation.UNSPECIFIED)
      }
      if (this.pageMounted !== editing || generation !== this.pageGeneration) return
      await win.setWindowLayoutFullScreen(editing)
      if (this.pageMounted !== editing || generation !== this.pageGeneration) return
      if (!ProductInputProfile.selection().desktopWindow) {
        await win.setWindowSystemBarEnable(editing ? [] : ['status', 'navigation'])
      }
    } catch (error) {
      hilog.warn(0x0000, 'LayoutEditorPage', '布局编辑器窗口样式切换失败：%{public}s', (error as Error).message)
    }
  }

  aboutToDisappear(): void {
    this.pageMounted = false
    this.pageGeneration++
    const generation: number = this.pageGeneration
    if (this.cleanupTask === undefined) this.cleanupTask = this.cleanupEditorPage_()
    // 生命周期同步返回；恢复方法内部已完整处理异步异常，不留未处理的 .then 链。
    this.applyEditorWindowStyle_(false, generation)
  }

  build() {
    Stack() {
      // 背景：模拟游戏画面深色，让 LayoutEditor 的按钮叠在上面
      Column().width('100%').height('100%').backgroundColor('#333333')

      if (this.ready) {
        LayoutEditor({
          screenWidth: this.screenW,
          screenHeight: this.screenH,
          onDone: (_result: LayoutProfile | null) => { this.finishEditorPage_() },
          onInitializationFailed: (message: string) => { this.reportEditorPageError_(message) }
        })
      } else if (this.loadError.length > 0) {
        Text(this.loadError).fontSize(14).fontColor('#FFFFFF').padding(24)
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_old: Area, newVal: Area) => {
      this.screenW = newVal.width as number
      this.screenH = newVal.height as number
    })
  }
}
