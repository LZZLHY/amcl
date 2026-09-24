/**
 * ChineseVariant.ets — 中文繁体 → 简体归一化（供中文搜索前置处理）
 *
 * 背景：译名库（mcmod 导出）里的中文名是**简体**。用户若输入繁体（如「機械動力」），
 * 直接与简体库匹配会 0 命中。对齐 PCL 的 `StrConv(text, SimplifiedChinese)`，
 * 在中文搜索前把查询词统一转简体。
 *
 * 实现：优先用系统 ICU 音译器 `@ohos.i18n` 的 Transliterator（零维护、覆盖全）。
 * 不同 ROM/ICU 版本的音译器 id 命名可能不同，故按候选 id 逐个尝试；
 * 全部不可用 / 抛异常时**降级为原样返回**（不影响简体输入，繁体仅退化为"不转换"）。
 *
 * best-effort：任何异常都吞掉并返回输入，绝不因繁简转换失败而破坏搜索。
 *
 * 创建日期：2026-07-03
 */

import { i18n } from '@kit.LocalizationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'ChineseVariant';

/**
 * ICU 繁→简音译器候选 id。不同实现命名不一，逐个试，第一个能构造成功的即用。
 * 常见：'Traditional-Simplified' / 'Hant-Hans' / 't2s'。
 */
const CANDIDATE_IDS: string[] = ['Traditional-Simplified', 'Hant-Hans', 't2s'];

/** 转换器状态：0=未尝试 / 1=就绪 / 2=不可用（本进程内不再重试）。 */
let state_: number = 0;
let translit_: i18n.Transliterator | null = null;

function ensureTransliterator_(): i18n.Transliterator | null {
  if (state_ === 1) return translit_;
  if (state_ === 2) return null;
  try {
    let available: string[] = [];
    try { available = i18n.Transliterator.getAvailableIDs(); } catch (e) { available = []; }
    for (let id of CANDIDATE_IDS) {
      // 若能拿到可用列表则先筛，拿不到就直接尝试构造
      if (available.length > 0 && available.indexOf(id) < 0) continue;
      try {
        let t = i18n.Transliterator.getInstance(id);
        if (t !== null && t !== undefined) {
          translit_ = t;
          state_ = 1;
          hilog.info(0x0000, TAG, 'transliterator ready: %{public}s', id);
          return translit_;
        }
      } catch (e) { /* 试下一个 id */ }
    }
    // 可用列表拿不到时，最后再无差别尝试一次候选（覆盖 getAvailableIDs 不含但可构造的情况）
    if (available.length === 0) {
      for (let id of CANDIDATE_IDS) {
        try {
          let t = i18n.Transliterator.getInstance(id);
          if (t !== null && t !== undefined) {
            translit_ = t;
            state_ = 1;
            hilog.info(0x0000, TAG, 'transliterator ready (blind): %{public}s', id);
            return translit_;
          }
        } catch (e) { /* 试下一个 */ }
      }
    }
  } catch (e) { /* 整体不可用 */ }
  state_ = 2;
  hilog.info(0x0000, TAG, 'no traditional->simplified transliterator available, passthrough');
  return null;
}

/**
 * 把可能含繁体的中文串转为简体。无中文 / 转换器不可用 / 异常 → 原样返回。
 */
export function toSimplifiedChinese(text: string): string {
  if (text.length === 0) return text;
  let t = ensureTransliterator_();
  if (t === null) return text;
  try {
    let out = t.transform(text);
    return (out !== null && out !== undefined && out.length > 0) ? out : text;
  } catch (e) {
    return text;
  }
}
