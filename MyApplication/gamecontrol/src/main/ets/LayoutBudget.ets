/**
 * 布局预算分层：XML单值上限来自官方MAX_VALUE_LENGTH=16MiB；目录后端与V2用32MiB有界恢复窗口。
 * 8MiB是转目录的触发值，用于为identity/系统补齐、原文备份与回滚留空间，不是拒写合法旧库的门。
 * 旧库必要规范化可迁移；后续超过16MiB库仍允许不增加用户内容压力的编辑/删除，新增增长须缩减后再提交。
 */
import { LayoutProfile, cloneLayout, utf8ByteLength } from './ControlLayout'
import { LAYOUT_STORAGE_XML_BYTES, LAYOUT_STORAGE_MIGRATION_BYTES,
  LAYOUT_STORAGE_LIBRARY_BYTES, LAYOUT_STORAGE_CHUNK_BYTES } from 'commons'
export const MAX_LAYOUT_XML_BYTES: number = LAYOUT_STORAGE_XML_BYTES
export const LAYOUT_FILE_MIGRATION_BYTES: number = LAYOUT_STORAGE_MIGRATION_BYTES
export const MAX_LAYOUT_LIBRARY_BYTES: number = LAYOUT_STORAGE_LIBRARY_BYTES
export const LAYOUT_TRANSFER_CHUNK_BYTES: number = LAYOUT_STORAGE_CHUNK_BYTES

/** 元数据修订与身份不是用户新增内容；比较独立副本，不能改动调用方对象。 */
function contentBytes(profiles: LayoutProfile[]): number {
  const content: LayoutProfile[] = profiles.map((profile: LayoutProfile): LayoutProfile => {
    const copy: LayoutProfile = cloneLayout(profile)
    copy.profileId = undefined; copy.profileRevision = undefined
    return copy
  })
  return utf8ByteLength(JSON.stringify(content))
}
export function validateLayoutLibraryBudget(before: LayoutProfile[], after: LayoutProfile[], migration: boolean = false): void {
  const bytes: number = utf8ByteLength(JSON.stringify(after))
  if (bytes > MAX_LAYOUT_LIBRARY_BYTES) throw new Error('BudgetExceeded:布局库超过32MiB有界恢复预算，请先导出和缩减')
  if (!migration && bytes > MAX_LAYOUT_XML_BYTES && contentBytes(after) > contentBytes(before)) {
    throw new Error('BudgetExceeded:历史大库暂只允许不增加内容压力的编辑、删除和导出，请缩减后新增')
  }
}
