// Legacy OpenGL lookup over the generated canonical profile mirror.
#ifndef AMCL_RENDERER_BACKEND_IDS_H
#define AMCL_RENDERER_BACKEND_IDS_H

#include <cstddef>
#include <string>
#include "graphics_profile_mirror.generated.h"

namespace amcl { namespace renderer {

using BackendGlLibrary = amcl::graphics::GeneratedGlLibrary;
inline constexpr const char* kDefaultBackendId = amcl::graphics::kDefaultGraphicsProfileId;
inline constexpr const auto& kBackendGlLibraries = amcl::graphics::kLegacyGlLibraries;
inline constexpr std::size_t kBackendGlLibraryCount =
    sizeof(kBackendGlLibraries) / sizeof(kBackendGlLibraries[0]);

constexpr bool StrEqual(const char* a, const char* b) {
    return amcl::graphics::GraphicsProfileStringEqual(a, b);
}
constexpr bool StrEmpty(const char* value) { return value == nullptr || value[0] == '\0'; }

// Empty legacy markers retain the default. Vulkan is deliberately absent from this GL-only view.
constexpr const BackendGlLibrary* FindBackendGlLibrary(const char* id) {
    const char* wanted = StrEmpty(id) ? kDefaultBackendId : id;
    for (std::size_t i = 0; i < kBackendGlLibraryCount; ++i) {
        if (StrEqual(wanted, kBackendGlLibraries[i].id)) return &kBackendGlLibraries[i];
    }
    return nullptr;
}
constexpr bool HasBackendGlLibrary(const char* id) { return FindBackendGlLibrary(id) != nullptr; }
inline const BackendGlLibrary* FindBackendGlLibrary(const std::string& id) {
    return FindBackendGlLibrary(id.c_str());
}
constexpr const BackendGlLibrary* DefaultBackendGlLibrary() { return FindBackendGlLibrary(kDefaultBackendId); }

namespace detail {
constexpr bool LegacyGlMirrorValid() {
    for (std::size_t i = 0; i < kBackendGlLibraryCount; ++i) {
        const BackendGlLibrary& item = kBackendGlLibraries[i];
        if (StrEmpty(item.id) || StrEmpty(item.glLibName)) return false;
        const auto* profile = amcl::graphics::FindGraphicsProfile(item.id);
        if (profile == nullptr || !StrEqual(profile->api, "OPENGL")
            || !StrEqual(profile->glLibName, item.glLibName)) return false;
        if (item.availableInThisBuild ? item.unavailableReason != nullptr : StrEmpty(item.unavailableReason)) return false;
        for (const char* p = item.id; *p != '\0'; ++p) {
            if (*p >= 'A' && *p <= 'Z') return false;
            if (p[0] == 'm' && p[1] == 'g' && p[2] == 'l') return false;
        }
        for (std::size_t j = i + 1; j < kBackendGlLibraryCount; ++j) {
            if (StrEqual(item.id, kBackendGlLibraries[j].id)) return false;
        }
    }
    return true;
}
}

static_assert(detail::LegacyGlMirrorValid(), "legacy GL view must match the canonical generated mirror");
static_assert(HasBackendGlLibrary(kDefaultBackendId), "legacy default must exist");
static_assert(DefaultBackendGlLibrary()->availableInThisBuild, "legacy default routing must be compiled");
static_assert(FindBackendGlLibrary("") == DefaultBackendGlLibrary(), "empty marker retains the default");
static_assert(FindBackendGlLibrary(nullptr) == DefaultBackendGlLibrary(), "null marker retains the default");
static_assert(FindBackendGlLibrary("nope") == nullptr, "unknown marker must fail closed");
static_assert(FindBackendGlLibrary("GL4ES") == nullptr, "lookup remains case-sensitive");
static_assert(FindBackendGlLibrary("gl4es ") == nullptr, "lookup does not trim");
static_assert(FindBackendGlLibrary("minecraft-vulkan") == nullptr, "Vulkan must not enter the legacy GL library route");

} }
#endif