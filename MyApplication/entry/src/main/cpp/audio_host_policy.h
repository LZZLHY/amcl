/**
 * 游戏进程音频政策接点。UI 只发布用户选择/前台事实，设备操作由异步控制任务执行。
 * 系统麦克风授权在实际采集 open/start 时通过原生 AccessToken API 重新查询。
 */
#pragma once

/** 同步收紧进程政策，无设备调用、无等待；只接受 bool 已由 NAPI 校验的值。 */
void amclModAudioSetPolicy(bool enabled, bool foreground);
/** 冻结模块私有政策目录；只接受真实绝对目录，同进程后续调用不得替换根。 */
bool amclModAudioConfigureRoot(const char* filesDir);
/** 工作线程应用当前最新政策；同进程并发请求串行，旧请求不会覆盖新事实。 */
int amclModAudioApplyPolicy();
/** JVM 创建前准备唯一音频 owner，不初始化 Java 类、不打开录音或播放设备。 */
int amclModAudioBegin();
/** 游戏 Java 主入口结束后关闭全部流；本 PID 不重新建立第二个 JVM/音频会话。 */
void amclModAudioEnd();
