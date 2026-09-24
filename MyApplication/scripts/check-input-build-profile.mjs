#!/usr/bin/env node
// Fail-closed static contract for the input route carried by Hvigor profiles.
//
// DevEco/Hvigor merges build options recursively, but
// externalNativeOptions.arguments is a scalar string: a target-level value
// replaces the buildMode/module value as a whole.  Keep that precedence
// explicit here so a new product or target cannot silently ship the legacy
// route while the source profile still looks correct in isolation.

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const MODULE_PROFILE = resolve(ROOT, 'entry/build-profile.json5');

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

function parseProfile(text) {
  return JSON.parse(stripJson5(text));
}

function valuesOf(argumentsText, flag) {
  const pattern = new RegExp(
    `(?:^|\\s)-D${flag}(?::[A-Za-z][A-Za-z0-9_]*)?\\s*=\\s*([^\\s,]*)`, 'g');
  return [...String(argumentsText ?? '').matchAll(pattern)]
    .map(match => match[1].replace(/[\\"']/g, '').toUpperCase());
}

export function cmakeValueLooksEnabled(value) {
  const normalized = String(value ?? '').replace(/[\\"']/g, '').trim().toUpperCase();
  if (!normalized || normalized.endsWith('-NOTFOUND')) return false;
  return !new Set(['0', 'OFF', 'NO', 'FALSE', 'N', 'IGNORE', 'NOTFOUND'])
    .has(normalized);
}

function effectiveArguments(profile, targetName, modeName) {
  const moduleOptions = profile?.buildOption?.externalNativeOptions ?? {};
  const mode = (profile?.buildOptionSet ?? []).find(item => item?.name === modeName);
  const target = (profile?.targets ?? []).find(item => item?.name === targetName);
  const modeOptions = mode?.externalNativeOptions ?? {};
  const targetOptions = target?.config?.buildOption?.externalNativeOptions ?? {};
  // `arguments` is scalar and target config wins; the fallback chain models
  // the documented recursive merge without pretending strings are appended.
  if (Object.prototype.hasOwnProperty.call(targetOptions, 'arguments')) {
    return String(targetOptions.arguments ?? '');
  }
  if (Object.prototype.hasOwnProperty.call(modeOptions, 'arguments')) {
    return String(modeOptions.arguments ?? '');
  }
  return String(moduleOptions.arguments ?? '');
}

function requireExactlyOne(issues, argumentsText, flag, expected, context) {
  const values = valuesOf(argumentsText, flag);
  if (values.length !== 1 || values[0] !== expected) {
    issues.push(`${context} must set ${flag}=${expected} exactly once (actual=${values.join('|') || 'missing'})`);
  }
}

function checkRoute(issues, argumentsText, expected, context) {
  const rawArguments = String(argumentsText ?? '');
  if (/(?:^|\s)-U(?:\s*\S+)?/.test(rawArguments)) {
    issues.push(`${context} must not use CMake -U cache deletion in the input argument closure`);
  }
  if (/(?:^|\s)-C(?:\s*\S+)?/.test(rawArguments)) {
    issues.push(`${context} must not use a CMake -C preload script in the input argument closure`);
  }
  for (const [flag, value] of Object.entries(expected)) {
    requireExactlyOne(issues, argumentsText, flag, value, context);
  }
  const forbidden = expected.AMCL_GLFW_API26_RAW_MOUSE_MOTION === undefined
    ? valuesOf(argumentsText, 'AMCL_GLFW_API26_RAW_MOUSE_MOTION')
    : [];
  const enabled = forbidden.filter(cmakeValueLooksEnabled);
  if (enabled.length > 0) {
    issues.push(`${context} must not enable AMCL_GLFW_API26_RAW_MOUSE_MOTION (actual=${enabled.join('|')})`);
  }
}

export function evaluateInputBuildProfile(profile) {
  const issues = [];
  if (!profile || typeof profile !== 'object') return ['module profile is not an object'];
  if (!profile.buildOption?.externalNativeOptions ||
      typeof profile.buildOption.externalNativeOptions.path !== 'string' ||
      !profile.buildOption.externalNativeOptions.path) {
    issues.push('module buildOption must retain externalNativeOptions.path');
  }
  if (profile.buildModeBinder !== undefined) {
    issues.push('module profile must not use buildModeBinder for native arguments; target closure is explicit');
  }
  const modeItems = Array.isArray(profile.buildOptionSet)
    ? profile.buildOptionSet : [];
  const modes = new Map(modeItems.map(item => [item?.name, item]));
  const seenModes = new Set();
  for (const item of modeItems) {
    const name = item?.name;
    if (typeof name !== 'string' || !name) {
      issues.push('module profile has buildOptionSet entry without a non-empty name');
      continue;
    }
    if (seenModes.has(name)) issues.push(`module profile has duplicate buildOptionSet[${name}]`);
    seenModes.add(name);
    if (name !== 'debug' && name !== 'release') {
      issues.push(`module profile has unreviewed buildOptionSet[${name}]`);
    }
  }
  for (const mode of ['debug', 'release']) {
    if (!modes.has(mode)) issues.push(`module profile missing buildOptionSet[${mode}]`);
  }

  const modeExpected = {
    debug: {
      MC_OHOS_BUILD_TESTS: 'ON',
      AMCL_GLFW_TYPED_PHYSICAL_DEFAULT: 'ON',
      AMCL_GLFW_RAW_RELATIVE_VERIFIED: 'ON',
      AMCL_GLFW_API26_RAW_MOUSE_MOTION: 'ON',
      AMCL_INPUT_COMPILED_FORMAL_DESKTOP: 'OFF',
    },
    release: {
      MC_OHOS_BUILD_TESTS: 'OFF',
      AMCL_GLFW_TYPED_PHYSICAL_DEFAULT: 'ON',
      AMCL_GLFW_RAW_RELATIVE_VERIFIED: 'ON',
      AMCL_GLFW_API26_RAW_MOUSE_MOTION: 'ON',
      AMCL_INPUT_COMPILED_FORMAL_DESKTOP: 'OFF',
    },
  };
  for (const mode of ['debug', 'release']) {
    if (modes.has(mode)) checkRoute(
      issues,
      modes.get(mode)?.externalNativeOptions?.arguments,
      modeExpected[mode],
      `buildOptionSet[${mode}]`,
    );
  }

  const expectedProducts = new Map([
    ['default', structuredClone(modeExpected)],
    ['ohosTest', structuredClone(modeExpected)],
    ['store', structuredClone(modeExpected)],
    ['sideload', structuredClone(modeExpected)],
    ['desktop', {
      debug: {
        MC_OHOS_BUILD_TESTS: 'OFF',
        AMCL_GLFW_TYPED_PHYSICAL_DEFAULT: 'ON',
        AMCL_GLFW_RAW_RELATIVE_VERIFIED: 'ON',
        AMCL_GLFW_API26_RAW_MOUSE_MOTION: 'ON',
        AMCL_INPUT_COMPILED_FORMAL_DESKTOP: 'ON',
      },
      release: {
        MC_OHOS_BUILD_TESTS: 'OFF',
        AMCL_GLFW_TYPED_PHYSICAL_DEFAULT: 'ON',
        AMCL_GLFW_RAW_RELATIVE_VERIFIED: 'ON',
        AMCL_GLFW_API26_RAW_MOUSE_MOTION: 'ON',
        AMCL_INPUT_COMPILED_FORMAL_DESKTOP: 'ON',
      },
    }],
  ]);
  // Every target closes the scalar native arguments, including product identity.
  for (const [product, productModes] of expectedProducts) {
    for (const mode of ['debug', 'release']) {
      productModes[mode] = { ...productModes[mode],
        AMCL_BUILD_PRODUCT: (product === 'ohosTest' ? 'default' : product).toUpperCase(),
        MC_OHOS_BUILD_TESTS: ['default', 'ohosTest'].includes(product) ? 'AUTO' : 'OFF' };
    }
  }
  const targets = Array.isArray(profile.targets) ? profile.targets : [];
  const targetNames = targets.map(item => item?.name);
  const invalidTargetCount = targetNames.filter(name =>
    typeof name !== 'string' || name.length === 0).length;
  if (invalidTargetCount > 0) {
    issues.push(`module profile has ${invalidTargetCount} target(s) without a non-empty name`);
  }
  const seenTargets = new Set();
  for (const name of targetNames) {
    if (typeof name !== 'string' || !name) continue;
    if (seenTargets.has(name)) issues.push(`module profile has duplicate target=${name}`);
    seenTargets.add(name);
    if (!expectedProducts.has(name)) {
      issues.push(`module profile has unreviewed target=${name}; add an explicit input route policy before shipping it`);
    }
  }
  for (const [product, productModes] of expectedProducts) {
    const target = targets.find(item => item?.name === product);
    if (!target) {
      issues.push(`module profile missing target=${product}`);
      continue;
    }
    for (const mode of ['debug', 'release']) {
      checkRoute(
        issues,
        effectiveArguments(profile, product, mode),
        productModes[mode],
        `effective ${product}/${mode}`,
      );
    }
  }
  return issues;
}

function main() {
  try {
    const profile = parseProfile(readFileSync(MODULE_PROFILE, 'utf8'));
    const issues = evaluateInputBuildProfile(profile);
    if (issues.length > 0) {
      console.error('[check-input-build-profile] FAIL');
      for (const issue of issues) console.error(`  - ${issue}`);
      process.exitCode = 1;
      return;
    }
    console.log('[check-input-build-profile] PASS');
    console.log('  effective debug/release routes: universal runtime capabilities; desktop-only strong-link closure preserved');
  } catch (error) {
    console.error(`[check-input-build-profile] ERROR: ${error.message}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
