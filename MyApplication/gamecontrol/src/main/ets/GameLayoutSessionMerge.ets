/**
 * V2按持久方案身份进行整方案三方比较。父侧保留current，child只携带相对冻结base的净修改。
 * 删除后同名重建具有另一身份，绝不把名字/摘要当实体身份证明；冲突建立明确副本，不拼接字段。
 */
import { LayoutProfile, cloneLayout, utf8ByteLength, validateAndNormalizeLayout } from './ControlLayout'
import { evidenceTextDigest } from 'commons'
import { buildLayoutCandidate } from './LayoutCandidate'
import { SessionLayoutCatalogEntry, SessionLayoutChange } from './GameSessionLayoutRepository'
import { validateLayoutLibraryBudget } from './LayoutBudget'

export interface GameSessionMergeResult { profiles: LayoutProfile[]; activeName: string; conflicts: string[]; changed: boolean }
/** 已验证source目录的未加载项不代表空布局；只有本次修改涉及的实体才读取实际定义。 */
export interface SourceCurrentLayouts { unloaded: Set<string>; readProfile: (profileId: string) => LayoutProfile }

/** 返回独立candidate，current/base/proposed不被修改；预算失败由同一 owner事务保留child原文。 */
export function mergeGameSessionLayouts(catalog: SessionLayoutCatalogEntry[], changes: SessionLayoutChange[],
  current: LayoutProfile[], currentActive: string, baseActiveId: string, proposedActiveId: string,
  sessionId: string, readBase: (entry: SessionLayoutCatalogEntry) => LayoutProfile,
  sourceCurrent?: SourceCurrentLayouts): GameSessionMergeResult {
  const result: Map<string, LayoutProfile> = new Map<string, LayoutProfile>()
  const names: Set<string> = new Set<string>()
  for (const profile of current) {
    const checked: LayoutProfile | null = sourceCurrent !== undefined && profile.profileId !== undefined && sourceCurrent.unloaded.has(profile.profileId)
      ? { profileId: profile.profileId, profileRevision: profile.profileRevision, name: profile.name, isPreset: profile.isPreset,
        targetDevice: profile.targetDevice, globalScale: 1, controls: [] } : validateAndNormalizeLayout(profile)
    if (checked === null || checked.profileId === undefined || result.has(checked.profileId) || names.has(checked.name)) {
      throw new Error('Invalid owner layout identity or semantic content; child original retained')
    }
    names.add(checked.name)
    result.set(checked.profileId, checked)
  }
  const selected: LayoutProfile | undefined = current.find((profile: LayoutProfile): boolean => profile.name === currentActive)
  if (selected === undefined) throw new Error('TargetMissing:父侧活动方案不存在')
  const parentSelected: boolean = selected?.profileId !== baseActiveId
  const childSelected: boolean = proposedActiveId !== baseActiveId
  if (!catalog.some((entry: SessionLayoutCatalogEntry): boolean => entry.profileId === proposedActiveId)
      && !changes.some((change: SessionLayoutChange): boolean => change.profileId === proposedActiveId && change.proposed !== null)) {
    throw new Error('TargetMissing:游戏提议的活动实体不属于本局目录或新增修改')
  }
  const chosen: Map<string, string> = new Map<string, string>()
  const conflicts: string[] = []
  for (const change of changes) {
    const entry: SessionLayoutCatalogEntry | undefined = catalog.find((item: SessionLayoutCatalogEntry): boolean => item.profileId === change.profileId)
    if (entry?.isPreset === true) throw new Error('Cannot change frozen system preset')
    const old: LayoutProfile | undefined = entry === undefined ? undefined : readBase(entry)
    let owner: LayoutProfile | undefined = result.get(change.profileId)
    if (owner !== undefined && sourceCurrent !== undefined && sourceCurrent.unloaded.has(change.profileId)) {
      owner = sourceCurrent.readProfile(change.profileId)
      result.set(change.profileId, cloneLayout(owner))
    }
    const next: LayoutProfile | null = change.proposed
    const sameBase: boolean = owner === undefined ? old === undefined : old !== undefined
      && owner.profileRevision === entry!.profileRevision && JSON.stringify(owner) === JSON.stringify(old)
    if (next === null) {
      if (entry === undefined) throw new Error('Cannot delete an unknown frozen identity')
      if (owner === undefined) continue
      if (sameBase && !(parentSelected && selected?.profileId === change.profileId)) result.delete(change.profileId)
      else conflicts.push('保留父进程方案，未应用游戏删除：' + owner.name)
      continue
    }
    if (next.profileId !== change.profileId || next.isPreset === true) throw new Error('Invalid V2 proposed layout identity')
    const candidate = buildLayoutCandidate(next)
    if (candidate.profile === null) throw new Error(candidate.reason)
    const proposed: LayoutProfile = candidate.profile
    if (owner !== undefined && JSON.stringify(owner) === JSON.stringify(proposed)) { chosen.set(change.profileId, change.profileId); continue }
    const sameNameOwner: LayoutProfile | undefined = Array.from(result.values()).find((profile: LayoutProfile): boolean => profile.name === proposed.name && profile.profileId !== proposed.profileId)
    if (sameBase && sameNameOwner === undefined) {
      result.set(change.profileId, cloneLayout(proposed)); chosen.set(change.profileId, change.profileId)
      continue
    }
    // 确定性副本身份含session/源id；本局重放由owner同flush标记去重，额外对同内容副本逐字段验证。
    const copy: LayoutProfile = cloneLayout(proposed)
    copy.profileId = 'conflict_' + sessionId.replace(/-/g, '').slice(0, 16) + '_' + evidenceTextDigest(change.profileId).slice(0, 32)
    copy.profileRevision = 1
    let name: string = proposed.name
    while (utf8ByteLength(name) > 160) name = name.substring(0, name.length - 1)
    const baseName: string = name + '（游戏冲突 ' + sessionId.slice(0, 8) + '）'
    copy.name = baseName
    let index: number = 2
    while (Array.from(result.values()).some((profile: LayoutProfile): boolean => profile.name === copy.name && profile.profileId !== copy.profileId)) {
      copy.name = baseName + ' ' + index.toString(); index++
    }
    const existing: LayoutProfile | undefined = result.get(copy.profileId)
    if (existing !== undefined && JSON.stringify(existing) !== JSON.stringify(copy)) throw new Error('V2 conflict identity already occupied; original retained')
    result.set(copy.profileId, copy); chosen.set(change.profileId, copy.profileId!)
    conflicts.push('保留父进程方案，游戏修改保存为：' + copy.name)
  }
  const profiles: LayoutProfile[] = Array.from(result.values())
  // 内容冲突本身不是选择变更；两侧均仍选择A时，A的child副本不得悄悄成为active。
  const activeId: string = parentSelected || !childSelected ? selected.profileId! : chosen.get(proposedActiveId) ?? proposedActiveId
  if (!result.has(activeId)) throw new Error('TargetMissing:游戏选择的冻结实体已被父侧删除，原修改集保留等待恢复')
  const activeName: string = result.get(activeId)?.name ?? ''
  if (profiles.length === 0 || activeName.length === 0) throw new Error('TargetMissing:合并后的活动方案不存在')
  if (sourceCurrent === undefined) validateLayoutLibraryBudget(current, profiles)
  return { profiles: profiles, activeName: activeName, conflicts: conflicts,
    changed: JSON.stringify(profiles) !== JSON.stringify(current) || activeName !== currentActive }
}
