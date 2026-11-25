#include "SDL_internal.h"
#include "SDL_amclphoneclipboard.h"
#include <database/pasteboard/oh_pasteboard.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition) do { \
    if (!(condition)) { fprintf(stderr, "line %d: %s\n", __LINE__, #condition); exit(1); } \
} while (false)

enum Resource { BOARD = 1, DATA = 2, RECORD = 4, PLAIN = 8 };
enum Step { SET_CONTENT = 1, ADD_PLAIN, ADD_RECORD, SET_DATA };

struct OH_Pasteboard { int unused; };
struct OH_UdmfData { OH_UdmfRecord *record; };
struct OH_UdmfRecord { OH_UdsPlainText *plain; };
struct OH_UdsPlainText { const char *text; };

static OH_Pasteboard board;
static OH_UdmfData data;
static OH_UdmfRecord record;
static OH_UdsPlainText plain;
static unsigned created, live, destroyed, rejected_resource;
static enum Step rejected_step;
static int system_writes, warnings;
static const char *system_text;
static char warning[128];

/* 模拟 NDK 对象身份。失败时只允许销毁已创建的对象，每个对象只能销毁一次。 */
static bool Create(enum Resource resource)
{
    if (resource == rejected_resource) return false;
    CHECK((created & resource) == 0);
    created |= resource;
    live |= resource;
    return true;
}

static void Destroy(enum Resource resource)
{
    CHECK((live & resource) != 0);
    live &= ~resource;
    destroyed |= resource;
}

OH_Pasteboard *OH_Pasteboard_Create(void) { return Create(BOARD) ? &board : NULL; }
OH_UdmfData *OH_UdmfData_Create(void) { return Create(DATA) ? &data : NULL; }
OH_UdmfRecord *OH_UdmfRecord_Create(void) { return Create(RECORD) ? &record : NULL; }
OH_UdsPlainText *OH_UdsPlainText_Create(void) { return Create(PLAIN) ? &plain : NULL; }

void OH_Pasteboard_Destroy(OH_Pasteboard *object) { CHECK(object == &board); Destroy(BOARD); }
void OH_UdmfData_Destroy(OH_UdmfData *object) { CHECK(object == &data); Destroy(DATA); }
void OH_UdmfRecord_Destroy(OH_UdmfRecord *object) { CHECK(object == &record); Destroy(RECORD); }
void OH_UdsPlainText_Destroy(OH_UdsPlainText *object) { CHECK(object == &plain); Destroy(PLAIN); }

int OH_UdsPlainText_SetContent(OH_UdsPlainText *object, const char *text)
{
    CHECK(object == &plain && text != NULL && (live & PLAIN));
    if (rejected_step == SET_CONTENT) return -1;
    object->text = text;
    return 0;
}

int OH_UdmfRecord_AddPlainText(OH_UdmfRecord *to, OH_UdsPlainText *from)
{
    CHECK(to == &record && from == &plain && from->text != NULL);
    CHECK((live & (RECORD | PLAIN)) == (RECORD | PLAIN));
    if (rejected_step == ADD_PLAIN) return -1;
    to->plain = from;
    return 0;
}

int OH_UdmfData_AddRecord(OH_UdmfData *to, OH_UdmfRecord *from)
{
    CHECK(to == &data && from == &record && from->plain == &plain);
    CHECK((live & (DATA | RECORD)) == (DATA | RECORD));
    if (rejected_step == ADD_RECORD) return -1;
    to->record = from;
    return 0;
}

int OH_Pasteboard_SetData(OH_Pasteboard *to, OH_UdmfData *from)
{
    CHECK(to == &board && from == &data && from->record == &record);
    CHECK(live == (BOARD | DATA | RECORD | PLAIN));
    ++system_writes;
    if (rejected_step == SET_DATA) return -1;
    system_text = from->record->plain->text;
    return 0;
}

size_t SDL_strnlen(const char *text, size_t limit)
{
    size_t length = 0;
    CHECK(text != NULL);
    while (length < limit && text[length] != '\0') ++length;
    return length;
}

void SDL_LogWarn(int category, const char *format, ...)
{
    va_list args;
    CHECK(category == SDL_LOG_CATEGORY_SYSTEM);
    va_start(args, format);
    vsnprintf(warning, sizeof(warning), format, args);
    va_end(args);
    ++warnings;
}

static void Reset(void)
{
    CHECK(live == 0 && created == destroyed);
    created = destroyed = rejected_resource = 0;
    rejected_step = 0;
    system_writes = warnings = 0;
    system_text = "earlier-system-clipboard";
    data.record = NULL;
    record.plain = NULL;
    plain.text = NULL;
    warning[0] = '\0';
}

int main(void)
{
    const char text[] = u8"系统剪贴板😀";
    Reset();
    CHECK(OPENHARMONY_AMCL_MirrorPhoneClipboardText(NULL, text));
    CHECK(system_writes == 1 && strcmp(system_text, text) == 0 && warnings == 0);
    CHECK(created == (BOARD | DATA | RECORD | PLAIN));

    Reset();
    CHECK(OPENHARMONY_AMCL_MirrorPhoneClipboardText(NULL, NULL));
    CHECK(OPENHARMONY_AMCL_MirrorPhoneClipboardText(NULL, ""));
    const size_t oversized = 4 * 1024 * 1024 + 1;
    char *large = malloc(oversized + 1);
    CHECK(large != NULL);
    memset(large, 'x', oversized);
    large[oversized] = '\0';
    CHECK(OPENHARMONY_AMCL_MirrorPhoneClipboardText(NULL, large));
    free(large);
    CHECK(created == 0 && system_writes == 0);
    CHECK(strcmp(system_text, "earlier-system-clipboard") == 0);

    /* 系统故障不能让 SDL 报本地复制失败，也不能把游戏文本写进警告。 */
    const enum Resource resources[] = { BOARD, DATA, RECORD, PLAIN };
    for (size_t i = 0; i < sizeof(resources) / sizeof(resources[0]); ++i) {
        Reset();
        rejected_resource = resources[i];
        CHECK(OPENHARMONY_AMCL_MirrorPhoneClipboardText(NULL, text));
        CHECK(system_writes == 0 && warnings == 1 && strstr(warning, text) == NULL);
    }

    const enum Step steps[] = { SET_CONTENT, ADD_PLAIN, ADD_RECORD, SET_DATA };
    for (size_t i = 0; i < sizeof(steps) / sizeof(steps[0]); ++i) {
        Reset();
        rejected_step = steps[i];
        CHECK(OPENHARMONY_AMCL_MirrorPhoneClipboardText(NULL, text));
        CHECK(system_writes == (rejected_step == SET_DATA ? 1 : 0));
        CHECK(strcmp(system_text, "earlier-system-clipboard") == 0);
        CHECK(warnings == 1 && strstr(warning, text) == NULL);
    }
    Reset();
    puts("SDL phone clipboard: UTF-8, local success and NDK cleanup PASS");
    return 0;
}
