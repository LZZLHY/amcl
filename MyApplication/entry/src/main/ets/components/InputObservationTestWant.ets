/**
 * default诊断构建的固定Want编排：外部只到exported的EntryAbility，内部转发给原私有
 * GameAbility.onNewWant。活动ID必须匹配原Host；冷启动竞态由GameAbility提前拒绝。
 * 固定沙箱文件只保留一次操作收据，startAbility成功不代替真实组件完成，read不推进维护。
 */
import { Want, common } from '@kit.AbilityKit'
import { DiagnosticPolicy, writeEvidenceTextAtomic } from 'commons'
import { ProductBuildProfile } from 'entry/ProductBuildProfile'
import testNapi from 'libentry.so'
import { EntryInputObservationResult, operateEntryInputObservation } from './EntryInputObservationPort'

class InputObservationRequest {
  action: string = ''
  requestId: string = ''
  activity: number = 0
}
class InputObservationReceipt {
  schema: number = 1
  requestId: string = ''
  action: string = ''
  result: EntryInputObservationResult = new EntryInputObservationResult()
}

/** 只识别固定标记；冷私有Ability据此拒绝创建游戏，不依赖尚未配置的诊断政策。 */
export function isInputObservationTestWant(want: Want): boolean {
  return want.parameters?.['amclInputObservationTest']!==undefined
}
/** 双门与严格固定参数同时成立才受理；过滤后的内部Want不携带原任意附加参数。 */
function parseRequest(want: Want): InputObservationRequest | undefined {
  if (ProductBuildProfile.product!=='default' || !DiagnosticPolicy.hasTestHooks()) return undefined
  const action: string=(want.parameters?.['amclInputObservationTest'] as string) ?? ''
  const requestId: string=(want.parameters?.['requestId'] as string) ?? ''
  // aa的整数参数不作为大活动ID的无损载体；外部允许严格十进制字符串，内部可保原number。
  const activityValue: string | number | undefined=want.parameters?.['activityId'] as string | number | undefined
  let activity: number=0
  if (typeof activityValue==='number') activity=activityValue
  else if (typeof activityValue==='string' && new RegExp('^[1-9][0-9]{0,15}$').test(activityValue)) activity=Number(activityValue)
  if ((action!=='off' && action!=='on' && action!=='read') ||
    typeof requestId!=='string' || !new RegExp('^[A-Za-z0-9_-]{1,32}$').test(requestId) ||
    !Number.isSafeInteger(activity) || activity<=0) return undefined
  const request: InputObservationRequest=new InputObservationRequest()
  request.action=action; request.requestId=requestId; request.activity=activity
  return request
}
/** 输出路径由Ability可信filesDir固定，不读取Want中的路径/URL；IO失败不逃出生命周期。 */
function writeReceipt(context: common.UIAbilityContext, request: InputObservationRequest,
  result: EntryInputObservationResult): void {
  const receipt: InputObservationReceipt=new InputObservationReceipt()
  receipt.requestId=request.requestId; receipt.action=request.action; receipt.result=result
  try { writeEvidenceTextAtomic(context.filesDir+'/input-observation-test-result.json',JSON.stringify(receipt)) }
  catch (_) { /* 无文件即无完成证明；不以日志或开始转发代替真实收据。 */ }
}

/** 仅转发已存在的游戏进程；原进程消失竞态不得通过诊断请求重新启动游戏。 */
export async function forwardInputObservationTestWant(context: common.UIAbilityContext, want: Want): Promise<boolean> {
  if (!isInputObservationTestWant(want)) return false
  const request: InputObservationRequest | undefined=parseRequest(want)
  if (request===undefined) return true
  const result: EntryInputObservationResult=new EntryInputObservationResult(); result.activity=request.activity
  try {
    if (testNapi.desktopGameProcessState(context.filesDir,0)!==1) {
      result.outcome='GameProcessUnavailable'; writeReceipt(context,request,result); return true
    }
    result.outcome='Forwarding'; writeReceipt(context,request,result)
    await context.startAbility({bundleName:context.applicationInfo.name,abilityName:'GameAbility',parameters:{
      'amclInputObservationTest':request.action,'requestId':request.requestId,'activityId':request.activity}})
  } catch (_) { result.outcome='ForwardFailed'; writeReceipt(context,request,result) }
  return true
}

/** 只在原GameAbility已完成正常启动时操作Port原登记；无页面/冷/失败窗口不调用Host工厂。 */
export function runInputObservationTestWant(context: common.UIAbilityContext, want: Want, startupReady: boolean): boolean {
  if (!isInputObservationTestWant(want)) return false
  const request: InputObservationRequest | undefined=parseRequest(want)
  if (request===undefined) return true
  let result: EntryInputObservationResult=new EntryInputObservationResult(); result.activity=request.activity
  if (!startupReady) result.outcome='GameProcessUnavailable'
  else {
    try { result=operateEntryInputObservation(request.activity,request.action) }
    catch (_) { result.outcome='ObservationOutcomeUnknown' }
  }
  writeReceipt(context,request,result)
  return true
}
