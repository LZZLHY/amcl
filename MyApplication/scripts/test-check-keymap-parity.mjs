#!/usr/bin/env node
// scripts/test-check-keymap-parity.mjs
//
// check-keymap-parity.mjs 的定向自测。
//
// ⚠️ 只证明"当前两份表一致"是不够的 —— 那种检查**在它坏掉之后也一样是绿的**。
// 所以这里逐条制造分叉，要求门禁真的红；并且要求"解析不出来"走**硬失败**而不是
// "0 个分歧 ⇒ 通过"（本仓的门禁事故里，最贵的一类正是判据按写法枚举、新写法静默漏过）。

import { analyze, readSources } from './check-keymap-parity.mjs';

let failed = 0;
function check(name, cond, extra) {
  if (cond) {
    console.log(`  ok   ${name}`);
  } else {
    failed += 1;
    console.error(`  FAIL ${name}${extra ? `\n       ${extra}` : ''}`);
  }
}

/**
 * 必须真的替换到东西：夹具本身写错了会让用例变成空真。
 * `from` 允许是正则 —— 源文件是 CRLF，跨行的字面量夹具会静默匹配不上。
 */
function mutate(texts, key, from, to) {
  const before = texts[key];
  const hit = typeof from === 'string' ? before.includes(from) : from.test(before);
  if (!hit) throw new Error(`fixture broken: ${key} 里找不到 ${from}`);
  const after = before.replace(from, to);
  if (after === before) throw new Error(`fixture broken: ${key} 替换没生效`);
  return { ...texts, [key]: after };
}

const real = readSources();

// ── 1. 正向：真实仓库状态必须通过（否则后面的反向用例都不可读）
{
  const r = analyze(real);
  check('real repo: 两份表一致', r.ok === true, r.fatal ?? JSON.stringify(r.valueMismatch));
  check('real repo: 键数非零且两侧相等',
    r.arkTsKeys > 0 && r.arkTsKeys === r.cppKeys, `${r.arkTsKeys} vs ${r.cppKeys}`);
}

// ── 2. C++ 侧改一个离散条目的目标值 ⇒ valueMismatch
{
  // 2050u (SPACE) -> 32 改成 33
  const r = analyze(mutate(real, 'adapterText', 'case 2050u: mapped = 32; break;', 'case 2050u: mapped = 33; break;'));
  check('C++ 改一个 case 值 ⇒ 不通过', r.ok === false);
  check('C++ 改一个 case 值 ⇒ 指出 2050 且报出两侧值',
    r.valueMismatch.length === 1 && r.valueMismatch[0].ohos === 2050
    && r.valueMismatch[0].arkTs === 32 && r.valueMismatch[0].cpp === 33,
    JSON.stringify(r.valueMismatch));
}

// ── 3. ArkTS 侧删掉一个条目 ⇒ onlyInCpp
{
  const r = analyze(mutate(real, 'keyMapText',
    /case OHOS_KEYCODE_MENU: return GLFW_KEY_MENU\s*/, ''));
  check('ArkTS 少一个条目 ⇒ 不通过', r.ok === false);
  check('ArkTS 少一个条目 ⇒ 报成 onlyInCpp(2067)',
    r.onlyInCpp.length === 1 && r.onlyInCpp[0].ohos === 2067, JSON.stringify(r.onlyInCpp));
}

// ── 4. 区间端点分叉（C++ 把 Z 从 2042 缩到 2041）⇒ onlyInArkTs
{
  const r = analyze(mutate(real, 'adapterText',
    'physicalKey >= 2017u && physicalKey <= 2042u', 'physicalKey >= 2017u && physicalKey <= 2041u'));
  check('区间端点缩一格 ⇒ 不通过', r.ok === false);
  check('区间端点缩一格 ⇒ 报成 onlyInArkTs(2042)',
    r.onlyInArkTs.length === 1 && r.onlyInArkTs[0].ohos === 2042, JSON.stringify(r.onlyInArkTs));
}

// ── 5. 区间起点分叉（C++ 把 A 的 GLFW 基准从 65 挪到 64）⇒ 整段 26 个 mismatch
{
  const r = analyze(mutate(real, 'adapterText',
    'mapped = 65 + static_cast<int32_t>(physicalKey - 2017u);',
    'mapped = 64 + static_cast<int32_t>(physicalKey - 2017u);'));
  check('区间基准整段偏移 ⇒ 26 个 mismatch',
    r.ok === false && r.valueMismatch.length === 26, `${r.valueMismatch.length}`);
}

// ── 6. ⭐ 未识别的写法必须硬失败，不能算成"0 个分歧"
{
  // 把一个 case 改成门禁不认识的等价写法（`mapped=` 之外的赋值形式）。
  const r = analyze(mutate(real, 'adapterText',
    'case 2050u: mapped = 32; break;', 'case 2050u: { mapped = 32; } break;'));
  check('C++ 出现未识别写法 ⇒ fatal（不是静默通过）',
    r.ok === false && typeof r.fatal === 'string' && r.fatal.includes('未被识别'), r.fatal ?? 'no fatal');
}
{
  const r = analyze(mutate(real, 'keyMapText',
    'case OHOS_KEYCODE_MENU: return GLFW_KEY_MENU',
    'case OHOS_KEYCODE_MENU: { return GLFW_KEY_MENU }'));
  check('ArkTS 出现未识别写法 ⇒ fatal（不是静默通过）',
    r.ok === false && typeof r.fatal === 'string' && r.fatal.includes('未被识别'), r.fatal ?? 'no fatal');
}

// ── 7. 常量解析不到 ⇒ fatal（而不是把那一条悄悄跳过）
{
  const r = analyze(mutate(real, 'ohosKeyCodesText', 'export const OHOS_SPACE = 2050', '// removed'));
  check('OHOS 常量缺失 ⇒ fatal',
    r.ok === false && (r.fatal ?? '').includes('无法解析'), r.fatal ?? 'no fatal');
}

// ── 8. 锚点函数被改名 / 兜底语义变了 ⇒ fatal
{
  const r = analyze(mutate(real, 'adapterText', 'bool MapOhosKey(', 'bool MapOhosKeyRenamed('));
  check('C++ 锚点函数找不到 ⇒ fatal', r.ok === false && (r.fatal ?? '').includes('找不到锚点'), r.fatal ?? 'no fatal');
}
{
  const r = analyze(mutate(real, 'keyMapText', /default:\s*return 0/, 'default:\n      return -1'));
  check('ArkTS 兜底从 0 变成 -1 ⇒ fatal',
    r.ok === false && (r.fatal ?? '').includes('default: return 0'), r.fatal ?? 'no fatal');
}
{
  const r = analyze(mutate(real, 'adapterText', 'outKey->key = mapped;', 'outKey->key = 0;'));
  check('C++ 解析出的表不再是出参 ⇒ fatal',
    r.ok === false && (r.fatal ?? '').includes('outKey->key = mapped;'), r.fatal ?? 'no fatal');
}

// ── 9. 同一个 OHOS 码被映射两次 ⇒ fatal（区间与 case 重叠是最容易漏的一种）
{
  const r = analyze(mutate(real, 'adapterText',
    'case 2012u: mapped = 265; break;', 'case 2017u: mapped = 265; break;'));
  check('C++ 区间与 case 撞码 ⇒ fatal',
    r.ok === false && (r.fatal ?? '').includes('被映射了两次'), r.fatal ?? 'no fatal');
}

console.log(failed === 0 ? 'ALL PASS' : `${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
