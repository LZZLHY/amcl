#pragma once

namespace amcl::jvm {
/**
 * 依据 HotSpot 导出入口的返回值决定是否消费同步异常。
 * 模板只隔离平台 siginfo_t，生产传入真实四参数函数指针；宿主可用独立样本验证契约。
 * PC 没变化也可能是已处理的安全点；PC 变化也不能取代 VM 的返回值。
 * 首次 abort_if_unrecognized 固定为 0，将未处理结果交还调用方；调用方再决定平台分发
 * 或对已确认的同步硬件故障进入 HotSpot 致命报告，不能把返回 false 误写成“已处理”。
 */
template<class Handler, class Info>
inline bool forwardSynchronousSignal(Handler handler, int signal, Info* info, void* context) {
    return handler != nullptr && info != nullptr && context != nullptr
        && handler(signal, info, context, 0) != 0;
}
}
