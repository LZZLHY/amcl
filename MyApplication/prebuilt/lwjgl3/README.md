# LWJGL 3：现代槽与旧版兼容槽

当前现代槽为 3.4.2，设备部署目录为 lwjgl-ohos；3.2.3 和 LWJGL 2 使用独立槽。精确版本和输入以 [deps.lock](../../deps.lock)、[modern-slot.manifest.json](modern-slot.manifest.json) 和 [legacy-slots.manifest.json](legacy-slots.manifest.json) 为准。

## 首次准备

在 MyApplication/ 执行：

```powershell
node scripts/prepare-public-deps.mjs
node scripts/prepare-lwjgl-modern-slot.mjs --require-source
```

lwjgl3_src/ 是 Git 子模块；jars/ 是下载及生成目录，不随公开快照复制其工作区内容。准备流程从锁定的 Maven 原包开始，校验 SHA-256 后完成 module-info、包表、旧 stack API、OHOS GLFW 桥接、STB v1、TinyFD 和最终 Native 指纹等处理。最终 JAR 与原始 Maven JAR 的 hash 不同是这条流程的预期结果，不能混用两份清单。

## 构建与交付

| 输入 | 位置与处理 |
|---|---|
| 现代 Java JAR | jars/ → entry/src/main/resources/rawfile/lwjgl/；准备脚本和 Hvigor 校验完整槽位 |
| OHOS GLFW 桥接类 | [ohos-glfw/](ohos-glfw/README.md)；保留上游 GLFW.class，并注入 AMCL 桥接类 |
| 现代 Native | entry/libs/arm64-v8a/；普通 HAP 使用快照保留的输入，精确集合见 manifest |
| 3.2.3 兼容槽 | [3.2.3/](3.2.3/README.md)，Native 名带 _v322 |
| AMCL GLFW facade | entry/src/main/cpp/glfw/，随 HAP 编译 |
| STB resize v1 兼容输入 | [compat/stb-v1/](compat/stb-v1/README.md)，sources.json 校验源文件身份 |

现代槽还会通过 scripts/check-lwjgl-modern-slot.mjs 与 scripts/check-lwjgl-native-surface.mjs 检查 Java/Native 配套关系。不要把通用 Linux 或 Android 的 Native 库直接替换进 OHOS 槽，也不要只升级 JAR 而保留不配套的 Native 输入。

独立 Native 配方为 [docker/build_lwjgl_ohos.sh](../../docker/build_lwjgl_ohos.sh)，其他字体、shaderc 等依赖有各自 Docker 配方。需要另外准备对应 OHOS 容器和 sysroot；这不等于普通 HAP 构建的首次安装步骤。

## 工作区差异与验证边界

[local-worktree.patch](local-worktree.patch) 保存主工作区中两份 VMA C++ 未提交修改，基于锁定上游提交 32593afe25e2f1394c3425673f1b71a0122f5cd4。该补丁不会自动应用到正常 Java 构建使用的子模块源码。公开快照保留的 liblwjgl_vma.so 含有相关 AMCL 适配标识，但尚未完成这份 Native 输入从干净环境到同字节产物的独立重建验证，具体边界见 [BUILD_SNAPSHOT.md](../../docs/BUILD_SNAPSHOT.md)。

上游许可和版权见源码子模块与各文件头。来源索引见 [CREDITS.md](../../docs/CREDITS.md)。主开发仓库中的历史升级文档不是公开构建的必需输入。
