#pragma once
#include <hilog/log.h>
#include "product_diagnostics_config.h"
#include "product_diagnostics.h"

// Conditional expression keeps disabled log arguments unevaluated. The native
// file writer applies the same policy, so direct NAPI writes cannot bypass it.
#define OH_LOG_Print(type, level, domain, tag, fmt, ...) \
    (amclDiagnosticLogAllowed(AMCL_DIAGNOSTICS_MASK, \
        (level) >= LOG_WARN ? 2 : ((level) == LOG_DEBUG ? 0 : 1), tag, fmt) \
        ? OH_LOG_Print(type, level, domain, tag, fmt, ##__VA_ARGS__) : 0)
