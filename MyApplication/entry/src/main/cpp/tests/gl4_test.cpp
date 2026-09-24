// The developer tool uses the same evidence-producing probe as desktop validation.
#include "../platform/native_gl.h"
#include <sstream>
#include <string>
extern "C" const char* runGl4Test() {
    static thread_local std::string text;
    const auto result = amcl::desktop::QueryNativeGlCapability();
    std::ostringstream out;
    out << "Huawei native OpenGL probe\nquery=" << result.queryAvailable
        << " supported=" << result.querySupported << " context=" << result.contextCreated
        << " pixels=" << result.pixelVerified << " ready=" << result.ready
        << "\nstage=" << result.stage << " error=" << result.error
        << "\nversion=" << result.version << "\nvendor=" << result.vendor
        << "\nrenderer=" << result.renderer
        << "\nRequires an appropriately configured PC/tablet application. A failure is not proof that all devices lack OpenGL.\n";
    text = out.str(); return text.c_str();
}
