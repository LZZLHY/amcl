/**
 * download/net_state.h — 下载状态枚举
 *
 * 照搬 PCL2 `ModNet.vb` 的 NetState/LoadState 状态机。两层状态：
 *   - NetState：单个 NetThread / NetFile 的状态
 *   - LoadState：整个 LoaderDownload 任务的状态（对外暴露给 UI）
 */
#pragma once

#include <cstdint>
#include <string_view>

namespace download {

/**
 * NetThread / NetFile 内部状态。
 *
 * 状态机（线程视角）：
 *   WaitingForSchedule → Connecting → Reading → Downloading → Finished
 *                                                          ↘ Failed（源挂掉，重调度）
 *                                                          ↘ Aborted（外部取消）
 *
 * 状态机（文件视角）：
 *   WaitingForSchedule → CheckingLocal（检查已有文件是否满足 sha1）
 *     已满足 → Finished（跳过下载）
 *     不满足 → Downloading → FinalCheck → Finished
 *                                        ↘ Failed（校验不过）
 */
enum class NetState : uint8_t {
    WaitingForSchedule = 0,  // 等待 engine 调度
    CheckingLocal      = 1,  // NetFile 检查本地已有文件（sha1/size）
    Connecting         = 2,  // curl_easy_perform 中 HTTP 连接建立前
    Reading            = 3,  // HTTP 响应头读取中
    Downloading        = 4,  // 正在 recv body
    FinalCheck         = 5,  // NetFile 下载完成后的 sha1 终检
    Finished           = 6,  // 成功
    Failed             = 7,  // 失败（带 exception 详情）
    Aborted            = 8,  // 外部取消
};

const char* netStateToString(NetState s);

/**
 * LoaderDownload 任务级状态（对 UI / 日志友好）。
 *
 * 状态机：
 *   Waiting → Loading → Finished
 *                    ↘ Failed（某个文件最终失败）
 *                    ↘ Aborted
 */
enum class LoadState : uint8_t {
    Waiting  = 0,
    Loading  = 1,
    Finished = 2,
    Failed   = 3,
    Aborted  = 4,
};

const char* loadStateToString(LoadState s);

} // namespace download
