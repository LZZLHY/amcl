// scripts/typed-validation-overrides.h
//
// typed 验证包**专用**的构建期宏覆盖。经 CXXFLAGS 的 `-include` 注入，只由
// scripts/build-typed-validation-hap.ps1 使用。**它绝不出现在任何出货配置里。**
//
// ============================ 为什么需要它 ============================
//
// typed 平面在出货包里结构不可达，两个独立条件（计划 §85.4 已更正过一次措辞：
// 是**两个**独立条件，不是三道闸门）：
//   bit10 AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE —— 由 AMCL_GLFW_TYPED_PHYSICAL_DEFAULT
//         决定（无启动 env 覆盖时）。它**不是证据位**、不受 Gate 0 门禁管辖。
//   bit13 AMCL_INPUT_CAP_VERIFIED_RAW_RELATIVE —— 由 AMCL_GLFW_RAW_RELATIVE_VERIFIED 决定，
//         而它受 Gate0Evidence.cmake 管：gate0-evidence.lock 里 approved=false ⇒ 把那个
//         CMake option 置 ON 会在 configure 期 FATAL_ERROR（刻意的）。
// ⇒ 缺 bit13 时 POINTER_RELATIVE 在 ingress 就 CAPABILITY_REJECTED（不提交 core、也**不**
//   回落 legacy）⇒ typed 视角是死的 ⇒ "体验一模一样"在真机上无法对比。
//
// ============================ 为什么走 -include 而不是改配置 ============================
//
// 三条路都试过，只有这条不留下任何可能被误发布的状态：
//   ✗ 把 option 置 ON            —— Gate0Evidence.cmake 直接 FATAL_ERROR（approved=false）。
//   ✗ 写进 build-profile.json5    —— check-gate0-evidence.mjs 扫的正是这个文件：它既拦
//                                   `AMCL_GLFW_*_VERIFIED=1`（清单未批准），也拦任何
//                                   手写的 `-D AMCL_GATE0_EVIDENCE_IDS=`。而它在
//                                   build-hap.ps1 的 [1/7]，出货路径上一定会跑。
//   ✓ CXXFLAGS 的 -include        —— 仓内**零文件改动**，lock 保持 approved=false，
//                                   门禁一行不动，且只在设了那个环境变量的那一次构建生效。
//
// 覆盖之所以生效，是 CMake/Ninja 的命令段顺序（实测 glfw_compat.cpp 的编译命令）：
// `$DEFINES`（target_compile_definitions 注入的 =0，token 4–12）排在 `$FLAGS`
// （CMAKE_CXX_FLAGS，token 20–37，`-D__MUSL__` / `-DNDEBUG` 就在这一段）**之前**
// ⇒ 后出现的定义赢。用 `-include` 一个真实文件而不是往 CXXFLAGS 里塞带引号的 `-D`，
// 是为了绕开 shell → CMake → Ninja → clang 四层转义（本仓已有的
// check-product-tu-syntax.mjs 就栽在 `-DAL_API=""` 的去引上）。
//
// ============================ 这份覆盖的强度边界 ============================
//
// glfw_input_mode.h 的 static_assert 自己写明了这条通道的存在与它买到的东西：
// 断言证明的是"**有人声称**授权"，不是"声称为真"；编译期不与清单对账。
// ⇒ 本文件把 evidence id 设成一个**自述其非证据**的字符串，任何人在产物里 grep 到它
//   都会立刻知道这个包没有任何真机证据、不得当作已批准。
// ⚠️ 因此：**用本文件构建出的 HAP 只能进开发者自己的设备，不得分发。**
// ⚠️ 它也**不**代表 R1/R2/R3 已成立 —— G1–G7 仍然全部敞着（计划 §83.8.1）。

#ifndef AMCL_TYPED_VALIDATION_OVERRIDES_H
#define AMCL_TYPED_VALIDATION_OVERRIDES_H

// bit10：选 typed 物理平面。不需要 env AMCL_GLFW_INPUT_BACKEND（仓内无写入点），
// 也不需要任何证据 —— CMakeLists 那行 option 上方的注释本来就写着这个用途
// （"a validation HAP can select typed without relying on process env"）。
#undef AMCL_GLFW_TYPED_PHYSICAL_DEFAULT
#define AMCL_GLFW_TYPED_PHYSICAL_DEFAULT 1

// bit13：让 POINTER_RELATIVE 能过 ingress，否则 typed 视角收不到任何样本。
// ⚠️ 这是本文件唯一触碰 Gate 0 证据位的地方，也是它必须是一次性构建覆盖、
// 而不是任何持久配置的原因。
#undef AMCL_GLFW_RAW_RELATIVE_VERIFIED
#define AMCL_GLFW_RAW_RELATIVE_VERIFIED 1

// 让 static_assert 通过，同时让产物自证"这是验证包、没有证据"。
// 字符串刻意写成一句人话：grep 到它的人不需要再去查任何文档。
#undef AMCL_GATE0_EVIDENCE_IDS
#define AMCL_GATE0_EVIDENCE_IDS \
    "TYPED-VALIDATION-BUILD-NO-DEVICE-EVIDENCE-DO-NOT-SHIP"

// bit14（native 绝对坐标）**刻意不开**：它需要坐标与时间戳两份独立证据，而本轮要验的是
// 滚轮 / 视角 / 失焦这条切换清单。多开一个不可达能力只会让对比结果多一个变量。

#endif  // AMCL_TYPED_VALIDATION_OVERRIDES_H
