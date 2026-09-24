#pragma once
#include "product_diagnostics_config.h"
#ifdef __cplusplus
#include "gl/log.h"

#if !(AMCL_DIAGNOSTICS_MASK & 1)
// Keep normal MG information/warnings/errors and compile out verbose producers
// before printf, write_log and hilog fan-out. Never use GLOBAL_DEBUG_FORCE_OFF:
// that vendor switch also removes warning/error macros.
#undef LOG
#define LOG() MG_BUFFER_UPLOAD_GL_ENTRY(); MG_FRAME_STATS_ALL_GL_SCOPE()
#undef LOG_D
#define LOG_D(...) {}
#undef LOG_D_N
#define LOG_D_N(...) {}
#undef LOG_V
#define LOG_V(...) {}
#endif
#endif
