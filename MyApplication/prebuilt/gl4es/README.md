# gl4es：OHOS 固定管线 OpenGL 兼容输入

gl4es 为旧版游戏所需的固定管线 OpenGL 提供翻译能力。具体是否选择该 provider 由启动期 GraphicsPlan、游戏请求和产品能力决定，不能仅以某个 Minecraft 版本号代替当前准入逻辑。

来源记录在 [deps.lock](../../deps.lock) 的 [gl4es] 节。当前配方基于 PojavLauncherTeam/gl4es-114-extra 的锁定提交；本目录采用源码基线加补丁的形式，不是 MobileGlues 那样的已注册 Git 子模块。

[patches/series](patches/series) 当前包含：

- 0001：OHOS EGL 原生类型适配。
- 0002：懒初始化与 NOEGL 硬件探测条件，避免跨链接命名空间仅初始化另一个库实例。

[entry/libs/arm64-v8a/libgl4es.so](../../entry/libs/arm64-v8a/libgl4es.so) 是公开快照保留的普通 HAP 输入。独立重建配方为 [docker/build_gl4es_ohos.sh](../../docker/build_gl4es_ohos.sh)，需要已有 OHOS 容器工具链和 sysroot。配置补丁目录时，应指向本目录 patches/ 的容器挂载位置；脚本默认 /build/gl4es-patches 不是新克隆自动创建的目录。

关键构建策略包括 NOX11、NO_GBM、NOEGL 和 NO_INIT_CONSTRUCTOR；窗口和 EGL 生命周期由宿主路径管理。修改这些开关或补丁后，需要重新验证构建与实际游戏，不能沿用历史设备结论。

完整构建范围见 [BUILD_SNAPSHOT.md](../../docs/BUILD_SNAPSHOT.md)，许可与来源入口见 [CREDITS.md](../../docs/CREDITS.md) 及对应上游源码。
