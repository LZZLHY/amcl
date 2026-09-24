/**
 * 独立游戏会话布局的纯三方合并：base=启动快照，proposed=本局累计保存，current=父进程最新值。
 * 不读写文件或 Preferences，不改变传入对象；任何非法/超限输入整笔抛错，不保留前半批。
 * 同一 journal 对刚合并的结果重放幂等；导入后又发生父进程编辑的历史由 entry receipt 去重。
 */
import { LaunchPreferenceSnapshot, LaunchPreferenceValue, copyLaunchPreferenceSnapshot } from 'commons'
import { LayoutProfile, GamepadAction, cloneLayout, migrateProfile, utf8ByteLength } from './ControlLayout'
import { getAllPresets } from './LayoutPresets'

export const MAX_LAYOUT_JOURNAL_PROFILES: number = 128
export const MAX_LAYOUT_JOURNAL_BYTES: number = 1024 * 1024

export interface LayoutMergeResult {
  snapshot: LaunchPreferenceSnapshot
  conflicts: string[]
  changed: boolean
}

interface ParsedLayouts {
  snapshot: LaunchPreferenceSnapshot
  profiles: LayoutProfile[]
  active: string
}

/** 规范化后只比较已知布局字段；手柄 map 排序，避免 JSON 属性书写顺序造成假冲突。 */
function normalizeProfile(source: LayoutProfile): LayoutProfile {
  if (source && source.deviceModel !== undefined &&
      (typeof source.deviceModel !== 'string' || utf8ByteLength(source.deviceModel) > 256)) {
    throw new Error('Invalid layout device model')
  }
  const normalized: LayoutProfile | null = migrateProfile(source)
  if (normalized === null) throw new Error('Invalid layout profile')
  normalized.isPreset = normalized.isPreset === true
  const gamepad = normalized.gamepad
  if (gamepad !== undefined && gamepad.buttonMap !== undefined) {
    const ordered: Record<string, GamepadAction> = {}
    for (const key of Object.keys(gamepad.buttonMap).sort()) {
      const action: GamepadAction = gamepad.buttonMap[key]
      ordered[key] = { kind: action.kind, code: action.code }
    }
    gamepad.buttonMap = ordered
  }
  return normalized
}

function readLayouts(snapshot: LaunchPreferenceSnapshot, presetNames: Set<string>): ParsedLayouts {
  const copied: LaunchPreferenceSnapshot = copyLaunchPreferenceSnapshot(snapshot)
  if (copied.name !== 'control_layout') throw new Error('Only control_layout may be merged')
  const keys: string[] = Object.keys(copied.values)
  const jsonValue: LaunchPreferenceValue = keys.includes('profiles') ? copied.values['profiles'] : ''
  const activeValue: LaunchPreferenceValue = keys.includes('active_profile') ? copied.values['active_profile'] : ''
  if (typeof jsonValue !== 'string' || typeof activeValue !== 'string' ||
      utf8ByteLength(jsonValue) > MAX_LAYOUT_JOURNAL_BYTES || utf8ByteLength(activeValue) > 256) {
    throw new Error('Invalid or oversized layout preference strings')
  }
  const raw: LayoutProfile[] = jsonValue.length === 0 ? [] : JSON.parse(jsonValue) as LayoutProfile[]
  if (!Array.isArray(raw) || raw.length > MAX_LAYOUT_JOURNAL_PROFILES) throw new Error('Invalid layout profile collection')
  const profiles: LayoutProfile[] = []
  const names: Set<string> = new Set<string>()
  for (const source of raw) {
    const profile: LayoutProfile = normalizeProfile(source)
    if (names.has(profile.name)) throw new Error('Duplicate layout profile name')
    if (profile.isPreset === true && !presetNames.has(profile.name)) throw new Error('Unknown system layout preset')
    if (profile.isPreset !== true && presetNames.has(profile.name)) throw new Error('User layout uses a reserved preset name')
    names.add(profile.name)
    profiles.push(profile)
  }
  // 首装没有 profiles/active；系统预设可能尚未写 XML，但仍是合法的 active 候选。
  if (activeValue.length > 0 && !names.has(activeValue) && !presetNames.has(activeValue)) {
    throw new Error('Active layout does not exist')
  }
  return { snapshot: copied, profiles: profiles, active: activeValue }
}

function userMap(profiles: LayoutProfile[]): Map<string, LayoutProfile> {
  const result: Map<string, LayoutProfile> = new Map<string, LayoutProfile>()
  for (const profile of profiles) {
    if (profile.isPreset !== true) result.set(profile.name, cloneLayout(profile))
  }
  return result
}

function equalProfile(left: LayoutProfile | undefined, right: LayoutProfile | undefined): boolean {
  if (left === undefined || right === undefined) return left === undefined && right === undefined
  return JSON.stringify(left) === JSON.stringify(right)
}

/** 只接纳两键的会话修改，历史其它布局偏好允许只读透传，但不能借 journal 写回更改。 */
function validateChangedKeys(base: LaunchPreferenceSnapshot, proposed: LaunchPreferenceSnapshot): void {
  const keys: Set<string> = new Set<string>(Object.keys(base.values))
  for (const key of Object.keys(proposed.values)) keys.add(key)
  for (const key of keys) {
    if (key === 'profiles' || key === 'active_profile') continue
    if (base.values[key] !== proposed.values[key]) throw new Error('Journal modified a non-layout preference key')
  }
}

/** 稳定摘要只用于副本命名，不作为安全校验；最终复用副本前仍逐字比较规范化内容。 */
function stableDigest(value: string): string {
  let first: number = 2166136261
  let second: number = 2246822519
  for (let index: number = 0; index < value.length; index++) {
    const code: number = value.charCodeAt(index)
    first = Math.imul(first ^ code, 16777619) >>> 0
    second = Math.imul(second ^ code, 3266489917) >>> 0
  }
  return first.toString(16).padStart(8, '0') + second.toString(16).padStart(8, '0')
}

/** 按 UTF-8 字节截取前缀，保留完整代理对；完整名字仍满足现有 256 字节布局契约。 */
function boundedPrefix(value: string, byteLimit: number): string {
  let result: string = ''
  for (let index: number = 0; index < value.length; index++) {
    let count: number = 1
    const high: number = value.charCodeAt(index)
    if (high >= 0xD800 && high <= 0xDBFF && index + 1 < value.length) {
      const low: number = value.charCodeAt(index + 1)
      if (low >= 0xDC00 && low <= 0xDFFF) count = 2
    }
    const next: string = value.slice(index, index + count)
    if (utf8ByteLength(result + next) > byteLimit) break
    result += next
    index += count - 1
  }
  return result
}

/**
 * 名字由 session + 原始名称 + 内容决定。相同 journal 重放复用同内容副本；
 * 即使用户已占用该名字，也只另找稳定序号，绝不覆盖父进程已有方案。
 */
function preserveConflict(proposed: LayoutProfile, result: Map<string, LayoutProfile>, sessionId: string): string {
  const digest: string = stableDigest(sessionId + '\n' + JSON.stringify(proposed))
  for (let index: number = 0; index < MAX_LAYOUT_JOURNAL_PROFILES; index++) {
    const suffix: string = '（游戏冲突 ' + sessionId.slice(0, 8) + '-' + digest +
      (index === 0 ? '' : '-' + index.toString()) + '）'
    const name: string = boundedPrefix(proposed.name, 256 - utf8ByteLength(suffix)) + suffix
    const copy: LayoutProfile = cloneLayout(proposed)
    copy.name = name
    copy.isPreset = false
    const existing: LayoutProfile | undefined = result.get(name)
    if (existing === undefined) { result.set(name, copy); return name }
    if (equalProfile(existing, copy)) return name
  }
  throw new Error('Too many layout conflict copies')
}

/**
 * 三方策略按方案名称作稳定身份：只有父进程仍等于 base 时才覆盖/删除；
 * 双方修改同名方案则保留 parent，并给 child 保存确定性副本；删除冲突永远保留 parent。
 * 系统预设由代码重建，不把设备自动对齐/hotbar 差异当用户编辑，更不接受 child 覆盖预设。
 */
export function mergeLayoutPreferences(base: LaunchPreferenceSnapshot, proposed: LaunchPreferenceSnapshot,
  current: LaunchPreferenceSnapshot, sessionId: string): LayoutMergeResult {
  if (typeof sessionId !== 'string' || !new RegExp('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').test(sessionId)) {
    throw new Error('Invalid stable layout session identity')
  }
  const presets: LayoutProfile[] = []
  const presetNames: Set<string> = new Set<string>()
  for (const preset of getAllPresets()) {
    const normalized: LayoutProfile = normalizeProfile(preset)
    presets.push(normalized)
    presetNames.add(normalized.name)
  }
  const original: ParsedLayouts = readLayouts(base, presetNames)
  const edited: ParsedLayouts = readLayouts(proposed, presetNames)
  const latest: ParsedLayouts = readLayouts(current, presetNames)
  validateChangedKeys(original.snapshot, edited.snapshot)
  const before: Map<string, LayoutProfile> = userMap(original.profiles)
  const after: Map<string, LayoutProfile> = userMap(edited.profiles)
  const result: Map<string, LayoutProfile> = userMap(latest.profiles)
  const conflicts: string[] = []
  const chosenNames: Map<string, string> = new Map<string, string>()
  const names: Set<string> = new Set<string>()
  for (const name of before.keys()) names.add(name)
  for (const name of after.keys()) names.add(name)
  const parentSelected: boolean = latest.active !== original.active

  for (const name of names) {
    const old: LayoutProfile | undefined = before.get(name)
    const next: LayoutProfile | undefined = after.get(name)
    const owner: LayoutProfile | undefined = result.get(name)
    if (equalProfile(old, next)) continue
    if (next === undefined) {
      if (owner === undefined) continue
      if (equalProfile(owner, old) && !(parentSelected && latest.active === name)) result.delete(name)
      else conflicts.push('保留父进程方案，未应用游戏删除：' + name)
      continue
    }
    if (equalProfile(owner, next)) { chosenNames.set(name, name); continue }
    if (equalProfile(owner, old)) {
      result.set(name, cloneLayout(next))
      chosenNames.set(name, name)
    } else {
      const copyName: string = preserveConflict(next, result, sessionId)
      chosenNames.set(name, copyName)
      conflicts.push('保留父进程方案，游戏修改保存为：' + copyName)
    }
  }

  const profiles: LayoutProfile[] = []
  for (const preset of presets) profiles.push(cloneLayout(preset))
  for (const profile of result.values()) profiles.push(cloneLayout(profile))
  if (profiles.length > MAX_LAYOUT_JOURNAL_PROFILES) throw new Error('Merged layouts exceed the profile limit')
  let active: string = latest.active
  if (!parentSelected) active = chosenNames.get(edited.active) ?? edited.active
  if (active.length > 0 && !presetNames.has(active) && !result.has(active)) {
    active = presets.length > 0 ? presets[0].name : ''
  }
  const serialized: string = JSON.stringify(profiles)
  if (utf8ByteLength(serialized) > MAX_LAYOUT_JOURNAL_BYTES) throw new Error('Merged layouts exceed the byte limit')
  const snapshot: LaunchPreferenceSnapshot = copyLaunchPreferenceSnapshot(latest.snapshot)
  snapshot.values['profiles'] = serialized
  snapshot.values['active_profile'] = active
  const changed: boolean = latest.snapshot.values['profiles'] !== serialized || latest.snapshot.values['active_profile'] !== active
  return { snapshot: snapshot, conflicts: conflicts, changed: changed }
}
