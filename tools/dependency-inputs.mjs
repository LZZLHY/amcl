#!/usr/bin/env node
/**
 * 汇总公开版本的第三方输入身份，不下载依赖、不执行配方，也不修改任何锁文件。
 *
 * 发行导出器把冻结提交中的文件以 Map 传入纯函数；CLI 只读取公开工作树中
 * Git 已跟踪的输入。报告是既有锁文件的派生视图，不是另一套可手改的版本源。
 * 源码 pin、所下载制品的摘要、构建配方存在与实际重建验证是独立事实；本工具
 * 只报告前三者能从输入材料证明的部分，始终不授予 HAP、设备或字节复现资格。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const COMMIT = /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/i;
const SHA256 = /^[a-f0-9]{64}$/i;

/** 固定键序及数组排序由调用方决定；这里递归排序对象键，避免输入 Map 顺序影响报告。 */
function ordered(value) {
  if (Array.isArray(value)) return value.map(ordered);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, ordered(value[key])]));
  }
  return value;
}

/** 元数据统一按 LF 计算摘要，明确区别于补丁、二进制制品各自声明的原字节摘要。 */
function authority(relative, bytes) {
  const content = Buffer.from(bytes.toString('utf8').replace(/\r\n/g, '\n'));
  return { path: relative, sha256: createHash('sha256').update(content).digest('hex'), normalization: 'lf' };
}

/** 只接受应用内的普通相对路径，阻止补丁 series 用绝对路径或上跳引用应用外文件。 */
function relativePath(value) {
  if (typeof value !== 'string' || !value || value.includes('\\') || value.includes('\0')
      || path.posix.isAbsolute(value) || /^[A-Za-z]:/.test(value)
      || value.split('/').some(part => !part || part === '.' || part === '..')) {
    throw new Error(`Invalid application-relative dependency path: ${value}`);
  }
  return value;
}

/** Windows 路径比较忽略大小写；其余宿主保留原生大小写语义，判断根自身也算在范围内。 */
function within(candidate, root) {
  const normalize = value => process.platform === 'win32' ? value.toLowerCase() : value;
  const target = normalize(candidate), base = normalize(root);
  return target === base || target.startsWith(base + path.sep);
}

/** 去掉引号外的行注释，保留 URL 片段和带 # 的合法字符串；不解析或运行任意表达式。 */
function uncomment(line) {
  let quote = '', escaped = false;
  for (let index = 0; index < line.length; index++) {
    const character = line[index];
    if (quote) {
      if (escaped) escaped = false;
      else if (character === '\\' && quote === '"') escaped = true;
      else if (character === quote) quote = '';
    } else if (character === '"' || character === "'") quote = character;
    else if (character === '#') return line.slice(0, index).trim();
  }
  return line.trim();
}

/** deps.lock 和 .gitmodules 的受限 INI 读取器；重复 section/字段直接失败，避免覆盖后丢身份。 */
function parseSections(text, label) {
  const sections = new Map();
  let current;
  for (const raw of text.replace(/^\uFEFF/, '').split(/\r?\n/)) {
    const line = uncomment(raw);
    if (!line) continue;
    const header = line.match(/^\[([^\]]+)\]$/);
    if (header) {
      if (sections.has(header[1])) throw new Error(`Duplicate section in ${label}: ${header[1]}`);
      current = {};
      sections.set(header[1], current);
      continue;
    }
    const field = line.match(/^([\w.-]+)\s*=\s*(.*)$/);
    if (!current || !field) throw new Error(`Unsupported dependency metadata syntax in ${label}`);
    if (Object.hasOwn(current, field[1])) throw new Error(`Duplicate field in ${label}: ${field[1]}`);
    const value = field[2];
    current[field[1]] = value.startsWith('"') ? JSON.parse(value)
      : value.startsWith("'") && value.endsWith("'") ? value.slice(1, -1) : value;
  }
  return sections;
}

/**
 * 读取仓内实际使用的 JSONC：双引号 JSON、注释和尾逗号。刻意不用 eval/Function，
 * 所以传入类似 (() => ...) 的配置文本只能解析失败，不可能执行文件里的代码。
 */
function parseJsonMetadata(text, label) {
  let stripped = '', quoted = false, escaped = false;
  const input = text.replace(/^\uFEFF/, '');
  for (let index = 0; index < input.length; index++) {
    const character = input[index], next = input[index + 1];
    if (quoted) {
      stripped += character;
      if (escaped) escaped = false;
      else if (character === '\\') escaped = true;
      else if (character === '"') quoted = false;
    } else if (character === '"') { quoted = true; stripped += character; }
    else if (character === '/' && next === '/') {
      while (index < input.length && input[index] !== '\n') index++;
      stripped += '\n';
    } else if (character === '/' && next === '*') {
      index += 2;
      while (index < input.length && !(input[index] === '*' && input[index + 1] === '/')) index++;
      if (index >= input.length) throw new Error(`Unterminated metadata comment: ${label}`);
      index++;
      stripped += ' ';
    } else stripped += character;
  }
  let normalized = '';
  quoted = false; escaped = false;
  for (let index = 0; index < stripped.length; index++) {
    const character = stripped[index];
    if (quoted) {
      normalized += character;
      if (escaped) escaped = false;
      else if (character === '\\') escaped = true;
      else if (character === '"') quoted = false;
    } else if (character === '"') { quoted = true; normalized += character; }
    else if (character === ',' && /^[\s]*[}\]]/.test(stripped.slice(index + 1))) continue;
    else normalized += character;
  }
  try { return JSON.parse(normalized); }
  catch (error) { throw new Error(`Invalid JSON metadata ${label}: ${error.message}`); }
}

/** 从 Cargo.lock 的 package 表读取声明身份；依赖数组不执行，也不推断本地 crate 的源码来源。 */
function cargoPackages(text, label) {
  const packages = [];
  let current = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = uncomment(raw);
    if (line === '[[package]]') { current = {}; packages.push(current); continue; }
    if (line.startsWith('[') && !line.startsWith('[[package]]')) { current = null; continue; }
    const field = line.match(/^(name|version|source|checksum)\s*=\s*(".*")$/);
    if (current && field) {
      if (Object.hasOwn(current, field[1])) throw new Error(`Duplicate Cargo package field in ${label}: ${field[1]}`);
      current[field[1]] = JSON.parse(field[2]);
    }
  }
  for (const item of packages) {
    if (!item.name || !item.version) throw new Error(`Incomplete Cargo package in ${label}`);
    item.identity = item.source?.startsWith('registry+') && SHA256.test(item.checksum ?? '') ? 'registry-checksum'
      : item.source?.startsWith('git+') && COMMIT.test(item.source.split('#').at(-1)) ? 'git-commit'
        : item.source ? 'unresolved' : 'workspace-or-path';
  }
  return packages.sort((a, b) => `${a.name}\0${a.version}\0${a.source ?? ''}`.localeCompare(`${b.name}\0${b.version}\0${b.source ?? ''}`, 'en'));
}

/** 选择与下载/源码身份有关的公开声明，省略历史证据路径、每个 ELF section 等冗长内部细节。 */
function identityFields(record) {
  if (!record || typeof record !== 'object' || Array.isArray(record)) return {};
  return Object.fromEntries(Object.entries(record).filter(([key, value]) =>
    /^(?:name|file|filename|url|repo|repository|upstream|source|commit|revision|tag|version|asset|sha256|sha1|checksum|integrity|size|bytes|license|artifactSha256|artifactSize|protocol|javaVersionSource)$/.test(key)
    && (value === null || ['string', 'number', 'boolean'].includes(typeof value))));
}

/** CLI 只读这些受管元数据和补丁；不遍历已初始化的巨大第三方工作树或读取私有配置。 */
export function isDependencyMetadata(relative) {
  return ['deps.lock', '.gitmodules', 'toolchain.lock'].includes(relative)
    || /(?:^|\/)(?:Cargo\.lock|oh-package-lock\.json5)$/.test(relative)
    || /^(?:prebuilt|scripts\/lwjgl-stack-backfill)\/.*\/(?:pin|sources|manifest|build-inputs|source-provenance|(?:[^/]+-)?build-provenance)\.json$/.test(relative)
    || /^prebuilt\/.*\/patches\/series$/.test(relative)
    || /^prebuilt\/.*\.patch$/.test(relative);
}

/**
 * 从调用方提供的冻结内容生成稳定报告。函数不读磁盘、不运行 Git、不联网，也不改 files。
 * files 必须包含所列补丁原件；缺件记录为 limitation，不能把“存在 series”误称为补丁齐全。
 * dependencyWorktrees 沿用旧 SOURCE_SNAPSHOT 的结构，因此旧快照没有新汇总文件时仍可读取。
 */
export function collectDependencyInputs({ files, dependencyWorktrees = [], sourceCommit = null }) {
  if (!(files instanceof Map)) throw new TypeError('files must be Map<application-relative path, Buffer>');
  if (sourceCommit !== null && !COMMIT.test(sourceCommit)) throw new Error('sourceCommit must be a complete immutable commit');
  for (const [relative, bytes] of files) {
    relativePath(relative);
    if (!Buffer.isBuffer(bytes)) throw new TypeError(`Dependency input must be a Buffer: ${relative}`);
  }
  const components = [], limitations = [];
  const warn = (component, code, message) => limitations.push({ component, code, message });
  const getJson = relative => parseJsonMetadata(files.get(relative).toString('utf8'), relative);
  const locks = files.has('deps.lock') ? parseSections(files.get('deps.lock').toString('utf8'), 'deps.lock') : new Map();
  if (!files.has('deps.lock')) warn('deps.lock', 'missing-authority', '输入中未提供 deps.lock，不能推断其组件身份。');

  // 保留每个 section 的公开锁定声明，以权威路径和字段名定位，不重造另一套可编辑版本号。
  for (const [name, fields] of [...locks].sort(([a], [b]) => a.localeCompare(b, 'en'))) {
    const declared = Object.fromEntries(Object.entries(fields).filter(([key]) =>
      /(?:^|_)(?:repo|upstream|source|url|commit|revision|tag|version|sha256|sha1|size|bytes|manifest|asset|branch)$/.test(key)
      || ['maven_base', 'modules'].includes(key)));
    const id = `deps-lock:${name}`;
    for (const [field, value] of Object.entries(declared)) {
      if (/\b(?:PENDING|UNKNOWN|TBD)\b/i.test(value)
          || /sha256$/.test(field) && !SHA256.test(value)
          || /(?:^|_)commit$/.test(field) && !COMMIT.test(value)) {
        warn(id, 'unresolved-declaration', `deps.lock [${name}].${field} 尚不能作为已核验的不可变身份。`);
      }
    }
    components.push({ id, kind: 'dependency-lock-section', authority: { ...authority('deps.lock', files.get('deps.lock')), section: name }, declared,
      sourceIdentity: COMMIT.test(fields.commit ?? '') ? 'commit-declared' : 'not-proven',
      rebuildValidation: 'not-performed-by-this-tool' });
  }

  const modules = new Map();
  if (files.has('.gitmodules')) {
    for (const fields of parseSections(files.get('.gitmodules').toString('utf8'), '.gitmodules').values()) {
      if (fields.path) modules.set(fields.path.replace(/^MyApplication\//, ''), fields);
    }
  }
  const seenLinks = new Set();
  for (const dependency of [...dependencyWorktrees].sort((a, b) => String(a.path).localeCompare(String(b.path), 'en'))) {
    const relative = relativePath(dependency.path), id = `gitlink:${relative}`;
    if (seenLinks.has(relative)) throw new Error(`Duplicate dependency gitlink: ${relative}`);
    seenLinks.add(relative);
    const match = [...locks.entries()].find(([, fields]) => fields.commit === dependency.baseCommit);
    const repository = modules.get(relative)?.url || match?.[1]?.repo || match?.[1]?.upstream || null;
    if (!repository) warn(id, 'missing-source-url', 'gitlink 未附可用源码地址；必须补充公开 .gitmodules 或相应锁字段。');
    if (!COMMIT.test(dependency.baseCommit ?? '')) warn(id, 'unresolved-source-pin', 'gitlink 缺少完整不可变提交。');
    if (dependency.dirty) warn(id, 'dirty-dependency', '该快照记录了第三方工作树改动，源码范围须连同补丁核对。');
    const localPatch = dependency.patch ? relativePath(dependency.patch) : null;
    const patchBytes = localPatch && files.get(localPatch);
    const patchSha256 = patchBytes ? createHash('sha256').update(patchBytes).digest('hex') : null;
    if (localPatch && (!patchBytes || patchSha256 !== dependency.patchSha256)) {
      warn(id, 'missing-or-drifted-patch', '快照声明的第三方本地补丁缺失或原字节摘要不符。');
    }
    components.push({ id, kind: 'gitlink', path: relative, source: { repository, commit: dependency.baseCommit ?? null },
      authority: { path: 'SOURCE_SNAPSHOT.json', field: 'dependencyWorktrees' },
      lockSection: match?.[0] ?? null, localPatch: localPatch ? { path: localPatch, sha256: patchSha256, declaredSha256: dependency.patchSha256 ?? null } : null,
      remoteAvailability: 'not-checked', rebuildValidation: 'not-performed-by-this-tool' });
  }

  const runtimePath = 'prebuilt/jdk/build-inputs.json';
  if (files.has(runtimePath)) {
    const runtimeInputs = getJson(runtimePath);
    if (!runtimeInputs.runtimes || typeof runtimeInputs.runtimes !== 'object' || Array.isArray(runtimeInputs.runtimes)) {
      throw new Error(`Invalid runtimes object in ${runtimePath}`);
    }
    for (const [major, runtime] of Object.entries(runtimeInputs.runtimes).sort(([a], [b]) => Number(a) - Number(b))) {
      const id = `jdk:${major}`;
      if (!COMMIT.test(runtime.commit ?? '')) warn(id, 'unresolved-source-pin', '新 JDK 构建输入未锁定完整源码提交。');
      components.push({ id, kind: 'jdk-build-input', authority: authority(runtimePath, files.get(runtimePath)),
        source: { repository: runtime.repository ?? null, commit: runtime.commit ?? null },
        bootJdk: runtime.bootJdk ? identityFields(runtime.bootJdk) : null,
        freetype: runtime.freetype ? identityFields(runtime.freetype) : null,
        scope: 'new-runtime-build-input-only', historicalReleaseMapping: 'not-proven-by-build-pin',
        rebuildValidation: 'not-performed-by-this-tool' });
    }
  } else warn('jdk', 'missing-build-inputs', '此输入未附新 JDK 构建锁；不能据旧 tag 推断完整源码。');

  for (const relative of [...files.keys()].sort()) {
    const bytes = files.get(relative), id = `metadata:${relative}`;
    if (/^prebuilt\/.*\/patches\/series$/.test(relative)) {
      const steps = [];
      for (const raw of bytes.toString('utf8').split(/\r?\n/)) {
        const entry = uncomment(raw);
        if (!entry) continue;
        relativePath(entry);
        const patchPath = relativePath(path.posix.join(path.posix.dirname(relative), entry));
        const patchBytes = files.get(patchPath);
        if (!patchBytes) warn(id, 'missing-patch', `补丁顺序中缺少输入：${patchPath}`);
        steps.push({ order: steps.length + 1, path: patchPath,
          sha256: patchBytes ? createHash('sha256').update(patchBytes).digest('hex') : null, normalization: 'none' });
      }
      components.push({ id, kind: 'patch-series', authority: authority(relative, bytes), steps, applicationValidation: 'not-performed-by-this-tool' });
    } else if (/(?:^|\/)Cargo\.lock$/.test(relative)) {
      const packages = cargoPackages(bytes.toString('utf8'), relative);
      for (const item of packages) if (item.identity === 'unresolved') warn(id, 'unresolved-cargo-package', `Cargo 包 ${item.name}@${item.version} 未附可确认的 registry checksum 或 Git commit。`);
      components.push({ id, kind: 'cargo-lock', authority: authority(relative, bytes), packages });
    } else if (/(?:^|\/)oh-package-lock\.json5$/.test(relative)) {
      const data = getJson(relative);
      const packages = Object.entries(data.packages ?? {}).sort(([a], [b]) => a.localeCompare(b, 'en')).map(([key, item]) => ({ key, ...identityFields(item), resolved: item.resolved ?? null }));
      for (const item of packages) if (item.resolved?.startsWith('http') && !/^sha(?:256|512)-/.test(item.integrity ?? '')) warn(id, 'missing-package-integrity', `OHPM 包 ${item.key} 缺少完整性摘要。`);
      components.push({ id, kind: 'ohpm-lock', authority: authority(relative, bytes), lockfileVersion: data.lockfileVersion ?? null, packages });
    } else if (relative === 'toolchain.lock') {
      const data = getJson(relative);
      components.push({ id, kind: 'toolchain-lock', authority: authority(relative, bytes), schemaVersion: data.schemaVersion ?? null,
        products: data.products ?? {}, validation: 'declarations-only-no-tool-execution' });
    } else if (/^(?:prebuilt|scripts\/lwjgl-stack-backfill)\/.*\/(?:pin|sources|manifest|source-provenance|(?:[^/]+-)?build-provenance)\.json$/.test(relative)) {
      const data = getJson(relative);
      const declaredFiles = Array.isArray(data.files) ? data.files.map(identityFields) : [];
      const slots = Array.isArray(data.slots) ? data.slots.map(slot => ({ ...identityFields(slot), upstream: identityFields(slot.upstream) })) : [];
      components.push({ id, kind: 'declared-artifact-metadata', authority: authority(relative, bytes),
        declarations: identityFields(data), source: identityFields(data.source), files: declaredFiles, slots,
        validation: 'declarations-only-no-artifact-rebuild' });
      if (relative === 'prebuilt/jdk/source-provenance.json') {
        warn(id, 'historical-runtime-boundary', '旧 JDK 包存在独立来源记录；新 build-inputs 的 pin 不补证历史混合发行包的完整重建来源。');
      }
    }
  }
  if (sourceCommit === null) warn('snapshot', 'missing-source-commit', '旧快照未提供完整 sourceCommit，汇总不自行猜测私有来源。');
  return ordered({ schemaVersion: 1, sourceCommit, scope: 'declared-public-dependency-inputs',
    qualification: { sourcePins: 'reported-when-declared', publicDownloadAvailability: 'not-checked',
      applicationBuild: 'not-performed', allThirdPartySourceRebuild: 'not-performed', officialBinaryReproduction: 'not-performed' },
    components: components.sort((a, b) => a.id.localeCompare(b.id, 'en')),
    limitations: limitations.sort((a, b) => `${a.component}\0${a.code}\0${a.message}`.localeCompare(`${b.component}\0${b.code}\0${b.message}`, 'en')) });
}

/** CLI 参数只确定读取根和显式输出，未知选项立即失败，防止拼错后写入默认位置。 */
function parseArgs(args) {
  const options = { root: path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../MyApplication') };
  for (let index = 0; index < args.length; index++) {
    const flag = args[index];
    if (['--json', '--check', '--help'].includes(flag)) options[flag.slice(2)] = true;
    else if (['--root', '--out'].includes(flag) && args[index + 1] && !args[index + 1].startsWith('--')) options[flag.slice(2)] = args[++index];
    else throw new Error(`Unknown or incomplete option: ${flag}`);
  }
  return options;
}

/**
 * 只遍历 Git 索引给出的应用路径；不跟随 symlink/junction，也不扫描依赖工作树。
 * 公共仓根 .gitmodules 比旧 MyApplication/.gitmodules 完整，读取时作为同一逻辑输入。
 */
function readPublicInputs(root) {
  const files = new Map();
  const listed = execFileSync('git', ['-C', root, 'ls-files', '-z'], { encoding: 'utf8' }).split('\0').filter(Boolean);
  for (const relative of listed.filter(isDependencyMetadata)) {
    relativePath(relative);
    const filename = path.join(root, relative);
    if (!fs.existsSync(filename)) continue;
    const stat = fs.lstatSync(filename);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`Dependency metadata must be a regular tracked file: ${relative}`);
    const real = fs.realpathSync(filename), base = fs.realpathSync(root);
    if (!within(real, base)) throw new Error(`Dependency metadata escapes root: ${relative}`);
    files.set(relative, fs.readFileSync(filename));
  }
  const repository = execFileSync('git', ['-C', root, 'rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
  const modules = path.join(repository, '.gitmodules');
  if (fs.existsSync(modules)) {
    const stat = fs.lstatSync(modules);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('Repository .gitmodules must be a regular file');
    files.set('.gitmodules', fs.readFileSync(modules));
  }
  const snapshotFile = path.join(root, 'SOURCE_SNAPSHOT.json');
  if (fs.existsSync(snapshotFile) && (!fs.lstatSync(snapshotFile).isFile() || fs.lstatSync(snapshotFile).isSymbolicLink())) {
    throw new Error('SOURCE_SNAPSHOT.json must be a regular file');
  }
  const snapshot = fs.existsSync(snapshotFile) ? parseJsonMetadata(fs.readFileSync(snapshotFile, 'utf8'), 'SOURCE_SNAPSHOT.json') : {};
  return { files, dependencyWorktrees: snapshot.dependencyWorktrees ?? [], sourceCommit: snapshot.sourceCommit ?? null, repository };
}

/** 只有显式 --out 才落盘，拒绝向源码仓内部生成报告；--check 对旧快照缺报告兼容。 */
function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    console.log('Usage: node tools/dependency-inputs.mjs [--root <MyApplication>] [--json] [--out <absolute-external-file>] [--check]');
    return;
  }
  const root = fs.realpathSync(options.root);
  const { repository, ...inputs } = readPublicInputs(root);
  const report = collectDependencyInputs(inputs);
  let check = 'not-requested';
  if (options.check) {
    const recorded = path.join(root, 'DEPENDENCY_INPUTS.json');
    if (!fs.existsSync(recorded)) check = 'legacy-report-absent';
    else {
      const expected = ordered(parseJsonMetadata(fs.readFileSync(recorded, 'utf8'), 'DEPENDENCY_INPUTS.json'));
      check = JSON.stringify(report) === JSON.stringify(expected) ? 'match' : 'drift';
      if (check === 'drift') process.exitCode = 1;
    }
  }
  if (options.out) {
    if (!path.isAbsolute(options.out)) throw new Error('--out must name an absolute external file');
    const output = path.resolve(options.out), repositoryRoot = fs.realpathSync(repository);
    if (within(output, repositoryRoot)) throw new Error('--out must stay outside the source repository');
    // 先解析最近存在的父目录，再创建输出目录，阻止外置 junction/symlink 把写入回流源码仓。
    let ancestor = path.dirname(output);
    while (!fs.existsSync(ancestor)) {
      const next = path.dirname(ancestor);
      if (next === ancestor) throw new Error('Cannot resolve output parent');
      ancestor = next;
    }
    if (within(fs.realpathSync(ancestor), repositoryRoot)) throw new Error('--out resolves inside the source repository');
    fs.mkdirSync(path.dirname(output), { recursive: true });
    if (fs.existsSync(output) && fs.lstatSync(output).isSymbolicLink()) throw new Error('Refusing symlink output');
    fs.writeFileSync(output, JSON.stringify(report, null, 2) + '\n');
  }
  if (options.json) console.log(JSON.stringify(options.check ? { check, report } : report, null, 2));
  else console.log(`Dependency inputs: ${report.components.length} components, ${report.limitations.length} limitations; check=${check}. No build, download, or reproduction verification performed.`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try { main(); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
