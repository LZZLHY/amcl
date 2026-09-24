/**
 * SheetSizes.ets — bindSheet 高度统一辅助
 *
 * 鸿蒙 NEXT 的 SheetSize 三档（MEDIUM ≈ 50% / LARGE ≈ 90% / FIT_CONTENT）颗粒度太粗：
 *   - LARGE 几乎贴顶，跟全屏页很难视觉区分
 *   - MEDIUM 在内容多时（详情 / 版本管理）严重滚动焦虑
 *
 * 详情类 sheet 统一走 80% 安全区高（避开状态栏 + 底部导航条），既留 20% 背景上下文，
 * 又有足够空间放 hero + 内容卡 + sticky CTA。height: '80%' 是基于全屏；这里换算成 vp
 * 数字（屏幕高 - top safe - bottom safe）* 0.8，更接近用户感知。
 *
 * 历史：
 *   - v1 (2026-05-17) 70%：早期偏保守，详情 sheet 内容多时仍滚动焦虑
 *   - v2 (2026-05-18) 80%：用户反馈想看到更多内容，且与设计稿 mock 更贴近
 *
 * 注意：DownloadSheet / ModDownloadSheet（下载进度类）**不走本函数**，
 *      它们用 `SheetSize.MEDIUM` 因为只展示进度条 + 几个 stat，内容固定，
 *      不需要那么高，反而占太多屏幕会让 FAB 进度提示失去"轻量浮层"的语义。
 *
 * 使用：
 *   .bindSheet($$this.show, this.Builder(), {
 *     height: detailSheetHeight(this.bottomSafeHeight, this.topSafeHeight),
 *     ...
 *   })
 */

import { Breakpoint, DeviceForm } from './device/DeviceProfile';

/**
 * 详情类 sheet 推荐高度（vp）：屏幕安全区 80%。
 *
 * 调用方负责传入 `topSafeHeight / bottomSafeHeight`（来自 EntryAbility 写入 AppStorage 的
 * 'topRectHeight' / 'bottomRectHeight'）。fallback 用 800 vp（典型手机 ~ 1280×720dp 的可视区）。
 *
 * 2026-05-23 API NEXT 迁移：旧实现在工具函数里调全局 `px2vp(d.height)` 把屏幕
 * 高度从 px 转成 vp，这两个 API 都已弃用（API 18+），且工具函数没有 UIContext
 * 可用。改成由 EntryAbility.onWindowStageCreate 期把 `screenHeightVp` 写入
 * AppStorage（详见 entryability/EntryAbility.ets 与 docs/guides/api-migration-2026-05.md），
 * 工具函数直接读缓存。
 */
export function detailSheetHeight(bottomSafeHeight: number, topSafeHeight: number): number {
  // EntryAbility 在 onWindowStageCreate 里把 vp 形式的屏幕高度缓存到这个 key。
  // 单测/极少数 EntryAbility 还没 ready 的场景下回退兜底 800 vp。
  let screenH = AppStorage.get<number>('screenHeightVp') ?? 800;
  if (screenH <= 0) screenH = 800;
  let safeH = screenH - topSafeHeight - bottomSafeHeight;
  if (safeH <= 0) safeH = screenH;
  return Math.round(safeH * 0.8);
}

/**
 * 加大尺寸 sheet 推荐高度（vp）：屏幕安全区 92%。
 *
 * 用途（项目里**唯一**用到这个的就是登录流）：
 *   - AddAccountSheet（含 Microsoft OAuth WebView）
 *
 * 其他详情 / 设置类 sheet 一律走 detailSheetHeight (80%) 保持视觉节奏一致；
 * 加高 12% 只给"内嵌 WebView 必须高才好用"的场景。
 *
 * 选 92% 而不是 SheetSize.LARGE：
 *   原生 LARGE 几乎贴到状态栏底（>= 95%），跟全屏页视觉无区别；92% 留 ~8%
 *   背景给"这是一个 sheet"的语义，又比 detailSheetHeight 的 80% 高出整整 12%
 *   ——足够把 Microsoft 登录卡片完整露出 + 底部 ArkWeb 提示栏不被裁。
 *
 * 同样的"先读 AppStorage 缓存的 screenHeightVp"逻辑见 detailSheetHeight。
 */
export function largeSheetHeight(bottomSafeHeight: number, topSafeHeight: number): number {
  let screenH = AppStorage.get<number>('screenHeightVp') ?? 800;
  if (screenH <= 0) screenH = 800;
  let safeH = screenH - topSafeHeight - bottomSafeHeight;
  if (safeH <= 0) safeH = screenH;
  return Math.round(safeH * 0.92);
}

/**
 * 三 Tab 滚动内容应预留的"悬浮 dock 占高"（vp）。
 *
 * 2026-05-24：底部从 Tabs 内置 bar (52 + safe) → 鸿蒙沉浸光感 FloatingDock 之后，
 * 每个 Tab 的 Scroll 内容 padding.bottom 都需要预留这个高度，否则最后一项会被
 * dock 盖住。组成：
 *
 *   FloatingDock 高度 = 60vp（pill 高）
 *   FloatingDock 离 home indicator 余量 = 10vp（设计美感）
 *   home indicator 安全区 = bottomSafeHeight（设备相关，典型 ~30vp）
 *   视觉缓冲（最后一项不贴 dock 上沿）= 8vp
 *   合计 = 78 + bottomSafeHeight
 *
 * 这个值由 Index.ets 算好之后透传到 HomeTab / DownloadTab / SettingsTab，
 * 仅用于 Scroll/List 的内容尾部，不可用于视口 margin 或固定根布局的 padding，
 * 否则会在 dock 上方产生截断空带。首页竖屏的余量放在最近活动内部 Scroll。
 */
export function floatingDockReserveHeight(bottomSafeHeight: number): number {
  return 78 + bottomSafeHeight;
}

// ============================================================
//  一多适配（平板/PC 宽屏）：sheet 呈现形态决策
//
//  鸿蒙 bindSheet 的 SheetType 三档：BOTTOM（底部抽屉）/ CENTER（居中悬浮卡片）/
//  POPUP（气泡，需锚定真实节点——本项目 sheet 全绑零尺寸隐藏锚点会错位，故不用）。
//
//  ⚠ 关键约束（踩坑记录 2026-06-15）：
//   1. 系统按**窗口宽度**决定支持的类型：< 600vp 只支持 BOTTOM；≥ 600vp 才支持 CENTER/POPUP。
//   2. 但**手机形态（DeviceForm.PHONE）即使横屏窗口 ≥ 600vp，系统仍以 BOTTOM 呈现**。
//      若此时仍把 `width` 传给它 → 会得到一张「底部超宽 sheet」（type 没变、宽度却被改）。
//   ∴ 决策必须**叠加 deviceForm 判定**，对齐本项目既有一多约定（见 HomeTab.isWideLayout：
//      `deviceForm !== PHONE && appBreakpoint === LG`，注释"避免手机横屏误触发"）：
//      仅「非手机形态 + 窗口 ≥ 600vp」才用 CENTER 并限宽；其余一律 BOTTOM 且**不传 width**。
//
//  设计原则同 DeviceProfile：决策逻辑（形态/断点 → 呈现/尺寸）是纯公共能力、不含 UI 枚举，
//  调用点把布尔/数值映射成 `SheetType` / `width` / `height`。deviceForm 与 appBreakpoint
//  均由 Index `@Provide` 下沉、子树 `@Consume` 取得。
// ============================================================

/**
 * 一多：当前形态+断点下 sheet 是否应以「居中悬浮卡片」呈现。
 * - 手机形态（含横屏宽窗口）→ false → 底部抽屉 `SheetType.BOTTOM`（系统强制，且避免误加宽度）
 * - 平板 / PC 且窗口 ≥ 600vp（MD/LG）→ true → 居中卡片 `SheetType.CENTER`
 *
 * 调用：`preferType: centerSheetForLayout(form, bp) ? SheetType.CENTER : SheetType.BOTTOM`
 */
export function centerSheetForLayout(form: DeviceForm, bp: Breakpoint): boolean {
  return form !== DeviceForm.PHONE && bp !== Breakpoint.SM;
}

/**
 * 一多：sheet 宽度（vp）。
 * - 非居中卡片（手机 / 窄窗口）→ `undefined`：**务必不传 width**，否则底部抽屉会被改成超宽。
 * - 居中卡片：MD 520 / LG 600（再宽内容显空旷）。
 */
export function sheetWidthForLayout(form: DeviceForm, bp: Breakpoint): number | undefined {
  if (!centerSheetForLayout(form, bp)) return undefined;
  return bp === Breakpoint.LG ? 600 : 520;
}

/**
 * 一多：sheet 高度（vp）。
 * - 非居中卡片（底部抽屉）：沿用 `detailSheetHeight`（安全区 80%）。
 * - 居中卡片：在 80% 安全区基础上封顶 640vp，避免平板上一张超高窄卡。
 *
 * 登录类（largeSheetHeight 92%）由调用点单独处理，不走本函数。
 */
export function detailSheetHeightForLayout(form: DeviceForm, bp: Breakpoint, bottomSafeHeight: number, topSafeHeight: number): number {
  const base = detailSheetHeight(bottomSafeHeight, topSafeHeight);
  if (!centerSheetForLayout(form, bp)) return base;
  return Math.min(base, 640);
}

/**
 * 一多：登录类 sheet 高度（vp）。底部抽屉沿用 `largeSheetHeight`（92%，给 OAuth WebView）；
 * 居中卡片封顶 720vp（比普通详情 640 略高，容纳登录卡片，又不至于在平板上过高）。
 */
export function largeSheetHeightForLayout(form: DeviceForm, bp: Breakpoint, bottomSafeHeight: number, topSafeHeight: number): number {
  const base = largeSheetHeight(bottomSafeHeight, topSafeHeight);
  if (!centerSheetForLayout(form, bp)) return base;
  return Math.min(base, 720);
}
