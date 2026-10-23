/** 系统鼠标的布局迁移与运行时投影：入口在真实方案中保存，编辑、菜单和游戏共用同一身份与位置。 */
import { ControlItem, ControlType, LayoutProfile, makeDefaultSystemMouseControl } from './ControlLayout'

/** 收集完整布局ID，派生入口必须与嵌套抽屉中的身份也不碰撞。 */
function collectTouchIds(items: ControlItem[],ids: Set<string>): void {
  for(const item of items) { ids.add(item.id); if(item.children!==undefined) collectTouchIds(item.children ?? [],ids) }
}
export function touchRuntimeId(base: string,items: ControlItem[]): string {
  const ids: Set<string>=new Set<string>(); collectTouchIds(items,ids)
  let index: number=0
  while(ids.has(base+index.toString())) index++
  return base+index.toString()
}

/**
 * 在布局事务副本中补齐鼠标系统按钮，并仅退休历史默认id=scroll的独立滚轮。
 * 所有已发布版本都没有鼠标入口，因此升级只需在缺项时新增统一的右下角默认按钮，不推断旧坐标是否为定制。
 * 已有入口代表用户/开发期布局中已有的真实设置，位置、尺寸、外观、场景和显隐全部保留，重复加载不恢复默认。
 * 历史默认滚轮的职责被新面板覆盖，但它的位置不代表用户对新鼠标入口的选择，不能拿来当新增入口坐标。
 * 用户另建的滚轮不属于默认清理范围。调用方随后整表校验，失败沿用原事务回滚，绝不删除其它控件腾位置。
 */
export function ensureSystemMouseControl(profile: LayoutProfile): void {
  profile.controls=profile.controls.filter((item: ControlItem): boolean =>
    !(item.type===ControlType.SCROLL_WHEEL && item.id==='scroll'))
  let mouse: ControlItem | undefined=profile.controls.find((item: ControlItem): boolean => item.systemAction==='mouse')
  if(mouse===undefined) {
    mouse=makeDefaultSystemMouseControl()
    // 仅新注入的入口归入默认组，既有鼠标入口仍由用户保存的归属控制。
    if (profile.controlGroups !== undefined) mouse.controlGroupId = profile.defaultControlGroupId
    const occupied: Set<string>=new Set<string>()
    collectTouchIds(profile.controls,occupied)
    if(occupied.has(mouse.id)) {
      // 同一冻结source在两个进程补齐时使用同一确定性ID，仍完整避让抽屉子控件。
      let index: number=0
      while(occupied.has('system_mouse_'+index.toString())) index++
      mouse.id='system_mouse_'+index.toString()
    }
    profile.controls.push(mouse)
  }
  // 已存在的入口不再被加载流程逐字段改写；系统动作由systemAction识别，用户显隐设置和摆放由原存档解释。
}

/** 运行时不再生成或改位临时工具按钮；实际布局是渲染、编辑和原生命中的共同事实源。 */
export function runtimeTouchControls(profile: LayoutProfile,_grabbed: boolean,_width: number,_height: number): ControlItem[] {
  return profile.controls
}
