extern "C" void amclDesktopNotifyHostEvent();
#include "desktop_gamepad.h"
#include "desktop_gamepad_mapping.h"
#include <GameControllerKit/game_device.h>
#include <GameControllerKit/game_pad.h>
#include <deviceinfo.h>
#include <dlfcn.h>
#include "../utils/amcl_log.h"
#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0xD003
#define LOG_TAG "AMCL_GAMEPAD"
#include <array>
#include <map>
#include <mutex>
#include <string>
#include <cstring>
#include <cstdlib>

namespace amcl::desktop {
namespace {
struct ControllerApi {
    decltype(&OH_GameDevice_GetAllDeviceInfos) OH_GameDevice_GetAllDeviceInfos = nullptr;
    decltype(&OH_GameDevice_RegisterDeviceMonitor) OH_GameDevice_RegisterDeviceMonitor = nullptr;
    decltype(&OH_GameDevice_UnregisterDeviceMonitor) OH_GameDevice_UnregisterDeviceMonitor = nullptr;
    decltype(&OH_GameDevice_DestroyAllDeviceInfos) OH_GameDevice_DestroyAllDeviceInfos = nullptr;
    decltype(&OH_GameDevice_AllDeviceInfos_GetCount) OH_GameDevice_AllDeviceInfos_GetCount = nullptr;
    decltype(&OH_GameDevice_AllDeviceInfos_GetDeviceInfo) OH_GameDevice_AllDeviceInfos_GetDeviceInfo = nullptr;
    decltype(&OH_GameDevice_DeviceEvent_GetChangedType) OH_GameDevice_DeviceEvent_GetChangedType = nullptr;
    decltype(&OH_GameDevice_DeviceEvent_GetDeviceInfo) OH_GameDevice_DeviceEvent_GetDeviceInfo = nullptr;
    decltype(&OH_GameDevice_DestroyDeviceInfo) OH_GameDevice_DestroyDeviceInfo = nullptr;
    decltype(&OH_GameDevice_DeviceInfo_GetDeviceId) OH_GameDevice_DeviceInfo_GetDeviceId = nullptr;
    decltype(&OH_GameDevice_DeviceInfo_GetName) OH_GameDevice_DeviceInfo_GetName = nullptr;
    decltype(&OH_GameDevice_DeviceInfo_GetDeviceType) OH_GameDevice_DeviceInfo_GetDeviceType = nullptr;
    decltype(&OH_GamePad_ButtonEvent_GetDeviceId) OH_GamePad_ButtonEvent_GetDeviceId = nullptr;
    decltype(&OH_GamePad_ButtonEvent_GetButtonAction) OH_GamePad_ButtonEvent_GetButtonAction = nullptr;
    decltype(&OH_GamePad_ButtonEvent_GetButtonCode) OH_GamePad_ButtonEvent_GetButtonCode = nullptr;
    decltype(&OH_GamePad_AxisEvent_GetDeviceId) OH_GamePad_AxisEvent_GetDeviceId = nullptr;
    decltype(&OH_GamePad_AxisEvent_GetAxisSourceType) OH_GamePad_AxisEvent_GetAxisSourceType = nullptr;
    decltype(&OH_GamePad_AxisEvent_GetXAxisValue) OH_GamePad_AxisEvent_GetXAxisValue = nullptr;
    decltype(&OH_GamePad_AxisEvent_GetYAxisValue) OH_GamePad_AxisEvent_GetYAxisValue = nullptr;
    decltype(&OH_GamePad_AxisEvent_GetZAxisValue) OH_GamePad_AxisEvent_GetZAxisValue = nullptr;
    decltype(&OH_GamePad_AxisEvent_GetRZAxisValue) OH_GamePad_AxisEvent_GetRZAxisValue = nullptr;
    decltype(&OH_GamePad_AxisEvent_GetHatXAxisValue) OH_GamePad_AxisEvent_GetHatXAxisValue = nullptr;
    decltype(&OH_GamePad_AxisEvent_GetHatYAxisValue) OH_GamePad_AxisEvent_GetHatYAxisValue = nullptr;
    decltype(&OH_GamePad_AxisEvent_GetBrakeAxisValue) OH_GamePad_AxisEvent_GetBrakeAxisValue = nullptr;
    decltype(&OH_GamePad_AxisEvent_GetGasAxisValue) OH_GamePad_AxisEvent_GetGasAxisValue = nullptr;
    decltype(&OH_GamePad_LeftShoulder_RegisterButtonInputMonitor) OH_GamePad_LeftShoulder_RegisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_LeftShoulder_UnregisterButtonInputMonitor) OH_GamePad_LeftShoulder_UnregisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_RightShoulder_RegisterButtonInputMonitor) OH_GamePad_RightShoulder_RegisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_RightShoulder_UnregisterButtonInputMonitor) OH_GamePad_RightShoulder_UnregisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_LeftTrigger_RegisterButtonInputMonitor) OH_GamePad_LeftTrigger_RegisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_LeftTrigger_UnregisterButtonInputMonitor) OH_GamePad_LeftTrigger_UnregisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_RightTrigger_RegisterButtonInputMonitor) OH_GamePad_RightTrigger_RegisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_RightTrigger_UnregisterButtonInputMonitor) OH_GamePad_RightTrigger_UnregisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_ButtonMenu_RegisterButtonInputMonitor) OH_GamePad_ButtonMenu_RegisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_ButtonMenu_UnregisterButtonInputMonitor) OH_GamePad_ButtonMenu_UnregisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_ButtonHome_RegisterButtonInputMonitor) OH_GamePad_ButtonHome_RegisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_ButtonHome_UnregisterButtonInputMonitor) OH_GamePad_ButtonHome_UnregisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_ButtonA_RegisterButtonInputMonitor) OH_GamePad_ButtonA_RegisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_ButtonA_UnregisterButtonInputMonitor) OH_GamePad_ButtonA_UnregisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_ButtonB_RegisterButtonInputMonitor) OH_GamePad_ButtonB_RegisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_ButtonB_UnregisterButtonInputMonitor) OH_GamePad_ButtonB_UnregisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_ButtonX_RegisterButtonInputMonitor) OH_GamePad_ButtonX_RegisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_ButtonX_UnregisterButtonInputMonitor) OH_GamePad_ButtonX_UnregisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_ButtonY_RegisterButtonInputMonitor) OH_GamePad_ButtonY_RegisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_ButtonY_UnregisterButtonInputMonitor) OH_GamePad_ButtonY_UnregisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_ButtonC_RegisterButtonInputMonitor) OH_GamePad_ButtonC_RegisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_ButtonC_UnregisterButtonInputMonitor) OH_GamePad_ButtonC_UnregisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor) OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_Dpad_LeftButton_UnregisterButtonInputMonitor) OH_GamePad_Dpad_LeftButton_UnregisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor) OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_Dpad_RightButton_UnregisterButtonInputMonitor) OH_GamePad_Dpad_RightButton_UnregisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor) OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_Dpad_UpButton_UnregisterButtonInputMonitor) OH_GamePad_Dpad_UpButton_UnregisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor) OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_Dpad_DownButton_UnregisterButtonInputMonitor) OH_GamePad_Dpad_DownButton_UnregisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor) OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_LeftThumbstick_UnregisterButtonInputMonitor) OH_GamePad_LeftThumbstick_UnregisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_RightThumbstick_RegisterButtonInputMonitor) OH_GamePad_RightThumbstick_RegisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_RightThumbstick_UnregisterButtonInputMonitor) OH_GamePad_RightThumbstick_UnregisterButtonInputMonitor = nullptr;
    decltype(&OH_GamePad_LeftTrigger_RegisterAxisInputMonitor) OH_GamePad_LeftTrigger_RegisterAxisInputMonitor = nullptr;
    decltype(&OH_GamePad_LeftTrigger_UnregisterAxisInputMonitor) OH_GamePad_LeftTrigger_UnregisterAxisInputMonitor = nullptr;
    decltype(&OH_GamePad_RightTrigger_RegisterAxisInputMonitor) OH_GamePad_RightTrigger_RegisterAxisInputMonitor = nullptr;
    decltype(&OH_GamePad_RightTrigger_UnregisterAxisInputMonitor) OH_GamePad_RightTrigger_UnregisterAxisInputMonitor = nullptr;
    decltype(&OH_GamePad_Dpad_RegisterAxisInputMonitor) OH_GamePad_Dpad_RegisterAxisInputMonitor = nullptr;
    decltype(&OH_GamePad_Dpad_UnregisterAxisInputMonitor) OH_GamePad_Dpad_UnregisterAxisInputMonitor = nullptr;
    decltype(&OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor) OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor = nullptr;
    decltype(&OH_GamePad_LeftThumbstick_UnregisterAxisInputMonitor) OH_GamePad_LeftThumbstick_UnregisterAxisInputMonitor = nullptr;
    decltype(&OH_GamePad_RightThumbstick_RegisterAxisInputMonitor) OH_GamePad_RightThumbstick_RegisterAxisInputMonitor = nullptr;
    decltype(&OH_GamePad_RightThumbstick_UnregisterAxisInputMonitor) OH_GamePad_RightThumbstick_UnregisterAxisInputMonitor = nullptr;
    bool ready = false;
    ControllerApi() {
        const char* type = OH_GetDeviceType();
        if (!type || strcmp(type, "2in1") != 0 || OH_GetSdkApiVersion() < 21) return;
        void* library = dlopen("libohgame_controller.z.so", RTLD_NOW | RTLD_LOCAL);
        if (!library) { AMCL_LOG_W(LOG_TAG, "GameControllerKit load failed: %{public}s", dlerror()); return; }
        OH_GameDevice_GetAllDeviceInfos = reinterpret_cast<decltype(OH_GameDevice_GetAllDeviceInfos)>(dlsym(library, "OH_GameDevice_GetAllDeviceInfos"));
        if (!OH_GameDevice_GetAllDeviceInfos) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GameDevice_GetAllDeviceInfos"); return; }
        OH_GameDevice_RegisterDeviceMonitor = reinterpret_cast<decltype(OH_GameDevice_RegisterDeviceMonitor)>(dlsym(library, "OH_GameDevice_RegisterDeviceMonitor"));
        if (!OH_GameDevice_RegisterDeviceMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GameDevice_RegisterDeviceMonitor"); return; }
        OH_GameDevice_UnregisterDeviceMonitor = reinterpret_cast<decltype(OH_GameDevice_UnregisterDeviceMonitor)>(dlsym(library, "OH_GameDevice_UnregisterDeviceMonitor"));
        if (!OH_GameDevice_UnregisterDeviceMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GameDevice_UnregisterDeviceMonitor"); return; }
        OH_GameDevice_DestroyAllDeviceInfos = reinterpret_cast<decltype(OH_GameDevice_DestroyAllDeviceInfos)>(dlsym(library, "OH_GameDevice_DestroyAllDeviceInfos"));
        if (!OH_GameDevice_DestroyAllDeviceInfos) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GameDevice_DestroyAllDeviceInfos"); return; }
        OH_GameDevice_AllDeviceInfos_GetCount = reinterpret_cast<decltype(OH_GameDevice_AllDeviceInfos_GetCount)>(dlsym(library, "OH_GameDevice_AllDeviceInfos_GetCount"));
        if (!OH_GameDevice_AllDeviceInfos_GetCount) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GameDevice_AllDeviceInfos_GetCount"); return; }
        OH_GameDevice_AllDeviceInfos_GetDeviceInfo = reinterpret_cast<decltype(OH_GameDevice_AllDeviceInfos_GetDeviceInfo)>(dlsym(library, "OH_GameDevice_AllDeviceInfos_GetDeviceInfo"));
        if (!OH_GameDevice_AllDeviceInfos_GetDeviceInfo) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GameDevice_AllDeviceInfos_GetDeviceInfo"); return; }
        OH_GameDevice_DeviceEvent_GetChangedType = reinterpret_cast<decltype(OH_GameDevice_DeviceEvent_GetChangedType)>(dlsym(library, "OH_GameDevice_DeviceEvent_GetChangedType"));
        if (!OH_GameDevice_DeviceEvent_GetChangedType) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GameDevice_DeviceEvent_GetChangedType"); return; }
        OH_GameDevice_DeviceEvent_GetDeviceInfo = reinterpret_cast<decltype(OH_GameDevice_DeviceEvent_GetDeviceInfo)>(dlsym(library, "OH_GameDevice_DeviceEvent_GetDeviceInfo"));
        if (!OH_GameDevice_DeviceEvent_GetDeviceInfo) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GameDevice_DeviceEvent_GetDeviceInfo"); return; }
        OH_GameDevice_DestroyDeviceInfo = reinterpret_cast<decltype(OH_GameDevice_DestroyDeviceInfo)>(dlsym(library, "OH_GameDevice_DestroyDeviceInfo"));
        if (!OH_GameDevice_DestroyDeviceInfo) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GameDevice_DestroyDeviceInfo"); return; }
        OH_GameDevice_DeviceInfo_GetDeviceId = reinterpret_cast<decltype(OH_GameDevice_DeviceInfo_GetDeviceId)>(dlsym(library, "OH_GameDevice_DeviceInfo_GetDeviceId"));
        if (!OH_GameDevice_DeviceInfo_GetDeviceId) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GameDevice_DeviceInfo_GetDeviceId"); return; }
        OH_GameDevice_DeviceInfo_GetName = reinterpret_cast<decltype(OH_GameDevice_DeviceInfo_GetName)>(dlsym(library, "OH_GameDevice_DeviceInfo_GetName"));
        if (!OH_GameDevice_DeviceInfo_GetName) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GameDevice_DeviceInfo_GetName"); return; }
        OH_GameDevice_DeviceInfo_GetDeviceType = reinterpret_cast<decltype(OH_GameDevice_DeviceInfo_GetDeviceType)>(dlsym(library, "OH_GameDevice_DeviceInfo_GetDeviceType"));
        if (!OH_GameDevice_DeviceInfo_GetDeviceType) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GameDevice_DeviceInfo_GetDeviceType"); return; }
        OH_GamePad_ButtonEvent_GetDeviceId = reinterpret_cast<decltype(OH_GamePad_ButtonEvent_GetDeviceId)>(dlsym(library, "OH_GamePad_ButtonEvent_GetDeviceId"));
        if (!OH_GamePad_ButtonEvent_GetDeviceId) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_ButtonEvent_GetDeviceId"); return; }
        OH_GamePad_ButtonEvent_GetButtonAction = reinterpret_cast<decltype(OH_GamePad_ButtonEvent_GetButtonAction)>(dlsym(library, "OH_GamePad_ButtonEvent_GetButtonAction"));
        if (!OH_GamePad_ButtonEvent_GetButtonAction) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_ButtonEvent_GetButtonAction"); return; }
        OH_GamePad_ButtonEvent_GetButtonCode = reinterpret_cast<decltype(OH_GamePad_ButtonEvent_GetButtonCode)>(dlsym(library, "OH_GamePad_ButtonEvent_GetButtonCode"));
        if (!OH_GamePad_ButtonEvent_GetButtonCode) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_ButtonEvent_GetButtonCode"); return; }
        OH_GamePad_AxisEvent_GetDeviceId = reinterpret_cast<decltype(OH_GamePad_AxisEvent_GetDeviceId)>(dlsym(library, "OH_GamePad_AxisEvent_GetDeviceId"));
        if (!OH_GamePad_AxisEvent_GetDeviceId) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_AxisEvent_GetDeviceId"); return; }
        OH_GamePad_AxisEvent_GetAxisSourceType = reinterpret_cast<decltype(OH_GamePad_AxisEvent_GetAxisSourceType)>(dlsym(library, "OH_GamePad_AxisEvent_GetAxisSourceType"));
        if (!OH_GamePad_AxisEvent_GetAxisSourceType) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_AxisEvent_GetAxisSourceType"); return; }
        OH_GamePad_AxisEvent_GetXAxisValue = reinterpret_cast<decltype(OH_GamePad_AxisEvent_GetXAxisValue)>(dlsym(library, "OH_GamePad_AxisEvent_GetXAxisValue"));
        if (!OH_GamePad_AxisEvent_GetXAxisValue) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_AxisEvent_GetXAxisValue"); return; }
        OH_GamePad_AxisEvent_GetYAxisValue = reinterpret_cast<decltype(OH_GamePad_AxisEvent_GetYAxisValue)>(dlsym(library, "OH_GamePad_AxisEvent_GetYAxisValue"));
        if (!OH_GamePad_AxisEvent_GetYAxisValue) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_AxisEvent_GetYAxisValue"); return; }
        OH_GamePad_AxisEvent_GetZAxisValue = reinterpret_cast<decltype(OH_GamePad_AxisEvent_GetZAxisValue)>(dlsym(library, "OH_GamePad_AxisEvent_GetZAxisValue"));
        if (!OH_GamePad_AxisEvent_GetZAxisValue) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_AxisEvent_GetZAxisValue"); return; }
        OH_GamePad_AxisEvent_GetRZAxisValue = reinterpret_cast<decltype(OH_GamePad_AxisEvent_GetRZAxisValue)>(dlsym(library, "OH_GamePad_AxisEvent_GetRZAxisValue"));
        if (!OH_GamePad_AxisEvent_GetRZAxisValue) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_AxisEvent_GetRZAxisValue"); return; }
        OH_GamePad_AxisEvent_GetHatXAxisValue = reinterpret_cast<decltype(OH_GamePad_AxisEvent_GetHatXAxisValue)>(dlsym(library, "OH_GamePad_AxisEvent_GetHatXAxisValue"));
        if (!OH_GamePad_AxisEvent_GetHatXAxisValue) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_AxisEvent_GetHatXAxisValue"); return; }
        OH_GamePad_AxisEvent_GetHatYAxisValue = reinterpret_cast<decltype(OH_GamePad_AxisEvent_GetHatYAxisValue)>(dlsym(library, "OH_GamePad_AxisEvent_GetHatYAxisValue"));
        if (!OH_GamePad_AxisEvent_GetHatYAxisValue) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_AxisEvent_GetHatYAxisValue"); return; }
        OH_GamePad_AxisEvent_GetBrakeAxisValue = reinterpret_cast<decltype(OH_GamePad_AxisEvent_GetBrakeAxisValue)>(dlsym(library, "OH_GamePad_AxisEvent_GetBrakeAxisValue"));
        if (!OH_GamePad_AxisEvent_GetBrakeAxisValue) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_AxisEvent_GetBrakeAxisValue"); return; }
        OH_GamePad_AxisEvent_GetGasAxisValue = reinterpret_cast<decltype(OH_GamePad_AxisEvent_GetGasAxisValue)>(dlsym(library, "OH_GamePad_AxisEvent_GetGasAxisValue"));
        if (!OH_GamePad_AxisEvent_GetGasAxisValue) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_AxisEvent_GetGasAxisValue"); return; }
        OH_GamePad_LeftShoulder_RegisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_LeftShoulder_RegisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_LeftShoulder_RegisterButtonInputMonitor"));
        if (!OH_GamePad_LeftShoulder_RegisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_LeftShoulder_RegisterButtonInputMonitor"); return; }
        OH_GamePad_LeftShoulder_UnregisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_LeftShoulder_UnregisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_LeftShoulder_UnregisterButtonInputMonitor"));
        if (!OH_GamePad_LeftShoulder_UnregisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_LeftShoulder_UnregisterButtonInputMonitor"); return; }
        OH_GamePad_RightShoulder_RegisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_RightShoulder_RegisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_RightShoulder_RegisterButtonInputMonitor"));
        if (!OH_GamePad_RightShoulder_RegisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_RightShoulder_RegisterButtonInputMonitor"); return; }
        OH_GamePad_RightShoulder_UnregisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_RightShoulder_UnregisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_RightShoulder_UnregisterButtonInputMonitor"));
        if (!OH_GamePad_RightShoulder_UnregisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_RightShoulder_UnregisterButtonInputMonitor"); return; }
        OH_GamePad_LeftTrigger_RegisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_LeftTrigger_RegisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_LeftTrigger_RegisterButtonInputMonitor"));
        if (!OH_GamePad_LeftTrigger_RegisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_LeftTrigger_RegisterButtonInputMonitor"); return; }
        OH_GamePad_LeftTrigger_UnregisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_LeftTrigger_UnregisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_LeftTrigger_UnregisterButtonInputMonitor"));
        if (!OH_GamePad_LeftTrigger_UnregisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_LeftTrigger_UnregisterButtonInputMonitor"); return; }
        OH_GamePad_RightTrigger_RegisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_RightTrigger_RegisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_RightTrigger_RegisterButtonInputMonitor"));
        if (!OH_GamePad_RightTrigger_RegisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_RightTrigger_RegisterButtonInputMonitor"); return; }
        OH_GamePad_RightTrigger_UnregisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_RightTrigger_UnregisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_RightTrigger_UnregisterButtonInputMonitor"));
        if (!OH_GamePad_RightTrigger_UnregisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_RightTrigger_UnregisterButtonInputMonitor"); return; }
        OH_GamePad_ButtonMenu_RegisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_ButtonMenu_RegisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_ButtonMenu_RegisterButtonInputMonitor"));
        if (!OH_GamePad_ButtonMenu_RegisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_ButtonMenu_RegisterButtonInputMonitor"); return; }
        OH_GamePad_ButtonMenu_UnregisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_ButtonMenu_UnregisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_ButtonMenu_UnregisterButtonInputMonitor"));
        if (!OH_GamePad_ButtonMenu_UnregisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_ButtonMenu_UnregisterButtonInputMonitor"); return; }
        OH_GamePad_ButtonHome_RegisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_ButtonHome_RegisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_ButtonHome_RegisterButtonInputMonitor"));
        if (!OH_GamePad_ButtonHome_RegisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_ButtonHome_RegisterButtonInputMonitor"); return; }
        OH_GamePad_ButtonHome_UnregisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_ButtonHome_UnregisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_ButtonHome_UnregisterButtonInputMonitor"));
        if (!OH_GamePad_ButtonHome_UnregisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_ButtonHome_UnregisterButtonInputMonitor"); return; }
        OH_GamePad_ButtonA_RegisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_ButtonA_RegisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_ButtonA_RegisterButtonInputMonitor"));
        if (!OH_GamePad_ButtonA_RegisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_ButtonA_RegisterButtonInputMonitor"); return; }
        OH_GamePad_ButtonA_UnregisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_ButtonA_UnregisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_ButtonA_UnregisterButtonInputMonitor"));
        if (!OH_GamePad_ButtonA_UnregisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_ButtonA_UnregisterButtonInputMonitor"); return; }
        OH_GamePad_ButtonB_RegisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_ButtonB_RegisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_ButtonB_RegisterButtonInputMonitor"));
        if (!OH_GamePad_ButtonB_RegisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_ButtonB_RegisterButtonInputMonitor"); return; }
        OH_GamePad_ButtonB_UnregisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_ButtonB_UnregisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_ButtonB_UnregisterButtonInputMonitor"));
        if (!OH_GamePad_ButtonB_UnregisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_ButtonB_UnregisterButtonInputMonitor"); return; }
        OH_GamePad_ButtonX_RegisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_ButtonX_RegisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_ButtonX_RegisterButtonInputMonitor"));
        if (!OH_GamePad_ButtonX_RegisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_ButtonX_RegisterButtonInputMonitor"); return; }
        OH_GamePad_ButtonX_UnregisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_ButtonX_UnregisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_ButtonX_UnregisterButtonInputMonitor"));
        if (!OH_GamePad_ButtonX_UnregisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_ButtonX_UnregisterButtonInputMonitor"); return; }
        OH_GamePad_ButtonY_RegisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_ButtonY_RegisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_ButtonY_RegisterButtonInputMonitor"));
        if (!OH_GamePad_ButtonY_RegisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_ButtonY_RegisterButtonInputMonitor"); return; }
        OH_GamePad_ButtonY_UnregisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_ButtonY_UnregisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_ButtonY_UnregisterButtonInputMonitor"));
        if (!OH_GamePad_ButtonY_UnregisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_ButtonY_UnregisterButtonInputMonitor"); return; }
        OH_GamePad_ButtonC_RegisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_ButtonC_RegisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_ButtonC_RegisterButtonInputMonitor"));
        if (!OH_GamePad_ButtonC_RegisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_ButtonC_RegisterButtonInputMonitor"); return; }
        OH_GamePad_ButtonC_UnregisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_ButtonC_UnregisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_ButtonC_UnregisterButtonInputMonitor"));
        if (!OH_GamePad_ButtonC_UnregisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_ButtonC_UnregisterButtonInputMonitor"); return; }
        OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor"));
        if (!OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor"); return; }
        OH_GamePad_Dpad_LeftButton_UnregisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_Dpad_LeftButton_UnregisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_Dpad_LeftButton_UnregisterButtonInputMonitor"));
        if (!OH_GamePad_Dpad_LeftButton_UnregisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_Dpad_LeftButton_UnregisterButtonInputMonitor"); return; }
        OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor"));
        if (!OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor"); return; }
        OH_GamePad_Dpad_RightButton_UnregisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_Dpad_RightButton_UnregisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_Dpad_RightButton_UnregisterButtonInputMonitor"));
        if (!OH_GamePad_Dpad_RightButton_UnregisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_Dpad_RightButton_UnregisterButtonInputMonitor"); return; }
        OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor"));
        if (!OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor"); return; }
        OH_GamePad_Dpad_UpButton_UnregisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_Dpad_UpButton_UnregisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_Dpad_UpButton_UnregisterButtonInputMonitor"));
        if (!OH_GamePad_Dpad_UpButton_UnregisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_Dpad_UpButton_UnregisterButtonInputMonitor"); return; }
        OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor"));
        if (!OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor"); return; }
        OH_GamePad_Dpad_DownButton_UnregisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_Dpad_DownButton_UnregisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_Dpad_DownButton_UnregisterButtonInputMonitor"));
        if (!OH_GamePad_Dpad_DownButton_UnregisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_Dpad_DownButton_UnregisterButtonInputMonitor"); return; }
        OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor"));
        if (!OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor"); return; }
        OH_GamePad_LeftThumbstick_UnregisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_LeftThumbstick_UnregisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_LeftThumbstick_UnregisterButtonInputMonitor"));
        if (!OH_GamePad_LeftThumbstick_UnregisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_LeftThumbstick_UnregisterButtonInputMonitor"); return; }
        OH_GamePad_RightThumbstick_RegisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_RightThumbstick_RegisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_RightThumbstick_RegisterButtonInputMonitor"));
        if (!OH_GamePad_RightThumbstick_RegisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_RightThumbstick_RegisterButtonInputMonitor"); return; }
        OH_GamePad_RightThumbstick_UnregisterButtonInputMonitor = reinterpret_cast<decltype(OH_GamePad_RightThumbstick_UnregisterButtonInputMonitor)>(dlsym(library, "OH_GamePad_RightThumbstick_UnregisterButtonInputMonitor"));
        if (!OH_GamePad_RightThumbstick_UnregisterButtonInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_RightThumbstick_UnregisterButtonInputMonitor"); return; }
        OH_GamePad_LeftTrigger_RegisterAxisInputMonitor = reinterpret_cast<decltype(OH_GamePad_LeftTrigger_RegisterAxisInputMonitor)>(dlsym(library, "OH_GamePad_LeftTrigger_RegisterAxisInputMonitor"));
        if (!OH_GamePad_LeftTrigger_RegisterAxisInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_LeftTrigger_RegisterAxisInputMonitor"); return; }
        OH_GamePad_LeftTrigger_UnregisterAxisInputMonitor = reinterpret_cast<decltype(OH_GamePad_LeftTrigger_UnregisterAxisInputMonitor)>(dlsym(library, "OH_GamePad_LeftTrigger_UnregisterAxisInputMonitor"));
        if (!OH_GamePad_LeftTrigger_UnregisterAxisInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_LeftTrigger_UnregisterAxisInputMonitor"); return; }
        OH_GamePad_RightTrigger_RegisterAxisInputMonitor = reinterpret_cast<decltype(OH_GamePad_RightTrigger_RegisterAxisInputMonitor)>(dlsym(library, "OH_GamePad_RightTrigger_RegisterAxisInputMonitor"));
        if (!OH_GamePad_RightTrigger_RegisterAxisInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_RightTrigger_RegisterAxisInputMonitor"); return; }
        OH_GamePad_RightTrigger_UnregisterAxisInputMonitor = reinterpret_cast<decltype(OH_GamePad_RightTrigger_UnregisterAxisInputMonitor)>(dlsym(library, "OH_GamePad_RightTrigger_UnregisterAxisInputMonitor"));
        if (!OH_GamePad_RightTrigger_UnregisterAxisInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_RightTrigger_UnregisterAxisInputMonitor"); return; }
        OH_GamePad_Dpad_RegisterAxisInputMonitor = reinterpret_cast<decltype(OH_GamePad_Dpad_RegisterAxisInputMonitor)>(dlsym(library, "OH_GamePad_Dpad_RegisterAxisInputMonitor"));
        if (!OH_GamePad_Dpad_RegisterAxisInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_Dpad_RegisterAxisInputMonitor"); return; }
        OH_GamePad_Dpad_UnregisterAxisInputMonitor = reinterpret_cast<decltype(OH_GamePad_Dpad_UnregisterAxisInputMonitor)>(dlsym(library, "OH_GamePad_Dpad_UnregisterAxisInputMonitor"));
        if (!OH_GamePad_Dpad_UnregisterAxisInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_Dpad_UnregisterAxisInputMonitor"); return; }
        OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor = reinterpret_cast<decltype(OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor)>(dlsym(library, "OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor"));
        if (!OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor"); return; }
        OH_GamePad_LeftThumbstick_UnregisterAxisInputMonitor = reinterpret_cast<decltype(OH_GamePad_LeftThumbstick_UnregisterAxisInputMonitor)>(dlsym(library, "OH_GamePad_LeftThumbstick_UnregisterAxisInputMonitor"));
        if (!OH_GamePad_LeftThumbstick_UnregisterAxisInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_LeftThumbstick_UnregisterAxisInputMonitor"); return; }
        OH_GamePad_RightThumbstick_RegisterAxisInputMonitor = reinterpret_cast<decltype(OH_GamePad_RightThumbstick_RegisterAxisInputMonitor)>(dlsym(library, "OH_GamePad_RightThumbstick_RegisterAxisInputMonitor"));
        if (!OH_GamePad_RightThumbstick_RegisterAxisInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_RightThumbstick_RegisterAxisInputMonitor"); return; }
        OH_GamePad_RightThumbstick_UnregisterAxisInputMonitor = reinterpret_cast<decltype(OH_GamePad_RightThumbstick_UnregisterAxisInputMonitor)>(dlsym(library, "OH_GamePad_RightThumbstick_UnregisterAxisInputMonitor"));
        if (!OH_GamePad_RightThumbstick_UnregisterAxisInputMonitor) { AMCL_LOG_W(LOG_TAG, "GameControllerKit symbol missing: OH_GamePad_RightThumbstick_UnregisterAxisInputMonitor"); return; }
        ready = true;
    }
};
ControllerApi& Api() { static ControllerApi api; return api; }
std::mutex mutex;
std::array<AmclDesktopGamepad, 16> pads{};
std::array<unsigned char, 16> digitalHats{};
std::map<std::string, uint64_t> changed;
uint64_t deviceEpoch = 0;
bool nativeMode = false, focused = false, started = false, attempted = false;
int Find(const std::string& id) {
    for (size_t i = 0; i < pads.size(); ++i) if (pads[i].connected && id == pads[i].id) return static_cast<int>(i);
    return -1;
}
void Neutral(AmclDesktopGamepad& pad) {
    memset(pad.buttons, 0, sizeof(pad.buttons)); memset(pad.axes, 0, sizeof(pad.axes));
    pad.axes[4] = pad.axes[5] = -1; pad.hats[0] = 0;
}
void DeviceInfo(GameDevice_DeviceInfo* info, bool online, bool inventory, uint64_t baseline) {
    char* rawId = nullptr; char* name = nullptr;
    auto& api = Api();
    if (api.OH_GameDevice_DeviceInfo_GetDeviceId(info, &rawId) != GAME_CONTROLLER_SUCCESS || !rawId) { free(rawId); return; }
    const std::string id(rawId); free(rawId);
    if (id.empty() || id.size() >= sizeof(pads[0].id)) return;
    api.OH_GameDevice_DeviceInfo_GetName(info, &name);
    GameDevice_DeviceType type = UNKNOWN;
    api.OH_GameDevice_DeviceInfo_GetDeviceType(info, &type);
    {
        std::lock_guard<std::mutex> lock(mutex);
        if (inventory && changed[id] > baseline) { free(name); return; }
        if (!inventory) changed[id] = ++deviceEpoch;
        int slot = Find(id);
        if (!online) { if (slot >= 0) { pads[slot].connected = 0; Neutral(pads[slot]); ++pads[slot].generation; } }
        else if (type == GAME_PAD) {
            if (slot < 0) for (size_t i = 0; i < pads.size(); ++i) if (!pads[i].connected) { slot = static_cast<int>(i); break; }
            if (slot >= 0 && !pads[slot].connected) {
                const uint64_t generation = pads[slot].generation + 1;
                pads[slot] = {}; pads[slot].generation = generation; Neutral(pads[slot]);
                pads[slot].connected = 1;
                snprintf(pads[slot].id, sizeof(pads[slot].id), "%s", id.c_str());
                snprintf(pads[slot].name, sizeof(pads[slot].name), "%s", name ? name : "Game Controller");
                digitalHats[slot] = 0;
            }
        }
    }
    free(name);
    amclDesktopNotifyHostEvent();
}
void OnDevice(const GameDevice_DeviceEvent* event) {
    auto& api = Api(); GameDevice_StatusChangedType type; GameDevice_DeviceInfo* info = nullptr;
    if (api.OH_GameDevice_DeviceEvent_GetChangedType(event, &type) != GAME_CONTROLLER_SUCCESS) return;
    if (api.OH_GameDevice_DeviceEvent_GetDeviceInfo(event, &info) == GAME_CONTROLLER_SUCCESS && info)
        DeviceInfo(info, type == ONLINE, false, 0);
    if (info) api.OH_GameDevice_DestroyDeviceInfo(&info);
}
void OnButton(const GamePad_ButtonEvent* event) {
    auto& api = Api(); char* rawId = nullptr; int32_t code = 0; GamePad_Button_ActionType action;
    if (api.OH_GamePad_ButtonEvent_GetDeviceId(event, &rawId) != GAME_CONTROLLER_SUCCESS || !rawId) { free(rawId); return; }
    const std::string id(rawId); free(rawId);
    if (api.OH_GamePad_ButtonEvent_GetButtonCode(event, &code) != GAME_CONTROLLER_SUCCESS ||
        api.OH_GamePad_ButtonEvent_GetButtonAction(event, &action) != GAME_CONTROLLER_SUCCESS) return;
    const int button = StandardGamepadButton(code); if (button < 0) return;
    std::lock_guard<std::mutex> lock(mutex);
    const int slot = Find(id); if (slot < 0 || !nativeMode || !focused) return;
    pads[slot].buttons[button] = action == DOWN ? 1 : 0; ++pads[slot].events; amclDesktopNotifyHostEvent();
    if (button >= 11 && button <= 14) {
        const unsigned char bit = static_cast<unsigned char>(1 << (button - 11));
        if (action == DOWN) digitalHats[slot] |= bit; else digitalHats[slot] &= ~bit;
    }
}
void OnAxis(const GamePad_AxisEvent* event) {
    auto& api = Api(); char* rawId = nullptr; GamePad_AxisSourceType source;
    if (api.OH_GamePad_AxisEvent_GetDeviceId(event, &rawId) != GAME_CONTROLLER_SUCCESS || !rawId) { free(rawId); return; }
    const std::string id(rawId); free(rawId);
    if (api.OH_GamePad_AxisEvent_GetAxisSourceType(event, &source) != GAME_CONTROLLER_SUCCESS) return;
    double x = 0, y = 0; int first = -1; bool hat = false;
    int error = 0;
    switch (source) {
        case LEFT_THUMBSTICK: first=0; error=api.OH_GamePad_AxisEvent_GetXAxisValue(event,&x); error|=api.OH_GamePad_AxisEvent_GetYAxisValue(event,&y); break;
        case RIGHT_THUMBSTICK: first=2; error=api.OH_GamePad_AxisEvent_GetZAxisValue(event,&x); error|=api.OH_GamePad_AxisEvent_GetRZAxisValue(event,&y); break;
        case LEFT_TRIGGER: first=4; error=api.OH_GamePad_AxisEvent_GetBrakeAxisValue(event,&x); break;
        case RIGHT_TRIGGER: first=5; error=api.OH_GamePad_AxisEvent_GetGasAxisValue(event,&x); break;
        case DPAD: hat=true; error=api.OH_GamePad_AxisEvent_GetHatXAxisValue(event,&x); error|=api.OH_GamePad_AxisEvent_GetHatYAxisValue(event,&y); break;
        default: return;
    }
    if (error || !std::isfinite(x) || !std::isfinite(y)) return;
    std::lock_guard<std::mutex> lock(mutex);
    const int slot=Find(id); if(slot<0 || !nativeMode || !focused) return;
    if(hat) pads[slot].hats[0]=GamepadHat(x,y);
    else { pads[slot].axes[first]=GamepadAxis(x); if(first<4) pads[slot].axes[first+1]=GamepadAxis(y); }
    ++pads[slot].events; amclDesktopNotifyHostEvent();
}
bool ControllerResult(int error, const char* stage) {
    if (error == GAME_CONTROLLER_SUCCESS) return true;
    AMCL_LOG_W(LOG_TAG, "GameControllerKit %{public}s failed: %{public}d", stage, error);
    return false;
}
bool Start() {
    auto& api=Api(); if(!api.ready) return false;
    if(!ControllerResult(api.OH_GameDevice_RegisterDeviceMonitor(OnDevice), "OH_GameDevice_RegisterDeviceMonitor")) return false;
    bool ok=true;
    if(!ControllerResult(api.OH_GamePad_LeftShoulder_RegisterButtonInputMonitor(OnButton), "OH_GamePad_LeftShoulder_RegisterButtonInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_RightShoulder_RegisterButtonInputMonitor(OnButton), "OH_GamePad_RightShoulder_RegisterButtonInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_LeftTrigger_RegisterButtonInputMonitor(OnButton), "OH_GamePad_LeftTrigger_RegisterButtonInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_RightTrigger_RegisterButtonInputMonitor(OnButton), "OH_GamePad_RightTrigger_RegisterButtonInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_ButtonMenu_RegisterButtonInputMonitor(OnButton), "OH_GamePad_ButtonMenu_RegisterButtonInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_ButtonHome_RegisterButtonInputMonitor(OnButton), "OH_GamePad_ButtonHome_RegisterButtonInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_ButtonA_RegisterButtonInputMonitor(OnButton), "OH_GamePad_ButtonA_RegisterButtonInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_ButtonB_RegisterButtonInputMonitor(OnButton), "OH_GamePad_ButtonB_RegisterButtonInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_ButtonX_RegisterButtonInputMonitor(OnButton), "OH_GamePad_ButtonX_RegisterButtonInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_ButtonY_RegisterButtonInputMonitor(OnButton), "OH_GamePad_ButtonY_RegisterButtonInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_ButtonC_RegisterButtonInputMonitor(OnButton), "OH_GamePad_ButtonC_RegisterButtonInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor(OnButton), "OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor(OnButton), "OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor(OnButton), "OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor(OnButton), "OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor(OnButton), "OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_RightThumbstick_RegisterButtonInputMonitor(OnButton), "OH_GamePad_RightThumbstick_RegisterButtonInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_LeftTrigger_RegisterAxisInputMonitor(OnAxis), "OH_GamePad_LeftTrigger_RegisterAxisInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_RightTrigger_RegisterAxisInputMonitor(OnAxis), "OH_GamePad_RightTrigger_RegisterAxisInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_Dpad_RegisterAxisInputMonitor(OnAxis), "OH_GamePad_Dpad_RegisterAxisInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor(OnAxis), "OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor")) ok=false;
    if(!ControllerResult(api.OH_GamePad_RightThumbstick_RegisterAxisInputMonitor(OnAxis), "OH_GamePad_RightThumbstick_RegisterAxisInputMonitor")) ok=false;
    uint64_t baseline; { std::lock_guard<std::mutex> lock(mutex); baseline=deviceEpoch; }
    GameDevice_AllDeviceInfos* all=nullptr;
    if (ok) {
        ok=ControllerResult(api.OH_GameDevice_GetAllDeviceInfos(&all), "GetAllDeviceInfos") && all;
        int32_t count=0;
        if (ok) ok=ControllerResult(api.OH_GameDevice_AllDeviceInfos_GetCount(all,&count), "GetCount") && count>=0;
        for(int i=0;ok && i<count;++i) {
            GameDevice_DeviceInfo* info=nullptr;
            ok=ControllerResult(api.OH_GameDevice_AllDeviceInfos_GetDeviceInfo(all,i,&info), "GetDeviceInfo") && info;
            if(ok) DeviceInfo(info,true,true,baseline);
            if(info) api.OH_GameDevice_DestroyDeviceInfo(&info);
        }
    }
    if(all) api.OH_GameDevice_DestroyAllDeviceInfos(&all);
    if(!ok) {
        api.OH_GamePad_LeftShoulder_UnregisterButtonInputMonitor();
        api.OH_GamePad_RightShoulder_UnregisterButtonInputMonitor();
        api.OH_GamePad_LeftTrigger_UnregisterButtonInputMonitor();
        api.OH_GamePad_RightTrigger_UnregisterButtonInputMonitor();
        api.OH_GamePad_ButtonMenu_UnregisterButtonInputMonitor();
        api.OH_GamePad_ButtonHome_UnregisterButtonInputMonitor();
        api.OH_GamePad_ButtonA_UnregisterButtonInputMonitor();
        api.OH_GamePad_ButtonB_UnregisterButtonInputMonitor();
        api.OH_GamePad_ButtonX_UnregisterButtonInputMonitor();
        api.OH_GamePad_ButtonY_UnregisterButtonInputMonitor();
        api.OH_GamePad_ButtonC_UnregisterButtonInputMonitor();
        api.OH_GamePad_Dpad_LeftButton_UnregisterButtonInputMonitor();
        api.OH_GamePad_Dpad_RightButton_UnregisterButtonInputMonitor();
        api.OH_GamePad_Dpad_UpButton_UnregisterButtonInputMonitor();
        api.OH_GamePad_Dpad_DownButton_UnregisterButtonInputMonitor();
        api.OH_GamePad_LeftThumbstick_UnregisterButtonInputMonitor();
        api.OH_GamePad_RightThumbstick_UnregisterButtonInputMonitor();
        api.OH_GamePad_LeftTrigger_UnregisterAxisInputMonitor();
        api.OH_GamePad_RightTrigger_UnregisterAxisInputMonitor();
        api.OH_GamePad_Dpad_UnregisterAxisInputMonitor();
        api.OH_GamePad_LeftThumbstick_UnregisterAxisInputMonitor();
        api.OH_GamePad_RightThumbstick_UnregisterAxisInputMonitor();
        api.OH_GameDevice_UnregisterDeviceMonitor(); return false;
    }
    return true;
}
}
bool SetNativeGamepadMode(bool enabled) {
    // Called on the owning UI thread before the game's input component starts.
    if(enabled && !attempted) { attempted=true; started=Start(); }
    std::lock_guard<std::mutex> lock(mutex);
    nativeMode=enabled && started;
    for(auto& pad:pads) Neutral(pad);
    digitalHats.fill(0);
    return !enabled || nativeMode;
}
void SetGamepadFocus(bool value) {
    std::lock_guard<std::mutex> lock(mutex); focused=value;
    if(!value) { for(auto& pad:pads) Neutral(pad); digitalHats.fill(0); }
    amclDesktopNotifyHostEvent();
}
int ReadGamepad(int slot, AmclDesktopGamepad* output) {
    if(!output || slot<0 || slot>=static_cast<int>(pads.size())) return 0;
    std::lock_guard<std::mutex> lock(mutex); *output=pads[slot];
    if(!nativeMode) output->connected=0;
    output->hats[0] |= digitalHats[slot];
    for(int i=0;i<4;++i) output->buttons[11+i] |= (output->hats[0] & (1<<i)) ? 1 : 0;
    return output->connected;
}
}
