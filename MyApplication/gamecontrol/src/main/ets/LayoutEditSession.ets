/**
 * 布局与输入设置共用的纯编辑会话：保存进入基线和有界撤销快照。
 * 本对象不访问平台、不发布输入或写盘。显示组件负责收集用户输入，仓库负责原子提交。
 * 每个检查点深复制完整方案，因而隐藏的来源政策、手柄、旧兼容字段和组引用均能往返。
 */
import { LayoutProfile, cloneLayout, validateAndNormalizeLayout } from './ControlLayout'

export class LayoutEditCheckpoint {
  profile: LayoutProfile
  currentGroup: string
  previewGroups: string[]
  constructor(profile: LayoutProfile, currentGroup: string, previewGroups: string[]) {
    this.profile=cloneLayout(profile)
    this.currentGroup=currentGroup
    this.previewGroups=previewGroups.slice()
  }
}

export class LayoutEditSession {
  private baseline: LayoutProfile | undefined = undefined
  private history: LayoutEditCheckpoint[] = []

  /** 打开新的编辑目标时清历史；目标身份随基线冻结，名称不是身份替代物。 */
  open(profile: LayoutProfile): void {
    this.baseline=cloneLayout(profile)
    this.history=[]
  }

  original(): LayoutProfile | undefined {
    return this.baseline === undefined ? undefined : cloneLayout(this.baseline)
  }

  /** 修改前记录完整合法草稿。无效临时文本只属于UI，不进入持久模型与撤销栈。 */
  remember(profile: LayoutProfile | null, currentGroup: string = '', previewGroups: string[] = []): void {
    if (profile === null) return
    this.history.push(new LayoutEditCheckpoint(profile,currentGroup,previewGroups))
    if (this.history.length>20) this.history.shift()
  }

  takeUndo(): LayoutEditCheckpoint | undefined { return this.history.pop() }
  count(): number { return this.history.length }

  /** 输入设置只替换其负责的字段；其他布局、组图和版本信息来自原完整草稿。 */
  validate(profile: LayoutProfile): LayoutProfile | null {
    if (this.baseline === undefined || profile.profileId !== this.baseline.profileId ||
      profile.profileRevision !== this.baseline.profileRevision) return null
    return validateAndNormalizeLayout(profile)
  }
}
