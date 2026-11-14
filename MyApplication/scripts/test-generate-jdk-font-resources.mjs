/** 模板发布前的必要反例：缺失、多重和错误上下文都不能生成可供Native消费的资源。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fontCacheToken, validateFontTemplate, genericFontRules } from './generate-jdk-font-resources.mjs';
const accepted = `<fontconfig><cachedir>${fontCacheToken}</cachedir></fontconfig>`;
validateFontTemplate(Buffer.from(accepted));
for (const invalid of [accepted.replace(fontCacheToken, 'cache'), accepted + fontCacheToken,
  `<fontconfig><!-- ${fontCacheToken} --><cachedir>cache</cachedir></fontconfig>`,
  `<fontconfig><cachedir prefix="relative">${fontCacheToken}</cachedir></fontconfig>`])
  assert.throws(() => validateFontTemplate(Buffer.from(invalid)), /唯一缓存目录占位符/);
console.log('PASS fontconfig template: one cachedir token accepted, missing/multiple/misplaced/relative forms rejected');
const actual = fs.readFileSync(new URL('../entry/src/main/resources/rawfile/fonts.conf', import.meta.url));
const generic = genericFontRules(actual);
assert(generic.includes('<family>sans</family>') && !generic.includes('<cachedir>') && !generic.includes(fontCacheToken));
assert.throws(() => genericFontRules(Buffer.from('<fontconfig/>')), /generic规则/);
assert.throws(() => genericFontRules(Buffer.from(actual.toString().replace('<family>sans</family>', '<family>serif</family>'))), /generic规则/);
console.log('PASS shared generic rules: actual four families accepted, cache excluded, missing/duplicate families rejected');
