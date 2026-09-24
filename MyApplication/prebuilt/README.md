# 第三方依赖、适配配方与运行时输入

本目录同时保存上游来源记录、AMCL 适配源码/补丁和部分构建输入。公开快照与主开发仓库的忽略规则不同：已经纳入公开快照的 SO/JAR 是工程输入，不能因为主仓历史文档说“gitignored”就删除。

从全新克隆开始的操作见 [公开构建说明](../docs/BUILD_SNAPSHOT.md)。以下命令在 MyApplication/ 执行：

```powershell
node scripts/prepare-public-deps.mjs
node scripts/prepare-public-deps.mjs --check
```

| 内容 | 取得与使用方式 |
|---|---|
| MobileGlues、LWJGL、MobileGL 大型上游源码 | 外层仓库 .gitmodules 和 gitlink 锁定；准备脚本初始化 |
| MobileGL 的 glslang External 依赖 | 按 known_good.json 与 deps.lock 准备，不能只靠 Git 递归子模块 |
| OpenAL Soft、SDL3 上游源码 | 准备脚本调用 setup_deps.sh 拉取；SDL3 适配在构建工作树按 patches/series 应用 |
| LWJGL 现代 Java 槽 | jars/ 为本地准备目录；下载、校验、后处理，再交给 Hvigor 同步到 rawfile |
| SDL3、LWJGL Native、curl 等 | 普通 HAP 使用 entry/libs/arm64-v8a/ 中已纳入快照的输入；各组件保留重建配方 |
| MobileGL DSO | mobilegl/dist/ 随仓保留两份库与 build-provenance.json；准备入口校验并准备 HAP 输入，源码重编为可选步骤 |
| MobileGlues、OpenAL、AMCL GLFW/Native | 随 HAP Native 编译图构建 |
| JDK 游戏运行时 | 保留补丁/配方，完整压缩包由应用配置的资源仓库下载 |

当前版本和指纹以 [deps.lock](../deps.lock)、组件来源清单及产物 manifest 为准。SDL3 的 patches/series 目前包含补丁，不再是早期 fork 模式下的空文件。Hvigor 的实际资源准备由 [entry/hvigorfile.ts](../entry/hvigorfile.ts) 中的任务驱动，不会自动运行每一份历史同步脚本。

第三方组件入口见 [CREDITS.md](../docs/CREDITS.md)。完整从源码重编所有 Native/JDK 输入尚未通过统一复现验证，具体缺口见公开构建说明；PENDING 字段不表示存在可下载的预构建发布。许可证以各组件实际许可文本为准，本索引不声明已收齐所有二进制的许可附件。
