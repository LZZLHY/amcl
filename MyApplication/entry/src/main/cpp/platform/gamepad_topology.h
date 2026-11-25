#pragma once
#include "desktop_host_api.h"

namespace amcl::desktop {
// 在既有 reader 上保留一个负槽供 GLFW 查询热插拔。旧 reader 在启用时返回 0、停用时
// 返回 -1；新 reader 在停用时也返回有效空拓扑，故可区分“旧实现”与“已断开”。
constexpr int GamepadTopologyQuery = -2;
constexpr int GamepadTopologyChanged = 1;
constexpr int GamepadTopologyUnchanged = 2;
constexpr int GamepadSlotCount = 16;
using GamepadGenerations = uint64_t[GamepadSlotCount];
// 请求仅用 generation 传上次 revision；变化时 connected 返回位图，id 的原始字节容纳
// 各槽 64 位代次。读写两端均 memcpy，不把 char 数组转换成需要对齐的整数指针。
static_assert(sizeof(AmclDesktopGamepad::id) == sizeof(GamepadGenerations));
}
