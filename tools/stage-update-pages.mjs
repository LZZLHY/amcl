#!/usr/bin/env node
/**
 * Pages 的唯一验证/暂存入口。先审核整个 feed 集合，再新建明确输出目录；相同函数用于
 * GitHub workflow 和宿主反例，避免测试只覆盖导出脚本而漏掉部署前的实际断言。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateUpdateFeeds } from './validate-update-feeds.mjs';

/** 仅复制实际普通文件和目录，不跟随链接或特殊设备；源文件本身不会被重写。 */
function copyTree(source, target) {
  const stat = fs.lstatSync(source);
  if (stat.isSymbolicLink()) throw new Error('Pages source must not contain links');
  if (stat.isDirectory()) {
    fs.mkdirSync(target);
    for (const name of fs.readdirSync(source)) copyTree(path.join(source, name), path.join(target, name));
  } else if (stat.isFile()) fs.copyFileSync(source, target, fs.constants.COPYFILE_EXCL);
  else throw new Error('Pages source contains a special file');
}

/** 输出必须全新且不等于输入/输入祖先，失败现场保留供调用方核查，绝不递归清共享目录。 */
export function stageUpdatePages(root, output) {
  root = fs.realpathSync(root); output = path.resolve(output);
  if (root === output || root.startsWith(output + path.sep)) throw new Error('Pages output cannot replace source');
  if (fs.existsSync(output)) throw new Error('Pages output must not already exist');
  const report = validateUpdateFeeds(root);
  fs.mkdirSync(output);
  for (const file of ['update.json', 'changelog.json', 'updates', 'assets']) {
    if (fs.existsSync(path.join(root, file))) copyTree(path.join(root, file), path.join(output, file));
  }
  for (const [file, url, title] of [['index.html', 'https://amcl.lovedhy.cn/', 'AMCL'],
    ['privacy-policy.html', 'https://amcl.lovedhy.cn/privacy-policy.html', 'AMCL 隐私政策']]) {
    fs.writeFileSync(path.join(output, file), `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=${url}"><title>${title}</title><a href="${url}">${title}</a></html>\n`, { flag: 'wx' });
  }
  return { ...report, staged: output };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  try {
    const args = process.argv.slice(2);
    if (args.length !== 4 || args[0] !== '--root' || args[2] !== '--out') throw new Error('Usage: node tools/stage-update-pages.mjs --root <repository> --out <new-directory>');
    console.log(JSON.stringify(stageUpdatePages(args[1], args[3])));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
