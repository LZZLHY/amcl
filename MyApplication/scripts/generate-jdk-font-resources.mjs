/** 从现役rawfile生成Native模板/静态属性。fonts.conf必须在运行期展开绝对缓存路径；
 * 此处只锁定模板身份，不能把模板SHA当成最终发布文件的SHA。--check只核实不写入。
 */
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const fontCacheToken = '@AMCL_FONT_CACHE_DIR@';
/** 在生成阶段拒绝遗漏/多重占位符及错误替换位置，Native展开时仍再次核验唯一性。 */
export function validateFontTemplate(data) {
  const text = data.toString('utf8'), at = text.indexOf(fontCacheToken);
  if (at < 0 || text.indexOf(fontCacheToken, at + fontCacheToken.length) >= 0 ||
      !text.includes(`<cachedir>${fontCacheToken}</cachedir>`))
    throw Error('fonts.conf模板必须在cachedir文本中具有唯一缓存目录占位符');
}

/** 独立 provider 只复用 generic 规则，缓存路径仍由宿主或已验证平台契约确定。
 * 当前配置的四个 alias 是同一事实源；拒绝重复/未知家族，避免 HAP 与默认 fallback 漂移。
 */
export function genericFontRules(data) {
  const aliases = [...data.toString('utf8').matchAll(/<alias>\s*[\s\S]*?<\/alias>/g)].map(item => item[0]);
  const families = aliases.map(alias => alias.match(/^<alias>\s*<family>([^<]+)<\/family>/)?.[1]);
  const required = ['sans', 'sans-serif', 'serif', 'monospace'];
  if (families.length !== 4 || new Set(families).size !== 4 || !required.every(value => families.includes(value)))
    throw Error('fonts.conf必须具有唯一sans/sans-serif/serif/monospace generic规则');
  return aliases.join('\n');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let output = '/** 由 scripts/generate-jdk-font-resources.mjs 从现役字体资源生成，不手改字节。 */\n';
  output += `static constexpr char kFontsConfCacheToken[] = "${fontCacheToken}";\n`;
  for (const [name, relative] of [['FontsConf', 'fonts.conf'], ['Jdk8Properties', 'jdk8/fontconfig.properties']]) {
    const data = fs.readFileSync(path.join(root, 'entry/src/main/resources/rawfile', relative));
    if (name === 'FontsConf') validateFontTemplate(data);
    // FontsConf的SHA仅记录模板身份，实际发布SHA由展开正文重新计算；属性文件仍直接复用。
    output += `${name === 'FontsConf' ? '[[maybe_unused]] ' : ''}static constexpr char k${name}Sha[] = "${createHash('sha256').update(data).digest('hex')}";\n`;
    output += `static constexpr unsigned char k${name}[] = {\n`;
    for (let at = 0; at < data.length; at += 24) output += '    ' + [...data.subarray(at, at + 24)].join(', ') + ',\n';
    output += '};\n';
  }
  const destination = path.join(root, 'entry/src/main/cpp/platform/jdk_font_resources.inc');
  const fonts = fs.readFileSync(path.join(root, 'entry/src/main/resources/rawfile/fonts.conf'));
  const genericHeader = '/** 自动生成的同源 generic XML；缓存不包含在这里，修改rawfile/fonts.conf后重新生成。 */\n' +
    '#ifndef AMCL_FONTCONFIG_GENERIC_FONTS_H\n#define AMCL_FONTCONFIG_GENERIC_FONTS_H\n' +
    `#define AMCL_FONTCONFIG_GENERIC_SOURCE_SHA256 "${createHash('sha256').update(fonts).digest('hex')}"\n` +
    `#define AMCL_FONTCONFIG_GENERIC_RULES ${JSON.stringify(genericFontRules(fonts))}\n#endif\n`;
  const genericDestination = path.join(root, 'prebuilt/fontconfig/ohos-generic-fonts.h');
  if (process.argv.includes('--check')) {
    if (fs.readFileSync(destination, 'utf8') !== output) throw Error('Native 字体资源与 rawfile 身份不同，请重新生成');
    if (fs.readFileSync(genericDestination, 'utf8') !== genericHeader) throw Error('Fontconfig默认generic规则与HAP模板不同，请重新生成');
    console.log('JDK font resources: exact rawfile bytes, unique cache token and template SHA256 verified');
  } else {
    fs.writeFileSync(destination, output);
    fs.writeFileSync(genericDestination, genericHeader);
  }
}
