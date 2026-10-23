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

// 固定新版实际生产形式：token 防耗尽分配、两套阶段出口和 private relative 在 neutral
// consumer 内还原旧 ABI。保留 fullFixture 的旧 inline token 作为刻意的干扰项，证明
// 新协议一旦断接，门禁不能借旧变量/旧 case 回退为“保留合同仍成立”。这里仅是源码
// 谓词的固定样本，不把它当设备通过、typed 等价替代或 Gate F 证据批准。
function causalTouchFixture() {
  const fixture = fullFixture();
  fixture.touchText += `
    #define MENU_POINTER_BEGIN 4
    #define MENU_POINTER_END 5
    void emitMenuInteraction(MenuTouchAction action, double x, double y) {
      if (action == MenuTouchAction::Begin || action == MenuTouchAction::RelativeBegin) {
        if (s_touchMenuNextToken == 0) return;
        s_touchMenuToken = s_touchMenuNextToken;
        s_touchMenuNextToken = s_touchMenuNextToken == 0x7fffffffu ? 0 : s_touchMenuNextToken + 1;
      }
      if (relative) {
        if (s_touchMenuToken == 0) return;
        const int phase = action == MenuTouchAction::RelativeBegin ? MENU_POINTER_BEGIN :
          action == MenuTouchAction::RelativeDown ? MENU_POINTER_DOWN :
          action == MenuTouchAction::RelativeUp ? MENU_POINTER_UP :
          action == MenuTouchAction::RelativeEnd ? MENU_POINTER_END :
          action == MenuTouchAction::RelativeCancel ? MENU_POINTER_CANCEL : MENU_POINTER_MOVE;
        if (phase == MENU_POINTER_CANCEL || mapMenuRelativePayload(x,y,&dx,&dy,&maxX,&maxY))
          inputBridge_publishTouchMenuRelativeV1(phase,s_touchMenuToken,dx,dy,maxX,maxY);
        if (phase == MENU_POINTER_END || phase == MENU_POINTER_CANCEL) s_touchMenuToken = 0;
        return;
      }
      if (action == MenuTouchAction::Position) {
        if (s_touchMenuToken != 0) sendEvent(EVENT_TYPE_MENU_POINTER,MENU_POINTER_MOVE,mx,my,s_touchMenuToken);
      } else if (action == MenuTouchAction::Begin || action == MenuTouchAction::Down) {
        if (s_touchMenuToken != 0) sendEvent(EVENT_TYPE_MENU_POINTER,
          action == MenuTouchAction::Begin ? MENU_POINTER_BEGIN : MENU_POINTER_DOWN,mx,my,s_touchMenuToken);
      } else if (s_touchMenuToken != 0) {
        sendEvent(EVENT_TYPE_MENU_POINTER,action == MenuTouchAction::Up ? MENU_POINTER_UP :
          action == MenuTouchAction::End ? MENU_POINTER_END : MENU_POINTER_CANCEL,mx,my,s_touchMenuToken);
        if (action == MenuTouchAction::End || action == MenuTouchAction::Cancel) s_touchMenuToken = 0;
      }
    }
    void schemaRetireTouchPolicyLocked() {
      inputBridge_retireTouchMenuScopeV1();
      s_menuTouch.Cancel(emitMenuInteraction);
    }
    void menuEvent() { s_menuTouch.Event(phase,id,x,y,time,emitMenuInteraction); }
  `;
  fixture.lwjglBridgeText += `
    #define EVENT_TYPE_MENU_POINTER 1008
    #define EVENT_TYPE_CURSOR_POSITION 1010
    #define EVENT_TYPE_MOUSE_BUTTON 1006
    #define EVENT_TYPE_TOUCH_MENU_RELATIVE 1017
    void inputBridge_publishTouchMenuRelativeV1(int phase,uint32_t token,double dx,double dy,double maxX,double maxY) {
      if (phase < MENU_POINTER_MOVE || phase > MENU_POINTER_END || (phase != MENU_POINTER_MOVE && token == 0)) return;
      publishMenuRelative(EVENT_TYPE_TOUCH_MENU_RELATIVE,phase,token,dx,dy,maxX,maxY);
    }
    void sendData_locked() {
      slot->menuScopeEpoch = atomic_load_explicit(&g_touchMenuScopeEpoch,memory_order_relaxed);
      if (relative) slot->relative = *relative;
      if (phase == MENU_POINTER_BEGIN) g_producerMenuGestureToken = token;
      slot->gestureToken = token;
      if (phase == MENU_POINTER_END || phase == MENU_POINTER_CANCEL) g_producerMenuGestureToken = 0;
    }
    void inputBridge_retireTouchMenuScopeV1() {
      atomic_fetch_add_explicit(&g_touchMenuScopeEpoch,1ULL,memory_order_release);
    }
    bool scopedMenuEventValid(int type,uint64_t menuEpoch,uint64_t toolEpoch) {
      if (isScopedMenuEvent(type) && menuEpoch != atomic_load_explicit(&g_touchMenuScopeEpoch,memory_order_acquire)) return false;
      return true;
    }
    bool queuedMenuInvalidates(uint32_t token,uint64_t epoch,bool gestureBegun) {
      bool canceled = epoch != atomic_load_explicit(&g_touchMenuScopeEpoch,memory_order_acquire);
      if (value == token && phase == MENU_POINTER_CANCEL) canceled = true;
      if (value == token && (phase == MENU_POINTER_END || (!gestureBegun && phase == MENU_POINTER_UP))) normallyEnded = true;
      if (!normallyEnded && (phase == MENU_POINTER_BEGIN || phase == MENU_POINTER_DOWN) && value != token) canceled = true;
      return canceled;
    }
    void resolveRelativeMenuCursor(uint32_t backend) {
      currentMenuCursor(backend,x,y);
      *x += dx; *y += dy;
      *x = fmin(relative->maxX,*x); *y = fmin(relative->maxY,*y);
    }
    bool resolveRelativeMenuEvent(uint32_t backend) {
      if (token != currentToken) return false;
      resolveRelativeMenuCursor(backend,event,relative,menuX,menuY);
      event->type = EVENT_TYPE_MENU_POINTER; event->i1 = phase; event->i4 = (int)token;
      return true;
    }
    bool advanceGlfwMenuPending() {
      if (queuedMenuInvalidates() || g_menuInputTargetEpoch != targetEpoch || g_glfwPresentedIdentity != g_menuPresentedIdentity) {
        cancelMenuTransaction(window,true); return true;
      }
      if (g_presentSerial < g_menuPressAfterPresent) return false;
      g_menuPressAfterPresent = g_presentSerial + 2ULL;
      return true;
    }
    void inputBridge_pumpOrdered() {
      if (!scopedMenuEventValid()) continue;
      if (!resolveRelativeMenuEvent(1,&event,&relative,token,&x,&y)) continue;
      if (queuedMenuInvalidates()) continue;
      if (!acceptMenuGestureStart()) continue;
      if (phase == MENU_POINTER_BEGIN || phase == MENU_POINTER_END || phase == MENU_POINTER_CANCEL) return;
      g_menuPressAfterPresent = g_presentSerial + 2ULL;
    }
    int inputBridge_l2NextEvent() {
      if (!scopedMenuEventValid()) continue;
      if (!resolveRelativeMenuEvent(2,&event,&relative,token,&x,&y)) continue;
      if (queuedMenuInvalidates()) continue;
      if (!acceptMenuGestureStart()) continue;
      if (phase == MENU_POINTER_BEGIN || phase == MENU_POINTER_END || phase == MENU_POINTER_CANCEL) return;
      returnOrderedMenuCursor(x,y,2,order,outType,o1,o2,o3,o4);
      e.type = EVENT_TYPE_MOUSE_BUTTON;
      return returnLegacyEvent(&e,outType,o1,o2,o3,o4);
    }
    int inputBridge_sdlNextThrough() {
      if (!scopedMenuEventValid()) continue;
      if (!resolveRelativeMenuEvent(3,&event,&relative,token,&x,&y)) continue;
      if (queuedMenuInvalidates()) continue;
      if (!acceptMenuGestureStart()) continue;
      if (phase == MENU_POINTER_BEGIN) return consumeSdlMenuPointer(&event,order,epoch,x,y);
    }
    int consumeSdlMenuPointer() {
      if (phase == MENU_POINTER_END || phase == MENU_POINTER_CANCEL) clearSdlMenuTransactionLocked();
      if (cursor) return returnOrderedMenuCursor(x,y,3,order,outType,o1,o2,o3,o4);
      return returnSdlMenuButtonEvent(action,outType,o1,o2,o3,o4);
    }
    int returnDueSdlMenuButton() {
      if (g_sdlMenuState.inputTargetEpoch != targetEpoch || g_sdlMenuState.targetPresentedIdentity != presentedIdentity || queuedMenuInvalidates()) {
        clearSdlMenuTransactionLocked();
      } else if (baselinePending) {
        g_sdlMenuState.pressAfterPresent = g_sdlMenuState.presentSerial + 1ULL;
      } else if (g_sdlMenuState.presentSerial >= g_sdlMenuState.pressAfterPresent) return 1;
      return 0;
    }
    int returnLegacyEvent() {
      if (outType) *outType = event->type;
      if (o1) *o1 = event->i1; if (o2) *o2 = event->i2;
      if (o3) *o3 = event->i3; if (o4) *o4 = event->i4;
      return 1;
    }
    int returnOrderedMenuCursor() { if (outType) *outType = EVENT_TYPE_CURSOR_POSITION; return 1; }
    int returnSdlMenuButtonEvent() {
      GLFWInputEvent event = {EVENT_TYPE_MOUSE_BUTTON,0,action,0,0};
      return returnLegacyEvent(&event,outType,o1,o2,o3,o4);
    }
  `;
  return fixture;
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

// 统一菜单解释器沿用token/cancel/present合同；正例及断接反例防止门禁只认旧变量名。
{
  const fixture = fullFixture();
  fixture.touchText = fixture.touchText.replaceAll('s_activeMenuTransactionToken', 's_touchMenuToken') + `
    s_touchMenuToken = s_touchMenuNextToken++;
    s_menuTouch.Event(phase, id, x, y, time, emitMenuInteraction);
    s_menuTouch.Cancel(emitMenuInteraction);
  `;
  const report = analyzeGateFReadiness(fixture);
  check('unified touch interpreter preserves the transaction contract',
    report.ok && prerequisite(report, 'touch-menu-pointer-contract')?.mode === 'preserved-legacy',
    JSON.stringify(report.issues));
  for (const [name, pattern] of [
    ['allocation', /s_touchMenuToken = s_touchMenuNextToken\+\+;/],
    ['event ingress', /s_menuTouch\.Event\([^;]+;/],
    ['cancel ingress', /s_menuTouch\.Cancel\([^;]+;/],
  ]) {
    const broken = analyzeGateFReadiness({...fixture, touchText: fixture.touchText.replace(pattern, '')});
    check(`unified touch missing ${name} blocks activation`,
      !broken.ok && broken.issues.some(issue => issue.includes("'touch-menu-pointer-contract'")),
      JSON.stringify(broken.issues));
  }
}

// 新版手势身份的固定正例及断接反例。Gate F 激活的其它三组使用原 fullFixture；
// 只变异当前触控合同，必须同时显示缺失具体条目和整个 touch prerequisite BLOCKED。
{
  const fixture = causalTouchFixture();
  const report = analyzeGateFReadiness(fixture);
  check('causal BEGIN/END + relative preserves legacy touch, never claims typed replacement',
    report.ok && prerequisite(report, 'touch-menu-pointer-contract')?.mode === 'preserved-legacy',
    JSON.stringify(report.prerequisites));
  for (const [name, key, from, to, checkId] of [
    ['token allocation', 'touchText', 's_touchMenuToken = s_touchMenuNextToken;', '', 'touch-token-allocation'],
    ['token exhaustion guard', 'touchText', 'if (s_touchMenuNextToken == 0) return;', '', 'touch-token-allocation'],
    ['cancel ingress', 'touchText', 's_menuTouch.Cancel(emitMenuInteraction);', '', 'touch-token-allocation'],
    ['UP incorrectly retires token', 'touchText', 'phase == MENU_POINTER_END || phase == MENU_POINTER_CANCEL) s_touchMenuToken = 0;',
      'phase == MENU_POINTER_UP || phase == MENU_POINTER_END || phase == MENU_POINTER_CANCEL) s_touchMenuToken = 0;', 'touch-gesture-lifetime'],
    ['relative END phase', 'touchText', 'MenuTouchAction::RelativeEnd ? MENU_POINTER_END',
      'MenuTouchAction::RelativeEnd ? MENU_POINTER_UP', 'touch-gesture-lifetime'],
    ['relative token publisher', 'touchText', 'inputBridge_publishTouchMenuRelativeV1(phase,s_touchMenuToken,dx,dy,maxX,maxY);',
      'inputBridge_publishTouchMenuRelativeV1(phase,0,dx,dy,maxX,maxY);', 'touch-relative-publication'],
    ['frozen relative metadata', 'lwjglBridgeText', 'slot->relative = *relative;', '', 'touch-relative-publication'],
    ['full scope retirement', 'touchText', 'inputBridge_retireTouchMenuScopeV1();', '', 'touch-scope-retirement'],
    ['queued CANCEL authority', 'lwjglBridgeText', 'if (value == token && phase == MENU_POINTER_CANCEL) canceled = true;', '', 'touch-scope-retirement'],
    ['BEGIN known UP treated as END', 'lwjglBridgeText', '(!gestureBegun && phase == MENU_POINTER_UP)',
      '(phase == MENU_POINTER_UP)', 'touch-scope-retirement'],
    ['normal END then BEGIN replaces completed tap', 'lwjglBridgeText', '!normallyEnded && (phase == MENU_POINTER_BEGIN',
      '(phase == MENU_POINTER_BEGIN', 'touch-scope-retirement'],
    ['relative actual consumer baseline', 'lwjglBridgeText', 'currentMenuCursor(backend,x,y);',
      'desiredMenuCursor(backend,x,y);', 'touch-relative-current'],
    ['GLFW relative consumer', 'lwjglBridgeText', 'resolveRelativeMenuEvent(1,&event',
      'resolveRelativeMenuEvent(9,&event', 'touch-three-consumers'],
    ['LWJGL2 relative consumer', 'lwjglBridgeText', 'resolveRelativeMenuEvent(2,&event',
      'resolveRelativeMenuEvent(9,&event', 'touch-three-consumers'],
    ['SDL relative consumer', 'lwjglBridgeText', 'resolveRelativeMenuEvent(3,&event',
      'resolveRelativeMenuEvent(9,&event', 'touch-three-consumers'],
    ['GLFW actual present test', 'lwjglBridgeText', 'if (g_presentSerial < g_menuPressAfterPresent) return false;', '', 'touch-present-barriers'],
    ['SDL actual present test', 'lwjglBridgeText', 'g_sdlMenuState.presentSerial >= g_sdlMenuState.pressAfterPresent',
      'pollCount >= 1', 'touch-present-barriers'],
    ['game pull ABI word four', 'lwjglBridgeText', '*o4 = event->i4;',
      '*o4 = event->i3;', 'touch-old-game-abi'],
  ]) {
    const broken = analyzeGateFReadiness(mutate(fixture, key, from, to));
    const contract = prerequisite(broken, 'touch-menu-pointer-contract');
    check(`causal missing ${name} blocks activation despite old inline decoys`,
      !broken.ok && contract?.mode === 'missing' &&
        contract.checks.some(item => item.id === checkId && !item.ok) &&
        broken.issues.some(issue => issue.includes("'touch-menu-pointer-contract'")),
      JSON.stringify(contract));
  }
}

// 同一固定反例还必须能在实仓形态定位断接，防止样本正例和谓词相互迁就。
// 只在内存变异 source view，不改生产文件或 evidence；DORMANT 本身仍不批准 Gate F。
{
  const fixture = readGateFSources();
  for (const [name, key, from, to, checkId] of [
    ['token allocation', 'touchText', /s_touchMenuToken\s*=\s*s_touchMenuNextToken\s*;/,
      's_touchMenuToken=0;', 'touch-token-allocation'],
    ['CANCEL hook', 'touchText', /s_menuTouch\.Cancel\s*\(\s*emitMenuInteraction\s*\)/g,
      's_menuTouch.Cancel(nullptr)', 'touch-token-allocation'],
    ['queued cancel scan', 'lwjglBridgeText', /value == token && phase == MENU_POINTER_CANCEL\) canceled = true;/,
      'value == token && phase == MENU_POINTER_CANCEL) canceled = false;', 'touch-scope-retirement'],
    ['shared actual present comparison', 'pointerTransactionText', /presentSerial < state->pressAfterPresent/,
      'false', 'touch-present-barriers'],
    ['GLFW policy', 'lwjglBridgeText', /g_glfwPointerPolicy\s*=\s*\{2u,\s*false,\s*false\}/,
      'g_glfwPointerPolicy = {0u, false, false}', 'touch-present-barriers'],
    ['SDL policy', 'lwjglBridgeText', /g_sdlPointerPolicy\s*=\s*\{1u,\s*true,\s*true\}/,
      'g_sdlPointerPolicy = {0u, false, false}', 'touch-present-barriers'],
    ['shared source freeze', 'pointerTransactionText', /state->sourceX\s*=\s*x;/,
      'state->sourceX = 0;', 'touch-three-consumers'],
    ['shared contact accepts only one DOWN', 'pointerTransactionText', /state->downAccepted\s*=\s*true;/,
      'state->downAccepted = false;', 'touch-three-consumers'],
    ['LWJGL2 shared transaction call', 'lwjglBridgeText', /amclPointerAccept\(&g_l2Pointer,/,
      'otherPointerAccept(&g_l2Pointer,', 'touch-three-consumers'],
    ['SDL shared transaction call', 'lwjglBridgeText', /amclPointerAccept\(&g_sdlMenuState.pointer,/,
      'otherPointerAccept(&g_sdlMenuState.pointer,', 'touch-three-consumers'],
    ['LWJGL2 relative call', 'lwjglBridgeText', /resolveRelativeMenuEvent\(2,/, 'resolveRelativeMenuEvent(9,', 'touch-three-consumers'],
  ]) {
    const broken = analyzeGateFReadiness(mutate(fixture, key, from, to));
    const contract = prerequisite(broken, 'touch-menu-pointer-contract');
    check(`real production source detects missing ${name} without fabricating Gate F approval`,
      broken.state === 'DORMANT' && !broken.activationRequested &&
        !broken.evidence.absoluteApproved && !broken.evidence.timestampApproved &&
        contract?.mode === 'missing' && contract.checks.some(item => item.id === checkId && !item.ok),
      JSON.stringify(contract));
  }
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
