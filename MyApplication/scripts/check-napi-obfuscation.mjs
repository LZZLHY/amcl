#!/usr/bin/env node
// Release 开启 property obfuscation 后，ArkTS 侧的 testNapi.foo 与传入/返回对象字段
// 都必须和 C++ 中的固定字符串保持同名。此检查把 native 跨语言 ABI 与 keep 列表做差集，
// 防止只在 Release 真机出现 `undefined is not callable` 或协议字段静默丢失。

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
const CPP_ROOT = path.join(ROOT, 'entry', 'src', 'main', 'cpp');
const RULES = path.join(ROOT, 'entry', 'obfuscation-rules.txt');
const JSON_OUTPUT = process.argv.includes('--json');

function walkCpp(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walkCpp(full, out);
    } else if (entry.isFile() && /\.(?:c|cc|cpp|h|hpp)$/.test(entry.name)) {
      out.push(full);
    }
  }
  return out;
}

const required = new Map();
function requireName(name, file, line, kind) {
  if (!name) return;
  const origin = `${path.relative(ROOT, file).replace(/\\/g, '/')}:${line} (${kind})`;
  if (!required.has(name)) required.set(name, []);
  required.get(name).push(origin);
}

// 除导出函数外，也审计 native 读取/写回的对象字段。后者同样是固定字符串 ABI：
// 例如 schemaVersion 被混淆后，即使 setControlSchema 本身可调用，native 仍会拒绝整张表。
const objectKeyCall = /\b(?:napi_(?:get|set|has)_named_property|Named(?:Value|Int|Double|Bool)|hasNamedProp|readStringProp|readNumberProp|readStringArrayProp|setStringProp|setInt64Prop|setInt32Prop|setDoubleProp|setBoolProp|setNum)\s*\([^"\r\n]*"([^"]+)"/g;
const exportCall = /\b(?:NAPI_FUNC|DL_NAPI_FUNC)\s*\(\s*"([^"]+)"/g;
// ⚠️ 第二种导出写法：**裸 `napi_property_descriptor` 初始化器**，不经上面那两个宏。
//   { "setOhosFrameRateForeground", nullptr, SetOhosFrameRateForeground, ... }
// 2026-08-22 之前本检查只认宏，于是 `kOhosRuntimeDescriptors` 里的三个名字
// **从来没进过 required 集合** —— `missing=0` 对它们是空真，而它们实际未被 keep，
// release 下 `testNapi.setOhosFrameRateForeground` 被重命名成 undefined、调用抛异常并被
// 调用点的 `catch { /* 老 native 兼容 */ }` 静默吞掉。整整若干个版本里那三个接口都没工作过。
// 完整因果与真机证据见 docs/refactor/实体键鼠输入架构重构计划.md §80。
//
// 这正是"一个不可能失败的门禁比没有门禁更糟"的形状：检查器读到一堆它不认识的东西，
// 然后报告一切正常。判据必须按**效果**（这个名字会不会成为跨语言 ABI）枚举，
// 而不是按**写法**（用了哪个宏）。
// 匹配**完整**的 napi_property_descriptor 形状并以 `napi_` 属性位收尾：
//   {utf8name, name, method, getter, setter, value, attributes, data}
// 收尾那个 `napi_` 是真正的判别信号（只有 NAPI 描述符才有 napi_default/napi_enumerable…），
// 所以不会误吞形状相近的数据表 —— 例如 `mg_config_migration.cpp` 的
// `{"multidrawOrderArrays", nullptr, kArraysBackends.data(), …}`（第一版正则误报过它）。
// 刻意跨行匹配（描述符在本仓常常折行），因此在**整个文件文本**上跑，行号由偏移换算。
const descriptorEntry =
  /\{\s*"([A-Za-z_][A-Za-z0-9_]*)"\s*,\s*nullptr\s*,\s*[A-Za-z_][A-Za-z0-9_]*\s*,\s*nullptr\s*,\s*nullptr\s*,\s*nullptr\s*,\s*napi_/g;

for (const file of walkCpp(CPP_ROOT)) {
  const text = fs.readFileSync(file, 'utf8');
  // 跨行的描述符表：在整份文本上匹配，行号由匹配偏移换算。
  descriptorEntry.lastIndex = 0;
  for (let match; (match = descriptorEntry.exec(text));) {
    const line = text.slice(0, match.index).split(/\r?\n/).length;
    requireName(match[1], file, line, 'descriptor-export');
  }
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    exportCall.lastIndex = 0;
    for (let match; (match = exportCall.exec(line));) {
      requireName(match[1], file, i + 1, 'export');
    }
    objectKeyCall.lastIndex = 0;
    for (let match; (match = objectKeyCall.exec(line));) {
      requireName(match[1], file, i + 1, 'object-key');
    }

  }
}

const kept = new Set();
let inPropertyNames = false;
for (const raw of fs.readFileSync(RULES, 'utf8').split(/\r?\n/)) {
  const line = raw.trim();
  if (line === '-keep-property-name') {
    inPropertyNames = true;
    continue;
  }
  if (line.startsWith('-keep-') && line !== '-keep-property-name') {
    inPropertyNames = false;
    continue;
  }
  if (inPropertyNames && line && !line.startsWith('#') && !line.startsWith('-')) {
    kept.add(line);
  }
}

const missing = [...required.keys()].filter((name) => !kept.has(name)).sort();
const stale = [...kept].filter((name) => !required.has(name)).sort();
const result = {
  ok: missing.length === 0,
  requiredCount: required.size,
  keptCount: kept.size,
  missing,
  stale,
  origins: Object.fromEntries(missing.map((name) => [name, required.get(name)])),
};

if (JSON_OUTPUT) {
  process.stdout.write(`${JSON.stringify(result)}\n`);
} else if (result.ok) {
  console.log(`NAPI obfuscation ABI OK: ${required.size} required names are kept`);
  if (stale.length) console.log(`Defensive/stale keep names (${stale.length}): ${stale.join(', ')}`);
} else {
  console.error(`NAPI obfuscation ABI FAIL: ${missing.length} names are not kept`);
  for (const name of missing) {
    console.error(`  ${name}`);
    for (const origin of required.get(name)) console.error(`    ${origin}`);
  }
}

process.exit(result.ok ? 0 : 1);
