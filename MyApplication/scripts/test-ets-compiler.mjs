/** CI 页面 AST 兼容只变换声明，保留方法体字节和注释/字符串中的示例。 */
import assert from 'node:assert/strict';
import ts, { normalizeStructDeclarations } from './lib/ets-compiler.mjs';
const body = 'method(value: string): string { return value + "struct Fake {"; }';
const source = '// struct Comment {\nconst text = `\nstruct StringExample {\n`;\n'
  + '@Component\nexport struct Page {\n' + body + '\n}\n';
const normalized = normalizeStructDeclarations(source);
assert.equal(normalized.length, source.length);
assert(normalized.includes('struct Comment {'));
assert(normalized.includes('struct StringExample {'));
assert(normalized.includes(body));
assert(normalized.includes('export class  Page {'));
const ast = ts.createSourceFile('Page.ets', source, ts.ScriptTarget.Latest, true);
const page = ast.statements.find(node => node.members?.some(member => member.name?.getText(ast) === 'method'));
assert(page, 'the actual page method must be present on SDK and plain TypeScript');
assert.equal(page.members.find(member => member.name?.getText(ast) === 'method').getText(ast), body);
console.log('PASS ETS host parser: declaration compatibility and exact production method body');
