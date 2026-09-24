#include "product_diagnostics_config.h"

// Kept in both native images and audited against the HAP's product metadata.
extern "C" __attribute__((visibility("default")))
const char* amclDiagnosticBuildIdentity() {
    return AMCL_DIAGNOSTICS_MARKER;
}
