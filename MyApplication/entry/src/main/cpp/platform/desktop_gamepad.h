#pragma once
#include "desktop_host_api.h"
#include <optional>
namespace amcl::desktop {
extern "C" __attribute__((visibility("default"))) int32_t amclGamepadRead(int32_t slot, AmclDesktopGamepad* output);
bool SetNativeGamepadMode(bool enabled);
void SetGamepadFocus(bool focused, std::optional<bool> routed);
int ReadGamepad(int slot, AmclDesktopGamepad* output);
}
