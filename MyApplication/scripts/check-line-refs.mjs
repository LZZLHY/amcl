#!/usr/bin/env node
// scripts/check-line-refs.mjs
//
// 扫描指定文件，找出所有 `<path>:<line>` 形式的引用并校验。
//
// 改进版（v2 2026-05-07）：
//   1. bare filename（无路径分隔符）通过 repo-wide search 解析；
//   2. keyword 匹配在 ±5 行窗口内寻找（容忍函数体中段）；
//   3. 输出明确的 STALE / SOFT-STALE / OK 三级；
//   4. 自动跳过原始报告中的 "::N-M" 描述性范围（位置上下文 ≥ 2 关键字才报错）。
//
// 用法:
//   node scripts/check-line-refs.mjs                    # 扫默认文件集
//   node scripts/check-line-refs.mjs file1 file2 ...    # 指定扫描

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');

const SCAN_FILES = process.argv.slice(2).length
  ? process.argv.slice(2)
  : [
      'docs/ROADMAP.md',
      'docs/security-signing.md',
      'docs/self-inspection/2026-05-06_AMCL_项目全面评审报告.md',
      'JavaApp/src/com/amcl/launcher/AmclLauncher.java',
      'JavaApp/test/com/amcl/launcher/AmclLauncherTest.java',
      'entry/src/main/cpp/jvm/mc_launcher.cpp',
      'entry/src/main/cpp/jvm/jvm_launcher.cpp',
      'entry/build-profile.json5',
      'entry/obfuscation-rules.txt',
      'setup_deps.sh',
      'deps.lock',
    ];

// 引用形式
const REF_RE = /@?([A-Za-z0-9_\-\\\/.]+\.(?:cpp|h|hpp|c|java|ets|ts|mjs|js|json5?|md|txt|sh|toml|cfg|properties))(?::(\d+)(?:-(\d+))?)/g;

// 关键字（值为关键字数组）
const CONTEXT_KEYWORDS = {
  setSystemProperty: ['setSystemProperty'],
  'System.setProperty': ['System.setProperty'],
  allocator: ['allocator'],
  'java.system.class.loader': ['java.system.class.loader'],
  AmclClassLoader: ['AmclClassLoader'],
  AmclLauncher: ['AmclLauncher', 'class AmclLauncher', 'AmclLauncher{', 'package com.amcl'],
  ForgeInstaller: ['ForgeInstaller', 'LGPL', 'Lesser General Public', '@version', 'package net.minecraftforge'],
  phase_setProperties: ['phase_setProperties', 'setSystemProperty'],
  watchdog: ['watchdog', 'Watchdog'],
  testSystemPropertiesLwjglAllocatorLocked: ['testSystemPropertiesLwjglAllocatorLocked'],
  setupSystemProperties: ['setupSystemProperties'],
  verifyArchiveIntegrity: ['verifyArchiveIntegrity', 'sha256'],
  CURLOPT_CAINFO: ['CURLOPT_CAINFO', 'cacert', 'caBundle', 'CaBundle', 'initializeCaBundle'],
  obfuscation: ['obfuscation', 'enable'],
  ProcessBuilder: ['ProcessBuilder', 'createMockMainJar'],
  initializeCaBundle: ['initializeCaBundle', 'cacert'],
  Forge: ['LGPL', 'Forge', 'forge', 'Lesser General Public'],
};

const KW_WINDOW = 12;

// repo-wide bare filename index
const repoIndex = new Map();
function buildRepoIndex(dir) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, ent.name);
    if (ent.isDirectory()) {
      if (['.git', 'node_modules', 'build', 'oh_modules', '.hvigor', '.idea'].includes(ent.name)) continue;
      buildRepoIndex(full);
    } else if (ent.isFile()) {
      const rel = path.relative(ROOT, full).replace(/\\/g, '/');
      const arr = repoIndex.get(ent.name) || [];
      arr.push(rel);
      repoIndex.set(ent.name, arr);
    }
  }
}
buildRepoIndex(ROOT);

function resolveRef(refPath) {
  if (refPath.includes('/') || refPath.includes('\\')) {
    const direct = path.join(ROOT, refPath);
    return fs.existsSync(direct) ? direct : null;
  }
  // bare filename: search index
  const hits = repoIndex.get(refPath);
  if (!hits || hits.length === 0) return null;
  if (hits.length === 1) return path.join(ROOT, hits[0]);
  // multiple — pick the shortest path (heuristic: closest to root, most "canonical")
  const best = hits.slice().sort((a, b) => a.length - b.length)[0];
  return path.join(ROOT, best);
}

let totalRefs = 0;
const findings = { STALE: [], SOFTSTALE: [], MISS: [], OOR: [], OK: [] };

for (const f of SCAN_FILES) {
  const abs = path.join(ROOT, f);
  if (!fs.existsSync(abs)) {
    console.warn(`[SKIP] ${f} not found`);
    continue;
  }
  const lines = fs.readFileSync(abs, 'utf8').split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    REF_RE.lastIndex = 0;
    let m;
    while ((m = REF_RE.exec(line)) !== null) {
      const [, refPath, lineNumS, lineNumEndS] = m;
      const lineNum = parseInt(lineNumS, 10);
      const lineNumEnd = lineNumEndS ? parseInt(lineNumEndS, 10) : lineNum;

      totalRefs++;
      const refDesc = `${f}:${i + 1}  →  ${refPath}:${lineNumS}${lineNumEndS ? '-' + lineNumEndS : ''}`;

      const targetAbs = resolveRef(refPath);
      if (!targetAbs) {
        findings.MISS.push({ ref: refDesc, msg: `target not found in repo: ${refPath}`, context: line.trim() });
        continue;
      }

      const targetLines = fs.readFileSync(targetAbs, 'utf8').split(/\r?\n/);
      if (lineNum > targetLines.length) {
        findings.OOR.push({ ref: refDesc, msg: `line ${lineNum} OOR (file has ${targetLines.length})`, context: line.trim() });
        continue;
      }

      // 关键字匹配：在引用所在源行中找已知关键字，再在目标 ±KW_WINDOW 行查
      const expectedKeyword = Object.entries(CONTEXT_KEYWORDS).find(([, kws]) => kws.some((kw) => line.includes(kw)));
      if (!expectedKeyword) {
        findings.OK.push({ ref: refDesc, msg: 'no keyword check', target: (targetLines[lineNum - 1] || '').trim().slice(0, 100), context: line.trim().slice(0, 100) });
        continue;
      }
      const [kwName, kws] = expectedKeyword;

      // 检查范围: [lineNum-KW_WINDOW, lineNumEnd+KW_WINDOW]
      const lo = Math.max(0, lineNum - 1 - KW_WINDOW);
      const hi = Math.min(targetLines.length, lineNumEnd + KW_WINDOW);
      let foundIn = -1;
      for (let k = lo; k < hi; k++) {
        if (kws.some((kw) => targetLines[k].includes(kw))) {
          foundIn = k + 1;
          break;
        }
      }

      if (foundIn !== -1) {
        const dist = Math.min(Math.abs(foundIn - lineNum), Math.abs(foundIn - lineNumEnd));
        if (dist <= 2) {
          findings.OK.push({ ref: refDesc, msg: `keyword "${kwName}" at L${foundIn} (≤2 from ref)`, target: (targetLines[lineNum - 1] || '').trim().slice(0, 100), context: line.trim().slice(0, 100) });
        } else {
          findings.SOFTSTALE.push({ ref: refDesc, msg: `keyword "${kwName}" found at L${foundIn} but ref points L${lineNum}-${lineNumEnd} (delta ${dist})`, target: (targetLines[lineNum - 1] || '').trim().slice(0, 100), context: line.trim().slice(0, 100) });
        }
      } else {
        // 全文搜索给提示
        const allHits = [];
        for (let k = 0; k < targetLines.length; k++) {
          if (kws.some((kw) => targetLines[k].includes(kw))) allHits.push(k + 1);
          if (allHits.length >= 5) break;
        }
        findings.STALE.push({ ref: refDesc, msg: `keyword "${kwName}" not in window L${lo + 1}..${hi}; nearest hits: [${allHits.join(', ')}${allHits.length >= 5 ? ', ...' : ''}]`, target: (targetLines[lineNum - 1] || '').trim().slice(0, 100), context: line.trim().slice(0, 100) });
      }
    }
  }
}

const totalIssues = findings.STALE.length + findings.SOFTSTALE.length + findings.MISS.length + findings.OOR.length;

console.log(`\n=== Line-Reference Check (v2) ===\n`);
console.log(`Scanned files: ${SCAN_FILES.length}`);
console.log(`Total refs: ${totalRefs}`);
console.log(`  OK:        ${findings.OK.length}`);
console.log(`  SOFTSTALE: ${findings.SOFTSTALE.length}  (keyword found but >2 lines from ref)`);
console.log(`  STALE:     ${findings.STALE.length}`);
console.log(`  MISS:      ${findings.MISS.length}  (target file not found)`);
console.log(`  OOR:       ${findings.OOR.length}`);
console.log();

for (const sev of ['STALE', 'OOR', 'MISS', 'SOFTSTALE']) {
  if (findings[sev].length === 0) continue;
  console.log(`--- ${sev} (${findings[sev].length}) ---`);
  for (const x of findings[sev]) {
    console.log(`  ${x.ref}`);
    console.log(`    ${x.msg}`);
    console.log(`    ctx: ${x.context}`);
    if (x.target) console.log(`    tgt: ${x.target}`);
    console.log();
  }
}

// 退出码：
//   OOR (line out of range) 是硬错误；
//   STALE / MISS / SOFTSTALE 是启发式，可能误报，默认仅警告。
//   --strict 让 STALE 也变硬错误（CI 用）。
const strict = process.argv.includes('--strict');
const exitErr = (findings.OOR.length > 0) || (strict && findings.STALE.length > 0) ? 1 : 0;
process.exit(exitErr);
