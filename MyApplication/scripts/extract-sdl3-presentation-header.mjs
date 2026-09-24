#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
export function extractPresentationHeader(patchText) {
  const name = 'src/video/openharmony/SDL_amclpresentation.h';
  let content = null;
  // 首个 patch 必须完整创建文件，后续按 series 顺序精确消费完整旧正文；绝不忽略冲突。
  for (const section of patchText.replace(/\r\n/g, '\n').split(/^diff --git /m).slice(1)) {
    if (!section.split('\n').includes('+++ b/' + name)) continue;
    const added = section.split('\n').includes('--- /dev/null');
    if (added ? content !== null : content === null) throw new Error('Presentation header creation order is invalid');
    const old = content ?? [];
    const output = []; let cursor = 0;
    const hunks = [...section.matchAll(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@[^\n]*\n/gm)];
    if (!hunks.length) throw new Error('Missing presentation header hunks');
    for (let i = 0; i < hunks.length; ++i) {
      const hunk = hunks[i], count = Number(hunk[2] ?? 1), newCount = Number(hunk[4] ?? 1);
      const body = section.slice(hunk.index + hunk[0].length, hunks[i + 1]?.index ?? section.length);
      const before = [], after = [];
      for (let line of body.split('\n')) {
        if (before.length === count && after.length === newCount) break;
        if (!line) line = ' ';
        if (line.startsWith(' ') || line.startsWith('-')) before.push(line.slice(1));
        if (line.startsWith(' ') || line.startsWith('+')) after.push(line.slice(1));
      }
      if (before.length !== count || after.length !== newCount) throw new Error('Incomplete presentation header hunk');
      let start = Number(hunk[1]) - (count ? 1 : 0);
      const matches = at => at >= cursor && at + count <= old.length && before.every((line, n) => old[at + n] === line);
      if (!matches(start)) {
        const candidates = [];
        for (let at = cursor; at + count <= old.length; ++at) if (matches(at)) candidates.push(at);
        if (candidates.length !== 1) throw new Error('Presentation header context mismatch or ambiguity');
        start = candidates[0];
      }
      output.push(...old.slice(cursor, start), ...after); cursor = start + count;
    }
    output.push(...old.slice(cursor)); content = output;
  }
  if (content === null) throw new Error('Presentation header must be an added file in the canonical patch');
  const header = content.join('\n') + '\n';
  if (!header.includes('AMCL_PresentationCreate') || !header.includes('AMCL_PresentationRetire')) throw new Error('Incomplete presentation header');
  return header;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const patchIndex = process.argv.indexOf('--patch'), outputIndex = process.argv.indexOf('--output');
  if (patchIndex < 0 || outputIndex < 0 || !process.argv[patchIndex + 1] || !process.argv[outputIndex + 1]) {
    throw new Error('--patch canonical SDL patch --output generated header are required');
  }
  const base = path.resolve(process.argv[patchIndex + 1]);
  const series = path.join(path.dirname(base), 'series');
  // CMake 仍传入历史创建 patch 作为锚点；实际测试必须消费当前完整 series 中的后续修改。
  const patches = fs.existsSync(series) ? fs.readFileSync(series, 'utf8').split(/\r?\n/)
    .map(value => value.trim()).filter(value => value && !value.startsWith('#'))
    .map(value => fs.readFileSync(path.join(path.dirname(series), value), 'utf8')).join('\n') : fs.readFileSync(base, 'utf8');
  const header = extractPresentationHeader(patches);
  const output = path.resolve(process.argv[outputIndex + 1]);
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, header, 'utf8');
}
