import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import compiler from './ets-compiler.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export function makePureEtsLoader(dependencies = {}) {
  const cache = new Map();
  const load = (relativePath) => {
    const absolutePath = path.resolve(root, relativePath);
    if (cache.has(absolutePath)) return cache.get(absolutePath);
    const source = fs.readFileSync(absolutePath, 'utf8');
    const js = compiler.transpileModule(source, { fileName: absolutePath,
      compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 } }).outputText;
    const module = { exports: {} };
    cache.set(absolutePath, module.exports);
    const localRequire = (name) => {
      if (Object.hasOwn(dependencies, name)) return dependencies[name];
      if (!name.startsWith('./')) throw new Error('Unexpected pure-module dependency: ' + name);
      return load(path.relative(root, path.resolve(path.dirname(absolutePath), name + (name.endsWith('.ets') ? '' : '.ets'))));
    };
    new Function('require', 'module', 'exports', js)(localRequire, module, module.exports);
    cache.set(absolutePath, module.exports);
    return module.exports;
  };
  return load;
}
