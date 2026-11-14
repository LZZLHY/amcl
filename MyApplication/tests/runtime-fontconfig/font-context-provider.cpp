/** 宿主独立 DSO：提供可控制的官方签名边界，不能用于目标平台资格。 */
#include <AbilityKit/ability_runtime/application_context.h>
#include <cassert>
#include <cstring>
#include <cstdlib>
namespace {
char fixturePath[4096];
int fixtureMode;
/** 只在未预加载 facade 的宿主用例中配置伪 Context，不属于真实 SDK 行为。 */
__attribute__((constructor)) void ConfigureFromTestEnvironment() {
    const char* path = std::getenv("AMCL_FONT_CONTEXT_FIXTURE_CACHE");
    if (path && std::strlen(path) < sizeof(fixturePath)) std::strcpy(fixturePath, path);
}
}
extern "C" void AmclFontContextFixtureConfigure(const char* path, int mode) {
    assert(path && std::strlen(path) < sizeof(fixturePath));
    std::strcpy(fixturePath, path);
    fixtureMode = mode;
}
extern "C" AbilityRuntime_ErrorCode OH_AbilityRuntime_ApplicationContextGetCacheDir(
    char* buffer, int32_t size, int32_t* written) {
    if (fixtureMode == 1) return ABILITY_RUNTIME_ERROR_CODE_CONTEXT_NOT_EXIST;
    const char* value = fixtureMode == 2 ? "relative-cache" : fixturePath;
    const auto length = std::strlen(value);
    if (!buffer || !written || size <= static_cast<int32_t>(length)) return ABILITY_RUNTIME_ERROR_CODE_PARAM_INVALID;
    std::memcpy(buffer, value, length + 1);
    *written = fixtureMode == 3 ? 0 : static_cast<int32_t>(length);
    return ABILITY_RUNTIME_ERROR_CODE_NO_ERROR;
}
