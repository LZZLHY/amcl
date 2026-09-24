#!/usr/bin/env node
// scripts/check-obfuscation-rules.mjs
//
// ============================ 它挡的是什么 ============================
//
// `entry/obfuscation-rules.txt` 是 release 产物正确性的**单点控制面**（8 个 HAR 模块各自的
// 规则文件都只有一行悬空 `-keep-property-name`，等价空）。这里挡两件事：
//
//   ① **未知指令悄悄进来**。已有两道门禁只认自己关心的那一个 flag
//      （check-napi-obfuscation 认 `-keep-property-name` 段，check-wire-json-obfuscation
//      认 `-enable-property-obfuscation`），别的 `-enable-*` 加进来两边都不出声。
//      2026-08-22 的教训就是一个 flag 能让下载与登录两大功能域在 release 里全坏。
//   ② **module.json5 里被系统按字符串反射的入口名没被 keep**。release 开着
//      `-enable-toplevel-obfuscation` + `-enable-export-obfuscation`，这些名字被改掉
//      就是 release 启动即崩、debug 全绿。现状是对的（三个都已 keep），这道门禁保证
//      将来新增 ability 时不会忘 —— 忘了的代价是出货包起不来。
//
// ⚠️ 抽取来源必须含 `requestPermissions[*].usedScene.abilities[*]`：那是 ability 类名的
// **第二处出现**，与 `abilities[*].name` 必须逐字相等。只抽第一处的话，改名时漏改这里
// 不会被任何检查发现。
//
// ============================ 它不能证明什么 ============================
//
// ❌ 不读 `entry/build/**`。规则文件是输入、nameCache 是结果，产物那半由
//    check-wire-json-obfuscation.mjs 的 `--require-artifact` 负责。
// ❌ 不判断 keep 清单里的名字是否**still needed**（多 keep 无害、少 keep 才致命）。
// ❌ 只看 entry 一个模块的规则文件。若哪天某个 HAR 的 consumerFiles 真的开始注入
//    `-enable-*`，这里看不见 —— 那时应当扩面而不是放宽判据。

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
const RULES_REL = 'entry/obfuscation-rules.txt';
const MODULE_REL = 'entry/src/main/module.json5';

// 白名单取"当前刻意启用/使用的指令"。新增任何一条都必须走这里，顺便迫使人写下理由。
const KNOWN_DIRECTIVES = new Set([
  '-enable-toplevel-obfuscation',
  '-enable-filename-obfuscation',
  '-enable-export-obfuscation',
  '-keep-property-name',
  '-keep-global-name',
]);

// 刻意**不在**白名单里、且必须显式拒绝的指令（给出比"未知指令"更明确的报错）。
const REJECTED_DIRECTIVES = new Map([
  ['-enable-property-obfuscation',
    '会改写 ArkTS 属性名而 JSON/NAPI 键名不跟着改；2026-08-22 实测让下载页与正版登录在 release 全坏'],
  ['-enable-string-property-obfuscation',
    '连字符串字面量键一起混淆，等于把 -enable-property-obfuscation 的坑扩大到目前侥幸能用的那一半'],
  ['-remove-log',
    '删掉 release 日志 = 出货包故障不可诊断；本项目两次事故都是靠 release 真机日志定位的'],
]);

/** 解析规则文件：指令行 + 各 keep 段的内容。 */
export function parseRules(text) {
  const directives = [];
  const sections = new Map();
  let current = null;
  text.split(/\r?\n/).forEach((raw, i) => {
    const line = raw.trim();
    if (line === '' || line.startsWith('#')) return;
    if (line.startsWith('-')) {
      directives.push({ name: line, line: i + 1 });
      current = line.startsWith('-keep-') ? line : null;
      if (current && !sections.has(current)) sections.set(current, new Set());
      return;
    }
    if (current) sections.get(current).add(line);
  });
  return { directives, sections };
}

/**
 * 从 module.json5 抽出被系统按字符串反射的入口名。
 *
 * json5 有注释与尾逗号，标准 JSON.parse 解析不了；这里按键名做词法抽取即可 ——
 * 判据只需要"名字集合"，不需要完整 AST。刻意不引第三方 json5 依赖。
 */
export function collectReflectedNames(text) {
  const names = new Set();
  // 先剥注释，避免注释里的历史名（如 "process": ":game" 那段）被当成现行配置。
  const stripped = text.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/(^|[^:])\/\/[^\n]*/g, '$1');
  const main = stripped.match(/"mainElement"\s*:\s*"([^"]+)"/);
  if (main) names.add(main[1]);
  // abilities / extensionAbilities 的 name：与 srcEntry 成对出现，用 srcEntry 锚定，
  // 避免把 metadata/permission 的 "name" 也收进来。
  const withEntry = /"name"\s*:\s*"([^"]+)"\s*,\s*"srcEntry"/g;
  for (let m; (m = withEntry.exec(stripped));) names.add(m[1]);
  // usedScene.abilities：ability 类名的第二处出现，必须与上面逐字相等。
  const usedScene = /"usedScene"\s*:\s*\{[^}]*?"abilities"\s*:\s*\[([^\]]*)\]/g;
  for (let m; (m = usedScene.exec(stripped));) {
    for (const n of m[1].match(/"([^"]+)"/g) || []) names.add(n.slice(1, -1));
  }
  return names;
}

export function evaluate({ directives, sections, reflectedNames }) {
  const unknown = [];
  const rejected = [];
  for (const d of directives) {
    if (REJECTED_DIRECTIVES.has(d.name)) {
      rejected.push({ ...d, why: REJECTED_DIRECTIVES.get(d.name) });
    } else if (!KNOWN_DIRECTIVES.has(d.name)) {
      unknown.push(d);
    }
  }
  const kept = sections.get('-keep-global-name') ?? new Set();
  const unkeptNames = [...reflectedNames].filter((n) => !kept.has(n)).sort();
  return {
    ok: unknown.length === 0 && rejected.length === 0 && unkeptNames.length === 0,
    unknown,
    rejected,
    unkeptNames,
  };
}

function main() {
  const jsonOutput = process.argv.includes('--json');
  const { directives, sections } = parseRules(fs.readFileSync(path.join(ROOT, RULES_REL), 'utf8'));
  const reflectedNames = collectReflectedNames(fs.readFileSync(path.join(ROOT, MODULE_REL), 'utf8'));
  const verdict = evaluate({ directives, sections, reflectedNames });

  const result = {
    ok: verdict.ok,
    directiveCount: directives.length,
    reflectedNames: [...reflectedNames].sort(),
    keptGlobalNameCount: (sections.get('-keep-global-name') ?? new Set()).size,
    unknownDirectives: verdict.unknown.map((d) => `${RULES_REL}:${d.line} ${d.name}`),
    rejectedDirectives: verdict.rejected.map((d) => `${RULES_REL}:${d.line} ${d.name} — ${d.why}`),
    unkeptReflectedNames: verdict.unkeptNames,
  };

  if (jsonOutput) {
    process.stdout.write(`${JSON.stringify(result)}\n`);
    process.exit(verdict.ok ? 0 : 1);
  }
  if (verdict.ok) {
    console.log(
      `obfuscation rules OK: ${directives.length} 条指令全部已知; ` +
      `${reflectedNames.size} 个反射入口名全部 keep`);
    console.log(`  reflected: ${result.reflectedNames.join(', ')}`);
  } else {
    for (const d of result.rejectedDirectives) console.error(`obfuscation rules FAIL: 明确拒绝的指令 ${d}`);
    for (const d of result.unknownDirectives) {
      console.error(`obfuscation rules FAIL: 未知指令 ${d}`);
      console.error('  新增指令必须先加进 KNOWN_DIRECTIVES 并写下理由 —— 一个 flag 就能让 release 静默失效。');
    }
    if (verdict.unkeptNames.length) {
      console.error(`obfuscation rules FAIL: ${verdict.unkeptNames.length} 个反射入口名没进 -keep-global-name`);
      console.error(`  ${verdict.unkeptNames.join(', ')}`);
      console.error('  这些名字系统按字符串反射；被 toplevel/export 混淆改掉 = release 启动即崩、debug 全绿。');
    }
  }
  process.exit(verdict.ok ? 0 : 1);
}

if (import.meta.url === url.pathToFileURL(process.argv[1] ?? '').href) {
  main();
}
