import { MobileInputPreference } from '../runtime/MobileInputPreference'
import { settingFailure, settingKeys, SettingsSkillData, settingText } from './SettingsSkillValues'

/** 启动器具名入口复用游戏中相同的输入偏好；成功回执回读唯一原件，独立进程并发改写时报告未知。 */
export function mobileInputSkill(context: Context, method: string, args: SettingsSkillData): SettingsSkillData {
  if (!MobileInputPreference.available()) return { 'state': 'unavailable', 'reason': 'unsupportedDevice' }
  const write: boolean = method === 'setMobileInputMode'
  if ((!write && method !== 'getMobileInputMode') || !settingKeys(args, write ? ['mode'] : [])) return settingFailure('invalidArguments')
  const mode: string = settingText(args, 'mode')
  if (write && !MobileInputPreference.valid(mode)) return settingFailure('invalidMode')
  try {
    if (write) MobileInputPreference.save(context, mode)
    const actual: string = MobileInputPreference.read(context)
    if (write && actual !== mode) return { 'state': 'unknown', 'reason': 'selectionChanged' }
    return { 'state': 'ready', 'mode': actual }
  } catch (_) {
    return { 'state': 'unknown', 'reason': write ? 'saveUnconfirmed' : 'settingUnreadable' }
  }
}
