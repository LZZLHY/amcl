/* 可选库缺失与库已存在但符号不完整分开记录，后者不能冒充零设备成功。
 * dlopen成功引用由api持有，所有解析失败均回滚该引用和整张表。 */
#include "midi_api.h"
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
int amcl_midi_api_load(AmclMidiApi* api, char* error, size_t errorSize) {
    if (!api) return AMCL_MIDI_API_BROKEN;
    memset(api, 0, sizeof(*api));
    if (error && errorSize) error[0] = 0;
    api->library = dlopen("libohmidi.so", RTLD_NOW | RTLD_LOCAL);
    if (!api->library) {
        const char* why = dlerror();
        if (error && errorSize) snprintf(error, errorSize, "OH_MIDI unavailable: %s", why ? why : "dlopen failed");
        return AMCL_MIDI_API_UNAVAILABLE;
    }
#define AMCL_MIDI_API_RESOLVE(field, symbol) do { \
        dlerror(); \
        api->field = (__typeof__(api->field))dlsym(api->library, #symbol); \
        if (!api->field) { \
            const char* why = dlerror(); \
            if (error && errorSize) snprintf(error, errorSize, "OH_MIDI missing %s: %s", #symbol, why ? why : "null symbol"); \
            amcl_midi_api_close(api); \
            return AMCL_MIDI_API_BROKEN; \
        } \
    } while (0);
    AMCL_MIDI_API_MEMBERS(AMCL_MIDI_API_RESOLVE)
#undef AMCL_MIDI_API_RESOLVE
    return AMCL_MIDI_API_OK;
}
void amcl_midi_api_close(AmclMidiApi* api) {
    if (!api) return;
    void* library = api->library;
    memset(api, 0, sizeof(*api));
    if (library) dlclose(library);
}
