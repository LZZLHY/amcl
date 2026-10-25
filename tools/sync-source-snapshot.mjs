#!/usr/bin/env node
/**
 * 人工发版时导出冻结源码。预览只写显式指定的外部计划，应用时重做全部预检并
 * 比对计划摘要；不提交、不推送、不创建发行，也不推进应用更新通道。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { prepareExport, applyExport, digest } from './lib/source-export.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const usage = `Manual release source export (no commit/push/release):
  node tools/sync-source-snapshot.mjs --source <clean-source> --expected-commit <40-hex> --plan <outside-repositories.json>
  node tools/sync-source-snapshot.mjs --source <same-source> --expected-commit <same-commit> --plan <same-plan.json> --write
  --require-clean is accepted for older callers; a clean source is always required.
  Without --plan, print a read-only plan. --write requires an existing plan.`;
try {
  if (args.includes('--help')) { console.log(usage); process.exit(0); }
  const options = {};
  for (let i = 0; i < args.length; i++) {
    const argument = args[i];
    if (argument === '--write' || argument === '--require-clean') { options[argument] = true; continue; }
    if (!['--source', '--expected-commit', '--plan'].includes(argument) || !args[i + 1] || args[i + 1].startsWith('--')) throw new Error(`Unknown or incomplete argument: ${argument}\n${usage}`);
    if (options[argument]) throw new Error(`Duplicate argument: ${argument}`);
    options[argument] = args[++i];
  }
  if (!options['--source'] || !/^[a-f0-9]{40}$/.test(options['--expected-commit'] ?? '')) throw new Error(usage);
  const source = fs.realpathSync(options['--source']);
  const planFile = options['--plan'] ? path.resolve(options['--plan']) : null;
  // 计划含维护者本机路径和未公开变更摘要，必须留在仓库外，不能误随源码公开。
  if (planFile) {
    let ancestor = path.dirname(planFile);
    while (!fs.existsSync(ancestor)) {
      const parent = path.dirname(ancestor);
      if (parent === ancestor) throw new Error('Cannot resolve plan parent: unavailable filesystem root');
      ancestor = parent;
    }
    const physicalParent = fs.realpathSync(ancestor);
    for (const repository of [source, root]) for (const candidate of [planFile, physicalParent]) {
      const relative = path.relative(repository, candidate);
      if (!relative || (!relative.startsWith('..' + path.sep) && relative !== '..' && !path.isAbsolute(relative))) throw new Error('The plan must be physically outside both source and public repositories');
    }
    if (fs.lstatSync(planFile, { throwIfNoEntry: false })?.isSymbolicLink()) throw new Error('Refusing a linked plan file');
  }
  if (options['--write'] && (!planFile || !fs.existsSync(planFile))) throw new Error('--write requires an existing, reviewed --plan file');
  const prepared = prepareExport({ source, publicRoot: root, expectedCommit: options['--expected-commit'] });
  const plan = { ...prepared.plan, planSha256: digest(Buffer.from(JSON.stringify(prepared.plan))) };
  if (options['--write']) {
    const previous = JSON.parse(fs.readFileSync(planFile, 'utf8').replace(/^\uFEFF/, ''));
    if (JSON.stringify(previous) !== JSON.stringify(plan)) throw new Error('Export plan drift: source, public baseline, policy or inputs changed; generate and review a new plan');
    applyExport(prepared, { stageRoot: path.dirname(planFile) });
    console.log(JSON.stringify({ mode: 'applied', planSha256: plan.planSha256, actions: plan.actions.length, sourceCommit: plan.sourceCommit, version: plan.release,
      note: 'Local candidate only; review, build and commit before any separately authorized publication.' }, null, 2));
  } else {
    if (planFile) {
      fs.mkdirSync(path.dirname(planFile), { recursive: true });
      // 不覆盖旧审阅记录；重新预览使用新文件名，保留失败与更正证据。
      fs.writeFileSync(planFile, JSON.stringify(plan, null, 2) + '\n', { flag: 'wx' });
    }
    console.log(JSON.stringify(plan, null, 2));
  }
} catch (error) { console.error(`Source export rejected: ${error.message}`); process.exitCode = 1; }
