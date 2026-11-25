#pragma once

#include <stdbool.h>
#include <stddef.h>

/* 只保留构建完整 SDL 补丁单元所需的 SDK 接口。 */
struct SDL_VideoDevice;
enum { SDL_LOG_CATEGORY_SYSTEM = 3 };
size_t SDL_strnlen(const char *text, size_t max_length);
void SDL_LogWarn(int category, const char *format, ...);
