#pragma once

#include <string>

namespace amcl {
// 启动前校正所选语言和移动端全屏。失败返回 false，调用者仍可用原配置继续启动。
bool updateGameOptions(const std::string &gameDir, const std::string &lang, bool forceWindowed);
}
