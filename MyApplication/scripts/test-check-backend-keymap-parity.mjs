#!/usr/bin/env node
// scripts/test-check-backend-keymap-parity.mjs
//
// check-backend-keymap-parity.mjs 的定向自测。
//
// ⚠️ 这道门禁最贵的坏法是**解析不到就当成空表然后报 0 个分歧** —— 那正好发生在"有人改了
// 其中一份表的写法"的时候，也就是最该说话的时候。所以下面每一条"解析失败"用例都要求 fatal。

import { analyze, readAll } from './check-backend-keymap-parity.mjs';

let failed = 0;
function check(name, cond, extra) {
  if (cond) console.log(`  ok   ${name}`);
  else { failed += 1; console.error(`  FAIL ${name}${extra ? `\n       ${extra}` : ''}`); }
}

function mutate(texts, key, from, to) {
  const before = texts[key];
  if (before === null) throw new Error(`fixture broken: ${key} 源文件不存在`);
  const hit = typeof from === 'string' ? before.includes(from) : from.test(before);
  if (!hit) throw new Error(`fixture broken: ${key} 里找不到 ${from}`);
  const after = before.replace(from, to);
  if (after === before) throw new Error(`fixture broken: ${key} 替换没生效`);
  return { ...texts, [key]: after };
}

const real = readAll();
const plane = (r, name) => r.planes.find((p) => p.name === name);

// ── 1. 正向
{
  const r = analyze(real);
  check('real repo: 通过', r.ok === true, r.fatal ?? JSON.stringify(r.planes));
  check('real repo: OHOS→GLFW 定义域非空', r.ohosToGlfw > 0, `${r.ohosToGlfw}`);
  check('real repo: 两条平面都有条目',
    plane(r, 'lwjgl2').actual > 0 && plane(r, 'sdl3').actual > 0);
  // LWJGL2 少一条（PRINT_SCREEN）是旧链既有差异，钉住它以免哪天被"顺手补齐"而无人察觉。
  check('real repo: LWJGL2 恰好比 SDL3 少一条（PRINT_SCREEN）',
    plane(r, 'sdl3').actual - plane(r, 'lwjgl2').actual === 1,
    `${plane(r, 'lwjgl2').actual} vs ${plane(r, 'sdl3').actual}`);
}

// ── 2. ⭐ 一步表改一个值 ⇒ mismatch（这是门禁存在的全部理由）
{
  const r = analyze(mutate(real, 'backendKeymaps',
    'case 2050u: mapped = 57; break;', 'case 2050u: mapped = 58; break;'));
  check('一步表改一个值 ⇒ 不通过', r.ok === false);
  const p = plane(r, 'lwjgl2');
  check('一步表改一个值 ⇒ 点名 ohos=2050 并给出期望值',
    p.mismatch.length === 1 && p.mismatch[0].ohos === 2050
    && p.mismatch[0].expected === 57 && p.mismatch[0].actual === 58,
    JSON.stringify(p.mismatch));
}

// ── 3. 一步表少一条 ⇒ missing
{
  // ⚠️ 必须是**全局**正则：`case 2067u` 在两张表里各有一条（值不同），非全局只删第一处，
  // 用例名说的"两条平面各一次"就会变成空真。这一条是自测自己踩出来的。
  const r = analyze(mutate(real, 'backendKeymaps',
    /case 2067u: mapped = \d+; break;\s*/g, ''));
  check('一步表少一条 ⇒ 报 missing（两条平面各一次）',
    r.ok === false && plane(r, 'lwjgl2').missing.length === 1
    && plane(r, 'sdl3').missing.length === 1,
    JSON.stringify([plane(r, 'lwjgl2').missing, plane(r, 'sdl3').missing]));
}

// ── 4. ⭐ 旧链改了而新表没跟 ⇒ 同样要红。方向对称是这道门禁的关键性质：
//    它不是"检查新表抄对了"，而是"三份表互相一致"。
{
  const r = analyze(mutate(real, 'glfwToLwjgl2',
    'case 32: return 0x39;', 'case 32: return 0x3A;'));
  check('旧链（GLFW→LWJGL2）改了而新表没跟 ⇒ 不通过',
    r.ok === false && plane(r, 'lwjgl2').mismatch.length === 1,
    JSON.stringify(plane(r, 'lwjgl2').mismatch));
}
{
  const r = analyze(mutate(real, 'ohosToGlfw',
    'case 2050u: mapped = 32; break;', 'case 2050u: mapped = 44; break;'));
  check('第一步（OHOS→GLFW）改了 ⇒ 两条平面同时红',
    r.ok === false && plane(r, 'lwjgl2').mismatch.length >= 1
    && plane(r, 'sdl3').mismatch.length >= 1);
}

// ── 5. 一步表多出一个旧链没有的键 ⇒ extra（挡"顺手加了个新键位"）
{
  const r = analyze(mutate(real, 'backendKeymaps',
    'case 2000u: mapped = 11; break;',
    'case 2000u: mapped = 11; break;\n            case 2078u: mapped = 99; break;'));
  check('一步表多一条 ⇒ 报 extra',
    r.ok === false && plane(r, 'lwjgl2').extra.some((e) => e.ohos === 2078),
    JSON.stringify(plane(r, 'lwjgl2').extra));
}

// ── 6. 四个锚点各改一次 ⇒ 全部 fatal（不是"0 个分歧 ⇒ 通过"）
for (const [key, from, to, label] of [
  ['ohosToGlfw', 'bool MapOhosKey(', 'bool MapOhosKeyGone(', 'OHOS→GLFW 锚点'],
  ['glfwToLwjgl2', 'private static int glfwToLwjgl2Key(int g)',
    'private static int glfwToLwjgl2KeyGone(int g)', 'GLFW→LWJGL2 锚点'],
  ['glfwToSdlSymbolic', 'static SDL_Scancode OPENHARMONY_ScancodeFromGlfwKey(int key)',
    'static SDL_Scancode OPENHARMONY_ScancodeGone(int key)', 'GLFW→SDL 锚点'],
  ['backendKeymaps', 'bool Sdl3MapOhosKey(', 'bool Sdl3MapOhosKeyGone(', '一步表锚点'],
]) {
  const r = analyze(mutate(real, key, from, to));
  check(`${label}改名 ⇒ fatal`,
    r.ok === false && (r.fatal ?? '').includes('找不到锚点'), r.fatal ?? 'no fatal');
}

// ── 7. 兜底语义变了 ⇒ fatal（三份表各一次）
{
  const r = analyze(mutate(real, 'glfwToLwjgl2', 'default: return 0;', 'default: return -1;'));
  check('GLFW→LWJGL2 兜底变更 ⇒ fatal',
    r.ok === false && (r.fatal ?? '').includes('兜底'), r.fatal ?? 'no fatal');
}
{
  const r = analyze(mutate(real, 'glfwToSdlSymbolic',
    'default: return SDL_SCANCODE_UNKNOWN;', 'default: return SDL_SCANCODE_A;'));
  check('GLFW→SDL 兜底变更 ⇒ fatal',
    r.ok === false && (r.fatal ?? '').includes('兜底'), r.fatal ?? 'no fatal');
}

// ── 8. 未知 scancode 符号 ⇒ fatal（挡"patch 用了一个 SDLScancode.java 里没有的名字"）
{
  const r = analyze(mutate(real, 'glfwToSdlSymbolic',
    'case 32: return SDL_SCANCODE_SPACE;', 'case 32: return SDL_SCANCODE_MADE_UP;'));
  check('未知 SDL scancode 符号 ⇒ fatal',
    r.ok === false && (r.fatal ?? '').includes('未知 scancode 符号'), r.fatal ?? 'no fatal');
}

// ── 9. 源文件缺失 ⇒ fatal，而不是当成空表通过
{
  const r = analyze({ ...real, sdlScancodeValues: null });
  check('SDL scancode 数值表缺失 ⇒ fatal',
    r.ok === false && (r.fatal ?? '').includes('不存在'), r.fatal ?? 'no fatal');
}

// ── 10. 同一个键在一步表里出现两次 ⇒ fatal
{
  const r = analyze(mutate(real, 'backendKeymaps',
    'case 2001u: mapped = 2; break;',
    'case 2001u: mapped = 2; break;\n            case 2000u: mapped = 11; break;'));
  check('一步表撞码 ⇒ fatal',
    r.ok === false && (r.fatal ?? '').includes('出现两次'), r.fatal ?? 'no fatal');
}

console.log(failed === 0 ? 'ALL PASS' : `${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
