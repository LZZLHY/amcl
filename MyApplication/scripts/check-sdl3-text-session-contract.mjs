#!/usr/bin/env node
/* Gate D SDL follow-up patch: typed text must be additive, owned and explicit. */
import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
const SERIES = path.join(ROOT, 'prebuilt', 'sdl3', 'patches', 'series');
const PATCH = path.join(ROOT, 'prebuilt', 'sdl3', 'patches',
  '0006-openharmony-typed-text-session.patch');

export function analyzeTextSessionContract({ seriesText, patchText }) {
  const checks = [];
  const requireText = (label, pattern) => {
    checks.push({ label, ok: pattern.test(patchText) });
  };
  const names = seriesText.split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#'));
  checks.push({
    label: '0005 remains before additive 0006',
    ok: names.indexOf('0005-openharmony-pointer-device-identity.patch') >= 0 &&
      names.indexOf('0006-openharmony-typed-text-session.patch') ===
        names.indexOf('0005-openharmony-pointer-device-identity.patch') + 1,
  });
  checks.push({ label: '0006 is a follow-up patch (not a replacement)',
    ok: patchText.includes('diff --git a/src/video/openharmony/SDL_openharmonyamcl.c') &&
      !patchText.includes('new file mode') });
  requireText('64-byte backend envelope stays asserted',
    /64-byte backend envelope|64 bytes|sizeof\(AMCL_BackendInputEvent\) == 64/);
  requireText('text event types 10..14 are additive',
    /AMCL_BACKEND_EVENT_TEXT_SESSION 10u[\s\S]*AMCL_BACKEND_EVENT_TEXT_COMMIT 11u[\s\S]*AMCL_BACKEND_EVENT_TEXT_EDITING 12u[\s\S]*AMCL_BACKEND_EVENT_TEXT_CANDIDATES 13u[\s\S]*AMCL_BACKEND_EVENT_TEXT_SELECTION 14u/);
  requireText('independent owned-text descriptor',
    /AMCL_TEXT_BRIDGE_ENV[\s\S]*AMCLBETV:1:[\s\S]*TextRead[\s\S]*TextRelease/);
  requireText('strict UTF-8 validation',
    /OPENHARMONY_ValidUtf8Bytes[\s\S]*d800[\s\S]*10ffff/);
  requireText('read, copy and release on commit/editing',
    /OPENHARMONY_ReadAndReleaseText[\s\S]*AMCL_BACKEND_EVENT_TEXT_COMMIT[\s\S]*SDL_SendKeyboardText[\s\S]*AMCL_BACKEND_EVENT_TEXT_EDITING[\s\S]*SDL_SendEditingText/);
  requireText('candidate metadata and page are validated',
    /AMCL_BACKEND_EVENT_TEXT_CANDIDATES[\s\S]*text-candidate-page[\s\S]*SDL_SendEditingTextCandidates/);
  requireText('selection is explicit degradation',
    /AMCL_BACKEND_EVENT_TEXT_SELECTION[\s\S]*OPENHARMONY_RecordTextDegradation/);
  requireText('session END/ABORT clears editing',
    /AMCL_BACKEND_EVENT_TEXT_SESSION[\s\S]*SDL_SendEditingText\("", 0, 0\)/);
  requireText('RESET clears active preedit with held input',
    /case AMCL_BACKEND_EVENT_RESET:[\s\S]*?SDL_ResetKeyboard\(\)[\s\S]*?OPENHARMONY_ReleaseHeldMouseButtons[\s\S]*?SDL_SendEditingText\("", 0, 0\)/);
  requireText('malformed and packet-read failures are observable',
    /amcl_typed_text_degraded_editing[\s\S]*commit-read/);
  return {
    ok: checks.every((check) => check.ok),
    checks,
  };
}

export function readContract(root = ROOT) {
  const seriesPath = path.join(root, 'prebuilt', 'sdl3', 'patches', 'series');
  const patchPath = path.join(root, 'prebuilt', 'sdl3', 'patches',
    '0006-openharmony-typed-text-session.patch');
  return {
    seriesText: fs.readFileSync(seriesPath, 'utf8'),
    patchText: fs.readFileSync(patchPath, 'utf8'),
  };
}

function main() {
  let report;
  try {
    report = analyzeTextSessionContract(readContract());
  } catch (error) {
    console.error(`[check-sdl3-text-session-contract] FAIL: ${error.message}`);
    process.exitCode = 1;
    return;
  }
  for (const check of report.checks) {
    console.log(`${check.ok ? 'PASS' : 'FAIL'} ${check.label}`);
  }
  if (!report.ok) process.exitCode = 1;
  else console.log('SDL3 typed text-session contract: PASS');
}

if (process.argv[1] && path.resolve(process.argv[1]) ===
    path.resolve(url.fileURLToPath(import.meta.url))) main();
