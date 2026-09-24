/**
 * source-noise.mjs — 源码文本门禁的**共享前置管道**：剥注释 / 剥字面量。
 *
 * 施工记录 `docs/refactor/渲染后端治理施工记录.md` §S6.2。
 *
 * ## 为什么要有这个文件（而不是每个门禁各抄一份）
 *
 * `check-renderer-registry.mjs` 与 `check-renderer-naming.mjs` 原本各有一份逐字相同的
 * `stripComments`，后者的注释还写着「与 check-renderer-registry.mjs 同款」。
 * §S6 验收时两份**同时**暴露同一个缺陷（见下面 §缺陷），于是同一个 bug 要改两处 ——
 * 这正是本仓反复付过学费的形状（CHANGELOG `1000543`：所有副本里取值相同的标志位
 * 不能鉴别副本身份；`1000549`⑤：同一事实两处各说一套）。
 * ⇒ 提取成一份，两个门禁 `import`。**新增源码文本门禁一律用这里的实现，不要再抄。**
 *
 * ## ⚠️ 缺陷（2026-08-27 §S6 实测发现，是本文件存在的直接原因）
 *
 * 旧实现**不认识正则字面量**。`check-renderer-registry.mjs:190` 有
 *
 * ```js
 * const re = /^\s*([A-Za-z][A-Za-z0-9]*)\s*=\s*'([^']*)'/gm;
 * ```
 *
 * 扫描器走到 `[^']` 的第一个 `'` 就进入"字符串态"，到 `]*)` 后面那个 `'` 才出来 ——
 * **引号配对整体错位**。此后文件里"真正的字符串"与"真正的代码"身份互换，
 * 于是 `analyze()` 上方那行 `//   ② §S5.2：...mgl...` **注释没被剥掉**，
 * 命名门禁报出一处假阳性（`scripts/check-renderer-registry.mjs` 命中禁用记号）。
 *
 * ⭐ **假阳性只是它今天的表现，真正的风险是假阴性**：失步之后"被当成字符串"的那一段
 * 是**真代码**，`stripStringLiterals` 会把它整段抹白 ⇒ 里面若真有禁用记号
 * 或第二个 env 通道，门禁**看不见**。命名门禁自己的注释写着
 * 「假阴性比假阳性糟得多：假阳性有人来吵，假阴性永远没人知道」——
 * 这就是那句话应验的一次，而且是在它自己的前置管道里。
 *
 * ⇒ **判据：在源码文本上做模式匹配的门禁，其词法前置必须能处理正则字面量。**
 *    门禁脚本自身就是正则密集的 JS，这个坑必然反复出现。
 *
 * ## 语义契约（两个门禁都依赖，改动前先看这里）
 *
 * | 函数 | 保留 | 抹白 |
 * |---|---|---|
 * | `stripComments` | 代码、字符串、模板串、正则字面量 | 行注释与块注释 |
 * | `stripStringLiterals` | 代码 | 字符串、模板串、正则（含定界符） |
 *
 * 两者都**用空格逐字符填充**而不是删除 ⇒ 行号与列偏移**都**不漂，
 * 门禁报出的 `index` 可以直接落回原文件定位。（旧实现只保行号不保列。）
 *
 * ## 已知取舍（写下来免得下次当 bug 修）
 *
 * ① **模板串整体抹白，`${...}` 插值里的标识符一并抹掉。** 这会漏掉
 *    `` `${mobileglXyz}` `` 这种写法。没做插值解析是因为它要递归（插值里能再嵌模板串），
 *    而当前两个门禁的判据（禁用记号 / env 通道名）都不依赖插值里的标识符。
 *    ⇒ 若将来某道门禁需要，在这里补插值递归，**不要在调用方绕过本模块**。
 * ② **`/` 是正则还是除号用回看启发式判定**，不是完整 JS 语法分析。回看上一个
 *    非空白**代码**字符（注释与字面量内的字符不参与）：
 *    - 标识符/数字/`)`/`]`/引号/`/` 之后 ⇒ 除号；
 *    - **例外**：`return` / `typeof` / `case` 这类关键字之后仍判为正则
 *      （`REGEX_OK_KEYWORDS`）。少了这条，`return /'/.test(x)` 里的 `'`
 *      会开启字符串态 —— 就是本文件要修的失步问题换个方向再犯一次。
 *    - 其余 ⇒ 正则。
 * ③ **未闭合的"正则"自动回退成普通代码字符。** 防的是把除号误判成正则后
 *    吞掉后面一大片。判错方向必须**收敛**，不能放大。
 *
 * 创建日期：2026-08-27
 */

/**
 * 这些关键字之后的 `/` 是正则而不是除号。
 *
 * ⚠️ 只列**语法上不可能紧跟除号**的（关键字不是值，不能当被除数）。
 * 不要往里加变量名之类 —— 那会让 `a / b` 被当成正则起点，走 ③ 回退虽不失步但白跑。
 */
const REGEX_OK_KEYWORDS = new Set([
  'return', 'typeof', 'case', 'in', 'of', 'do', 'else', 'void', 'delete',
  'instanceof', 'new', 'throw', 'yield', 'await',
]);

const IDENT_CHAR = /[A-Za-z0-9_$]/;

/**
 * ⭐ 语言模式。**必须显式选对，用错会静默给出错答案。**
 *
 * | 模式 | 适用 | 正则字面量 | `` ` `` | `'…'` |
 * |---|---|---|---|---|
 * | `js`（默认） | `.mjs` `.ts` `.ets` | **识别** | 模板串 | 字符串 |
 * | `c` | `.c` `.h` `.cpp` | **不识别**（C 里 `/` 永远是除号） | **普通字符** | 字符字面量 |
 *
 * ⚠️ **为什么 C 模式必须关掉正则识别（实测理由，不是推想）**：
 *
 * 我最初给的理由是「`x = a / b / c;` 会被判成正则 `/ b /`」—— **那是错的，自测当场变红**：
 * C 的除号左边总有操作数（标识符/数字/`)`/`]`），`canStartRegex` 本来就返回 false。
 *
 * 真实触发形状实测自本仓 `entry/src/main/cpp/openal/openal-soft/core/helpers.cpp:346`
 * （C++ filesystem 的 `path` 运算符链）：
 *
 * ```cpp
 * DirectorySearch(homepath{…}/".local/share"/path, ext, &results);
 * ```
 *
 * `}` 之后 js 模式**允许**正则 ⇒ `/".local/` 被当成正则字面量、`share` 被当成 flags
 * 一并吃掉 ⇒ 随后那个 `"` 开启一段假字符串 ⇒ **把后面的块注释整段吞掉**。
 *
 * 实测爆炸半径（`check-renderer-naming` 的真实扫描集，840 文件 / 其中 **536 个 C/C++**）：
 * 4 个文件被切错，`helpers.cpp` 有 **2,959 字符的真代码被多抹白** ——
 * 那部分内容门禁**看不见**，正是假阴性。
 *
 * ⚠️ **为什么 C 模式要把 `` ` `` 当普通字符**：C 里反引号只出现在注释与字符串里
 * （本仓注释大量用它做代码标记）。若按模板串处理，注释外偶然出现的一个反引号会
 * 开启一段"模板串"并吞到下一个反引号 —— 那正是 §S6.2 那类失步换个方向再犯一次。
 */
const LANGS = new Set(['js', 'c']);

/**
 * C 家族扩展名。放这里是为了让"扩展名 → 语言"这条映射**只有一处**。
 *
 * ⚠️ **`.java` 归在这里**：Java 的注释与字面量词法与 C 逐条相同，而它**没有**正则字面量。
 * 落 js 模式的代价是把某个 `/` 当成正则起点、把后面一整段真代码抹白 ⇒ 那是本文件
 * 头注释里那类**假阴性**（门禁看不见的代码）。2026-09-04 之前 `.java` 落的是 js 默认值。
 */
const C_FAMILY_EXT = [
  '.c', '.h', '.cpp', '.hpp', '.cc', '.cxx', '.hxx', '.inc', '.java',
];

/**
 * 按路径/文件名推断语言模式。
 *
 * ⚠️ **扫多种扩展名的门禁必须逐文件调它**，不能整批用一个模式 ——
 * `check-renderer-naming` 扫 840 个文件而其中 **536 个是 C/C++**，
 * 此前整批走 js 模式，实测 4 个文件被切错（见 §LANGS 的实测数据）。
 *
 * 未知扩展名落 `js`：本仓的门禁脚本与 ArkTS 都是 JS 家族，
 * 而 C 家族的扩展名是封闭且已知的 ⇒ 默认落 js 的误判面更小。
 */
export function langForPath(p) {
  const lower = String(p).toLowerCase();
  return C_FAMILY_EXT.some((e) => lower.endsWith(e)) ? 'c' : 'js';
}

/**
 * 单遍词法扫描，把源码切成不重叠、覆盖全文的 span 序列。
 *
 * `kind`: `code` | `line-comment` | `block-comment` | `string` | `template` | `regex`
 *
 * 导出是为了让自测能**直接**断言切分结果，而不是只能透过两个 strip 函数间接观察 ——
 * 本文件修的那个 bug 之所以活了两批，正因为切分本身没有被直接测过。
 *
 * @param {string} text
 * @param {{lang?: 'js'|'c'}} [opts] 见 `LANGS` 上方的说明。默认 `js`。
 */
export function scanSpans(text, opts = {}) {
  const lang = opts.lang ?? 'js';
  // 拼错语言名必须硬失败，不能静默落回 js —— 那会让一道 C 门禁悄悄用错规则。
  if (!LANGS.has(lang)) {
    throw new Error(`source-noise: 未知 lang '${lang}'（可选：${[...LANGS].join(' / ')}）`);
  }
  const allowRegex = lang === 'js';
  const backtickIsTemplate = lang === 'js';

  const spans = [];
  const n = text.length;
  let i = 0;
  let codeStart = 0;
  /** 上一个非空白代码字符（注释/字面量内的不算）。 */
  let lastSignificant = '';
  /** 正在累积的标识符；到 `/` 的判定点时它就是"紧邻的那个词"。 */
  let wordBuf = '';

  const flushCode = (end) => {
    if (end > codeStart) spans.push({ kind: 'code', start: codeStart, end });
  };

  while (i < n) {
    const c = text[i];
    const c2 = text[i + 1];

    // ── 行注释 ──（不动 lastSignificant / wordBuf：注释对语法不可见）
    if (c === '/' && c2 === '/') {
      flushCode(i);
      let j = i;
      while (j < n && text[j] !== '\n') j += 1;
      spans.push({ kind: 'line-comment', start: i, end: j });
      i = j;
      codeStart = i;
      continue;
    }

    // ── 块注释 ──
    if (c === '/' && c2 === '*') {
      flushCode(i);
      let j = i + 2;
      while (j < n && !(text[j] === '*' && text[j + 1] === '/')) j += 1;
      j = j < n ? j + 2 : n;                        // 未闭合则吃到 EOF
      spans.push({ kind: 'block-comment', start: i, end: j });
      i = j;
      codeStart = i;
      continue;
    }

    // ── 字符串 / 模板串 / C 的字符字面量 ──
    if (c === '"' || c === "'" || (c === '`' && backtickIsTemplate)) {
      flushCode(i);
      let j = i + 1;
      // ⚠️ C 模式下字符串不跨行（除非行尾续行），JS 模板串跨行。这里刻意不区分：
      //    未闭合就吃到 EOF，由下面的 Math.min 收口 —— 宁可多抹一段，不要失步。
      while (j < n) {
        if (text[j] === '\\') { j += 2; continue; }
        if (text[j] === c) { j += 1; break; }
        j += 1;
      }
      j = Math.min(j, n);
      spans.push({ kind: c === '`' ? 'template' : 'string', start: i, end: j });
      i = j;
      codeStart = i;
      lastSignificant = c;                          // 字符串是一个值
      wordBuf = '';
      continue;
    }

    // ── 正则字面量（仅 js 模式；C 里 `/` 永远是除号）──
    if (allowRegex && c === '/' && canStartRegex(lastSignificant, wordBuf)) {
      let j = i + 1;
      let inClass = false;
      let closed = false;
      while (j < n) {
        const d = text[j];
        if (d === '\\') { j += 2; continue; }
        if (d === '\n') break;                      // 正则不跨行 ⇒ 判错了
        if (inClass) { if (d === ']') inClass = false; j += 1; continue; }
        if (d === '[') { inClass = true; j += 1; continue; }
        if (d === '/') { j += 1; closed = true; break; }
        j += 1;
      }
      if (!closed) {
        // §已知取舍 ③：回退成普通代码字符，`/` 仍留在当前 code span 里。
        lastSignificant = c;
        wordBuf = '';
        i += 1;
        continue;
      }
      while (j < n && /[a-z]/.test(text[j])) j += 1; // flags
      flushCode(i);
      spans.push({ kind: 'regex', start: i, end: j });
      i = j;
      codeStart = i;
      lastSignificant = '/';                        // 正则是一个值
      wordBuf = '';
      continue;
    }

    // ── 普通代码字符 ──
    if (IDENT_CHAR.test(c)) {
      wordBuf += c;
    } else if (!/\s/.test(c)) {
      wordBuf = '';
    }
    if (!/\s/.test(c)) lastSignificant = c;
    i += 1;
  }

  flushCode(n);
  return spans;
}

/** 见 §已知取舍 ②。`word` 是紧邻 `/` 的那个标识符（可能为空）。 */
function canStartRegex(lastSignificant, word) {
  if (lastSignificant === '') return true;                       // 文件开头
  if (word.length > 0) return REGEX_OK_KEYWORDS.has(word);       // 关键字例外
  if (IDENT_CHAR.test(lastSignificant)) return false;            // 保险：值之后
  if (lastSignificant === ')' || lastSignificant === ']') return false;
  if (lastSignificant === '"' || lastSignificant === "'") return false;
  if (lastSignificant === '`' || lastSignificant === '/') return false;
  return true;
}

/** 逐字符换空格，换行/回车原样保留 ⇒ 行号与列偏移都不漂。 */
function blank(s) {
  let out = '';
  for (const ch of s) out += (ch === '\n' || ch === '\r') ? ch : ' ';
  return out;
}

const COMMENT_KINDS = new Set(['line-comment', 'block-comment']);
const LITERAL_KINDS = new Set(['string', 'template', 'regex']);

/**
 * 剥注释，保留代码 / 字符串 / 模板串 / 正则。
 *
 * 用途：判据按"源码里出现过某个**写法**"计的检查（env 宏名、字面量 id 等）——
 * 它们需要看见字符串内容，所以只能剥注释。
 *
 * 为什么必须剥：本仓的注释纪律**鼓励**留墓碑注释引用旧代码原文
 * （「改造前是 `jvmArgs.indexOf('-Damcl.gl.backend=gl4es')`」）。一道禁止某写法的门禁
 * 若不剥注释，就会禁止"解释为什么不再这么写"，方向正好反了。
 * 这一类 bug 在渲染后端门禁里咬过**四次**（§S5.1 / §S5.2 / §S6 native 镜像 / §S6.2 本次）。
 */
export function stripComments(text, opts = {}) {
  let out = '';
  for (const s of scanSpans(text, opts)) {
    const raw = text.slice(s.start, s.end);
    out += COMMENT_KINDS.has(s.kind) ? blank(raw) : raw;
  }
  return out;
}

/**
 * 剥字符串 / 模板串 / 正则（含定界符），只留代码骨架。
 * **不剥注释** —— 需要时先跑 `stripComments`。
 *
 * 用途：判据按"源码里出现过某个**标识符**"计的检查。字符串里的禁用记号
 * 不是标识符，而恰恰是"执行禁令的代码自身"最常见的形态 ⇒ 必须剥，否则门禁禁止自己。
 * 正则体同理（`/mgl/` 是模式不是标识符），且标识符不可能出现在正则体里 ⇒ 抹掉零损失。
 */
export function stripStringLiterals(text, opts = {}) {
  let out = '';
  for (const s of scanSpans(text, opts)) {
    const raw = text.slice(s.start, s.end);
    out += LITERAL_KINDS.has(s.kind) ? blank(raw) : raw;
  }
  return out;
}
