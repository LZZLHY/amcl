// scripts/test-lib-source-noise.mjs
//
// scripts/lib/source-noise.mjs 的定向自测。
//
// ⚠️ **本文件存在的理由**：这个词法前置管道在 §S5 就已上线（当时是两个门禁各一份副本），
// 但只被**间接**测过 —— 自测只断言 `stripComments('a // MGL')` 之类的一行样例。
// 于是"不认识正则字面量 ⇒ 引号配对失步"这个缺陷活到了 §S6.2 才暴露，
// 而暴露它的是一处**假阳性**；同一失步在别处会变成**假阴性**（真代码被当字符串抹白）。
//
// ⇒ **判据：一个做词法切分的东西，必须能直接断言它的切分结果，而不是只能透过
//    调用方的最终判定间接观察。** 这也是 `scanSpans` 被导出的原因。
//
// 用法：node scripts/test-lib-source-noise.mjs

import { scanSpans, stripComments, stripStringLiterals } from './lib/source-noise.mjs';

let failed = 0;
function check(name, cond, extra) {
  if (cond) console.log(`  ok   ${name}`);
  else { failed += 1; console.error(`  FAIL ${name}${extra ? `\n       ${extra}` : ''}`); }
}

/** 把 span 序列压成 `kind:文本` 便于断言。 */
const kinds = (t) => scanSpans(t).map((s) => s.kind);
const spanText = (t, kind) =>
  scanSpans(t).filter((s) => s.kind === kind).map((s) => t.slice(s.start, s.end));

const BT = String.fromCharCode(96);   // 反引号，避免和本文件的模板串打架

// ── 1. ⭐⭐ 回归钉子：正则字面量里的引号不得开启字符串态 ────────────────
{
  // 这就是 §S6.2 的原始现场（check-renderer-registry.mjs:190 的简化版）：
  // 正则里有**两个**单引号，旧实现会把它们当成一对字符串定界符 ⇒ 此后配对整体错位。
  const src = [
    "const re = /^\\s*([A-Za-z]*)\\s*=\\s*'([^']*)'/gm;",
    '// FORBIDDEN_TOKEN_IN_COMMENT',
    "const s = 'real string';",
  ].join('\n');

  check('⭐⭐ 正则后面的行注释仍被剥掉（失步回归钉子）',
    !stripComments(src).includes('FORBIDDEN_TOKEN_IN_COMMENT'),
    JSON.stringify(stripComments(src)));

  check('⭐ 正则之后的真字符串仍被识别为字符串',
    stripStringLiterals(src).includes('const s = ') &&
    !stripStringLiterals(src).includes('real string'),
    JSON.stringify(stripStringLiterals(src)));

  check('⭐ 切分结果里那段正则被标成 regex（而不是 string+code 混杂）',
    spanText(src, 'regex').length === 1 &&
    spanText(src, 'regex')[0] === "/^\\s*([A-Za-z]*)\\s*=\\s*'([^']*)'/gm",
    JSON.stringify(spanText(src, 'regex')));

  check('⭐ 正则体在 stripStringLiterals 里被抹白（正则是模式不是标识符）',
    !stripStringLiterals(src).includes('A-Za-z'),
    JSON.stringify(stripStringLiterals(src)));

  check('⭐ 正则体在 stripComments 里保留（它是代码，不是注释）',
    stripComments(src).includes('A-Za-z'));
}

// ── 2. `/` 的正则 vs 除号判定 ─────────────────────────────────────────
{
  check('标识符之后的 / 是除号',
    kinds('const x = a / b;').every((k) => k === 'code'),
    JSON.stringify(kinds('const x = a / b;')));
  check('数字之后的 / 是除号',
    kinds('const x = 1 / 2;').every((k) => k === 'code'));
  check(') 之后的 / 是除号',
    kinds('const x = f(1) / 2;').every((k) => k === 'code'));
  check('] 之后的 / 是除号',
    kinds('const x = a[0] / 2;').every((k) => k === 'code'));
  check('= 之后的 / 是正则',
    kinds('const r = /ab/;').includes('regex'));
  check('( 之后的 / 是正则',
    kinds('s.split(/,/);').includes('regex'));
  check(', 之后的 / 是正则',
    kinds('f(a, /b/);').includes('regex'));

  // ⭐ 关键字例外：少了这条，`return /'/.test(x)` 里那个 ' 会开启字符串态 ⇒ 又一次失步。
  check("⭐ return 之后的 / 是正则（含单引号也不失步）",
    kinds("function f(x) { return /'/.test(x); }").includes('regex'),
    JSON.stringify(kinds("function f(x) { return /'/.test(x); }")));
  check('⭐ return /re/ 之后的注释仍被剥',
    !stripComments("function f(x) { return /'/.test(x); }\n// TOMB\n").includes('TOMB'));
  check('typeof 之后的 / 是正则',
    kinds('typeof /a/;').includes('regex'));
}

// ── 3. 正则里的字符类：`[/]` 不终止正则 ────────────────────────────────
{
  const src = 'const r = /[/]a/g; const s = "kept";';
  check('字符类里的 / 不终止正则',
    spanText(src, 'regex')[0] === '/[/]a/g',
    JSON.stringify(spanText(src, 'regex')));
  check('字符类之后的字符串仍被正确识别',
    spanText(src, 'string').length === 1 && spanText(src, 'string')[0] === '"kept"',
    JSON.stringify(spanText(src, 'string')));
}

// ── 4. ⭐ 判错方向必须收敛：未闭合不得吞掉后文 ──────────────────────────
{
  // `a` 之后本判为除号，这里刻意造一个会被判成"正则起点"的位置但行内没有第二个 /。
  const src = 'const x = (1) ;\nconst y = 2 ;\n// TOMB\nconst s = "kept";';
  check('⭐ 无正则时全是 code（不误判）',
    !kinds(src).includes('regex'), JSON.stringify(kinds(src)));

  // 真正的回退场景：`= /` 判为正则起点，但该行没有闭合的 `/`。
  const src2 = 'const half = total\n  / 2;\n// TOMB\nconst s = "kept";';
  check('⭐ 未闭合的"正则"回退成普通代码，不吞掉后面的注释与字符串',
    !stripComments(src2).includes('TOMB') && stripComments(src2).includes('"kept"'),
    JSON.stringify(stripComments(src2)));
}

// ── 5. 注释与字符串的基本契约（旧实现已有，回归保护）────────────────────
{
  check('行注释被剥', !stripComments('const a = 1; // SECRET').includes('SECRET'));
  check('块注释被剥', !stripComments('/* SECRET */ const a = 1;').includes('SECRET'));
  check('块注释未闭合 ⇒ 吃到 EOF（不崩）',
    !stripComments('/* SECRET').includes('SECRET'));
  check("字符串里的 // 不当注释",
    stripComments("const u = 'https://x/y';").includes('https://x/y'));
  check('模板串在 stripComments 里保留',
    stripComments(`const t = ${BT}a//b${BT};`).includes('a//b'));
  check('字符串内容在 stripStringLiterals 里被抹',
    !stripStringLiterals("const a = 'SECRET';").includes('SECRET'));
  check('标识符在 stripStringLiterals 里保留',
    stripStringLiterals("const keep_me = 'y';").includes('keep_me'));
  check('转义引号不破坏配对',
    stripStringLiterals("const a = 'it\\'s'; const keep_me = 1;").includes('keep_me'));
  check('模板串整体被抹（§已知取舍 ①：插值里的标识符一并抹掉）',
    !stripStringLiterals(`const t = ${BT}x\${inner_id}y${BT};`).includes('inner_id'));
}

// ── 6. ⭐ 偏移契约：行号与列都不漂 ─────────────────────────────────────
{
  const src = 'a\n// x\nb';
  check('stripComments: 保留行数', stripComments(src).split('\n').length === 3);
  check('⭐ stripComments: 保留总长度（列也不漂，旧实现只保行号）',
    stripComments(src).length === src.length,
    `${stripComments(src).length} vs ${src.length}`);
  const src2 = "a\nconst s = 'xyz';\nb";
  check('stripStringLiterals: 保留行数', stripStringLiterals(src2).split('\n').length === 3);
  check('⭐ stripStringLiterals: 保留总长度',
    stripStringLiterals(src2).length === src2.length);
  check('⭐ 报出的 index 能直接落回原文定位',
    (() => {
      const t = "// pad\nconst bad_ident = 1;";
      const i = stripStringLiterals(stripComments(t)).indexOf('bad_ident');
      return i >= 0 && t.slice(i, i + 9) === 'bad_ident';
    })());
}

// ── 6b. ⭐⭐ C 模式（lang:'c'）─────────────────────────────────────────
{
  const C = { lang: 'c' };

  // ① 普通除法：**两个模式都判对**。
  //
  // ⚠️ 这条曾被我写成「js 模式会把 `a / b / c` 误判成正则」的对照用例，**当场变红** ——
  // 因为 C 的除号左边总有操作数（标识符/数字/`)`/`]`），`canStartRegex` 本来就返回 false。
  // 留着它是为了钉住"不要再用这个错理由去论证 lang:'c'"。
  const div = 'int r = a / b / c;';
  check('普通除法：C 模式不切出 regex',
    !scanSpans(div, C).some((s) => s.kind === 'regex'));
  check('普通除法：js 模式**也**不切出 regex（左边有操作数）',
    !scanSpans(div).some((s) => s.kind === 'regex'),
    JSON.stringify(scanSpans(div).map((s) => s.kind)));

  // ② ⭐⭐ 真正的差异（实测自 openal-soft/core/helpers.cpp:346）：
  //    C++ filesystem 的 `path` 运算符链 —— `}` 之后 js 模式**允许**正则，
  //    于是 `/".local/` 被当正则、`share` 被当 flags 吃掉，随后那个 `"` 开启假字符串，
  //    把后面的块注释整段吞掉。这是本仓真实代码，不是构造出来的。
  const fsPath = 'f(x{y}/".local/share"/p);\n/* TOMBSTONE */\nint keep_e = 1;';
  check('⭐⭐ C 模式：filesystem path 运算符链之后的块注释仍被剥（实测回归钉子）',
    !stripComments(fsPath, C).includes('TOMBSTONE'),
    JSON.stringify(stripComments(fsPath, C)));
  check('⭐⭐ 对照：js 模式在同一段上**失步**，块注释没被剥掉（lang:c 存在的实测理由）',
    stripComments(fsPath).includes('TOMBSTONE'),
    JSON.stringify(stripComments(fsPath)));
  check('⭐ C 模式：该行的标识符不被误抹',
    stripStringLiterals(stripComments(fsPath, C), C).includes('keep_e'));

  // ② 字符字面量 '"' —— 旧的 video-callbacks 实现不跟 `'`，那个 `"` 会开启假字符串。
  const chr = "if (c == '\"') { device->Foo = Bar; }\nint keep_me = 1;";
  check("⭐⭐ C 模式：字符字面量 '\"' 不开启假字符串态（失步回归钉子）",
    stripComments(chr, C).includes('device->Foo = Bar') &&
    stripComments(chr, C).includes('keep_me'),
    JSON.stringify(stripComments(chr, C)));

  // ③ 行稳定：多行块注释必须原地留白，不塌行。这是 video-callbacks 的硬依赖。
  const blk = 'int a;\n/* one\n   two\n   three */\n#if 0\nint dead;\n#endif\nint b;\n';
  check('⭐⭐ C 模式：多行块注释不塌行（video-callbacks 的行号依赖）',
    stripComments(blk, C).split('\n').length === blk.split('\n').length,
    `${stripComments(blk, C).split('\n').length} vs ${blk.split('\n').length}`);
  check('⭐ C 模式：块注释后的 #if 0 仍在自己那一行的行首',
    stripComments(blk, C).split('\n')[4].trim() === '#if 0',
    JSON.stringify(stripComments(blk, C).split('\n')));
  check('⭐ C 模式：块注释内容被抹掉',
    !stripComments(blk, C).includes('three'));

  // ④ 反引号在 C 里是普通字符（注释里大量出现），不得开启模板串。
  const bt = `int x;  /* 见 ${BT}foo${BT} */\nint keep_c = 1;\nint y = 2;`;
  check('⭐ C 模式：注释里的反引号不吞后文',
    stripComments(bt, C).includes('keep_c') && stripComments(bt, C).includes('int y = 2'),
    JSON.stringify(stripComments(bt, C)));
  // 单个不配对的反引号（若按模板串处理会吞到 EOF）
  const bt1 = `int x = 1; /* ${BT} */\nint keep_d = 2;`;
  check('⭐ C 模式：单个不配对反引号不吞到 EOF',
    stripComments(bt1, C).includes('keep_d'),
    JSON.stringify(stripComments(bt1, C)));

  // ⑤ 语言名拼错必须硬失败，不能静默落回 js。
  let threw = false;
  try { scanSpans('int a;', { lang: 'cpp' }); } catch { threw = true; }
  check('⭐ 未知 lang 硬失败（不静默落回 js）', threw);
  check('默认 lang 是 js（不传 opts 时识别正则）',
    scanSpans('const r = /ab/;').some((s) => s.kind === 'regex'));
}

// ── 7. span 序列必须无缝覆盖全文（切分本身的不变量）────────────────────
{
  const samples = [
    "const re = /a'b/g; // c\nconst s = \"d\";",
    `const t = ${BT}x\${y}z${BT}; /* m */ let q = 1 / 2;`,
    '',
    '/* unterminated',
    "const bad = 'unterminated",
  ];
  let ok = true;
  const detail = [];
  for (const t of samples) {
    const spans = scanSpans(t);
    let cursor = 0;
    for (const sp of spans) {
      if (sp.start !== cursor || sp.end < sp.start) { ok = false; detail.push([t, sp, cursor]); }
      cursor = sp.end;
    }
    if (cursor !== t.length) { ok = false; detail.push([t, 'tail', cursor, t.length]); }
  }
  check('⭐ span 无缝、不重叠、覆盖到 EOF', ok, JSON.stringify(detail));
}

console.log('');
if (failed > 0) {
  console.error(`test-lib-source-noise: ${failed} failure(s)`);
  process.exit(1);
}
console.log('test-lib-source-noise: all checks passed');
