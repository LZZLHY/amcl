#include "../../platform/egl_provider_dispatch.h"
#include <iostream>
#include <cstdlib>
#define CHECK(x) do { if (!(x)) { std::cerr << "failed line " << __LINE__ << '\n'; std::exit(1); } } while (false)
static int compatibilityCalls = 0, systemCalls = 0;
static int Compatibility(int value) { ++compatibilityCalls; return value + 10; }
static int System(int value) { ++systemCalls; return value + 20; }
int main() {
    using amcl::desktop::DispatchEglProvider;
    using amcl::desktop::EglProvider;
    using amcl::desktop::SelectEglProvider;
    CHECK(DispatchEglProvider(EglProvider::kMobileGlues, &Compatibility, &System, 5) == 15);
    CHECK(compatibilityCalls == 1 && systemCalls == 0);
    CHECK(DispatchEglProvider(EglProvider::kSystem, &Compatibility, &System, 5) == 25);
    CHECK(compatibilityCalls == 1 && systemCalls == 1);
    auto missing = static_cast<int (*)(int)>(nullptr);
    CHECK(DispatchEglProvider(EglProvider::kSystem, &Compatibility, missing, 5) == 0);
    CHECK(compatibilityCalls == 1 && systemCalls == 1);
    CHECK(DispatchEglProvider(EglProvider::kMobileGlues, &Compatibility, missing, 5) == 15);
    CHECK(compatibilityCalls == 2 && systemCalls == 1);
    CHECK(SelectEglProvider(false, "gl4es", "OPENGL") == EglProvider::kSystem);
    CHECK(SelectEglProvider(false, "mobileglues", "OPENGL") == EglProvider::kMobileGlues);
    CHECK(SelectEglProvider(true, "nativegl", "OPENGL") == EglProvider::kSystem);
    CHECK(SelectEglProvider(false, "mobilegl", "OPENGL") == EglProvider::kMobileGl);
    CHECK(DispatchEglProvider(EglProvider::kMobileGl, missing, &System, 1) == 0);
    CHECK(DispatchEglProvider(EglProvider::kMobileGl, &Compatibility, &System, 1) == 11);
    CHECK(SelectEglProvider(false, "unknown-profile", "OPENGL") == EglProvider::kUnavailable);
    CHECK(SelectEglProvider(true, "minecraft-vulkan", "VULKAN") == EglProvider::kUnavailable);
    CHECK(SelectEglProvider(false, "minecraft-vulkan", "VULKAN") == EglProvider::kUnavailable);
    CHECK(DispatchEglProvider(SelectEglProvider(false, "gl4es", "OPENGL"), &Compatibility, missing, 1) == 0);
    CHECK(DispatchEglProvider(SelectEglProvider(true, "minecraft-vulkan", "VULKAN"), &Compatibility, &System, 1) == 0);
    CHECK(compatibilityCalls == 3 && systemCalls == 1);
    std::cout << "EGL provider selection and missing-provider isolation PASS\n";
}
