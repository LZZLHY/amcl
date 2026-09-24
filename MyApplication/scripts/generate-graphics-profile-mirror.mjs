#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseGraphicsRegistry, renderGraphicsProfileMirror } from './lib/graphics-profile-registry.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const registryPath = path.join(root, 'launch/src/main/ets/GraphicsProfileRegistry.ets');
const mirrorPath = path.join(root, 'entry/src/main/cpp/platform/graphics_profile_mirror.generated.h');
const expected = renderGraphicsProfileMirror(parseGraphicsRegistry(fs.readFileSync(registryPath, 'utf8')));
if (process.argv.includes('--check')) {
  const actual = fs.existsSync(mirrorPath) ? fs.readFileSync(mirrorPath, 'utf8').replace(/\r\n/g, '\n') : '';
  if (actual !== expected) {
    console.error('Graphics profile mirror is stale. Run node scripts/generate-graphics-profile-mirror.mjs');
    process.exit(1);
  }
  console.log('Canonical graphics profile mirror PASS');
} else {
  fs.writeFileSync(mirrorPath, expected, 'utf8');
  console.log('Generated ' + path.relative(root, mirrorPath));
}