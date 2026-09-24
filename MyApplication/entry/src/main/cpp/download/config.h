/**
 * download/config.h — 下载引擎全局配置（运行时可调）
 *
 * 当前只有 CA bundle path（P1-3 Stage 1c-ca 插队）。
 *
 * 为什么需要 CA bundle？
 *   OHOS 的系统根证书路径不在 libcurl 默认搜索的 /etc/ssl/certs/，OpenSSL
 *   找不到任何信任根 → 所有 HTTPS 握手失败，报 "self-signed certificate in
 *   certificate chain"（误导性错误，实际是"empty trust store"）。
 *
 * 解决方案：
 *   把 Mozilla ca-bundle（curl.se/ca/cacert.pem）打包到 HAP rawfile，
 *   ArkTS 启动时抽到 filesDir/cacert.pem，通过 setCaBundlePath 传进来。
 *   NetThread::performOnce 在 curl_easy_setopt 时用 CURLOPT_CAINFO 指定。
 *
 * 未来可能扩展：代理 URL、全局 User-Agent 定制、DNS servers、连接池尺寸等。
 */
#pragma once

#include <string>

namespace download {

/** 设置 CA bundle 文件绝对路径（PEM 格式）。空串 = 回退到 curl 默认 */
void setCaBundlePath(std::string path);

/** 读当前 CA path；线程安全；未设置时返回空串 */
std::string getCaBundlePath();

} // namespace download
