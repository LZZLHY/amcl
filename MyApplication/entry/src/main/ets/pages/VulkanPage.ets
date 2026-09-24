import testNapi from 'libentry.so';
/**
 * VulkanPage.ets — Vulkan 能力探针（开发者探针页）
 *
 * 2026-08-01 配色修正：与 RenderPage 同一个毛病 —— 结果区硬编码 `#F5F5F5` 底色、
 * Text 不设 fontColor，深色模式下变成白底白字，探针输出看不见。现已改为页面壳走
 * resolveTheme、结果区换用共享组件 DevConsole。
 */
import { formatError } from 'commons';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_NATIVE } from 'commons';
import { ThemeColors, ThemeMode, resolveTheme, resolveIsDark } from 'commons';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { PreferenceManager } from 'feature_system';
import { DevConsole } from '../components/DevConsole';
import { GraphicsProfileInput, listGraphicsProfileAvailability } from 'launch';
import { prepareGraphicsProfileInput } from '../runtime/GraphicsCapabilityAdapter';

@Entry
@Component
struct VulkanPage {
  @State vkInfo: string = ''
  @State isRefreshing: boolean = false
  private xComponentController: XComponentController = new XComponentController()
  @State surfaceId: string = ''
  @State renderStatus: string = '未启动'
  @State nativeVulkanRequested: boolean = false
  @State vulkanAvailable: boolean = false
  @State vulkanAvailabilityReason: string = '尚未运行 Vulkan 能力探针'
  /** 异步读取客户端摘要时页面可能已经退出；旧查询不可覆盖后一次刷新。 */
  private availabilityGeneration: number = 0
  // ⚰️ 2026-08-27：曾有 `@State glRenderer` 承载 MobileGlues ⇄ Zink 切换按钮的状态。
  // zink 完全退役后本页不再有渲染器切换入口（§S6）。
  /** 当前展示的是哪个探针的输出（给控制台标题条用）。 */
  @State consoleLabel: string = 'vulkan'

  // ---- 主题：与 DevToolsPage / RenderPage 同一套接法 ----
  @State theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false)
  @StorageProp('currentColorMode') @Watch('onColorModeChange') currentColorMode: number = 0
  @StorageProp('topRectHeight') topSafeHeight: number = 0
  @StorageProp('bottomRectHeight') bottomSafeHeight: number = 0

  // 2026-05-23 API NEXT 迁移：getContext(this) 已弃用，改读 EntryAbility 缓存的 context。
  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!;

  aboutToAppear(): void {
    this.applyTheme()
    const preferences: PreferenceManager = new PreferenceManager(this.context)
    this.nativeVulkanRequested = preferences.devRendererOverride === 'minecraft-vulkan'
      || preferences.graphicsProfile === 'minecraft-vulkan'
    this.refreshVulkanAvailability()
  }

  aboutToDisappear(): void {
    this.availabilityGeneration++
  }

  /** 与设置页共用真实版本/客户端/设备准入，避免 26.2 的旧摘要把 26.4 错误置灰。 */
  private async refreshVulkanAvailability(): Promise<void> {
    const generation: number = ++this.availabilityGeneration
    this.vulkanAvailable = false
    try {
      const preferences: PreferenceManager = new PreferenceManager(this.context)
      const input: GraphicsProfileInput = await prepareGraphicsProfileInput(this.context,
        AppStorage.get<string>('mcDir') ?? '', preferences.mcVersion, preferences.graphicsProfile, true,
        preferences.graphicsProfileExplicit)
      if (generation !== this.availabilityGeneration) return
      this.vulkanAvailabilityReason = '请选择已安装且已适配的游戏版本'
      for (const candidate of listGraphicsProfileAvailability(input)) {
        if (candidate.id !== 'minecraft-vulkan') continue
        this.vulkanAvailable = candidate.admitted
        this.vulkanAvailabilityReason = input.realMcVersion + '：' + (candidate.admitted
          ? '设备检查通过，启动时复核窗口和呈现' : candidate.reason)
      }
    } catch (error) {
      if (generation !== this.availabilityGeneration) return
      this.vulkanAvailable = false
      this.vulkanAvailabilityReason = 'Vulkan 能力探针不可用'
      AppLogger.warn('VK_RENDER', 'Vulkan availability parse failed', error, LOG_DOMAIN_NATIVE)
    }
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
      Row() {
        Text('Vulkan 能力探针 (Phase 0)')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme.textPrimary)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 12, bottom: 8 })

      Stack() {
        XComponent({
          id: 'xcomponent_vulkan',
          type: XComponentType.SURFACE,
          libraryname: 'entry',
          controller: this.xComponentController
        })
          .onLoad(() => {
            this.surfaceId = this.xComponentController.getXComponentSurfaceId()
            this.renderStatus = 'Vulkan 渲染中'
            AppLogger.info('VK_RENDER', `Vulkan XComponent loaded, surfaceId: ${this.surfaceId}`, LOG_DOMAIN_NATIVE)

            setTimeout(() => {
              this.refreshVkInfo()
            }, 2000)
          })
          .onDestroy(() => {
            this.renderStatus = '已销毁'
          })
          .width('100%')
          .height('100%')

        Text(this.renderStatus)
          .fontSize(12)
          .fontColor('#FFFFFF')
          .backgroundColor('#80000000')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(4)
          .position({ x: 8, y: 8 })
      }
      .width('100%')
      .height('45%')
      .borderRadius(12)
      .clip(true)
      .margin({ left: 12, right: 12, bottom: 8 })

      Button('运行 Vulkan 探针')
        .type(ButtonType.Capsule)
        .width('60%')
        .height(40)
        .fontSize(15)
        .backgroundColor('#9C27B0')
        .enabled(!this.isRefreshing)
        .margin({ bottom: 8 })
        .onClick(() => {
          this.refreshVkInfo()
        })

      Button('运行 Vulkan 实战自检（建 surface→swapchain→present）')
        .type(ButtonType.Capsule)
        .width('80%')
        .height(40)
        .fontSize(13)
        .backgroundColor('#00897B')
        .enabled(!this.isRefreshing && this.vulkanAvailable)
        .margin({ bottom: 8 })
        .onClick(() => {
          this.runSelfTest()
        })

      // ⚰️ 2026-08-27（渲染后端治理 §S6）：这里曾有 4 个 zink/OSMesa 相关按钮 ——
      //   「OSMesa 加载自检（仅 dlopen）」/「OSMesa 全量·softpipe」/「OSMesa 全量·zink」
      //   + 「游戏渲染器: MobileGlues ⇄ Zink」切换。
      // zink 已完全退役（产品决策 D1），四个入口一并移除：一个回答"该不该找回 zink"的探针，
      // 在 zink 退役之后没人会据此行动。
      // 索引与恢复路径见 prebuilt/mesa-zink/integration-archive/README.md。

      Button(this.nativeVulkanRequested
        ? '已请求原生 Vulkan（下次启动检查）'
        : (this.vulkanAvailable ? '请求原生 Vulkan（下次启动检查）' : '原生 Vulkan 不可用（已置灰）'))
        .type(ButtonType.Capsule)
        .width('80%')
        .height(40)
        .fontSize(13)
        .backgroundColor(this.nativeVulkanRequested ? '#C0392B' : '#E67E22')
        .fontColor('#FFFFFF')
        .enabled(!this.isRefreshing && (this.vulkanAvailable || this.nativeVulkanRequested))
        .margin({ bottom: 8 })
        .onClick(() => {
          const preferences: PreferenceManager = new PreferenceManager(this.context)
          this.nativeVulkanRequested = !this.nativeVulkanRequested
          preferences.devRendererOverride = this.nativeVulkanRequested ? 'minecraft-vulkan' : ''
          this.vkInfo = this.nativeVulkanRequested
            ? '已记录原生 Vulkan 请求。下次启动会按版本、窗口 provider 和真实 capability 检查。'
            : '已清除原生 Vulkan 请求。下次启动使用常规 profile 选择。'
        })

      Text(this.vulkanAvailabilityReason)
        .fontSize(12)
        .fontColor(this.vulkanAvailable ? '#2E7D32' : this.theme.textHint)
        .width('88%')
        .margin({ bottom: 8 })

      // 结果区：统一的开发者终端面板（深色底 + 逐行语义着色），修掉深色模式白底白字
      DevConsole({
        label: this.consoleLabel,
        content: this.vkInfo,
        running: this.isRefreshing,
        hint: '点击上方按钮运行 Vulkan 能力探针…'
      })
        .width('92%')
        .margin({ bottom: 12 })
    }
    .height('100%')
    .width('100%')
    .backgroundColor(this.theme.bgPrimary)
    .padding({ top: this.topSafeHeight, bottom: this.bottomSafeHeight })
  }

  refreshVkInfo(): void {
    this.isRefreshing = true
    this.refreshVulkanAvailability()
    try {
      // VULKAN_ADAPTATION_PLAN.md Phase 0：调 native Vulkan 能力探针（dlopen libvulkan，
      // 只读盘点 loader 版本 / VK_KHR_surface + VK_OHOS_surface / 物理设备 core 版本 / 关键设备扩展）。
      let info: string = testNapi.getVulkanInfo()
      this.vkInfo = info
      this.renderStatus = 'Vulkan 探针完成'
      AppLogger.info('VK_RENDER', `Vulkan probe info refreshed (${info.length} chars)`, LOG_DOMAIN_NATIVE)
    } catch (error) {
      this.vkInfo = '获取 Vulkan 信息失败: ' + formatError(error)
      AppLogger.error('VK_RENDER', 'Vulkan probe failed', error, LOG_DOMAIN_NATIVE)
    }
    this.isRefreshing = false
  }

  // Phase B：端到端实战自检。复用本页 XComponent 的 NativeWindow（native 侧从环境变量
  // AMCL_NATIVE_WINDOW 取，xcomponent.cpp OnSurfaceCreated 已设），真的建 surface +
  // swapchain + 渲染一帧天蓝色 + present，逐步报告华为驱动在哪一环断。
  runSelfTest() {
    this.isRefreshing = true
    this.renderStatus = 'Vulkan 自检运行中...'
    try {
      // 不显式传指针：native 侧会回退到 AMCL_NATIVE_WINDOW 环境变量（本页 XComponent 已设）。
      let report: string = testNapi.runVulkanSelfTest()
      this.vkInfo = report
      this.renderStatus = 'Vulkan 自检完成'
      AppLogger.info('VK_RENDER', `Vulkan self-test done (${report.length} chars)`, LOG_DOMAIN_NATIVE)
    } catch (error) {
      this.vkInfo = 'Vulkan 实战自检失败: ' + formatError(error)
      AppLogger.error('VK_RENDER', 'Self-test failed', error, LOG_DOMAIN_NATIVE)
    }
    this.isRefreshing = false
  }

  // ⚰️ 2026-08-27（渲染后端治理 §S6）：这里曾有 `runOSMesaTest(driver)` ——
  //   经 NAPI 调 `runOSMesaSelfTest`，driver=''/'softpipe'/'zink' 三档自检。
  // 随 zink 完全退役一并移除（native 侧 `platform/osmesa_probe.*` 与 NAPI 导出同批退役）。
  // 索引与恢复路径见 prebuilt/mesa-zink/integration-archive/README.md。

}
