#include "api26_input_probe_contract.h"

#if !defined(AMCL_GLFW_API26_RAW_MOUSE_MOTION) || AMCL_GLFW_API26_RAW_MOUSE_MOTION != 1
#error "api26_input_link_probe.cpp belongs only to the formal API26 desktop build"
#endif

#if !defined(__OHOS__)
#error "api26_input_link_probe.cpp requires the HarmonyOS native toolchain"
#endif

#include <GameControllerKit/game_device.h>
#include <GameControllerKit/game_device_event.h>
#include <GameControllerKit/game_pad.h>
#include <GameControllerKit/game_pad_event.h>
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <arkui/native_key_event.h>
#include <arkui/ui_input_event.h>

namespace {

constexpr auto kProbeContract =
    amcl::input::ResolveApi26InputProbeContract(true, true);
static_assert(kProbeContract.disposition ==
              amcl::input::Api26InputProbeDisposition::CompileLinkOnly);
static_assert(kProbeContract.compileTranslationUnit);
static_assert(kProbeContract.linkGameControllerKit);
static_assert(amcl::input::IsStrictlyNonRouting(kProbeContract));
static_assert(ARKUI_UIINPUTEVENT_TYPE_KEY == 4,
              "XComponent KEY UIInputEvent ABI changed");

// Taking addresses is deliberate: it creates a compile-time signature check
// and retained link relocations without registering a callback, querying a
// device, or emitting an input event.  The exported accessor below keeps this
// surface alive under --gc-sections; the toolchain's --no-undefined then makes
// a missing libace_ndk/GameControllerKit symbol fail the formal desktop link.
struct Api26InputSymbolSurface final {
    decltype(&OH_NativeXComponent_RegisterUIInputEventCallback) registerUiInputEvent;

    decltype(&OH_ArkUI_UIInputEvent_GetType) getUiInputType;
    decltype(&OH_ArkUI_UIInputEvent_GetEventTime) getUiInputTime;
    decltype(&OH_ArkUI_UIInputEvent_GetDeviceId) getUiInputDeviceId;
    decltype(&OH_ArkUI_UIInputEvent_GetPressedKeys) getPressedKeys;
    decltype(&OH_ArkUI_UIInputEvent_GetModifierKeyStates) getModifierKeys;
    decltype(&OH_ArkUI_KeyEvent_GetType) getKeyType;
    decltype(&OH_ArkUI_KeyEvent_GetKeyCode) getKeyCode;
    decltype(&OH_ArkUI_KeyEvent_GetKeyText) getKeyText;
    decltype(&OH_ArkUI_KeyEvent_GetKeySource) getKeySource;
    decltype(&OH_ArkUI_KeyEvent_GetUnicode) getKeyUnicode;

    decltype(&OH_ArkUI_MouseEvent_GetRawDeltaX) getRawDeltaX;
    decltype(&OH_ArkUI_MouseEvent_GetRawDeltaY) getRawDeltaY;

    decltype(&OH_GameDevice_GetAllDeviceInfos) getAllGameDevices;
    decltype(&OH_GameDevice_DestroyAllDeviceInfos) destroyAllGameDevices;
    decltype(&OH_GameDevice_AllDeviceInfos_GetCount) getGameDeviceCount;
    decltype(&OH_GameDevice_AllDeviceInfos_GetDeviceInfo) getGameDeviceInfo;
    decltype(&OH_GameDevice_DeviceInfo_GetDeviceId) getGameDeviceId;
    decltype(&OH_GamePad_ButtonEvent_GetDeviceId) getGamePadButtonDeviceId;
    decltype(&OH_GamePad_AxisEvent_GetDeviceId) getGamePadAxisDeviceId;
    decltype(&OH_GamePad_AxisEvent_GetXAxisValue) getGamePadAxisX;
    decltype(&OH_GamePad_AxisEvent_GetYAxisValue) getGamePadAxisY;
};

const Api26InputSymbolSurface kApi26InputSymbolSurface = {
    &OH_NativeXComponent_RegisterUIInputEventCallback,

    &OH_ArkUI_UIInputEvent_GetType,
    &OH_ArkUI_UIInputEvent_GetEventTime,
    &OH_ArkUI_UIInputEvent_GetDeviceId,
    &OH_ArkUI_UIInputEvent_GetPressedKeys,
    &OH_ArkUI_UIInputEvent_GetModifierKeyStates,
    &OH_ArkUI_KeyEvent_GetType,
    &OH_ArkUI_KeyEvent_GetKeyCode,
    &OH_ArkUI_KeyEvent_GetKeyText,
    &OH_ArkUI_KeyEvent_GetKeySource,
    &OH_ArkUI_KeyEvent_GetUnicode,

    &OH_ArkUI_MouseEvent_GetRawDeltaX,
    &OH_ArkUI_MouseEvent_GetRawDeltaY,

    &OH_GameDevice_GetAllDeviceInfos,
    &OH_GameDevice_DestroyAllDeviceInfos,
    &OH_GameDevice_AllDeviceInfos_GetCount,
    &OH_GameDevice_AllDeviceInfos_GetDeviceInfo,
    &OH_GameDevice_DeviceInfo_GetDeviceId,
    &OH_GamePad_ButtonEvent_GetDeviceId,
    &OH_GamePad_AxisEvent_GetDeviceId,
    &OH_GamePad_AxisEvent_GetXAxisValue,
    &OH_GamePad_AxisEvent_GetYAxisValue,
};

} // namespace

extern "C" __attribute__((used, visibility("default")))
const void* AMCL_Api26InputCompileLinkSymbolSurface() noexcept {
    return &kApi26InputSymbolSurface;
}
