#pragma once
#include <cstring>
namespace amcl::desktop {
enum class EglProvider { kMobileGlues, kMobileGl, kSystem, kUnavailable };
inline EglProvider SelectEglProvider(bool nativeGl, const char* profile, const char* gameApi) {
    if (gameApi && std::strcmp(gameApi, "VULKAN") == 0) return EglProvider::kUnavailable;
    if (profile && std::strcmp(profile, "minecraft-vulkan") == 0)
        return EglProvider::kUnavailable;
    if (profile && std::strcmp(profile, "mobilegl") == 0) return EglProvider::kMobileGl;
    if (nativeGl || (profile && (std::strcmp(profile, "nativegl") == 0 || std::strcmp(profile, "gl4es") == 0)))
        return EglProvider::kSystem;
    if (!profile || std::strcmp(profile, "mobileglues") == 0) return EglProvider::kMobileGlues;
    return EglProvider::kUnavailable;
}
template<typename Function, typename... Args>
auto DispatchEglProvider(EglProvider provider, Function compatibility, Function system, Args... args)
    -> decltype(compatibility(args...)) {
    // compatibility 始终是本次明确选择的翻译器函数；为空时不借用系统 EGL。
    if ((provider == EglProvider::kMobileGlues || provider == EglProvider::kMobileGl) && compatibility) return compatibility(args...);
    if (provider == EglProvider::kSystem && system) return system(args...);
    return {}; // No provider may silently substitute another backend.
}
}
