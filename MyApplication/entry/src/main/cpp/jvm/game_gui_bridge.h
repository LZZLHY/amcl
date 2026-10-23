#ifndef AMCL_GAME_GUI_BRIDGE_H
#define AMCL_GAME_GUI_BRIDGE_H
#include <cstdint>
// 只读数值快照与显式恢复命令。无JVM/无已初始化游戏类时返回零状态，不主动加载Minecraft。
// 原13项前缀保持，19项完整快照另含只读菜单导航；关闭教学时不遍历游戏控件。
constexpr int AMCL_GAME_GUI_VALUE_COUNT=19;
void amcl_read_game_gui(int realWidth,int realHeight,const char* gameVersion,double values[AMCL_GAME_GUI_VALUE_COUNT],bool guideActive=false);
uint64_t amcl_restore_game_gui(int scale,uint64_t expectedRevision);
#endif
