/** 真实生产摘要helper在严格HCF边界下处理空内容；非空I/O/crypto故障不能被空摘要掩盖。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

const modulePath = 'commons/src/main/ets/utils/EvidenceIo.ets';
const EMPTY_SHA256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

test('原无条件updateSync的真实生产反例在strict crypto边界失败，修复保留标准空SHA-256', () => {
  const original = evidenceRuntime({ transform: (absolute, source) => absolute.endsWith('EvidenceIo.ets')
    ? source.replace('if (bytes.byteLength > 0) digest.updateSync({ data: bytes });', 'digest.updateSync({ data: bytes });') : source });
  const current = evidenceRuntime();
  try {
    assert.throws(() => original.load(modulePath).evidenceTextDigest(''), error => error.message === 'update failed');
    assert.equal(original.control.cryptoUpdates[0].bytes, 0);
    const io = current.load(modulePath);
    assert.equal(io.evidenceTextDigest(''), EMPTY_SHA256);
    for (const text of ['abc', '非空Unicode😀\n']) assert.equal(io.evidenceTextDigest(text), crypto.createHash('sha256').update(text, 'utf8').digest('hex'));
    assert.ok(current.control.cryptoUpdates.every(update => update.bytes > 0));
  } finally { original.close(); current.close(); }
});

test('空文件同步/异步摘要、零范围复制和空gzip均只finalize，原件和目标仍为空且标准摘要一致', async () => {
  const f = evidenceRuntime();
  try {
    const io = f.load(modulePath); const empty = f.write('empty.bin', ''); const gzip = f.write('empty.log.gz', zlib.gzipSync(''));
    assert.equal(io.evidenceFileDigestSync(empty), EMPTY_SHA256);
    assert.equal(await io.evidenceFileDigestAsync(empty), EMPTY_SHA256);
    const input = f.kitFs.openSync(empty, f.kitFs.OpenMode.READ_ONLY);
    const outputPath = f.write('copy.bin', ''); const output = f.kitFs.openSync(outputPath, f.kitFs.OpenMode.READ_WRITE);
    try { assert.equal(await io.hashEvidenceRange(input.fd, 0, output.fd), EMPTY_SHA256); }
    finally { f.kitFs.closeSync(input); f.kitFs.closeSync(output); }
    assert.equal(await io.hashGzipEvidenceContent(gzip), EMPTY_SHA256);
    assert.equal(fs.statSync(empty).size, 0); assert.equal(fs.statSync(outputPath).size, 0);
    assert.deepEqual(f.control.cryptoUpdates, [], '合法空内容不调用sync或async update');
  } finally { f.close(); }
});

test('非空范围、文件和gzip仍产生真实标准摘要，短读/读取EIO/磁盘短写原错误严格传播', async () => {
  const f = evidenceRuntime();
  try {
    const io = f.load(modulePath); const bytes = Buffer.from('真实内容\n' + 'x'.repeat(100000));
    const source = f.write('source.bin', bytes); const expected = crypto.createHash('sha256').update(bytes).digest('hex');
    assert.equal(io.evidenceFileDigestSync(source), expected); assert.equal(await io.evidenceFileDigestAsync(source), expected);
    assert.equal(await io.hashGzipEvidenceContent(f.write('source.gz', zlib.gzipSync(bytes))), expected);
    const readSync = f.kitFs.readSync; f.kitFs.readSync = () => 0;
    assert.throws(() => io.evidenceFileDigestSync(source), /读取不完整/); f.kitFs.readSync = readSync;
    const read = f.kitFs.read; f.kitFs.read = async () => 0;
    await assert.rejects(io.evidenceFileDigestAsync(source), /被截断/);
    const failure = new Error('synthetic nonempty read EIO'); f.kitFs.read = async () => { throw failure; };
    await assert.rejects(io.evidenceFileDigestAsync(source), error => error === failure); f.kitFs.read = read;
    const input = f.kitFs.openSync(source, f.kitFs.OpenMode.READ_ONLY);
    const output = f.kitFs.openSync(f.write('failed-copy.bin', ''), f.kitFs.OpenMode.READ_WRITE);
    const write = f.kitFs.write; f.kitFs.write = async () => 0;
    try { await assert.rejects(io.hashEvidenceRange(input.fd, bytes.length, output.fd), /磁盘短写/); }
    finally { f.kitFs.write = write; f.kitFs.closeSync(input); f.kitFs.closeSync(output); }
    assert.ok(f.control.cryptoUpdates.every(update => update.bytes > 0));
  } finally { f.close(); }
});
