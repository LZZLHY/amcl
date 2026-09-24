#!/usr/bin/env node
// check-comment-identifiers.mjs 的定向自测。
//
// 门禁写错的失败方式是**静默放行**：注释里的假标识符照旧漏过去，而检查说 PASS。
// 所以每条性质都必须**双向**测：既测"该报的报了"，也测"不该报的没报"。
//
// 本文件覆盖的每一条都对应一次真实踩过的坑，坑的编号写在用例名里：
//   · 反引号提取与 A::b / foo() / 前后缀通配的归一化；
//   · 字符串字面量里的 `//` 不是注释（否则符号宇宙会缺真实 token → 假命中）；
//   · `#` 行注释必须被切掉（否则 obfuscation-rules.txt 注释里那四个**已删除**的
//     NAPI 名会被注入宇宙，让假注释解析成功 —— 门禁在最该报警处沉默）；
//   · 历史标记降级只对墓碑生效，不得让现在时的假注释闭嘴。

import { normalizeClaim, splitCommentsAndCode } from './check-comment-identifiers.mjs';

let failures = 0;

function check(label, ok, detail) {
  if (ok) {
    console.log(`[test-check-comment-identifiers] PASS: ${label}`);
    return;
  }
  failures += 1;
  console.error(`[test-check-comment-identifiers] FAIL: ${label}`);
  if (detail !== undefined) console.error(`  ${detail}`);
}

// ---- normalizeClaim ----------------------------------------------------------

check('plain identifier resolves to itself',
  normalizeClaim('applyLookDelta')?.symbol === 'applyLookDelta');

check('call syntax is stripped',
  normalizeClaim('isInJoystick()')?.symbol === 'isInJoystick');

check('qualified name uses its last segment',
  normalizeClaim('GameControls.currentInputMode')?.symbol === 'currentInputMode');

check('C++ scope resolution uses its last segment',
  normalizeClaim('Impl::DiscardInFlightLocked')?.symbol === 'DiscardInFlightLocked');

check('arrow member access uses its last segment',
  normalizeClaim('impl_->inFlight')?.symbol === 'inFlight');

// 前缀通配：`AMCL_LOCK_STATE_*` 指一族常量。不认它就会被剥成尾部下划线 → 脚本自己误报。
const prefixClaim = normalizeClaim('AMCL_LOCK_STATE_*');
check('trailing wildcard becomes a prefix query',
  prefixClaim?.prefix === true && prefixClaim.symbol === 'AMCL_LOCK_STATE_',
  JSON.stringify(prefixClaim));

// 后缀通配：`*Transaction` 指 PlatformInput*Transaction 一族。
const suffixClaim = normalizeClaim('*Transaction');
check('leading wildcard becomes a suffix query',
  suffixClaim?.suffix === true && suffixClaim.symbol === 'Transaction',
  JSON.stringify(suffixClaim));

check('prose is rejected rather than guessed at',
  normalizeClaim('two independent evidence chains') === null);

check('file paths are rejected',
  normalizeClaim('touch_input.cpp') === null &&
  normalizeClaim('docs/refactor/x.md') === null);

check('very short spans are rejected',
  normalizeClaim('ok') === null);

// ---- splitCommentsAndCode ---------------------------------------------------

{
  const src = [
    'const char* tag = "AMCL_INSRC // not a comment";',
    'int realSymbol = 1;  // `claimedSymbol` lives only in this comment',
    '/* block `blockClaim` */',
  ].join('\n');
  const { comments, code } = splitCommentsAndCode(src);
  const joined = comments.map(c => c.text).join('\n');
  check('line and block comments are both extracted',
    joined.includes('claimedSymbol') && joined.includes('blockClaim'), joined);
  check('code keeps real symbols', code.includes('realSymbol'));
  // 这一条是承重的：把字符串里的 `//` 当注释起点，会让它后面的**真实代码** token
  // 掉出符号宇宙，于是提到那些 token 的注释全部变成假命中。
  check('a `//` inside a string literal does not start a comment',
    !joined.includes('not a comment'), joined);
  check('string literal contents stay out of the symbol universe',
    !code.includes('AMCL_INSRC'), code);
}

{
  // `#` 注释：默认**不**当注释（C++ 的 #include / #ifdef 是代码）。
  const src = '#include <cstdint>\nint kept = 0;';
  const { code } = splitCommentsAndCode(src);
  check('`#` is code unless hashComments is requested',
    code.includes('include') && code.includes('kept'), code);
}

{
  // obfuscation-rules.txt 的形状：keep-list 是代码，`#` 后面的墓碑不是。
  const src = [
    '# clearButtons / clearJoystick 已随 legacy 注册表一起删除',
    '-keep-property-name',
    'sendSourceKeyEvent',
  ].join('\n');
  const { code, comments } = splitCommentsAndCode(src, { hashComments: true });
  check('hashComments keeps the keep-list entries as code',
    code.includes('sendSourceKeyEvent'), code);
  check('hashComments removes deleted names named only in a `#` tombstone',
    !code.includes('clearButtons') && !code.includes('clearJoystick'), code);
  check('the `#` tombstone is still reported as a comment',
    comments.map(c => c.text).join('\n').includes('clearButtons'));
}

{
  // 行号必须准，否则报出来的位置没法用。
  const src = 'int a = 0;\n\n// `lateClaim` on line three\n';
  const { comments } = splitCommentsAndCode(src);
  const hit = comments.find(c => c.text.includes('lateClaim'));
  check('reported line numbers are 1-based and correct',
    hit !== undefined && hit.line === 3, JSON.stringify(hit));
}

if (failures > 0) {
  console.error(
    `[test-check-comment-identifiers] ${failures} case(s) failed`);
  process.exitCode = 1;
} else {
  console.log('[test-check-comment-identifiers] ALL PASS');
}
