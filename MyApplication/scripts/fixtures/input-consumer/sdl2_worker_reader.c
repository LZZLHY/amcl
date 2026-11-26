/* 宿主夹具只替代设备服务。设备枚举、增量查询、虚拟轴、SDL2 兼容层和事件分派均用生产代码。 */
#include "desktop_host_api.h"
#include "gamepad_change_query.h"
#include <SDL3/SDL.h>
#include <stdbool.h>
#include <string.h>
#ifdef _WIN32
#define FIXTURE_EXPORT __declspec(dllexport)
#else
#define FIXTURE_EXPORT __attribute__((visibility("default")))
#endif

static AmclDesktopGamepad sample;
static uint64_t revision = 1;
static SDL_AtomicInt holdRead, enteredRead;

/* 让原 owner 在真实 SDK 正读取平台快照时退出，验证正在执行的轮询与销毁互斥。 */
FIXTURE_EXPORT void amclTestHoldRead(int hold) { SDL_SetAtomicInt(&holdRead, hold); }
FIXTURE_EXPORT int amclTestReadEntered(void) { return SDL_GetAtomicInt(&enteredRead); }
typedef int32_t (*AmclGamepadReadFn)(int32_t, AmclDesktopGamepad *);

static int32_t readPad(int32_t slot, AmclDesktopGamepad *out)
{
    if (slot == AMCL_GAMEPAD_QUERY_CHANGES && out) {
        if (SDL_GetAtomicInt(&holdRead)) {
            SDL_SetAtomicInt(&enteredRead, 1);
            while (SDL_GetAtomicInt(&holdRead)) SDL_Delay(1);
            SDL_SetAtomicInt(&enteredRead, 0);
        }
        out->connected = out->generation == revision ? 0 : 1;
        out->generation = revision;
        return AMCL_GAMEPAD_CHANGES_SUPPORTED;
    }
    if (slot != 0 || !out || !sample.connected) return 0;
    *out = sample;
    return 1;
}

AmclGamepadReadFn amclResolveGamepadReader(void) { return readPad; }
bool SDL_AMCL_GamepadSessionActive(void) { return true; }

/* 调用方依次提交设备变化并等待 worker 回执，没有并发写入。 */
FIXTURE_EXPORT void amclTestPublishController(int online, float axis, int down)
{
    if (sample.connected != online) ++sample.generation;
    sample.connected = online;
    strcpy(sample.name, "AMCL worker test pad");
    sample.axes[0] = axis;
    sample.axes[4] = sample.axes[5] = -1;
    sample.buttons[0] = down;
    ++sample.events;
    ++revision;
}
