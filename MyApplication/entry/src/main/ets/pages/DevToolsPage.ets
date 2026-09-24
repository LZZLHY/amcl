/**
 * DevToolsPage.ets — 开发者工具页面（2026-06 重构：主从布局 / 一多适配 / 明暗主题）
 *
 * 设计稿：docs/design/devtab.pen（技术风，已圆角化 + 主题适配）。
 *   - 平板（Breakpoint.LG）：左侧分类工具栏 + 右侧详情/控制台（master-detail 同屏）。
 *   - 手机：工具列表 → 点击进入详情（list-detail 两段式，AppBar 返回回列表）。
 *
 * 适配：
 *   - 明暗主题：走 commons 的 resolveTheme + @StorageProp('currentColorMode')，整页随主题变色；
 *     控制台保持深色（终端语义，明暗下都用深底，符合直觉）。
 *   - 顶部安全区：@StorageProp('topRectHeight') 顶到 AppBar 上方留白，避开状态栏/挖孔。
 *   - 圆角 + 官方 Button（ButtonType.Capsule）。
 *
 * 工具运行逻辑（批次 D4 之后）：单条 NAPI 探针一律走 `nativeProbeRegistry()` 这张表，
 * 由 `runProbe` 的纯分派执行 —— 页面按钮与自动化共用同一条实现。
 * 留在本页的只有非探针的四类：MobileGL 覆盖开关 / 下载 smoke / FS·存储·手机存储探针
 * （后三者带 picker 与多步流程）。
 */

import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { NativeProbeDef, ProbeOutcome, findProbe, runProbe } from '../devtools/ProbeRegistryModel';
import { nativeProbeRegistry } from '../devtools/NativeProbeRegistry';
import { DownloadManager, DownloadTaskView, formatBytes, formatSpeed } from 'feature_core';
import { runFsRenameProbe, formatReport, FsProbeReport } from 'commons';
import { runStorageProbe, StorageProbeResult } from 'feature_system';
import { runPhoneStorageProbe, PhoneStorageProbeResult } from 'feature_system';
import { PreferenceManager } from 'feature_system';
import { formatError } from 'commons';
import { AppLogger } from 'commons';
import { LOG_DOMAIN } from 'commons';
import { DeviceProfile, Breakpoint } from 'commons';
import { ThemeColors, ThemeMode, resolveTheme, resolveIsDark } from 'commons';
import { fileIo as fs } from '@kit.CoreFileKit';
import { ProductBuildProfile } from 'entry/ProductBuildProfile';
import { GraphicsProfileSpec, graphicsProfileById, graphicsProfileByRole, GraphicsSelectionRole } from 'launch';

// 分类品牌色（明暗皆可读；与 Theme.task* 同调）
const CAT_SYSTEM = '#3B82F6';
const CAT_GRAPHICS = '#14B8A6';
const CAT_DIAG = '#F97316';

// 控制台固定深色（终端语义，明暗主题下都用深底）
const CONSOLE_BG = '#0E1117';
const CONSOLE_PANEL = '#161B22';
const CONSOLE_FG = '#C9D3DE';
const CONSOLE_DIM = '#6E7B8A';
const CONSOLE_GREEN = '#3FB950';
const CONSOLE_RED = '#F85149';
const OK_BG = '#102A17';
const ERR_BG = '#2A1213';
const RUN_AMBER = '#D29922';
const MONO = 'monospace';

// 圆角
const R_CARD = 14;
const R_CHIP = 8;
const R_BADGE = 6;

const SIDEBAR_W = 330;

/** 单个工具定义。action: 'run'(executeTest) | 'navigate'(独立页) | 'download' | 'embed' */
interface ToolDef {
  id: string;
  name: string;
  desc: string;
  cat: string;
  color: string;
  action: string;
  runLabel: string;
  route: string;
}

interface ToolGroup {
  name: string;
  color: string;
  tools: ToolDef[];
}

@Entry
@Component
struct DevToolsPage {
  @State testResult: string = '';
  @State isRunning: boolean = false;
  @State statusMsg: string = '就绪';
  @State currentTool: string = 'phoneStorage';
  @State showDetailOnPhone: boolean = false;
  @State breakpoint: Breakpoint = Breakpoint.SM;
  @State groups: ToolGroup[] = [];
  @State mobileglPackaged: boolean = false;

  @State theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false);
  @StorageProp('topRectHeight') topSafeHeight: number = 0;
  @StorageProp('bottomRectHeight') bottomSafeHeight: number = 0;
  @StorageProp('currentColorMode') @Watch('onColorModeChange') currentColorMode: number = 0;

  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!;
  private prefManager: PreferenceManager = new PreferenceManager(this.context);

  aboutToAppear() {
    this.applyTheme();
    this.breakpoint = DeviceProfile.currentBreakpoint();
    this.refreshGraphicsAvailability();
    this.groups = this.buildGroups();
  }

  private refreshGraphicsAvailability(): void {
    const host: common.UIAbilityContext | undefined = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (host === undefined) return;
    try {
      this.mobileglPackaged = fs.accessSync(host.bundleCodeDir + '/libs/arm64/libmobilegl.so');
    } catch (_) {
      this.mobileglPackaged = false;
    }
  }

  private toolEnabled(tool: ToolDef): boolean {
    if (tool.id === 'mobileglOverride') {
      return this.mobileglPackaged;
    }
    return true;
  }

  private toolDescription(tool: ToolDef): string {
    if (tool.id === 'mobileglOverride' && !this.toolEnabled(tool)) {
      return '当前安装包未包含 libmobilegl.so；安装带此运行库的包后可用。';
    }
    return tool.desc;
  }

  onColorModeChange(): void {
    this.applyTheme();
  }

  private applyTheme() {
    let systemIsDark = (this.currentColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    let mode = this.prefManager.themeMode;
    this.theme = resolveTheme(mode, resolveIsDark(mode, systemIsDark));
  }

  private buildGroups(): ToolGroup[] {
    const sys: ToolDef[] = [
      { id: 'jit', name: 'JIT / mmap', desc: '匿名内存 RWX · mmap EXEC · 文件映射 EXEC · dlopen — HotSpot JIT 核心能力探测', cat: '系统能力', color: CAT_SYSTEM, action: 'run', runLabel: '运行 JIT/mmap 测试', route: '' },
      { id: 'jvm', name: 'JVM 可行性', desc: 'dlopen/dlsym · pthread · signal · mmap 高级特性 · JNI 接口兼容性探测', cat: '系统能力', color: CAT_SYSTEM, action: 'run', runLabel: '运行 JVM 探测', route: '' },
      { id: 'jvmEmbed', name: 'JVM 嵌入', desc: '混合部署：.so 在 HAP libs/（系统允许 dlopen），数据文件解压到 filesDir/jdk/', cat: '系统能力', color: CAT_SYSTEM, action: 'embed', runLabel: '运行 JVM 嵌入测试', route: '' },
    ];
    const gfx: ToolDef[] = [
      { id: 'gles', name: 'GLES', desc: 'OpenGL ES 渲染自检（独立页面）', cat: '图形渲染', color: CAT_GRAPHICS, action: 'navigate', runLabel: '打开 GLES 页面', route: 'pages/RenderPage' },
      { id: 'vulkan', name: 'Vulkan', desc: 'Vulkan 能力 / swapchain 自检（独立页面）', cat: '图形渲染', color: CAT_GRAPHICS, action: 'navigate', runLabel: '打开 Vulkan 页面', route: 'pages/VulkanPage' },
      { id: 'glfw', name: 'GLFW', desc: 'glfwInit/Terminate · 窗口创建/查询 · 回调注册 · 触摸→鼠标映射', cat: '图形渲染', color: CAT_GRAPHICS, action: 'run', runLabel: '运行 GLFW 测试', route: '' },
      { id: 'gl4', name: 'OpenGL 4.x', desc: '官方能力查询 · OpenGL 4.2 上下文 · 像素回读验证', cat: '图形渲染', color: CAT_GRAPHICS, action: 'run', runLabel: '运行 OpenGL 4.x 探测', route: '' },
      { id: 'mg', name: 'MobileGlues', desc: 'GL→GLES 翻译 · 固定管线 · 矩阵/着色器函数 · MC 关键扩展', cat: '图形渲染', color: CAT_GRAPHICS, action: 'run', runLabel: '运行 MobileGlues 测试', route: '' },
      // MobileGL optional peer 的开发覆盖入口；常规选择由设置页 profile 列表提供。
      // 出帧探针在 RenderPage（上面 GLES 卡片进入）；这里只管"下次启动用哪个后端"的覆盖开关。
      { id: 'mobileglOverride', name: 'MobileGL 覆盖', desc: '请求 OpenGL peer profile MobileGL；SDL3 路线使用 DirectVulkan transport，启动前仍按版本、provider、产物和能力准入。', cat: '图形渲染', color: CAT_GRAPHICS, action: 'run', runLabel: '切换 MobileGL 覆盖', route: '' },
      { id: 'minecraftVulkanOverride', name: 'Minecraft Vulkan 候选', desc: '请求 Minecraft 原生 Vulkan profile；仅对清单确认的 26.2+ 版本进入原生 Vulkan 准入，不能替代 MobileGL。', cat: '图形渲染', color: CAT_GRAPHICS, action: 'run', runLabel: '切换 Vulkan 候选', route: '' },
      { id: 'lwjgl', name: 'LWJGL', desc: 'liblwjgl core / opengl / stb / tinyfd 加载 + 关键 JNI 符号验证', cat: '图形渲染', color: CAT_GRAPHICS, action: 'run', runLabel: '运行 LWJGL 测试', route: '' },
      { id: 'sdl3c2', name: 'SDL3 C2 关卡', desc: 'MC 26.3 硬校验：SDL_GL_GetProcAddress("glGetError") 必须与 dlsym(libglfw.so) 同址，否则 OpenGL 后端被拒。末行 C2 判定: PASS 即通过。', cat: '图形渲染', color: CAT_GRAPHICS, action: 'run', runLabel: '运行 SDL3 C2 探针', route: '' },
    ];
    const diag: ToolDef[] = [
      { id: 'download', name: '下载引擎', desc: '下载引擎端到端 smoke test：createTask/start/onProgress/onComplete · 多线程分段 + sha1', cat: '诊断 · 存储', color: CAT_DIAG, action: 'download', runLabel: '', route: '' },
      { id: 'fs', name: '沙箱 FS 探针', desc: 'rename 跨子目录是否 O(1) vs copy+unlink（评估 libraries 迁移方案）', cat: '诊断 · 存储', color: CAT_DIAG, action: 'run', runLabel: '运行 FS 探针（8 项）', route: '' },
      { id: 'storage', name: '存储探针 · 平板', desc: '平板沙箱外存储：Environment.getUserDownloadDir() + 原始路径直写 + native POSIX', cat: '诊断 · 存储', color: CAT_DIAG, action: 'run', runLabel: '运行存储探针', route: '' },
      { id: 'phoneStorage', name: '手机存储探针', desc: '手机沙箱外存储：DocumentViewPicker DOWNLOAD（无弹窗）→ native 裸 POSIX 读写 → 跨重启复用。末行 NATIVE_RW_OK 即可行。', cat: '诊断 · 存储', color: CAT_DIAG, action: 'run', runLabel: '运行手机存储探针', route: '' },
      // JDK IPv6 能力探针（JDK_IPV6_ADAPTATION_PLAN.md §3 P0-a）。放这里而不是新开一页：
      // 它纯文本、无 surface 依赖、一次跑完，控制台就是合适的载体。
      // ⚠️ 它是**诊断**不是关卡：没有"通过/失败"，看末尾的逐条判据与结论行。
      //   顶部状态胶囊显示 DONE 只代表探针跑完了（沿用本页共用的判定启发式）。
      { id: 'ipv6', name: 'IPv6 能力探针', desc: '逐条复现 libnet IPv6_supported() 的判据：C1 socket(AF_INET6) · C2 getsockname(fd 0)（仅 JDK 17）· C3 fopen(/proc/net/if_inet6)+fgets · C4 dlsym(RTLD_DEFAULT, inet_pton)，并枚举 getifaddrs 的 IPv6 地址。第二部分 D1–D8 量「把 ipv6_available 翻成 true 会不会打断 IPv4」。只观测，不改 JDK。', cat: '诊断 · 存储', color: CAT_DIAG, action: 'run', runLabel: '运行 IPv6 探针', route: '' },
      // Java 侧那一半：native 探针只能复现 libnet 的判据，读不到 Java 层真正观测到的东西。
      // 这个关卡 fork 子进程建 JVM 跑 com.amcl.launcher.Ipv6Diagnostics，抓「连 IPv6
      // 字面量时的第一条异常原文」。⚠️ 同步阻塞数秒；需要先启动过一次游戏（jar 才会解出来）。
      { id: 'ipv6java', name: 'IPv6 · Java 侧', desc: 'fork 子进程建 JVM 跑 Ipv6Diagnostics：读 SocketChannel 的实际地址族（= Net.isIPv6Available 的可观测投影）、连 [2001:db8::1]:25565 抓第一条异常原文（预期 UnsupportedAddressTypeException 且 message 为 null）、数 NetworkInterface 的 IPv6 条数。不需要 IPv6 服务器（该异常在任何网络 I/O 之前抛出）。⚠️ 会阻塞数秒；需先启动过一次游戏。', cat: '诊断 · 存储', color: CAT_DIAG, action: 'run', runLabel: '运行 Java 侧诊断', route: '' },
      // 键鼠诊断刻意做成独立页而不是 'run' 探针：它要观测的是**平台投递给应用的事件流**，
      // 必须有一块能真实接收 onMouse/onTouch/onAxisEvent 的区域，而控制台只能显示文本。
      // 独立页同时把观测面缩到最小（不碰 NAPI/光标锁/虚拟控件），且不必启动 Minecraft。
      { id: 'inputProbe', name: '键鼠原始输入诊断', desc: '判定系统的「鼠标左键+轴 → 触摸事件」兜底转换是否生效：按住左键拖动时 onMouse 是否仍投递 rawDelta。同时显示 touch 的 sourceTool/source 与轴事件原始值。不需要启动游戏。', cat: '诊断 · 存储', color: CAT_DIAG, action: 'navigate', runLabel: '打开键鼠诊断页', route: 'pages/InputProbePage' },
    ];
    return [
      { name: '系统能力', color: CAT_SYSTEM, tools: sys },
      { name: '图形渲染', color: CAT_GRAPHICS, tools: gfx },
      { name: '诊断 · 存储', color: CAT_DIAG, tools: diag },
    ];
  }

  private allTools(): ToolDef[] {
    let out: ToolDef[] = [];
    for (const g of this.groups) {
      for (const t of g.tools) out.push(t);
    }
    return out;
  }

  private toolCount(): number {
    return this.allTools().length;
  }

  private currentToolDef(): ToolDef {
    for (const t of this.allTools()) {
      if (t.id === this.currentTool) return t;
    }
    return this.allTools()[0];
  }

  private isTablet(): boolean {
    return this.breakpoint === Breakpoint.LG;
  }

  private selectTool(t: ToolDef) {
    if (!this.toolEnabled(t)) return;
    if (t.action === 'navigate') {
      try {
        this.getUIContext().getRouter().pushUrl({ url: t.route });
      } catch (e) {
        AppLogger.warn('DevTools', 'pushUrl failed', e, LOG_DOMAIN);
      }
      return;
    }
    this.currentTool = t.id;
    this.testResult = '';
    this.statusMsg = '就绪';
    if (!this.isTablet()) this.showDetailOnPhone = true;
  }

  private onBack() {
    if (!this.isTablet() && this.showDetailOnPhone) {
      this.showDetailOnPhone = false;
    } else {
      this.getUIContext().getRouter().back();
    }
  }

  // ==================== 布局 ====================

  build() {
    Column() {
      this.AppBar()
      if (this.isTablet()) {
        Row() {
          this.Sidebar()
          Column() { this.DetailContent() }.layoutWeight(1).height('100%')
        }.width('100%').layoutWeight(1).alignItems(VerticalAlign.Top)
      } else {
        if (this.showDetailOnPhone) {
          Column() { this.DetailContent() }.layoutWeight(1).width('100%')
        } else {
          this.ToolListView()
        }
      }
    }
    .width('100%').height('100%').backgroundColor(this.theme.bgPrimary)
    .onAreaChange((_o: Area, n: Area) => {
      let w = n.width as number
      if (w > 0) this.breakpoint = DeviceProfile.breakpointOf(w)
    })
  }

  @Builder
  AppBar() {
    Column() {
      Row({ space: 10 }) {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          Text('←').fontSize(20).fontColor(this.theme.textPrimary)
        }
        .width(36).height(36).backgroundColor(this.theme.bgInput)
        .onClick(() => { this.onBack() })

        Text((!this.isTablet() && this.showDetailOnPhone) ? this.currentToolDef().name : '开发者工具')
          .fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary)
        if (this.isTablet() || !this.showDetailOnPhone) {
          Row() {
            Text('DEV').fontSize(10).fontColor(this.theme.textOnPrimary).fontFamily(MONO).fontWeight(FontWeight.Bold)
          }.backgroundColor(this.theme.primary).borderRadius(R_BADGE).padding({ left: 7, right: 7, top: 2, bottom: 2 })
        }
        Blank()
        if (this.isTablet()) {
          Text('AMCL · 1.0.0-beta.5 · build 1000328').fontSize(12).fontColor(this.theme.textHint).fontFamily(MONO)
        }
      }
      .width('100%').height(56).padding({ left: 12, right: 20 }).alignItems(VerticalAlign.Center)
    }
    .width('100%').padding({ top: this.topSafeHeight })
    .backgroundColor(this.theme.bgSecondary)
    .border({ width: { bottom: 0.5 }, color: this.theme.divider })
  }

  @Builder
  Sidebar() {
    Column() {
      Row({ space: 8 }) {
        Text('⌕').fontSize(15).fontColor(this.theme.textHint)
        Text('筛选工具…').fontSize(13).fontColor(this.theme.textHint)
        Blank()
        Text(this.toolCount().toString()).fontSize(11).fontColor(this.theme.textHint).fontFamily(MONO)
      }
      .width('100%').height(48).padding({ left: 16, right: 16 })
      .border({ width: { bottom: 0.5 }, color: this.theme.divider }).alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          ForEach(this.groups, (g: ToolGroup) => {
            this.CatHeader(g)
            ForEach(g.tools, (t: ToolDef) => { this.SidebarRow(t) }, (t: ToolDef) => t.id)
          }, (g: ToolGroup) => g.name)
        }.width('100%').padding({ left: 8, right: 8, bottom: this.bottomSafeHeight + 8 })
      }.layoutWeight(1).width('100%').align(Alignment.Top)
    }
    .width(SIDEBAR_W).height('100%').backgroundColor(this.theme.bgSecondary)
    .border({ width: { right: 0.5 }, color: this.theme.divider })
  }

  @Builder
  CatHeader(g: ToolGroup) {
    Row({ space: 8 }) {
      Circle({ width: 8, height: 8 }).fill(g.color)
      Text(g.name).fontSize(11).fontColor(this.theme.textHint).fontFamily(MONO).fontWeight(FontWeight.Medium).letterSpacing(0.6)
    }
    .width('100%').padding({ left: 12, right: 12, top: 18, bottom: 8 }).alignItems(VerticalAlign.Center)
  }

  @Builder
  SidebarRow(t: ToolDef) {
    Row({ space: 12 }) {
      Circle({ width: 8, height: 8 }).fill(this.currentTool === t.id ? this.theme.primary : t.color)
      Text(t.name).layoutWeight(1).fontSize(15)
        .fontColor(this.currentTool === t.id ? this.theme.primary : this.theme.textPrimary)
        .fontWeight(this.currentTool === t.id ? FontWeight.Bold : FontWeight.Medium)
      Text('›').fontSize(16).fontColor(this.currentTool === t.id ? this.theme.primary : this.theme.textHint)
    }
    .width('100%').padding({ left: 12, right: 12, top: 11, bottom: 11 }).borderRadius(R_CHIP)
    .backgroundColor(this.currentTool === t.id ? this.theme.primaryLight : Color.Transparent)
    .alignItems(VerticalAlign.Center)
    .opacity(this.toolEnabled(t) ? 1 : 0.55)
    .onClick(() => { this.selectTool(t) })
  }

  @Builder
  ToolListView() {
    Scroll() {
      Column() {
        ForEach(this.groups, (g: ToolGroup) => {
          this.CatHeader(g)
          Column() {
            ForEach(g.tools, (t: ToolDef) => { this.ListRow(t) }, (t: ToolDef) => t.id)
          }
          .width('100%').backgroundColor(this.theme.bgCard).borderRadius(R_CARD)
          .margin({ left: 12, right: 12 })
          .clip(true)
        }, (g: ToolGroup) => g.name)
      }.width('100%').padding({ bottom: this.bottomSafeHeight + 16 })
    }.layoutWeight(1).width('100%').align(Alignment.Top)
  }

  @Builder
  ListRow(t: ToolDef) {
    Column() {
      Row({ space: 12 }) {
        Circle({ width: 8, height: 8 }).fill(t.color)
        Column({ space: 3 }) {
          Text(t.name).width('100%').fontSize(15).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Medium)
          Text(this.toolDescription(t)).width('100%').fontSize(12).fontColor(this.toolEnabled(t) ? this.theme.textSecondary : this.theme.textHint).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text('›').fontSize(16).fontColor(this.theme.textHint)
      }
      .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 14 }).alignItems(VerticalAlign.Center)
      .onClick(() => { this.selectTool(t) })
    }.width('100%')
  }

  @Builder
  DetailContent() {
    Column({ space: 18 }) {
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Circle({ width: 8, height: 8 }).fill(this.currentToolDef().color)
          Text(this.currentToolDef().cat).fontSize(11).fontColor(this.currentToolDef().color)
            .fontFamily(MONO).fontWeight(FontWeight.Medium).letterSpacing(0.6)
        }.alignItems(VerticalAlign.Center)
        Text(this.currentToolDef().name).fontSize(24).fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary)
        Text(this.toolDescription(this.currentToolDef())).width('100%').fontSize(14).fontColor(this.toolEnabled(this.currentToolDef()) ? this.theme.textSecondary : this.theme.textHint).lineHeight(21)
      }.width('100%').alignItems(HorizontalAlign.Start)

      if (this.currentTool === 'mobileglOverride' || this.currentTool === 'minecraftVulkanOverride') {
        this.GraphicsBackendInfo()
      }

      if (this.currentTool === 'phoneStorage') {
        this.MetaChips()
      }
      this.ActionArea()
      this.ConsoleView()
    }
    .width('100%').height('100%')
    .padding({ left: 20, right: 20, top: 18, bottom: this.bottomSafeHeight + 18 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  MetaChips() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(['FolderObtain = false', 'FolderAuth = true', '无需 persist / activate', 'FILE_ACCESS_PERSIST'],
        (c: string) => {
          Row() {
            Text(c).fontSize(11).fontColor(c.indexOf('persist / activate') >= 0 ? CAT_GRAPHICS : this.theme.textHint).fontFamily(MONO)
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(this.theme.bgInput).borderRadius(R_CHIP)
        }, (c: string) => c)
    }.width('100%')
  }

  @Builder
  ActionArea() {
    Row({ space: 10 }) {
      if (this.currentTool === 'download') {
        Button('1. 小文件 ~50KB').type(ButtonType.Capsule).fontSize(13).height(42)
          .fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.primary)
          .enabled(!this.isRunning).onClick(() => { this.runDownloadSmokeTest('small') })
        Button('2. 中文件 ~25MB').type(ButtonType.Capsule).fontSize(13).height(42)
          .fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.primary)
          .enabled(!this.isRunning).onClick(() => { this.runDownloadSmokeTest('medium') })
      } else {
        Button(this.currentToolDef().runLabel).type(ButtonType.Capsule).fontSize(14).height(42)
          .fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.primary)
          .enabled(!this.isRunning && this.toolEnabled(this.currentToolDef())).onClick(() => { this.runTool(this.currentToolDef()) })
      }
      Button('清空').type(ButtonType.Capsule).fontSize(14).height(42)
        .fontColor(this.theme.textSecondary).backgroundColor(this.theme.bgInput)
        .enabled(!this.isRunning && this.testResult.length > 0)
        .onClick(() => { this.testResult = ''; this.statusMsg = '就绪' })
      Blank()
      Text(this.statusMsg).fontSize(12).fontColor(this.theme.textHint).fontFamily(MONO).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width('100%').alignItems(VerticalAlign.Center)
  }

  @Builder
  ConsoleView() {
    Column() {
      Row({ space: 8 }) {
        Text('>_').fontSize(12).fontColor(CONSOLE_DIM).fontFamily(MONO)
        Text('控制台输出 · ' + this.currentToolDef().id).fontSize(11).fontColor(CONSOLE_DIM).fontFamily(MONO)
        Blank()
        Row({ space: 6 }) {
          Circle({ width: 7, height: 7 }).fill(this.statusColor())
          Text(this.statusLabel()).fontSize(11).fontColor(this.statusColor()).fontFamily(MONO).fontWeight(FontWeight.Bold)
        }.padding({ left: 9, right: 9, top: 4, bottom: 4 }).backgroundColor(this.statusBg()).borderRadius(20).alignItems(VerticalAlign.Center)
      }
      .width('100%').height(40).padding({ left: 14, right: 12 })
      .backgroundColor(CONSOLE_PANEL).alignItems(VerticalAlign.Center)

      Scroll() {
        Column({ space: 3 }) {
          if (this.testResult.length === 0) {
            Text('点击「' + this.currentToolDef().runLabel + '」开始（结果同时写入 hilog + amcl_launcher.log）')
              .width('100%').fontSize(12).fontColor(CONSOLE_DIM).fontFamily(MONO)
          } else {
            ForEach(this.consoleLines(), (ln: string, i: number) => {
              Text(ln.length === 0 ? ' ' : ln).width('100%')
                .fontSize(12).lineHeight(18).fontFamily(MONO).fontColor(this.lineColor(ln))
            }, (ln: string, i: number) => i.toString())
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).width('100%').align(Alignment.TopStart).padding({ left: 14, right: 14, top: 12, bottom: 12 })
    }
    .layoutWeight(1).width('100%').backgroundColor(CONSOLE_BG).borderRadius(R_CARD).clip(true)
  }

  // ==================== 状态派生（控制台状态胶囊 / 行着色）====================

  private isOk(): boolean {
    if (this.isRunning) return false
    return this.testResult.indexOf('NATIVE_RW_OK') >= 0 || this.testResult.indexOf('✅') >= 0
      || this.testResult.indexOf('成功') >= 0 || this.testResult.indexOf('完成') >= 0
  }

  private isFail(): boolean {
    if (this.isRunning || this.isOk()) return false
    return this.testResult.indexOf('❌') >= 0 || this.testResult.indexOf('失败') >= 0
      || this.testResult.indexOf('FAIL') >= 0 || this.testResult.indexOf('not permitted') >= 0
  }

  private statusLabel(): string {
    if (this.isRunning) return 'RUNNING'
    if (this.isOk()) return 'DONE'
    if (this.isFail()) return 'FAILED'
    return 'IDLE'
  }

  private statusColor(): string {
    if (this.isRunning) return RUN_AMBER
    if (this.isOk()) return CONSOLE_GREEN
    if (this.isFail()) return CONSOLE_RED
    return CONSOLE_DIM
  }

  private statusBg(): string {
    if (this.isOk()) return OK_BG
    if (this.isFail()) return ERR_BG
    return '#1C2230'
  }

  private consoleLines(): string[] {
    return this.testResult.length === 0 ? [] : this.testResult.split('\n')
  }

  private lineColor(ln: string): string {
    if (ln.indexOf('NATIVE_RW_OK') >= 0 || ln.indexOf('✅') >= 0 || ln.indexOf(' OK') >= 0 || ln.indexOf('成功') >= 0) return CONSOLE_GREEN
    if (ln.indexOf('❌') >= 0 || ln.indexOf('FAIL') >= 0 || ln.indexOf('失败') >= 0 || ln.indexOf('异常') >= 0 || ln.indexOf('not permitted') >= 0) return CONSOLE_RED
    if (ln.startsWith('===') || ln.startsWith('0)') || ln.startsWith('1)') || ln.indexOf('设备能力') >= 0) return CONSOLE_DIM
    return CONSOLE_FG
  }

  // ==================== 运行逻辑（保持原有行为）====================

  /**
   * 工具分派（批次 D4 后）。
   *
   * ⭐ 单条 NAPI 探针一律走 `nativeProbeRegistry()` 这张表 —— 页面按钮与未来的
   * 自动化/应用内 agent **共用同一行代码**（契约 §1.1 同路径）。这里只做
   * "选哪个 id"，"怎么跑"在 `runProbe` 的纯分派里。
   *
   * 留在本页的四类不是探针：`mobileglOverride` 是写偏好的开关（mutating）、
   * `fs` / `storage` / `phoneStorage` 是带 picker 的多步页面流程（契约 §3.9 的边界）、
   * `download` 走 DownloadManager 的端到端 smoke、
   * `navigate` 类只是跳页面。
   */
  private runTool(t: ToolDef) {
    const probe: NativeProbeDef | null = findProbe(nativeProbeRegistry(), t.id)
    if (probe !== null) {
      this.runRegisteredProbe(probe); return
    }
    switch (t.id) {
      case 'mobileglOverride':
        this.toggleMobileglOverride(); break
      case 'minecraftVulkanOverride':
        this.toggleMinecraftVulkanOverride(); break
      case 'fs':
        this.runFsProbe(); break
      case 'storage':
        this.runStorageProbeAction(); break
      case 'phoneStorage':
        this.runPhoneStorageProbeAction(); break
      default:
        break
    }
  }

  /**
   * 跑注册表里的一条探针并把结果贴到控制台。
   *
   * ⚠️ 这里**不解释**探针的输出：`ipv6` 之类的诊断型探针没有"通过/失败"，
   * 结论在报告末尾的逐条判据行。顶部状态胶囊只表示"跑完了"，
   * 这条既有语义在 D4 之后保持不变。
   */
  private runRegisteredProbe(probe: NativeProbeDef) {
    this.isRunning = true
    this.statusMsg = '正在运行...'
    this.testResult = '测试启动中...\n'
    runProbe(probe, this.context.filesDir).then((outcome: ProbeOutcome) => {
      if (outcome.error !== null) {
        this.testResult = '测试异常: ' + outcome.error
        this.statusMsg = '测试出错!'
        AppLogger.error(probe.id, 'probe error: ' + outcome.error, LOG_DOMAIN)
      } else {
        this.testResult = outcome.text
        this.statusMsg = probe.title + ' 完成!'
        AppLogger.info(probe.id, probe.title + ' done', LOG_DOMAIN)
      }
      this.isRunning = false
    })
  }

  /**
   * MobileGL optional peer 的兼容开发覆盖开关（早期通道见施工记录 §S14）。
   *
   * 写 `PreferenceManager.devRendererOverride`（'' ↔ 'mobilegl'），下次启动 MC 时
   * McGamePage 把它递进 LaunchProfileBuilder，解析器对 optional/candidate/experimental 放行、
   * 且仍受强制规则（≤1.16.5 → gl4es）与现代管线判据（≥1.17）约束。
   * 覆盖生效与否以启动日志 `Renderer route: mobilegl — dev override ...` 为准。
   */
  private toggleMobileglOverride() {
    const pref = new PreferenceManager(this.context)
    const now: string = pref.devRendererOverride
    const next: string = now === 'mobilegl' ? '' : 'mobilegl'
    pref.devRendererOverride = next
    const lines: string[] = []
    lines.push('== MobileGL OpenGL peer 覆盖 ==')
    lines.push(`devRendererOverride: '${now}' -> '${next}'`)
    if (next === 'mobilegl') {
      lines.push('')
      lines.push('已请求：下次启动 SDL3 路线的 MC 时检查 MobileGL 能力，通过后启用；GLFW 路线按 provider 不匹配回退。')
      lines.push('profile=mobilegl api=OPENGL，native 路由到 libmobilegl.so（DirectVulkan transport）。')
      lines.push('')
      lines.push('前置：安装显式携带 MobileGL 的验证包。')
      lines.push('  pwsh -File build-hap.ps1 -IncludeMobileGL')
      lines.push('  产物缺失、着色器或呈现检查失败时不会取得 MobileGL 准入。')
      lines.push('验证判据：hilog 里 AMCL_RENDERER backend=mobilegl lib=libmobilegl.so')
      lines.push('  + GL_VERSION 含 "MobileGL ... Direct (Vulkan) Backend"。')
    } else {
      lines.push('')
      lines.push('已关闭：恢复常规路由（默认 mobileglues / 版本强制 gl4es）。')
    }
    this.testResult = lines.join('\n')
    this.statusMsg = next === 'mobilegl' ? 'MobileGL peer 覆盖：开' : 'MobileGL peer 覆盖：关'
    AppLogger.info('DevTools', `mobilegl dev override -> '${next}'`, LOG_DOMAIN)
  }

  private snapshotProfile(): GraphicsProfileSpec {
    const selected: string = this.prefManager.devRendererOverride.length > 0
      ? this.prefManager.devRendererOverride : this.prefManager.graphicsProfile
    const fallback: GraphicsProfileSpec = graphicsProfileByRole(GraphicsSelectionRole.Default)
    return graphicsProfileById(selected) ?? fallback
  }

  private snapshotSelected(): string {
    return this.prefManager.devRendererOverride.length > 0
      ? this.prefManager.devRendererOverride : this.prefManager.graphicsProfile
  }

  @Builder
  GraphicsBackendInfo() {
    Column({ space: 5 }) {
      Text('当前图形选择快照').fontSize(12).fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary)
      Text('规范 profile：' + (this.prefManager.graphicsProfile.length > 0 ? this.prefManager.graphicsProfile : 'auto'))
        .fontSize(12).fontFamily(MONO).fontColor(this.theme.textSecondary)
      Text('开发覆盖：' + (this.prefManager.devRendererOverride.length > 0 ? this.prefManager.devRendererOverride : '无'))
        .fontSize(12).fontFamily(MONO).fontColor(this.theme.textSecondary)
      Text('保存偏好：' + (this.snapshotSelected().length > 0 ? this.snapshotSelected() : 'auto') + ' · 偏好条目：' + this.snapshotProfile().id + ' · 产品：' + ProductBuildProfile.product)
        .fontSize(12).fontFamily(MONO).fontColor(CAT_GRAPHICS)
      Text('api=' + this.snapshotProfile().api + ' · provider=' + this.snapshotProfile().windowProviders.join('/') + ' · transport=' + this.snapshotProfile().transport
        + ' · capability=' + this.snapshotProfile().capabilityKind)
        .fontSize(12).fontFamily(MONO).fontColor(this.theme.textSecondary)
      Text('lifecycle=' + this.snapshotProfile().lifecycle + ' · admission=' + this.snapshotProfile().admission + ' · restart=' + String(this.snapshotProfile().restartRequired)
        + ' · artifact=' + (this.snapshotProfile().id === 'mobilegl' ? (this.mobileglPackaged ? 'present' : 'missing') : 'n/a'))
        .fontSize(12).fontFamily(MONO).fontColor(this.theme.textSecondary)
      Text('fallback=' + graphicsProfileByRole(GraphicsSelectionRole.Default).id + ' · requirement=' + this.snapshotProfile().requirementId)
        .fontSize(12).fontFamily(MONO).fontColor(this.theme.textSecondary)
      Text('这里显示偏好与注册信息。本次采用的后端由启动计划锁存；游戏实际 API 与底层实现以呈现日志为准。')
        .fontSize(12).fontColor(this.theme.textHint).width('100%')
      Text('验证时看 hilog：Renderer route → graphics_plan_capability_admitted → AMCL_RENDERER → 游戏实际 driver。')
        .fontSize(12).fontColor(this.theme.textHint).width('100%')
    }.width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor(this.theme.bgInput).borderRadius(R_CARD)
      .alignItems(HorizontalAlign.Start)
  }

  private toggleMinecraftVulkanOverride(): void {
    const preferences: PreferenceManager = new PreferenceManager(this.context)
    const enabled: boolean = preferences.devRendererOverride !== 'minecraft-vulkan'
    preferences.devRendererOverride = enabled ? 'minecraft-vulkan' : ''
    this.statusMsg = enabled ? 'Minecraft Vulkan 候选：开' : 'Minecraft Vulkan 候选：关'
    this.testResult = enabled
      ? '已请求 Minecraft Vulkan 候选。\n下次启动对清单确认的 26.2 GLFW 或 26.3 SDL3 版本检查原生 Vulkan 准入。\n缺少设备特性、窗口呈现支持或运行库时不会启用。\n游戏是否实际使用 Vulkan 以游戏初始化和呈现记录为准；此开关不修改游戏内偏好。'
      : '已关闭 Minecraft Vulkan 候选请求，恢复常规图形计划。'
    AppLogger.info('DevTools', 'minecraft-vulkan development request=' + String(enabled), LOG_DOMAIN)
  }

  // executeTest / runJvmEmbed 已随批次 D4 删除：它们的全部调用点都改走
  // nativeProbeRegistry() + runProbe 的纯分派（同一条实现，页面与自动化共用）。
  // 删掉而不是留着的理由是 `AGENTS.md` §二.6 —— 留一个没人调的旧执行路径，
  // 下一个人会以为探针有两条通路，而其中一条永远不会被跑到。

  /** 下载引擎 smoke test：'small'=50KB JSON，'medium'=25MB JAR。 */
  private runDownloadSmokeTest(mode: string) {
    this.isRunning = true
    this.statusMsg = `正在下载测试（${mode}）...`
    let lines: string[] = []
    let appendLine = (s: string) => {
      lines.push(s)
      if (lines.length > 200) lines.shift()
      this.testResult = lines.join('\n')
    }
    appendLine(`[${new Date().toLocaleTimeString()}] 开始 ${mode} 测试`)
    appendLine(`filesDir = ${this.context.filesDir}`)
    let mgr = DownloadManager.instance()
    if (!mgr.isCaBundleInitialized()) {
      appendLine('初始化 CA bundle (抽 rawfile/cacert.pem)...')
      mgr.initializeCaBundle(this.context)
      appendLine(mgr.isCaBundleInitialized() ? '  ✓ CA bundle 就绪' : '  ✗ CA bundle 初始化失败（见 hilog）')
    }
    let targetTaskId = -1
    let listener = (v: DownloadTaskView) => {
      if (v.taskId !== targetTaskId) return
      if (!v.finished) {
        let pct = Math.floor(v.progress * 100)
        let lastLine = lines[lines.length - 1] || ''
        let line = `  ${v.state} ${pct}% ${formatBytes(v.bytesDone)}`
          + (v.bytesTotal > 0 ? `/${formatBytes(v.bytesTotal)}` : '')
          + ` @${formatSpeed(v.speedBps)} threads=${v.activeThreads}`
          + ` file=${v.filesDone}/${v.filesTotal}`
        if (!lastLine.startsWith('  ')) {
          lines.push(line)
        } else {
          lines[lines.length - 1] = line
        }
        this.testResult = lines.join('\n')
      } else {
        if (v.success) {
          appendLine(`[${new Date().toLocaleTimeString()}] ✅ 成功`)
          appendLine(`  已完成文件: ${v.filesDone}/${v.filesTotal}`)
          appendLine(`  总下载: ${formatBytes(v.bytesDone)}`)
          appendLine(`  用时: ${((v.finishedAt - v.createdAt) / 1000).toFixed(1)}s`)
          appendLine(`  保存位置: ${v.currentFile || '(见 filesDir)'}`)
        } else {
          appendLine(`[${new Date().toLocaleTimeString()}] ❌ 失败`)
          appendLine(`  错误类型: ${v.errorKind}`)
          appendLine(`  错误详情: ${v.errorMessage}`)
        }
        this.statusMsg = v.success ? '下载测试完成!' : '下载测试失败'
        this.isRunning = false
        mgr.removeListener(listener)
      }
    }
    mgr.addListener(listener)
    try {
      targetTaskId = mode === 'small' ? mgr.runSmokeTestSmall(this.context.filesDir) : mgr.runSmokeTestMedium(this.context.filesDir)
      appendLine(`taskId = ${targetTaskId}`)
    } catch (error) {
      appendLine(`❌ 启动异常: ${formatError(error)}`)
      this.statusMsg = '测试启动失败'
      this.isRunning = false
      mgr.removeListener(listener)
      AppLogger.error('DL_SMOKE', 'download smoke test error', error, LOG_DOMAIN)
    }
  }

  /** 沙箱 FS 探针。 */
  private runFsProbe() {
    this.isRunning = true
    this.statusMsg = '正在运行 FS 探针（可能需 5~20 秒）...'
    this.testResult = '⏳ 探针启动中...\n  - 在 filesDir/sandbox-probe-<sid>/ 下创建临时目录\n  - 顺序执行 8 项测试（含 50MB 文件 rename 与 copy 对比）\n  - 完成后自动清理\n'
    runFsRenameProbe(this.context.filesDir)
      .then((report: FsProbeReport) => {
        this.testResult = formatReport(report)
        this.statusMsg = 'FS 探针完成!'
        this.isRunning = false
        AppLogger.info('FS_PROBE', `Probe completed, ${report.tests.length} tests`, LOG_DOMAIN)
      })
      .catch((e: Error) => {
        this.testResult = '❌ 探针异常: ' + (e && e.message ? e.message : formatError(e))
        this.statusMsg = 'FS 探针失败!'
        this.isRunning = false
        AppLogger.error('FS_PROBE', 'Probe failed', e, LOG_DOMAIN)
      })
  }

  /** 平板沙箱外存储探针。 */
  private runStorageProbeAction() {
    this.isRunning = true
    this.statusMsg = '正在运行存储探针...'
    this.testResult = '⏳ 探针启动中（请在弹窗里允许权限）...\n'
    runStorageProbe(this.context)
      .then((res: StorageProbeResult) => {
        this.testResult = res.report
        this.statusMsg = '存储探针完成: ' + res.verdict
        this.isRunning = false
        AppLogger.info('STORAGE_PROBE', `verdict=${res.verdict}`, LOG_DOMAIN)
      })
      .catch((e: Error) => {
        this.testResult = '❌ 探针异常: ' + formatError(e)
        this.statusMsg = '存储探针失败'
        this.isRunning = false
        AppLogger.error('STORAGE_PROBE', 'storage probe error', e, LOG_DOMAIN)
      })
  }

  /** 手机沙箱外存储探针（picker DOWNLOAD + native POSIX + 跨重启）。 */
  private runPhoneStorageProbeAction() {
    this.isRunning = true
    this.statusMsg = '正在运行手机存储探针...'
    this.testResult = '⏳ 探针启动中（picker DOWNLOAD 模式应无弹窗直接返回）...\n'
    runPhoneStorageProbe(this.context)
      .then((res: PhoneStorageProbeResult) => {
        this.testResult = res.report
        this.statusMsg = '手机存储探针完成: ' + res.verdict
        this.isRunning = false
        AppLogger.info('PHONE_STORAGE_PROBE', `verdict=${res.verdict}`, LOG_DOMAIN)
      })
      .catch((e: Error) => {
        this.testResult = '❌ 探针异常: ' + formatError(e)
        this.statusMsg = '手机存储探针失败'
        this.isRunning = false
        AppLogger.error('PHONE_STORAGE_PROBE', 'phone storage probe error', e, LOG_DOMAIN)
      })
  }
}
