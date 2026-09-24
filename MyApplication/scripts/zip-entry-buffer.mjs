import { inflateRawSync } from 'node:zlib';

function requireRange(buffer, offset, length, label) {
  if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) ||
      offset < 0 || length < 0 || offset > buffer.length - length) {
    throw new Error(`ZIP ${label} is out of range`);
  }
}

export function readUniqueZipEntry(input, wantedName) {
  const buffer = Buffer.from(input);
  let eocd = -1;
  for (let index = buffer.length - 22;
    index >= 0 && index >= buffer.length - 22 - 65535; index -= 1) {
    if (buffer.readUInt32LE(index) === 0x06054b50) { eocd = index; break; }
  }
  if (eocd < 0) throw new Error('ZIP central directory is missing');
  requireRange(buffer, eocd, 22, 'EOCD');
  const count = buffer.readUInt16LE(eocd + 10);
  const centralSize = buffer.readUInt32LE(eocd + 12);
  const centralOffset = buffer.readUInt32LE(eocd + 16);
  requireRange(buffer, centralOffset, centralSize, 'central directory');

  let offset = centralOffset;
  const matches = [];
  for (let entry = 0; entry < count; entry += 1) {
    requireRange(buffer, offset, 46, `central header ${entry}`);
    if (buffer.readUInt32LE(offset) !== 0x02014b50) {
      throw new Error(`ZIP central header ${entry} is malformed`);
    }
    const method = buffer.readUInt16LE(offset + 10);
    const compressedSize = buffer.readUInt32LE(offset + 20);
    const uncompressedSize = buffer.readUInt32LE(offset + 24);
    const nameLength = buffer.readUInt16LE(offset + 28);
    const extraLength = buffer.readUInt16LE(offset + 30);
    const commentLength = buffer.readUInt16LE(offset + 32);
    const recordLength = 46 + nameLength + extraLength + commentLength;
    requireRange(buffer, offset, recordLength, `central record ${entry}`);
    const name = buffer.toString('utf8', offset + 46, offset + 46 + nameLength);
    if (name === wantedName) {
      matches.push({
        method, compressedSize, uncompressedSize,
        localOffset: buffer.readUInt32LE(offset + 42),
      });
    }
    offset += recordLength;
  }
  if (offset !== centralOffset + centralSize) {
    throw new Error('ZIP central directory size/count mismatch');
  }
  if (matches.length !== 1) {
    throw new Error(`ZIP entry ${wantedName} must appear exactly once (actual=${matches.length})`);
  }

  const match = matches[0];
  requireRange(buffer, match.localOffset, 30, 'local header');
  if (buffer.readUInt32LE(match.localOffset) !== 0x04034b50) {
    throw new Error(`ZIP local header is malformed: ${wantedName}`);
  }
  const localNameLength = buffer.readUInt16LE(match.localOffset + 26);
  const localExtraLength = buffer.readUInt16LE(match.localOffset + 28);
  const dataStart = match.localOffset + 30 + localNameLength + localExtraLength;
  requireRange(buffer, dataStart, match.compressedSize, `entry data ${wantedName}`);
  const raw = buffer.subarray(dataStart, dataStart + match.compressedSize);
  const data = match.method === 0 ? Buffer.from(raw)
    : (match.method === 8 ? inflateRawSync(raw) : null);
  if (!data) throw new Error(`unsupported ZIP compression method ${match.method}: ${wantedName}`);
  if (data.length !== match.uncompressedSize) {
    throw new Error(`ZIP uncompressed size mismatch: ${wantedName}`);
  }
  return data;
}
