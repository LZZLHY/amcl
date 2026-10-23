/**
 * 构建门禁目录的纯读取入口。
 *
 * 本模块只读取并校验静态 catalog，不导入任何检查器、不生成构建输出、不执行子进程。
 * 相同脚本只有一个稳定 ID；一次调用的产品、参数和阶段由实际 runner 事件分别记录，
 * 不能把脚本名相同解释成参数不同的两次检查已经相互覆盖。
 */
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { scanSpans } from './source-noise.mjs';

const DEFAULT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const KINDS = new Set(['fact', 'behavior', 'static', 'artifact', 'prepare']);
const TOOLS = new Set(['node', 'python', 'bash', 'powershell']);

/**
 * 返回目录结构问题，不抛出第一处错误，便于一次报告所有漏项或重复项。
 * 输入只作为值检查，不修改调用方对象；依赖必须指向本目录的真实 ID。
 */
export function gateCatalogIssues(catalog) {
  const issues = [];
  if (!catalog || catalog.schema !== 1 || !Array.isArray(catalog.gates)) {
    return ['catalog 必须为 schema=1 且包含 gates 数组'];
  }
  const ids = new Set();
  const scripts = new Set();
  for (const [index, gate] of catalog.gates.entries()) {
    const label = gate?.id || `gates[${index}]`;
    if (!gate || typeof gate !== 'object') { issues.push(`${label}: 门禁必须为对象`); continue; }
    if (typeof gate.id !== 'string' || !/^[a-z0-9][a-z0-9-]*$/.test(gate.id)) issues.push(`${label}: ID 不合法`);
    if (ids.has(gate.id)) issues.push(`${label}: 重复 ID`);
    ids.add(gate.id);
    if (typeof gate.script !== 'string' || !/^[A-Za-z0-9_./-]+\.(?:mjs|py|sh|ps1)$/.test(gate.script) ||
        gate.script.startsWith('/') || gate.script.split('/').some(part => part === '..' || part === '')) {
      issues.push(`${label}: script 必须是仓库内规范相对路径`);
    }
    if (scripts.has(gate.script)) issues.push(`${label}: 同脚本重复登记`);
    scripts.add(gate.script);
    if (!TOOLS.has(gate.tool)) issues.push(`${label}: 未知 tool`);
    if (!KINDS.has(gate.kind)) issues.push(`${label}: 未知 kind`);
    if (typeof gate.domain !== 'string' || gate.domain.length === 0) issues.push(`${label}: domain 缺失`);
    if (!['always', 'affected', 'defer'].includes(gate.quick)) issues.push(`${label}: 未知 quick 策略`);
    if (!['never', 'pass'].includes(gate.cachePolicy)) issues.push(`${label}: 未知缓存策略`);
    if (!Array.isArray(gate.dependsOn) || !Array.isArray(gate.surfaces) || !gate.surfaces.length) issues.push(`${label}: 依赖或来源面缺失`);
    if (gate.cachePolicy === 'pass' && (gate.kind !== 'static' || gate.deterministic !== true ||
        !Array.isArray(gate.inputs?.files) || !gate.inputs.files.includes(gate.script))) {
      issues.push(`${label}: 成功缓存只允许明确 deterministic 的 static 检查，并须绑定检查器自身`);
    }
    if (['artifact', 'prepare', 'fact'].includes(gate.kind) && (gate.quick !== 'always' || gate.cachePolicy !== 'never')) {
      issues.push(`${label}: 当前事实、产物和生成准备必须 always/never`);
    }
  }
  for (const gate of catalog.gates) {
    for (const dependency of gate?.dependsOn ?? []) {
      if (!ids.has(dependency)) issues.push(`${gate.id}: 依赖不存在 ${dependency}`);
      if (dependency === gate.id) issues.push(`${gate.id}: 不能依赖自身`);
    }
  }
  // 环会使调度器无法取得可执行顺序，目录读取阶段先拒绝，避免运行一半才发现。
  const gatesById = new Map(catalog.gates.filter(Boolean).map(gate => [gate.id, gate]));
  const active = new Set();
  const finished = new Set();
  function visit(id) {
    if (active.has(id)) { issues.push(`${id}: 依赖环`); return; }
    if (finished.has(id) || !gatesById.has(id)) return;
    active.add(id);
    for (const dependency of gatesById.get(id).dependsOn ?? []) visit(dependency);
    active.delete(id); finished.add(id);
  }
  for (const id of ids) visit(id);
  return issues;
}

/** 读取指定仓库或显式内存目录；校验失败时不返回可调度清单。 */
export function readGateCatalog({ root = DEFAULT_ROOT, catalog } = {}) {
  const value = catalog ?? JSON.parse(readFileSync(resolve(root, 'config/build-gates.json'), 'utf8').replace(/^\uFEFF/, ''));
  const issues = gateCatalogIssues(value);
  if (issues.length) throw new Error(`构建门禁目录无效：\n${issues.join('\n')}`);
  return structuredClone(value);
}

/**
 * 向 runner、计划输出和完整性测试提供相同清单。
 * 返回深副本，调用者附加 argv/phase 时不会意外修改另一次调用看到的静态策略。
 */
export function exportGateInventory(options = {}) {
  return readGateCatalog(options).gates;
}

/**
 * 只剥离 PowerShell 行注释与块注释，保留引号内的 # 和原换行。
 * 此扫描仅用于入口的静态 witness/未知脚本预检；不解释 PowerShell 表达式或执行变量。
 */
export function powerShellCode(text) {
  const input = String(text).replace(/^\uFEFF/, '').replace(/\r\n/g, '\n');
  let output = '', quote = null, block = false;
  for (let index = 0; index < input.length; index++) {
    const char = input[index], next = input[index + 1];
    if (block) {
      if (char === '#' && next === '>') { output += '  '; index++; block = false; }
      else output += char === '\n' ? '\n' : ' ';
      continue;
    }
    if (quote) {
      output += char;
      if (quote === '"' && char === '`' && next !== undefined) { output += next; index++; continue; }
      if (char === quote) {
        if (quote === "'" && next === "'") { output += next; index++; }
        else quote = null;
      }
      continue;
    }
    if (char === '<' && next === '#') { output += '  '; index++; block = true; continue; }
    if (char === '#') {
      while (index < input.length && input[index] !== '\n') { output += ' '; index++; }
      if (index < input.length) output += '\n';
      continue;
    }
    if (char === "'" || char === '"') quote = char;
    output += char;
  }
  if (block || quote) throw new Error('PowerShell 静态预检遇到未闭合注释或字符串');
  return output;
}

/** 仅归一显式 Node/Python 包装器和换行，不改变 argv、splat、if 或 foreach 内容。 */
export function normalizePowerShellWitness(text) {
  return powerShellCode(text).replace(/`\n[ \t]*/g, ' ')
    .replace(/\bInvoke-AmclNode\b/g, '& node').replace(/\bInvoke-AmclPython\b/g, '& python')
    .replace(/\s+/g, ' ').trim();
}

/**
 * 在任何 quick 延期之前查出未登记的静态脚本名。
 * 动态成员仍由固定基线中的 foreach/参数绑定覆盖；本函数不根据变量名猜测脚本。
 * 无法静态确认的语法由调用者回退 full，不能先延期若干门禁再补报未知脚本。
 */
export function findUnregisteredHapScripts({ root = DEFAULT_ROOT, catalog, source } = {}) {
  const gates = exportGateInventory({ root, catalog });
  const known = new Set(gates.map(gate => gate.script));
  const code = powerShellCode(source ?? readFileSync(resolve(root, 'build-hap.ps1'), 'utf8'));
  const found = new Set();
  for (const match of code.matchAll(/(?:scripts[\\/](?:[A-Za-z0-9_-]+[\\/])*)?([A-Za-z_][A-Za-z0-9_.-]*\.(?:mjs|py))/g)) {
    const full = match[0].replaceAll('\\', '/');
    found.add(full.startsWith('scripts/') ? full : `scripts/${match[1]}`);
  }
  return [...found].filter(script => !known.has(script)).sort();
}

/** 精确的入口脚本字面路径；lib 是实现依赖，不因被引用就变成需要调度的 gate。 */
function entryScript(value) {
  const normalized = value.replaceAll('\\', '/');
  return /^scripts\/(?!lib\/)[A-Za-z0-9_./-]+\.(?:mjs|py|sh)$/.test(normalized) &&
    !normalized.split('/').includes('..') ? normalized : null;
}

/** 只取 JS 真字符串/无插值模板中的静态引用；墓碑注释和正则字面量不给覆盖资格。 */
function preflightReferences(text) {
  const rows = [];
  for (const span of scanSpans(text)) {
    if (!['string', 'template'].includes(span.kind)) continue;
    const raw = text.slice(span.start + 1, span.end - 1);
    if (raw.includes('${')) continue;
    const script = entryScript(raw);
    if (script) rows.push({ source: 'scripts/preflight.mjs', script,
      line: text.slice(0, span.start).split('\n').length, evidence: 'static-script-reference' });
  }
  return rows;
}

/** Bash 行尾注释只在引号外且单词边界生效；保留路径、引号内 # 和反斜杠续行。 */
function shellLine(text) {
  let quote = null, output = '';
  for (let index = 0; index < text.length; index++) {
    const char = text[index];
    if (char === '\\' && quote !== "'" && index + 1 < text.length) { output += char + text[++index]; continue; }
    if (quote) { output += char; if (char === quote) quote = null; continue; }
    if (char === "'" || char === '"') quote = char;
    if (char === '#' && (index === 0 || /\s/.test(text[index - 1]))) break;
    output += char;
  }
  return output;
}

/** 读取本仓 CI 的 run 单行或缩进块；env、uses 和 YAML 注释绝不作为脚本调用。 */
function ciRunBlocks(text) {
  const lines = text.replace(/\r\n/g, '\n').split('\n'), blocks = [];
  for (let index = 0; index < lines.length; index++) {
    const match = /^(\s*)run:\s*(.*)$/.exec(lines[index]);
    if (!match) continue;
    const firstLine = index + 1, indentation = match[1].length, value = match[2].trim();
    if (!/^[|>][-+]?\s*(?:#.*)?$/.test(value)) {
      let command = value;
      if ((command.startsWith("'") && command.endsWith("'")) || (command.startsWith('"') && command.endsWith('"'))) command = command.slice(1, -1);
      blocks.push({ firstLine, text: command }); continue;
    }
    const body = [];
    while (index + 1 < lines.length) {
      const next = lines[index + 1], depth = /^\s*/.exec(next)[0].length;
      if (next.trim() && !next.trimStart().startsWith('#') && depth <= indentation) break;
      index++; body.push(next.slice(Math.min(next.length, indentation + 2)));
    }
    blocks.push({ firstLine: firstLine + 1, text: body.join('\n') });
  }
  return blocks;
}

/** 静态 shell 表中的脚本路径；只供已确认被 node/python/bash 消费的表使用。 */
function tableScripts(text) {
  return [...text.matchAll(/scripts\/[A-Za-z0-9_./-]+\.(?:mjs|py|sh)/g)]
    .map(match => entryScript(match[0])).filter(Boolean);
}

/**
 * CI 当前只有直接命令与静态脚本表需要补录；不解释任意 shell 或执行 YAML/JS。
 * 对脚本表须同时看到明确的解释器消费该循环变量，路径盘点本身不授予已执行资格。
 */
function ciReferences(text) {
  const rows = [];
  const interpreter = /^(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S+)\s+)*(?:node(?:\.exe)?|python(?:3)?|bash)\b/;
  for (const block of ciRunBlocks(text)) {
    const clean = block.text.split('\n').map(shellLine).join('\n').replace(/\\\n[ \t]*/g, ' ');
    const add = (script, evidence, offset = 0) => rows.push({ source: '.github/workflows/ci.yml', script,
      line: block.firstLine + clean.slice(0, offset).split('\n').length - 1, evidence });
    let offset = 0;
    for (const line of clean.split('\n')) {
      if (interpreter.test(line.trim())) for (const script of tableScripts(line)) add(script, 'explicit-interpreter-command', offset);
      offset += line.length + 1;
    }
    for (const loop of clean.matchAll(/\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+([\s\S]*?);?\s*\bdo\b([\s\S]*?)\bdone\b/g)) {
      const variable = loop[1], body = loop[3];
      const consumesVariable = body.split('\n').some(line => interpreter.test(line.trim()) &&
        (line.includes('$' + variable) || line.includes('${' + variable + '}')));
      if (!consumesVariable) continue;
      let values = loop[2];
      const array = /\$\{([A-Za-z_][A-Za-z0-9_]*)\[@\]\}/.exec(values);
      if (array) {
        const declaration = new RegExp('(?:^|\\n)\\s*' + array[1] + '=\\(([\\s\\S]*?)\\)', 'm').exec(clean);
        values = declaration?.[1] ?? '';
      }
      for (const script of tableScripts(values)) add(script, 'static-interpreter-script-table', loop.index);
    }
  }
  return rows;
}

/**
 * 在不可变旧基线之外补查当前入口新增的显式脚本引用，防止旧见证全在而新项未登记。
 * 该结果是 catalog 覆盖检查，不宣称脚本已经执行；原动态 foreach/参数条件仍由旧基线负责。
 */
export function findUnregisteredCurrentEntryScripts({ root = DEFAULT_ROOT, catalog, preflightSource, ciSource } = {}) {
  const known = new Set(exportGateInventory({ root, catalog }).map(gate => gate.script));
  const rows = [...preflightReferences(preflightSource ?? readFileSync(resolve(root, 'scripts/preflight.mjs'), 'utf8')),
    ...ciReferences(ciSource ?? readFileSync(resolve(root, '.github/workflows/ci.yml'), 'utf8'))];
  const seen = new Set();
  return rows.filter(row => {
    const key = row.source + ':' + row.script;
    if (known.has(row.script) || seen.has(key)) return false;
    seen.add(key); return true;
  });
}
