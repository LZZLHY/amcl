#pragma once
#include <string.h>
#include <stdbool.h>
#ifndef AMCL_DIAGNOSTICS_MASK
// Standalone/host compilation has no authority to enable developer features.
#define AMCL_DIAGNOSTICS_MASK 0
#endif

// Severity: 0 debug, 1 info, 2+ warnings/errors. Pure policy, also host tested.
static inline bool amclDiagnosticLogAllowed(unsigned mask, int severity, const char* tag, const char* format) {
    if (severity >= 2) return true;
    if (severity <= 0 && !(mask & 1u)) return false;
    if ((mask & 5u) == 5u) return true;
    const char* verboseTags[] = {"INPUT_TRACE", "INPUT_CORE", "BACKEND_INPUT", "INPUT_INGRESS",
        "AMCL_GATE0_INPUT", "TOUCH_INPUT", "AMCL_INPOLICY", "AMCL_INSRC"};
    for (unsigned i = 0; i < sizeof(verboseTags) / sizeof(verboseTags[0]); ++i) {
        if (tag && strcmp(tag, verboseTags[i]) == 0) return false;
    }
    const char* prefixes[] = {"AMCL_LOOK", "AMCL_LOOKLAT", "AMCL_HELD", "AMCL_MOUSEIN",
        "AMCL_WHEEL", "AMCL_PADID", "AMCL_PADAXIS", "AMCL_HITTEST"};
    for (unsigned i = 0; i < sizeof(prefixes) / sizeof(prefixes[0]); ++i) {
        if (format && strstr(format, prefixes[i])) return false;
    }
    return true;
}
