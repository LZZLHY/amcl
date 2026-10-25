# 完整 shaderc C API 的 OHOS 构建

`libshaderc.so` 是现代槽 `lwjgl-shaderc.jar` 的直接 C API 提供方。除主 `Shaderc`
接口外，`GLSLang`、`GLSLangResourceLimits`、`SPV`、`SPVOptimizer` 默认均通过
`Shaderc::getLibrary` 复用它；只导出 `shaderc_*` 不满足整个 JAR 的交付契约。

`build-inputs.json` 锁定 shaderc v2026.1 与其上游 `DEPS` 中的 glslang、SPIRV-Tools、
SPIRV-Headers 精确提交和源码归档摘要。`required-symbols.json` 记录现代槽锁定
LWJGL 提交中五组 Java 绑定的源码摘要和必需函数；`required-symbols.txt` 与
`exports.map` 是同一集合的链接保留与动态导出输入。升级任一方须核对整组接口。

## 正式入口

在工程根执行，`--sdk` 指向包含 `native/` 的 OpenHarmony SDK，`--out` 使用独占仓外目录：

```powershell
python -B scripts/build-shaderc-native.py --sdk <OpenHarmony-SDK> --out <外部构建目录> --jobs 6 --install
```

脚本先从锁定 LWJGL Git 对象重取必需函数并核对三份接口清单，再校验下载归档与全部展开
源码。CMake 的配置、对象、日志及候选均在 `--out`；源码缓存不同于锁定归档时停止并
保留现场，不覆盖未知修改。生成器禁止写 Python bytecode，避免污染待核验源码。

只有完整构建和产物验证全部通过后，显式 `--install` 才更新
`entry/libs/arm64-v8a/libshaderc.so` 与本目录 `build-provenance.json`。随后按现代槽
契约同步 `deps.lock`、现代清单及其消费者；重建脚本不自行接受或修改这些锁。

## 链接与验证

`CMakeLists.txt` 配置上游真实库目标，`complete-api.cmake` 为每个必需函数传入
`--undefined`，从真实静态归档抽取实现；不生成替代实现，不关闭运行时函数检查。
Windows 下通过 `-Wl,@response-file` 保留完整参数，避免命令行长度上限。
版本脚本仅公开锁定 C API，隐藏内部 C++ ABI；最终链接保留 `--no-undefined`。

产物验证精确比较全部必需动态导出，并核实 AArch64 ELF64、`libshaderc.so` SONAME、
批准的动态依赖及 OHOS libc++ `__n1` ABI。收据保存源码、编译器、配方和产物摘要。
这些检查证明构建输入、配套接口及 ELF 交付，不替代设备上的着色器编译、图形效果或
具体模组调用验收。

## Docker 兼容入口

`docker/build_shaderc_ohos.sh` 的 shaderc 部分消费同一套只读 `/prebuilt/shaderc`
CMake 配方、锁定提交和完整接口表；缺少配方挂载或来源身份不符时立即拒绝，不能
退回上游默认 `shaderc_shared` 配置。工作数据仍由 Compose `amcl/builder` 管理，
遵循 [Docker 构建契约](../../docs/guides/DOCKER_BUILD_LAYOUT.md)。该脚本的 SPIRV-Cross
构建范围独立保留。

## 来源与许可

上游仓库和提交以 `build-inputs.json` 为准。Shaderc、SPIRV-Tools 使用 Apache-2.0；
glslang 与 SPIRV-Headers 的分文件许可及例外以本目录 `licenses/` 保存的锁定源码
许可原文为准。LWJGL 绑定采用其原 BSD 许可；本目录仅登记绑定摘要和函数名，不复制
生成的 Java 实现。
