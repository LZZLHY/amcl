/**
 * RenderPage.ets — P1: OpenGL ES 渲染验证（开发者探针页）
 *
 * 2026-08-01 配色修正：本页原先整页不接主题、结果区硬编码 `#F5F5F5` 底色且 Text 不设
 * fontColor —— 深色模式下系统把默认文字色变浅，配上近白的面板底色就是**白底白字**，
 * 探针输出完全看不见。现在：页面壳走 resolveTheme（跟 DevToolsPage 同一套），结果区
 * 换用共享组件 DevConsole（固定深色终端观感 + 逐行语义着色）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import testNapi from 'libentry.so';
import { formatError } from 'commons';
import { ThemeColors, ThemeMode, resolveTheme, resolveIsDark } from 'commons';
import { PreferenceManager } from 'feature_system';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { DevConsole } from '../components/DevConsole';

@Entry
@Component
struct RenderPage {
  @State gpuInfo: string = ''
  @State isRefreshing: boolean = false
  private xComponentController: XComponentController = new XComponentController()
  @State surfaceId: string = ''
  @State renderStatus: string = '未启动'
  /** 当前展示的是哪个探针的输出（给控制台标题条用）。 */
  @State consoleLabel: string = 'gpu-info'

  // ---- 主题：与 DevToolsPage 完全一致的接法（@StorageProp + @Watch 跟随系统切换）----
  @State theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false)
  @StorageProp('currentColorMode') @Watch('onColorModeChange') currentColorMode: number = 0
  @StorageProp('topRectHeight') topSafeHeight: number = 0
  @StorageProp('bottomRectHeight') bottomSafeHeight: number = 0
  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!

  aboutToAppear() {
    this.applyTheme()
  }

  onColorModeChange(): void {
    this.applyTheme()
  }

  private applyTheme(): void {
    let systemIsDark: boolean = (this.currentColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK)
    let mode: ThemeMode = new PreferenceManager(this.context).themeMode
    this.theme = resolveTheme(mode, resolveIsDark(mode, systemIsDark))
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('P1: OpenGL ES 渲染验证')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme.textPrimary)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 12, bottom: 8 })

      // XComponent 渲染区域
      Stack() {
        XComponent({
          id: 'xcomponent_render',
          type: XComponentType.SURFACE,
          libraryname: 'entry',
          controller: this.xComponentController
        })
          .onLoad(() => {
            this.surfaceId = this.xComponentController.getXComponentSurfaceId()
            this.renderStatus = '渲染中'
            hilog.info(0x0000, 'RENDER', 'XComponent loaded, surfaceId: %{public}s', this.surfaceId)

            // 延迟获取 GPU 信息（等待 EGL 初始化完成）
            setTimeout(() => {
              if (this.consoleLabel === 'gpu-info' && !this.isRefreshing) this.refreshGpuInfo()
            }, 1500)
          })
          .onDestroy(() => {
            this.renderStatus = '已销毁'
            hilog.info(0x0000, 'RENDER', 'XComponent destroyed')
          })
          .width('100%')
          .height('100%')

        // 渲染状态叠加层
        Text(this.renderStatus)
          .fontSize(12)
          .fontColor('#FFFFFF')
          .backgroundColor('#80000000')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(4)
          .position({ x: 8, y: 8 })
      }
      .width('100%')
      .height('38%')
      .borderRadius(12)
      .clip(true)
      .margin({ left: 12, right: 12, bottom: 8 })

      // 刷新按钮
      Button('刷新 GPU 信息')
        .type(ButtonType.Capsule)
        .width('60%')
        .height(40)
        .fontSize(15)
        .backgroundColor(this.theme.primary)
        .fontColor(this.theme.textOnPrimary)
        .enabled(!this.isRefreshing)
        .margin({ bottom: 8 })
        .onClick(() => {
          this.refreshGpuInfo()
        })

      // SDL3 混合双窗口 Phase 0 探针：验证 auxiliary pbuffer + presented host surface。
      // 放在本页而不是 DevTools，是因为探针需要活跃的 XComponent surface —— 本页的
      // XComponent 已让 xcomponent.cpp 的 OnSurfaceCreated 设好 AMCL_NATIVE_WINDOW。
      // 与 VulkanPage 的 runVulkanSelfTest 是同一模式。
      Button('SDL3 混合双窗口 Phase 0 探针')
        .type(ButtonType.Capsule)
        .width('60%')
        .height(40)
        .fontSize(15)
        .backgroundColor('#5E35B1')
        .fontColor('#FFFFFF')
        .enabled(!this.isRefreshing)
        .margin({ bottom: 8 })
        .onClick(() => {
          this.runSdl3WindowProbe()
        })

      // MobileGL DirectVulkan 出帧探针（MOBILEGL_ADAPTATION_PLAN.md §5.2 Phase 2a 收口判据）。
      // 与上面 SDL3 探针同一模式：需要本页的活跃 XComponent surface。
      // ⚠️ libmobilegl.so 不在发布 HAP：先 build-mobilegl.ps1 -DeployToLibs 再装机，
      // 否则探针会在 dlopen 步骤给出带提示的失败报告（那也是有效判据）。
      Button('MobileGL 出帧探针（Phase 2a）')
        .type(ButtonType.Capsule)
        .width('60%')
        .height(40)
        .fontSize(15)
        .backgroundColor('#00695C')
        .fontColor('#FFFFFF')
        .enabled(!this.isRefreshing)
        .margin({ bottom: 8 })
        .onClick(() => {
          this.runMobileglProbe()
        })

      Button('MobileGL 双窗口验证')
        .width('60%')
        .height(40)
        .enabled(!this.isRefreshing)
        .margin({ bottom: 8 })
        .onClick(() => {
          this.runMobileglProbe(true)
        })

      // 结果区：统一的开发者终端面板（深色底 + 逐行语义着色），修掉深色模式白底白字
      DevConsole({
        label: this.consoleLabel,
        content: this.gpuInfo,
        running: this.isRefreshing,
        hint: '等待渲染面初始化…（XComponent onLoad 后 1.5s 自动查一次 GPU 信息）'
      })
        .width('92%')
        .margin({ bottom: 12 })
    }
    .height('100%')
    .width('100%')
    .backgroundColor(this.theme.bgPrimary)
    .padding({ top: this.topSafeHeight, bottom: this.bottomSafeHeight })
  }

  refreshGpuInfo() {
    this.isRefreshing = true
    this.consoleLabel = 'gpu-info'
    try {
      let info: string = testNapi.getGpuInfo()
      this.gpuInfo = info
      this.renderStatus = '渲染中'
      hilog.info(0x0000, 'RENDER', 'GPU info refreshed')
    } catch (error) {
      this.gpuInfo = '❌ 获取 GPU 信息失败: ' + formatError(error)
      hilog.error(0x0000, 'RENDER', 'Failed to get GPU info: %{public}s', formatError(error))
    }
    this.isRefreshing = false
  }

  // 验证 SDL3 能否用宿主（本页 XComponent）的 native window 建出窗口 + GL 上下文。
  // 不显式传路径：native 侧按名字 dlopen("libSDL3.so")，走应用 namespace 默认搜索。
  runSdl3WindowProbe() {
    this.isRefreshing = true
    this.consoleLabel = 'sdl3-window'
    this.gpuInfo = 'SDL3 窗口探针运行中...'
    try {
      let report: string = testNapi.runSdl3WindowTest('')
      this.gpuInfo = report
      hilog.info(0x0000, 'RENDER', 'SDL3 window probe done')
    } catch (error) {
      this.gpuInfo = '❌ SDL3 窗口探针失败: ' + formatError(error)
      hilog.error(0x0000, 'RENDER', 'SDL3 window probe failed: %{public}s', formatError(error))
    }
    this.isRefreshing = false
  }

  // MobileGL DirectVulkan 端到端出帧（本页 XComponent 的 OHNativeWindow → VkSurface →
  // swapchain → 纯色 present ×5 → 重建一轮）。报告逐步 ✅/❌，细节在 hilog tag=MobileGL。
  runMobileglProbe(pbufferFirst: boolean = false): void {
    this.isRefreshing = true
    this.consoleLabel = 'mobilegl-probe'
    this.gpuInfo = 'MobileGL 出帧探针运行中...（屏幕应闪过蓝→青数帧）'
    try {
      let report: string = pbufferFirst ? testNapi.runMobileglPbufferProbe() : testNapi.runMobileglProbe()
      this.gpuInfo = report
      hilog.info(0x0000, 'RENDER', 'MobileGL probe done')
    } catch (error) {
      this.gpuInfo = '❌ MobileGL 出帧探针失败: ' + formatError(error)
      hilog.error(0x0000, 'RENDER', 'MobileGL probe failed: %{public}s', formatError(error))
    }
    this.isRefreshing = false
  }
}
