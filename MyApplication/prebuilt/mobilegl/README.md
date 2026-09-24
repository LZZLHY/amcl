# MobileGL：OHOS 独立图形 DSO

本工程使用 LZZLHY/MobileGL 的锁定 fork。上游为 MobileGL-Dev/MobileGL，fork 分支为 amcl/ohos；精确 commit、source_tree、依赖提交与产物指纹见 [deps.lock](../../deps.lock) 的 [mobilegl] 节。源码位置 src/ 通过外层仓库 Git 子模块跟踪，OHOS 修改保存在 fork 提交中，本目录不另加本地 patches/ 栈。

## 普通 HAP 使用随仓的锁定输入

[dist/](dist/) 随公开快照保留 libmobilegl.so、libmobilegl.unstripped.so 和 build-provenance.json。普通 HAP 构建使用这三份输入，无需先运行源码重编配方。

在 MyApplication/ 执行，工具配置见 [BUILD_SNAPSHOT.md](../../docs/BUILD_SNAPSHOT.md)：

```powershell
node scripts/prepare-public-deps.mjs
node scripts/prepare-public-deps.mjs --check
```

默认准备入口会校验 MobileGL 来源与 dist 指纹，并准备 HAP 所需的 entry/libs/arm64-v8a/libmobilegl.so。现役 default/store/sideload/desktop 四产品都要求这份图形输入；不能把它仅当作 default 的可选验证库。

准备脚本会初始化正常生产构建需要的嵌套依赖，包括着色器编译线程池使用的 3rdparty/asio，也会取得 glslang known_good.json 指定的 External/spirv-tools 和 external/spirv-headers。后两者不是常规 Git 子模块。准备入口自动设置 GIT_LFS_SKIP_SMUDGE=1，保留可选 trace_replay 工具的数据指针而不下载大型回放夹具；普通 HAP 不需要这些数据。

## 可选：独立源码重编

完成依赖准备和 SDK 配置后可执行：

```powershell
pwsh -File prebuilt/mobilegl/build-mobilegl.ps1
```

[build-mobilegl.ps1](build-mobilegl.ps1) 使用 DEVECO_SDK_HOME 下的 Windows Native SDK、CMake、Ninja、LLVM 和 PATH 中的 Python。构建设置包括 OHOS arm64、c++_static、Release 和 LTO=OFF，具体参数以脚本为准。命令会覆盖随仓 dist 的两份库和 build-provenance.json，因此这一步用于独立重建研究，不是普通 HAP 的必需步骤。

2026-09-24 的公开源码独立目录验证已完成编译，但新生成 stripped/unstripped 库的 SHA-256 与 deps.lock 中锁定产物不同，无法通过严格的包输入门禁。字节差异的全部因素尚未定位；不能把可编译描述成锁定二进制已复现，也不能直接修改 hash 绕过检查。

需要保留研究结果时，先另存新库、provenance 和日志。**仅在确认放弃本工作区的 dist 重编结果后**，可在 MyApplication/ 恢复当前公开提交的锁定输入：

```powershell
git restore -- prebuilt/mobilegl/dist
node scripts/check-mobilegl-build-contract.mjs --prepare --product default
```

## 运行与验证范围

MobileGL 提供独立 GL/EGL provider。游戏能否选择它由实际包内库、设备能力、游戏请求和窗口 provider 的准入决定，携带库并不保证所有组合可运行。宿主和 SDL3/GLFW 通过共享的图形生命周期契约接入，见 [architecture.md](../../docs/architecture.md)。

scripts/check-mobilegl-build-contract.mjs 检查来源、两份 dist 的 SHA-256 和运行时 ELF 内容；HAP 二次 strip 的检查比较已分配 ELF section。源码、单库编译、完整 HAP、安装与设备运行是不同验证范围，本说明不把其中一项通过视为其他项已通过。

该公开说明不复制内部设备施工记录。来源与许可索引见 [CREDITS.md](../../docs/CREDITS.md)。
