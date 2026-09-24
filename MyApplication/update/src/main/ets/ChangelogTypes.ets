/**
 * ChangelogTypes.ets — 更新日志的分类词表（App 侧唯一定义处）
 *
 * 与 AMCL-web/web/src/changelog/parse.js 的 CATEGORY_ORDER / CATEGORY_LABELS 一一对应。
 * 服务端（生成期）产出的 `type` 就是这里的 key；两边必须同时改，规范见
 * AMCL-web/CHANGELOG-SPEC.md 第二节。
 *
 * 硬规则（规范第三节）：**遇到未知 type 必须归入 notice 展示，不得丢弃、不得抛异常**。
 * 这样服务端将来新增分类时，老客户端只是把它显示成「注意」，而不会白屏或崩。
 *
 * 创建日期：2026-08-08
 */

/** 分类 key。顺序即展示顺序（头条最前、注意最后）。 */
export const NOTE_TYPE_ORDER: string[] = ['highlight', 'added', 'improved', 'refactored', 'fixed', 'notice'];

/** 分类 key → 中文标签（App UI 只有中文，见 entry/src/main/resources 无 en 目录）。 */
export function noteTypeLabel(type: string): string {
  switch (type) {
    case 'highlight': return '头条';
    case 'added': return '新增';
    case 'improved': return '优化';
    case 'refactored': return '重构';
    case 'fixed': return '修复';
    default: return '注意';
  }
}

/** 分类在 NOTE_TYPE_ORDER 中的次序；未知类型排最后。 */
export function noteTypeRank(type: string): number {
  let i = NOTE_TYPE_ORDER.indexOf(type);
  return i < 0 ? NOTE_TYPE_ORDER.length : i;
}

/**
 * 归一化分类：接受服务端 key（highlight/added/…）与中文词（头条/新增/…，
 * 供 notes 纯文本回退路径使用），其余一律归 notice。
 */
export function normalizeNoteType(raw: string): string {
  let s = raw.trim().toLowerCase();
  switch (s) {
    case 'highlight': case 'highlights': case '头条': return 'highlight';
    case 'added': case 'add': case 'feature': case '新增': return 'added';
    case 'improved': case 'improve': case 'perf': case '优化': return 'improved';
    case 'refactored': case 'refactor': case '重构': return 'refactored';
    case 'fixed': case 'fix': case 'bugfix': case '修复': return 'fixed';
    default: return 'notice';
  }
}
