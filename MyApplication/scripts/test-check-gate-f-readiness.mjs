#!/usr/bin/env node
// check-gate-f-readiness.mjs 的无落盘 fixture 自测。
//
// 自测刻意区分“当前安全”与“迁移完成”：空实现 + 两证据 OFF 必须 DORMANT/PASS；
// 同一份空实现只要批准任一证据或尝试打开 bit14 就必须 BLOCKED。只有生产者、owner、
// 三后端组合消费、physical legacy 退役及 touch 合同全部出现，才允许 READY。

import {
  analyzeSdlPatchViews,
  analyzeGateFReadiness,
  findGateFProfileEnablements,
  gateFCmakeValueLooksEnabled,
  readGateFSources,
  stripGateFCode,
} from './check-gate-f-readiness.mjs';

let failures = 0;

function check(name, condition, detail = '') {
  if (condition) {
    console.log(`  ok   ${name}`);
    return;
  }
  failures += 1;
  console.error(`  FAIL ${name}${detail ? `\n       ${detail}` : ''}`);
}

function manifest(absoluteApproved = false, timestampApproved = false) {
  return JSON.stringify({
    schemaVersion: 1,
    capabilities: {
      AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED: {
        approved: absoluteApproved,
      },
      AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED: {
        approved: timestampApproved,
      },
    },
  });
}

function blankFixture({
  absoluteApproved = false,
  timestampApproved = false,
  profileText = '{ "targets": [] }',
} = {}) {
  return {
    missing: [],
    manifestText: manifest(absoluteApproved, timestampApproved),
    profileText,
    policyHeaderText: '',
    policySourceText: '',
    policyTestText: '',
    nativeRouteHeaderText: 'enum class ArktsPhysicalMotionRoute { LegacyMenuAbsolute };',
    nativeRouteSourceText: 'auto route = ArktsPhysicalMotionRoute::LegacyMenuAbsolute;',
    ingressHeaderText: '',
    ingressSourceText: '',
    touchText: '',
    napiText: 'ohos_send_cursor_pos_checked(x, y); // active physical legacy writer',
    pageText: '',
    eventHeaderText: '',
    adapterHeaderText: '',
    adapterSourceText: '',
    backendHeaderText: '',
    backendSourceText: '',
    glfwText: '',
    lwjglBridgeText: '',
    lwjglTranslateHeaderText: '',
    lwjglTranslateSourceText: '',
    backendPointerTestText: '',
    physicalLegacyTestText: '',
    hostCmakeText: '',
    sdlSeriesText: '',
    sdlPatchText: '',
    sdlGateFFinalPatchText: '',
  };
}

function fullFixture({
  absoluteApproved = true,
  timestampApproved = true,
  profileText = '{ "name": "desktop", "arguments": "-DAMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED=ON" }',
} = {}) {
  const f = blankFixture({ absoluteApproved, timestampApproved, profileText });
  f.policyHeaderText = `
    bool amcl_input_policy_left_begin_atomic_menu(AmclInputChannel channel,
                                                   bool coordinatesBound);
  `;
  f.policySourceText = `
    bool amcl_input_policy_left_begin_atomic_menu(AmclInputChannel channel,
                                                   bool coordinatesBound) {
      return coordinatesBound && channel != AMCL_INPUT_CHANNEL_NONE;
    }
  `;
  f.policyTestText = `
    void TestGateFOwnerAtomicRoute() {
      auto a = AMCL_INPUT_CHANNEL_ARKUI_MOUSE;
      auto n = AMCL_INPUT_CHANNEL_NATIVE_MOUSE;
    }
  `;
  f.nativeRouteHeaderText = 'enum class ArktsPhysicalMotionRoute { NativeMenuAbsoluteOwner };';
  f.nativeRouteSourceText = 'return ArktsPhysicalMotionRoute::NativeMenuAbsoluteOwner;';
  f.ingressHeaderText = `
    PlatformInputNativeMouseResult PlatformInputMenuPointerTransaction(
      uint64_t generation, double x, double y, uint64_t device,
      uint32_t button, uint32_t action);
  `;
  f.ingressSourceText = `
    PlatformInputNativeMouseResult PlatformInputMenuPointerTransaction(
        uint64_t generation, double x, double y, uint64_t device,
        uint32_t button, uint32_t action) {
      AmclInputEvent events[2] = {};
      events[1].header.flags |= AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND;
      return SubmitBatchLocked(events, 2u) == AMCL_INPUT_OK
        ? PlatformInputNativeMouseResult::Submitted
        : PlatformInputNativeMouseResult::SubmitFailed;
    }
  `;
  // 两个 route-aware owner 调用 + 两个统一 transaction 调用分别代表 ArkUI/native 入口。
  // 同时保留真实 touch MENU_POINTER 的 token/cancel/present 合同。
  f.touchText = `
    if (amcl_input_policy_left_begin_atomic_menu(
          AMCL_INPUT_CHANNEL_ARKUI_MOUSE, true)) {
      PlatformInputMenuPointerTransaction(generation, x, y, device, button, action);
    }
    if (amcl_input_policy_left_begin_atomic_menu(
          AMCL_INPUT_CHANNEL_NATIVE_MOUSE, true)) {
      PlatformInputMenuPointerTransaction(generation, x, y, device, button, action);
    }
    int s_activeMenuTransactionToken = 1;
    sendEvent(EVENT_TYPE_MENU_POINTER, MENU_POINTER_DOWN, x, y,
              s_activeMenuTransactionToken);
    sendEvent(EVENT_TYPE_MENU_POINTER, MENU_POINTER_MOVE, x, y,
              s_activeMenuTransactionToken);
    sendEvent(EVENT_TYPE_MENU_POINTER, MENU_POINTER_UP, x, y,
              s_activeMenuTransactionToken);
    sendEvent(EVENT_TYPE_MENU_POINTER, MENU_POINTER_CANCEL, 0, 0,
              s_activeMenuTransactionToken);
  `;
  // 严格退役形态：不再出现 LegacyMenuAbsolute 或物理 cursor mailbox writer。
  f.napiText = 'void PhysicalMenuRouteUsesTypedTransaction() {}';
  f.adapterHeaderText = `
    using GlfwAbsoluteButtonSinkFn = void (*)(void*, const GlfwAbsoluteButtonSinkEvent&);
    struct GlfwInputSink {
      GlfwAbsoluteButtonSinkFn absoluteButton = nullptr;
      GlfwMenuPointerSinkFn menuPointer = nullptr;
    };
  `;
  f.adapterSourceText = `
    if (event.requiresAbsoluteAuthorization && sink.absoluteButton) {
      sink.absoluteButton(sink.context, combined);
    }
  `;
  f.backendHeaderText = `
    #define AMCL_BACKEND_INPUT_LWJGL2 2u
    #define AMCL_BACKEND_INPUT_SDL3 3u
    #define AMCL_BACKEND_INPUT_EVENT_POINTER_TRANSACTION 15u
  `;
  f.backendSourceText = `
    void PointerTransactionSink(void* context,
                                const GlfwAbsoluteButtonSinkEvent& event) {
      AmclBackendInputEvent out = BlankEvent(
        AMCL_BACKEND_INPUT_EVENT_POINTER_TRANSACTION);
      EnqueueLocked(static_cast<BackendChannel*>(context), out);
    }
    GlfwInputSink SinkFor(BackendChannel* channel) {
      GlfwInputSink sink{};
      sink.absoluteButton = PointerTransactionSink;
      return sink;
    }
  `;
  f.glfwText = `
    void typedAbsoluteButtonSink(void*, const GlfwAbsoluteButtonSinkEvent& event) {
      GlfwTypedRuntimeCommitAbsolute(route, event.absolute, target, publication, absolute);
      GlfwTypedRuntimeCommitButton(route, aggregate, event.button, target, publication, button);
    }
    GlfwInputSink typedInputSink() {
      GlfwInputSink sink{};
      sink.absoluteButton = typedAbsoluteButtonSink;
      return sink;
    }
  `;
  f.lwjglTranslateHeaderText = `
    int amclConsumeBackendPointerTransactionLwjgl2(
      const AmclBackendInputEvent* event, AmclLwjgl2WireEvent* out);
  `;
  f.lwjglTranslateSourceText = `
    int amclConsumeBackendPointerTransactionLwjgl2(
        const AmclBackendInputEvent* event, AmclLwjgl2WireEvent* out) {
      if (event->eventType != AMCL_BACKEND_INPUT_EVENT_POINTER_TRANSACTION) return 0;
      return 1;
    }
  `;
  f.lwjglBridgeText = `
    int l2NextTypedEvent() {
      if (ev.eventType == AMCL_BACKEND_INPUT_EVENT_POINTER_TRANSACTION) {
        inputBridge_setMenuCursor(ev.wheelX, ev.wheelY);
        return amclConsumeBackendPointerTransactionLwjgl2(&ev, &wire);
      }
      return 0;
    }
    void legacyTouchMenu() {
      switch (event.type) {
        case EVENT_TYPE_MENU_POINTER:
          g_menuTransactionToken = event.i4;
          g_menuPressAfterPresent = presentSerial + 2;
          if (event.i1 == MENU_POINTER_CANCEL) g_menuTransactionToken = 0;
          break;
      }
    }
  `;
  f.backendPointerTestText = `
    void TestGateFBackendPointerTransaction() {
      TestBackend(AMCL_BACKEND_INPUT_LWJGL2);
      TestBackend(AMCL_BACKEND_INPUT_SDL3);
    }
  `;
  f.hostCmakeText = `
    add_executable(amcl_backend_pointer_transaction_test
      backend_pointer_transaction_test.cpp)
  `;
  f.sdlPatchText = `
    #define AMCL_EVENT_MENU_POINTER 1008
    #define AMCL_MENU_POINTER_DOWN 1
    switch (event.eventType) {
      case AMCL_BACKEND_INPUT_EVENT_POINTER_TRANSACTION:
        SDL_SendMouseMotion(event.time, window, event.device, false, event.x, event.y);
        SDL_SendMouseButton(event.time, window, event.device, event.button, event.down);
        break;
    }
  `;
  f.sdlGateFFinalPatchText = f.sdlPatchText;
  return f;
}

function mutate(fixture, key, from, to) {
  const before = fixture[key];
  const hit = typeof from === 'string' ? before.includes(from) : from.test(before);
  if (!hit) throw new Error(`fixture broken: ${key} does not contain ${from}`);
  const after = before.replace(from, to);
  if (after === before) throw new Error(`fixture broken: ${key} mutation was a no-op`);
  return { ...fixture, [key]: after };
}

function prerequisite(report, id) {
  return report.prerequisites.find(item => item.id === id);
}

// 1. 真实仓库必须明确处于 DORMANT。不要断言其它组 pending：施工可能先把 dormant
// 代码补齐，但在证据与产品配置仍 OFF 时状态依然应是安全的 DORMANT。
{
  const report = analyzeGateFReadiness(readGateFSources());
  check('real repo is explicitly DORMANT/PASS',
    report.ok && report.state === 'DORMANT' && !report.activationRequested,
    JSON.stringify(report.issues));
  check('real repo keeps both evidence entries unapproved',
    !report.evidence.absoluteApproved && !report.evidence.timestampApproved,
    JSON.stringify(report.evidence));
  check('real repo recognizes the preserved touch MENU_POINTER contract',
    prerequisite(report, 'touch-menu-pointer-contract')?.ok === true &&
      prerequisite(report, 'touch-menu-pointer-contract')?.mode === 'preserved-legacy',
    JSON.stringify(prerequisite(report, 'touch-menu-pointer-contract')));
}

// 2. 安全态不要求未来实现已经存在；否则门禁会把“保持 bit14 OFF”错误地变成构建阻塞。
{
  const report = analyzeGateFReadiness(blankFixture());
  check('empty implementation + evidence/profile OFF => DORMANT/PASS',
    report.ok && report.state === 'DORMANT');
  check('DORMANT does not claim prerequisites are ready',
    report.prerequisites.some(item => !item.ok));
}

// 3. 任一证据开始批准，空实现必须立刻 fail closed。
{
  const report = analyzeGateFReadiness(blankFixture({ timestampApproved: true }));
  check('timestamp approval alone activates readiness gate',
    report.activationRequested && report.state === 'BLOCKED');
  check('timestamp approval reports all incomplete prerequisite groups',
    ['owner-atomic-route', 'three-backend-pointer-transaction',
      'physical-legacy-retired', 'touch-menu-pointer-contract']
      .every(id => report.issues.some(issue => issue.includes(`'${id}'`))),
    JSON.stringify(report.issues));
}
{
  const report = analyzeGateFReadiness(blankFixture({ absoluteApproved: true }));
  check('absolute approval without timestamp is blocked',
    !report.ok && report.issues.some(issue => issue.includes('timestamp dependency')),
    JSON.stringify(report.issues));
}

// 4. 产品配置提前打开 bit14：常见 CMake 真值写法都必须被识别。注释与明确假值不触发。
for (const value of ['ON', '1', 'TRUE', 'YES', '2', '00', 'anything']) {
  const profileText = `{ "name":"desktop", "arguments":"-DAMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED:BOOL=${value}" }`;
  const report = analyzeGateFReadiness(blankFixture({ profileText }));
  check(`desktop bit14=${value} is an activation attempt and fails closed`,
    report.activationRequested && !report.ok &&
      report.issues.some(issue => issue.includes('before both Gate F evidence')),
    JSON.stringify(report.issues));
}
for (const value of ['OFF', '0', 'NO', 'FALSE', 'IGNORE', 'NOTFOUND']) {
  const profileText = `{ "arguments":"-DAMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED=${value}" }`;
  const report = analyzeGateFReadiness(blankFixture({ profileText }));
  check(`explicit false bit14=${value} stays DORMANT`,
    report.ok && report.state === 'DORMANT');
}
{
  const profileText = `{
    // -DAMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED=ON is documentation, not an argument
    "arguments":""
  }`;
  const report = analyzeGateFReadiness(blankFixture({ profileText }));
  check('comment-only bit14 token does not activate',
    report.ok && report.state === 'DORMANT' && !report.activationRequested);
}
{
  const profileText = '{"note":"https://example.invalid/a",' +
    '"arguments":"-DAMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED=ON"}';
  const report = analyzeGateFReadiness(blankFixture({ profileText }));
  check('a // sequence inside a JSON string cannot hide a later bit14 argument',
    report.activationRequested && !report.ok,
    JSON.stringify(report.issues));
}
check('CMake helper treats 00 as enabled (matches Gate0Evidence.cmake safety side)',
  gateFCmakeValueLooksEnabled('00'));
check('profile parser supports quoted/type-suffixed form',
  findGateFProfileEnablements(
    '{"arguments":"-DAMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED:BOOL=\\\"1\\\""}')
    .length === 1);

// 5. 即使所有代码先决条件齐全，产品 profile 也不能越过两份证据批准。
{
  const report = analyzeGateFReadiness(fullFixture({
    absoluteApproved: false,
    timestampApproved: false,
  }));
  check('complete code cannot authorize an unapproved product profile',
    !report.ok && report.issues.some(issue => issue.includes('before both Gate F evidence')),
    JSON.stringify(report.issues));
}

// 6. 全部契约齐全 + 两份批准 + 产品尝试启用，才是 READY。
{
  const report = analyzeGateFReadiness(fullFixture());
  check('all prerequisites + approved evidence + profile enable => READY/PASS',
    report.ok && report.state === 'READY' && report.activationRequested,
    JSON.stringify(report.issues));
  check('READY means all four prerequisite groups are mechanically present',
    report.prerequisites.length === 4 && report.prerequisites.every(item => item.ok),
    JSON.stringify(report.prerequisites));
  check('strict physical legacy removal is recognized',
    prerequisite(report, 'physical-legacy-retired')?.mode === 'removed');
  check('preserved touch contract remains valid alongside physical retirement',
    prerequisite(report, 'touch-menu-pointer-contract')?.mode === 'preserved-legacy');
}

// timestamp 本身可以先获得证据；只要 Gate F 源码先决条件已经完整，门禁允许 READY，
// 但没有 product enablement，因此它不声称 bit14 已出货。
{
  const report = analyzeGateFReadiness(fullFixture({
    absoluteApproved: false,
    timestampApproved: true,
    profileText: '{"arguments":""}',
  }));
  check('timestamp-only approval is allowed only after all source prerequisites exist',
    report.ok && report.state === 'READY' && report.profileEnablements.length === 0,
    JSON.stringify(report.issues));
}

// 7. 从完整 fixture 各摘一组，必须只要缺一组就红。
{
  const report = analyzeGateFReadiness(mutate(fullFixture(), 'policyHeaderText',
    'amcl_input_policy_left_begin_atomic_menu',
    'amcl_input_policy_left_begin_non_atomic'));
  check('missing owner atomic contract blocks activation',
    !report.ok && report.issues.some(issue => issue.includes("'owner-atomic-route'")),
    JSON.stringify(report.issues));
}
{
  const report = analyzeGateFReadiness(mutate(fullFixture(), 'backendHeaderText',
    '#define AMCL_BACKEND_INPUT_EVENT_POINTER_TRANSACTION 15u', ''));
  check('missing backend combined event blocks activation',
    !report.ok && report.issues.some(
      issue => issue.includes("'three-backend-pointer-transaction'")),
    JSON.stringify(report.issues));
}
{
  const report = analyzeGateFReadiness(mutate(fullFixture(),
    'sdlGateFFinalPatchText',
    'SDL_SendMouseMotion(event.time, window, event.device, false, event.x, event.y);\n        SDL_SendMouseButton(event.time, window, event.device, event.button, event.down);',
    'break;'));
  check('empty SDL pointer case cannot borrow motion/button tokens from other cases',
    !report.ok && report.issues.some(
      issue => issue.includes("'three-backend-pointer-transaction'")),
    JSON.stringify(report.issues));
}
{
  const fixture = fullFixture();
  fixture.sdlGateFFinalPatchText = `#if 0\n${fixture.sdlGateFFinalPatchText}\n#endif`;
  const report = analyzeGateFReadiness(fixture);
  check('SDL pointer consumer hidden by conditional compilation cannot pass READY',
    !report.ok && report.issues.some(
      issue => issue.includes("'three-backend-pointer-transaction'")),
    JSON.stringify(report.issues));
}
{
  const report = analyzeGateFReadiness({
    ...fullFixture(),
    napiText: 'case LegacyMenuAbsolute: ohos_send_cursor_pos_checked(x, y);',
  });
  check('active physical legacy writer blocks activation',
    !report.ok && report.issues.some(issue => issue.includes("'physical-legacy-retired'")),
    JSON.stringify(report.issues));
}
{
  const fixture = fullFixture();
  fixture.touchText = `
    amcl_input_policy_left_begin_atomic_menu(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, true);
    PlatformInputMenuPointerTransaction(generation, x, y, device, button, action);
    amcl_input_policy_left_begin_atomic_menu(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, true);
    PlatformInputMenuPointerTransaction(generation, x, y, device, button, action);
  `;
  const report = analyzeGateFReadiness(fixture);
  check('removing touch MENU_POINTER without replacement blocks activation',
    !report.ok && report.issues.some(issue => issue.includes("'touch-menu-pointer-contract'")),
    JSON.stringify(report.issues));
}

// 8. touch 可以不是永久 legacy：typed 等价替代的完整符号集合也应通过。
{
  const fixture = fullFixture();
  fixture.touchText = `
    amcl_input_policy_left_begin_atomic_menu(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, true);
    PlatformInputMenuPointerTransaction(generation, x, y, device, button, action);
    amcl_input_policy_left_begin_atomic_menu(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, true);
    PlatformInputMenuPointerTransaction(generation, x, y, device, button, action);
    PlatformInputTouchMenuPointerTransaction(token, phase, x, y);
  `;
  fixture.eventHeaderText = '#define AMCL_INPUT_EVENT_MENU_POINTER_TRANSACTION 20u';
  fixture.adapterHeaderText += '\nGlfwMenuPointerSinkFn menuPointer = nullptr;';
  fixture.backendHeaderText += '\n#define AMCL_BACKEND_INPUT_EVENT_MENU_POINTER_TRANSACTION 16u';
  fixture.glfwText += '\nvoid typedMenuPointerSink() {}';
  fixture.lwjglBridgeText += `
    case AMCL_BACKEND_INPUT_EVENT_MENU_POINTER_TRANSACTION: consumeTypedTouchMenu(); break;
  `;
  fixture.sdlPatchText += `
    case AMCL_BACKEND_INPUT_EVENT_MENU_POINTER_TRANSACTION: consume_typed_touch_menu(); break;
  `;
  fixture.sdlGateFFinalPatchText += `
    case AMCL_BACKEND_INPUT_EVENT_MENU_POINTER_TRANSACTION: consume_typed_touch_menu(); break;
  `;
  const report = analyzeGateFReadiness(fixture);
  check('complete typed touch replacement satisfies Gate F',
    report.ok && prerequisite(report, 'touch-menu-pointer-contract')?.mode ===
      'typed-replacement',
    JSON.stringify(report.issues));
}

// 9. Patch history and dead literals cannot manufacture an SDL READY token.
{
  const views = analyzeSdlPatchViews(
    '0008-openharmony-gate-f-pointer-transaction.patch\n0009-cleanup.patch\n',
    new Map([
      ['0008-openharmony-gate-f-pointer-transaction.patch',
        '+case AMCL_BACKEND_INPUT_EVENT_POINTER_TRANSACTION:\n+SDL_SendMouseMotion();'],
      ['0009-cleanup.patch',
        '-case AMCL_BACKEND_INPUT_EVENT_POINTER_TRANSACTION:\n-SDL_SendMouseMotion();'],
    ]));
  check('later SDL patch deletion removes stale added tokens from net view',
    !views.netText.includes('AMCL_BACKEND_INPUT_EVENT_POINTER_TRANSACTION'));
  check('Gate F SDL patch must be the final series entry',
    views.gateFFinalName === '' && views.gateFFinalText === '');
}
check('dead string literals cannot satisfy code-token checks',
  !stripGateFCode('const char *decoy = "PointerTransactionSink SDL_SendMouseButton";')
    .includes('PointerTransactionSink'));

// 10. 门禁自己的输入损坏必须 fail loud，不能退化成 DORMANT。
{
  const fixture = blankFixture();
  fixture.manifestText = '{not json';
  const report = analyzeGateFReadiness(fixture);
  check('malformed manifest is BLOCKED, never DORMANT/PASS',
    !report.ok && report.state === 'BLOCKED' &&
      report.issues.some(issue => issue.includes('not valid JSON')),
    JSON.stringify(report.issues));
}
{
  const fixture = blankFixture();
  fixture.manifestText = JSON.stringify({ schemaVersion: 1, capabilities: {} });
  const report = analyzeGateFReadiness(fixture);
  check('missing Gate F capability entries fail loud',
    !report.ok && report.issues.length === 2,
    JSON.stringify(report.issues));
}
{
  const fixture = blankFixture();
  fixture.manifestText = fixture.manifestText.replace('"schemaVersion":1',
    '"schemaVersion":2');
  const report = analyzeGateFReadiness(fixture);
  check('unknown manifest schema is BLOCKED',
    !report.ok && report.issues.some(issue => issue.includes('schemaVersion must be 1')),
    JSON.stringify(report.issues));
}
{
  const fixture = blankFixture();
  fixture.profileText = '';
  fixture.missing = ['entry/build-profile.json5'];
  const report = analyzeGateFReadiness(fixture);
  check('missing/empty build profile is BLOCKED',
    !report.ok && report.issues.some(issue => issue.includes('build-profile.json5')),
    JSON.stringify(report.issues));
}

console.log(failures === 0 ? 'ALL PASS' : `${failures} FAILED`);
process.exitCode = failures === 0 ? 0 : 1;
