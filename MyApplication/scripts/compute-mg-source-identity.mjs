#!/usr/bin/env node
// Deterministic MobileGlues source/build identity.
//
// The identity deliberately includes dirty tracked bytes, untracked file bytes,
// recursive submodule state/content, and the MG-affecting CMake option set. It
// is used both by CMake (generated header embedded in libglfw.so) and by the HAP
// provenance audit, so two different dirty trees can never claim the same MG
// build identity merely because they share a HEAD commit.

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readlinkSync,
  writeFileSync,
} from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

export const MG_SOURCE_IDENTITY_SCHEMA = 1;
const MAX_GIT_OUTPUT = 256 * 1024 * 1024;
const SHA1 = /^[0-9a-f]{40}$/;
const OPTION_NAME = /^[A-Za-z0-9_.-]+$/;

function runGit(repo, args, encoding = null) {
  return execFileSync('git', ['-c', 'core.quotepath=false', ...args], {
    cwd: repo,
    encoding,
    maxBuffer: MAX_GIT_OUTPUT,
    stdio: ['ignore', 'pipe', 'pipe'],
    windowsHide: true,
  });
}

function frame(hash, label, value) {
  const bytes = Buffer.isBuffer(value) ? value : Buffer.from(String(value), 'utf8');
  const length = Buffer.allocUnsafe(8);
  length.writeBigUInt64BE(BigInt(bytes.length));
  hash.update(Buffer.from(label, 'utf8'));
  hash.update(Buffer.from([0]));
  hash.update(length);
  hash.update(bytes);
}

function parseNullPaths(bytes) {
  if (bytes.length === 0) return [];
  const paths = bytes.toString('utf8').split('\0');
  if (paths.at(-1) === '') paths.pop();
  return paths.sort((left, right) =>
    Buffer.compare(Buffer.from(left, 'utf8'), Buffer.from(right, 'utf8')));
}

function containedPath(repo, gitPath) {
  const path = resolve(repo, gitPath);
  const rel = relative(repo, path);
  if (rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    throw new Error(`Git path escapes repository: ${gitPath}`);
  }
  return path;
}

function fileBytes(path) {
  const stat = lstatSync(path);
  if (stat.isSymbolicLink()) return Buffer.from(readlinkSync(path), 'utf8');
  if (!stat.isFile()) throw new Error(`Untracked Git path is not a file: ${path}`);
  return readFileSync(path);
}

function appendRepositoryContent(hash, repo, identityPath) {
  const head = String(runGit(repo, ['rev-parse', '--verify', 'HEAD'], 'utf8')).trim();
  if (!SHA1.test(head)) throw new Error(`Cannot identify Git HEAD for ${repo}: ${head}`);

  const status = String(runGit(
    repo,
    ['status', '--porcelain=v1', '--untracked-files=all', '--ignore-submodules=none'],
    'utf8',
  )).replace(/\r\n/g, '\n');
  const diff = runGit(
    repo,
    ['diff', '--binary', '--no-ext-diff', '--no-color', 'HEAD', '--', '.'],
  );
  const untracked = parseNullPaths(runGit(
    repo,
    ['ls-files', '--others', '--exclude-standard', '-z', '--', '.'],
  ));

  frame(hash, `${identityPath}:head`, head);
  frame(hash, `${identityPath}:status`, status);
  frame(hash, `${identityPath}:diff`, diff);
  for (const gitPath of untracked) {
    const bytes = fileBytes(containedPath(repo, gitPath));
    frame(hash, `${identityPath}:untracked-path`, gitPath.replaceAll('\\', '/'));
    frame(hash, `${identityPath}:untracked-bytes`, bytes);
  }

  return {
    head,
    dirty: status.trim().length !== 0,
    status,
    untrackedFiles: untracked.length,
  };
}

function normalizeOptions(options) {
  const entries = options instanceof Map
    ? [...options.entries()]
    : Object.entries(options ?? {});
  const seen = new Set();
  const normalized = entries.map(([rawName, rawValue]) => {
    const name = String(rawName);
    if (!OPTION_NAME.test(name)) throw new Error(`Invalid build option name: ${name}`);
    if (seen.has(name)) throw new Error(`Duplicate build option: ${name}`);
    seen.add(name);
    return [name, String(rawValue)];
  });
  normalized.sort(([left], [right]) =>
    Buffer.compare(Buffer.from(left, 'utf8'), Buffer.from(right, 'utf8')));
  return normalized;
}

function parseRecursiveSubmodules(repo) {
  const output = String(runGit(repo, ['submodule', 'status', '--recursive'], 'utf8'))
    .replace(/\r\n/g, '\n');
  const modules = [];
  for (const line of output.split('\n').filter(Boolean)) {
    const match = line.match(/^(.)([0-9a-f]{40})\s+(.+?)(?:\s+\(.*\))?$/);
    if (!match) throw new Error(`Cannot parse recursive submodule status: ${line}`);
    modules.push({ marker: match[1], commit: match[2], path: match[3] });
  }
  modules.sort((left, right) =>
    Buffer.compare(Buffer.from(left.path, 'utf8'), Buffer.from(right.path, 'utf8')));
  return { output, modules };
}

export function computeMgSourceIdentity({ repo, options = {} }) {
  if (!repo) throw new Error('MobileGlues repository path is required');
  const repository = resolve(repo);
  const topLevel = resolve(String(runGit(
    repository,
    ['rev-parse', '--show-toplevel'],
    'utf8',
  )).trim());
  if (process.platform === 'win32'
    ? topLevel.toLowerCase() !== repository.toLowerCase()
    : topLevel !== repository) {
    throw new Error(`Expected repository root ${repository}, Git reports ${topLevel}`);
  }

  const sourceHash = createHash('sha256');
  frame(sourceHash, 'schema', MG_SOURCE_IDENTITY_SCHEMA);
  const rootContent = appendRepositoryContent(sourceHash, repository, '.');

  const recursive = parseRecursiveSubmodules(repository);
  frame(sourceHash, 'recursive-submodule-status', recursive.output);
  let nestedDirty = false;
  let nestedUntrackedFiles = 0;
  for (const module of recursive.modules) {
    frame(sourceHash, 'submodule-path', module.path);
    frame(sourceHash, 'submodule-marker', module.marker);
    frame(sourceHash, 'submodule-recorded-commit', module.commit);
    if (module.marker === '-') continue;
    const nestedRepo = containedPath(repository, module.path);
    if (!existsSync(join(nestedRepo, '.git'))) {
      throw new Error(`Initialized submodule has no Git metadata: ${module.path}`);
    }
    const nested = appendRepositoryContent(sourceHash, nestedRepo, `submodule:${module.path}`);
    nestedDirty ||= nested.dirty || nested.head !== module.commit || module.marker !== ' ';
    nestedUntrackedFiles += nested.untrackedFiles;
  }

  const normalizedOptions = normalizeOptions(options);
  const optionsHash = createHash('sha256');
  frame(optionsHash, 'schema', MG_SOURCE_IDENTITY_SCHEMA);
  for (const [name, value] of normalizedOptions) frame(optionsHash, name, value);
  const optionsSha256 = optionsHash.digest('hex');
  const worktreeSha256 = sourceHash.digest('hex');
  const worktreeDirty = rootContent.dirty || nestedDirty;
  const buildIdentity = [
    `schema=${MG_SOURCE_IDENTITY_SCHEMA}`,
    `source=${rootContent.head}`,
    `worktree=${worktreeSha256}`,
    `state=${worktreeDirty ? 'dirty' : 'clean'}`,
    `options=${optionsSha256}`,
  ].join(':');

  return {
    schemaVersion: MG_SOURCE_IDENTITY_SCHEMA,
    sourceCommit: rootContent.head,
    worktreeSha256,
    worktreeDirty,
    worktreeState: worktreeDirty ? 'dirty' : 'clean',
    buildOptionsSha256: optionsSha256,
    buildIdentity,
    dirtyStatusSha256: rootContent.dirty
      ? createHash('sha256').update(rootContent.status, 'utf8').digest('hex')
      : null,
    untrackedFileCount: rootContent.untrackedFiles + nestedUntrackedFiles,
    options: Object.fromEntries(normalizedOptions),
  };
}

function cString(value) {
  return String(value).replaceAll('\\', '\\\\').replaceAll('"', '\\"');
}

export function renderMgSourceIdentityHeader(identity) {
  return `// Generated by scripts/compute-mg-source-identity.mjs; do not edit.\n` +
    `#ifndef AMCL_MG_SOURCE_IDENTITY_GENERATED_H\n` +
    `#define AMCL_MG_SOURCE_IDENTITY_GENERATED_H\n\n` +
    `#define AMCL_MG_IDENTITY_SCHEMA ${identity.schemaVersion}\n` +
    `#define AMCL_MG_SOURCE_COMMIT "${cString(identity.sourceCommit)}"\n` +
    `#define AMCL_MG_WORKTREE_SHA256 "${cString(identity.worktreeSha256)}"\n` +
    `#define AMCL_MG_WORKTREE_DIRTY ${identity.worktreeDirty ? 1 : 0}\n` +
    `#define AMCL_MG_BUILD_OPTIONS_SHA256 "${cString(identity.buildOptionsSha256)}"\n` +
    `#define AMCL_MG_BUILD_IDENTITY "${cString(identity.buildIdentity)}"\n\n` +
    `#endif // AMCL_MG_SOURCE_IDENTITY_GENERATED_H\n`;
}

function parseArguments(argv) {
  const result = { options: new Map(), json: false };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--json') {
      result.json = true;
      continue;
    }
    if (argument === '--repo' || argument === '--output' || argument === '--option') {
      if (index + 1 >= argv.length) throw new Error(`Missing value for ${argument}`);
      const value = argv[++index];
      if (argument === '--repo') result.repo = value;
      else if (argument === '--output') result.output = value;
      else {
        const separator = value.indexOf('=');
        if (separator <= 0) throw new Error(`Build option must be NAME=VALUE: ${value}`);
        const name = value.slice(0, separator);
        if (result.options.has(name)) throw new Error(`Duplicate build option: ${name}`);
        result.options.set(name, value.slice(separator + 1));
      }
      continue;
    }
    if (argument === '--help' || argument === '-h') return { help: true };
    throw new Error(`Unknown argument: ${argument}`);
  }
  return result;
}

function usage() {
  console.log('Usage: node scripts/compute-mg-source-identity.mjs --repo <mg-root> [--output <header>] [--option NAME=VALUE]... [--json]');
}

function main() {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (args.help) {
      usage();
      return;
    }
    if (!args.repo) throw new Error('--repo is required');
    const identity = computeMgSourceIdentity({ repo: args.repo, options: args.options });
    if (args.output) {
      const output = resolve(args.output);
      const content = renderMgSourceIdentityHeader(identity);
      mkdirSync(dirname(output), { recursive: true });
      if (!existsSync(output) || readFileSync(output, 'utf8') !== content) {
        writeFileSync(output, content, 'utf8');
      }
    }
    if (args.json) console.log(JSON.stringify(identity, null, 2));
    else console.log(`[compute-mg-source-identity] ${identity.buildIdentity}`);
  } catch (error) {
    console.error(`[compute-mg-source-identity] ERROR: ${error.message}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
