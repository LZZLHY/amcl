# MobileGlues：锁定 fork 与 AMCL 集成

上游为 MobileGL-Dev/MobileGlues，AMCL 使用 LZZLHY/MobileGlues 的 amcl/2.0-ohos 分支。当前精确身份由 [deps.lock](../../deps.lock) 的 [mobileglues] 节与外层仓库 gitlink 共同记录，源码位于 mg_src/。

锁文件同时记录官方源码基线、Android plugin 实际使用的 renderer 提交及其 tree。2.0 发布仓标签和源码提交不是同一种身份，不能用同名标签字符串代替锁定内容。

## 首次准备

在 MyApplication/ 执行：

```powershell
node scripts/prepare-public-deps.mjs
node scripts/prepare-public-deps.mjs --check
```

准备流程使用 setup_deps.sh 初始化 fork 和正常构建所需的嵌套依赖。OHOS 改动保存在 fork 提交内，[patches/series](patches/series) 保持空或仅注释，不在本地重放另一套修改。可选 profiling 依赖并不是常规构建必需。

## 集成结构

[entry/src/main/cpp/CMakeLists.txt](../../entry/src/main/cpp/CMakeLists.txt) 把 MobileGlues core 编入 libamcl_gl_host.so；libglfw.so 保留窗口、输入和 session facade，通过版本化 C ABI 使用图形宿主。不要继续按历史描述把全部 MobileGlues 实现理解为直接嵌入 libglfw.so，也不要再放入第二份 standalone libmobileglues.so。

图形宿主校验 provider 身份与函数归属；SDL3 的实际消费者负责自己的初始化，宿主发布窗口和输入身份。运行时与产品策略以当前 CMake、Native 代码和 [config/products.json](../../config/products.json) 为准。

## 公开构建与主仓验收入口

scripts/check-mg-pin.mjs、check-mg-docs.mjs、build-hap.ps1 等保留主开发仓库的来源/证据/发布要求。其中来源检查会拒绝把 LZZLHY/amcl 分发仓库当成原始发布源，因此不是公开仓库的通用首次构建命令。

公开快照依赖准备和常规 HAP 构建请使用 [BUILD_SNAPSHOT.md](../../docs/BUILD_SNAPSHOT.md)。源码与 ELF 检查不能代替设备运行验证。快照不含原始设备日志，仅保留默认 Native 配置所需的 Gate 0 脱敏输入能力记录；该记录保留原风险接受与未闭合缺口，不构成新验收。

许可证和版权以锁定上游/fork 源码及文件头为准，导航见 [CREDITS.md](../../docs/CREDITS.md)。
