/**
 * GUI观察/恢复的Native执行端口。进程只拥有一个固定worker，单局scope和来源lease分别
 * 退休；UI端口不进入JNI、不等待worker。lease/ticket是无回绕uint32，NAPI number可精确
 * 表示；activity仍由已校验的本局启动身份提供。旧13/完整19值包保持原字段含义。
 */
#ifndef AMCL_GAME_GUI_OBSERVATION_H
#define AMCL_GAME_GUI_OBSERVATION_H
#include "game_gui_bridge.h"
#include <cstdint>

uint32_t amcl_game_gui_start_session(uint64_t activityId);
uint32_t amcl_game_gui_capture_session();
bool amcl_game_gui_stop_session(uint32_t scope);
uint32_t amcl_game_gui_attach_source(uint32_t scope);
bool amcl_game_gui_retire_source(uint32_t source);
void amcl_read_game_gui_for_source(uint32_t source,int width,int height,const char* version,
                                  double values[AMCL_GAME_GUI_VALUE_COUNT],bool guide=false);
uint32_t amcl_restore_game_gui_for_source(uint32_t source,int scale,uint64_t revision);

namespace amcl::gui {
/** worker只拿请求副本；来源槽在JNI期间可独立退休/重用，完成只能回原source/binding。 */
struct Request {
    uint32_t scope=0,source=0,binding=0,ticket=0;
    int width=0,height=0,scale=0;
    uint64_t revision=0;
    bool guide=false;
    char version[97]{};
};
// 只允许进程worker调用这两个JNI执行端口，不能再暴露为同步NAPI getter。
void PollOnWorker(const Request&,double values[AMCL_GAME_GUI_VALUE_COUNT]);
// 正Java ID=已入游戏队列，0=拒绝，-2=同helper读任务忙；仅忙可在原2s期限内重试。
int64_t RestoreOnWorker(const Request&);
// Java游戏线程在真正写前回查Native原scope/source/resource；Begin另取得本票执行资格。
bool TicketCurrent(uint32_t ticket);
bool BeginRestore(uint32_t ticket);
#ifdef AMCL_GUI_OBSERVATION_HOST_TESTING
/** 私有只读宿主观测面，只看生产槽/真实dispatch进展，不替代任何JNI或资格算法。 */
struct Diagnostics { uint32_t sources=0,inFlight=0,queuedReads=0;uint64_t completed=0,discarded=0; };
Diagnostics ReadDiagnostics();
struct TicketDiagnostics {uint32_t id=0;int result=0;uint64_t javaId=0;};
TicketDiagnostics ReadTicketDiagnostics(uint32_t source);
#endif
}
#endif
