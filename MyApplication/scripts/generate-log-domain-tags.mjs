// 渲染分流直接由域注册表生成，门禁验证派生产物，避免两套名单漂移。
import fs from 'node:fs';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const registry = JSON.parse(fs.readFileSync(path.join(root, 'config/log-domains.json'), 'utf8'));
const names = Object.entries(registry.tags).filter(([, domain]) => domain === 'render').map(([name]) => name).sort();
const text = '#pragma once\n// 由 scripts/generate-log-domain-tags.mjs 生成；修改 config/log-domains.json。\n'
  + 'static constexpr const char* AMCL_RENDER_LOG_TAGS[] = {\n'
  + names.map(name => `    ${JSON.stringify(name)},`).join('\n') + '\n};\n';
const target = path.join(root, 'entry/src/main/cpp/utils/render_log_tags.generated.h');
if (process.argv.includes('--check')) {
  // Git 在 Windows checkout 时可能转换为 CRLF；派生内容按行比较，换行风格不改变域映射。
  if (!fs.existsSync(target) || fs.readFileSync(target, 'utf8').replace(/\r\n/g, '\n') !== text) throw new Error('日志域分流派生表未同步');
  console.log('render log domain table PASS');
} else fs.writeFileSync(target, text);
