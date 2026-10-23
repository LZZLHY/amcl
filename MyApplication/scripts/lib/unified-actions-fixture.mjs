/**
 * 圆形动作宿主回归的生产组件装载与声明接收器。
 * 方法、分支、回调及 BuilderParam 调用来自生产 AST；只隔离系统能力与 ArkUI 绘制边界。
 * UI 模式用编译器打印器把声明式容器块展开成宿主可执行语句，保留真实条件和事件表达式。
 * 接收器只记录声明与执行正文闭包，不能证明像素、布局占高、命中区域或 GPU 表现。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import compiler from './ets-compiler.mjs';
import { PROJECT_ROOT } from './workspace-paths.mjs';
import { stripComments, stripStringLiterals } from './source-noise.mjs';

/**
 * 只为声明定位/入口约束提供括号配对，不解析ArkUI语义。复用仓库共享词法前置，
 * 字符串、模板、正则、注释里的括号不参加配对，原始UTF16位置保持不变。
 */
export function builderSourceLex(source) {
  const skeleton = stripStringLiterals(stripComments(source, { lang: 'js' }), { lang: 'js' });
  const scanner = compiler.createScanner(compiler.ScriptTarget.Latest, true, compiler.LanguageVariant.Standard, skeleton);
  const tokens = [], pairs = new Map(), stack = [], closing = { ')': '(', ']': '[', '}': '{' };
  let kind;
  while ((kind = scanner.scan()) !== compiler.SyntaxKind.EndOfFileToken) {
    tokens.push({ value: scanner.getTokenText(), start: scanner.getTokenPos(), end: scanner.getTextPos() });
  }
  tokens.forEach((token, index) => {
    if (['(', '[', '{'].includes(token.value)) stack.push(index);
    else if (Object.hasOwn(closing, token.value)) {
      const open = stack.pop();
      assert.equal(tokens[open]?.value, closing[token.value], '声明定位括号不匹配：' + token.start);
      pairs.set(open, index); pairs.set(index, open);
    }
  });
  assert.equal(stack.length, 0, '声明定位存在未闭合括号');
  return { tokens, pairs };
}

/** 保留完整生产字段和非 UI 方法；render=true 时同时保留真实 build/Builder 控制流。 */
export function loadActionComponent(relative, name, options = {}) {
  const original = fs.readFileSync(path.join(PROJECT_ROOT, relative), 'utf8');
  const source = options.mutate ? options.mutate(original.replaceAll('\r\n', '\n')) : original;
  if (options.mutate) assert.notEqual(source, original.replaceAll('\r\n', '\n'), '负控必须命中真实源码');
  const ast = compiler.createSourceFile(relative, source, compiler.ScriptTarget.Latest, true);
  const owner = ast.statements.find(node => node.members && node.name?.getText(ast) === name);
  assert.ok(owner, '生产组件不存在：' + name);
  const imports = ast.statements.filter(node => node.kind === compiler.SyntaxKind.ImportDeclaration)
    .map(node => node.getText(ast)).join('\n');
  const constants = ast.statements.filter(node => !options.methods && node.kind === compiler.SyntaxKind.VariableStatement)
    .map(node => node.getText(ast)).join('\n');
  // 无障碍等生产AttributeModifier是被测逻辑的一部分，不能在组件抽取时丢掉或用假实现替代。
  const supportDeclarations = ast.statements.filter(node => !options.methods && node !== owner &&
    [compiler.SyntaxKind.ClassDeclaration, compiler.SyntaxKind.EnumDeclaration].includes(node.kind))
    .map(node => node.getText(ast)).join('\n');
  const printer = compiler.createPrinter();
  // SDK parser会给struct补无源码区间的合成constructor；它不是业务方法，不能用printer拼入宿主类。
  const members = owner.members.filter(member => member.end > member.pos)
    .filter(member => !options.methods || options.methods.includes(member.name?.getText(ast)))
    .filter(member => options.render ||
    (member.name?.getText(ast) !== 'build' && !member.getText(ast).includes('@Builder')))
    .map(member => {
      const start = member.getStart(ast);
      const text = options.render ? printer.printNode(compiler.EmitHint.Unspecified, member, ast) : source.slice(start, member.end);
      return text.replace(/@(Prop|State|Watch|StorageLink|StorageProp|Link|ObjectLink|BuilderParam|Builder)(\([^\n]*?\))?\s*/g, '');
    });
  const extracted = imports + '\n' + constants + '\n' + supportDeclarations + '\nexport class ' + name + '{' + members.join('\n') + '}';
  const compiled = compiler.transpileModule(extracted, {
    fileName: relative.replace(/\.ets$/, '.ts'), reportDiagnostics: true,
    compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 },
  });
  const errors = (compiled.diagnostics ?? []).filter(d => d.category === compiler.DiagnosticCategory.Error);
  assert.equal(errors.length, 0, '宿主提取语法失败：' + relative + '\n' + errors.map(d =>
    compiler.flattenDiagnosticMessageText(d.messageText, '\n') + ' near ' + extracted.slice(Math.max(0, d.start - 50), d.start + 80)).join('\n'));
  const dependencies = options.dependencies ?? {}, globals = Object.fromEntries(
    Object.entries(options.globals ?? {}).filter(([key]) => key !== name)), module = { exports: {} };
  new Function('require', 'module', 'exports', ...Object.keys(globals), compiled.outputText)(dependency => {
    assert.ok(Object.hasOwn(dependencies, dependency), '未声明的系统/组件边界：' + dependency);
    return dependencies[dependency];
  }, module, module.exports, ...Object.values(globals));
  return module.exports[name];
}

/**
 * 记录生产 DSL 输出；每次声明获得独立接收器，ForEach 执行生产 callback。
 * 被测 onClick 不由接收器自动触发，测试必须显式保存再迟到投递，避免把禁用链路假装为系统保证。
 */
export function actionUiReceiver() {
  const records = [];
  const make = (type, args = []) => {
    const record = { type, args, modifiers: {} };
    records.push(record);
    const receiver = new Proxy({}, { get: (_, key) => (...values) => {
      record.modifiers[key] = values;
      // 运行真实修饰器，在同一个ButtonAttribute接收器上观察string/Resource重载分支的原值。
      if (key === 'attributeModifier') {
        assert.equal(typeof values[0]?.applyNormalAttribute, 'function', '真实AttributeModifier必须可执行');
        values[0].applyNormalAttribute(receiver);
      }
      return receiver;
    } });
    return receiver;
  };
  const globals = {};
  for (const name of ['Column', 'Row', 'Stack', 'Button', 'Text', 'Image', 'AppRoundIconButton', 'AppIcon', 'HdsNavigation']) {
    globals[name] = (...args) => make(name, args);
  }
  for (const name of ['width', 'height', 'mode', 'padding', 'backgroundColor', 'constraintSize', 'layoutWeight']) {
    globals[name] = (...args) => make('detached-' + name, args);
  }
  globals.ForEach = (items, build) => { for (const item of items) build(item); };
  for (const name of ['Alignment', 'ButtonType', 'FlexAlign', 'VerticalAlign', 'FontWeight', 'TextOverflow',
    'HorizontalAlign', 'NavigationMode', 'HitTestMode', 'ImageFit', 'ImageInterpolation']) {
    globals[name] = new Proxy({}, { get: (_, key) => name + '.' + String(key) });
  }
  return { globals, records, clear() { records.length = 0; } };
}
