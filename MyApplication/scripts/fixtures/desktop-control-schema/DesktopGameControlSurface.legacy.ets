import testNapi from 'libentry.so'
import { ControlSchemaMsg } from 'libentry.so'
import { display } from '@kit.ArkUI'
import { hilog } from '@kit.PerformanceAnalysisKit'
import {
  DEFAULT_JOYSTICK_DEAD_ZONE,
  InputSurfaceContext,
  INPUT_SURFACE_FIELD_DENSITY,
  getInputSurfaceContextStore
} from 'gamecontrol'
import { DesktopPhysicalTextInput } from './DesktopPhysicalTextInput'

const TAG: string = 'DesktopControls'

/**
 * desktop product 的游戏控制面。
 *
 * 它只负责关闭触控产品遗留的 Native 控件表并同步游戏 surface 尺寸；不渲染虚拟按钮、
 * 布局编辑入口、恢复按钮或透明恢复热区。键盘、鼠标、滚轮与指针抓取继续由
 * McGamePage/XComponent 的实体输入链处理。
 */
@Component
export struct DesktopGameControlSurface {
  /** 产品控制面统一入参；纯桌面产品不读取触控动作配置。 */
  @Prop gameDirectory: string = ''
  /** 统一游戏页面的版本身份入参；桌面控制面不启动触控GUI桥，仅维持产品组件签名一致。 */
  @Prop realGameVersion: string = ''
  @Prop @Watch('onGrabChanged') isGrabbed: boolean = false
  @Prop @Watch('onSurfaceContextChanged') surfaceContextGeneration: number = 0
  @Prop pageActive: boolean = true
  /** 与通用包装保持一致；纯桌面没有触控编辑覆盖层，不主动请求暂停。 */
  onInputPause: (paused: boolean) => void = (_paused: boolean): void => {}
  private compWidth: number = 0
  private compHeight: number = 0
  private density: number = 0

  aboutToAppear(): void {
    this.publishEmptySchema()
  }

  private onGrabChanged(): void {
    this.publishEmptySchema()
  }

  private onSurfaceContextChanged(): void {
    this.density = 0
    this.publishEmptySchema()
  }

  // ⚠️ 这里曾有 clearLegacyRegions()（调 clearButtons + clearJoystick）。
  // 那张 legacy 矩形表在 native 侧已删除 —— 它的唯一读取方位于一个永不执行的分支里。
  // desktop 产品要表达的"没有任何虚拟控件"现在由 publishEmptySchema() 单独承担：
  // 一张 controls 为空的 Control Schema，就是权威表述。

  private publishEmptySchema(): void {
    if (this.compWidth <= 0 || this.compHeight <= 0) return
    try {
      if (!this.resolveDensity()) return
      const widthPx: number = Math.max(1, this.compWidth * this.density)
      const heightPx: number = Math.max(1, this.compHeight * this.density)
      // ⚠️ 墓碑: `testNapi.setCompSize(widthPx, heightPx)` 已删除（终点零读者），
      // 详见计划 §64.3。同样的两个值下一行就进了 schema，而 schema 里那两个字段是活的。
      const schema: ControlSchemaMsg = {
        schemaVersion: 2,
        compWidth: widthPx,
        compHeight: heightPx,
        grabbed: this.isGrabbed,
        deadZone: DEFAULT_JOYSTICK_DEAD_ZONE,
        controls: []
      }
      if (testNapi.setControlSchema(schema) <= 0) {
        hilog.error(0x0000, TAG, 'Failed to publish empty desktop control schema')
      }
    } catch (e) {
      hilog.error(0x0000, TAG, 'Desktop control schema update failed: %{public}s', (e as Error).message)
    }
  }

  build() {
    Stack() {
      Stack()
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          this.compWidth = newArea.width as number
          this.compHeight = newArea.height as number
          this.resolveDensity()
          this.publishEmptySchema()
        })
      DesktopPhysicalTextInput({
        active: this.pageActive && !this.isGrabbed
      })
    }
    .width('100%')
    .height('100%')
  }

  private resolveDensity(): boolean {
    const context: InputSurfaceContext = getInputSurfaceContextStore().snapshot()
    if (!context.provisional) {
      if (!context.has(INPUT_SURFACE_FIELD_DENSITY)) return false
      this.density = context.density
      return true
    }
    if (this.density > 0) return true
    // Window 尚未取得时的临时值；首个权威 context generation 会覆盖它。
    try {
      const currentDisplay = display.getDefaultDisplaySync()
      this.density = currentDisplay.densityPixels > 0 ? currentDisplay.densityPixels : 1
    } catch (_) {
      this.density = 1
    }
    return true
  }
}
