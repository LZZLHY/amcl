#include "driver_profile_core.h"

#include <cstdlib>
#include <iostream>

namespace {

void Require(bool condition, const char* message) {
    if (condition) return;
    std::cerr << "mg_driver_profile_core_test: FAIL: " << message << '\n';
    std::exit(1);
}

} // namespace

int main() {
    using namespace mg::platform;

    const DriverProfile maleoon = BuildProfile(PlatformKind::Ohos, "/system/lib64/libGLESv3.so", "Huawei",
                                               "Maleoon 910", "OpenGL ES 3.2", false);
    Require(maleoon.provider == ProviderKind::Native, "OHOS system GLES was not classified native");
    Require(maleoon.gpu_family == GpuFamily::Maleoon, "Maleoon family was not detected");

    const DriverProfile angle = BuildProfile(PlatformKind::Android, "/data/app/libGLESv2_angle.so", "Google Inc.",
                                             "ANGLE (Mali-G78)", "OpenGL ES 3.2", true);
    Require(angle.provider == ProviderKind::Angle, "Android ANGLE provider was not detected");
    Require(angle.gpu_family == GpuFamily::Mali, "GPU behind ANGLE was not retained in the profile");

    const DriverProfile metal = BuildProfile(PlatformKind::Apple, "libGLESv2.dylib", "Google Inc.",
                                             "ANGLE Metal Renderer: Apple M2", "OpenGL ES 3.0", false);
    Require(metal.provider == ProviderKind::MetalAngle, "Apple ANGLE/Metal provider was not detected");
    Require(metal.gpu_family == GpuFamily::Apple, "Apple GPU family was not detected");

    const DriverProfile zink = BuildProfile(PlatformKind::Generic, "/usr/lib/dri/zink_dri.so", "Mesa",
                                            "zink (RADV)", "OpenGL 4.6", false);
    Require(zink.provider == ProviderKind::Zink, "Zink provider was not detected");

    const DriverProfile xclipse = BuildProfile(PlatformKind::Android, "libGLESv3.so", "Samsung",
                                               "Xclipse 550", "OpenGL ES 3.2", false);
    Require(xclipse.gpu_family == GpuFamily::Xclipse, "Xclipse family was not detected");
    Require(std::string(PlatformName(PlatformKind::Ohos)) == "ohos" &&
                std::string(ProviderName(ProviderKind::Native)) == "native",
            "stable profile names changed");

    std::cout << "mg_driver_profile_core_test: PASS\n";
    return 0;
}
