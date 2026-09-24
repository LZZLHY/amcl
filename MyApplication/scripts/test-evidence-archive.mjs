/** 迁移证据检查的正反向回归，测试在自身独占仓外目录内修改夹具，不修改冻结的真实证据。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { createWorkspaceTemp } from './lib/workspace-paths.mjs';
import { checkEvidenceArchive } from './check-evidence-archive.mjs';

const temporary = createWorkspaceTemp('amcl-evidence-migration-');
try {
  const evidence = path.join(temporary, 'docs/testing/evidence');
  fs.mkdirSync(evidence, { recursive: true });
  const bytes = Buffer.from('preserve CRLF\r\nraw evidence\n');
  const file = path.join(evidence, 'fixture.txt');
  fs.writeFileSync(file, bytes);
  const item = { path: 'docs/testing/evidence/fixture.txt', bytes: bytes.length,
    sha256: createHash('sha256').update(bytes).digest('hex') };
  const writeManifest = (files) => fs.writeFileSync(path.join(evidence, 'migration-manifest.json'), JSON.stringify({ schema: 1, count: files.length, files }));
  writeManifest([item]);
  assert.deepEqual(checkEvidenceArchive(temporary), []);
  fs.writeFileSync(file, bytes.toString().replaceAll('\r\n', '\n'));
  assert.match(checkEvidenceArchive(temporary).join(), /bytes changed/);
  fs.unlinkSync(file);
  assert.match(checkEvidenceArchive(temporary).join(), /missing evidence/);
  writeManifest([{ ...item, path: 'docs/testing/evidence/../../outside.txt' }]);
  assert.match(checkEvidenceArchive(temporary).join(), /invalid or duplicate/);
  fs.writeFileSync(file, bytes);
  writeManifest([item, item]);
  assert.match(checkEvidenceArchive(temporary).join(), /invalid or duplicate/);
  assert.deepEqual(checkEvidenceArchive(), []);
  console.log('Evidence migration: real manifest and altered/missing/escaping/duplicate fixture cases PASS');
} finally {
  assert.ok(path.basename(temporary).startsWith('amcl-evidence-migration-'));
  fs.rmSync(temporary, { recursive: true, force: true });
}
