import { createHash } from 'node:crypto';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';

export function archiveNames(buffer) {
  let eocd = -1;
  for (let i = buffer.length - 22; i >= Math.max(0, buffer.length - 65557); i--) {
    if (buffer.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error('APP central directory missing');
  const count = buffer.readUInt16LE(eocd + 10);
  let cursor = buffer.readUInt32LE(eocd + 16);
  const names = [];
  for (let i = 0; i < count; i++) {
    if (cursor + 46 > eocd || buffer.readUInt32LE(cursor) !== 0x02014b50) throw new Error('APP directory malformed');
    const length = buffer.readUInt16LE(cursor + 28);
    const total = 46 + length + buffer.readUInt16LE(cursor + 30) + buffer.readUInt16LE(cursor + 32);
    if (cursor + total > eocd) throw new Error('APP entry out of bounds');
    names.push(buffer.toString('utf8', cursor + 46, cursor + 46 + length));
    cursor += total;
  }
  if (new Set(names).size !== names.length) throw new Error('APP contains duplicate entries');
  return names;
}

// Preserve JSON tokens, key order, duplicate keys and string contents. Only
// insignificant whitespace can differ when Hvigor reformats pack.info.
export function compactJsonFormatting(bytes) {
  const text = bytes.toString('utf8');
  JSON.parse(text);
  let result = '', quoted = false, escaped = false;
  for (const c of text) {
    if (quoted) {
      result += c;
      if (escaped) escaped = false;
      else if (c === '\\') escaped = true;
      else if (c === '"') quoted = false;
    } else if (c === '"') { quoted = true; result += c; }
    else if (!/[\t\r\n ]/.test(c)) result += c;
  }
  return result;
}

export function verifyNestedPayload(embedded, reference) {
  const names = archiveNames(reference).sort();
  if (JSON.stringify(names) !== JSON.stringify(archiveNames(embedded).sort())) throw new Error('APP HAP entry set differs from audited HAP');
  for (const name of names) {
    const a = readUniqueZipEntry(embedded, name), b = readUniqueZipEntry(reference, name);
    if (a.equals(b)) continue;
    if (name === 'pack.info' && compactJsonFormatting(a) === compactJsonFormatting(b)) continue;
    throw new Error(`APP HAP payload mismatch: ${name}`);
  }
  return createHash('sha256').update(JSON.stringify(names.map(name => {
    const bytes = readUniqueZipEntry(embedded, name);
    const content = name === 'pack.info' ? compactJsonFormatting(bytes) : bytes;
    return [name, createHash('sha256').update(content).digest('hex')];
  }))).digest('hex');
}
