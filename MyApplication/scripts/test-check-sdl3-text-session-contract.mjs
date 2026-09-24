#!/usr/bin/env node
import { analyzeTextSessionContract } from './check-sdl3-text-session-contract.mjs';

const good = `
0005-openharmony-pointer-device-identity.patch
0006-openharmony-typed-text-session.patch
`;
const patch = `
diff --git a/src/video/openharmony/SDL_openharmonyamcl.c
 static_assert(sizeof(AMCL_BackendInputEvent) == 64);
 #define AMCL_BACKEND_EVENT_TEXT_SESSION 10u
 #define AMCL_BACKEND_EVENT_TEXT_COMMIT 11u
 #define AMCL_BACKEND_EVENT_TEXT_EDITING 12u
 #define AMCL_BACKEND_EVENT_TEXT_CANDIDATES 13u
 #define AMCL_BACKEND_EVENT_TEXT_SELECTION 14u
 #define AMCL_TEXT_BRIDGE_ENV "AMCLBETV:1:"
 TextRead TextRelease
 static bool OPENHARMONY_ValidUtf8Bytes(Uint8 *x) { d800 10ffff; }
 OPENHARMONY_ReadAndReleaseText
 case AMCL_BACKEND_EVENT_TEXT_COMMIT: SDL_SendKeyboardText
 case AMCL_BACKEND_EVENT_TEXT_EDITING: SDL_SendEditingText
 case AMCL_BACKEND_EVENT_TEXT_CANDIDATES: text-candidate-page SDL_SendEditingTextCandidates
 case AMCL_BACKEND_EVENT_TEXT_SELECTION: OPENHARMONY_RecordTextDegradation
 case AMCL_BACKEND_EVENT_TEXT_SESSION: SDL_SendEditingText("", 0, 0)
 case AMCL_BACKEND_EVENT_RESET: SDL_ResetKeyboard() OPENHARMONY_ReleaseHeldMouseButtons SDL_SendEditingText("", 0, 0)
 amcl_typed_text_degraded_editing commit-read
`;

function check(label, value) {
  if (!value) throw new Error(`FAIL ${label}`);
  console.log(`PASS ${label}`);
}

check('known-good fixture', analyzeTextSessionContract({
  seriesText: good, patchText: patch,
}).ok);
check('missing release fails closed', !analyzeTextSessionContract({
  seriesText: good, patchText: patch.replace('TextRelease', ''),
}).ok);
check('RESET without preedit clear fails closed', !analyzeTextSessionContract({
  seriesText: good,
  patchText: patch.replace(
    'case AMCL_BACKEND_EVENT_RESET: SDL_ResetKeyboard() OPENHARMONY_ReleaseHeldMouseButtons SDL_SendEditingText("", 0, 0)',
    'case AMCL_BACKEND_EVENT_RESET: SDL_ResetKeyboard() OPENHARMONY_ReleaseHeldMouseButtons'),
}).ok);
check('0006 before 0005 fails closed', !analyzeTextSessionContract({
  seriesText: '0006-openharmony-typed-text-session.patch\n0005-openharmony-pointer-device-identity.patch\n',
  patchText: patch,
}).ok);
check('legacy replacement/new-file fixture fails closed', !analyzeTextSessionContract({
  seriesText: good, patchText: patch.replace('diff --git', 'new file mode\ndiff --git'),
}).ok);
console.log('[test-check-sdl3-text-session-contract] ALL PASS');
