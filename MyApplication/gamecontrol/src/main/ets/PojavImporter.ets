/**
 * Pojav导入的兼容入口，真实转换与逐类损失报告统一位于ExternalLayoutImporter。
 * -1是软件键盘，-3/-4才是鼠标左右键；不再沿用旧适配器的错误负数映射。
 * 有兼容差异时默认拒绝直接导入，调用方先展示analyzeExternalLayout报告后才可显式接受。
 */
import { LayoutProfile } from './ControlLayout'
import { externalLayoutFormat, analyzeExternalLayout } from './ExternalLayoutImporter'

export function isPojavLayoutJson(value: Object): boolean {
  return externalLayoutFormat(value)==='pojav'
}

export function importPojavLayout(json: string,profileName: string,acceptWarnings: boolean = false): LayoutProfile | null {
  const review = analyzeExternalLayout(json,profileName)
  if (review.format!=='pojav' || (review.warnings.length>0 && !acceptWarnings)) return null
  return review.profile
}
