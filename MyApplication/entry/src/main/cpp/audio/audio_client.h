/** Java/OpenAL 薄客户端：验证本局宿主描述符，不创建第二份音频 Runtime。 */
#pragma once
#include "audio_runtime.h"
namespace amcl::audio {
/** 返回只读函数表；宿主撤销或 PID/会话/导出映像不符时返回 nullptr。 */
const AmclAudioApiV1 *resolveAudioHost() noexcept;
} // namespace amcl::audio
