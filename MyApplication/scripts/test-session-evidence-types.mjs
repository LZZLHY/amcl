#!/usr/bin/env node
/**
 * 会话证据模型宿主测试。
 *
 * 只测试共享纯策略，不伪装成设备/LogShare 端到端测试：
 *   - 默认集合必须是 latest + launcher + 真正崩溃报告；
 *   - optional 文件不能被默认选择；
 *   - 路径遍历和绝对路径必须拒绝；
 *   - 用户选择只能保留真实可上传文件。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import ts from './lib/ets-compiler.mjs';

const file = path.resolve(import.meta.dirname, '../commons/src/main/ets/utils/EvidenceTypes.ets');
const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
}).outputText;
const mod = { exports: {} };
vm.runInThisContext('(function(module,exports){' + compiled + '\n})', { filename: file })(mod, mod.exports);

const {
  EvidenceRole, EvidenceSource, EvidenceFileState, EvidenceUploadPolicy,
  isSafeEvidencePath, defaultEvidenceSelection, normalizeEvidenceSelection,
} = mod.exports;

const files = [
  { fileId: 'latest', path: 'game/logs/latest.log', localPath: '/tmp/latest.log',
    role: EvidenceRole.MINECRAFT_MAIN, source: EvidenceSource.MOJANG_LOG4J,
    state: EvidenceFileState.COMPLETE, uploadPolicy: EvidenceUploadPolicy.OPTIONAL,
    defaultSelected: true, bytes: 10, lines: 1, capturedAt: 1, completedAt: 2,
    attribution: 'exact', reason: '', digest: '' },
  { fileId: 'launcher', path: 'launcher/launcher.log', localPath: '/tmp/launcher.log',
    role: EvidenceRole.LAUNCHER, source: EvidenceSource.AMCL_LAUNCHER,
    state: EvidenceFileState.COMPLETE, uploadPolicy: EvidenceUploadPolicy.OPTIONAL,
    defaultSelected: true, bytes: 10, lines: 1, capturedAt: 1, completedAt: 2,
    attribution: 'exact', reason: '', digest: '' },
  { fileId: 'crash', path: 'crash-reports/crash.txt', localPath: '/tmp/crash.txt',
    role: EvidenceRole.CRASH_REPORT, source: EvidenceSource.MOJANG_LOG4J,
    state: EvidenceFileState.COMPLETE, uploadPolicy: EvidenceUploadPolicy.OPTIONAL,
    defaultSelected: true, bytes: 10, lines: 1, capturedAt: 1, completedAt: 2,
    attribution: 'exact', reason: '', digest: '' },
  { fileId: 'render', path: 'render/renderer.log', localPath: '/tmp/render.log',
    role: EvidenceRole.RENDERER, source: EvidenceSource.AMCL_RENDERER,
    state: EvidenceFileState.COMPLETE, uploadPolicy: EvidenceUploadPolicy.OPTIONAL,
    defaultSelected: false, bytes: 10, lines: 1, capturedAt: 1, completedAt: 2,
    attribution: 'exact', reason: '', digest: '' },
  { fileId: 'missing', path: 'game/mc_output.log', localPath: '/tmp/missing.log',
    role: EvidenceRole.MINECRAFT_OUTPUT, source: EvidenceSource.MC_STDIO,
    state: EvidenceFileState.MISSING, uploadPolicy: EvidenceUploadPolicy.OPTIONAL,
    defaultSelected: false, bytes: 0, lines: 0, capturedAt: 1, completedAt: 0,
    attribution: 'exact', reason: '源文件不存在', digest: '' },
];

assert.equal(isSafeEvidencePath('game/logs/latest.log'), true);
assert.equal(isSafeEvidencePath('../latest.log'), false);
assert.equal(isSafeEvidencePath('/absolute.log'), false);
assert.equal(isSafeEvidencePath('C:/absolute.log'), false);
assert.deepEqual(defaultEvidenceSelection(files), ['latest', 'launcher', 'crash']);
assert.deepEqual(normalizeEvidenceSelection(files, ['latest', 'render', 'missing', 'render']),
  ['latest', 'render']);
console.log('PASS: evidence roles, default selection, path safety and selection normalization');
