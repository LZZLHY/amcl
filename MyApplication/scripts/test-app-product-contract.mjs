import assert from 'node:assert/strict';
import { archiveNames, compactJsonFormatting, verifyNestedPayload } from './app-product-contract.mjs';

function storedZip(entries) {
  const local = [], central = [];
  let offset = 0;
  for (const [name, value] of entries) {
    const n = Buffer.from(name), bytes = Buffer.from(value);
    const l = Buffer.alloc(30), c = Buffer.alloc(46);
    l.writeUInt32LE(0x04034b50); l.writeUInt32LE(bytes.length, 18); l.writeUInt32LE(bytes.length, 22); l.writeUInt16LE(n.length, 26);
    c.writeUInt32LE(0x02014b50); c.writeUInt32LE(bytes.length, 20); c.writeUInt32LE(bytes.length, 24); c.writeUInt16LE(n.length, 28); c.writeUInt32LE(offset, 42);
    local.push(l, n, bytes); central.push(c, n); offset += l.length + n.length + bytes.length;
  }
  const directory = Buffer.concat(central), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...local, directory, end]);
}
const entries = [['pack.info', '{"name":"a b","devices":["tablet","2in1"]}'], ['module.json', '{"kind":"store"}'], ['libs/arm64-v8a/libentry.so', 'native payload']];
const hap = storedZip(entries);
const pretty = structuredClone(entries);
pretty[0][1] = JSON.stringify(JSON.parse(pretty[0][1]), null, 2);
assert.equal(verifyNestedPayload(storedZip(pretty), hap), verifyNestedPayload(hap, hap));
assert.throws(() => verifyNestedPayload(storedZip([...entries, ['extra.so', 'bad']]), hap), /entry set/);
for (const index of [0, 1, 2]) {
  const bad = structuredClone(entries);
  bad[index][1] = index === 0 ? '{"name":"ab","devices":["tablet","2in1"]}' : 'changed';
  assert.throws(() => verifyNestedPayload(storedZip(bad), hap), /payload mismatch/);
}
assert.throws(() => archiveNames(storedZip([...entries, entries[0]])), /duplicate/);
assert.notEqual(compactJsonFormatting(Buffer.from('{"x":1,"x":2}')), compactJsonFormatting(Buffer.from('{"x":2}')));
console.log('test-app-product-contract: exact payload binding, whitespace-only allowance, added/changed/duplicate entry rejection passed');
