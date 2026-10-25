#!/usr/bin/env node
/**
 * 检查基于公开发行源码的贡献。基线身份从指定 Git commit 读取，PR/工作树则允许
 * 修改源码；两者不能共用“当前文件必须等于发行清单”的判据。此工具没有私有仓、
 * SDK、签名或发布权限，只提供来源、变更范围及适用的无 SDK 语法检查。
 *
 * 用法：node tools/check-public-contribution.mjs --base <40位公开基线commit> [--json] [--release-sync]
 * 正式 SOURCE_SNAPSHOT.json 由维护者发版生成，贡献者不应重写它来使修改版冒充原版。
 * --release-sync 仅供维护者显式核对已提交、干净的人工同步候选；它不授权发布，
 * 也不能代替私有源提交、真实构建或用户批准。公共 CI 仅向同仓 owner PR 开放此模式。
 */
import fs from 'node:fs';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { StringDecoder } from 'node:string_decoder';
import { fileURLToPath } from 'node:url';
import { parseJson5 } from '../MyApplication/scripts/product-contract.mjs';
import { classify } from './lib/source-export.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const snapshotPath = 'MyApplication/SOURCE_SNAPSHOT.json';
const args = process.argv.slice(2);
const jsonOutput = args.includes('--json');
const releaseSync = args.includes('--release-sync');
const report = {
  ok: false, mode: releaseSync ? 'release-sync' : 'contribution', base: null, sourceCommit: null,
  baselineFiles: 0, candidate: null, changes: [], checks: [], failures: [],
  notRun: ['HarmonyOS SDK / HAP 编译', '第三方 Native / 游戏 JDK 重建', '设备安装与游戏运行'],
};

/** Git 不经 shell 拼接；调用错误必须保留，不能把缺失基线解释为没有改动。 */
function git(...params) {
  const result = spawnSync('git', ['-C', root, ...params], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`Git ${params[0]} 失败：${result.stderr.trim()}`);
  return result.stdout;
}

/** 清单仅允许仓内相对 POSIX 路径；不解码路径或允许链接绕到贡献者仓库外。 */
function safePath(relative) {
  if (typeof relative !== 'string' || !relative || relative.includes('\\') || relative.includes('\0')
      || relative.startsWith('/') || /^[A-Za-z]:/.test(relative)
      || relative.split('/').some(part => !part || part === '.' || part === '..')) {
    throw new Error(`不安全的清单路径：${JSON.stringify(relative)}`);
  }
  return relative;
}

/** 读取指定 Git 树的 mode、类型与对象身份；子模块无需初始化即可核对 gitlink。 */
function treeAt(commit) {
  const tree = new Map();
  for (const record of git('ls-tree', '-r', '-z', commit).split('\0').filter(Boolean)) {
    const match = record.match(/^(\d+) (\w+) ([a-f0-9]{40})\t([\s\S]+)$/);
    if (!match) throw new Error('无法解析公开基线 Git 树');
    tree.set(match[4], { mode: match[1], type: match[2], object: match[3] });
  }
  return tree;
}

/**
 * 用一个 cat-file 子进程流式核对所有基线内容，避免逐文件启动 Git，也不把约百 MB
 * 的 Native 制品一次加载进 JS 堆。LF 规范化跨 stdout 块保持 UTF-8/CRLF 边界完整。
 * 进程结束前同时核对对象头、字节数、分隔符及全部摘要，任何缺项都使检查失败。
 */
async function verifyBlobs(records, label) {
  const items = [...records.values()];
  if (!items.length) throw new Error('公开基线清单没有文件');
  await new Promise((resolve, reject) => {
    const child = spawn('git', ['-C', root, 'cat-file', '--batch'], { stdio: ['pipe', 'pipe', 'pipe'] });
    let index = 0, header = Buffer.alloc(0), remaining = null, separator = false;
    let hash, decoder, trailingCR = '', stderr = '', failed = false;
    const fail = error => { if (!failed) { failed = true; child.kill(); reject(error); } };
    const text = chunk => {
      let value = trailingCR + chunk;
      trailingCR = value.endsWith('\r') ? '\r' : '';
      if (trailingCR) value = value.slice(0, -1);
      hash.update(value.replace(/\r\n/g, '\n'));
    };
    child.on('error', fail);
    child.stdin.on('error', fail);
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.stdout.on('data', chunk => {
      if (failed) return;
      try {
        let offset = 0;
        while (offset < chunk.length) {
          if (separator) {
            if (chunk[offset++] !== 10) throw new Error('Git blob 分隔符损坏');
            separator = false;
            index++;
            continue;
          }
          if (remaining === null) {
            const end = chunk.indexOf(10, offset);
            if (end < 0) { header = Buffer.concat([header, chunk.subarray(offset)]); break; }
            const line = Buffer.concat([header, chunk.subarray(offset, end)]).toString('utf8');
            const item = items[index];
            const match = line.match(/^([a-f0-9]{40}) blob (\d+)$/);
            if (!item || !match || match[1] !== item.object) throw new Error(`Git blob 头不符：${line}`);
            remaining = Number(match[2]);
            hash = createHash('sha256');
            decoder = item.normalization === 'lf' ? new StringDecoder('utf8') : null;
            trailingCR = '';
            header = Buffer.alloc(0);
            offset = end + 1;
          }
          const count = Math.min(remaining, chunk.length - offset);
          const bytes = chunk.subarray(offset, offset + count);
          if (decoder) text(decoder.write(bytes)); else hash.update(bytes);
          remaining -= count;
          offset += count;
          if (remaining === 0) {
            if (decoder) { text(decoder.end()); if (trailingCR) hash.update(trailingCR); }
            const item = items[index];
            if (hash.digest('hex') !== item.sha256) throw new Error(`${label}原版哈希不符：${item.relative}`);
            remaining = null;
            separator = true;
          }
        }
      } catch (error) { fail(error); }
    });
    child.on('close', code => {
      if (failed) return;
      if (code !== 0 || index !== items.length || remaining !== null || separator || header.length) {
        reject(new Error(`公开基线对象未完整核对：${index}/${items.length}，exit=${code} ${stderr.trim()}`));
      } else resolve();
    });
    child.stdin.end(items.map(item => item.object).join('\n') + '\n');
  });
}

/**
 * 原版校验只读取 --base 的不可变对象。清单中的直接文件、依赖补丁、脱敏证据和
 * gitlink 分别核对，不能用 PR 自己提交的新哈希作为其来源证明。
 */
async function verifySnapshot(commit, label, { requireModes = false } = {}) {
  const tree = treeAt(commit);
  const manifest = JSON.parse(git('show', `${commit}:${snapshotPath}`));
  if (manifest.schema !== 1 || manifest.sourceDirty !== false || !/^[a-f0-9]{40}$/.test(manifest.sourceCommit ?? '')
      || !Array.isArray(manifest.entries) || !manifest.entries.length) {
    throw new Error('公开基线必须含有干净、完整来源身份的 SOURCE_SNAPSHOT.json');
  }
  const records = new Map();
  const add = (relative, sha256, normalization) => {
    safePath(relative);
    if (!/^[a-f0-9]{64}$/.test(sha256 ?? '') || !['lf', 'none'].includes(normalization)) {
      throw new Error(`公开基线清单摘要或规范化规则无效：${relative}`);
    }
    const full = `MyApplication/${relative}`;
    const object = tree.get(full);
    if (!object || object.type !== 'blob' || !['100644', '100755'].includes(object.mode)) {
      throw new Error(`公开基线缺少普通文件：${full}`);
    }
    // 同一路径可能同时受“文本LF身份”和“补丁原始字节身份”约束，必须分别核对。
    const key = `${full}:${normalization}`;
    const old = records.get(key);
    if (old && old.sha256 !== sha256) {
      throw new Error(`公开基线重复摘要冲突：${relative}`);
    }
    records.set(key, { ...object, relative: full, sha256, normalization });
  };
  const entryPaths = new Set();
  for (const entry of manifest.entries) {
    if (entryPaths.has(entry.path)) throw new Error(`${label}包含重复源码条目：${entry.path}`);
    entryPaths.add(entry.path);
    add(entry.path, entry.sha256, entry.normalization);
    if (requireModes && !['100644', '100755'].includes(entry.mode)) throw new Error(`${label}源码条目缺少有效 Git mode：${entry.path}`);
    if (entry.mode && tree.get(`MyApplication/${entry.path}`)?.mode !== entry.mode) throw new Error(`公开基线 Git mode 不符：${entry.path}`);
  }
  if (manifest.publicGitmodulesSha256) {
    const modules = tree.get('.gitmodules');
    if (!modules || modules.type !== 'blob' || modules.mode !== '100644') throw new Error('公开基线缺少根 .gitmodules');
    records.set('.gitmodules:lf', { ...modules, relative: '.gitmodules', sha256: manifest.publicGitmodulesSha256, normalization: 'lf' });
  }
  const dependencyPaths = new Set();
  for (const dependency of manifest.dependencyWorktrees ?? []) {
    if (dependencyPaths.has(dependency.path)) throw new Error(`${label}包含重复 gitlink：${dependency.path}`);
    dependencyPaths.add(dependency.path);
    const relative = `MyApplication/${safePath(dependency.path)}`;
    const entry = tree.get(relative);
    if (!entry || entry.mode !== '160000' || entry.object !== dependency.baseCommit) {
      throw new Error(`公开基线 gitlink 不符：${relative}`);
    }
    if (dependency.patch) add(dependency.patch, dependency.patchSha256, 'none');
  }
  for (const evidence of manifest.publicEvidence ?? []) add(evidence.path, evidence.publicSha256, 'lf');
  if (manifest.publicEvidenceLockSha256) add('gate0-evidence.lock', manifest.publicEvidenceLockSha256, 'lf');
  await verifyBlobs(records, label);
  return { tree, manifest, entryPaths, verifiedFiles: records.size };
}

/**
 * 清单变更的维护者候选须覆盖候选 Git 树中的全部导出源码，而非只核对清单自己列出的
 * 子集。归属规则取候选 commit 的冻结 policy，与导出器复用同一 classify 函数；
 * 公开专属文档/工具及正常生成物保持各自边界，删除了源码的版本不要求保留旧文件。
 */
function verifyCandidateCoverage(commit, candidate) {
  const policy = JSON.parse(git('show', `${commit}:tools/source-export-policy.json`));
  const fields = ['publicOwnedFiles', 'generatedFiles', 'derivedEvidence', 'excludedSegments',
    'excludedExtensions', 'sourceFiles', 'privateFiles', 'privateRoots', 'sourceRoots'];
  if (policy.schemaVersion !== 1 || fields.some(field => !Array.isArray(policy[field]))) {
    throw new Error('公开候选缺少可验证的导出归属规则');
  }
  const links = new Set((candidate.manifest.dependencyWorktrees ?? []).map(item => item.path));
  const evidence = new Set((candidate.manifest.publicEvidence ?? []).map(item => item.path));
  for (const [full, object] of candidate.tree) {
    if (!full.startsWith('MyApplication/')) continue;
    const relative = safePath(full.slice('MyApplication/'.length));
    const owner = classify(relative, policy);
    if (owner === 'source' && object.mode === '160000' && !links.has(relative)) {
      throw new Error(`公开候选清单遗漏 gitlink：${relative}`);
    }
    if (owner === 'source' && object.type === 'blob' && !candidate.entryPaths.has(relative)) {
      throw new Error(`公开候选清单遗漏源码文件：${relative}`);
    }
    if (owner === 'derived' && object.type === 'blob' && !evidence.has(relative)) {
      throw new Error(`公开候选清单遗漏派生证据：${relative}`);
    }
    if (relative === 'DEPENDENCY_INPUTS.json' && !candidate.entryPaths.has(relative)) {
      throw new Error('公开候选清单遗漏派生依赖报告');
    }
  }
  if (candidate.tree.has('MyApplication/gate0-evidence.lock') && !candidate.manifest.publicEvidenceLockSha256) {
    throw new Error('公开候选清单遗漏 Gate 0 锁身份');
  }
  if (candidate.tree.has('.gitmodules') && !candidate.manifest.publicGitmodulesSha256) {
    throw new Error('公开候选清单遗漏根 .gitmodules 身份');
  }
}

/**
 * 比较基线与当前实际工作树，并纳入尚未 git add 的新文件，方便贡献者提交前使用。
 * 删除和新增分别列出，避免 Git 重命名启发式掩盖需要审阅的精确路径。
 */
function changedFiles(commit) {
  const parts = git('diff', '--name-status', '-z', '--no-renames', commit, '--').split('\0');
  const changes = [];
  for (let index = 0; index < parts.length - 1; index += 2) {
    changes.push({ status: parts[index], path: safePath(parts[index + 1]) });
  }
  const known = new Set(changes.map(item => item.path));
  for (const relative of git('ls-files', '--others', '--exclude-standard', '-z').split('\0').filter(Boolean)) {
    if (!known.has(relative)) changes.push({ status: '?', path: safePath(relative) });
  }
  return changes.sort((left, right) => left.path.localeCompare(right.path));
}

/** 对实际变更执行可用的无 SDK 检查；这里不启动脚本本身，也不自动构建整个应用。 */
function checkChanges(changes, verifiedRelease = false) {
  for (const change of changes) {
    if (change.path === snapshotPath) {
      if (verifiedRelease) {
        report.checks.push({ path: change.path, check: 'committed release snapshot verified from Git objects' });
        continue;
      }
      report.failures.push('SOURCE_SNAPSHOT.json 只由维护者发版同步生成；请保留基线清单，直接提交源码修改。');
      continue;
    }
    const file = path.join(root, change.path);
    try {
      // 不跟随父目录链接；只检查最终文件会把链接目录下的仓外内容当成普通源码。
      let current = root, stat = null;
      for (const part of change.path.split('/')) {
        current = path.join(current, part);
        try { stat = fs.lstatSync(current); } catch (error) {
          if (error.code !== 'ENOENT') throw error;
          stat = null;
          break;
        }
        if (stat.isSymbolicLink()) throw new Error('变更路径或父目录是链接，需维护者单独审阅');
      }
      if (!stat) { report.checks.push({ path: change.path, check: 'deleted' }); continue; }
      if (!stat.isFile()) { report.checks.push({ path: change.path, check: 'gitlink/directory; build not run' }); continue; }
      if (/\.(?:mjs|cjs|js)$/.test(file)) {
        const result = spawnSync(process.execPath, ['--check', file], { encoding: 'utf8', maxBuffer: 1024 * 1024 });
        if (result.error) throw result.error;
        if (result.status !== 0) throw new Error(result.stderr.trim() || `node --check exit=${result.status}`);
        report.checks.push({ path: change.path, check: 'node --check' });
      } else if (/\.json(?:5)?$/.test(file) || /\.json5\.template$/.test(file)) {
        const source = fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '');
        if (/\.json5(?:\.template)?$/.test(file)) parseJson5(source); else JSON.parse(source);
        report.checks.push({ path: change.path, check: 'JSON/JSON5 parse' });
      } else report.checks.push({ path: change.path, check: 'reported; no generic compiler available' });
    } catch (error) { report.failures.push(`${change.path}：${error.message}`); }
  }
}

try {
  if (args.filter(value => value === '--base').length !== 1) throw new Error('必须提供一次 --base <完整40位公开基线commit>');
  const baseIndex = args.indexOf('--base');
  const commit = args[baseIndex + 1];
  const allowed = new Set([baseIndex, baseIndex + 1, ...(jsonOutput ? [args.indexOf('--json')] : []),
    ...(releaseSync ? [args.indexOf('--release-sync')] : [])]);
  if (!/^[a-f0-9]{40}$/.test(commit ?? '') || args.some((_, index) => !allowed.has(index))) {
    throw new Error('用法：node tools/check-public-contribution.mjs --base <完整40位公开基线commit> [--json] [--release-sync]');
  }
  report.base = commit;
  if (git('rev-parse', '--verify', `${commit}^{commit}`).trim() !== commit) throw new Error('公开基线不是可读取的 Git commit');
  const baseline = await verifySnapshot(commit, '公开基线');
  report.sourceCommit = baseline.manifest.sourceCommit;
  report.baselineFiles = baseline.verifiedFiles;
  if (releaseSync) {
    if (git('status', '--porcelain', '--untracked-files=all', '--ignore-submodules=none').trim()) {
      throw new Error('维护者源码同步检查要求已提交且干净的候选 HEAD；请先提交同步结果，不检查未提交或脏工作树。');
    }
    const head = git('rev-parse', '--verify', 'HEAD^{commit}').trim();
    const manifestChanged = baseline.tree.get(snapshotPath)?.object !== treeAt(head).get(snapshotPath)?.object;
    if (manifestChanged) {
      const candidate = await verifySnapshot(head, '公开候选', { requireModes: true });
      verifyCandidateCoverage(head, candidate);
      report.candidate = { commit: head, sourceCommit: candidate.manifest.sourceCommit,
        verifiedFiles: candidate.verifiedFiles, manifestChanged: true, coverageChecked: true };
    } else {
      // owner 也可能提出普通功能修复。没有改官方清单时，源码应按贡献版检查，
      // 不能再次拿旧发行哈希去要求 HEAD 源码完全不变；只报告本次未验证新发行快照。
      report.candidate = { commit: head, sourceCommit: baseline.manifest.sourceCommit,
        verifiedFiles: 0, manifestChanged: false, coverageChecked: false,
        snapshotValidation: 'not-required-unchanged-manifest; committed source checked as contribution' };
    }
  }
  report.changes = changedFiles(commit);
  checkChanges(report.changes, releaseSync && report.candidate?.manifestChanged === true);
  report.ok = report.failures.length === 0;
} catch (error) { report.failures.push(error.message); }

if (jsonOutput) console.log(JSON.stringify(report, null, 2));
else {
  console.log(`${report.ok ? 'PASS' : 'FAIL'} public ${report.mode}: base=${report.base}, verified original files=${report.baselineFiles}, changes=${report.changes.length}`);
  if (report.candidate) console.log(`  committed candidate=${report.candidate.commit}, verified files=${report.candidate.verifiedFiles}, snapshot changed=${report.candidate.manifestChanged}`);
  for (const change of report.changes) console.log(`  ${change.status} ${change.path}`);
  for (const failure of report.failures) console.error(`  ${failure}`);
  console.log(`未执行：${report.notRun.join('；')}。通过仅表示上述基线与无 SDK 检查通过。`);
}
process.exitCode = report.ok ? 0 : 1;
