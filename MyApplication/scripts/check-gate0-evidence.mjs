#!/usr/bin/env node
// Gate 0 证据清单 + 证据门禁的源码契约检查。
//
// 为什么需要它（docs/refactor/实体键鼠输入架构重构计划.md Gate 0 / §1.1）：
//   AMCL_GLFW_*_VERIFIED 断言的是真机事实。Gate0Evidence.cmake 已经把"打开这些选项"
//   绑定到 gate0-evidence.lock 的书面批准上，但那只在 configure 期生效。本脚本在
//   source gate 阶段做三件 CMake 做不到的事：
//     1. 无论选项开关，都保证清单本身结构合法 —— 否则真要批准时才发现清单是坏的。
//     2. 保证清单键集合与 CMake 受管能力列表完全一致 —— 新增证据位若只加在一处，
//        它就会绕过门禁；这里让遗漏变成显式失败。
//     3. 保证产品构建配置没有在清单未批准时打开这些选项（entry/build-profile.json5
//        的 externalNativeOptions.arguments 是最容易被顺手改的地方）。
//
// 边界：本脚本不能证明真机结论，它只保证"未经批准不可能打开"这条不变量在源码层成立。

import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const MANAGED_CAPABILITIES = [
  'AMCL_GLFW_RAW_RELATIVE_VERIFIED',
  'AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED',
  'AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED',
];

const REQUIRED_STRING_FIELDS = [
  'evidenceId', 'evidenceDocument', 'evidenceSha256', 'sdkVersion',
  'approvedBy', 'approvedOn', 'independentReviewer',
];

const PLACEHOLDER_TOKENS = [
  'TODO', 'PLACEHOLDER', 'XXX', 'FIXME', 'SAMPLE', 'EXAMPLE', 'CHANGEME',
];

function readIfPresent(root, relative) {
  const target = join(root, relative);
  if (!existsSync(target)) return null;
  return readFileSync(target, 'utf8');
}

const NATIVE_SOURCE_EXTENSIONS = ['.c', '.cc', '.cpp', '.h', '.hpp', '.cmake'];

/**
 * 递归收集 entry/src/main/cpp 下的原生源码/CMake 文件（相对路径）。
 *
 * 刻意不走 glob 依赖：本仓的 source gates 都只用 node 标准库，加一个第三方依赖会让
 * 门禁本身多一个供应链面。
 *
 * 覆盖边界（有限集，扩展时需同步）：
 *   - 跳过的目录：build / .cxx（构建产物）、third_party / openal-soft（第三方源码，
 *     不会消费本项目的证据宏）。
 *   - 只认扩展名 .c/.cc/.cpp/.h/.hpp/.cmake 与文件名 CMakeLists.txt。若将来引入
 *     .cxx/.hh/.ipp/.inc 之类的源文件，或把证据宏的消费者放进被跳过的目录，本扫描
 *     会静默漏掉——那时必须同步扩展这两个集合。
 *   - 不跟随符号链接：readdirSync(withFileTypes) 对链接的 isDirectory()/isFile()
 *     均为 false，因此不会成环，代价是链接指向的源文件被跳过。
 *   - 不吞异常：权限等错误直接抛栈（fail loud），不会被误判成"扫过且干净"。
 */
function collectNativeSourceFiles(root) {
  const base = join(root, 'entry/src/main/cpp');
  if (!existsSync(base)) return [];
  const skipped = new Set(['build', '.cxx', 'third_party', 'openal-soft']);
  const files = [];
  const walk = (absolute, relative) => {
    for (const item of readdirSync(absolute, { withFileTypes: true })) {
      if (item.isDirectory()) {
        if (skipped.has(item.name)) continue;
        walk(join(absolute, item.name), `${relative}/${item.name}`);
        continue;
      }
      if (!item.isFile()) continue;
      const dot = item.name.lastIndexOf('.');
      const extension = dot < 0 ? '' : item.name.slice(dot).toLowerCase();
      if (!NATIVE_SOURCE_EXTENSIONS.includes(extension) &&
          item.name !== 'CMakeLists.txt') {
        continue;
      }
      files.push(`entry/src/main/cpp${relative}/${item.name}`);
    }
  };
  walk(base, '');
  return files;
}

/**
 * 校验一条 approved=true 的条目。未批准的条目只需保证"选项确实没被打开"，因此
 * 这里不强制它填完整字段：允许清单里长期留着未批准占位条目并记录 blockedBy 原因。
 */
function validateApprovedEntry(root, capability, entry, issues) {
  for (const field of REQUIRED_STRING_FIELDS) {
    const value = entry[field];
    if (typeof value !== 'string' || value.trim() === '') {
      issues.push(`${capability}: approved entry field '${field}' must be a non-empty string`);
    }
  }
  if (!Array.isArray(entry.deviceMatrix) || entry.deviceMatrix.length === 0) {
    issues.push(`${capability}: approved entry deviceMatrix must be a non-empty array`);
  }

  const evidenceId = typeof entry.evidenceId === 'string' ? entry.evidenceId : '';
  if (evidenceId && (!/^[A-Za-z0-9._-]+$/.test(evidenceId) || evidenceId.length < 8)) {
    issues.push(`${capability}: evidenceId '${evidenceId}' must be >= 8 chars of [A-Za-z0-9._-]`);
  }
  const upperId = evidenceId.toUpperCase();
  for (const token of PLACEHOLDER_TOKENS) {
    if (upperId.includes(token)) {
      issues.push(`${capability}: evidenceId '${evidenceId}' looks like a placeholder (${token})`);
    }
  }

  if (typeof entry.approvedOn === 'string' &&
      !/^\d{4}-\d{2}-\d{2}$/.test(entry.approvedOn)) {
    issues.push(`${capability}: approvedOn '${entry.approvedOn}' must be YYYY-MM-DD`);
  }

  // 文档必须存在且哈希与批准时一致：否则"先批准空文档、之后往里写结论"能绕过门禁。
  const documentPath = typeof entry.evidenceDocument === 'string' ? entry.evidenceDocument : '';
  if (documentPath) {
    const absolute = join(root, documentPath);
    if (!existsSync(absolute)) {
      issues.push(`${capability}: evidenceDocument does not exist: ${documentPath}`);
    } else {
      const actual = createHash('sha256').update(readFileSync(absolute)).digest('hex');
      const recorded = String(entry.evidenceSha256 ?? '').toLowerCase();
      if (actual !== recorded) {
        issues.push(
          `${capability}: evidenceDocument sha256 mismatch (recorded ${recorded}, actual ${actual})`);
      }
    }
  }
}

export function validateGate0Evidence(root) {
  const issues = [];

  const manifestText = readIfPresent(root, 'gate0-evidence.lock');
  if (manifestText === null) {
    issues.push('gate0-evidence.lock is missing');
    return issues;
  }
  let manifest;
  try {
    manifest = JSON.parse(manifestText);
  } catch (error) {
    issues.push(`gate0-evidence.lock is not valid JSON: ${error.message}`);
    return issues;
  }
  if (manifest.schemaVersion !== 1) {
    issues.push(`gate0-evidence.lock schemaVersion must be 1; got ${manifest.schemaVersion}`);
  }
  const capabilities = manifest.capabilities;
  if (capabilities === null || typeof capabilities !== 'object' || Array.isArray(capabilities)) {
    issues.push('gate0-evidence.lock capabilities must be an object');
    return issues;
  }

  // 清单与 CMake 受管列表必须完全一致（双向）。少一个 = 新选项绕过门禁；
  // 多一个 = 清单里有 CMake 根本不认识的能力，批准了也不会生效。
  const gateText = readIfPresent(root, 'entry/src/main/cpp/input/Gate0Evidence.cmake');
  if (gateText === null) {
    issues.push('entry/src/main/cpp/input/Gate0Evidence.cmake is missing');
  } else {
    const managedBlock = /AMCL_GATE0_MANAGED_CAPABILITIES\s*([\s\S]*?)\)/.exec(gateText);
    const managed = managedBlock
      ? (managedBlock[1].match(/AMCL_[A-Z0-9_]+/g) ?? [])
      : [];
    for (const capability of MANAGED_CAPABILITIES) {
      if (!managed.includes(capability)) {
        issues.push(`Gate0Evidence.cmake does not manage ${capability}`);
      }
    }
    for (const capability of managed) {
      if (!MANAGED_CAPABILITIES.includes(capability)) {
        issues.push(`Gate0Evidence.cmake manages unknown capability ${capability}`);
      }
    }
    // 门禁的关键行为必须存在，防止有人把校验体删空只留文件名。
    for (const [pattern, label] of [
      [/FATAL_ERROR/, 'fail-closed FATAL_ERROR'],
      [/CMAKE_VERSION VERSION_LESS "3\.19"/, 'refuse-when-unverifiable CMake floor'],
      [/file\(SHA256/, 'evidence document hash check'],
      [/deviceMatrix/, 'device matrix requirement'],
      [/requires/, 'dependent-capability requirement'],
    ]) {
      if (!pattern.test(gateText)) {
        issues.push(`Gate0Evidence.cmake is missing ${label}`);
      }
    }
  }

  // 任何在源码里实际被消费/定义的 AMCL_GLFW_*_VERIFIED 都必须在纳管列表里。
  //
  // 只比对"清单 vs CMake 列表"是不够的：新增第 4 个证据位时，只要在任意 TU 里写
  // `#if AMCL_GLFW_FOO_VERIFIED` 并从 cppFlags 注宏，两份列表都察觉不到，
  // glfw_input_mode.h 的 static_assert 也只枚举现有三个宏，门禁对它形同不存在。
  //
  // 覆盖范围（边界）：递归扫 entry/src/main/cpp 下的 C/C++/CMake 源码，含
  // tests/host。不扫构建产物目录与非源码文件。新增证据位时**唯一**需要同步的地方是
  // MANAGED_CAPABILITIES + gate0-evidence.lock + Gate0Evidence.cmake 的纳管列表；
  // 漏掉任何一处，这里都会报出来。
  for (const relative of collectNativeSourceFiles(root)) {
    const text = readIfPresent(root, relative);
    if (text === null) continue;
    const found = new Set(text.match(/AMCL_GLFW_[A-Z0-9_]*_VERIFIED/g) ?? []);
    for (const name of found) {
      if (!MANAGED_CAPABILITIES.includes(name)) {
        issues.push(
          `${relative} references ${name}, which is not a managed Gate 0 capability`);
      }
    }
  }

  const cmakeText = readIfPresent(root, 'entry/src/main/cpp/CMakeLists.txt');
  if (cmakeText === null) {
    issues.push('entry/src/main/cpp/CMakeLists.txt is missing');
  } else {
    if (!/include\([^)]*input\/Gate0Evidence\.cmake\)/.test(cmakeText)) {
      issues.push('CMakeLists.txt does not include input/Gate0Evidence.cmake');
    }
    if (!/AMCL_GATE0_EVIDENCE_IDS="\$\{AMCL_GATE0_EVIDENCE_IDS_STRING\}"/.test(cmakeText)) {
      issues.push('CMakeLists.txt does not embed AMCL_GATE0_EVIDENCE_IDS into libglfw');
    }
    // 每个受管能力都必须声明为 option 且默认 OFF。
    for (const capability of MANAGED_CAPABILITIES) {
      const optionPattern = new RegExp(`option\\(${capability}[\\s\\S]{0,400}?\\)`);
      const declaration = optionPattern.exec(cmakeText);
      if (!declaration) {
        issues.push(`CMakeLists.txt does not declare option(${capability} ...)`);
      } else if (!/\bOFF\s*\)$/.test(declaration[0])) {
        issues.push(`option(${capability}) must default to OFF`);
      }
    }
  }

  for (const capability of MANAGED_CAPABILITIES) {
    const entry = capabilities[capability];
    if (entry === undefined) {
      issues.push(`gate0-evidence.lock has no entry for ${capability}`);
      continue;
    }
    if (typeof entry.approved !== 'boolean') {
      issues.push(`${capability}: 'approved' must be a boolean`);
      continue;
    }
    if (!Array.isArray(entry.requires)) {
      issues.push(`${capability}: 'requires' must be an array`);
    } else {
      for (const required of entry.requires) {
        if (!MANAGED_CAPABILITIES.includes(required)) {
          issues.push(`${capability}: requires unknown capability ${required}`);
        }
      }
    }
    if (entry.approved) {
      validateApprovedEntry(root, capability, entry, issues);
      // 依赖链必须一并批准，否则批准了也发布不出能力位。
      for (const required of Array.isArray(entry.requires) ? entry.requires : []) {
        const dependency = capabilities[required];
        if (!dependency || dependency.approved !== true) {
          issues.push(`${capability}: approved but dependency ${required} is not approved`);
        }
      }
    } else {
      // 未批准条目必须写清阻断原因，避免"忘了为什么没开"。
      if (typeof entry.blockedBy !== 'string' || entry.blockedBy.trim() === '') {
        issues.push(`${capability}: unapproved entry must record a non-empty 'blockedBy' reason`);
      }
    }
  }

  // 产品构建配置不得在未批准时打开这些选项，也不得绕过 option 直接注宏。
  //
  // 为什么真值判定要取"非明确假值"而不是枚举 ON/1/TRUE/YES：Gate0Evidence.cmake 的
  // 判定就是这个语义（见其中 amcl_gate0_normalize_enabled）。若这里只认 4 种写法，
  // `-D<cap>=2` 之类的取值会在 source gate 静默通过，而 CMake 侧却当作已启用 ——
  // 两处口径不一致本身就是一条缺陷，且更宽的那一侧才是安全侧。
  //
  // cppFlags / arguments 两个字段都要看：前者直接进编译器命令行、能覆盖
  // target_compile_definitions 给出的 =0，后者进 CMake 配置。这里直接扫整份 profile
  // 文本，因此两个字段都在覆盖范围内。
  //
  // 写法集合也要放宽，不能只认 `-DNAME=VALUE`：CMake 接受 `-DNAME:BOOL=ON` 形式，
  // 而 JSON5 里的值可能带引号或 JSON 转义（`-DNAME="1"` / `-DNAME=\"1\"`）。只匹配
  // 裸写法会让这些形态静默通过 —— 与刚修掉的"只认 4 种取值"是同一族缺陷，只换了维度。
  // 因此：可选类型后缀 + 捕获到空白/逗号为止，再剥掉引号与转义反斜杠后判定。
  const CMAKE_FALSE_VALUES = new Set([
    '0', 'n', 'no', 'off', 'false', 'ignore', 'notfound', '',
  ]);
  const looksEnabled = (value) => {
    const trimmed = value.trim().replace(/[\\"']/g, '').toLowerCase();
    if (CMAKE_FALSE_VALUES.has(trimmed)) return false;
    return !trimmed.endsWith('-notfound');
  };

  const profileText = readIfPresent(root, 'entry/build-profile.json5');
  if (profileText === null) {
    issues.push('entry/build-profile.json5 is missing');
  } else {
    for (const capability of MANAGED_CAPABILITIES) {
      const pattern = new RegExp(
        `-D\\s*${capability}(?::[A-Za-z]+)?\\s*=\\s*([^\\s,]*)`, 'gi');
      for (const match of profileText.matchAll(pattern)) {
        if (!looksEnabled(match[1])) continue;
        if (capabilities[capability]?.approved === true) continue;
        issues.push(
          `entry/build-profile.json5 enables ${capability}=${match[1]} but the ` +
          'manifest has not approved it');
      }
    }
    // evidence id 只能由 Gate0Evidence.cmake 注入。产品配置里出现它，说明有人试图
    // 手写一个 id 去满足 glfw_input_mode.h 的 static_assert，而不是走清单批准。
    if (/-D\s*AMCL_GATE0_EVIDENCE_IDS(?::[A-Za-z]+)?\s*=/.test(profileText)) {
      issues.push(
        'entry/build-profile.json5 defines AMCL_GATE0_EVIDENCE_IDS directly; only ' +
        'Gate0Evidence.cmake may inject it after validating gate0-evidence.lock');
    }
    // ⭐ typed 验证包的一次性覆盖通道（2026-08-24，计划 §89）。
    //
    // scripts/build-typed-validation-hap.ps1 需要在真机上跑 typed 平面，而 bit13 受本门禁
    // 管、清单里 approved=false ⇒ 它临时往这里写一条 -DCMAKE_PROJECT_INCLUDE=...，
    // 由 scripts/typed-validation-inject.cmake 把 bit10/bit13 的宏覆盖成 1。
    //
    // 那是**刻意留的逃生阀**，但它有一个致命失败模式：脚本崩在中途、或有人手工试完忘了
    // 撤，这一行就留在出货配置里，于是**下一次 release 构建静默带上一个没有任何真机证据的
    // 能力位**，而所有既有判据都查不到它（那条 -D 里既没有 *_VERIFIED 也没有 evidence id
    // 字样，上面两条规则对它恒不命中 —— 正是规范 §八 第五条推论 b 那个"判据按写法枚举"的形状）。
    //
    // ⇒ 这里主动猎它：默认一律报错，只有**同时**设了 AMCL_TYPED_VALIDATION=1 的那一次
    // 构建才放行。两个条件必须同时成立，缺省状态（都没有）是出货安全的；只剩文件残留时
    // 硬失败。这比放宽门禁相反 —— 在此之前，往 arguments 里塞任何 -include / 任意
    // CMAKE_PROJECT_INCLUDE 都是静默通过的。
    if (/typed-validation/i.test(profileText) ||
        /-D\s*CMAKE_PROJECT_INCLUDE(?::[A-Za-z]+)?\s*=/.test(profileText)) {
      if (process.env.AMCL_TYPED_VALIDATION !== '1') {
        issues.push(
          'entry/build-profile.json5 still carries the typed-validation override ' +
          '(CMAKE_PROJECT_INCLUDE / typed-validation-*). That override asserts Gate 0 ' +
          'bit13 with no device evidence and must never reach a shipping build. ' +
          'Restore the file (scripts/build-typed-validation-hap.ps1 does it in a ' +
          'finally block), or set AMCL_TYPED_VALIDATION=1 if this really is the ' +
          'validation build.');
      }
    }
  }

  return issues;
}

const invokedDirectly = process.argv[1] &&
  resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url));
if (invokedDirectly) {
  const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
  const issues = validateGate0Evidence(root);
  if (issues.length > 0) {
    for (const issue of issues) {
      console.error(`[check-gate0-evidence] ${issue}`);
    }
    process.exitCode = 1;
  } else {
    const manifest = JSON.parse(readFileSync(join(root, 'gate0-evidence.lock'), 'utf8'));
    const approved = MANAGED_CAPABILITIES
      .filter(capability => manifest.capabilities[capability].approved);
    console.log('[check-gate0-evidence] PASS');
    console.log(`  managed capabilities: ${MANAGED_CAPABILITIES.length}`);
    console.log(`  approved: ${approved.length === 0 ? 'none' : approved.join(', ')}`);
    // 只陈述本脚本实际验证过的事。configure 期是否真的 fail closed 由
    // test-gate0-evidence-cmake.mjs 用真实 cmake 证明，不在这里下结论。
    console.log('  checked here: manifest schema/fields, hash-pinned evidence docs,');
    console.log('                managed-list agreement, no unmanaged VERIFIED macro,');
    console.log('                options default OFF, build profile not over-enabling');
    console.log('  configure-time fail-closed behaviour: see test-gate0-evidence-cmake.mjs');
  }
}
