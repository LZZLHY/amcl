#pragma once

#include <stdint.h>

namespace amcl::clipboard {
// 将 UTF-8 纯文本写入系统剪贴板，返回写入结果。调用方负责选择设备和交互来源。
int32_t WritePlainText(const char* text);
}
