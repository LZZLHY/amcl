# libjli 构建辅助脚本回归

`test-libjli.py` 不启动 Docker，也不重编整份 JDK。它直接执行正式
`docker/scripts/rebuild_libjli.sh` 的函数/只读门禁，用已有真实 AArch64 libjli 作正控，
再以实际 SDK 编译的最小 ELF 证明缺符号、hidden、UND、同名前缀、数据对象和错误架构均被拒绝。
其中 hidden 样本同样使用 `global: JLI_*` version-script，直接证明版本脚本不能提升 hidden。

```powershell
python tests/runtime-build-tools/test-libjli.py `
  --library <现有实际AArch64-libjli.so绝对路径> `
  --clang D:/Huawei/command-line-tools/sdk/default/hms/native/BiSheng/bin/clang.exe `
  --output <新的仓外绝对输出目录>
```

Windows 使用已安装的 WSL Ubuntu `bash/readelf/awk`（可通过 `--wsl` 指定已有发行版），
不下载安装工具。每条命令、退出码及原始输出保存于外部收据；不执行 AArch64 库。
路径回归检查固定目录、明确正确路径、其他配置、缺失/相对/空路径、残缺树及不支持代际；
退役入口必须准确退出 2，并指向 `docker/project.py build` 正常复用流程。

正式重链仍保留既有 java.c、java_md.c、parse_manifest.c 编译和完整 JLI_* 导出范围。
`JLI_Launch` 与 `JLI_ManifestIterate` 必须是共享对象动态符号表中的可见已定义函数，
门禁在复制至 `/output` 和 JDK image 前运行，复制后再次检查。旧 JLI_Exit/JLI_ExitHook
不再作为当前要求。17/21/25 标准脚本继续无参数调用；固定构建路径为各自源码下的
`build/linux-aarch64-server-release`，显式错路径不搜索其他树。

只读产物检查也可直接运行：

```bash
READELF=readelf bash docker/scripts/rebuild_libjli.sh --verify-only /absolute/libjli.so
```

宿主回归和既有库正控不等于修订脚本已经完成目标 JDK 重链；下一轮标准 JDK 完整构建
仍需实际消费这些脚本并通过原有产物门禁。
