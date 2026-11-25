import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';
import { createHostTestScope } from './lib/host-test-lifecycle.mjs';

const name = 'amcl-launcher';
const path = 'scripts/LauncherSkill';
const record = `entry/skills/${name}/${path}`;
const descriptor = `skills/${name}/SKILL.md`;
const repositorySkill = fileURLToPath(new URL('../entry/skills/amcl-launcher/',import.meta.url));

/** 清单、契约和编译入口均取自同一 HAP；同时核对本候选随源码提交的契约正文。 */
export function packagedLauncherSkill(archive, module, expectedDescription, sourceDir = repositorySkill) {
  const profiles = module.skillProfiles?.filter(profile => profile.name === name) ?? [];
  assert.equal(profiles.length, 1, 'HAP must register the launcher Skill exactly once');
  const [profile] = profiles;
  assert.equal(profile.abilityName, 'EntryAbility');
  assert.equal(profile.visibility, 'system');
  assert.deepEqual(profile.srcEntries, [`@normalized:N&&&${record}&`]);
  assert.ok(module.abilities.some(ability => ability.name === profile.abilityName), 'missing bound ability');
  const description = readUniqueZipEntry(archive, descriptor).toString('utf8').replaceAll('\r\n', '\n');
  assert.equal(description, expectedDescription.replaceAll('\r\n', '\n'), 'HAP Skill description differs from source');
  assert.match(description, /^---\n(?:[^\n]+\n)*?name: amcl-launcher\n/);
  const references = [...description.matchAll(/\]\((references\/[a-z0-9-]+\.md)\)/g)].map(match => match[1]);
  assert.ok(description.split('\n').length <= 500, 'Skill index exceeds the platform instruction limit');
  const pages = [description];
  for (const reference of new Set(references)) {
    const content = readUniqueZipEntry(archive, `skills/${name}/${reference}`).toString('utf8').replaceAll('\r\n','\n');
    assert.equal(content, readFileSync(join(sourceDir,reference),'utf8').replaceAll('\r\n','\n'), 'wrong packaged '+reference);
    pages.push(content);
  }
  const methods = new Set([...pages.join('\n').matchAll(/--functionName\s+['"]?([a-zA-Z_$][\w$]*)/g)].map(match => match[1]));
  assert.ok(methods.size > 0, 'HAP Skill description has no callable methods');
  return [...methods].sort();
}

/** 发行混淆可能改名源码记录而保留清单字符串；把每个契约方法定位到实际 ABC 的指定记录。 */
export async function auditLauncherSkillHap(hap, disassembler, expectedDescription, sourceDir = repositorySkill) {
  const archive = readFileSync(hap);
  const manifest = JSON.parse(readUniqueZipEntry(archive, 'module.json'));
  const methods = packagedLauncherSkill(archive, manifest.module, expectedDescription, sourceDir);
  const abc = readUniqueZipEntry(archive, 'ets/modules.abc');
  const scope = createHostTestScope('launcher-skill-abc-', { automatic: false });
  let success = false;
  try {
    const input = join(scope.directory, 'modules.abc');
    const output = join(scope.directory, 'modules.pa');
    writeFileSync(input, abc);
    execFileSync(disassembler, ['--quiet', input, output], { timeout: 180000 });
    const listing = readFileSync(output, 'utf8');
    const marker = `&${record.replaceAll('/', '.')}&`;
    assert.ok(listing.split('\n').some(line => line.startsWith(`.record ${marker} {`)), 'Skill module record missing or renamed');
    const actual = new Set();
    for (const match of listing.matchAll(/^\.function\s+\S+\s+(&[^&]+&)\.[^\n(]*?>#([\w$]+)\(/gm)) {
      if (match[1] === marker) actual.add(match[2]);
    }
    for (const method of methods) assert.ok(actual.has(method), `Skill method missing or renamed: ${method}`);
    success = true;
    return { hapSha256: createHash('sha256').update(archive).digest('hex'), record, methods };
  } finally {
    await scope.close({ success });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [hap, disassembler, source = fileURLToPath(new URL('../entry/skills/amcl-launcher/SKILL.md', import.meta.url))] = process.argv.slice(2);
  if (!hap || !disassembler) throw new Error('Usage: node check-launcher-skill-hap.mjs <HAP> <SDK ark_disasm> [SKILL.md]');
  console.log(JSON.stringify(await auditLauncherSkillHap(hap, disassembler, readFileSync(source, 'utf8'), dirname(resolve(source)))));
}
