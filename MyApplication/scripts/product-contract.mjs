import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const PRODUCT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export function readProductRegistry(root = PRODUCT_ROOT) {
  return JSON.parse(readFileSync(resolve(root, 'config/products.json'), 'utf8'));
}
export function productDefinition(name, registry = readProductRegistry()) {
  const product = registry.products[name];
  if (!product || !registry.families[product.family]) throw new Error(`Unknown product: ${name}`);
  const definition = { ...registry.families[product.family], ...product, name };
  definition.distributionDevices ??= definition.deviceTypes;
  return definition;
}
export function productMetadataSource(name, registry = readProductRegistry()) {
  const p = productDefinition(name, registry);
  return `// Generated from config/products.json by scripts/sync-product-profiles.mjs.\n` +
    `export class ProductBuildProfile {\n` +
    `  static readonly product: string = '${name}'\n` +
    `  static readonly family: string = '${p.family}'\n` +
    `  static readonly storeChannel: boolean = ${p.channel === 'store'}\n` +
    `  static readonly publishable: boolean = ${p.publishable}\n` +
    `  static readonly developerDiagnostics: boolean = ${p.developerDiagnostics}\n` +
    `  static readonly touchControls: boolean = ${p.touchControls}\n` +
    `  static readonly runtimeRawMouse: boolean = ${p.runtimeRawMouse}\n` +
    `}\n`;
}
export function assertPublishable(name) {
  const product = productDefinition(name);
  if (!product.publishable) throw new Error(`Product ${name} is development/compatibility-only and cannot be published`);
  return product;
}

/**
 * 解析本仓配置使用的 JSON5 子集：双引号键/值、行/块注释、尾逗号和可选 BOM。
 * 两次线性扫描都跟踪字符串及转义，避免 URL、签名占位符或普通文本中的
 * 注释符号、逗号和括号被正则误删。不执行表达式；其它语法继续由 JSON.parse 拒绝。
 */
export function parseJson5(text) {
  let result = '', quote = '', escaped = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i], next = text[i + 1];
    if (i === 0 && c === '\uFEFF') continue;
    if (quote) {
      result += c;
      if (escaped) escaped = false;
      else if (c === '\\') escaped = true;
      else if (c === quote) quote = '';
    } else if (c === '"') { quote = c; result += c; }
    else if (c === '/' && next === '/') {
      while (i < text.length && text[i] !== '\n') i++;
      result += '\n';
    } else if (c === '/' && next === '*') {
      i += 2;
      while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) i++;
      if (i >= text.length) throw new SyntaxError('Unterminated JSON5 block comment');
      i++;
      result += ' ';
    } else result += c;
  }
  let normalized = '';
  quote = ''; escaped = false;
  for (let i = 0; i < result.length; i++) {
    const c = result[i];
    if (quote) {
      normalized += c;
      if (escaped) escaped = false;
      else if (c === '\\') escaped = true;
      else if (c === quote) quote = '';
      continue;
    }
    if (c === '"') { quote = c; normalized += c; continue; }
    if (c === ',') {
      let next = i + 1;
      while (next < result.length && /\s/.test(result[next])) next++;
      if (result[next] === '}' || result[next] === ']') continue;
    }
    normalized += c;
  }
  return JSON.parse(normalized);
}
