#!/usr/bin/env node
// Materialize the ignored root build-profile.json5 from the tracked, non-secret
// template plus one base64-encoded signing config supplied through the runner's
// secret store. Secret values and machine-local paths are never printed.

import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

function stripJson5(text) {
  let result = '';
  let quote = '';
  let escaped = false;
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    const next = text[index + 1];
    if (quote) {
      result += char;
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === quote) quote = '';
      continue;
    }
    if (char === '"' || char === "'") {
      quote = char;
      result += char;
      continue;
    }
    if (char === '/' && next === '/') {
      while (index < text.length && text[index] !== '\n') index += 1;
      result += '\n';
      continue;
    }
    if (char === '/' && next === '*') {
      index += 2;
      while (index < text.length && !(text[index] === '*' && text[index + 1] === '/')) {
        if (text[index] === '\n') result += '\n';
        index += 1;
      }
      index += 1;
      continue;
    }
    result += char;
  }
  return result.replace(/,\s*([}\]])/g, '$1');
}

function parseArguments(argv) {
  const options = {
    template: resolve(root, 'build-profile.json5.template'),
    output: resolve(root, 'build-profile.json5'),
    product: 'default',
    expectedTargetSdk: '6.1.0(23)',
    expectedCompatibleSdk: '6.0.0(20)',
  };
  const names = new Map([
    ['--template', 'template'],
    ['--output', 'output'],
    ['--product', 'product'],
    ['--expected-target-sdk', 'expectedTargetSdk'],
    ['--expected-compatible-sdk', 'expectedCompatibleSdk'],
  ]);
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--help' || argv[index] === '-h') return { help: true };
    const key = names.get(argv[index]);
    if (!key || index + 1 >= argv.length) throw new Error(`unknown or incomplete argument: ${argv[index]}`);
    options[key] = key === 'template' || key === 'output' ? resolve(argv[index + 1]) : argv[index + 1];
    index += 1;
  }
  return options;
}

function usage() {
  console.log(`Usage: node scripts/prepare-release-profile.mjs [options]

Requires AMCL_SIGNING_CONFIG_B64: base64(JSON) for one HarmonyOS signing config.
The signing material files referenced by the JSON must already exist on the
self-hosted runner. The script never logs the decoded secret.
`);
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.help) return usage();
  if (!existsSync(options.template)) throw new Error(`profile template missing: ${options.template}`);
  const profile = JSON.parse(stripJson5(readFileSync(options.template, 'utf8')));
  if (!Array.isArray(profile?.app?.signingConfigs) || profile.app.signingConfigs.length !== 0) {
    throw new Error('tracked profile template must contain an empty signingConfigs array');
  }
  const product = profile?.app?.products?.find(item => item.name === options.product);
  if (!product) throw new Error(`tracked profile template has no product=${options.product}`);
  if (product.targetSdkVersion !== options.expectedTargetSdk ||
      product.compatibleSdkVersion !== options.expectedCompatibleSdk) {
    throw new Error(
      `product=${options.product} SDK mismatch: target=${product.targetSdkVersion}, ` +
      `compatible=${product.compatibleSdkVersion}, expected target=${options.expectedTargetSdk}, ` +
      `compatible=${options.expectedCompatibleSdk}`,
    );
  }

  const encoded = process.env.AMCL_SIGNING_CONFIG_B64;
  if (!encoded) throw new Error('AMCL_SIGNING_CONFIG_B64 is not set');
  let signing;
  try {
    signing = JSON.parse(Buffer.from(encoded, 'base64').toString('utf8'));
  } catch {
    throw new Error('AMCL_SIGNING_CONFIG_B64 is not valid base64-encoded JSON');
  }
  if (Array.isArray(signing)) {
    if (signing.length !== 1) throw new Error('signing secret must contain exactly one config');
    [signing] = signing;
  }
  if (!signing || typeof signing !== 'object' || signing.name !== product.signingConfig) {
    throw new Error(`signing secret name must equal product signingConfig=${product.signingConfig}`);
  }
  if (signing.type !== 'HarmonyOS') throw new Error('signing secret type must be HarmonyOS');
  const material = signing.material;
  for (const key of [
    'certpath', 'keyAlias', 'keyPassword', 'profile', 'signAlg', 'storeFile', 'storePassword',
  ]) {
    if (typeof material?.[key] !== 'string' || !material[key]) {
      throw new Error(`signing secret material.${key} is missing`);
    }
  }
  if (material.signAlg !== 'SHA256withECDSA') {
    throw new Error('signing secret material.signAlg must be SHA256withECDSA');
  }
  for (const key of ['certpath', 'profile', 'storeFile']) {
    if (!existsSync(material[key])) throw new Error(`signing material.${key} file does not exist on runner`);
  }

  profile.app.signingConfigs = [signing];
  writeFileSync(options.output, `${JSON.stringify(profile, null, 2)}\n`, { mode: 0o600 });
  console.log(`[prepare-release-profile] wrote controlled product=${options.product} profile`);
}

try {
  main();
} catch (error) {
  console.error(`[prepare-release-profile] ERROR: ${error.message}`);
  process.exitCode = 1;
}
