#!/usr/bin/env node
// scripts/check-renderer-naming.mjs
//
// ============================ 它挡的是什么 ============================
//
// 两条命名纪律（治理规范 §3.2 / §4.2），都是**零命中时成本为零、第一次有人图省事时才响**：
//
// ① **禁止 `MGL` / `mgl_` / `_mgl` 一族记号。**
//    `MG` 前缀在本仓已经**冻结归 MobileGlues**（`MG_DIR_PATH` / `AMCL_MG_FRAME_STATS` /
//    `[MG-STORAGE]` / `mg_src` / `check-mg-*.mjs`…）。MobileGL 是**另一个仓库**的另一个实现，
//    如果它进来时起名 `MGL`，就会出现 `MG_SRC_DIR` 与 `MGL_SRC_DIR`、
//    `check-mg-pin` 与 `check-mgl-pin` 这种**差一个字符、写错的那个会静默编译通过**的对子。
//    ⇒ MobileGL 一律写全 `mobilegl` / `MOBILEGL`。
//    与 `1000543`「一个在所有副本里取值相同的标志位不能用来鉴别副本身份」、
//    `1000547`「新增一个后端就是新增一份副本的机会」同源。
//
// ② **禁止第二个 env / system property 表示同一个渲染后端决策。**
//    治理规范 §1 缺陷 1、2 的成因：`AMCL_GL_BACKEND` 这个 env **只有读者没有写者**
//    （`glfw_osmesa.cpp` 读它，而 `mc_launcher.cpp` 从不 setenv 它），
//    同时 `glfw_osmesa.h` 的注释还声称"当 mc_launcher 设它时…"。
//    ⇒ 同一个决策只允许一种表示：system property `amcl.gl.backend`。
//    ⚠️ 若将来真的**需要** env（跨 linker namespace 时确有必要，本仓已有 5 个这类通道），
//    正确做法是把它加进下面的 `ALLOWED_ENV_PUBLISHERS` 白名单并说明谁写谁读，
//    **不是把本检查删掉**。
//
// ============================ 它不能证明什么 ============================
//
// ❌ 不检查 `id` 与 `prebuilt/<id>/` / `deps.lock [<id>]` 同名（见 check-renderer-registry 的说明）。
// ❌ 不检查注释里提到 `MGL` —— 讨论"为什么不叫 MGL"是应该允许的。⇒ 扫描前剥注释。
//
// 用法：
//   node scripts/check-renderer-naming.mjs
//   node scripts/check-renderer-naming.mjs --json

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

import { stripComments, stripStringLiterals, langForPath } from './lib/source-noise.mjs';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');

/** 扫描范围。刻意不含 `build/` `oh_modules/` `.cxx/` 等产物与依赖副本。 */
export const SCAN_DIRS = [
  'entry/src/main',
  'launch/src',
  'commons/src',
  'feature_core/src',
  'feature_system/src',
  'gamecontrol/src',
  'account/src',
  'mods/src',
  'update/src',
  'scripts',
];

export const SCAN_EXTS = ['.ets', '.ts', '.cpp', '.c', '.h', '.hpp', '.mjs', '.json5'];

/** 产物 / 第三方 / 依赖副本 —— 出现在路径里就跳过。 */
export const SKIP_PATH_PARTS = [
  '/build/', '/oh_modules/', '/.cxx/', '/.test/', '/node_modules/',
  '/third_party/', '/mg_src/', '/lwjgl3_src/', '/prebuilt/',
];

/**
 * 允许用 env 发布的渲染后端决策通道（白名单）。
 *
 * 当前为空：决策只走 system property `amcl.gl.backend`。
 * ⚠️ 加条目时必须同时写清 **谁写、谁读** —— 一个只有读者的 env 就是治理规范 §1 缺陷 1。
 */
export const ALLOWED_ENV_PUBLISHERS = [
  // 例：{ name: 'AMCL_XXX', writer: 'a.cpp', reader: 'b.cpp', why: '跨 linker namespace' }
];

/**
 * 把字符串字面量替换成等长空白（保留换行与偏移）。
 *
 * ⚠️ **被一次误报逼出来的**（施工记录 §S5.2）：本门禁第一版只剥注释，于是
 * `'mgl'` 这个记号在**执行这条禁令的代码自身**里命中了 ——
 * `renderer_backend_ids.h` 的 `static_assert` 消息、`check-renderer-registry.mjs` 的
 * `b.id.includes('mgl')`。一道门禁不能禁止"写出它所禁止的那个字符串"，
 * 否则它连自己都过不了。
 *
 * ⇒ 记号扫描按**标识符**判定（剥字符串），env 扫描按**字符串**判定（保留字符串）。
 *   两种扫描用不同的预处理，这不是重复，是它们问的问题不同。
 *
 * ⚠️ **刻意不处理 `#` 行注释**（这条纪律随实现一起搬走了，留在这里是因为它是本门禁
 * 付过的学费）：首版有一段"行首 `#` 当 shell/CMake 注释"的逻辑，它把
 * `#define <禁用前缀>_SRC_DIR` / `#ifndef` / `#pragma` 整行吃掉 ⇒ 门禁对**所有 C/C++
 * 预处理行漏报**。自测那条「`_SRC_DIR` ⇒ 命中」当场变红（施工记录 §S5.2）。
 * 假阴性比假阳性糟得多：假阳性有人来吵，假阴性永远没人知道。
 * ⇒ `SCAN_EXTS` 里本来就没有 `.cmake` / `.sh`，那段逻辑不解决任何真实问题。
 *
 * ⚰️ 2026-08-27（§S6.2）：`stripStringLiterals` 与 `stripComments` 的实现都搬到了
 * `scripts/lib/source-noise.mjs`。原因见那边的 §缺陷 —— 本文件与
 * `check-renderer-registry.mjs` 各有一份逐字相同的副本，而两份**同时**不认识正则字面量，
 * 于是 `check-renderer-registry.mjs` 里的 `/...([^']*)'/gm` 让引号配对失步，
 * 本门禁报出一处假阳性。⚠️ 更要紧的是同一失步会把**真代码**当字符串抹白 ⇒ 假阴性。
 *
 * 这里继续 re-export，是为了不动 `test-check-renderer-naming.mjs` 的 import。
 */
export { stripStringLiterals, stripComments } from './lib/source-noise.mjs';

export function collectFiles(root = ROOT, dirs = SCAN_DIRS, exts = SCAN_EXTS) {
  const files = [];
  const walk = (abs) => {
    let entries;
    try { entries = fs.readdirSync(abs, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const child = path.join(abs, e.name);
      const posix = child.split(path.sep).join('/');
      if (SKIP_PATH_PARTS.some((p) => `${posix}/`.includes(p))) continue;
      if (e.isDirectory()) { walk(child); continue; }
      if (!exts.includes(path.extname(e.name))) continue;
      files.push(child);
    }
  };
  for (const d of dirs) walk(path.join(root, d));
  return files;
}

/** 本文件自己必然含被禁记号（它在讲这件事），必须自我豁免。 */
export const SELF_EXEMPT = ['scripts/check-renderer-naming.mjs', 'scripts/test-check-renderer-naming.mjs'];

export function analyze(samples) {
  const abbreviation = [];
  const envChannels = [];
  const allowedEnvNames = new Set(ALLOWED_ENV_PUBLISHERS.map((e) => e.name));

  for (const { rel, text } of samples) {
    if (SELF_EXEMPT.includes(rel)) continue;
    // ⚠️⚠️ **逐文件选语言，不能整批用一个模式。**
    //
    // 本门禁扫 840 个文件，其中 **536 个是 C/C++**（`SCAN_EXTS` 含 .c/.h/.cpp/.hpp）。
    // 此前整批走 js 模式 ⇒ 实测 4 个文件被切错，`openal-soft/core/helpers.cpp` 里
    // **2,959 字符的真代码被多抹白** —— 那部分内容本门禁**看不见**，是实打实的假阴性
    // （成因：C++ filesystem 的 `path` 运算符链让 js 的正则启发式失步，
    //  详见 `lib/source-noise.mjs` 的 §LANGS）。
    const opts = { lang: langForPath(rel) };
    const noComments = stripComments(text, opts);
    // 记号按**标识符**判定 ⇒ 连字符串一起剥（见 stripStringLiterals 的说明）。
    const identifiers = stripStringLiterals(noComments, opts);
    // env 名按**字符串/宏名**判定 ⇒ 保留字符串。
    const withStrings = noComments;

    // ① 禁用记号。\b 在下划线两侧不成立，所以显式列出各形态。
    const abbrRe = /\bMGL\b|\bMGL_|_MGL\b|\bmgl_|_mgl\b|\bmgl\b/g;
    let m;
    while ((m = abbrRe.exec(identifiers)) !== null) {
      abbreviation.push({ rel, token: m[0], index: m.index });
    }

    // ② 第二个 env 通道。
    //
    // ⚠️ 判据必须窄到只覆盖**GL 渲染器决策**这一件事。第一版写成
    // `AMCL_[A-Z0-9_]*GL[A-Z0-9_]*BACKEND` —— 那会命中 `AMCL_GLFW_INPUT_BACKEND`
    // （"GLFW" 里含 "GL"），而后者是**输入**系统的 typed/legacy 平面选择开关，
    // 与渲染器毫无关系，且是输入架构规范 §一 的正当机制。误报 18 处。
    //
    // ⇒ 改为要求 `GL_BACKEND` 或 `RENDERER_BACKEND` 作为**整段**出现：
    //    `AMCL_GL_BACKEND` ✅ 命中（正是要抓的那个死通道）
    //    `AMCL_GLFW_INPUT_BACKEND` ✅ 不命中（GLFW_INPUT 不是 GL_BACKEND）
    //    `AMCL_MY_RENDERER_BACKEND_ID` ✅ 命中（新发明的第二通道也抓得到）
    const envRe = /\b(AMCL_[A-Z0-9_]*?(?:GL_BACKEND|RENDERER_BACKEND)[A-Z0-9_]*)\b/g;
    while ((m = envRe.exec(withStrings)) !== null) {
      const name = m[1];
      if (allowedEnvNames.has(name)) continue;
      // ⚠️ include guard 不是 env 通道。`AMCL_RENDERER_BACKEND_IDS_H` 命中过一次误报 ——
      // 它是 `renderer_backend_ids.h` 的头文件保护宏。按 C/C++ 惯例排除 `_H` / `_HPP` 结尾。
      if (/_(H|HPP|H_)$/.test(name)) continue;
      envChannels.push({ rel, name, index: m.index });
    }
  }

  return {
    ok: abbreviation.length === 0 && envChannels.length === 0,
    abbreviation,
    envChannels,
    scanned: samples.length,
  };
}

export function readSamples(root = ROOT) {
  return collectFiles(root).map((abs) => ({
    rel: path.relative(root, abs).split(path.sep).join('/'),
    text: fs.readFileSync(abs, 'utf8'),
  }));
}

function main() {
  const wantJson = process.argv.includes('--json');
  const result = analyze(readSamples());
  if (wantJson) {
    console.log(JSON.stringify(result, null, 2));
    process.exit(result.ok ? 0 : 1);
  }
  if (!result.ok) {
    console.error('[check-renderer-naming] FAIL');
    if (result.abbreviation.length > 0) {
      console.error(`  ${result.abbreviation.length} 处禁用记号（治理规范 §3.2）:`);
      for (const a of result.abbreviation.slice(0, 20)) console.error(`    - ${a.rel}: '${a.token}'`);
      console.error("    ⇒ MG 已冻结归 MobileGlues；MobileGL 一律写全 'mobilegl'。");
      console.error('       差一个字符的记号写错时会静默编译通过，这就是本检查存在的理由。');
    }
    if (result.envChannels.length > 0) {
      console.error(`  ${result.envChannels.length} 处第二个后端决策通道（治理规范 §4.2）:`);
      for (const e of result.envChannels.slice(0, 20)) console.error(`    - ${e.rel}: ${e.name}`);
      console.error('    ⇒ 同一个决策只允许一种表示（system property amcl.gl.backend）。');
      console.error('       确需 env 时把它加进 ALLOWED_ENV_PUBLISHERS 并写清谁写谁读，不要删本检查。');
    }
    process.exit(1);
  }
  console.log(`[check-renderer-naming] PASS   ${result.scanned} files scanned,`
    + ' no forbidden abbreviation, no second backend-decision channel');
  process.exit(0);
}

if (import.meta.url === url.pathToFileURL(process.argv[1] ?? '').href) main();
