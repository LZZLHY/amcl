# Mesa / Zink：保留的适配配方

本目录保存 Mesa/Zink 的 OHOS 适配材料与历史构建配方。现役 HAP 构建在 [entry/hvigorfile.ts](../../entry/hvigorfile.ts) 中排除 libEGL_mesa.so、libgallium.so 和 libglapi.so；不能根据这些文件仍保留在快照中，就把 Mesa/Zink 描述为当前可选或已验证的游戏图形路线。

来源见 [deps.lock](../../deps.lock) 的 [mesa-zink] 节。补丁顺序以 [patches/series](patches/series) 为准；当前该文件有 0001–0004，不是空占位。

独立构建配方为 [docker/build_mesa_zink_ohos.sh](../../docker/build_mesa_zink_ohos.sh)，平台补充材料在 [ohos-platform/](ohos-platform/)。该配方需要 OHOS 交叉工具链、sysroot 和 Meson 等宿主工具，脚本中的历史容器路径必须映射到使用者自己的环境。

编译出 Mesa 库并不证明设备具备目标 Vulkan 能力，也不证明某个 OpenGL 模组可运行。本公开说明不保留旧施工阶段对 Voxy/Nvidium 或设备能力的推断性承诺。当前图形运行链路见 [architecture.md](../../docs/architecture.md)。

许可应核对所用 Mesa 源码中的实际许可文件和组件声明；第三方范围见 [CREDITS.md](../../docs/CREDITS.md)。
