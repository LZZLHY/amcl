import { createRequire } from 'node:module';
/** 宿主回归使用 SDK 编译器或指定的 TypeScript；不会替代正式 ArkTS 编译。 */
const require = createRequire(import.meta.url);
let compiler;
for (const candidate of [process.env.AMCL_ETS_TYPESCRIPT, 'typescript',
  'D:/Huawei/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'].filter(Boolean)) {
  try { compiler = require(candidate); break; } catch (error) { if (error.code !== 'MODULE_NOT_FOUND') throw error; }
}
if (!compiler) throw new Error('Set AMCL_ETS_TYPESCRIPT to the TypeScript compiler used by host evidence tests');

/**
 * 为无 SDK 的 CI 提供页面成员解析。只把行首的 struct 声明关键字等长替换成
 * class，方法正文不变；扫描器排除注释和字符串中的同名文本。ArkUI 布局依然
 * 不在宿主执行，真实布局语义由 SDK/HAP 检查负责。
 */
export function normalizeStructDeclarations(source) {
  const scanner = compiler.createScanner(compiler.ScriptTarget.Latest, false,
    compiler.LanguageVariant.Standard, source);
  const replacements = [];
  let token;
  while ((token = scanner.scan()) !== compiler.SyntaxKind.EndOfFileToken) {
    if (token !== compiler.SyntaxKind.Identifier || scanner.getTokenText() !== 'struct') continue;
    const start = scanner.getTokenPos();
    const lineStart = source.lastIndexOf('\n', start - 1) + 1;
    if (!/^\s*(?:export\s+)?$/.test(source.slice(lineStart, start))) continue;
    if (!/^struct\s+[\p{ID_Start}_$][\p{ID_Continue}$]*\s*\{/u.test(source.slice(start))) continue;
    replacements.push(start);
  }
  let normalized = source;
  for (let i = replacements.length - 1; i >= 0; i--) {
    const start = replacements[i];
    normalized = normalized.slice(0, start) + 'class ' + normalized.slice(start + 6);
  }
  return normalized;
}

const probe = compiler.createSourceFile('Probe.ets', 'struct Probe { method() {} }', compiler.ScriptTarget.Latest, true);
const supportsStruct = probe.statements.some(node => node.members?.some(member => member.name?.getText(probe) === 'method'));
// SDK 保持原 API；通用 TS 只在 .ets 的 AST 读取入口补上声明兼容，不改写 transpileModule。
const hostCompiler = supportsStruct ? compiler : {
  ...compiler,
  createSourceFile(file, source, target, setParentNodes, kind) {
    return compiler.createSourceFile(file, file.endsWith('.ets') ? normalizeStructDeclarations(source) : source,
      target, setParentNodes, kind ?? compiler.ScriptKind.TS);
  },
};
export default hostCompiler;
