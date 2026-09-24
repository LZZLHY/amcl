# 第三方组件和资源说明

下表按公开工程中的位置列出主要依赖入口。它用于查找来源、版本、适配材料与构建配方；完整的文件身份还应结合 [deps.lock](../deps.lock)、Git 子模块指针、组件内的 sources.json 和产物清单核对。

| 组件或材料 | 工程内入口 | 来源与复建线索 |
|---|---|---|
| LWJGL 3 与旧版兼容槽位 | [prebuilt/lwjgl3/](../prebuilt/lwjgl3/) | 上游源码子模块、deps.lock、现代/旧版槽位清单、OHOS GLFW 桥接及 STB 兼容源；现代 Maven JAR 由下载脚本取回并校验后处理 |
| LWJGL 2 | [prebuilt/lwjgl2/](../prebuilt/lwjgl2/)、[docker/build_lwjgl2_ohos.sh](../docker/build_lwjgl2_ohos.sh) | 旧版 Minecraft 的 Native 配方与适配材料 |
| MobileGlues | [prebuilt/mobileglues/](../prebuilt/mobileglues/) | LZZLHY/MobileGlues fork 子模块、deps.lock [mobileglues]；AMCL 改动保存在锁定 fork 提交中 |
| MobileGL | [prebuilt/mobilegl/](../prebuilt/mobilegl/) | LZZLHY/MobileGL fork 子模块、deps.lock [mobilegl]；随仓 dist 含锁定的两份库和 build-provenance.json，普通 HAP 使用这些输入；源码重编边界见构建说明 |
| OpenAL Soft 与 OHAudio 适配 | [prebuilt/openal-soft/](../prebuilt/openal-soft/)、[entry/src/main/cpp/openal/](../entry/src/main/cpp/openal/) | 上游 OpenAL Soft、OHAudio 源码、补丁和 CMake 接入 |
| SDL3 | [prebuilt/sdl3/](../prebuilt/sdl3/) | deps.lock [sdl3-native]、patches/series 和 [scripts/build-sdl3-ohos.ps1](../scripts/build-sdl3-ohos.ps1) |
| curl 与 OpenSSL | [prebuilt/curl/](../prebuilt/curl/)、[docker/build_curl_ohos.sh](../docker/build_curl_ohos.sh) | Native 下载/TLS 依赖，具体版本与编译参数见配方 |
| OpenJDK 8/17/21/25 | [prebuilt/jdk/](../prebuilt/jdk/)、[docker/](../docker/) | 各版本补丁、shim、构建脚本；完整运行时包通过应用配置的资源仓库分发 |
| gl4es 与 Mesa/Zink 配方 | [prebuilt/gl4es/](../prebuilt/gl4es/)、[prebuilt/mesa-zink/](../prebuilt/mesa-zink/) | 对应补丁和 Docker 配方；保留配方不表示所有产物仍会打入现役 HAP |
| JNA 和兼容 stub | [prebuilt/jna/](../prebuilt/jna/)、[prebuilt/stubs/](../prebuilt/stubs/) | 对应来源说明、保留源文件和构建输入 |
| 模组 Native 依赖 | [prebuilt/mod-natives/](../prebuilt/mod-natives/) | manifest.json 及 imgui-java 等组件的来源和编译材料 |
| Fabric 兼容层构建输入 | [prebuilt/runtime-compat/](../prebuilt/runtime-compat/) | AMCL 兼容源码及 lib/sources.json 中锁定的 Mixin、ASM 构建依赖；运行时 Mixin 由 Fabric Loader 提供 |
| Khronos EGL 头文件 | [prebuilt/khronos-egl-headers/](../prebuilt/khronos-egl-headers/) | 对应 README 与 LICENSE.txt |

源码子模块的 URL 在公开仓库根目录的 [.gitmodules](../../.gitmodules) 中声明。精确版本由 Git 的 160000 gitlink 和锁文件共同确定，不能只按分支名获取最新代码。首次准备方式见 [BUILD_SNAPSHOT.md](BUILD_SNAPSHOT.md)。

[prebuilt/lwjgl3/local-worktree.patch](../prebuilt/lwjgl3/local-worktree.patch) 单独保存主工作区中两份尚未进入上游提交的 VMA C++ 修改，便于审查已保留 Native 输入的来源差异；默认依赖准备不应用它。其基线、指纹与未完成的第三方重建验证范围见构建说明。

## 许可证与分发边界

AMCL 自有源码采用 [GNU GPL-3.0-only](../LICENSE)，第三方边界见 [NOTICE](../NOTICE)。第三方源码、头文件、补丁、JAR、SO、运行时压缩包和其他资源保留各自版权及许可证；目录级的 AMCL 许可不替换第三方文件中的条款。

已从 18 个锁定源码位置复制 23 份许可正文到 [third-party-notices](../third-party-notices/README.md)，[清单](../third-party-notices/manifest.json) 逐份记录源仓库、提交、原路径和 SHA-256。该附件集不等于全部历史二进制的许可审查；其它组件仍须结合上游 LICENSE、COPYING、NOTICE 及源文件头核对。组件 README 的历史状态或“动态链接”描述不替代其实际许可文本。

Minecraft、Fabric、Forge、NeoForge、LWJGL、OpenAL Soft、SDL3、MobileGlues、MobileGL、HarmonyOS 及相关名称和商标归各自权利人所有。AMCL 不声明与 Mojang Studios、Microsoft、Xbox、网易、华为或上述第三方项目存在官方授权或背书关系。
