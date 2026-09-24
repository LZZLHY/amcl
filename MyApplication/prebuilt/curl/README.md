# curl 与 OpenSSL：OHOS Native 下载输入

应用的 Native 下载模块链接 [entry/libs/arm64-v8a/libcurl.so](../../entry/libs/arm64-v8a/libcurl.so)。公开快照保留该输入，普通 HAP 构建不要求先重编 curl。

配方为 [docker/build_curl_ohos.sh](../../docker/build_curl_ohos.sh)，Windows 包装入口为 [docker/build_curl_ohos.ps1](../../docker/build_curl_ohos.ps1)。当前脚本使用 curl 8.10.1 和 OpenSSL 3.3.2；版本、下载和参数应直接核对脚本。curl 头文件位于 [entry/src/main/cpp/third_party/curl/](../../entry/src/main/cpp/third_party/curl/)。

独立重建需要配方要求的 OHOS 交叉编译容器、sysroot 和工具链；本地历史容器名不是新克隆后自动存在的环境。完整准备范围见 [构建说明](../../docs/BUILD_SNAPSHOT.md)。不要把 deps.lock 中尚为 PENDING 的 amcl-prebuilts 字段当作已发布下载源。

curl 与 OpenSSL 保留各自上游许可和版权信息；本目录不声明许可正文已完整复制到公开 docs/。来源和分发边界见 [CREDITS.md](../../docs/CREDITS.md)。
