# 完整 HDC 消费与侧载更新

`muka-rust-hdc` 是固定源码子模块，来自 [muka_rust_hdc](https://github.com/Attect/muka_rust_hdc)，锁定 `4a2d9c42059b3ff346f4d3f533cf781a5fbe70ba`。MIT 许可正文保留在子模块 `LICENSE`，同时进入应用 rawfile/sideload。

AMCL 的适配和私有客户端接入位于 `entry/src/main/cpp/hdc/core`。客户端、host、设备认证、传输、网络发现和USB实现均参与编译；普通应用运行时关闭USB发现，使用用户授权的设备TCP daemon。上游三个需适配的文件以副本保存在core/src/upstream；其余模块直接引用固定子模块。修改不通过环境变量重写HOME或进程全局stdio。

重建使用 `scripts/build-hdc-core.mjs`、Cargo.lock和HarmonyOS NDK。指定 `AMCL_HDC_TARGET_DIR` 可使用工作区外置构建树；未指定时用仓库外系统临时目录。非store产品由正常Hvigor入口编译并静态链接；store不调用Cargo且没有HDC核心。

`libusb1-sys` 编译的libusb采用LGPL-2.1-or-later。它的许可与作者说明随HAP提供。Cargo.lock固定源码依赖版本，Cargo构建目录保留libusb静态库/对象；需要重新链接时可在完整AMCL源码树运行正常CMake/Ninja入口，用替换后的libusb重建HDC静态库并重链libentry。对外分发时应同步提供这一源码、构建输入和许可，不能只发布签名包而丢弃相应来源。

签名器采用 [OpenHarmony developtools_hapsigner](https://github.com/openharmony/developtools_hapsigner) 的Apache-2.0开源分发，固定 `b5d2d41ceccff5a7c81c5e18ef18d843615f3251` 的dist/hap-sign-tool.jar及SHA-256。正常资源编译前由scripts/build-sideload-signer.mjs核实固定签名器并重建自有 `AmclSigningRunner`，源码位于entry/src/main/sideload；两者随包资源携带，手机运行时提取并再次校验签名器摘要，不依赖运行时从GitHub下载工具。固定commit、摘要和许可证没有改变。

2026-10-04复审提示：固定工具的verify-profile验证CMS/链内部一致性，不独立证明Profile属于目标系统可信签发根；导入预检、材料来源和最后系统安装裁决的边界见[架构审查](../../docs/reports/2026-10-04_SIDELOAD_SELF_UPDATE_ARCHITECTURE_AUDIT.md)及[整改方案](../../docs/adaptation/SIDELOAD_SELF_UPDATE_PLAN.md)。待实施方案不会据此自动替换签名器或开放任意HDC命令。
