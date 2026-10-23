/**
 * download/host_admission.h — 一次真实 HTTP hop 的 Engine 主机准入租约。
 *
 * 两执行器在发请求前取得，退出时恰好归还。对象不拥有 CURL、fd 或业务 owner；
 * 未发请求/本地失败/用户取消的析构仅释放名额，不伪造主机恢复成功。
 */
#pragma once

#include <cstdint>
#include <string>
#include "engine.h"

namespace download {

class HostAdmissionLease {
public:
    HostAdmissionLease() = default;
    ~HostAdmissionLease() { finish(false); }
    HostAdmissionLease(const HostAdmissionLease&) = delete;
    HostAdmissionLease& operator=(const HostAdmissionLease&) = delete;

    /** false 只表示暂未准入；不消费实际请求/授权次数，不改变来源内容身份。 */
    bool tryAcquire(const std::string& host) {
        if (acquired_) return host_ == host;
        // 字符串分配必须在取得Engine资源之前；获取后只做无抛的整数/布尔赋值。
        host_ = host;
        uint64_t token = 0;
        if (!DownloadEngine::instance().tryAcquireHostSlot(host, &token)) return false;
        receipt_ = token; acquired_ = true; health_reported_ = false;
        return true;
    }

    /** 在途有效正文和EOF使用同一收据；健康不归还本次active名额，重复证据幂等。 */
    void noteHealthy() {
        if (!acquired_ || health_reported_) return;
        health_reported_ = true;
        DownloadEngine::instance().markHostHealthy(host_, receipt_);
    }

    /** 已验证成功才传 true；token 避免迟到请求归还另一次半开探针。 */
    void finish(bool healthy) {
        if (!acquired_) return;
        acquired_ = false;
        DownloadEngine::instance().releaseHostSlot(host_, healthy, receipt_);
    }

private:
    std::string host_;
    uint64_t receipt_ = 0;
    bool acquired_ = false;
    bool health_reported_ = false;
};

} // namespace download
