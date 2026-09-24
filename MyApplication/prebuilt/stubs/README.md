# 兼容 stub 与 ABI shim 输入

本目录保留 stub-objc-bridge.jar、libclear_cache.so、libcxxabi_shim.so 以及 [src/](src/) 中的 ABI shim 源码。这些文件属于不同的 Java/Native 兼容用途，不能仅按“stub”名称视为可删缓存。

- stub-objc-bridge.jar 为 Java Objective-C bridge 的兼容输入，部署到 rawfile 后由运行时按启动路径使用。
- libclear_cache.so 与 libcxxabi_shim.so 是历史 JDK/Native 配方使用的辅助输入；是否需要打入某个最终产物应检查其 ELF NEEDED 和实际构建配方。
- entry/src/main/cpp/stubs/ 中另有随应用 Native 编译的实现，不能与本目录的预构建文件混为一谈。

当前 Hvigor 任务同步这里的 JAR，但不自动运行 scripts/sync_prebuilt.sh，也不自动把所有 SO 复制到 entry/libs。普通 HAP 使用快照内已经纳入工程的输入，详见 [BUILD_SNAPSHOT.md](../../docs/BUILD_SNAPSHOT.md)。

ABI shim 配方可从 [docker/build_jdk17_ohos.sh](../../docker/build_jdk17_ohos.sh) 和 [docker/scripts/incremental_rebuild.sh](../../docker/scripts/incremental_rebuild.sh) 查找。历史 Objective-C bridge JAR 的完整源码重建闭环不在本次验证范围，不能把一个备用 javac 命令当作已经验证的来源配方。

第三方来源、原始版权与具体文件头应分别核对，见 [CREDITS.md](../../docs/CREDITS.md)。本说明不以目录级许可替代上游文件条款。
