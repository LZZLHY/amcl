# 公开快照构建说明

2026-09-24 已按此流程完成 **1.0.4 / 1000671、sideload / release / unsigned** HAP 构建及包内关键输入校验；环境、产物 SHA-256 和剩余限制见 [本轮核验记录](public-reproduction-audit.md)。

本文从公开仓库的全新 Git 克隆开始，说明怎样准备依赖并编译 HarmonyOS HAP。工程目录为 MyApplication/，以下命令除克隆外均在该目录执行。

先明确验证范围：普通 HAP 构建会编译应用 ArkTS、Java 启动层、MobileGlues 和 OpenAL 等 Native 源码，同时使用快照保留的 MobileGL、SDL3、LWJGL Native、curl 等第三方二进制输入。MobileGL 的两份库和构建来源记录随快照提供，正常构建无需先重编它。把这些输入也全部从源码重新编译，是范围更大的第三方重建工作；逐字节重现官方签名 Release 还涉及工具链、路径、构建元数据和签名，不能由一次 HAP 编译成功推断。

## 1. 工具链和网络

当前配方以 Windows x64 为主。可选的 MobileGL 源码重建配方显式使用 Windows SDK 中的 cmake.exe、ninja.exe 和 LLVM 工具；本文没有把 Linux/macOS 的完整 HAP 构建列为已经验证的路径。

| 项目 | 要求与依据 |
|---|---|
| Git for Windows | 提供 git 和 Git Bash；Bash 必须能执行 setup_deps.sh 并访问同一份 Git、Node、JDK 环境 |
| DevEco Studio 或官方命令行工具 | 安装 HarmonyOS SDK、ArkTS、Native 工具链、Hvigor 和 ohpm；工程不是通用 npm/Vite 项目 |
| SDK 编译基线 | [toolchain.lock](../toolchain.lock) 记录 26.0.0.105 |
| Hvigor 基线 | 锁文件记录 6.26.4；过旧插件可能在读取 26.0.0 SDK 配置时失败 |
| Native 基线 | BiSheng clang 15.0.4、CMake 3.28.2；具体工具身份还记录在 toolchain.lock 的 SHA-256 中 |
| Node.js | 使用与所装 Hvigor 配套的 Node，并确保 node 命令在 PATH 中可用 |
| JDK | JDK 21 或更高，含 javac、java、jar；设置 JAVA_HOME。启动器本体使用 --release 8，但 Fabric 兼容产物使用 --release 21 |
| Python | Python 3；python 命令应在 PATH 可用。Java 构建和 LWJGL 后处理均会调用 Python；AMCL_PYTHON 可指定部分 Node 入口使用的解释器 |
| PowerShell | 本文示例采用 PowerShell；可选的独立 Native 重建配方通过 pwsh 调用 PowerShell 7 |

构建 SDK 与应用最低支持 API 是不同概念。当前产品定义见 [config/products.json](../config/products.json)：

| 产品 | targetSdkVersion | compatibleSdkVersion | 默认构建模式 |
|---|---|---|---|
| default | 6.1.0(23) | 6.0.0(20) | debug，开发用途 |
| sideload | 6.1.0(23) | 6.0.0(20) | release |
| store | 6.1.0(23) | 6.0.0(20) | release |
| desktop | 26.0.0 | 6.0.2(22) | release，仅 2in1 |

首次准备需要能访问 GitHub 的依赖仓库、Maven 下载源和 ohpm 仓库。源码已下载不等于 Maven JAR 和 ArkTS HAR 都已缓存。不要用关闭 TLS 校验或随意改锁文件的方式处理网络失败。

## 2. 克隆和检查快照

在 PowerShell 中执行：

```powershell
git -c core.longpaths=true clone https://github.com/LZZLHY/amcl.git amcl
Set-Location amcl/MyApplication
git config core.longpaths true
node scripts/check-public-snapshot.mjs
```

建议使用较短的工作路径，例如 C:/src/amcl，以减少 Native 构建中的路径长度问题。

[SOURCE_SNAPSHOT.json](../SOURCE_SNAPSHOT.json) 记录同步时的源仓库提交、工作区是否有未提交改动以及文件 SHA-256。sourceDirty 为 true 表示快照包含当时工作区的改动，sourceCommit 只是其基线提交，不能独自标识快照的全部内容。文件清单用于核对实际交付内容；文本校验按 LF 规范化，避免 Windows 换行转换造成误报。

完整 Git 仓库的根位于 MyApplication/ 的上一层。[根 .gitmodules](../../.gitmodules) 与 Git 索引中的三个 gitlink 共同记录 LWJGL、MobileGlues 和 MobileGL。GitHub 的 ZIP 下载不包含依赖工作树，也缺少这些来源检查需要的 Git 身份；请使用 Git 克隆并保留外层仓库。

[gate0-evidence.lock](../gate0-evidence.lock) 与其引用的 [docs/testing/gate0-raw-relative-evidence.md](testing/gate0-raw-relative-evidence.md) 也是构建必需输入。默认 Native 配置启用受 Gate 0 管理的输入能力，CMake 在配置阶段校验批准条目、文档存在性与内容身份；删除其中任一文件会使该配置被拒绝。

这两份公开输入不包含原始设备日志。同步先校验原证据文档身份，再替换设备序号并记录公开副本 SHA-256，原文身份由 sourceEvidenceSha256 保留。原批准状态、日期、G1–G7 未闭合缺口和产品所有者接受风险的事实均未改变；approved=true 不代表这些缺口已闭合，公开脱敏副本也不是一次新的设备验收。

## 3. 配置本机工具位置

以下路径是格式示例，必须替换为本机的实际安装位置：

```powershell
$env:JAVA_HOME = 'C:\Tools\jdk-21'
$env:DEVECO_SDK_HOME = 'C:\Tools\command-line-tools\sdk'
$env:AMCL_HVIGORW = 'C:\Tools\command-line-tools\bin\hvigorw.bat'
$env:AMCL_OHPM = 'C:\Tools\command-line-tools\bin\ohpm.bat'
$env:OHOS_LLVM_READELF = Join-Path $env:DEVECO_SDK_HOME 'default\openharmony\native\llvm\bin\llvm-readelf.exe'
$env:Path = "$env:JAVA_HOME\bin;$env:Path"

Test-Path -LiteralPath $env:OHOS_LLVM_READELF
git --version
bash --version
node --version
python --version
javac -version
& $env:AMCL_HVIGORW --version --no-daemon
& $env:AMCL_OHPM --version
```

DEVECO_SDK_HOME 指向含 default/openharmony/ 的 SDK 根目录，不能直接指到 native/。MobileGL 配方会检查其下的 default/openharmony/native/build-tools/cmake/bin/cmake.exe。使用 DevEco Studio 自带工具时，将 Hvigor、ohpm 路径换成该安装的 tools/ 下对应入口。

Test-Path 应返回 True。LWJGL Native 符号面检查需要显式设置 OHOS_LLVM_READELF；仅设置 DEVECO_SDK_HOME 不会让该检查自动找到 llvm-readelf。

Git for Windows 的 bash.exe 应能从当前 PATH 找到。Windows 的 WSL Bash 使用不同路径和工具环境；这里应使用 Git Bash，避免把 Windows JDK 和 SDK 路径直接混入 WSL。

## 4. 准备第三方源码和 Java 输入

```powershell
node scripts/prepare-public-deps.mjs
node scripts/prepare-public-deps.mjs --check
```

无参数命令准备依赖；--check 只检查已准备内容。首次运行需要下载较大的源码树，耗时取决于网络。按脚本报出的仓库、路径和命令判断进展，不要把某一次大型 Git 下载耗时直接视为编译卡死。

准备入口自动设置 `GIT_LFS_SKIP_SMUDGE=1`，跳过 MobileGL 可选 trace_replay 工具使用的大型 LFS 回放夹具，保留其指针文件。普通 HAP 构建不消费这些夹具，不需要另行运行 `git lfs pull`；只有独立使用对应工具时才需要准备其额外数据。

依赖分工如下：

| 输入 | 取得方式 |
|---|---|
| MobileGlues | 按 deps.lock 与子模块 gitlink 初始化 fork，以及正常构建所需的嵌套子模块 |
| LWJGL 3 | 初始化源码子模块；下载锁定的现代 Maven JAR，校验并完成 AMCL 后处理 |
| OpenAL Soft | setup_deps.sh 按 deps.lock 的 upstream/tag/commit 拉取并校验 SHA，再通过 docker/apply_patches.sh 幂等应用 OHAudio 注册补丁 |
| SDL3 源码 | 根据 deps.lock [sdl3-native] 准备到 prebuilt/sdl3/sdl3_src；普通 HAP 使用快照内已保留的 SDL3 库 |
| MobileGL | 初始化 fork 和所需嵌套依赖（包括生产线程池使用的 asio），补全 glslang known_good 外部依赖；校验随仓 dist 并准备 HAP 输入 |
| ArkTS HAR | 下一步通过 ohpm 安装，Git 子模块步骤不负责 HAR |
| JDK 游戏运行时 | 应用运行时按配置下载；构建主机的 JAVA_HOME 和设备使用的 JDK 是两件事 |

根 [.gitmodules](../../.gitmodules) 是公开仓库的 Git 子模块注册入口；[deps.lock](../deps.lock) 记录来源与指纹。glslang 的 External/spirv-tools 不是普通 Git 子模块，仅运行 Git 的递归子模块命令不能替代准备脚本。保留的 setup_deps.sh 也不单独覆盖 MobileGL 这一部分。

不要在首次准备时使用 setup_deps.sh --force；该选项会重建部分已有依赖。修改过依赖源码时，先保存自己的改动，再决定是否恢复锁定版本。

## 5. 配置工程与签名

```powershell
Copy-Item build-profile.json5.template build-profile.json5
& $env:AMCL_OHPM install --all
```

只在首次配置时复制模板，已有本地配置时不要覆盖。随后在 DevEco Studio 中打开 MyApplication/，选择已安装的 SDK，让 IDE 生成本机 local.properties 并完成工程同步。

模板的 signingConfigs 为空，而产品引用名为 default 的签名配置。要生成可安装的签名包，在 DevEco 的 Project Structure → Signing Configs 中配置自己的证书、profile 和 keystore，并确保配置名与选中产品的 signingConfig 一致。仅检查 unsigned 构建时，在本地 build-profile.json5 中移除该产品的 signingConfig 属性，保留空 signingConfigs；不要把示例密码或虚构证书填进模板。

build-profile.json5、local.properties 和签名材料不属于公开源码输入。可安装的签名包还须满足设备及签名 profile 的要求；构建成功的 unsigned HAP 不能直接等同于可安装包。

## 6. 使用锁定输入编译 HAP

当前四个产品都要求完整图形产物集合。公开快照在 [prebuilt/mobilegl/dist/](../prebuilt/mobilegl/dist/) 保留三份已锁定输入：libmobilegl.so、libmobilegl.unstripped.so 和 build-provenance.json。prepare-public-deps.mjs 默认准备流程会调用原工程的 MobileGL 校验器，核对源码身份、两份库的 SHA-256 与运行时内容，再复制所需库到 HAP 输入目录。正常构建不需要运行 build-mobilegl.ps1。

```powershell
node scripts/check-mobilegl-build-contract.mjs --prepare --product default
```

上面的单独命令可用于复查或重新准备输入；它不会重新编译 MobileGL，也不会用同名但不同身份的库替代锁定产物。MobileGL 源码重编是第 9 节的可选步骤，会修改随仓的 dist 文件；目前独立目录重编成功与锁定字节复现的结果不同，不能把重编当作普通构建的必要准备。

可在完整 HAP 编译前单独验证 Java 和资源准备：

```powershell
node scripts/prepare-lwjgl-modern-slot.mjs --require-source
node scripts/build-amcl-launcher.mjs --product default
```

随后在工程根目录使用与 SDK 配套的 Hvigor：

```powershell
& $env:AMCL_HVIGORW assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

也可以在 DevEco 中选择对应 product/target 和 build mode 执行 HAP 构建。Hvigor 的 entry/hvigorfile.ts 会在资源编译前准备产品资源、检查 MobileGL/SDL3、处理 LWJGL 并生成 Java 产物；前面的单独命令用于尽早发现依赖或 JDK 错误。

切换产品时同时设置 product 和 buildMode，例如：

```powershell
& $env:AMCL_HVIGORW assembleHap --mode module -p product=sideload -p buildMode=release --no-daemon
```

store 和 desktop 同理，应使用模板中同名产品及 entry target。产品能力以 config/products.json 和实际合并的 HAP 配置为准。

主工程保留的 build-hap.ps1、build-app.ps1 和发布相关脚本包含源仓库身份、内部证据、正式验收或发布要求。公开仓库不是这些脚本默认要求的源仓库；其中拒绝分发仓库作为发布源的门禁是有意行为。本文不通过删除这些检查来宣称公开快照已完成正式发布流程。

## 7. 检查构建结果

首先确认 Hvigor 完成且返回退出码 0，然后查看对应目标的输出目录：

```powershell
Get-ChildItem entry/build/default/outputs -Recurse -Filter *.hap
```

切换产品时将 default 改为对应目标名。确认输出的 signed/unsigned 后缀与你的本地签名配置一致，并记录 Git 提交、SOURCE_SNAPSHOT.json、deps.lock、toolchain.lock、实际工具版本和构建命令。

可检查这些内容，避免把“有文件”当成成功：

- HAP 属于所选产品，包含所需的 arm64-v8a Native 库和 Java 资源。
- MobileGL 的产物检查通过；Java 和 LWJGL 构建没有跳过失败。
- 若安装到设备，使用自己的有效签名并单独验证启动、下载、JDK 解压及目标游戏运行。

快照校验应先于构建执行。构建脚本可能更新 rawfile 中的 JAR、产品元数据或生成的 ArkTS 常量；构建后检查 git diff 可区分这些生成变化与手工源码修改。不要把这些文件的变化误认为首次同步漏文件，也不要把包含本地修改的结果称为未经修改的官方源码产物。

## 8. 常见失败与定位

| 表现 | 优先检查 |
|---|---|
| 子模块路径不存在或没有 gitlink | 是否保留 amcl 外层 Git 仓库、是否执行公开准备入口；不要从 ZIP 或独立复制的 MyApplication 开始 |
| Git 下载迟迟没有完成 | 查看正在拉取的依赖及网络；首次 LWJGL/MobileGL 源码准备可能较大 |
| Windows 提示 Filename too long | 准备入口已为所有 Git 写入（包括 External）启用 longpaths；仍建议短路径克隆，SDK/Native 工具也可能有自己的路径限制。旧版入口留下的半成品目录不要当作完整依赖，先保存自己的修改再恢复锁定文件 |
| 下载停在 Git LFS / trace_replay 大型数据 | 使用 prepare-public-deps.mjs 入口；它自动跳过普通 HAP 不需要的可选 LFS 回放夹具，不必额外执行 git lfs pull |
| 缺少 glslang External/spirv-tools | 重新运行 prepare-public-deps.mjs；这些依赖不由常规递归子模块初始化取得 |
| javac 不支持 release 21 | JAVA_HOME 和实际 javac 是否为 JDK 21+；DevEco 终端可能继承旧环境变量 |
| Python 找不到或兼容 JAR 生成失败 | 检查 python、AMCL_PYTHON、LWJGL JAR 是否已准备及来源清单校验输出 |
| SDK 版本字符串无效或缺少 API | 检查 Hvigor/插件与 SDK 是否匹配，不要仅修改 compatibleSdkVersion 来掩盖编译 SDK 不匹配 |
| check-lwjgl-native-surface 找不到 llvm-readelf | 按第 3 节设置 OHOS_LLVM_READELF，并确认 Test-Path 为 True |
| CMake 在 Gate 0 输入能力校验时拒绝配置 | 检查 gate0-evidence.lock 及其引用的脱敏文档是否随克隆保留且内容完整；不要删除记录或篡改批准/指纹来绕过检查 |
| MobileGL dist 不存在 | 检查是否完整拉取随仓的三份 dist 文件；普通 HAP 不需要重新编译 MobileGL |
| MobileGL hash 不匹配 | 检查是否运行过可选源码重编并改写 dist；保存日志和产物后按第 9 节恢复锁定输入，不要改锁绕过检查 |
| 找不到签名配置 default | 导入自己的签名材料，或按 unsigned 构建要求移除本地所选产品的 signingConfig |
| build-hap.ps1 拒绝 origin 或缺少内部文档 | 这是主仓发布/验收入口；公开工程使用本文的 DevEco/Hvigor 构建流程 |

## 9. 重新编译第三方库的范围

普通 HAP 构建保留已纳入快照的第三方 Native 输入。若需要独立重编这些输入，请按 [CREDITS.md](CREDITS.md) 定位每个组件的源码、版本、补丁和配方：

- SDL3：scripts/build-sdl3-ohos.ps1 与 prebuilt/sdl3/patches/series。
- LWJGL、curl、gl4es、Mesa/Zink 和 JDK：docker/ 下各自配方与 prebuilt/ 对应说明。
- MobileGL：本节下面的可选独立 Windows Native 构建；普通 HAP 沿用第 6 节的随仓 dist。
- MobileGlues 和 OpenAL：在 HAP 的 Native 编译图中构建，源码由准备步骤取得。

Docker 镜像、可用的 OHOS sysroot、上游归档和各配方要求的工具需要另行准备；仓库没有将所有外部工具链及全部第三方源码打包分发。deps.lock 中仍为 PENDING 的下载字段不代表存在可用的预构建 Release。部分历史配方或二进制输入也不具备统一的全链路重建/字节复现验证，因此本文没有承诺仅靠一条命令从零重建全部第三方二进制。

### 可选：从源码重编 MobileGL

完成依赖准备和 SDK 配置后，可独立研究或验证该 Native 库的编译：

```powershell
pwsh -File prebuilt/mobilegl/build-mobilegl.ps1
```

该命令会重新生成并覆盖随仓的 `prebuilt/mobilegl/dist/` 三个文件。2026-09-24 的公开源码独立工作目录验证已成功完成 MobileGL 编译，但 stripped 和 unstripped 的 SHA-256 与 deps.lock 中的锁定产物不同，因此新产物不能通过严格的 HAP 输入门禁。导致字节差异的全部因素尚未定位，不能据此声称已重现锁定二进制，也不能直接修改锁文件 hash 来绕过检查。

如需保留研究结果，先将新库、provenance 和日志另存到本地研究目录。**仅在确认放弃本工作区的 MobileGL dist 重编结果后**，可在 MyApplication/ 执行以下命令恢复随当前公开提交提供的锁定文件，再重新准备包输入：

```powershell
git restore -- prebuilt/mobilegl/dist
node scripts/check-mobilegl-build-contract.mjs --prepare --product default
```

依赖准备与 Java 启动器编译已在独立公开工程验证通过；这与完整 HAP 的编译、安装、设备验收仍是不同层次的结果。

本次同步另外保留 [prebuilt/lwjgl3/local-worktree.patch](../prebuilt/lwjgl3/local-worktree.patch)，用于审阅主工作区中尚未进入上游提交的两份 VMA C++ 修改。它基于锁定的 LWJGL 提交，SHA-256 为 `531dc88f3593831cd97972ee05cb65eb27640e11ac627a54332e9392a24b2bd4`；准备脚本不会把它自动应用到供 Java 资源构建使用的已锁定上游源码树。普通 HAP 使用快照内保留的 `liblwjgl_vma.so`；独立重编该库时还需要核对补丁、Native 构建参数和最终产物。保存这份补丁不等于已经完成该库从干净克隆到产物的重建验证。

此外，`deps.lock [openjdk17].commit` 仍为 `PENDING`，因此不能把现有 JDK 配方描述为已完成不可变源码提交锁定的全栈重建闭环。

这份快照提供的是可核对的工程输入和具体构建步骤。完整设备兼容性、所有第三方的源码重建闭环以及官方 Release 的逐字节复现，需要分别给出实际验证结果。
