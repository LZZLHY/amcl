/**
 * download/probe.h — 下载引擎 probe API
 *
 * Stage 1a 的唯一用途：验证 libcurl.so 能被 libentry.so 链接，并且在真机上
 * 能被 ELF loader 正确加载（通过 readelf DT_NEEDED 解析）。不做实际下载。
 *
 * 后续 Stage 1b 会在此目录补齐 NetSource/NetThread/NetFile/LoaderDownload 等
 * 完整引擎类，届时本 probe API 可以保留用于运维诊断，也可以删除。
 */
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 返回 libcurl 版本、TLS backend、feature 列表的可读字符串。
 * 例如："libcurl/8.10.1 OpenSSL/3.3.2 IPv6=1 Threaded=1 Protocols=http,https"
 *
 * 线程安全：内部静态 std::string，多线程并发调用可能返回陈旧指针。
 *           probe 是诊断用途，不在热路径，不考虑并发。
 *
 * 返回值：NUL 结尾 C 字符串，生命周期至进程结束（由 static 持有）。
 */
const char* downloadEngineProbe();

/**
 * 简单自检：curl_global_init → curl_easy_init → curl_easy_cleanup → curl_global_cleanup。
 * 不做任何网络请求，仅验证 libcurl 运行时符号能被 resolve 且初始化路径正常。
 *
 * 返回 0 表示 OK；非 0 为 CURLcode（< 100）或 -1（easy_init 失败）。
 */
int downloadEngineSelfTest();

#ifdef __cplusplus
}
#endif
