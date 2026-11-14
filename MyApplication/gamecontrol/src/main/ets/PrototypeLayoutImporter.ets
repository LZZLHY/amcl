/**
 * 将用户确认的HTML原型导出转换为原生布局。边框边车进入ControlStyle，二级绑定进入v6正式字段。
 * 不执行网页代码，不读取外部资源；所有方案和引用先校验，原文件保持。现有方案库一次导入一个方案，
 * 多方案文件明确选用pack.active，并在预览告知其他方案仍保留在原文件中，不能静默选第一项。
 */
import { LayoutProfile,ControlItem,ControlType,validateAndNormalizeLayout } from './ControlLayout'
import { ControlGroup,hasOnlyControlGroupFields,SECONDARY_GROUP_PROFILE_VERSION,TOUCH_SECONDARY_GROUP_CAPABILITY } from './ControlGroups'

type PrototypeObject=Record<string,Object>
export class PrototypeLayoutConversion {
  profile: LayoutProfile | null=null
  warnings: string[]=[]
}
function prototypeObject(value: Object | undefined): PrototypeObject {
  if(value===null||value===undefined||typeof value!=='object'||Array.isArray(value))throw new Error('原型文件包含非法对象')
  return value as PrototypeObject
}
function profileIndex(key: string,count: number): number {
  const index: number=Number(key)
  if(!new RegExp('^(0|[1-9][0-9]*)$').test(key)||!Number.isInteger(index)||index<0||index>=count)throw new Error('原型方案引用不存在')
  return index
}
function controlTable(profile: LayoutProfile): Map<string,ControlItem> {
  const table: Map<string,ControlItem>=new Map<string,ControlItem>()
  const visit=(items: ControlItem[]): void=>{for(const item of items){table.set(item.id,item);if(item.children!==undefined)visit(item.children)}}
  visit(profile.controls);return table
}

/** 调用方已完成JSON大小限制；此处先规范化全部方案，再原子转换，失败不返回部分结果。 */
export function convertPrototypeLayout(value: Object): PrototypeLayoutConversion {
  const root: PrototypeObject=prototypeObject(value),pack: PrototypeObject=prototypeObject(root['pack'])
  const version: Object | undefined=root['version']
  if(root['format']!=='amcl-ui-prototype'||(version!==1&&version!==2&&version!==3))throw new Error('不支持的HTML原型版本')
  if(!Array.isArray(pack['profiles'])||(pack['profiles'] as Object[]).length===0||(pack['profiles'] as Object[]).length>128)throw new Error('原型方案列表不合法')
  const active: number=pack['active'] as number,raw: Object[]=pack['profiles'] as Object[]
  if(typeof active!=='number'||!Number.isInteger(active)||active<0||active>=raw.length)throw new Error('原型当前方案不存在')
  const profiles: LayoutProfile[]=[]
  for(const source of raw){const checked: LayoutProfile | null=validateAndNormalizeLayout(source as LayoutProfile)
    if(checked===null)throw new Error('原型中有无法读取的按键方案');profiles.push(checked)}
  if(pack['appearanceExtras']!==undefined){
    const styles: PrototypeObject=prototypeObject(pack['appearanceExtras'])
    for(const key of Object.keys(styles)){
      const profile: LayoutProfile=profiles[profileIndex(key,profiles.length)],items: Map<string,ControlItem>=controlTable(profile)
      const extras: PrototypeObject=prototypeObject(styles[key])
      for(const id of Object.keys(extras)){
        const item: ControlItem | undefined=items.get(id),style: PrototypeObject=prototypeObject(extras[id])
        if(item===undefined||item.type!==ControlType.BUTTON||!hasOnlyControlGroupFields(style,['borderWidth','borderColor']))throw new Error('原型边框引用或字段不合法')
        if(style['borderWidth']!==undefined&&(typeof style['borderWidth']!=='number'||!Number.isFinite(style['borderWidth'] as number)||(style['borderWidth'] as number)<0||(style['borderWidth'] as number)>12))throw new Error('原型边框粗细超出范围')
        if(style['borderColor']!==undefined&&(typeof style['borderColor']!=='string'||!new RegExp('^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$').test(style['borderColor'] as string)))throw new Error('原型边框颜色不合法')
        if(item.style===undefined)item.style={}
        if(style['borderWidth']!==undefined)item.style.borderWidth=style['borderWidth'] as number
        if(style['borderColor']!==undefined)item.style.borderColor=style['borderColor'] as string
      }
    }
  }
  if(pack['secondaryLayers']!==undefined){
    if(version===1)throw new Error('二级按键组需要原型版本2或3')
    const layers: PrototypeObject=prototypeObject(pack['secondaryLayers'])
    for(const key of Object.keys(layers)){
      const profile: LayoutProfile=profiles[profileIndex(key,profiles.length)],table: PrototypeObject=prototypeObject(layers[key])
      const assigned: Set<string>=new Set<string>()
      for(const id of Object.keys(table)){
        const record: PrototypeObject=prototypeObject(table[id])
        const group: ControlGroup | undefined=profile.controlGroups?.find((item: ControlGroup): boolean=>item.id===id)
        if(group===undefined||group.id===profile.defaultControlGroupId||group.initialVisible!==false||!hasOnlyControlGroupFields(record,['openerId','returnId','hidePrimary'])||typeof record['hidePrimary']!=='boolean')throw new Error('原型二级组定义不合法')
        group.secondary=true;group.hidePrimary=record['hidePrimary'] as boolean
        for(const role of ['openerId','returnId']){
          const identity: Object | undefined=record[role]
          if(identity===null){if(version===2&&role==='returnId')throw new Error('旧版原型返回键引用缺失');continue}
          if(typeof identity!=='string'||assigned.has(identity as string))throw new Error('原型展开键或返回键引用重复')
          const item: ControlItem | undefined=profile.controls.find((control: ControlItem): boolean=>control.id===identity)
          if(item===undefined||item.secondaryAction!==undefined)throw new Error('原型展开键或返回键引用不存在或冲突')
          assigned.add(identity as string)
          item.secondaryAction={kind:role==='openerId'?'toggle':'return',groupId:id}
          if(role==='returnId'){
            // HTML的返回功能曾借用同组hide作为实现；只移除这一条可证明的派生动作。
            item.groupActions=item.groupActions?.filter(action=>!(action.phase==='press'&&action.operation==='hide'&&action.targets.length===1&&action.targets[0]===id))
          }
        }
      }
      if(Object.keys(table).length>0){
        profile.version=SECONDARY_GROUP_PROFILE_VERSION
        const capabilities: string[]=profile.requiredCapabilities?.slice()??[]
        if(capabilities.indexOf(TOUCH_SECONDARY_GROUP_CAPABILITY)<0)capabilities.push(TOUCH_SECONDARY_GROUP_CAPABILITY)
        profile.requiredCapabilities=capabilities
      }
    }
  }
  for(let i: number=0;i<profiles.length;i++){
    const checked: LayoutProfile | null=validateAndNormalizeLayout(profiles[i])
    if(checked===null)throw new Error('原型二级绑定或样式无法完整转换，未导入任何控件')
    profiles[i]=checked
  }
  const result: PrototypeLayoutConversion=new PrototypeLayoutConversion();result.profile=profiles[active]
  if(profiles.length>1)result.warnings.push('文件含'+profiles.length.toString()+'个方案，本次导入当前选中的“'+result.profile.name+'”；其他方案仍保留在原文件中。')
  return result
}
