/**
 * download/relay.h — AMCL 加速网关客户端（native 侧）
 *
 * 分工说明（为什么签名必须在这里做）：
 *   · ArkTS 侧（RelayClient.ets）负责**握手**：用内置密钥做 HMAC 签名换取
 *     `ticket` + `sessionKey`，然后调 downloadSetRelay(...) 注入进来；
 *   · native 侧负责**每个请求的持有证明**：分段下载中每个段都是独立 HTTP 请求，
 *     各自需要自己的 ts/nonce/签名，只有真正发请求的这一层（net_thread）能算。
 *
 * URL 改写同样放在 native：引擎内部会跟随重定向、换源、重试，改写点必须贴着
 * 实际发出的那次请求，否则会出现"改写过的 URL 又被换回官方源"之类的错位。
 *
 * 线程安全：配置由 ArkTS 线程写、多个下载 worker 读，用读写锁保护；
 * 票据快过期时由 ArkTS 侧提前续签并再次注入（native 不主动发起网络握手）。
 */
#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace download {

/** 加速网关运行期配置 */
struct RelayConfig {
    bool        enabled = false;
    std::string base;          // 形如 https://relay.amcl.lovedhy.cn/dl（无尾斜杠）
    std::string ticket;        // Bearer 票据
    std::string session_key;   // 持有证明密钥（仅内存）
    bool        require_proof = true;
    int64_t     expires_at_ms = 0;   // 票据到期时刻（本地时钟）
};

/** 设置/更新配置（ArkTS 握手成功后调用；enabled=false 即整体关闭） */
void relaySetConfig(const RelayConfig& cfg);

/** 关闭加速（用户关开关 / 握手失败 / 网关不可用时） */
void relayDisable();

/**
 * 一次实际 hop 的内存请求计划。URL和凭据来自同一配置快照，避免配置轮换时把旧URL
 * 与新票据拼在一起；headers只交给本次easy handle，不写日志或文件。
 * generation只用于提交前撤销旧计划，不承诺取消已经提交的在途HTTP。
 */
struct RelayRequestPlan {
    std::string url;
    std::vector<std::string> headers;
    uint64_t generation = 0;
    bool via_relay = false;
    bool fallback = false;
};

/**
 * 构造GET/HEAD请求计划：普通官方源可改写，redirect hop只允许给当前受信 /p/ URL
 * 重新签名。带业务Bearer的任务必须传allow_relay=false；force_direct表示上次网关
 * 失败后的同源直连重试，不改变队列、Range或任务权限预算。
 */
RelayRequestPlan relayPrepareRequest(const std::string& method, const std::string& url,
                                    bool allow_relay, bool rewrite_official = true,
                                    bool force_direct = false);

/**
 * 提交请求的线性化边界。网关计划在共享配置锁内校验代次，并执行一个不阻塞、不重入
 * Relay API的submit回调；callback成功才计请求。worker回调只发布即将执行的transport，
 * CURLM回调只执行add_handle。锁不跨网络IO，关闭只阻止尚未提交的旧计划。
 * requests表示已提交的网关传输尝试，不表示服务端收到或成功；fallbacks只计实际提交
 * 的失败后直连尝试。返回false可能是旧计划已撤销，或submit自身拒绝，调用方保留原因。
 */
bool relaySubmitRequest(const RelayRequestPlan& plan, const std::function<bool()>& submit);

/** 当前是否可用（已启用 + 票据未过期 + 必要字段齐全） */
bool relayUsable();

/**
 * 判断某个 URL 是否可经网关加速。
 * 只对**官方源主机**放行——这与"打开加速就全走官方通道"的产品语义一致：
 * 镜像源（BMCLAPI / mcim 等）不改写，因为网关自己到官方源就很快，
 * 再套一层镜像只会多一跳、还可能撞上镜像的回源未命中。
 */
bool relayCanAccelerate(const std::string& url);

/**
 * 把官方源 URL 改写成经网关的 URL。
 *   https://cdn.modrinth.com/data/x.jar
 *     → https://relay.amcl.lovedhy.cn/dl/p/cdn.modrinth.com/data/x.jar
 * 不可加速或未启用时返回空串（调用方保持原 URL）。
 * ⚠️ 不对 path 做任何解码/编码：Modrinth 文件名里的 %2B 必须原样带过去，
 *    否则上游 URL 与网关缓存键都会错开（网关侧已踩过一次）。
 */
std::string relayRewriteUrl(const std::string& url);

/** 该 URL 是否是指向我们网关的（用于决定要不要加鉴权头） */
bool relayIsRelayUrl(const std::string& url);

/**
 * 为一次请求生成鉴权头。
 * @param method  GET / HEAD
 * @param url     完整的网关 URL（内部会截取 "/p/..." 作为签名路径）
 * @param out_authorization  形如 "Authorization: Bearer xxx"
 * @param out_ts / out_nonce / out_sig  形如 "X-AMCL-Ts: 123"
 * @return false 表示当前不可用（调用方应放弃加速、走原始 URL）
 */
bool relayBuildAuthHeaders(const std::string& method,
                           const std::string& url,
                           std::string& out_authorization,
                           std::string& out_ts,
                           std::string& out_nonce,
                           std::string& out_sig);

/** 统计：网关请求数 / 失败数 / 因失败自动回退的次数（供日志与诊断） */
struct RelayStats {
    int64_t requests = 0;
    int64_t failures = 0;
    int64_t fallbacks = 0;
    int64_t auth_rejects = 0;
};
RelayStats relayStats();

/** 记录一次网关失败；连续失败过多会自动熔断一段时间（避免拖慢整体下载） */
void relayNoteFailure(int http_status);
void relayNoteSuccess();

/** 熔断中（短时间内不要再尝试加速） */
bool relayTripped();

} // namespace download
