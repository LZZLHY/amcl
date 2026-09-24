#pragma once
#include "desktop_host_api.h"
namespace amcl::desktop {
bool SetNativeGamepadMode(bool enabled);
void SetGamepadFocus(bool focused);
int ReadGamepad(int slot, AmclDesktopGamepad* output);
}
