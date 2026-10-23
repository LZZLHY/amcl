/** owner布局存储与跨进程通道唯一数值策略；XML常量对应官方Preferences.MAX_VALUE_LENGTH。 */
export const LAYOUT_STORAGE_XML_BYTES: number = 16 * 1024 * 1024
/** 达到此值先迁目录，给元数据迁移、备份与回滚保留XML空间；不作为全库拒写上限。 */
export const LAYOUT_STORAGE_MIGRATION_BYTES: number = 8 * 1024 * 1024
/** 目录后端与会话的有界恢复窗口，增长/历史策略由gamecontrol语义层统一判断。 */
export const LAYOUT_STORAGE_LIBRARY_BYTES: number = 32 * 1024 * 1024
export const LAYOUT_STORAGE_CHUNK_BYTES: number = 256 * 1024
