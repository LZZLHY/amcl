/* 使用真实 SDL3 gamepad/joystick/event 库；只控制平台的当前快照和实例资格。
 * 无 VIDEO 的第一次查询、显式更新、事件泵、同槽重连和退出后的重新初始化各有独立断言。 */
#define SDL_MAIN_HANDLED
#include <SDL3/SDL.h>
#include "desktop_host_api.h"
#include "gamepad_change_query.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "line %d: %s (%s)\n", __LINE__, #expr, SDL_GetError()); exit(1); } } while (0)

static AmclDesktopGamepad pads[2];
static bool session = true, route = true;
static int reads, resolves;
static int queries, masks, snapshots;
static Uint64 revision = 1, versions[2];
static bool legacy;
static void changed(int slot) { versions[slot] = ++revision; }
/* 用 SDL 自己的分配接口制造一次 attach 失败；故障只作用于当前轮询线程。 */
static SDL_malloc_func originalMalloc;
static SDL_calloc_func originalCalloc;
static SDL_realloc_func originalRealloc;
static SDL_free_func originalFree;
static SDL_AtomicInt failNextOpen;
static SDL_ThreadID testThread;
static void *SDLCALL failOneCalloc(size_t count, size_t size) {
    if (SDL_GetAtomicInt(&failNextOpen) && SDL_GetCurrentThreadID() == testThread &&
        SDL_CompareAndSwapAtomicInt(&failNextOpen, 1, 0)) return NULL;
    return originalCalloc(count, size);
}
typedef int32_t (*AmclGamepadReadFn)(int32_t, AmclDesktopGamepad *);

static int32_t readPad(int32_t index, AmclDesktopGamepad *out)
{
    ++reads;
    if (index == AMCL_GAMEPAD_QUERY_CHANGES && !legacy) {
        ++queries;
        out->connected = 0;
        if (out->generation == revision) return AMCL_GAMEPAD_CHANGES_SUPPORTED;
        for (int i = 0; i < 2; ++i)
            if (!out->generation ? pads[i].connected : versions[i] > out->generation) out->connected |= 1 << i;
        if (!route) out->connected = -1;
        out->generation = revision;
        return AMCL_GAMEPAD_CHANGES_SUPPORTED;
    }
    if (!route) return -1;
    if (index == -1 && !out) { ++masks; return (pads[0].connected ? 1 : 0) | (pads[1].connected ? 2 : 0); }
    if (index >= 0) ++snapshots;
    if (index < 0 || index >= 2 || !pads[index].connected) return 0;
    *out = pads[index];
    return 1;
}

AmclGamepadReadFn amclResolveGamepadReader(void) { ++resolves; return readPad; }
bool SDL_AMCL_GamepadSessionActive(void) { return session; }

/* 两条路径都用 SDL 的真实更新循环；仅统计调用到平台 reader 的工作量，不推断 FPS。 */
static void checkIdle(const char *phase) {
    const int q = queries, m = masks, s = snapshots;
    for (int i = 0; i < 1000; ++i) SDL_UpdateGamepads();
    printf("%s idle: 1000 updates, queries=%d masks=%d snapshots=%d\n", phase, queries-q, masks-m, snapshots-s);
    CHECK(queries-q == 1000 && masks == m && snapshots == s);
}

/* 宿主也可能实际接有其它手柄；只断言 fixture 发布的两个设备，要求同名设备不重复创建。 */
static SDL_JoystickID findPad(const char *name)
{
    int count = 0;
    SDL_JoystickID *ids = SDL_GetGamepads(&count), found = 0;
    CHECK(ids);
    for (int i = 0; i < count; ++i) {
        const char *actual = SDL_GetGamepadNameForID(ids[i]);
        if (actual && strcmp(actual, name) == 0) { CHECK(!found); found = ids[i]; }
    }
    SDL_free(ids);
    return found;
}

int main(void)
{
    const char *first = "AMCL test pad A", *second = "AMCL test pad B";
    SDL_GetMemoryFunctions(&originalMalloc, &originalCalloc, &originalRealloc, &originalFree);
    CHECK(SDL_SetMemoryFunctions(originalMalloc, failOneCalloc, originalRealloc, originalFree));
    testThread = SDL_GetCurrentThreadID();
    SDL_SetMainReady();
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_GAMEINPUT, "0");
    SDL_SetHint(SDL_HINT_JOYSTICK_RAWINPUT, "0");
    strcpy(pads[0].name, first); strcpy(pads[1].name, second);
    pads[0].connected = 1; pads[0].generation = 1;
    pads[0].axes[4] = pads[0].axes[5] = -1.0f;
    pads[0].axes[0] = 0.75f;
    CHECK(SDL_Init(SDL_INIT_GAMEPAD));
    CHECK(SDL_WasInit(SDL_INIT_VIDEO) == 0);
    const SDL_JoystickID id = findPad(first);
    CHECK(id && resolves == 1);
    SDL_Gamepad *pad = SDL_OpenGamepad(id);
    CHECK(pad && SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTX) > 24000);
    CHECK(SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER) == 0);
    checkIdle("aux");
    CHECK(!SDL_GamepadHasButton(pad, SDL_GAMEPAD_BUTTON_LEFT_PADDLE1));
    CHECK(!SDL_GamepadHasButton(pad, SDL_GAMEPAD_BUTTON_RIGHT_PADDLE1));
    pads[0].buttons[0] = 1; pads[0].buttons[12] = 1;
    pads[0].hats[0] = SDL_HAT_RIGHT; pads[0].axes[4] = 1.0f;
    ++pads[0].events; changed(0);
    SDL_UpdateGamepads();
    CHECK(SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_SOUTH));
    CHECK(SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_DPAD_RIGHT));
    CHECK(SDL_GetJoystickHat(SDL_GetGamepadJoystick(pad), 0) == SDL_HAT_RIGHT);
    CHECK(SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER) == 32767);

    /* 在公开 virtual 接口留下可辨认的哨兵；若 AMCL 因单轴报告重写任一无关组，
     * 这些值会被平台快照覆盖。真实 SDL 的输出去重不能掩盖这类多余的 setter。 */
    SDL_Joystick *stick = SDL_GetGamepadJoystick(pad);
    CHECK(SDL_SetJoystickVirtualAxis(stick, 2, 1234));
    CHECK(SDL_SetJoystickVirtualButton(stick, 1, true));
    CHECK(SDL_SetJoystickVirtualHat(stick, 0, SDL_HAT_LEFT));
    pads[0].axes[0] = -0.5f;
    ++pads[0].events; changed(0);
    SDL_UpdateJoysticks();
    CHECK(SDL_GetJoystickAxis(stick, 0) == -16384);
    CHECK(SDL_GetJoystickAxis(stick, 2) == 1234);
    CHECK(SDL_GetJoystickButton(stick, 1));
    CHECK(SDL_GetJoystickHat(stick, 0) == SDL_HAT_LEFT);

    /* 模拟重复报告和低于一个 SDL 轴单位的变化；同一量化值不能覆盖哨兵。 */
    CHECK(SDL_SetJoystickVirtualAxis(stick, 0, 4321));
    pads[0].axes[0] = -0.500001f;
    ++pads[0].events; changed(0);
    SDL_UpdateGamepads();
    CHECK(SDL_GetJoystickAxis(stick, 0) == 4321);

    /* 当前连接失焦归中仍须发布真实变化，随后同槽插拔由原代次测试覆盖。 */
    pads[0].axes[0] = 0;
    pads[0].axes[4] = -1;
    pads[0].buttons[0] = pads[0].buttons[12] = 0;
    pads[0].hats[0] = SDL_HAT_CENTERED;
    pads[0].events += (Uint64)1 << 32; changed(0);
    SDL_UpdateGamepads();
    CHECK(SDL_GetJoystickAxis(stick, 2) == 0);
    CHECK(!SDL_GetJoystickButton(stick, 1));
    CHECK(SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTX) == 0);
    CHECK(SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER) == 0);
    CHECK(!SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_SOUTH));
    CHECK(SDL_GetJoystickHat(stick, 0) == SDL_HAT_CENTERED);

    /* 真实 SDL 空焦点会丢掉按下，恢复后只改轴，保持按下的键也必须送达。 */
    CHECK(SDL_SetHint(SDL_HINT_VIDEO_DRIVER, "dummy"));
    CHECK(SDL_InitSubSystem(SDL_INIT_VIDEO));
    SDL_Window *window = SDL_CreateWindow("controller focus recovery", 32, 32, SDL_WINDOW_HIDDEN);
    CHECK(window);
    CHECK(SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "0"));
    CHECK(SDL_GetKeyboardFocus() == NULL);
    pads[0].buttons[0] = 1;
    ++pads[0].events; changed(0);
    SDL_UpdateGamepads();
    CHECK(!SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_SOUTH));
    CHECK(SDL_ShowWindow(window) && SDL_GetKeyboardFocus() == window);
    pads[0].axes[0] = -0.75f;
    ++pads[0].events; changed(0);
    SDL_UpdateGamepads();
    CHECK(SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTX) == -24576);
    CHECK(SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_SOUTH));
    /* 仅 SDL 焦点恢复也须补发被拒的按键；下一轮静止不能再重复全量写入。 */
    CHECK(SDL_HideWindow(window) && SDL_GetKeyboardFocus() == NULL);
    pads[0].buttons[1] = 1;
    ++pads[0].events; changed(0);
    SDL_UpdateGamepads();
    CHECK(!SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_EAST));
    CHECK(SDL_ShowWindow(window) && SDL_GetKeyboardFocus() == window);
    SDL_UpdateGamepads();
    CHECK(SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_EAST));
    CHECK(SDL_SetJoystickVirtualAxis(stick, 2, 2222));
    SDL_UpdateGamepads();
    SDL_UpdateGamepads();
    CHECK(SDL_GetJoystickAxis(stick, 2) == 2222);
    checkIdle("video");
    SDL_DestroyWindow(window);
    SDL_QuitSubSystem(SDL_INIT_VIDEO);

    SDL_FlushEvents(SDL_EVENT_FIRST, SDL_EVENT_LAST);
    pads[1].connected = 1; pads[1].generation = 1;
    pads[0].connected = 0;
    changed(0); changed(1);
    SDL_Event event;
    bool added = false, removed = false;
    while (SDL_PollEvent(&event)) {
        if (event.type == SDL_EVENT_GAMEPAD_REMOVED && event.gdevice.which == id) removed = true;
        if (event.type == SDL_EVENT_GAMEPAD_ADDED && event.gdevice.which == findPad(second)) added = true;
    }
    SDL_JoystickID other = findPad(second);
    if (!added || !removed || !other || findPad(first) || SDL_GamepadConnected(pad)) fprintf(stderr, "hotplug added=%d removed=%d other=%u first=%u connected=%d reads=%d\n", added, removed, other, findPad(first), SDL_GamepadConnected(pad), reads);
    CHECK(added && removed && other && !findPad(first) && !SDL_GamepadConnected(pad));
    SDL_CloseGamepad(pad);
    pads[0].connected = 1; ++pads[0].generation; changed(0);
    SDL_SetAtomicInt(&failNextOpen, 1);
    SDL_UpdateJoysticks();
    CHECK(!SDL_GetAtomicInt(&failNextOpen) && !findPad(first));
    /* 不产生新的平台事件，下一次轮询仍须完成前次失败的打开。 */
    SDL_UpdateJoysticks();
    const SDL_JoystickID newId = findPad(first);
    CHECK(newId && newId != id && findPad(second) == other);
    ++pads[0].generation; changed(0);
    SDL_UpdateJoysticks();
    CHECK(findPad(first) != newId && findPad(second) == other);
    /* 两台实体只变一台的轴；从 SDL 外部移除虚拟映射，下一轮即从未变的平台状态恢复。 */
    const int beforeSnapshots = snapshots;
    pads[0].axes[2] = 0.25f; ++pads[0].events; changed(0);
    SDL_UpdateGamepads();
    CHECK(snapshots == beforeSnapshots + 1);
    const SDL_JoystickID beforeDetach = findPad(first);
    CHECK(SDL_DetachVirtualJoystick(beforeDetach));
    SDL_UpdateGamepads();
    CHECK(findPad(first) && findPad(first) != beforeDetach && findPad(second) == other);
    route = false; ++revision; reads = 0;
    SDL_UpdateJoysticks();
    CHECK(reads == 1 && !findPad(first) && !findPad(second));
    route = true; ++revision; session = false; reads = 0;
    SDL_UpdateJoysticks();
    CHECK(!reads && !findPad(first));
    SDL_QuitSubSystem(SDL_INIT_GAMEPAD);
    CHECK(!SDL_WasInit(SDL_INIT_JOYSTICK));
    session = true;
    CHECK(SDL_InitSubSystem(SDL_INIT_GAMEPAD));
    CHECK(resolves == 2 && findPad(first) && findPad(second));
    SDL_QuitSubSystem(SDL_INIT_GAMEPAD);
    legacy = true;
    CHECK(SDL_InitSubSystem(SDL_INIT_GAMEPAD));
    CHECK(findPad(first) && findPad(second) && masks > 0);
    SDL_Quit();
    puts("PASS real SDL gamepad initial inventory, standard state, hotplug without VIDEO, route retirement, Quit/re-init");
    return 0;
}
