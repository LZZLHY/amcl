#!/usr/bin/env node
// scripts/preflight.mjs
//
// 跨平台预检脚本 — 提交前一键验收。
//
// 检查清单与实际数量以本文件 add(...) 注册项为准；下方保留每项的完整理由：
//   1. line-refs:      文档/代码中 `@path:N` 引用漂移。**只有 OOR 是硬错**。
//   2. java-build:     编译 JavaApp/src + JavaApp/test。
//   3. java-tests:     运行下方 suites 清单中的测试套件，totalFail 必须为 0。
//   4. bash-syntax:    对 .sh 跑 `bash -n`（⚠️ 缺 bash 时报 ok 并跳过）。
//   5. json5-parse:    6 个 json5 可解析。
//   6. lf-eol:         .sh 必须 LF（CRLF 会让 bash 报 syntax error）。
//   7. glfw-surface:   GLFW native 必需/可选符号缺失均须为 0。
//   8. napi-obfuscation: 全部跨语言固定 ABI 名受 Release 混淆 keep-list 保护。
//   9. comment-ids:    注释里以现在时提到的标识符必须真的存在（类型 A）。
//  10. comment-layering: 棘轮 —— 任何文件的最长连续注释块不得变长。
//  11. hvigor-testlog: "ArkTS 断言失败必须让构建失败"那条判定逻辑**自身**的自测。
//  12. wire-json-obfuscation: 属性名混淆与"用接口读外部 JSON"不能同时成立（含自测）。
//  13. nav-param-keys: 导航传参的写侧键名与读侧取值口径必须一致（含自测）。
//  14. obfuscation-rules: 混淆指令白名单 + 反射入口名必须 keep（含自测）。
//  15. cpp-assert: 首方 C++ 不得出现运行期 assert(（release 的 NDEBUG 会删掉它，含自测）。
//  16. empty-catch-napi: 棘轮 —— 空 catch 不得包住 testNapi.* 调用（含自测）。
//  17. keymap-parity: 物理键盘映射表的 ArkTS 与 C++ 两份实现必须逐条一致（含自测）。
//  18. typed-sink-wiring: typed 事件的消费端不得静默缺席（含自测 + 声明式例外清单）。
//  19. backend-keymap-parity: 新的一步后端映射必须等于旧的两步复合（含自测）。
//  20. renderer-registry: canonical 图形注册表、派生兼容入口与 native 生成镜像必须一致（含自测）。
//  21. jdk-release-pin: JDK 发行版四处 SoT 必须一致（含自测）。
//  22. renderer-naming: 禁止后端缩写及第二条决策通道（含共享词法自测）。
//  23. sdl3-multiwindow: SDL3 混合多窗口 + 宿主激活源码/patch 契约
//      （含逐规则负向 fixture）。
//  24. gamecontrol-scope: HAR 仅由 entry 消费；桌面私有进程须独立初始化（含自测）。
//  25. input-build-profile: debug/release 与各产品的 native 输入平面闭包（含自测）。
//  26. sdl3-text-session: SDL3 typed TextInputSession patch 顺序、ABI 与 read/release 契约（含自测）。
//  27. gate-f-readiness: menu absolute 证据/产品启用前，原子 owner、三后端与 legacy 退役必须闭包（含自测）。
//  28. device-automation: P0 宿主编排器的判定工具正反向自测（解析器 / 五值判决 / 脱敏；
//      真实样本组在 CI 上显式 SKIP，原始日志不入库）。
//  29. product-identity: 产品身份 banner 的字段覆盖、解析后能力位来源、以及
//      **必须排在 setNativeLogSink 之后**（含自测）。
//      runtime-compat: 冻结 Minecraft 消费者 API、AWT/GLFW 接线与最终 native 指纹（含负向自测和真实 Mixin 变换）。
//  30. graphics-profile-inventory: 图形请求/候选隔离、失败快照、GLES/GLFW 生命周期、WSI 诊断、SDL presentation、静态盘点与产物门禁自测；明确不把
//      源码引用或工作树 ELF 当作运行时/真机成功证据。
//  32. logging-evidence: 日志域、关键故障持久化、分享/UI失败恢复与 host/game writer 回归。
//      runtime-foundation: JDK 元数据/区间、选定 LWJGL 槽与部署、平板持久进程策略/布局保存、ELF 输入边界；仅宿主证据。
//      runtime-ownership: JVM 前属性冻结/参数适配、真实JNA协议与独立native槽、精确槽名单、真实 JNI 加载器归属、SDL 消费者初始化与 processor 精确等待；不替代设备矩阵。
//      runtime-exit: 独立游戏退出身份/有界记录、真实宿主 JNI exit/halt 回调与活动恢复；不替代平板 OS/前台验收。
//      workspace-layout: 最后检查物理目录与链接；Agent 配置、自建临时/运行资料不得回流主项目，含负向自测。
//
// ⚠️ 本注释块自己曾经过期过（只列到第 8 项、写"4 个套件、断言总数 ≥101"），
// 而 `docs/release-checklist.md` §0 同时写着"预期 6 项全绿"+ 一个不存在的 `--strict`。
// **新增检查项时必须同时改三处**：这里、`docs/release-checklist.md` §0、
// `.github/workflows/ci.yml` 的 preflight job 注释。
// ⚠️ 这句话此前只点了前两处、漏了 ci.yml —— 一份"提醒别人别漏"的清单自己漏了一项，
// 于是那处项数腐烂了一整轮（2026-08-24 补齐）。三处都是"看起来权威的过期清单"，
// 而这个项目已经因为读了自己文档里的过期结论付过多次学费。
//
// 退出码：0 = 全绿；非 0 = 至少一项失败。
//
// 用法:
//   node scripts/preflight.mjs               # 完整跑
//   node scripts/preflight.mjs --skip=tests  # 跳过 java tests
//   node scripts/preflight.mjs --only=lf-eol # 只跑指定项

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';
import { spawnSync, execSync } from 'node:child_process';
import { parseJson5 as parseProjectJson5 } from './product-contract.mjs';
import { workspacePath } from './lib/workspace-paths.mjs';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
const argv = process.argv.slice(2);
const opt = (k) => {
  const m = argv.find((a) => a.startsWith(`--${k}=`));
  return m ? m.slice(k.length + 3).split(',') : null;
};
const SKIP = opt('skip') || [];
const ONLY = opt('only');

const isWin = process.platform === 'win32';
const checks = [];
const results = [];

function add(name, fn) {
  checks.push({ name, fn });
}

function shouldRun(name) {
  if (ONLY) return ONLY.includes(name);
  return !SKIP.includes(name);
}

function color(s, c) {
  return `\x1b[${c}m${s}\x1b[0m`;
}
const red = (s) => color(s, 31);
const green = (s) => color(s, 32);
const yellow = (s) => color(s, 33);
const dim = (s) => color(s, 90);

// ─────────────────────────────────────────────
// 1. line-refs
add('line-refs', () => {
  const r = spawnSync('node', ['scripts/check-line-refs.mjs'], { cwd: ROOT, encoding: 'utf8' });
  const txt = (r.stdout || '') + (r.stderr || '');
  // 提取 STALE / OOR 数量
  // “STALE:” 会被 “SOFTSTALE:” 误命中，加行首锚定位
  const mStale = txt.match(/^\s+STALE:\s+(\d+)/m);
  const mOOR = txt.match(/^\s+OOR:\s+(\d+)/m);
  const mSoft = txt.match(/^\s+SOFTSTALE:\s+(\d+)/m);
  const stale = mStale ? parseInt(mStale[1]) : 0;
  const oor = mOOR ? parseInt(mOOR[1]) : 0;
  const soft = mSoft ? parseInt(mSoft[1]) : 0;
  // 只有 OOR（行号越界）才是硬错。STALE 是启发式检查，误报在所难免，当作信息输出。
  const ok = oor === 0;
  return {
    ok,
    summary: `OOR=${oor}  STALE=${stale}  SOFTSTALE=${soft}  (只有 OOR 是硬错，其余人工复查)`,
    detail: ok ? null : 'OOR refs detected; run `node scripts/check-line-refs.mjs` for details',
  };
});

// ─────────────────────────────────────────────
// 2. java-build
function findJavac() {
  // PATH first; then JAVA_HOME
  for (const cmd of [isWin ? 'javac.exe' : 'javac', isWin ? 'java.exe' : 'java']) {
    const r = spawnSync(cmd, ['-version'], { encoding: 'utf8', shell: false });
    if (r.status === 0 || r.status === 2) return cmd.replace(/\.exe$/, '');
  }
  if (process.env.JAVA_HOME) {
    return path.join(process.env.JAVA_HOME, 'bin', isWin ? 'javac.exe' : 'javac');
  }
  return null;
}

function listJavaFiles(dir) {
  const out = [];
  function walk(d) {
    for (const ent of fs.readdirSync(d, { withFileTypes: true })) {
      const full = path.join(d, ent.name);
      if (ent.isDirectory()) walk(full);
      else if (ent.isFile() && ent.name.endsWith('.java')) out.push(full);
    }
  }
  walk(dir);
  return out;
}

add('java-build', () => {
  const javac = findJavac();
  if (!javac) return { ok: false, summary: 'javac not found in PATH or JAVA_HOME' };

  const javaApp = path.join(ROOT, 'JavaApp');
  // preflight 自建 Java 测试树与正式 JavaApp 制品分离，避免递归清理时碰到已有发布中间物。
  const buildDir = workspacePath('build', 'preflight-java');
  const cls = path.join(buildDir, 'classes');
  const tcls = path.join(buildDir, 'test-classes');
  fs.rmSync(buildDir, { recursive: true, force: true });
  fs.mkdirSync(cls, { recursive: true });
  fs.mkdirSync(tcls, { recursive: true });

  const srcs = listJavaFiles(path.join(javaApp, 'src'));
  const r1 = spawnSync(javac, ['-d', cls, '-source', '17', '-target', '17', ...srcs], { cwd: javaApp, encoding: 'utf8' });
  if (r1.status !== 0) {
    return { ok: false, summary: 'src compile FAIL', detail: (r1.stdout || '') + (r1.stderr || '') };
  }
  const tests = listJavaFiles(path.join(javaApp, 'test'));
  const r2 = spawnSync(javac, ['-d', tcls, '-source', '17', '-target', '17', '-cp', cls, ...tests], { cwd: javaApp, encoding: 'utf8' });
  if (r2.status !== 0) {
    return { ok: false, summary: 'test compile FAIL', detail: (r2.stdout || '') + (r2.stderr || '') };
  }
  return { ok: true, summary: `${srcs.length} src + ${tests.length} test files compiled` };
});

// ─────────────────────────────────────────────
// 3. java-tests
add('java-tests', () => {
  const javaApp = path.join(ROOT, 'JavaApp');
  const cls = workspacePath('build', 'preflight-java', 'classes');
  const tcls = workspacePath('build', 'preflight-java', 'test-classes');
  if (!fs.existsSync(tcls)) {
    return { ok: false, summary: 'build artifacts missing — run java-build first' };
  }
  const cp = `${tcls}${path.delimiter}${cls}`;
  const suites = ['com.amcl.launcher.LaunchConfigTest', 'com.amcl.launcher.AmclClassLoaderTest', 'com.amcl.launcher.ForgeHelperTest', 'com.amcl.launcher.DebugProfileCompatTest', 'com.amcl.launcher.AmclLauncherTest', 'com.amcl.launcher.AwtRuntimeTest'];
  let totalPass = 0;
  let totalFail = 0;
  const fails = [];
  for (const s of suites) {
    const r = spawnSync('java', ['-cp', cp, s], { cwd: javaApp, encoding: 'utf8' });
    const txt = (r.stdout || '') + (r.stderr || '');
    const m = txt.match(/Results:\s+(\d+) passed,\s+(\d+) failed/);
    if (!m) {
      fails.push(`${s}: no Results line; exit=${r.status} signal=${r.signal} error=${r.error?.message || '(none)'}\n${txt.split(/\r?\n/).slice(-20).join('\n')}`);
      continue;
    }
    totalPass += parseInt(m[1]);
    totalFail += parseInt(m[2]);
    if (r.status !== 0) fails.push(`${s}: exit ${r.status}, ${m[1]}p/${m[2]}f`);
  }
  const ok = totalFail === 0 && fails.length === 0;
  return {
    ok,
    summary: `${totalPass} passed, ${totalFail} failed across ${suites.length} suites`,
    detail: fails.length ? fails.join('\n') : null,
  };
});

// ─────────────────────────────────────────────
// 4. bash-syntax
add('bash-syntax', () => {
  // try bash, if missing skip
  try {
    execSync('bash --version', { stdio: 'ignore' });
  } catch {
    return { ok: true, summary: 'bash not available, skipped' };
  }
  const shFiles = [];
  function walk(d, depth = 0) {
    if (depth > 3) return; // 不深入
    for (const ent of fs.readdirSync(d, { withFileTypes: true })) {
      if (ent.isDirectory()) {
        if (['.git', 'node_modules', 'build', 'oh_modules', '.hvigor', '.idea', 'output'].includes(ent.name)) continue;
        walk(path.join(d, ent.name), depth + 1);
      } else if (ent.isFile() && ent.name.endsWith('.sh')) {
        shFiles.push(path.relative(ROOT, path.join(d, ent.name)).replace(/\\/g, '/'));
      }
    }
  }
  walk(ROOT);
  const errs = [];
  for (const f of shFiles) {
    const r = spawnSync('bash', ['-n', f], { cwd: ROOT, encoding: 'utf8' });
    if (r.status !== 0) errs.push(`${f}: ${(r.stderr || '').trim().split('\n')[0]}`);
  }
  return {
    ok: errs.length === 0,
    summary: `${shFiles.length} .sh files: ${errs.length === 0 ? 'all OK' : `${errs.length} errors`}`,
    detail: errs.length ? errs.join('\n') : null,
  };
});

// ─────────────────────────────────────────────
// 5. json5-parse — 与产品构建共用配置解析器，支持首行注释且不改写字符串内容。

add('json5-parse', () => {
  const targets = [
    'entry/build-profile.json5',
    'entry/build-profile.json5.template',
    'entry/code-linter.json5',
    'build-profile.json5',
    'oh-package.json5',
    'entry/oh-package.json5',
  ].filter((f) => fs.existsSync(path.join(ROOT, f)));
  const errs = [];
  for (const f of targets) {
    try {
      parseProjectJson5(fs.readFileSync(path.join(ROOT, f), 'utf8'));
    } catch (e) {
      errs.push(`${f}: ${e.message}`);
    }
  }
  return {
    ok: errs.length === 0,
    summary: `${targets.length} json5 files: ${errs.length === 0 ? 'all parsed' : `${errs.length} errors`}`,
    detail: errs.length ? errs.join('\n') : null,
  };
});

// ─────────────────────────────────────────────
// 6. lf-eol — .sh 必须 LF
add('lf-eol', () => {
  const targets = [];
  function walk(d, depth = 0) {
    if (depth > 3) return;
    for (const ent of fs.readdirSync(d, { withFileTypes: true })) {
      if (ent.isDirectory()) {
        if (['.git', 'node_modules', 'build', 'oh_modules', '.hvigor', '.idea'].includes(ent.name)) continue;
        walk(path.join(d, ent.name), depth + 1);
      } else if (ent.isFile() && ent.name.endsWith('.sh')) {
        targets.push(path.relative(ROOT, path.join(d, ent.name)).replace(/\\/g, '/'));
      }
    }
  }
  walk(ROOT);
  const crlf = [];
  for (const f of targets) {
    const txt = fs.readFileSync(path.join(ROOT, f), 'utf8');
    if (txt.includes('\r\n')) crlf.push(f);
  }
  return {
    ok: crlf.length === 0,
    summary: `${targets.length} .sh files: ${crlf.length === 0 ? 'all LF' : `${crlf.length} have CRLF`}`,
    detail: crlf.length ? crlf.map((f) => `  ${f}`).join('\n') : null,
  };
});

// ─────────────────────────────────────────────
// 7. glfw-surface — GLFW native 符号覆盖门禁（方案 B）
add('glfw-surface', () => {
  const r = spawnSync('node', ['scripts/check-glfw-surface.mjs', '--json'], { cwd: ROOT, encoding: 'utf8' });
  let data;
  try {
    data = JSON.parse(r.stdout || '{}');
  } catch {
    return { ok: false, summary: 'check-glfw-surface.mjs produced no JSON', detail: (r.stdout || '') + (r.stderr || '') };
  }
  // 硬门禁：native 必需 + Optional 符号都必须全覆盖（方案 B：上游原版 GLFW.class 会查/调全部符号）。
  const nativeMissing = data.nativeMissingRequiredCount ?? 0;
  const optMissing = data.nativeMissingOptionalCount ?? 0;
  const ok = nativeMissing === 0 && optMissing === 0;
  // version-sync：native glfwGetVersionString 版本号应与 deps.lock 部署版本一致。
  const verMismatch = data.deployedVersion && data.nativeVersionNum
    && data.deployedVersion !== data.nativeVersionNum;
  const missingDetail = [
    ...(data.nativeMissingRequired || []).map((s) => `required:${s}`),
    ...(data.nativeMissingOptional || []).map((s) => `optional:${s}`),
  ];
  return {
    ok,
    summary: `native 符号缺 必需${nativeMissing}/Optional${optMissing}（须 0/0）${verMismatch ? '；⚠️版本串不一致' : ''}`,
    detail: ok ? null : `native missing symbols: ${missingDetail.join(', ')}`,
  };
});

// ─────────────────────────────────────────────
// 8. napi-obfuscation — native 固定字符串 ABI 必须保留 ArkTS 属性名
add('napi-obfuscation', () => {
  const r = spawnSync('node', ['scripts/check-napi-obfuscation.mjs', '--json'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  let data;
  try {
    data = JSON.parse(r.stdout || '{}');
  } catch {
    return {
      ok: false,
      summary: 'check-napi-obfuscation.mjs produced no JSON',
      detail: (r.stdout || '') + (r.stderr || ''),
    };
  }
  const missing = data.missing || [];
  return {
    ok: r.status === 0 && data.ok === true && missing.length === 0,
    summary: `${data.requiredCount ?? 0} ABI names kept; missing=${missing.length}`,
    detail: missing.length ? `missing keep names: ${missing.join(', ')}` : null,
  };
});

// ─────────────────────────────────────────────
// 9. comment-identifiers — 注释里用现在时提到的标识符必须真的存在（类型 A）
//
// 为什么值得一道门禁：这一类的代价已经付过一次真的 —— `isControlVisible` 的头注释
// 声称包含 capability 判定，而它引用的两个标识符两个月前就随功能删了，那段注释被当成
// 规格读了一遍，变成一条错误的真机复测判据，用户照着测了一整轮才发现。
// 此前八轮的排查全是从已知事故反推，覆盖是抽样的；这道门禁把它变成机械全量。
add('comment-ids', () => {
  const r = spawnSync('node', ['scripts/check-comment-identifiers.mjs', '--json'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  let data;
  try {
    data = JSON.parse(r.stdout || '{}');
  } catch {
    return {
      ok: false,
      summary: 'check-comment-identifiers.mjs produced no JSON',
      detail: (r.stdout || '') + (r.stderr || ''),
    };
  }
  const hard = data.hard || [];
  return {
    ok: r.status === 0 && hard.length === 0,
    // advisory 与 literalOnly 一起打出来是刻意的：它们是这道门禁**看不见**的部分，
    // 只报 "0 hard" 会让人以为注释全对了。
    summary:
      `${data.claims ?? 0} claims, ${hard.length} unresolved; ` +
      `${(data.advisory || []).length} tombstones, ` +
      `${data.literalOnly ?? 0} literal-only, ${data.rejected ?? 0} not checked`,
    detail: hard.length
      ? hard.map(h => `${h.file}:${h.line} \`${h.raw}\``).join('\n')
      : null,
  };
});

// ─────────────────────────────────────────────
// 10. comment-layering — 注释不得再长回去（棘轮）
//
// 它挡的不是"注释多"，是**连续注释块过长**导致打开文件看不见代码。实测（2026-08-21）：
// 输入子系统 19% 是注释、64 个块 ≥20 行、6 个 ≥40 行，最极端的一个文件 115 行里 87 行注释。
// 成因是规范 §八.6 被按字面执行：注释累积成内嵌变更日志，同一套因果在计划/规范/代码里
// 各写一遍。棘轮语义（只禁止变长、允许按批偿还）是刻意的 —— 一上线就 64 处全红的门禁
// 下一轮就会被忽略。
add('comment-layering', () => {
  const r = spawnSync('node', ['scripts/check-comment-layering.mjs', '--json'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  let data;
  try {
    data = JSON.parse(r.stdout || '{}');
  } catch {
    return {
      ok: false,
      summary: 'check-comment-layering.mjs produced no JSON',
      detail: (r.stdout || '') + (r.stderr || ''),
    };
  }
  const grew = data.diff?.grew ?? [];
  const added = data.diff?.added ?? [];
  const shrank = data.diff?.shrank ?? [];
  const m = data.measured ?? {};
  return {
    ok: grew.length === 0 && added.length === 0,
    summary:
      `${m.commentPct ?? m.pct ?? '?'}% comments, ` +
      `${m.blocksOverWarn ?? '?'} blocks>=20, ${m.blocksOverLoud ?? '?'} blocks>=40; ` +
      `grew=${grew.length} paidDown=${shrank.length}`,
    detail: (grew.length || added.length)
      ? [...grew.map(g => `${g.file}: ${g.before} -> ${g.now} lines @ L${g.at}`),
         ...added.map(a => `new file ${a.file}: ${a.now} lines @ L${a.at}`)].join('\n')
      : null,
  };
});

// ─────────────────────────────────────────────
// 11. hvigor-test-log — "ArkTS 断言失败必须让构建失败"这条判定逻辑自身的自测
//
// 这里跑的**不是** ArkTS 单测本体（那需要 OHOS SDK，只在 build-hap.ps1 的 [3/7] 里跑），
// 而是那一步用来判读输出的 check-hvigor-test-log.mjs 的自测。为什么单独立一项：
// 2026-08-21 实测发现 `hvigorw test` 在断言失败时仍报 BUILD SUCCESSFUL 且退出码 0
// ⇒ 出货脚本原来那句 `if ($LASTEXITCODE -ne 0)` 是 fail-open 的。替代它的判定要靠
// "先剥 ANSI 再匹配 hvigor ERROR:"，而那条前提写错就是**静默永绿**（我第一版就写错了）。
// 所以判定逻辑必须有自测，且自测要在没有 SDK 的机器上也能跑 —— 正好是 preflight 的位置。
add('hvigor-testlog', () => {
  const r = spawnSync('node', ['scripts/test-check-hvigor-test-log.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const out = (r.stdout || '') + (r.stderr || '');
  const passCount = (out.match(/PASS:/g) || []).length;
  return {
    ok: r.status === 0,
    summary: r.status === 0
      ? `${passCount} self-tests pass (ANSI-strip precondition pinned)`
      : 'self-test failed',
    detail: r.status === 0 ? null : out,
  };
});

// ─────────────────────────────────────────────
// 12. wire-json-obfuscation — 属性名混淆与"用接口读外部 JSON"不能同时成立
//
// 与第 8 项同一个病，受害者不同：第 8 项守的是 native 固定字符串 ABI，这一项守的是
// HTTP 响应 / 落盘 JSON 的键名。2026-08-22 真机定案：release 包里 `raw.latest` 被改写成
// `raw.n84`，版本列表 / 模组列表 / 加载器列表 / 整合包清单 / 正版登录全部静默失效，而
// debug 恒绿、报错还伪装成"请检查网络连接" —— 一个只在出货产物里存在的失败面。
// 现在 -enable-property-obfuscation 已移除，这道门禁负责"这个决定不被人默默改回去"。
add('wire-json-obfuscation', () => {
  const r = spawnSync('node', ['scripts/check-wire-json-obfuscation.mjs', '--json'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  let data;
  try {
    data = JSON.parse(r.stdout || '{}');
  } catch {
    return {
      ok: false,
      summary: 'check-wire-json-obfuscation.mjs produced no JSON',
      detail: (r.stdout || '') + (r.stderr || ''),
    };
  }
  const self = spawnSync('node', ['scripts/test-check-wire-json-obfuscation.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const ok = r.status === 0 && data.ok === true && self.status === 0;
  // unresolvedRootTypes 与 atRisk 一起打出来是刻意的：它们是这道门禁**看不见**和
  // **暂时容忍**的部分，只报 ok 会让人以为属性名混淆已经可以安全打开。
  return {
    ok,
    summary:
      `property-obf ${data.propertyObfuscationEnabled ? 'ON' : 'off'}; ` +
      `${data.wireFieldCount ?? 0} wire fields / ${data.wireRootTypes ?? 0} root types, ` +
      `${data.atRiskIfEnabled ?? 0} unkept, ${(data.unresolvedRootTypes || []).length} unresolved`,
    detail: ok
      ? null
      : [
        data.unkept?.length ? `unkept wire fields: ${data.unkept.join(', ')}` : null,
        self.status === 0 ? null : (self.stdout || '') + (self.stderr || ''),
      ].filter(Boolean).join('\n'),
  };
});

// ─────────────────────────────────────────────
// 13. nav-param-keys — 导航传参的写侧键名与读侧取值口径必须一致
//
// 与第 8、12 项同一个病的第三个受害者：键名跨越 ArkTS 编译单元边界。
// 标识符键会被属性名混淆改名、字符串下标不会，混着用就断链。2026-08-22 审计实测到一处
// （Index.performLaunch 用标识符键写 6 个启动参数、McGamePage.startMC 用 params?.['…'] 读），
// 属性名混淆一旦回归，内嵌模式启动游戏的全部参数变 undefined，而 debug 恒正常。
//
// 判据取**一致性**不取**风格**：本仓另有 6 处是"标识符写 + 接口标识符读"，两侧共用同一张
// 重命名表、自洽且安全。要求它们改成引号键会连读侧一起动 6 个页面，换不到正确性 ——
// 而一个会误报的门禁下一轮就会被忽略。
add('nav-param-keys', () => {
  const r = spawnSync('node', ['scripts/check-nav-param-keys.mjs', '--json'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  let data;
  try {
    data = JSON.parse(r.stdout || '{}');
  } catch {
    return {
      ok: false,
      summary: 'check-nav-param-keys.mjs produced no JSON',
      detail: (r.stdout || '') + (r.stderr || ''),
    };
  }
  const self = spawnSync('node', ['scripts/test-check-nav-param-keys.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const violations = data.violations || [];
  const unresolved = data.unresolvedSites || [];
  const ok = r.status === 0 && data.ok === true && self.status === 0;
  // unresolved 一起打出来是刻意的：那是这道门禁**跟不动**的间接引用，
  // 只报 0 violations 会让人以为所有传参点都查过了。
  return {
    ok,
    summary:
      `${data.navSites ?? 0} nav sites / ${data.subscriptReadKeyCount ?? 0} subscript keys; ` +
      `${violations.length} mismatched, ${unresolved.length} unresolved`,
    detail: ok
      ? null
      : [
        violations.length
          ? violations.map((v) => `${v.file}:${v.line} ${v.api}.${v.key} 应写成引号键`).join('\n')
          : null,
        self.status === 0 ? null : (self.stdout || '') + (self.stderr || ''),
      ].filter(Boolean).join('\n'),
  };
});

// ─────────────────────────────────────────────
// 14. obfuscation-rules — 混淆规则文件的单点控制面
//
// 两件事：① 未知 `-enable-*` 不得悄悄进来（第 8、12 项各只认自己关心的那一个 flag，
// 别的加进来两边都不出声，而一个 flag 就能让下载与登录两大功能域在 release 全坏）；
// ② `-keep-global-name` 必须覆盖 module.json5 里被系统按字符串反射的入口名 ——
// 现状是对的，这道门禁保证将来新增 ability 时不会忘，忘了的代价是出货包起不来、debug 全绿。
add('obfuscation-rules', () => {
  const r = spawnSync('node', ['scripts/check-obfuscation-rules.mjs', '--json'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  let data;
  try {
    data = JSON.parse(r.stdout || '{}');
  } catch {
    return {
      ok: false,
      summary: 'check-obfuscation-rules.mjs produced no JSON',
      detail: (r.stdout || '') + (r.stderr || ''),
    };
  }
  const self = spawnSync('node', ['scripts/test-check-obfuscation-rules.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const bad = [
    ...(data.rejectedDirectives || []),
    ...(data.unknownDirectives || []),
    ...(data.unkeptReflectedNames || []),
  ];
  const ok = r.status === 0 && data.ok === true && self.status === 0;
  return {
    ok,
    summary:
      `${data.directiveCount ?? 0} directives, ` +
      `${(data.reflectedNames || []).length} reflected names kept`,
    detail: ok
      ? null
      : [bad.length ? bad.join('\n') : null,
        self.status === 0 ? null : (self.stdout || '') + (self.stderr || '')]
        .filter(Boolean).join('\n'),
  };
});

// ─────────────────────────────────────────────
// 15. cpp-assert — 首方 C++ 不得出现运行期 assert(
//
// release 由 SDK toolchain 注入 `-DNDEBUG`（本仓 CMakeLists 里**没有**任何 build-type
// 分支，所以改本仓察觉不到这个差异），`assert()` 整条被预处理器删掉 —— 副作用写在里面
// 就只在出货包里消失。首方现在 0 命中，这道门禁是趁干净钉住而不是清债。
// vendored 的 openal-soft 有 126 处（编译进 87），它是 gitignored 可重克隆物，走目录级黑名单。
add('cpp-assert', () => {
  const r = spawnSync('node', ['scripts/check-cpp-runtime-assert.mjs', '--json'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  let data;
  try {
    data = JSON.parse(r.stdout || '{}');
  } catch {
    return {
      ok: false,
      summary: 'check-cpp-runtime-assert.mjs produced no JSON',
      detail: (r.stdout || '') + (r.stderr || ''),
    };
  }
  const self = spawnSync('node', ['scripts/test-check-cpp-runtime-assert.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const hits = data.hits || [];
  const ok = r.status === 0 && data.ok === true && self.status === 0;
  return {
    ok,
    summary: `${data.scannedFiles ?? 0} first-party TU; ${hits.length} hits`,
    detail: ok
      ? null
      : [hits.map((h) => `${h.file}:${h.line} [${h.kind}] ${h.text}`).join('\n') || null,
        self.status === 0 ? null : (self.stdout || '') + (self.stderr || '')]
        .filter(Boolean).join('\n'),
  };
});

// ─────────────────────────────────────────────
// 16. empty-catch-napi — 空 catch 不得包住 testNapi.* 调用（棘轮）
//
// 它挡的是**两次 release-only 事故共同的放大器**：`catch (e) { /* 老 native 兼容 */ }`
// 把"这个接口被混淆改名了"变成"什么都没发生"。三个帧率 NAPI 因此在所有开混淆的 release
// 包里从未工作过，而 debug 恒绿、日志一行不打。
// ⚠️ 逐条核对过：那句"老 native 兼容"对当前代码 **0 条成立** —— 51 处覆盖的 31 个 NAPI 名
// 在 index.d.ts 与 native 侧 31/31 都存在，libentry.so 随 HAP 打包，不存在旧 native 组合。
// 这些 catch 唯一能真正触发的场景就是混淆改名，也就是最该炸出来的那个。
// 棘轮语义是刻意的：51 处里 14 处在每输入事件/每 250ms 的热路径上，无条件 warn 会刷爆日志，
// 只能改成计数器或一次性置位 —— 一上线就 51 处全红的门禁下一轮就会被忽略。
add('empty-catch-napi', () => {
  const r = spawnSync('node', ['scripts/check-empty-catch-napi.mjs', '--json'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  let data;
  try {
    data = JSON.parse(r.stdout || '{}');
  } catch {
    return {
      ok: false,
      summary: 'check-empty-catch-napi.mjs produced no JSON',
      detail: (r.stdout || '') + (r.stderr || ''),
    };
  }
  const self = spawnSync('node', ['scripts/test-check-empty-catch-napi.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const grew = data.diff?.grew ?? [];
  const added = data.diff?.added ?? [];
  const shrank = data.diff?.shrank ?? [];
  const ok = data.hasBaseline === true && grew.length === 0 && added.length === 0
    && self.status === 0;
  // total 与 paidDown 一起打出来是刻意的：只报 "0 grew" 会让人以为这 51 处已经不是问题。
  return {
    ok,
    summary:
      `${data.total ?? 0} empty catch around NAPI (baseline ratchet); ` +
      `grew=${grew.length} new=${added.length} paidDown=${shrank.length}`,
    detail: ok
      ? null
      : [
        data.hasBaseline === true ? null : 'no baseline — run --update-baseline',
        [...grew.map((g) => `${g.file}: ${g.before} -> ${g.now}`),
          ...added.map((a) => `new file ${a.file}: ${a.now}`)].join('\n') || null,
        self.status === 0 ? null : (self.stdout || '') + (self.stderr || ''),
      ].filter(Boolean).join('\n'),
  };
});

// ─────────────────────────────────────────────
// 17. keymap-parity — 物理键盘映射表两份实现的逐条一致性
//
// 键盘**没有** native 事件源：legacy 与 typed 吃同一个 ArkTS 事件、同一次 NAPI 调用，
// 却各自翻译一遍（ArkTS `glfwKeyFromOhos` / C++ `MapOhosKey`）。两份表分叉 = 同一次按键
// 在两条平面上变成不同的 GLFW 键，而两侧各自编译与测试都会照常全绿 —— 分歧落在语言的缝里。
// ⚠️ 刻意**不覆盖** scanCode（原理性不等价，已被 glfw_source_plane_aggregate_test 固化）
// 与鼠标按钮表（两侧输入域不同，不是同一张表的两份）。理由见 check 脚本头部。
add('keymap-parity', () => {
  const r = spawnSync('node', ['scripts/check-keymap-parity.mjs', '--json'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  let data;
  try {
    data = JSON.parse(r.stdout || '{}');
  } catch {
    return {
      ok: false,
      summary: 'check-keymap-parity.mjs produced no JSON',
      detail: (r.stdout || '') + (r.stderr || ''),
    };
  }
  const self = spawnSync('node', ['scripts/test-check-keymap-parity.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const ok = r.status === 0 && data.ok === true && self.status === 0;
  // 键数一起打出来是刻意的：只报 "0 divergence" 无法区分"两份表一致"与"一条都没解析到"。
  return {
    ok,
    summary:
      `${data.arkTsKeys ?? 0} ArkTS / ${data.cppKeys ?? 0} C++ keys; ` +
      `${data.valueMismatch?.length ?? 0} mismatched, ` +
      `${(data.onlyInArkTs?.length ?? 0) + (data.onlyInCpp?.length ?? 0)} one-sided`,
    detail: ok
      ? null
      : [
        data.fatal ?? null,
        (data.valueMismatch ?? []).map((d) => `ohos=${d.ohos} arkTs=${d.arkTs} cpp=${d.cpp}`).join('\n') || null,
        (data.onlyInArkTs ?? []).map((d) => `only ArkTS: ohos=${d.ohos} -> ${d.glfw}`).join('\n') || null,
        (data.onlyInCpp ?? []).map((d) => `only C++: ohos=${d.ohos} -> ${d.glfw}`).join('\n') || null,
        self.status === 0 ? null : (self.stdout || '') + (self.stderr || ''),
      ].filter(Boolean).join('\n'),
  };
});

// ─────────────────────────────────────────────
// 18. typed-sink-wiring — typed 事件的消费端不得静默缺席
//
// `GlfwInputSink` 是一张普通函数表，没赋值的字段就是 nullptr，而 adapter 对 nullptr sink
// 是**静默跳过**（那是对的：陌生能力不该拆掉不相关的持有态）。代价是"忘了接一根线"与
// "刻意不接这根线"在代码里长得完全一样。实证：`sink.capture` 至今没接，理由此前只存在于
// 一句注释里 —— 而注释不是契约。现在它是一条**声明过的**例外，而不是没声明的遗漏。
// ⚠️ 它**不覆盖** ring 失明（计划 §96.3，需要跨 TU 调用图可达性，本仓没有）。
// ⭐ 2026-08-24 起覆盖**两个**装配点（`typedInputSink()` 与 `SinkFor()`），判据是"每个
// 站点 × 每个字段 = 一个必须被回答的槽位"。扩容的直接原因：§102.1 那次真缺陷就在第二个
// 站点里，而当时门禁只看第一个 —— 门禁的覆盖边界要随被检查对象的数量一起长。
add('typed-sink-wiring', () => {
  const r = spawnSync('node', ['scripts/check-typed-sink-wiring.mjs', '--json'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  let data;
  try {
    data = JSON.parse(r.stdout || '{}');
  } catch {
    return {
      ok: false,
      summary: 'check-typed-sink-wiring.mjs produced no JSON',
      detail: (r.stdout || '') + (r.stderr || ''),
    };
  }
  const self = spawnSync('node', ['scripts/test-check-typed-sink-wiring.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const ok = r.status === 0 && data.ok === true && self.status === 0;
  // declared-unwired 一起打出来是刻意的：只报 "0 missing" 会让人以为每个 typed 事件
  // 都有消费者，而实际有一条被声明为刻意不接。
  return {
    ok,
    summary:
      `${data.wired ?? 0}/${data.slots ?? 0} slots wired across `
      + `${(data.sites ?? []).length} assembly point(s); `
      + `${data.declaredUnwired ?? 0} declared-unwired, ${(data.missing ?? []).length} missing`,
    detail: ok
      ? null
      : [
        data.fatal ?? null,
        (data.missing ?? []).map((f) => `unwired sink.${f}`).join('\n') || null,
        (data.staleAllowlist ?? []).map((s) => `stale ${s.field}: ${s.why}`).join('\n') || null,
        self.status === 0 ? null : (self.stdout || '') + (self.stderr || ''),
      ].filter(Boolean).join('\n'),
  };
});

// ─────────────────────────────────────────────
// 19. backend-keymap-parity — 新的"一步"后端映射必须等于旧的"两步"复合
//
// 迁移的核心命题：`新表[ohos] == 第二步[第一步[ohos]]`。旧的两步链（OHOS→GLFW→后端编码）
// 现在**是工作的**，所以它是迁移期唯一的"已知正确"参考 —— 抄错一个键，复合会揪出来。
// ⚠️ 等外部 .so 改完、两步链被删的那一刻，本项会失去参考侧，必须同时改成新表自己的
// 回归基线，不能让它静默退化成永绿。这条转换刻意写在 check 脚本头部。
add('backend-keymap-parity', () => {
  const r = spawnSync('node', ['scripts/check-backend-keymap-parity.mjs', '--json'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  let data;
  try {
    data = JSON.parse(r.stdout || '{}');
  } catch {
    return {
      ok: false,
      summary: 'check-backend-keymap-parity.mjs produced no JSON',
      detail: (r.stdout || '') + (r.stderr || ''),
    };
  }
  const self = spawnSync('node', ['scripts/test-check-backend-keymap-parity.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const planes = data.planes || [];
  const bad = planes.reduce((n, p) =>
    n + (p.missing?.length ?? 0) + (p.extra?.length ?? 0) + (p.mismatch?.length ?? 0), 0);
  const ok = r.status === 0 && data.ok === true && self.status === 0;
  // 逐平面键数一起打出来是刻意的：只报 "0 divergence" 无法区分"三份表一致"与"一条都没解析到"。
  return {
    ok,
    summary:
      `OHOS->GLFW ${data.ohosToGlfw ?? 0} keys; one-step `
      + `${planes.map((p) => `${p.name}=${p.actual ?? 0}`).join(' ') || 'none'}; ${bad} divergent`,
    detail: ok
      ? null
      : [
        data.fatal ?? null,
        planes.flatMap((p) => [
          ...(p.mismatch ?? []).map((d) => `${p.name} ohos=${d.ohos} expected=${d.expected} actual=${d.actual}`),
          ...(p.missing ?? []).map((d) => `${p.name} missing ohos=${d.ohos} -> ${d.expected}`),
          ...(p.extra ?? []).map((d) => `${p.name} extra ohos=${d.ohos} -> ${d.actual}`),
        ]).join('\n') || null,
        self.status === 0 ? null : (self.stdout || '') + (self.stderr || ''),
      ].filter(Boolean).join('\n'),
  };
});

// ─────────────────────────────────────────────
// 20. renderer-registry — 渲染后端 id 在 ArkTS 注册表与 native 镜像之间必须一致
//
// 施工记录 `docs/refactor/渲染后端治理施工记录.md` §S5 / §S6.2。
//
// ⚠️ **为什么这一项要和 renderer-naming 一起注册进 preflight**：门禁写完了但不在
// 日常回路里跑，等于没写 —— §S6 验收时才发现 `check-renderer-naming` 已经红了一阵
// （`check-renderer-registry.mjs` 的正则让引号配对失步，报出一处假阳性）。
// 一道只在"想起来的时候"手跑的门禁，其反馈延迟等于两次想起之间的间隔。
add('renderer-registry', () => {
  const r = spawnSync('node', ['scripts/check-renderer-registry.mjs', '--json'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  let data;
  try {
    data = JSON.parse(r.stdout || '{}');
  } catch {
    return {
      ok: false,
      summary: 'check-renderer-registry.mjs produced no JSON',
      detail: (r.stdout || '') + (r.stderr || ''),
    };
  }
  const self = spawnSync('node', ['scripts/test-check-renderer-registry.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const ok = r.status === 0 && data.ok === true && self.status === 0;
  // ⚠️ `arkBackends` 是 id 字符串数组，不是对象数组。第一版写成 `.map((b) => b.id)`
  // ⇒ summary 打成 `3 backends (, , )`。这类"计数对但内容空"的 summary 恰恰是
  // 本文件多处注释在防的那个坑（只报数字不报内容 ⇒ 分不清一致与没解析到），
  // 结果它自己犯了一次。留注释而不是静默改掉。
  const ids = data.arkBackends ?? [];
  return {
    ok,
    // ⚠️ 打出后端个数与 id 列表是刻意的：只报 "consistent" 无法区分
    // "两侧一致"与"一条都没解析到"（`1000544` 同源：端到端判据必须是单调计数）。
    summary: `${ids.length} backends (${ids.join(', ') || 'none'}), `
      + `native mirror ${data.nativeBackends?.length ?? 0}`,
    detail: ok
      ? null
      : [
        data.fatal ?? null,
        (data.problems ?? []).join('\n') || null,
        self.status === 0 ? null : (self.stdout || '') + (self.stderr || ''),
      ].filter(Boolean).join('\n'),
  };
});

// ─────────────────────────────────────────────
// 30. graphics-profile-inventory — 图形后端迁移的事实盘点
//
// 这道门禁只保证盘点器本身可信，并生成当前工作树的 machine-readable 入口；它刻意不把
// 静态引用、声明式编译参数或 workspace ELF 提升成 provider/游戏/真机通过。真实 HAP 与
// lifecycle 证据仍由 build-hap 和设备报告提供。
add('graphics-profile-inventory', () => {
  // 下载报告、请求、候选故障隔离及失败 wire 执行生产逻辑，不只检查页面字符串。
  for (const test of ['scripts/test-vulkan-download-status.mjs', 'scripts/test-game-vulkan-preference.mjs', 'scripts/test-graphics-capability-adapter.mjs',
    'scripts/test-graphics-launch-failure.mjs', 'scripts/test-graphics-observation-report.mjs', 'scripts/test-game-startup.mjs',
    'scripts/test-graphics-artifact-manifest.mjs', 'scripts/test-graphics-profiles.mjs', 'scripts/test-graphics-runtime-artifact.mjs', 'scripts/test-graphics-bootstrap.mjs',
    'scripts/test-sdl3-presentation-contract.mjs', 'scripts/check-sdl3-presentation-contract.mjs']) {
    const checked = spawnSync('node', [test], { cwd: ROOT, encoding: 'utf8' });
    if (checked.status !== 0) {
      return { ok: false, summary: test + ' 失败', detail: (checked.stdout || '') + (checked.stderr || '') };
    }
  }
  // 生产 Native 失败快照和 WSI 日志门控在宿主执行；编译器缺失不能当成已通过。
  const python = process.env.AMCL_PYTHON || (isWin ? 'python' : 'python3');
  for (const script of ['scripts/test-graphics-launch-failure.py', 'scripts/test-vulkan-wsi-diagnostics.py',
    'scripts/test-mobilegl-buffer-lifetime.py', 'scripts/test-mg-buffer-readback.py',
    'scripts/test-vulkan-capability-admission.py', 'scripts/test-vulkan-presentation-bridge.py', 'scripts/test-vulkan-orientation.py',
    'scripts/test-mobilegl-present-result.py',
    'scripts/test-sdl3-graphics-context.py', 'scripts/test-sdl3-pbuffer-limits.py', 'scripts/test-native-gl-probe.py', 'scripts/test-graphics-probe-gate.py',
    'scripts/test-egl-lifecycle.py', 'scripts/test-mobilegl-glfw.py', 'scripts/test-graphics-runtime-binding.py',
    'scripts/test-window-resource-epochs.py', 'scripts/test-graphics-observation-abi.py',
    'scripts/test-graphics-runtime-images.py', 'scripts/test-graphics-features.py', 'scripts/test-glfw-auxiliary-input.py',
    'scripts/test-desktop-review-generator.py']) {
    const checked = spawnSync(python, [script], { cwd: ROOT, encoding: 'utf8' });
    if (checked.status !== 0) return { ok: false, summary: script + ' 失败',
      detail: (checked.stdout || '') + (checked.stderr || '') + (checked.error?.message || '') };
  }
  const self = spawnSync('node', ['scripts/test-graphics-profile-inventory.mjs'], {
    cwd: ROOT, encoding: 'utf8',
  });
  if (self.status !== 0) {
    return { ok: false, summary: '图形 profile inventory 自测失败', detail: (self.stdout || '') + (self.stderr || '') };
  }
  const planSelf = spawnSync('node', ['scripts/test-graphics-plan.mjs'], {
    cwd: ROOT, encoding: 'utf8',
  });
  // The repository's Windows host runner uses MSVC discovered by vswhere, while
  // this lightweight Node check only uses CXX/g++. Exit 2 means that compiler
  // is unavailable; the actual CTest target remains mandatory in the host/HAP
  // build path and is reported as a deferred check here.
  if (planSelf.status !== 0 && planSelf.status !== 2) {
    return { ok: false, summary: 'native graphics plan host 自测失败', detail: (planSelf.stdout || '') + (planSelf.stderr || '') };
  }
  const r = spawnSync('node', ['scripts/graphics-profile-inventory.mjs',
    '--out', workspacePath('run', 'preflight', 'graphics-profile-inventory.json')], {
    cwd: ROOT, encoding: 'utf8',
  });
  return {
    ok: r.status === 0,
    summary: r.status === 0 ? '图形 profile 静态盘点完成；运行 provider/真机证据仍单独判定' : '图形 profile 静态盘点失败',
    detail: r.status === 0 ? (planSelf.status === 2 ? 'graphics plan C++ check deferred: use run-host-tests-msvc.ps1/CTest' : null) : (r.stdout || '') + (r.stderr || ''),
  };
});

// ─────────────────────────────────────────────
// 21. jdk-release-pin — JDK 发行版四处 SoT 一致性
//
// ⚠️ 这道门禁是 2026-08-29 补的：`deps.lock` 的注释一直声称「CI 校验本节字段跟三处一致」，
// 但实测**全仓没有任何脚本读过 JDK_VERSIONS 或 mc-ohos-resources** —— 那个校验从来不存在。
// 换 JDK 包时漏改一处的后果都离改动现场很远（sizeBytes 不符 → 引擎判所有源失败；
// sha256 不符 → 全量下完才报「可能镜像被劫持」；giteePartSizes 不符 → 下载前就被判死）。
// 自测（test-check-jdk-release-pin.mjs）对 9 种漏改各造一个已知坏样本并断言被抓住 ——
// 一个只会说 PASS 的门禁比没有门禁更糟。
add('jdk-release-pin', () => {
  const self = spawnSync('node', ['scripts/test-check-jdk-release-pin.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  if (self.status !== 0) {
    return { ok: false, summary: 'test-check-jdk-release-pin 自测失败（门禁本身不可信，先修它）' };
  }
  const r = spawnSync('node', ['scripts/check-jdk-release-pin.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  if (r.status !== 0) {
    const out = ((r.stderr || '') + (r.stdout || '')).trim().split(/\r?\n/).slice(0, 8).join(' | ');
    return { ok: false, summary: 'JDK 四处 SoT 不一致', detail: out };
  }
  const line = (r.stdout || '').split(/\r?\n/).filter((l) => l.includes('JDK ')).length;
  return { ok: true, summary: `${line} 个 JDK 四处一致（tag/asset/size/sha256 + 分卷算术），自测 14 项` };
});

// ─────────────────────────────────────────────
// 22. renderer-naming — 禁用缩写记号 + 禁止第二个后端决策通道
//
// 治理规范 `docs/guides/renderer-backend-governance.md` §3.2。
// 自测连 `scripts/lib/source-noise.mjs`（两道门禁共享的词法前置）一起跑 ——
// §S6.2 的缺陷正是出在那一层，而它当时只被间接测过。
add('renderer-naming', () => {
  const r = spawnSync('node', ['scripts/check-renderer-naming.mjs', '--json'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  let data;
  try {
    data = JSON.parse(r.stdout || '{}');
  } catch {
    return {
      ok: false,
      summary: 'check-renderer-naming.mjs produced no JSON',
      detail: (r.stdout || '') + (r.stderr || ''),
    };
  }
  const self = spawnSync('node', ['scripts/test-check-renderer-naming.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const libSelf = spawnSync('node', ['scripts/test-lib-source-noise.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  // ⭐ `check-sdl3-video-callbacks` 的自测挂在这一项下面，而不是单独一项。
  //
  // 理由：它测的**主要**是共享词法前置的行稳定性（施工记录 §S9），而那道门禁本体
  // 需要 `--repo <SDL 树>` 才能跑、本仓没有 ⇒ 单独立一项会永远是 SKIP 或红。
  // 这里跑的是它的**纯函数 + 最小假 SDL 树**，不依赖外部树，可以每次都跑。
  // ⚠️ 若将来 CI 上有了 SDL worktree，应把门禁本体单独立项，而不是继续搭在这里。
  const svcSelf = spawnSync('node', ['scripts/test-check-sdl3-video-callbacks.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const ok = r.status === 0 && data.ok === true && self.status === 0
    && libSelf.status === 0 && svcSelf.status === 0;
  return {
    ok,
    // 扫描文件数必须打出来：范围塌成 0 个文件时门禁同样"通过"。
    summary: `${data.scanned ?? 0} files, ${data.abbreviation?.length ?? 0} abbrev, `
      + `${data.envChannels?.length ?? 0} env channel(s)`,
    detail: ok
      ? null
      : [
        (data.abbreviation ?? []).map((a) => `abbrev ${a.rel}: '${a.token}' @${a.index}`).join('\n') || null,
        (data.envChannels ?? []).map((e) => `env ${e.rel}: ${e.name} @${e.index}`).join('\n') || null,
        self.status === 0 ? null : (self.stdout || '') + (self.stderr || ''),
        libSelf.status === 0 ? null : (libSelf.stdout || '') + (libSelf.stderr || ''),
        svcSelf.status === 0 ? null : (svcSelf.stdout || '') + (svcSelf.stderr || ''),
      ].filter(Boolean).join('\n'),
  };
});

// ─────────────────────────────────────────────
// 23. sdl3-multiwindow — OpenHarmony hybrid-window source contract
//
// The default check reads the checked-in patch series plus the AMCL host
// activation sources, so it is available in a clean checkout without an
// external SDL worktree. The SDL build runs the same gate with --repo after
// applying the patches. The self-test has one known-bad fixture per rule; a
// gate that only knows how to print PASS is not evidence.
add('sdl3-multiwindow', () => {
  const self = spawnSync('node', ['scripts/test-check-sdl3-multiwindow-contract.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  if (self.status !== 0) {
    return {
      ok: false,
      summary: 'multiwindow 门禁自测失败（门禁本身不可信）',
      detail: ((self.stdout || '') + (self.stderr || '')).trim(),
    };
  }

  const gate = spawnSync('node', ['scripts/check-sdl3-multiwindow-contract.mjs', '--json'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  let data;
  try {
    data = JSON.parse(gate.stdout || '{}');
  } catch {
    return {
      ok: false,
      summary: 'check-sdl3-multiwindow-contract.mjs produced no JSON',
      detail: ((gate.stdout || '') + (gate.stderr || '')).trim(),
    };
  }

  const ok = gate.status === 0 && data.ok === true;
  return {
    ok,
    // Count both files and rules: "0 files / 0 rules / PASS" must never look
    // equivalent to a real contract scan (AGENTS.md §二.3).
    summary: `${data.scannedFiles ?? 0} contract-source files, `
      + `${data.passed ?? 0}/${data.total ?? 0} rules, ${data.patches?.length ?? 0} patches`,
    detail: ok ? null : (data.results ?? [])
      .filter((r) => !r.ok)
      .map((r) => `${r.id}: ${r.detail}${r.evidence ? ` (${r.evidence})` : ''}`)
      .join('\n'),
  };
});

// ─────────────────────────────────────────────
// 24. gamecontrol-scope — HAR 单例的模块/进程适用边界
add('gamecontrol-scope', () => {
  const self = spawnSync('node', ['scripts/test-check-gamecontrol-runtime-scope.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  if (self.status !== 0) {
    return {
      ok: false,
      summary: 'gamecontrol scope 门禁自测失败（门禁本身不可信）',
      detail: ((self.stdout || '') + (self.stderr || '')).trim(),
    };
  }
  const gate = spawnSync('node', ['scripts/check-gamecontrol-runtime-scope.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const output = ((gate.stdout || '') + (gate.stderr || '')).trim();
  return {
    ok: gate.status === 0,
    summary: gate.status === 0
      ? 'entry owns gamecontrol; desktop process initialization is explicit'
      : 'gamecontrol module/process ownership drifted',
    detail: gate.status === 0 ? null : output,
  };
});

// ─────────────────────────────────────────────
// 25. input-build-profile — debug/release 与产品 target 的输入平面闭包
add('input-build-profile', () => {
  const self = spawnSync('node', ['scripts/test-check-input-build-profile.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  if (self.status !== 0) {
    return {
      ok: false,
      summary: 'input build-profile 门禁自测失败（门禁本身不可信）',
      detail: ((self.stdout || '') + (self.stderr || '')).trim(),
    };
  }
  const gate = spawnSync('node', ['scripts/check-input-build-profile.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const output = ((gate.stdout || '') + (gate.stderr || '')).trim();
  return {
    ok: gate.status === 0,
    summary: gate.status === 0
      ? 'debug/release typed+relative routes and desktop closures are explicit'
      : 'input build-profile route drifted',
    detail: gate.status === 0 ? null : output,
  };
});

// ─────────────────────────────────────────────
// 26. sdl3-text-session — additive typed text consumer contract
add('sdl3-text-session', () => {
  const patchsetSelf = spawnSync('node', ['scripts/test-sdl3-patchset-digest.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  if (patchsetSelf.status !== 0) {
    return {
      ok: false,
      summary: 'SDL3 patchset provenance 自测失败（门禁本身不可信）',
      detail: ((patchsetSelf.stdout || '') + (patchsetSelf.stderr || '')).trim(),
    };
  }
  const zipSelf = spawnSync('node', ['scripts/test-zip-entry-buffer.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  if (zipSelf.status !== 0) {
    return {
      ok: false,
      summary: 'HAP ZIP unique-entry parser 自测失败（门禁本身不可信）',
      detail: ((zipSelf.stdout || '') + (zipSelf.stderr || '')).trim(),
    };
  }
  const self = spawnSync('node', ['scripts/test-check-sdl3-text-session-contract.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  if (self.status !== 0) {
    return {
      ok: false,
      summary: 'SDL3 text-session 门禁自测失败（门禁本身不可信）',
      detail: ((self.stdout || '') + (self.stderr || '')).trim(),
    };
  }
  const gate = spawnSync('node', ['scripts/check-sdl3-text-session-contract.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const artifact = spawnSync('node', [
    'scripts/check-sdl3-artifact.mjs', '--provenance-only',
  ], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  if (artifact.status !== 0) {
    return {
      ok: false,
      summary: 'SDL3 patch/source/binary provenance 漂移',
      detail: ((artifact.stdout || '') + (artifact.stderr || '')).trim(),
    };
  }
  const output = ((gate.stdout || '') + (gate.stderr || '')).trim();
  return {
    ok: gate.status === 0,
    summary: gate.status === 0
      ? 'SDL3 typed text session patch and owned blob lifecycle are explicit'
      : 'SDL3 typed text-session contract drifted',
    detail: gate.status === 0 ? null : output,
  };
});

// ─────────────────────────────────────────────
// 27. gate-f-readiness — dormant-safe, activation fail-closed
add('gate-f-readiness', () => {
  const self = spawnSync('node', ['scripts/test-check-gate-f-readiness.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  if (self.status !== 0) {
    return {
      ok: false,
      summary: 'Gate F readiness 门禁自测失败（门禁本身不可信）',
      detail: ((self.stdout || '') + (self.stderr || '')).trim(),
    };
  }
  const gate = spawnSync('node', ['scripts/check-gate-f-readiness.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const output = ((gate.stdout || '') + (gate.stderr || '')).trim();
  return {
    ok: gate.status === 0,
    summary: gate.status === 0
      ? 'Gate F is safely dormant or every activation prerequisite is ready'
      : 'Gate F evidence/profile activation outran its atomic route prerequisites',
    detail: gate.status === 0 ? null : output,
  };
});

// ─────────────────────────────────────────────
// 28. device-automation — P0 宿主编排器的判定工具自测
//
// 跑的**不是**编排器本体（那需要真机），而是它用来下判决的那批纯函数的正反向自测。
// 为什么必须进 preflight：这批判据的失败形态全是**静默永绿** —— 正则少一个分支就
// 永远匹配不到、判决聚合写反就永远不报错，而真机跑一轮要 6 秒且没人会每次都看。
// 实测过两个具体形状：`ps -A` 的 CMD 列截断到 15 字符（按完整包名匹配永远匹配不到，
// 失败表现是"进程不存在"）、hilog 默认格式无年份时区（两种形状都要能解析）。
add('device-automation', () => {
  const self = spawnSync('node', ['scripts/test-device-automation.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const out = ((self.stdout || '') + (self.stderr || '')).trim();
  const passed = /(\d+)\/(\d+) checks passed/.exec(out);
  // 样本组在 CI 上会 SKIP（原始日志在 .gitignore 的 /.logs/ 下）⇒ 这里把它显式报出来，
  // 免得"少跑了一组"看起来和"全跑过了"一样。
  const sampleSkipped = out.includes('SKIP  真实样本组');
  return {
    ok: self.status === 0,
    summary: self.status === 0
      ? `${passed ? passed[1] : '?'} judge self-tests pass` +
        (sampleSkipped ? '（真实样本组 SKIP：raw 不入库）' : '（含真实样本正负对照）')
      : 'device-automation judge self-test failed（判定工具本身不可信）',
    detail: self.status === 0 ? null : out,
  };
});

// ─────────────────────────────────────────────
// 29. product-identity — 产品身份 banner 的源码契约（批次 D8）
//
// 守三件事，每一件不做都**没有任何信号**：banner 漂到 `setNativeLogSink` 之前就只进
// hilog 不落盘（施工记录 §S03.3 的窗口）、少一个字段则报告照常输出只是再也回答不了
// "我在驱动哪个产品"、采集侧改读 native 掩码则非 default 产品上记下一个假的能力位。
// ⚠️ 它是源码级的：断言不了出货包里编进去的是哪一份 ProductBuildProfile（五份），
// 那要 G2 产物级反查（`AGENTS.md` §二.4）。
add('product-identity', () => {
  const self = spawnSync('node', ['scripts/test-check-product-identity-banner.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  if (self.status !== 0) {
    return {
      ok: false,
      summary: '产品身份 banner 门禁自测失败（门禁本身不可信）',
      detail: ((self.stdout || '') + (self.stderr || '')).trim(),
    };
  }
  const gate = spawnSync('node', ['scripts/check-product-identity-banner.mjs'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const output = ((gate.stdout || '') + (gate.stderr || '')).trim();
  return {
    ok: gate.status === 0,
    summary: gate.status === 0
      ? 'identity banner covers every current product track and follows setNativeLogSink'
      : 'product identity banner drifted (fields / capability source / emit order)',
    detail: gate.status === 0 ? null : output,
  };
});

// ─────────────────────────────────────────────
// Runtime compatibility needs JDK 21 for the Minecraft 1.21.11 Mixin fixture.
add('runtime-compat', () => {
  const python = process.env.AMCL_PYTHON || (isWin ? 'python' : 'python3');
  for (const script of ['scripts/test-game-runtime-compat.py', 'scripts/check-game-runtime-compat.py', 'scripts/test-game-compat.py']) {
    const result = spawnSync(python, [script], { cwd: ROOT, encoding: 'utf8' });
    if (result.status !== 0) return { ok: false, summary: `${script} failed`, detail: (result.stdout || '') + (result.stderr || '') };
  }
  return { ok: true, summary: 'consumer API, startup/window wiring, native fingerprints and actual Mixin lifecycle verified' };
});

add('logging-evidence', () => {
  for (const args of [['scripts/check-log-domains.mjs'], ['scripts/test-check-log-domains.mjs'],
    ['scripts/check-critical-logging.mjs'], ['--test', 'scripts/test-log-ux.mjs'],
    ['scripts/generate-log-domain-tags.mjs', '--check'], ['--test', 'scripts/test-evidence-system.mjs'],
    ['scripts/test-session-retention.mjs'], ['scripts/test-logshare-protocol.mjs'],
    ['scripts/test-activity-log-reader.mjs'], ['scripts/test-session-evidence-types.mjs'],
    ['--test', 'scripts/test-session-completeness.mjs'], ['--test', 'scripts/test-log-experience.mjs'],
    ['scripts/test-ai-diagnostic.mjs']]) {
    const result = spawnSync('node', args, { cwd: ROOT, encoding: 'utf8' });
    if (result.status !== 0) return { ok: false, summary: 'logging evidence regression failed', detail: (result.stdout || '') + (result.stderr || '') };
  }
  const python = process.env.AMCL_PYTHON || (isWin ? 'python' : 'python3');
  for (const script of ['scripts/test-logging-writer.py', 'scripts/test-native-log-durability.py', 'scripts/test-session-log-io.py']) {
    const result = spawnSync(python, [script], { cwd: ROOT, encoding: 'utf8' });
    if (result.status !== 0) return { ok: false, summary: script + ' failed', detail: (result.stdout || '') + (result.stderr || '') };
  }
  return { ok: true, summary: 'production evidence/share, UX failures, critical logging and host/game writer regressions' };
});

// 首次 native 加载必须属于合法消费者；本组执行实际 JNI 和生产 SDL 初始化入口的
// 宿主测试，并保留负向用例。它不是设备图形验收，失败也不能降级成跳过。
add('runtime-ownership', () => {
  const python = process.env.AMCL_PYTHON || (isWin ? 'python' : 'python3');
  const commands = [
    [python, 'scripts/test-runtime-bootstrap-contract.py'],
    [python, 'scripts/test-jvm-bootstrap-invocation.py'],
    [python, 'scripts/test-processor-wait.py'],
    ['node', 'scripts/test-runtime-slot-classpath.mjs'],
    ['node', 'scripts/test-runtime-jvm-argument-policy.mjs'],
    [python, 'scripts/test-jna-runtime-contract.py'],
    ['node', 'scripts/test-check-jna-runtime.mjs'],
    ['node', 'scripts/check-jna-runtime.mjs'],
    ['node', 'scripts/test-jni-classloader-ownership.mjs'],
    ['node', 'scripts/test-sdl3-host-runtime.mjs'],
    ['node', 'scripts/test-check-sdl3-launch-contract.mjs'],
    ['node', 'scripts/check-sdl3-launch-contract.mjs'],
  ];
  for (const [command, script] of commands) {
    const run = spawnSync(command, [script], { cwd: ROOT, encoding: 'utf8' });
    if (run.status !== 0) return { ok: false, summary: script + ' failed',
      detail: (run.stdout || '') + (run.stderr || '') + (run.error?.message || '') };
  }
  return { ok: true, summary: 'frozen runtime, precise slots, actual JNI ownership and SDL consumer lifecycle verified' };
});

// 运行时基础第一批：生产区间/清单、所选 LWJGL 槽与部署、平板进程策略、ELF 输入。
// 每个脚本自身包含反例；编译器缺失或子命令异常必须失败，不能静默跳过。
// 宿主用例不含真实设备呈现或 JVM 执行，其证据边界由专项报告单独记录。
add('runtime-foundation', () => {
  const python = process.env.AMCL_PYTHON || (isWin ? 'python' : 'python3');
  const commands = [
    ['node', 'scripts/test-jdk-runtime-contract.mjs'],
    ['node', 'scripts/test-prelaunch-runtime-slot.mjs'],
    ['node', 'scripts/check-lwjgl-legacy-slots.mjs'],
    ['node', 'scripts/test-lwjgl-runtime-slots.mjs'],
    [python, 'scripts/test-runtime-slot-store.py'],
    ['node', 'scripts/test-graphics-recovery.mjs'],
    ['node', 'scripts/test-graphics-recovery-handoff.mjs'],
    ['node', 'scripts/test-graphics-history.mjs'],
    ['node', 'scripts/test-graphics-builder-history.mjs'],
    ['node', 'scripts/test-tablet-process-policy.mjs'],
    ['node', 'scripts/test-game-layout-journal-core.mjs'],
    ['node', 'scripts/test-game-layout-transport.mjs'],
    ['node', 'scripts/test-layout-store-transactions.mjs'],
    ['node', 'scripts/test-layout-editor-failures.mjs'],
    [python, 'scripts/test-elf-input-validation.py'],
  ];
  for (const [command, script] of commands) {
    const run = spawnSync(command, [script], { cwd: ROOT, encoding: 'utf8' });
    if (run.status !== 0) return { ok: false, summary: script + ' failed',
      detail: (run.stdout || '') + (run.stderr || '') + (run.error?.message || '') };
  }
  return { ok: true, summary: 'JDK constraints, selected LWJGL slots/deployment, tablet process policy and ELF input validation' };
});

// 退出专项分别验证生产记录核心、标准 JVM 的真实回调和 ArkTS 会话裁决。
// 每个 JVM 退出场景必须运行在新宿主子进程；不能因为工具链缺失静默略过。
add('runtime-exit', () => {
  const python = process.env.AMCL_PYTHON || (isWin ? 'python' : 'python3');
  const commands = [
    [python, 'scripts/test-game-process-exit.py'],
    [python, 'scripts/test-runtime-bootstrap-contract.py'],
    ['node', 'scripts/test-jvm-exit-invocation.mjs'],
    ['node', 'scripts/test-jvm-exit-recovery.mjs'],
    ['node', 'scripts/test-tablet-game-return.mjs'],
    ['node', 'scripts/test-game-page-exit.mjs'],
    ['node', 'scripts/test-runtime-process-capture.mjs'],
    [python, 'scripts/test-mc-exit-seams.py'],
  ];
  for (const [command, script] of commands) {
    const run = spawnSync(command, [script], { cwd: ROOT, encoding: 'utf8' });
    if (run.status !== 0) return { ok: false, summary: script + ' failed',
      detail: (run.stdout || '') + (run.stderr || '') + (run.error?.message || '') };
  }
  return { ok: true, summary: 'isolated exit identity/record, real host JNI exit/halt, and session recovery verified' };
});

// 最后运行物理布局门：前面的测试即使退出成功，也不能把自建输出重新留在主项目。
// 门禁范围仅明确禁止的顶层名称及 docker/output，不扫描依赖内部，不以 gitignore 代替物理检查。
add('workspace-layout', () => {
  for (const script of ['scripts/test-check-workspace-layout.mjs', 'scripts/check-workspace-layout.mjs']) {
    const run = spawnSync(process.execPath, [script], { cwd: ROOT, encoding: 'utf8' });
    if (run.status !== 0) return {
      ok: false,
      summary: script.endsWith('test-check-workspace-layout.mjs') ? 'workspace layout guard self-test failed' : 'Agent/temporary entries remain or returned to the project',
      detail: (run.stdout || '') + (run.stderr || '') + (run.error?.message || ''),
    };
  }
  return { ok: true, summary: 'physical project layout clean; ignored directories and junctions cannot bypass this guard' };
});

// run
console.log(`\n=== AMCL Preflight ===\n`);
const t0 = Date.now();
let failures = 0;
for (const c of checks) {
  if (!shouldRun(c.name)) {
    console.log(`${dim('SKIP')}  ${c.name.padEnd(14)}`);
    continue;
  }
  process.stdout.write(`${dim('....')}  ${c.name.padEnd(14)}`);
  let res;
  try {
    res = c.fn();
  } catch (e) {
    res = { ok: false, summary: `EXCEPTION: ${e.message}`, detail: e.stack };
  }
  const tag = res.ok ? green(' OK ') : red('FAIL');
  process.stdout.write(`\r${tag}  ${c.name.padEnd(14)}  ${res.summary}\n`);
  if (!res.ok) {
    failures++;
    if (res.detail) {
      console.log(res.detail.split('\n').map((l) => '       ' + l).join('\n'));
    }
  }
  results.push({ name: c.name, ...res });
}

const dt = ((Date.now() - t0) / 1000).toFixed(1);
console.log(`\n=== ${failures === 0 ? green('all green') : red(`${failures} FAILED`)}  (${dt}s) ===\n`);
process.exit(failures > 0 ? 1 : 0);
