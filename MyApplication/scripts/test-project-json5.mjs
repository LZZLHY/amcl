/** 验证实际配置解析器保留字符串、接受模板注释，并拒绝损坏配置。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { parseJson5, readProductRegistry } from './product-contract.mjs';

const source = '\uFEFF// first line\n{\n"url":"https://example.com/a",\n'
  + '"text":"/* keep */ // keep ,} ,]",\n"items":[1,/* comment */2,],\n}';
assert.deepEqual(parseJson5(source), {
  url: 'https://example.com/a', text: '/* keep */ // keep ,} ,]', items: [1, 2],
});
assert.equal(parseJson5('{"quoted":"a\\\"//b",}').quoted, 'a"//b');
assert.throws(() => parseJson5('{"a":1, /* never closed'), /Unterminated/);
assert.throws(() => parseJson5('{"a":1, ,}'));
const template = parseJson5(fs.readFileSync(new URL('../build-profile.json5.template', import.meta.url), 'utf8'));
assert.deepEqual(template.app.products.map(p => p.name).sort(), Object.keys(readProductRegistry().products).sort());
console.log('PASS project JSON5: first-line/BOM comments, intact strings, trailing commas and malformed input');
