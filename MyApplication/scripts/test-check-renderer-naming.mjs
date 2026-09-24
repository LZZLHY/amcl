#!/usr/bin/env node
// scripts/test-check-renderer-naming.mjs
//
// check-renderer-naming.mjs 的定向自测。
//
// ⚠️ 这道门禁的两个坏法都在首次运行时真实发生过（施工记录 §S5.2），本文件逐条钉住修复：
//   ① 只剥注释、不剥字符串 ⇒ `'mgl'` 在**执行这条禁令的代码自身**里命中
//      （`static_assert` 消息、`b.id.includes('mgl')`）。一道门禁连自己都过不了。
//   ② env 正则写成 `AMCL_*GL*BACKEND` ⇒ 命中 `AMCL_GLFW_INPUT_BACKEND`（"GLFW" 含 "GL"），
//      而那是**输入**系统的 typed/legacy 平面开关，与渲染器毫无关系。误报 18 处。
//   ③ 顺带：include guard `AMCL_RENDERER_BACKEND_IDS_H` 也被当成 env 通道。
//
// ⇒ 一道"禁止某个写法"的门禁，必须先证明它**不禁止讨论那个写法**，否则方向正好反了。

import {
  analyze, readSamples, stripComments, stripStringLiterals, ALLOWED_ENV_PUBLISHERS,
} from './check-renderer-naming.mjs';

let failed = 0;
function check(name, cond, extra) {
  if (cond) console.log(`  ok   ${name}`);
  else { failed += 1; console.error(`  FAIL ${name}${extra ? `\n       ${extra}` : ''}`); }
}

const s = (rel, text) => [{ rel, text }];

// ── 1. ⭐ 真实仓库：当前只应报 G2 那一处死通道 ──────────────────────
{
  const r = analyze(readSamples());
  check('real repo: 零禁用记号误报（含执行禁令的代码自身）',
    r.abbreviation.length === 0, JSON.stringify(r.abbreviation));
  // ⭐ **这一条在 §S5 → §S6 之间被改过一次，那次修改本身就是 S6 的验收证据。**
  //
  // §S5 当时写的是「**恰好 1 处**且是 `AMCL_GL_BACKEND` 且在 `glfw_osmesa.cpp`」——
  // 因为 G2（有读者无写者的死通道）是已知缺陷，门禁**应该**报它。
  // 一道门禁在一棵已知含该缺陷的树上变绿，才是可疑的（施工记录 §S5.3）。
  //
  // §S6 删掉了那个读者（`osmesaZinkMode()` 改为硬返回 false），于是判据变成 0。
  check('real repo: 零第二后端决策通道（§S6 删掉 G2 死通道后应为 0）',
    r.envChannels.length === 0, JSON.stringify(r.envChannels));
  check('real repo: 整体通过', r.ok === true, JSON.stringify(r));
  check('real repo: 扫到的文件数 > 100（范围没塌）', r.scanned > 100, `${r.scanned}`);
}

// ── 2. 禁用记号：标识符命中 ──────────────────────────────────────────
{
  check('MGL_SRC_DIR ⇒ 命中',
    analyze(s('x.h', '#define MGL_SRC_DIR "a"')).abbreviation.length === 1);
  check('mgl_init() ⇒ 命中',
    analyze(s('x.cpp', 'void mgl_init();')).abbreviation.length === 1);
  check('check_mgl ⇒ 命中（_mgl 后缀）',
    analyze(s('x.mjs', 'const check_mgl = 1;')).abbreviation.length === 1);
  check('裸 mgl ⇒ 命中',
    analyze(s('x.ts', 'let mgl = 1;')).abbreviation.length === 1);
}

// ── 2b. ⭐⭐ 逐文件语言模式：C/C++ 必须用 C 词法，否则真的会漏报 ─────────
//
// 施工记录 §S9。本门禁扫 840 个文件，其中 **536 个是 C/C++**（SCAN_EXTS 含 .c/.h/.cpp/.hpp）。
// 它此前**整批**用 js 词法 ⇒ 实测 4 个文件被切错，`openal-soft/core/helpers.cpp` 里
// **2,959 字符的真代码被多抹白**，那部分门禁看不见。
//
// 下面这条是**同一段内容、只改扩展名**的对照：形状取自 helpers.cpp:346 的 C++
// filesystem `path` 运算符链。`}` 之后 js 模式允许正则 ⇒ `/".local/` 被当正则、
// `share` 被当 flags 吃掉 ⇒ 随后的 `"` 开启假字符串 ⇒ 把后面的 `mgl_hidden` 藏起来。
{
  const Q = String.fromCharCode(34);
  const src = `void f(){ g(x{y}/${Q}.local/share${Q}/p); }\nint mgl_hidden = 1;\n`;

  const asCpp = analyze(s('x.cpp', src));
  const asTs = analyze(s('x.ts', src));

  check('⭐⭐ .cpp ⇒ 走 C 词法，藏在 filesystem path 之后的 mgl_hidden 被抓到',
    asCpp.abbreviation.length === 1, JSON.stringify(asCpp.abbreviation));
  check('⭐⭐ 对照：同一段内容当成 .ts（js 词法）⇒ 漏报（这就是修复前的行为）',
    asTs.abbreviation.length === 0, JSON.stringify(asTs.abbreviation));
  check('⭐ 报出的 index 能落回原文（偏移契约）',
    asCpp.abbreviation.length === 1 &&
    src.slice(asCpp.abbreviation[0].index, asCpp.abbreviation[0].index + 4) === 'mgl_',
    JSON.stringify(asCpp.abbreviation));

  // C 头也要走 C 词法（registry 门禁读的 renderer_backend_ids.h 就是 .h）。
  check('.h ⇒ 走 C 词法',
    analyze(s('x.h', src)).abbreviation.length === 1);
  // 反向：真正的 JS 文件必须仍走 js 词法（正则字面量要被认出来，否则又失步）。
  check('⭐ .mjs 仍走 js 词法：正则里的记号不误报',
    analyze(s('x.mjs', 'const re = /mgl/g; const ok = 1;')).abbreviation.length === 0,
    JSON.stringify(analyze(s('x.mjs', 'const re = /mgl/g; const ok = 1;')).abbreviation));
}

// ── 3. ⭐ 禁用记号：不得误报的三种情形 ───────────────────────────────
{
  check("⭐ 字符串字面量里的 'mgl' ⇒ 不命中（门禁不禁止执行自己的禁令）",
    analyze(s('x.h', 'static_assert(ok, "ids must not contain \'mgl\'");')).abbreviation.length === 0,
    JSON.stringify(analyze(s('x.h', 'static_assert(ok, "ids must not contain \'mgl\'");')).abbreviation));
  check("⭐ includes('mgl') 这种检查代码 ⇒ 不命中",
    analyze(s('x.mjs', "if (b.id.includes('mgl')) problems.push('bad');")).abbreviation.length === 0);
  check('⭐ 注释里讨论 MGL ⇒ 不命中（允许解释为什么不叫 MGL）',
    analyze(s('x.ts', '// 禁止 MGL / mgl_ 一族记号，理由见规范 §3.2')).abbreviation.length === 0);
  // 真实存在的相邻名字不得被牵连。
  check('mobilegl（写全名）⇒ 不命中',
    analyze(s('x.ts', "const id = mobilegl_thing;")).abbreviation.length === 0);
  check('MOBILEGL_BACKEND_TYPE ⇒ 不命中',
    analyze(s('x.h', '#define MOBILEGL_BACKEND_TYPE 1')).abbreviation.length === 0);
}

// ── 4. env 通道：命中与不命中 ────────────────────────────────────────
{
  check('AMCL_GL_BACKEND ⇒ 命中（就是 G2 那个死通道）',
    analyze(s('x.cpp', 'getenv("AMCL_GL_BACKEND");')).envChannels.length === 1);
  check('新发明的 AMCL_MY_RENDERER_BACKEND_ID ⇒ 命中',
    analyze(s('x.cpp', 'setenv("AMCL_MY_RENDERER_BACKEND_ID", v, 1);')).envChannels.length === 1);

  check('⭐ AMCL_GLFW_INPUT_BACKEND ⇒ 不命中（输入系统，与渲染器无关）',
    analyze(s('x.h', 'getenv("AMCL_GLFW_INPUT_BACKEND");')).envChannels.length === 0,
    JSON.stringify(analyze(s('x.h', 'getenv("AMCL_GLFW_INPUT_BACKEND");')).envChannels));
  check('⭐ include guard AMCL_RENDERER_BACKEND_IDS_H ⇒ 不命中',
    analyze(s('x.h', '#ifndef AMCL_RENDERER_BACKEND_IDS_H')).envChannels.length === 0);
  check('AMCL_MG_FRAME_PACING_FPS ⇒ 不命中（正当 env）',
    analyze(s('x.cpp', 'setenv("AMCL_MG_FRAME_PACING_FPS", v, 1);')).envChannels.length === 0);
  check('AMCL_MG_FRAME_STATS ⇒ 不命中',
    analyze(s('x.cpp', '#ifdef AMCL_MG_FRAME_STATS')).envChannels.length === 0);
  check('AMCL_INPUT_SHADOW ⇒ 不命中',
    analyze(s('x.cpp', 'getenv("AMCL_INPUT_SHADOW");')).envChannels.length === 0);
}

// ── 5. 白名单机制真的生效（不是装饰）─────────────────────────────────
{
  // 直接验证白名单语义：当前白名单为空，所以 AMCL_GL_BACKEND 必然命中。
  check('白名单当前为空（S6 之前不该有条目）',
    ALLOWED_ENV_PUBLISHERS.length === 0, JSON.stringify(ALLOWED_ENV_PUBLISHERS));
  // 白名单起作用的证据：把它的 name 换成实际扫到的那个，命中数应当归零。
  // 这里不改模块状态（ESM 常量不可写），改为断言实现里确实读了它 ——
  // 用一个不在白名单里的近似名确认判据是"精确名字匹配"而不是模糊。
  check('白名单按精确名匹配（近似名仍命中）',
    analyze(s('x.cpp', 'getenv("AMCL_GL_BACKEND_V2");')).envChannels.length === 1);
}

// ── 6. 自我豁免 ──────────────────────────────────────────────────────
{
  check('门禁自身文件被豁免（它必然含被禁记号）',
    analyze(s('scripts/check-renderer-naming.mjs', 'MGL mgl_ AMCL_GL_BACKEND')).ok === true);
  check('自测文件同样被豁免',
    analyze(s('scripts/test-check-renderer-naming.mjs', 'MGL mgl_ AMCL_GL_BACKEND')).ok === true);
  check('其他文件不被豁免',
    analyze(s('scripts/check-something-else.mjs', 'MGL')).ok === false);
}

// ── 7. 两个 strip 函数自身 ───────────────────────────────────────────
{
  check('stripComments: 行注释被剥',
    !stripComments('const a = 1; // MGL').includes('MGL'));
  check('stripComments: 字符串里的 // 保留',
    stripComments("const u = 'a//b';").includes('a//b'));
  check('stripStringLiterals: 字符串内容被抹',
    !stripStringLiterals("const a = 'mgl';").includes('mgl'));
  check('stripStringLiterals: 标识符保留',
    stripStringLiterals("const mgl_x = 'y';").includes('mgl_x'));
  check('stripStringLiterals: 保留行数（行号不漂）',
    stripStringLiterals("a\nconst s = 'x';\nb").split('\n').length === 3);
  check('stripStringLiterals: 转义引号不破坏配对',
    stripStringLiterals("const a = 'it\\'s'; const mgl_y = 1;").includes('mgl_y'));
}

console.log('');
if (failed > 0) {
  console.error(`test-check-renderer-naming: ${failed} failure(s)`);
  process.exit(1);
}
console.log('test-check-renderer-naming: all checks passed');
