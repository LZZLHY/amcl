#include "../../utils/product_diagnostics.h"
#include <cstdlib>

static void check(bool value) { if (!value) std::abort(); }
int main() {
    check(!amclDiagnosticLogAllowed(0, 0, "Downloader", "debug"));
    check(amclDiagnosticLogAllowed(1, 0, "Downloader", "debug"));
    check(amclDiagnosticLogAllowed(0, 1, "JVM", "starting backend"));
    check(!amclDiagnosticLogAllowed(0, 1, "INPUT_TRACE", "sample"));
    check(!amclDiagnosticLogAllowed(1, 1, "INPUT_TRACE", "sample"));
    check(amclDiagnosticLogAllowed(5, 1, "INPUT_TRACE", "sample"));
    check(!amclDiagnosticLogAllowed(0, 1, "GLFW", "AMCL_LOOK delta"));
    for (int severity = 2; severity <= 4; ++severity) {
        check(amclDiagnosticLogAllowed(0, severity, "INPUT_TRACE", "AMCL_LOOK failure"));
        check(amclDiagnosticLogAllowed(0, severity, nullptr, nullptr));
    }
}
