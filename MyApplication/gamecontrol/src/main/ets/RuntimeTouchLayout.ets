/**
 * 触控运行时几何的纯投影：存档保持原样，UI、Native、教学和抽屉消费同一组有界矩形。
 * 平台只传已采样的surface事实；本文件不读取默认display，不调用NAPI，也不持有输入owner。
 */
import { ControlItem, ControlType, LayoutProfile, cloneItem, isVisibleInScene, hasControlAction } from './ControlLayout'
import { InputSurfaceContext, INPUT_SURFACE_FIELD_DENSITY, INPUT_SURFACE_FIELD_RECT } from './InputSurfaceContext'
import { GameGuiState, projectGameHotbar } from './GameGuiGeometry'
import { TouchControlRect, touchControlRect } from './TouchControlGeometry'

/** 一次投影固定的解释单位；density/transform变化即使px视口不变也有不同身份。 */
export class RuntimeTouchContext {
  surfaceGeneration: number = 0
  widthPx: number = 0
  heightPx: number = 0
  density: number = 0
  transform: number = 0
  valid: boolean = false
  key: string = ''

  widthVp(): number { return this.valid ? this.widthPx / this.density : 0 }
  heightVp(): number { return this.valid ? this.heightPx / this.density : 0 }
}

/** 测量值只在Window尚未发布时作为同一UIContext的暂定事实，权威字段缺失时禁止回退。 */
export function runtimeTouchContext(surface: InputSurfaceContext, widthVp: number,
  heightVp: number, measuredDensity: number): RuntimeTouchContext {
  const context = new RuntimeTouchContext()
  context.surfaceGeneration = surface.generation
  context.transform = surface.transform
  context.density = surface.has(INPUT_SURFACE_FIELD_DENSITY) ? surface.density :
    (surface.provisional ? measuredDensity : 0)
  context.widthPx = surface.has(INPUT_SURFACE_FIELD_RECT) ? surface.widthPx :
    (surface.provisional ? widthVp * context.density : 0)
  context.heightPx = surface.has(INPUT_SURFACE_FIELD_RECT) ? surface.heightPx :
    (surface.provisional ? heightVp * context.density : 0)
  context.valid = Number.isFinite(context.density) && context.density > 0 &&
    Number.isFinite(context.widthPx) && context.widthPx > 0 &&
    Number.isFinite(context.heightPx) && context.heightPx > 0
  context.key = [surface.generation, surface.windowId, surface.displayId, context.widthPx,
    context.heightPx, context.density, context.transform, surface.provisional].join(':')
  return context
}

/** 运行时夹取同时供UI和Native使用；越界/过大不写回用户布局，NaN不进入协议。 */
export function clampRuntimeTouchRect(rect: TouchControlRect, width: number, height: number): TouchControlRect {
  const result = new TouchControlRect()
  result.width = Math.min(width, Number.isFinite(rect.width) && rect.width > 0 ? rect.width : 1)
  result.height = Math.min(height, Number.isFinite(rect.height) && rect.height > 0 ? rect.height : 1)
  result.x = Math.max(0, Math.min(width - result.width, Number.isFinite(rect.x) ? rect.x : 0))
  result.y = Math.max(0, Math.min(height - result.height, Number.isFinite(rect.y) ? rect.y : 0))
  return result
}

/**
 * 模式0全显、1菜单、2隐藏；强显覆盖场景/全局档，但不覆盖显式隐藏、解绑或仅游戏控件的能力边界。
 * 先消除无效热区，再处理用户强显；鼠标入口与其它系统工具共用该规则，只有恢复显隐入口跳过全局档。
 */
export function runtimeTouchControlVisible(item: ControlItem, grabbed: boolean, visibility: number): boolean {
  if (item.hidden || (item.visibilityOverride ?? 'auto') === 'force_hide') return false
  if (item.type === ControlType.BUTTON && item.systemAction === undefined && !hasControlAction(item)) return false
  if ((item.visibilityOverride ?? 'auto') === 'force_show') return grabbed ||
    (item.type !== ControlType.JOYSTICK && item.type !== ControlType.SCROLL_WHEEL && item.type !== ControlType.HOTBAR_SELECTOR)
  if (item.systemAction === 'visibility') return isVisibleInScene(item, grabbed)
  if (visibility === 2) return false
  if (visibility === 1) return isVisibleInScene(item, false) && item.type !== ControlType.JOYSTICK &&
    item.type !== ControlType.SCROLL_WHEEL && item.type !== ControlType.HOTBAR_SELECTOR
  if (!isVisibleInScene(item, grabbed)) return false
  return grabbed || (item.type !== ControlType.JOYSTICK && item.type !== ControlType.SCROLL_WHEEL &&
    item.type !== ControlType.HOTBAR_SELECTOR)
}

/** 同一稳定control ID的有效几何；parentId非空时是展开抽屉的BUTTON。 */
export class RuntimeTouchEntry {
  item: ControlItem
  parentId: string = ''
  childIndex: number = -1
  rectPx: TouchControlRect = new TouchControlRect()
  rectVp: TouchControlRect = new TouchControlRect()
  handledBy: number = 0
  hitSlopPx: number = 0
  constructor(item: ControlItem) { this.item = cloneItem(item) }
}

/** 不可变候选的汇总投影。Native根是entries/controls的共同前缀，保证摇杆视觉下标一致；
 * UI根及其抽屉孩子随后绘制。跨解释域按UI优先，但Native域内命中仍保留最近中心，不等同于全部Z总序。
 */
export class RuntimeTouchLayout {
  context: RuntimeTouchContext = new RuntimeTouchContext()
  entries: RuntimeTouchEntry[] = []
  controls: ControlItem[] = []
  overlays: RuntimeTouchOverlay[] = []
  find(id: string): RuntimeTouchEntry | undefined {
    return this.entries.find((entry: RuntimeTouchEntry): boolean => entry.item.id === id)
  }
}

/** GUI/兼容性提示仍是独立UI职责，矩形同样进入冻结候选和布局确认。 */
export class RuntimeTouchOverlay {
  id: string = ''
  role: string = ''
  rectPx: TouchControlRect = new TouchControlRect()
  rectVp: TouchControlRect = new TouchControlRect()
}

/** overlay只投影一次；role供UI查找，稳定id由调用者避让整个schema命名空间。 */
export function appendRuntimeTouchOverlay(layout: RuntimeTouchLayout, id: string, role: string,
  vp: TouchControlRect): RuntimeTouchOverlay {
  const overlay = new RuntimeTouchOverlay()
  overlay.id = id; overlay.role = role
  const context: RuntimeTouchContext = layout.context
  const px = new TouchControlRect()
  px.x=vp.x*context.density; px.y=vp.y*context.density
  px.width=vp.width*context.density; px.height=vp.height*context.density
  overlay.rectPx=clampRuntimeTouchRect(px,context.widthPx,context.heightPx)
  overlay.rectVp.x=overlay.rectPx.x/context.density; overlay.rectVp.y=overlay.rectPx.y/context.density
  overlay.rectVp.width=overlay.rectPx.width/context.density; overlay.rectVp.height=overlay.rectPx.height/context.density
  layout.overlays.push(overlay)
  return overlay
}

/** 快照不向调用方借出矩形/数组/嵌套控件；候选冻结和UI读取均使用此显式复制。 */
export function cloneRuntimeTouchLayout(source: RuntimeTouchLayout): RuntimeTouchLayout {
  const value = new RuntimeTouchLayout()
  value.context=copyRuntimeContext(source.context)
  for (const entry of source.entries) {
    const copy = new RuntimeTouchEntry(entry.item)
    copy.parentId=entry.parentId; copy.childIndex=entry.childIndex
    copy.handledBy=entry.handledBy; copy.hitSlopPx=entry.hitSlopPx
    copy.rectPx=copyRuntimeRect(entry.rectPx); copy.rectVp=copyRuntimeRect(entry.rectVp)
    value.entries.push(copy)
  }
  for (const item of source.controls) value.controls.push(value.find(item.id)?.item ?? cloneItem(item))
  for (const overlay of source.overlays) {
    const copy = new RuntimeTouchOverlay()
    copy.id=overlay.id; copy.role=overlay.role
    copy.rectPx=copyRuntimeRect(overlay.rectPx); copy.rectVp=copyRuntimeRect(overlay.rectVp)
    value.overlays.push(copy)
  }
  return value
}

function copyRuntimeRect(source: TouchControlRect): TouchControlRect {
  const value = new TouchControlRect()
  value.x=source.x; value.y=source.y; value.width=source.width; value.height=source.height
  return value
}

/** context随候选复制，不借用平台后续采样会改写的输入对象。 */
function copyRuntimeContext(source: RuntimeTouchContext): RuntimeTouchContext {
  const value = new RuntimeTouchContext()
  value.surfaceGeneration=source.surfaceGeneration
  value.widthPx=source.widthPx; value.heightPx=source.heightPx
  value.density=source.density; value.transform=source.transform
  value.valid=source.valid; value.key=source.key
  return value
}

/** 从vp计算一次px矩形，再从这个px矩形反推UI位置与尺寸，消除Native单边夹取。 */
function projectedEntry(item: ControlItem, profile: LayoutProfile, context: RuntimeTouchContext,
  vp: TouchControlRect): RuntimeTouchEntry {
  const entry = new RuntimeTouchEntry(item)
  const px = new TouchControlRect()
  px.x = vp.x * context.density; px.y = vp.y * context.density
  px.width = vp.width * context.density; px.height = vp.height * context.density
  entry.rectPx = clampRuntimeTouchRect(px, context.widthPx, context.heightPx)
  entry.rectVp.x = entry.rectPx.x / context.density; entry.rectVp.y = entry.rectPx.y / context.density
  entry.rectVp.width = entry.rectPx.width / context.density; entry.rectVp.height = entry.rectPx.height / context.density
  entry.item.xPct = entry.rectPx.x / context.widthPx; entry.item.yPct = entry.rectPx.y / context.heightPx
  entry.item.baseWidth = entry.rectVp.width / (profile.globalScale * entry.item.itemScale)
  entry.item.baseHeight = entry.rectVp.height / (profile.globalScale * entry.item.itemScale)
  entry.handledBy = item.systemAction !== undefined || item.type === ControlType.DRAWER ? 1 : 0
  entry.hitSlopPx = entry.handledBy === 1 || item.type === ControlType.HOTBAR_SELECTOR ? 0 :
    (item.type === ControlType.JOYSTICK ? 12 : 8) * context.density
  return entry
}

/** 自动快捷栏和展开抽屉均在这里完成；子控件只支持现行BUTTON能力，不在运行时伪造其它类型。 */
export function projectRuntimeTouchLayout(profile: LayoutProfile, context: RuntimeTouchContext,
  gui: GameGuiState, grabbed: boolean, visibility: number, drawers: Map<string, boolean>): RuntimeTouchLayout {
  const layout = new RuntimeTouchLayout()
  layout.context = copyRuntimeContext(context)
  if (!context.valid) return layout
  const width: number = context.widthVp(), height: number = context.heightVp()
  const controls: ControlItem[] = projectGameHotbar(profile, profile.controls, gui, width, height)
  const roots: RuntimeTouchEntry[] = []
  for (const item of controls) {
    if (!runtimeTouchControlVisible(item, grabbed, visibility)) continue
    const entry: RuntimeTouchEntry = projectedEntry(item, profile, context, touchControlRect(item, profile, width, height))
    roots.push(entry)
  }
  // UI专属矩形必须同时是视觉上层和Native排除域。只稳定分层运行时根，绝不重排用户存档；
  // 每个域内保持原顺序，故Native等距先项和UI原兄弟顺序不变。所有Native根组成Schema前缀，
  // 后续抽屉孩子恒属UI域，不会改变Native摇杆在entries与顶层controls中的共同下标。
  const nativeRoots: RuntimeTouchEntry[] = roots.filter((entry: RuntimeTouchEntry): boolean => entry.handledBy === 0)
  const uiRoots: RuntimeTouchEntry[] = roots.filter((entry: RuntimeTouchEntry): boolean => entry.handledBy === 1)
  for (const entry of nativeRoots.concat(uiRoots)) {
    layout.entries.push(entry); layout.controls.push(entry.item)
  }
  for (const parent of layout.controls) {
    if (parent.type !== ControlType.DRAWER || !(drawers.get(parent.id) ?? false)) continue
    const children: ControlItem[] = parent.children ?? []
    const parentEntry: RuntimeTouchEntry | undefined = layout.find(parent.id)
    if (parentEntry === undefined) continue
    for (let index: number = 0; index < children.length; index++) {
      const child: ControlItem = children[index]
      // 子按钮保留导入时的场景/显隐/解绑语义，不能因为抽屉展开就把菜单专用或空绑定按钮变成游戏热区。
      if (child.type !== ControlType.BUTTON || !runtimeTouchControlVisible(child, grabbed, visibility)) continue
      const rect: TouchControlRect = touchControlRect(child, profile, width, height)
      const angle: number = -Math.PI / 2 + Math.PI * 2 / Math.min(8, children.length) * (index % 8)
      const distance: number = (1.4 + Math.floor(index / 8) * .4) * parentEntry.rectVp.width / 2 + rect.width
      rect.x = parentEntry.rectVp.x + parentEntry.rectVp.width / 2 + Math.cos(angle) * distance - rect.width / 2
      rect.y = parentEntry.rectVp.y + parentEntry.rectVp.height / 2 + Math.sin(angle) * distance - rect.height / 2
      const entry: RuntimeTouchEntry = projectedEntry(child, profile, context, rect)
      entry.parentId = parent.id; entry.childIndex = index
      // 普通子按钮与顶层按钮共用Native解释器；系统业务入口仍由ArkUI接线。
      entry.handledBy = child.systemAction === undefined ? 0 : 1
      entry.hitSlopPx = 0
      layout.entries.push(entry)
    }
  }
  // 抽屉普通子项也是Native按钮，统一平铺到Native显示层；全部系统业务节点位于其上。
  // Native exact命中优先让出UI域，绘制必须使用同一顺序，避免透明上层孩子吞掉系统点击。
  layout.entries = layout.entries.filter((entry: RuntimeTouchEntry): boolean => entry.handledBy === 0)
    .concat(layout.entries.filter((entry: RuntimeTouchEntry): boolean => entry.handledBy === 1))
  return layout
}
