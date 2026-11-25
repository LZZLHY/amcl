/* 真实锁定 SDL SDK 的文本队列用例。只有宿主会话序号与进程分配器观察端是替身。 */
#define SDL_MAIN_HANDLED
#include "SDL_internal.h"
#include "events/SDL_keyboard_c.h"
#include "events/SDL_events_c.h"
#include <stdio.h>
#include <stdlib.h>

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "CHECK failed line %d: %s (%s)\n", __LINE__, #condition, SDL_GetError()); exit(1); } } while (0)
static Uint64 active_serial;
static SDL_free_func real_free;
static void *tracked_commit, *tracked_edit;
static SDL_AtomicInt freed;

static Uint64 current_serial(void) { return active_serial; }

/* 只计刚在真实事件中看到的两份 SDK 临时字符串，记录后仍委派原分配器。 */
static void SDLCALL observe_free(void *p)
{
    if (p && (SDL_CompareAndSwapAtomicPointer(&tracked_commit, p, NULL) ||
              SDL_CompareAndSwapAtomicPointer(&tracked_edit, p, NULL))) {
        SDL_AddAtomicInt(&freed, 1);
    }
    real_free(p);
}

static SDL_AMCL_InputReceipt scope(SDL_Window *window, Uint64 serial)
{
    SDL_AMCL_InputReceipt receipt;
    SDL_zero(receipt);
    receipt.target = SDL_GetWindowID(window);
    receipt.textDemand.identity = serial;
    receipt.textDemand.peek = current_serial;
    return receipt;
}

static int texts(SDL_Event *out, int size, SDL_EventAction action)
{
    return SDL_PeepEvents(out, size, action, SDL_EVENT_TEXT_EDITING, SDL_EVENT_TEXT_INPUT);
}

/* 验证 A 的 commit/edit 入队成功。A 关闭、B 接管后的第一次查询分别使用真实 count/PEEK/GET。 */
static void change_field(SDL_Window *window, SDL_Window *sibling, SDL_EventAction action, bool count_only)
{
    SDL_Event observed[8];
    CHECK(SDL_SetKeyboardFocus(window));
    CHECK(SDL_StartTextInput(window));
    active_serial = 100;
    SDL_AMCL_InputReceipt a = scope(window, active_serial);
    SDL_SendKeyboardTextWithReceipt("A-commit", &a);
    SDL_SendEditingTextWithReceipt("A-edit", 1, 2, &a);
    CHECK(texts(observed, 8, SDL_PEEKEVENT) == 2);
    CHECK(observed[0].type == SDL_EVENT_TEXT_INPUT && observed[1].type == SDL_EVENT_TEXT_EDITING);
    SDL_SetAtomicPointer(&tracked_commit, (void *)observed[0].text.text);
    SDL_SetAtomicPointer(&tracked_edit, (void *)observed[1].edit.text);
    SDL_SetAtomicInt(&freed, 0);

    CHECK(SDL_StopTextInput(window));
    active_serial = 0;
    CHECK(SDL_StartTextInput(window));
    active_serial = 101;
    SDL_AMCL_InputReceipt b = scope(window, active_serial);
    SDL_SendKeyboardTextWithReceipt("stale-at-enqueue", &a);
    SDL_SendKeyboardTextWithReceipt("B-commit", &b);
    SDL_SendEditingTextWithReceipt("B-edit", 2, 1, &b);
    SDL_SendKeyboardText("ordinary");
    SDL_SendEditingText("soft-edit", 0, 0);
    CHECK(SDL_SetKeyboardFocus(sibling));
    CHECK(SDL_StartTextInput(sibling));
    SDL_SendKeyboardTextWithReceipt("wrong-window", &b);
    SDL_SendKeyboardText("sibling");
    if (count_only) {
        CHECK(texts(NULL, 0, SDL_PEEKEVENT) == 5);
    }
    CHECK(texts(observed, 8, action) == 5);
    CHECK(observed[0].type == SDL_EVENT_TEXT_INPUT && SDL_strcmp(observed[0].text.text, "B-commit") == 0);
    CHECK(observed[1].type == SDL_EVENT_TEXT_EDITING && SDL_strcmp(observed[1].edit.text, "B-edit") == 0);
    CHECK(observed[1].edit.start == 2 && observed[1].edit.length == 1);
    CHECK(observed[2].type == SDL_EVENT_TEXT_INPUT && SDL_strcmp(observed[2].text.text, "ordinary") == 0);
    CHECK(observed[3].type == SDL_EVENT_TEXT_EDITING && SDL_strcmp(observed[3].edit.text, "soft-edit") == 0);
    CHECK(observed[4].text.windowID == SDL_GetWindowID(sibling) && SDL_strcmp(observed[4].text.text, "sibling") == 0);
    if (action == SDL_PEEKEVENT) CHECK(texts(observed, 8, SDL_GETEVENT) == 5);
    SDL_FreeTemporaryMemory();
    CHECK(SDL_GetAtomicInt(&freed) == 2);
    CHECK(texts(NULL, 0, SDL_PEEKEVENT) == 0);
    CHECK(SDL_StopTextInput(sibling));
    CHECK(SDL_StopTextInput(window));
}

int main(void)
{
    SDL_malloc_func allocate;
    SDL_calloc_func allocate_zero;
    SDL_realloc_func reallocate;
    SDL_GetMemoryFunctions(&allocate, &allocate_zero, &reallocate, &real_free);
    CHECK(SDL_SetMemoryFunctions(allocate, allocate_zero, reallocate, observe_free));
    CHECK(SDL_SetHint(SDL_HINT_VIDEO_DRIVER, "dummy"));
    CHECK(SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS));
    SDL_Window *window = SDL_CreateWindow("fields A/B", 320, 240, SDL_WINDOW_HIDDEN);
    SDL_Window *sibling = SDL_CreateWindow("sibling", 320, 240, SDL_WINDOW_HIDDEN);
    CHECK(window && sibling);
    change_field(window, sibling, SDL_GETEVENT, false);
    change_field(window, sibling, SDL_PEEKEVENT, false);
    change_field(window, sibling, SDL_PEEKEVENT, true);
    SDL_DestroyWindow(sibling);
    SDL_DestroyWindow(window);
    SDL_Quit();
    puts("PASS real SDL text queue: GET/PEEK/count discard previous field, current text and editing ranges survive, ordinary and sibling events survive, stale strings freed once");
    return 0;
}
