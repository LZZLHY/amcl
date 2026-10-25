/**
 * 人工发行导出的输入冻结、所有权判定与候选应用。Git对象提供源码字节，
 * 被忽略的发行制品只有通过既有制品门禁后才读取。本模块不联网、不提交、
 * 不推送、不发布应用，公开仓也不承担私有工程的日常开发。
 */
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { parseJson5 } from '../../MyApplication/scripts/product-contract.mjs';
import { collectDependencyInputs } from '../dependency-inputs.mjs';

export const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const manifestRelative = 'MyApplication/SOURCE_SNAPSHOT.json';

/** Git采用独立参数和管道，不经shell；blob保持原字节，失败立即终止预检。 */
function git(root, args, buffer = false, input) {
  return execFileSync('git', ['-C', root, ...args], { encoding: buffer ? null : 'utf8', input,
    maxBuffer: 256 * 1024 * 1024, stdio: ['pipe', 'pipe', 'pipe'] });
}

/** 发行路径使用可移植相对文件名，拒绝越界、设备名、Git元数据与Windows别名。 */
export function safeRelative(relative) {
  if (typeof relative !== 'string' || !relative || relative.includes('\\') || path.posix.isAbsolute(relative)
      || relative.split('/').some(part => !part || part === '.' || part === '..' || part.toLowerCase() === '.git'
        || /[:\x00-\x1f]/.test(part) || /[. ]$/.test(part) || /^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(part))) throw new Error(`Unsafe export path: ${relative}`);
  return relative;
}

/** 查每一级真实目录，不能让junction/symlink把精确文件操作导向仓库外。 */
function checkedPath(root, relative) {
  safeRelative(relative);
  let current = root;
  for (const part of relative.split('/')) {
    current = path.join(current, part);
    if (fs.lstatSync(current, { throwIfNoEntry: false })?.isSymbolicLink()) throw new Error(`Linked export path is not supported: ${relative}`);
  }
  return current;
}

/** 文字身份统一LF；二进制和非法UTF-8保留原字节，不因宿主换行误判贡献冲突。 */
export function contentIdentity(bytes, requested) {
  let text = !bytes.includes(0);
  try { new TextDecoder('utf-8', { fatal: true }).decode(bytes); } catch { text = false; }
  const normalization = requested ?? (text ? 'lf' : 'none');
  const normalized = normalization === 'lf' ? Buffer.from(bytes.toString('utf8').replace(/\r\n/g, '\n')) : bytes;
  return { sha256: digest(normalized), normalization };
}

/** 全部源路径必须有归属；新源码根不能被旧白名单静默丢弃。 */
export function classify(relative, policy) {
  safeRelative(relative);
  if (policy.publicOwnedFiles.includes(relative)) return 'public-owned';
  if (policy.generatedFiles.includes(relative)) return 'generated';
  if (policy.derivedEvidence.includes(relative)) return 'derived';
  if (relative.split('/').some(segment => policy.excludedSegments.includes(segment))
      || policy.excludedExtensions.includes(path.posix.extname(relative).toLowerCase())
      || path.posix.basename(relative) === 'AGENTS.md') return 'excluded';
  if (policy.sourceFiles.includes(relative)) return 'source';
  if (policy.privateFiles.includes(relative) || policy.privateRoots.includes(relative.split('/')[0])) return 'private';
  return policy.sourceRoots.includes(relative.split('/')[0]) ? 'source' : 'unclassified';
}

/**
 * 一次batch读取需要的冻结blob，不读取已排除的内部资料正文。树元数据仍完整
 * 分类，以发现新模块；batch边界按字节长度解析，源码中的换行不影响序列化。
 */
function readTree(root, commit, policy) {
  const rows = git(root, ['ls-tree', '-r', '-z', commit]).split('\0').filter(Boolean).map(row => {
    const match = row.match(/^(\d+) (\w+) ([a-f0-9]{40})\t([\s\S]+)$/);
    if (!match) throw new Error('Malformed Git tree record');
    return { mode: match[1], type: match[2], oid: match[3], path: safeRelative(match[4]) };
  });
  for (const row of rows) {
    row.owner = classify(row.path, policy);
    if (row.owner === 'unclassified') throw new Error(`Unclassified source path; review tools/source-export-policy.json: ${row.path}`);
  }
  const needed = rows.filter(row => row.type === 'blob' && (['source', 'derived'].includes(row.owner) || ['.gitmodules', 'gate0-evidence.lock'].includes(row.path)));
  const ids = [...new Set(needed.map(row => row.oid))];
  const data = git(root, ['cat-file', '--batch'], true, ids.join('\n') + '\n');
  const blobs = new Map();
  let offset = 0;
  for (const id of ids) {
    const end = data.indexOf(10, offset);
    const header = data.subarray(offset, end).toString('utf8').match(/^([a-f0-9]{40}) blob (\d+)$/);
    if (!header || header[1] !== id) throw new Error('Incomplete frozen Git object delivery');
    const length = Number(header[2]); offset = end + 1;
    if (offset + length >= data.length) throw new Error('Truncated frozen Git blob');
    blobs.set(id, Buffer.from(data.subarray(offset, offset + length))); offset += length + 1;
  }
  return { rows, blobs };
}

/** 从冻结.gitmodules取Git认可的path/url，拒绝内嵌凭据、本机协议及未注册gitlink。 */
function readModules(source, commit, links) {
  const modules = [];
  const names = git(source, ['config', '--blob', `${commit}:.gitmodules`, '--name-only', '--get-regexp', '^submodule\..*\.path$']).trim().split('\n').filter(Boolean);
  for (const name of names) {
    const relative = git(source, ['config', '--blob', `${commit}:.gitmodules`, '--get', name]).trim();
    if (!links.has(relative)) continue;
    const url = git(source, ['config', '--blob', `${commit}:.gitmodules`, '--get', name.replace(/\.path$/, '.url')]).trim();
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.search || parsed.hash) throw new Error(`A public HTTPS dependency URL is required: ${relative}`);
    modules.push({ path: relative, url, baseCommit: links.get(relative) });
  }
  if (modules.length !== links.size) throw new Error('Each exported gitlink needs a public .gitmodules URL');
  return modules.sort((left, right) => left.path.localeCompare(right.path, 'en'));
}

/** 脱敏只转换固定证据，保留原批准和风险接受语义，不新增设备结论。 */
function deriveEvidence(frozen, policy) {
  const gateBytes = frozen.get('gate0-evidence.lock');
  if (!gateBytes) throw new Error('Missing frozen gate0-evidence.lock');
  const gate = JSON.parse(gateBytes.toString('utf8'));
  const serials = [...new Set(Object.values(gate.capabilities ?? {}).flatMap(capability => capability.deviceMatrix ?? [])
    .flatMap(device => [...String(device).matchAll(/\b[A-Z0-9]{12,20}\b/g)].map(match => match[0])))];
  const redact = value => serials.reduce((text, serial, index) => text.split(serial).join(`REDACTED-DEVICE-${index + 1}`), value);
  const files = new Map(), evidence = [];
  for (const capability of Object.values(gate.capabilities ?? {})) {
    if (!capability.approved) continue;
    const relative = capability.evidenceDocument;
    if (!policy.derivedEvidence.includes(relative)) throw new Error(`Review a new public evidence input before export: ${relative}`);
    const original = frozen.get(relative);
    if (!original || digest(original) !== capability.evidenceSha256) throw new Error(`Original Gate 0 evidence drift: ${relative}`);
    const originalSha256 = digest(original);
    const header = `> 公开快照脱敏副本：原文 SHA-256 为 \`${originalSha256}\`。仅替换设备序号；原批准条件、已知缺口和风险接受事实均保留。本副本不构成新的设备验收。\n\n`;
    const bytes = Buffer.from(header + redact(original.toString('utf8')).replace(/\r\n/g, '\n'));
    capability.sourceEvidenceSha256 = originalSha256; capability.evidenceSha256 = digest(bytes);
    files.set(relative, bytes);
    if (!evidence.some(item => item.path === relative)) evidence.push({ path: relative, originalSha256, publicSha256: digest(bytes) });
  }
  gate.publicSnapshotNote = 'Device serials are redacted. Original approvals, dates and known evidence gaps are unchanged. See sourceEvidenceSha256 for the original document identity.';
  files.set('gate0-evidence.lock', Buffer.from(redact(JSON.stringify(gate, null, 2)) + '\n'));
  return { files, evidence };
}

/** 发布来源必须是指定HEAD的干净checkout；不能从未提交开发树制作发行快照。 */
function assertSource(source, expectedCommit) {
  if (!/^[a-f0-9]{40}$/.test(expectedCommit) || git(source, ['rev-parse', 'HEAD']).trim() !== expectedCommit) throw new Error('Expected source commit does not match the complete source HEAD');
  if (git(source, ['status', '--porcelain', '--untracked-files=all']).trim()) throw new Error('A release snapshot requires a clean source checkout');
}

/**
 * 生成只读计划与内存中的候选字节。外部计划只存路径/摘要/动作，不携带源码正文。
 * 预检涵盖固定来源、依赖、制品、旧清单、必要输入和三方冲突；失败不写公开目录。
 */
export function prepareExport({ source, publicRoot, expectedCommit }) {
  source = fs.realpathSync(source); publicRoot = fs.realpathSync(publicRoot);
  if (source === publicRoot || source === path.join(publicRoot, 'MyApplication')) throw new Error('Source and destination must differ');
  if (fs.realpathSync(git(source, ['rev-parse', '--show-toplevel']).trim()) !== source || fs.realpathSync(git(publicRoot, ['rev-parse', '--show-toplevel']).trim()) !== publicRoot) throw new Error('Use the actual source and public Git roots');
  assertSource(source, expectedCommit);
  if (git(publicRoot, ['status', '--porcelain', '--untracked-files=all']).trim()) throw new Error('Use a clean, exclusive public candidate checkout before planning or applying');
  const policyBytes = fs.readFileSync(path.join(publicRoot, 'tools/source-export-policy.json'));
  const policy = JSON.parse(policyBytes.toString('utf8'));
  if (policy.schemaVersion !== 1) throw new Error('Unsupported export policy schema');
  const { rows, blobs } = readTree(source, expectedCommit, policy);
  const frozen = new Map(), outputs = new Map(), modes = new Map(), links = new Map();
  const inventory = [], aliases = new Set();
  for (const row of rows) {
    const alias = row.path.toLowerCase();
    if (aliases.has(alias)) throw new Error(`Case-insensitive source collision: ${row.path}`);
    aliases.add(alias); inventory.push({ path: row.path, owner: row.owner });
    if (blobs.has(row.oid)) frozen.set(row.path, blobs.get(row.oid));
    if (row.owner !== 'source') continue;
    if (row.mode === '160000') { links.set(row.path, row.oid); continue; }
    if (!['100644', '100755'].includes(row.mode)) throw new Error(`Unsupported source file mode ${row.mode}: ${row.path}`);
    outputs.set(row.path, blobs.get(row.oid)); modes.set(row.path, row.mode);
  }
  for (const relative of policy.requiredDependencies) if (!links.has(relative)) throw new Error(`Missing required source gitlink: ${relative}`);
  const modules = readModules(source, expectedCommit, links), dependencyWorktrees = [];
  for (const module of modules) {
    const dependency = checkedPath(source, module.path);
    if (git(dependency, ['rev-parse', 'HEAD']).trim() !== module.baseCommit) throw new Error(`Source gitlink mismatch: ${module.path}`);
    if (git(dependency, ['status', '--porcelain', '--untracked-files=all']).trim()) throw new Error(`Dirty dependency requires a committed/published pin: ${module.path}`);
    const record = { path: module.path, baseCommit: module.baseCommit, dirty: false };
    const patch = path.posix.join(path.posix.dirname(module.path), 'local-worktree.patch');
    if (outputs.has(patch)) Object.assign(record, { patch, patchOrigin: 'tracked-source', patchSha256: digest(outputs.get(patch)) });
    dependencyWorktrees.push(record);
  }
  // 复用已冻结源树的既有制品验收，不把任意同名库当作获准发行输入。
  execFileSync(process.execPath, ['--input-type=module', '-e', "import {verifyDist} from './scripts/check-mobilegl-build-contract.mjs'; verifyDist();"], { cwd: source, stdio: ['ignore', 'pipe', 'pipe'] });
  for (const relative of policy.lockedBinaryInputs) {
    const filename = checkedPath(source, relative);
    if (!fs.statSync(filename).isFile()) throw new Error(`Missing locked artifact: ${relative}`);
    const bytes = fs.readFileSync(filename);
    outputs.set(relative, bytes); modes.set(relative, '100644'); frozen.set(relative, bytes);
  }
  const derived = deriveEvidence(frozen, policy);
  const app = parseJson5(frozen.get('AppScope/app.json5')?.toString('utf8') ?? '').app;
  if (typeof app?.versionName !== 'string' || !Number.isSafeInteger(app.versionCode) || app.versionCode <= 0) throw new Error('Invalid frozen application version');
  for (const relative of policy.requiredInputs) if (!outputs.has(relative)) throw new Error(`Missing public build/test input: ${relative}`);
  for (const relative of policy.requiredPublicInputs) if (!fs.existsSync(checkedPath(publicRoot, `MyApplication/${relative}`))) throw new Error(`Missing public-owned build input: ${relative}`);
  const dependencies = collectDependencyInputs({ files: frozen, dependencyWorktrees, sourceCommit: expectedCommit });
  outputs.set('DEPENDENCY_INPUTS.json', Buffer.from(JSON.stringify(dependencies, null, 2) + '\n'));
  const entries = [...outputs].sort(([left], [right]) => left.localeCompare(right, 'en')).map(([relative, bytes]) => ({ path: relative,
    ...contentIdentity(bytes), mode: modes.get(relative) ?? '100644', owner: relative === 'DEPENDENCY_INPUTS.json' ? 'derived' : 'source' }));
  for (const [relative, bytes] of derived.files) outputs.set(relative, bytes);
  const gitmodules = Buffer.from(modules.map(module => `[submodule "MyApplication/${module.path}"]\n\tpath = MyApplication/${module.path}\n\turl = ${module.url}\n`).join(''));
  const manifest = {
    schema: 1, sourceCommit: expectedCommit, sourceBranch: git(source, ['branch', '--show-current']).trim(), sourceDirty: false,
    note: 'Manually exported release source from immutable Git objects. Public-owned documentation and tooling are maintained separately. No continuous source synchronization.',
    release: { versionName: app.versionName, versionCode: app.versionCode }, exporter: { schemaVersion: 2, policySha256: digest(policyBytes) },
    dependencyWorktrees, lockedBinaryInputs: policy.lockedBinaryInputs, publicEvidence: derived.evidence,
    publicEvidenceLockSha256: contentIdentity(derived.files.get('gate0-evidence.lock'), 'lf').sha256,
    publicGitmodulesSha256: contentIdentity(gitmodules, 'lf').sha256, entries,
    selectionSummary: Object.fromEntries([...new Set(inventory.map(item => item.owner))].sort().map(owner => [owner, inventory.filter(item => item.owner === owner).length]))
  };
  const writes = new Map([...outputs].map(([relative, bytes]) => [`MyApplication/${relative}`, bytes]));
  writes.set('.gitmodules', gitmodules); writes.set(manifestRelative, Buffer.from(JSON.stringify(manifest, null, 2) + '\n'));
  const previousPath = checkedPath(publicRoot, manifestRelative);
  const previous = fs.existsSync(previousPath) ? JSON.parse(fs.readFileSync(previousPath, 'utf8')) : null;
  const baseline = new Map();
  for (const entry of previous?.entries ?? []) {
    safeRelative(entry.path);
    if (baseline.has(`MyApplication/${entry.path}`)) throw new Error('Duplicate path in previous release manifest');
    baseline.set(`MyApplication/${entry.path}`, entry);
  }
  for (const item of previous?.publicEvidence ?? []) baseline.set(`MyApplication/${safeRelative(item.path)}`, { sha256: item.publicSha256, normalization: 'lf' });
  if (previous?.publicEvidenceLockSha256) baseline.set('MyApplication/gate0-evidence.lock', { sha256: previous.publicEvidenceLockSha256, normalization: 'lf' });
  if (previous?.publicGitmodulesSha256) baseline.set('.gitmodules', { sha256: previous.publicGitmodulesSha256, normalization: 'lf' });
  // 旧版清单没有根.gitmodules身份时，以本次已冻结的公开HEAD接管该固定生成文件。
  for (const relative of [manifestRelative, '.gitmodules']) if (!baseline.has(relative) && fs.existsSync(checkedPath(publicRoot, relative))) baseline.set(relative, contentIdentity(fs.readFileSync(checkedPath(publicRoot, relative))));
  const indexModes = new Map(git(publicRoot, ['ls-files', '--stage', '-z']).split('\0').filter(Boolean).map(row => {
    const match = row.match(/^(\d+) [a-f0-9]{40} 0\t([\s\S]+)$/);
    if (!match) throw new Error('Unmerged public index is not an export baseline');
    return [match[2], match[1]];
  }));
  const actions = [], guards = [], conflicts = [], publicAliases = new Set();
  for (const relative of [...new Set([...baseline.keys(), ...writes.keys()])].sort()) {
    if (publicAliases.has(relative.toLowerCase())) throw new Error(`Case-only path migration requires explicit review: ${relative}`);
    publicAliases.add(relative.toLowerCase());
    const filename = checkedPath(publicRoot, relative);
    const existing = fs.existsSync(filename) ? fs.readFileSync(filename) : null, next = writes.get(relative) ?? null;
    const old = baseline.get(relative), appRelative = relative.startsWith('MyApplication/') ? relative.slice(14) : null;
    // 曾纳管但已明确归公开仓/生成器的文件保留，不能因源仓没选中而删除。
    if (!next && appRelative && ['public-owned', 'generated'].includes(classify(appRelative, policy))) { actions.push({ type: 'release-ownership', path: relative }); continue; }
    const currentHash = existing ? contentIdentity(existing, old?.normalization).sha256 : null;
    const nextHash = next ? contentIdentity(next, old?.normalization).sha256 : null;
    const currentMode = indexModes.get(relative) ?? null;
    const nextMode = next ? (modes.get(appRelative) ?? '100644') : null;
    const oldMode = old?.mode ?? currentMode;
    guards.push({ path: relative, rawSha256: existing ? digest(existing) : null });
    if (currentHash === nextHash && currentMode === nextMode) continue;
    if (currentHash !== (old?.sha256 ?? null) && currentHash !== nextHash
        || currentMode !== oldMode && currentMode !== nextMode) { conflicts.push(relative); continue; }
    actions.push({ type: next ? (existing ? 'update' : 'add') : 'delete', path: relative,
      beforeSha256: existing ? digest(existing) : null, afterSha256: next ? digest(next) : null, beforeMode: currentMode, afterMode: nextMode });
  }
  if (conflicts.length) throw new Error(`Public changes conflict with the release source; import/preserve them before synchronization: ${conflicts.join(', ')}`);
  const previousLinks = new Map((previous?.dependencyWorktrees ?? []).map(item => [safeRelative(item.path), item.baseCommit]));
  for (const relative of new Set([...previousLinks.keys(), ...links.keys()])) {
    const publicPath = `MyApplication/${relative}`;
    const staged = git(publicRoot, ['ls-files', '--stage', '--', publicPath]).match(/^160000 ([a-f0-9]{40}) /)?.[1] ?? null;
    const old = previousLinks.get(relative) ?? null, next = links.get(relative) ?? null;
    if (staged !== old && staged !== next) throw new Error(`Public gitlink conflict: ${relative}`);
    if (next === null && fs.existsSync(checkedPath(publicRoot, publicPath)) && fs.readdirSync(checkedPath(publicRoot, publicPath)).length) throw new Error(`Preserve initialized removed dependency before sync: ${relative}`);
    if (staged !== next) actions.push({ type: next ? 'gitlink' : 'remove-gitlink', path: publicPath, beforeCommit: staged, afterCommit: next });
  }
  assertSource(source, expectedCommit);
  const plan = { schemaVersion: 2, source, publicRoot, sourceCommit: expectedCommit,
    publicBaseCommit: git(publicRoot, ['rev-parse', 'HEAD']).trim(), policySha256: digest(policyBytes), release: manifest.release,
    inventory, actions, guards, manifestSha256: digest(writes.get(manifestRelative)), dependencies: dependencyWorktrees,
    validation: { frozenSource: true, dependencyWorktreesClean: true, lockedArtifacts: 'existing verifyDist gate passed',
      publicFetch: 'not run; validate a clean public clone before publishing', hapBuild: 'not run; export does not grant build or device qualification' } };
  return { plan, writes, publicRoot, source, expectedCommit };
}

/**
 * 应用重新核对的精确计划。先在仓外同文件系统写完新旧文件，再原子替换，
 * 磁盘满不会先截断原件。精确暂存本次动作（含可执行mode和gitlink），不提交。
 * 文件/索引回滚都有postimage核对；外部改动保留，恢复材料留在显式外部目录。
 */
export function applyExport({ plan, writes, publicRoot, source, expectedCommit }, { stageRoot }) {
  assertSource(source, expectedCommit);
  if (git(publicRoot, ['rev-parse', 'HEAD']).trim() !== plan.publicBaseCommit || git(publicRoot, ['status', '--porcelain', '--untracked-files=all']).trim()) throw new Error('Public candidate changed after planning');
  for (const guard of plan.guards) {
    const filename = checkedPath(publicRoot, guard.path);
    if ((fs.existsSync(filename) ? digest(fs.readFileSync(filename)) : null) !== guard.rawSha256) throw new Error(`Public input changed before apply: ${guard.path}`);
  }
  stageRoot = fs.realpathSync(stageRoot);
  if (fs.statSync(stageRoot).dev !== fs.statSync(publicRoot).dev) throw new Error('Atomic application requires an external plan directory on the same filesystem as the public candidate');
  const stage = fs.mkdtempSync(path.join(stageRoot, 'source-export-stage-'));
  const ordered = plan.actions.filter(action => action.type !== 'release-ownership').sort((left, right) => (left.path === manifestRelative) - (right.path === manifestRelative));
  const records = ordered.map((action, index) => {
    const filename = checkedPath(publicRoot, action.path), isLink = ['gitlink', 'remove-gitlink'].includes(action.type);
    const record = { action, filename, before: !isLink && fs.existsSync(filename) ? fs.readFileSync(filename) : null,
      next: !isLink ? writes.get(action.path) ?? null : null,
      backup: path.join(stage, `old-${index}`), prepared: path.join(stage, `new-${index}`) };
    if (record.before) fs.writeFileSync(record.backup, record.before, { flag: 'wx' });
    if (record.next) { fs.writeFileSync(record.prepared, record.next, { flag: 'wx' }); fs.chmodSync(record.prepared, action.afterMode === '100755' ? 0o755 : 0o644); }
    return record;
  });
  const gitPath = value => path.resolve(publicRoot, git(publicRoot, ['rev-parse', '--git-path', value]).trim());
  const lockFile = gitPath('public-source-export.lock'), lock = fs.openSync(lockFile, 'wx');
  const indexPath = gitPath('index'), index = fs.existsSync(indexPath) ? fs.readFileSync(indexPath) : null;
  const applied = [], directories = []; let indexChanged = false, expectedIndex = index ? digest(index) : null;
  const indexIdentity = () => fs.existsSync(indexPath) ? digest(fs.readFileSync(indexPath)) : null;
  try {
    for (const record of records) {
      const { action, filename } = record;
      if (indexIdentity() !== expectedIndex) throw new Error('Another writer changed the public index during apply');
      if (action.type === 'gitlink' || action.type === 'remove-gitlink') {
        if (action.type === 'gitlink' && !fs.existsSync(filename)) { fs.mkdirSync(filename, { recursive: true }); directories.push(filename); }
        git(publicRoot, action.type === 'gitlink' ? ['update-index', '--add', '--cacheinfo', `160000,${action.afterCommit},${action.path}`] : ['update-index', '--force-remove', '--', action.path]);
      } else {
        if ((fs.existsSync(filename) ? digest(fs.readFileSync(filename)) : null) !== action.beforeSha256) throw new Error(`Another writer changed a planned file during apply: ${action.path}`);
        if (record.next) { fs.mkdirSync(path.dirname(filename), { recursive: true }); fs.renameSync(record.prepared, filename); }
        else fs.unlinkSync(filename);
        applied.push(record);
        if (record.next) {
          const oid = git(publicRoot, ['hash-object', '-w', '--stdin'], false, record.next).trim();
          git(publicRoot, ['update-index', '--add', '--cacheinfo', `${action.afterMode},${oid},${action.path}`]);
        } else git(publicRoot, ['update-index', '--force-remove', '--', action.path]);
      }
      indexChanged = true; expectedIndex = indexIdentity();
    }
  } catch (error) {
    const retained = [];
    for (const item of applied.reverse()) {
      const current = fs.existsSync(item.filename) ? fs.readFileSync(item.filename) : null;
      if ((current === null) !== (item.next === null) || (current && !current.equals(item.next))) { retained.push(item.filename); continue; }
      if (item.before) { fs.chmodSync(item.backup, item.action.beforeMode === '100755' ? 0o755 : 0o644); fs.renameSync(item.backup, item.filename); }
      else fs.unlinkSync(item.filename);
    }
    if (indexChanged && index && indexIdentity() === expectedIndex) {
      let indexLock;
      try {
        indexLock = fs.openSync(indexPath + '.lock', 'wx');
        if (indexIdentity() !== expectedIndex) retained.push(indexPath);
        else { fs.writeFileSync(indexLock, index); fs.closeSync(indexLock); indexLock = undefined; fs.renameSync(indexPath + '.lock', indexPath); }
      } catch { retained.push(indexPath); }
      finally { if (indexLock !== undefined) { fs.closeSync(indexLock); fs.unlinkSync(indexPath + '.lock'); } }
    } else if (indexChanged) retained.push(indexPath);
    for (const directory of directories.reverse()) if (fs.existsSync(directory) && fs.readdirSync(directory).length === 0) fs.rmdirSync(directory);
    throw new Error(`Apply failed; preimages restored where unchanged: ${error.message}; recovery material: ${stage}${retained.length ? `; external changes retained: ${retained.join(', ')}` : ''}`);
  } finally { fs.closeSync(lock); fs.unlinkSync(lockFile); }
  // 仅精确回收本次创建且成功后不再需要的暂存文件，不递归操作任何用户目录。
  for (const item of records) for (const file of [item.backup, item.prepared]) if (fs.existsSync(file)) fs.unlinkSync(file);
  fs.rmdirSync(stage);
}
