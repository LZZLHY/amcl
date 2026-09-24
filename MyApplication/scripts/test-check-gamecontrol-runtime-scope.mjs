#!/usr/bin/env node
// Directed fixtures for check-gamecontrol-runtime-scope.mjs. Every dangerous
// direction must produce a named issue; comments/generated trees must not.

// 临时夹具及其清理边界统一使用外部宿主测试区，不修改系统 TEMP，也不回退到源码目录。
import { workspaceTempRoot } from './lib/workspace-paths.mjs';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  collectGamecontrolImports,
  validateGamecontrolRuntimeScope,
} from './check-gamecontrol-runtime-scope.mjs';

const repoRoot = resolve(fileURLToPath(new URL('..', import.meta.url)));

function write(root, path, content) {
  const target = join(root, path);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, content, 'utf8');
}

function buildFixture() {
  const root = mkdtempSync(join(workspaceTempRoot(), 'amcl-gamecontrol-scope-'));
  write(root, 'build-profile.json5', `{
    "modules": [
      { "name": "entry", "srcPath": "./entry" },
      { "name": "gamecontrol", "srcPath": "./gamecontrol" },
      { "name": "feature_core", "srcPath": "./feature_core" },
    ]
  }
  `);
  write(root, 'entry/oh-package.json5', `{
    "name": "entry",
    "dependencies": { "gamecontrol": "file:../gamecontrol" }
  }
  `);
  write(root, 'gamecontrol/oh-package.json5', `{
    "name": "gamecontrol",
    "dependencies": {}
  }
  `);
  write(root, 'feature_core/oh-package.json5', `{
    "name": "feature_core",
    "dependencies": {}
  }
  `);
  write(root, 'entry/src/main/module.json5', `{
    "module": {
      "name": "entry",
      "type": "entry",
      "abilities": [{
        // Historical text is not an executable declaration:
        // "process": ":old_game"
        "name": "EntryAbility",
        "srcEntry": "./ets/entryability/EntryAbility.ets"
      }]
    }
  }
  `);
  write(root, 'gamecontrol/src/main/module.json5', `{
    "module": { "name": "gamecontrol", "type": "har" }
  }
  `);
  write(root, 'feature_core/src/main/module.json5', `{
    "module": { "name": "feature_core", "type": "har" }
  }
  `);
  write(root, 'entry/src/main/ets/entryability/EntryAbility.ets', `
    import { getInputSourceRegistry } from 'gamecontrol'
    const ignored = "import { fake } from 'gamecontrol'"
    const template = \`export { fake } from 'gamecontrol'\`
    // import { commented } from 'gamecontrol'
    export const marker = getInputSourceRegistry
  `);
  write(root, 'gamecontrol/Index.ets', 'export const marker = 1\n');
  write(root, 'feature_core/src/main/ets/Feature.ets', 'export const marker = 1\n');
  return root;
}

let failures = 0;

function expectClean(issues) {
  return issues.length === 0 ? null : `expected no issues, got ${issues.join(' | ')}`;
}

function expectIssue(pattern) {
  return issues => issues.some(issue => pattern.test(issue))
    ? null : `expected issue matching ${pattern}, got ${issues.join(' | ') || '(none)'}`;
}

function check(label, mutate, expectation) {
  const root = buildFixture();
  try {
    if (mutate) mutate(root);
    const issues = validateGamecontrolRuntimeScope(root);
    const problem = expectation(issues);
    if (problem) {
      failures += 1;
      console.error(`[test-gamecontrol-runtime-scope] FAIL: ${label} — ${problem}`);
    } else {
      console.log(`[test-gamecontrol-runtime-scope] PASS: ${label}`);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

check('known-good sole entry owner', null, expectClean);

function desktopFixture(root) {
  for (const path of ['entry/src/main/ets/gameability/GameAbility.ets', 'entry/src/main/ets/runtime/ProcessRuntime.ets']) {
    write(root, path, readFileSync(join(repoRoot, path), 'utf8'));
  }
  write(root, 'entry/src/main/module.json5', JSON.stringify({module:{name:'entry',type:'entry',abilities:[{
    name:'GameAbility',srcEntry:'./ets/gameability/GameAbility.ets',process:':game',launchType:'singleton',exported:false
  }]}}));
}
check('named desktop process with its own initialization', desktopFixture, expectClean);
for (const required of ['setControlNativeSink', 'DiagnosticPolicy.configure', 'DistributionPolicy.configure', 'ProductInputProfile.initialize']) {
  check(`desktop initializer must retain ${required}`, root => {
    desktopFixture(root);
    const path='entry/src/main/ets/runtime/ProcessRuntime.ets';
    write(root,path,readFileSync(join(root,path),'utf8').replaceAll(required, 'missingRuntimeHook'));
  }, expectIssue(/process=/));
}
check('desktop process cannot omit PID guard', root => {
  desktopFixture(root);const path='entry/src/main/ets/gameability/GameAbility.ets';
  write(root,path,readFileSync(join(root,path),'utf8').replaceAll('desktopGameProcessState','missingPidGuard'));
}, expectIssue(/process=/));
check('comments and strings cannot replace desktop initialization', root => {
  desktopFixture(root);const path='entry/src/main/ets/runtime/ProcessRuntime.ets';
  write(root,path,'// '+readFileSync(join(root,path),'utf8').replaceAll('\n','\n// ')+'\nconst fake="setControlNativeSink (";');
}, expectIssue(/process=/));
check('approved desktop does not authorize a third process', root => {
  desktopFixture(root);const path='entry/src/main/module.json5';const m=JSON.parse(readFileSync(join(root,path),'utf8'));
  m.module.abilities.push({name:'OtherAbility',process:':other'});write(root,path,JSON.stringify(m));
}, expectIssue(/:other/));

check('second module dependency by package name', root => {
  write(root, 'feature_core/oh-package.json5', `{
    "name": "feature_core",
    "dependencies": { "gamecontrol": "file:../gamecontrol" }
  }
  `);
}, expectIssue(/feature_core\/dependencies depends on gamecontrol/));

check('aliased file dependency still targets gamecontrol', root => {
  write(root, 'feature_core/oh-package.json5', `{
    "name": "feature_core",
    "dependencies": { "controls_alias": "file:../gamecontrol" }
  }
  `);
}, expectIssue(/feature_core\/dependencies depends on gamecontrol/));

check('second module devDependency is still a second HAR owner', root => {
  write(root, 'feature_core/oh-package.json5', `{
    "name": "feature_core",
    "devDependencies": { "gamecontrol": "file:../gamecontrol" }
  }
  `);
}, expectIssue(/feature_core\/devDependencies depends on gamecontrol/));

check('source import outside entry and gamecontrol', root => {
  write(root, 'feature_core/src/main/ets/Feature.ets', `
    import {
      GamepadManager
    } from "gamecontrol"
    export const marker = GamepadManager
  `);
}, expectIssue(/Feature\.ets:\d+ imports 'gamecontrol' outside entry\/gamecontrol/));

check('re-export outside entry and gamecontrol', root => {
  write(root, 'feature_core/src/main/ets/Feature.ets', `
    export { GamepadManager } from 'gamecontrol'
  `);
}, expectIssue(/imports 'gamecontrol' outside entry\/gamecontrol/));

check('side-effect import outside entry and gamecontrol', root => {
  write(root, 'feature_core/src/main/ets/Feature.ets', `
    import 'gamecontrol'
  `);
}, expectIssue(/imports 'gamecontrol' outside entry\/gamecontrol/));

check('entry consumer assigned explicit second process', root => {
  write(root, 'entry/src/main/module.json5', `{
    "module": {
      "name": "entry",
      "type": "entry",
      "abilities": [{
        "name": "EntryAbility",
        "srcEntry": "./ets/entryability/EntryAbility.ets",
        "process": ":input_worker"
      }]
    }
  }
  `);
}, expectIssue(/declares process=.*separate process runtime contract/));

check('entry consumer assigned isolated process', root => {
  write(root, 'entry/src/main/module.json5', `{
    "module": {
      "name": "entry",
      "type": "entry",
      "abilities": [{
        "name": "EntryAbility",
        "srcEntry": "./ets/entryability/EntryAbility.ets",
        "isolationProcess": true
      }]
    }
  }
  `);
}, expectIssue(/enables an isolated process/));

check('entry consumer extension per-type process mode', root => {
  write(root, 'entry/src/main/module.json5', `{
    "module": {
      "name": "entry",
      "type": "entry",
      "extensionAbilities": [{
        "name": "InputExtension",
        "srcEntry": "./ets/InputExtension.ets",
        "extensionProcessMode": "type"
      }]
    }
  }
  `);
}, expectIssue(/extensionProcessMode=.*type/));

check('missing entry runtime dependency', root => {
  write(root, 'entry/oh-package.json5', `{
    "name": "entry",
    "dependencies": {}
  }
  `);
}, expectIssue(/entry\/dependencies must declare gamecontrol/));

check('entry dependency cannot resolve to a registry copy', root => {
  write(root, 'entry/oh-package.json5', `{
    "name": "entry",
    "dependencies": { "gamecontrol": "1.0.0" }
  }
  `);
}, expectIssue(/must resolve to the project HAR/));

check('gate fails closed when the HAR contract changes to HSP', root => {
  write(root, 'gamecontrol/src/main/module.json5', `{
    "module": { "name": "gamecontrol", "type": "shared" }
  }
  `);
}, expectIssue(/expects module\.type="har"/));

check('malformed module package fails closed', root => {
  write(root, 'feature_core/oh-package.json5', '{ "dependencies": ');
}, expectIssue(/feature_core oh-package\.json5 is not parseable/));

check('module srcPath outside repository fails closed', root => {
  write(root, 'build-profile.json5', `{
    "modules": [
      { "name": "entry", "srcPath": "./entry" },
      { "name": "gamecontrol", "srcPath": "./gamecontrol" },
      { "name": "escaped", "srcPath": "../escaped" }
    ]
  }
  `);
}, expectIssue(/srcPath escapes repository root/));

check('generated oh_modules source is ignored', root => {
  write(root, 'feature_core/oh_modules/generated/Bad.ets', `
    import { GamepadManager } from 'gamecontrol'
  `);
}, expectClean);

check('gamecontrol self-source is inside the allowed ownership boundary', root => {
  write(root, 'gamecontrol/src/main/ets/Self.ets', `
    export { marker } from 'gamecontrol'
  `);
}, expectClean);

{
  const text = `
    // import { fake } from 'gamecontrol'
    const a = "export { fake } from 'gamecontrol'"
    const b = \`import { fake } from 'gamecontrol'\`
    export const from = 'gamecontrol'
  `;
  const imports = collectGamecontrolImports(text);
  if (imports.length === 0) {
    console.log('[test-gamecontrol-runtime-scope] PASS: comments and strings cannot forge imports');
  } else {
    failures += 1;
    console.error('[test-gamecontrol-runtime-scope] FAIL: comments or strings forged an import');
  }
}

{
  const text = `
    import('gamecontrol')
    export type { GamepadEmitter } from 'gamecontrol'
  `;
  const imports = collectGamecontrolImports(text);
  if (imports.length === 2) {
    console.log('[test-gamecontrol-runtime-scope] PASS: dynamic import and type re-export are detected');
  } else {
    failures += 1;
    console.error(`[test-gamecontrol-runtime-scope] FAIL: expected 2 import tokens, got ${imports.length}`);
  }
}

{
  const issues = validateGamecontrolRuntimeScope(repoRoot);
  if (issues.length === 0) {
    console.log('[test-gamecontrol-runtime-scope] PASS: real repository');
  } else {
    failures += 1;
    console.error('[test-gamecontrol-runtime-scope] FAIL: real repository');
    for (const issue of issues) console.error(`  ${issue}`);
  }
}

if (failures > 0) {
  console.error(`[test-gamecontrol-runtime-scope] ${failures} case(s) failed`);
  process.exitCode = 1;
} else {
  console.log('[test-gamecontrol-runtime-scope] ALL PASS');
}
