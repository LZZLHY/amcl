#pragma once

#include <cstring>
#if defined(__OHOS__)
#include <dlfcn.h>
#endif

namespace amcl::input {

inline bool DesktopRawCapabilityAllowed(bool compiled, int runtimeApi,
                                       const char* deviceType) {
    return compiled && runtimeApi >= 26 && deviceType != nullptr &&
           std::strcmp(deviceType, "2in1") == 0;
}

// Resolve public API10 device-info functions without adding a newer platform
// DSO to the loader's mandatory dependency set. Missing functions fail closed.
inline bool RuntimeDesktopRawCapability(bool compiled) {
    if (!compiled) return false;
#if defined(__OHOS__)
    using ApiFn = int (*)();
    using TypeFn = const char* (*)();
    static const bool available = []() {
        void* handle = dlopen("libdeviceinfo_ndk.z.so", RTLD_NOW | RTLD_LOCAL);
        if (!handle) return false;
        const auto api = reinterpret_cast<ApiFn>(dlsym(handle, "OH_GetSdkApiVersion"));
        const auto type = reinterpret_cast<TypeFn>(dlsym(handle, "OH_GetDeviceType"));
        const bool allowed = api && type && DesktopRawCapabilityAllowed(true, api(), type());
        dlclose(handle);
        return allowed;
    }();
    return available;
#else
    // Host fixtures explicitly choose the compile capability; the pure gate
    // above is separately tested with unavailable/old/mobile environments.
    return compiled;
#endif
}

} // namespace amcl::input
