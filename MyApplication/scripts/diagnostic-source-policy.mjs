import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';

export function unguardedDebugLines(source, appLogger = false) {
  const issues = [];
  const lines = source.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    if (!/\bhilog\.debug\s*\(/.test(lines[i]) || /^\s*(\/\/|\*)/.test(lines[i])) continue;
    if (/if\s*\(DiagnosticPolicy\.isDeveloperBuild\(\)\)\s+hilog\.debug\(/.test(lines[i])) continue;
    if (appLogger && /if\s*\(!DiagnosticPolicy\.isDeveloperBuild\(\)\)\s*return;/.test(lines[i - 1] ?? '')) continue;
    issues.push(i + 1);
  }
  return issues;
}

export function checkDiagnosticSources(root) {
  const issues = [];
  function walk(dir) {
    for (const item of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, item.name);
      if (item.isDirectory()) walk(path);
      else if (item.name.endsWith('.ets')) {
        const name = relative(root, path).replaceAll('\\', '/');
        const source = readFileSync(path, 'utf8');
        for (const line of unguardedDebugLines(source, name === 'commons/src/main/ets/utils/AppLogger.ets')) {
          issues.push(`${name}:${line}: direct debug producer needs DiagnosticPolicy`);
        }
      }
    }
  }
  for (const item of readdirSync(root, { withFileTypes: true })) {
    if (!item.isDirectory()) continue;
    const dir = join(root, item.name, 'src/main/ets');
    if (existsSync(dir)) walk(dir);
  }
  return issues;
}
