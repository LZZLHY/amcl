#include "tests.h"
#include "../platform/mobilegl_capability.h"
#include <string>

// Both historical UI commands exercise the same production admission executor:
// shader compilation, pbuffer/window GPU preservation, repeated present and
// complete provider teardown. Diagnostics never convert text into evidence.
const char* runMobileglProbe(void) {
    static thread_local std::string report;
    report = amcl::graphics::MobileGlCapabilityDiagnosticReport();
    return report.c_str();
}

const char* runMobileglPbufferProbe(void) {
    return runMobileglProbe();
}
