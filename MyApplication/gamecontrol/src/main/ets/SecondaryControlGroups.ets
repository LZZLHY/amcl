/**
 * 二级按键组的纯编辑事务。仅产生完整布局草稿，不持有当前展开状态，不直接写Store或调用Native。
 * 绑定使用组的稳定ID；二级成员始终保存全屏坐标。删除与解绑明确分开，一次事务可由编辑会话完整撤销。
 */
import { ControlItem, ControlType, AlignGroup, LayoutProfile, cloneLayout, enableLayoutControlGroups, effectiveLabel,
  generateControlId, validateAndNormalizeLayout, removeLayoutControlGroup, DEFAULT_BUTTON_SIZE } from './ControlLayout'
import { ControlGroup, SECONDARY_GROUP_PROFILE_VERSION, TOUCH_SECONDARY_GROUP_CAPABILITY, MAX_CONTROL_GROUPS } from './ControlGroups'

/** 创建结果同时返回新组/控件身份；失败不修改输入，原因供原面板就地显示。 */
export class SecondaryGroupEditResult {
  profile: LayoutProfile | null = null
  groupId: string = ''
  controlId: string = ''
  reason: string = ''
}

/** 删除计划只列稳定身份；UI确认时须再次核对完整草稿签名，不能按旧下标执行。 */
export class SecondaryControlRemoval {
  controlIds: string[] = []
  groupIds: string[] = []
  memberNames: string[] = []
  requiresConfirmation: boolean = false
  /** 只用于无法保持其它锁定子项几何的删除；明确拒绝，不以确认绕过锁定约束。 */
  reason: string = ''
  /** 系统功能仍遵守原生保护：整组删除时移回一级，不能先删掉再被候选补齐成默认配置。 */
  retainedSystemNames: string[] = []
}

export function secondaryControlGroup(profile: LayoutProfile, id: string): ControlGroup | undefined {
  return profile.controlGroups?.find((group: ControlGroup): boolean => group.id === id && group.secondary === true)
}

/** 一个组至多一个展开键和一个返回键；完整校验负责拒绝重复引用。 */
export function secondaryGroupOpener(profile: LayoutProfile, groupId: string): ControlItem | undefined {
  return profile.controls.find((item: ControlItem): boolean => item.secondaryAction?.kind === 'toggle' && item.secondaryAction.groupId === groupId)
}
export function secondaryGroupReturn(profile: LayoutProfile, groupId: string): ControlItem | undefined {
  return profile.controls.find((item: ControlItem): boolean => item.secondaryAction?.kind === 'return' && item.secondaryAction.groupId === groupId)
}

/** 一级展开键只能绑定顶层普通按钮；系统恢复入口、隐藏键和已绑定入口不能被静默夺用。 */
export function canBindSecondaryGroup(profile: LayoutProfile, item: ControlItem, groupId: string = ''): boolean {
  return profile.controls.some((root: ControlItem): boolean => root.id === item.id) &&
    item.type === ControlType.BUTTON && item.systemAction === undefined && item.hidden !== true &&
    item.visibilityOverride !== 'force_hide' && secondaryControlGroup(profile, item.controlGroupId ?? '') === undefined &&
    (item.secondaryAction === undefined || (item.secondaryAction.kind === 'toggle' && item.secondaryAction.groupId === groupId))
}

/** 只在用户显式创建二级组时启用v6。普通v3/v4/v5的查看和编辑不会被隐式升级。 */
function enableSecondaryGroups(source: LayoutProfile): LayoutProfile {
  const draft: LayoutProfile = enableLayoutControlGroups(source)
  draft.version = SECONDARY_GROUP_PROFILE_VERSION
  const capabilities: string[] = draft.requiredCapabilities?.slice() ?? []
  if (capabilities.indexOf(TOUCH_SECONDARY_GROUP_CAPABILITY) < 0) capabilities.push(TOUCH_SECONDARY_GROUP_CAPABILITY)
  draft.requiredCapabilities = capabilities
  return draft
}

/** 新建功能键无游戏输出。缺省外观与普通按钮一致，位置仅为首次落点，之后可自由摆放。 */
function makeSecondaryButton(profile: LayoutProfile, label: string, groupId: string, width: number, height: number): ControlItem {
  return { id:generateControlId(profile.controls),label:label,type:ControlType.BUTTON,keyOrMouse:0,keys:[],
    xPct:0.46,yPct:0.08,baseWidth:width,baseHeight:height,itemScale:1,isCircle:false,
    style:{cornerRadius:0.12},alignGroup:AlignGroup.NONE,alignIndex:0,grabbedOnly:false,hideOnInput:[],controlGroupId:groupId }
}

/**
 * 新建一级展开键与普通按钮共用标准正方形基准及默认itemScale=1。
 * 两个创建入口都调用此工厂，避免补建入口再出现72×44的独立尺寸；运行与编辑预览
 * 继续使用base尺寸×itemScale×globalScale，不烘焙当前全局倍率，也不新增JSON尺寸字段。
 * 这里只创建未绑定的普通键草稿；调用方添加后仍须走完整组绑定与布局校验。
 */
export function makeSecondaryGroupOpener(profile: LayoutProfile, label: string): ControlItem {
  return makeSecondaryButton(profile,label,profile.defaultControlGroupId!,DEFAULT_BUTTON_SIZE,DEFAULT_BUTTON_SIZE)
}

/** 创建空二级组后直接添加成员；返回键不附带，新建或选定的展开键留在一级。 */
export function createSecondaryControlGroup(source: LayoutProfile, name: string, openerId?: string): SecondaryGroupEditResult {
  const result: SecondaryGroupEditResult = new SecondaryGroupEditResult()
  if (name.trim().length === 0 || name.trim().length > 64) { result.reason='组名须为1至64个字符'; return result }
  const draft: LayoutProfile = enableSecondaryGroups(source)
  if ((draft.controlGroups?.length ?? 0) >= MAX_CONTROL_GROUPS) { result.reason='控件组已达数量上限'; return result }
  let groupId: string = generateControlId(draft.controls)
  while (draft.controlGroups!.some((group: ControlGroup): boolean => group.id === groupId)) groupId=generateControlId(draft.controls)
  let opener: ControlItem | undefined = openerId === undefined ? undefined : draft.controls.find((item: ControlItem): boolean => item.id === openerId)
  if (openerId !== undefined && (opener === undefined || !canBindSecondaryGroup(draft,opener))) {
    result.reason='请选择未绑定其它二级组的一级普通按键'; return result
  }
  if (opener === undefined) { opener=makeSecondaryGroupOpener(draft,name.trim()); draft.controls.push(opener) }
  draft.controlGroups!.push({id:groupId,name:name.trim(),initialVisible:false,secondary:true,hidePrimary:false})
  opener.secondaryAction={kind:'toggle',groupId:groupId}
  result.profile=validateAndNormalizeLayout(draft);result.groupId=groupId;result.controlId=opener.id
  if (result.profile === null) result.reason='二级组草稿未通过完整布局校验'
  return result
}

/** 更换入口只移除旧入口的层级动作，原键位/触发/样式保持；undefined明确表示解除绑定。 */
export function bindSecondaryControlGroup(source: LayoutProfile, groupId: string, openerId?: string): LayoutProfile | null {
  if (secondaryControlGroup(source,groupId) === undefined) return null
  const draft: LayoutProfile = cloneLayout(source)
  const next: ControlItem | undefined = openerId === undefined ? undefined : draft.controls.find((item: ControlItem): boolean => item.id === openerId)
  if (openerId !== undefined && (next === undefined || !canBindSecondaryGroup(draft,next,groupId))) return null
  const previous: ControlItem | undefined = secondaryGroupOpener(draft,groupId)
  if (previous !== undefined) previous.secondaryAction=undefined
  if (next !== undefined) next.secondaryAction={kind:'toggle',groupId:groupId}
  return validateAndNormalizeLayout(draft)
}

/** 返回键由添加目录显式创建；重复添加只定位已有键，绝不生成重复身份。 */
export function addSecondaryGroupReturn(source: LayoutProfile, groupId: string): SecondaryGroupEditResult {
  const result: SecondaryGroupEditResult = new SecondaryGroupEditResult();result.groupId=groupId
  if (secondaryControlGroup(source,groupId) === undefined) { result.reason='二级组不存在';return result }
  const draft: LayoutProfile = cloneLayout(source)
  let item: ControlItem | undefined = secondaryGroupReturn(draft,groupId)
  if (item === undefined) {
    item=makeSecondaryButton(draft,'返回一级',groupId,88,44);item.xPct=0.02;item.yPct=0.33
    item.secondaryAction={kind:'return',groupId:groupId};draft.controls.push(item)
  }
  result.controlId=item.id;result.profile=validateAndNormalizeLayout(draft)
  if (result.profile === null) result.reason='返回键草稿未通过校验'
  return result
}

/** 移入/移出只修改成员关系，显式子项归属随父更新，所有几何与键位保持。 */
export function moveSecondaryGroupMember(source: LayoutProfile, controlId: string, targetGroupId: string): LayoutProfile | null {
  if (!source.controlGroups?.some((group: ControlGroup): boolean => group.id === targetGroupId)) return null
  const draft: LayoutProfile=cloneLayout(source),item: ControlItem | undefined=draft.controls.find((value: ControlItem): boolean => value.id === controlId)
  if (item === undefined || item.secondaryAction !== undefined || item.systemAction === 'edit' || item.systemAction === 'visibility') return null
  const assign=(value: ControlItem,root: boolean): void=>{
    if (root || value.controlGroupId !== undefined) value.controlGroupId=targetGroupId
    for (const child of value.children ?? []) assign(child,false)
  }
  assign(item,true);return validateAndNormalizeLayout(draft)
}

/** 计划包含隐藏成员和抽屉子项，不依赖画布可见性；同名但不同身份的控件不在删除范围。 */
export function secondaryControlRemovalPlan(profile: LayoutProfile, selectedIds: string[]): SecondaryControlRemoval {
  const result: SecondaryControlRemoval=new SecondaryControlRemoval(),removed: Set<string>=new Set<string>()
  let compound: boolean=false
  const protectedTree=(item: ControlItem): boolean=>item.systemAction!==undefined||(item.children??[]).some((child: ControlItem): boolean=>protectedTree(child))
  const collect=(item: ControlItem): void=>{removed.add(item.id);for(const child of item.children ?? [])collect(child)}
  const visit=(items: ControlItem[]): void=>{
    for(const item of items){
      if(selectedIds.indexOf(item.id)>=0 && !protectedTree(item)){
        collect(item)
        if((item.children?.length??0)>0){compound=true;for(const child of item.children??[])result.memberNames.push(effectiveLabel(child)||child.id)}
        if(item.secondaryAction?.kind==='toggle' && result.groupIds.indexOf(item.secondaryAction.groupId)<0) result.groupIds.push(item.secondaryAction.groupId)
      }
      if(item.children!==undefined)visit(item.children)
    }
  }
  visit(profile.controls)
  for(const item of profile.controls)if(result.groupIds.indexOf(item.controlGroupId ?? '')>=0){
    if(protectedTree(item)){result.retainedSystemNames.push(effectiveLabel(item)||item.id);continue}
    collect(item);result.memberNames.push(effectiveLabel(item)||item.id)
  }
  const checkChildren=(items: ControlItem[]): void=>{
    for(const parent of items){
      const children: ControlItem[]=parent.children??[]
      if(!removed.has(parent.id)&&children.some((child: ControlItem): boolean=>removed.has(child.id))&&
        children.some((child: ControlItem): boolean=>child.locked===true&&!removed.has(child.id)))
        result.reason='抽屉中仍有锁定子项，删除会改变其位置，请先解锁'
      checkChildren(children)
    }
  }
  checkChildren(profile.controls)
  removed.forEach((id: string): void=>{result.controlIds.push(id)})
  result.requiresConfirmation=result.groupIds.length>0||compound
  return result
}

/** 已确认范围以完整草稿事务执行；删除展开键同时删除其组和全部成员，普通单键只删除本身。 */
export function removeSecondaryControls(source: LayoutProfile, ids: string[]): LayoutProfile | null {
  const plan: SecondaryControlRemoval=secondaryControlRemovalPlan(source,ids)
  if(plan.reason.length>0)return null
  let draft: LayoutProfile=cloneLayout(source)
  for(const groupId of plan.groupIds){const next: LayoutProfile | null=removeLayoutControlGroup(draft,groupId);if(next===null)return null;draft=next}
  const prune=(items: ControlItem[]): ControlItem[]=>items.filter((item: ControlItem): boolean=>plan.controlIds.indexOf(item.id)<0).map((item: ControlItem): ControlItem=>{
    if(item.children!==undefined)item.children=prune(item.children);return item
  })
  if(source.controls.some((item: ControlItem): boolean=>plan.controlIds.indexOf(item.id)>=0&&item.type===ControlType.HOTBAR_SELECTOR))draft.hotbarAutoAdded=true
  draft.controls=prune(draft.controls);return validateAndNormalizeLayout(draft)
}
