# Fontconfig 运行时 provider

`build-inputs.json` 固定 Fontconfig、Expat、FreeType 参考源码以及 Meson 工具。
正式入口是 `docker/project.py build --component fontconfig`；沿用固定 `amcl`
Compose builder，并冻结目标 SDK、配方与本次源码输出。每次构建保留独立候选，
不覆写四份 JDK 归档或 HAP 库。

Fontconfig 动态使用消费者现有的 FreeType。JDK 8 的依赖名是
`libfreetype.so.6`，现代 JDK 和 HAP 文件入口是 `libfreetype.so`。两种候选
来自同一 ELF，打包器只允许缩短明确的动态字符串，逐项排除共享字符串，
记录转换前后 SHA-256 和所有变更字节位置。指令、重定位、节和段的位置不变。
参考 FreeType 只用于真实 C ABI 链接，不作为新运行时库交付；接入时还必须
把记录中的全部 `requiredFreeTypeSymbols` 与每个实际消费者库的导出核对。

Expat 按锁定源码构建并私有静态链接，保留 DTD、实体、命名空间及上游默认
安全机制；`XML_*` 和 `FT_*` 定义不得从 Fontconfig provider 导出。这样不
改变 HAP 其他模块正在使用的 Expat，也不引入第二套运行时 FreeType。

宿主字体配置从现役 rawfile 精确生成，落在应用的
`filesDir/runtime-fonts/<SHA256>.conf`，其中 cachedir 使用经 XML 转义的
`filesDir/runtime-fonts/cache` 实际绝对路径，文件名按展开后正文计算 SHA；
Fontconfig 的 cachedir 不按配置文件位置解释 `prefix="relative"`，因此不能
用该前缀保证宿主缓存位置。配置发布持有目录排他锁，使用同目录 `renameat` 和文件/目录同步；
真实 API 26 设备禁止的 `linkat` 不再是该路径的前提。已有配置正文不符时拒绝
继续，不把权限失败吞成成功。独立 CLI 也可以显式使用具有可写 cachedir 的配置；
不能靠 `/data/local/tmp` 或外部 HOME 的偶然权限运行。

`patches/0001-ohos-default-fonts-and-context-cache.patch` 的 OHOS 默认配置使用与 HAP
同源的 generic alias；`ohos-generic-fonts.h` 由现役模板生成。有效的显式 cachedir
以及可用的标准 XDG/HOME 位置优先，随后查询固定官方 NDK provider 的可选 Context。
API 26 NativeChildProcess 已实测返回 `CONTEXT_NOT_EXIST`，因此 Context 仅为可选来源，
不承诺任何 NCP 或 fresh exec 都具有应用 Context。

这些来源均不可用时，默认候选从本 provider 的实际绝对加载地址识别现代
`<jdk>/lib/libfontconfig.so` 或经典 `<jdk>/jre/lib/aarch64/libfontconfig.so`，
在 **JDK 根的父目录** 建立 `.amcl-fontconfig-cache/fontconfig`。父目录须由当前 UID
拥有且不可被组/其他用户写；缓存顶层目录须为同 UID 的 0700 普通目录，创建/打开通过
dirfd、`mkdirat`、`O_NOFOLLOW` 和 inode 回读收敛并发，不覆盖未知文件或链接。
缓存不进入运行时归档、文件清单、封存树或安装槽，不与版本目录 rename/delete 或 `.use`
租约文件竞争。默认位置选择只发生在配置初始化，热缓存继续使用 Fontconfig 原机制。

未知 provider 布局、只读父目录或没有可用标准位置时，字体匹配仍可使用内存结果；这条
分支明确不具备持久缓存资格，需要宿主提供可写配置。实现不改 HOME，不猜系统沙箱前缀，
也不把 NCP 成功推导成任意独立 CLI 的缓存成功。最终默认 provider 必须从新冻结来源完整
构建，并以实际缓存文件写入/再加载及目标 Java 覆盖复验；旧 provider 收据不能继承资格。

构建成功只证明 ELF 及来源闭包。HAP 命名空间加载、实际中文字体匹配、缓存
冷/热重用、Java Font/ImageIO 和四份 JDK 的真实执行分别保留验收证据；未完成
这些验证的候选不得标记为完整预览版。

`build-provenance.json` 记录已完成 provider 构建的冻结输入身份、SDK 索引摘要、
两份依赖名变体和当前 `entry/libs/arm64-v8a/libfontconfig.so` 的实际消费摘要。
其中配方摘要属于该次真实构建；后来对工具展开树的复用校验修复，不追认成旧
产物已经消费的新配方。重建时须产生新收据，旧构建目录与日志继续保留。

## 现代 JDK 的 FreeType 服务补全

JDK 17、21、25 的 bundled FreeType 分别是 2.13.3、2.13.2、2.14.2，原树省略
`ftbdf.c`、BDF/PCF 驱动和 SFNT BDF 服务。`freetype-completion.json` 为每一代
记录对应上游提交、18 个导入文件、两个配置开关、补丁及许可证的原始 SHA。
各自 `0016-fontconfig-freetype-bdf-pcf-completion.patch` 只恢复匹配版本的真实
服务，继续沿用该 JDK 的其他字体配置，不替换整份 FreeType，也不删改 Fontconfig
调用能力。JDK 8 现有 FreeType 已提供全部 23 个 provider 所需导出。

`tests/runtime-fontconfig/` 在三个真实 JDK 基线的新工作树上重放完整 series，
并编译补前/补后所有 bundled FreeType 编译单元。自有 BDF、PCF 和 TrueType
字体验证实际像素、字符映射、属性类型/值与 SFNT strike 选择；原库保留 TrueType
正常行为但缺少恢复服务时才算负对照成功。该宿主测试不代替三份 OHOS JDK
完整重建、最终 ELF 导入闭包检查和 Java Font/ImageIO 真机验证。

## 源码导出需要的材料

公开源码包须分别保留 JDK 和 provider 的构建身份，不把参考 FreeType 当作交付库：

- 四代 JDK 的锁定源提交、完整 series 与补丁；现代版本还须带上本目录的
  `freetype-completion.json` 和对应 FreeType 许可证。
- provider 构建收据对应的完整 `fontconfig`、`expat`、参考 `freetype` Git 归档，
  以及被固定 SHA 验证的 `meson.whl`、`gperf-3.3.tar.gz`。这些文件已在原构建
  `out/sources/` 留存；原始归档摘要由 `source-identities.json` / 构建输入固定。
- 同次构建的冻结配方、`build-inputs.json`、provider 来源收据、真实 SDK 身份和
  工具链要求；SDK 二进制是否可分发由其现有许可约束决定，不能用三个头文件
  哨兵假称完整 SDK 来源已公开。
- 默认适配还包含 `ohos-defaults.json`、完整 series/patch、生成的 generic 头及
  `fontconfig-adaptation.json`。原始 Git 归档仍保持上游字节，实际编译的补后文件与生成头
  分别记录 SHA；该 provider 来源命名空间独立于较早四份 JDK 的编译来源。
- Fontconfig 和静态链接 Expat 的 `COPYING`，以及补全源码的 FreeType 许可。
  仓内 `licenses/` 均来自上游锁定提交的原始正文。

最终四份运行包分别验证 provider 所需的全部 FreeType 导出及 SONAME 闭包。
`before/after.tar` 是字体回归测试的源输入证据，不是 JDK 整包来源归档，也不能
代替上述最终交付来源材料。

## 新增源文件的派生 notice

`scripts/freetype-notices.py` 从每代原补全补丁恢复全部新增文件，核对每文件原始
SHA，保全完整版权/许可注释并附匹配版本的原许可证全文。`derived-notices/`
保存输出与逐文件来源清单；它是派生分发补充，不属于原已完成 JDK 构建的
`inputClosure`，也不改变或解释上游许可。

现代新派生使用字体 bundle schema2 和原构建的 `--compiled-inputs`，新增
`legal/amcl-freetype-completion/NOTICE.txt`。公开源包将 notice、来源清单和
捕获的生成器在 `derivedNoticeFiles` 单列；发布端独立从原冻结补丁/许可重算，
不能通过更新派生 SHA 来掩盖正文、作者、文件集合或版本的改变。单代公开源包
可用生成器的 `--major` 只生成该代材料。历史包保持原字节，材料修复使用新的
不可变 buildId/文件名。
