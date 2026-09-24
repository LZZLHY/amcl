#!/usr/bin/env node
import assert from 'node:assert/strict';
import { deflateRawSync } from 'node:zlib';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';

function makeZip(entries) {
  const locals = [];
  const centrals = [];
  let localOffset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.name, 'utf8');
    const data = Buffer.from(entry.data);
    const method = entry.deflate ? 8 : 0;
    const compressed = entry.deflate ? deflateRawSync(data) : data;
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(method, 8);
    local.writeUInt32LE(compressed.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(name.length, 26);
    const localRecord = Buffer.concat([local, name, compressed]);
    locals.push(localRecord);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(method, 10);
    central.writeUInt32LE(compressed.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt32LE(localOffset, 42);
    centrals.push(Buffer.concat([central, name]));
    localOffset += localRecord.length;
  }
  const centralBytes = Buffer.concat(centrals);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(centralBytes.length, 12);
  eocd.writeUInt32LE(localOffset, 16);
  return Buffer.concat([...locals, centralBytes, eocd]);
}

const stored = makeZip([{ name: 'a.bin', data: 'stored', deflate: false }]);
assert.equal(readUniqueZipEntry(stored, 'a.bin').toString(), 'stored');
const deflated = makeZip([{ name: 'a.bin', data: 'deflated payload', deflate: true }]);
assert.equal(readUniqueZipEntry(deflated, 'a.bin').toString(), 'deflated payload');
const duplicate = makeZip([
  { name: 'a.bin', data: 'first' },
  { name: 'a.bin', data: 'second' },
]);
assert.throws(() => readUniqueZipEntry(duplicate, 'a.bin'), /exactly once/);
assert.throws(() => readUniqueZipEntry(stored.subarray(0, stored.length - 8), 'a.bin'),
  /central directory|EOCD|out of range/);
assert.throws(() => readUniqueZipEntry(stored, 'missing.bin'), /exactly once/);

console.log('test-zip-entry-buffer: stored/deflate/duplicate/truncated/missing cases passed');
