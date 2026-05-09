# ELF Loader 踩坑记录与注意事项

> 从根目录的 `ELF_LOADER_NOTES.md` 搬进 `docs/`（2026-04-19），方便 `docs/README.md` 统一索引。
> 这不是归档文件，而是**活的参考资料** —— 任何改动 `entry/src/main/cpp/jvm/elf_loader.cpp` 或
> HotSpot 信号处理相关代码的人都应该先读一遍。

## 概述

自定义 ELF loader 用于绕过 HarmonyOS MAP_XPM 代码签名验证，从 filesDir 加载外部下载的 .so 文件（如多版本 JDK 的 libjvm.so）。原理：匿名 mmap + pread + mprotect(PROT_EXEC)。

## 踩过的坑

### 1. TLSDESC resolver 必须保存所有 caller-saved 寄存器（最严重的坑）

**现象**：SEGV 在 `ExceptionMark::ExceptionMark()` 的 `str x0, [x8]` 指令，x8（this 指针）是垃圾值。

**根因**：AArch64 TLSDESC ABI 要求 resolver 只能修改 x0，必须保留 x1-x17、x29、x30、NZCV。但我们的 asm trampoline 只保存了 x1-x4，C helper 函数使用了 x8（indirect result register），破坏了调用者保存在 x8 中的 this 指针。

**修复**：保存 160 字节栈帧，覆盖 x1-x17 全部寄存器 + NZCV flags。

**教训**：TLSDESC resolver 的寄存器保存必须完整，不能偷懒只保存"常用"的几个。

### 2. TLSDESC 多线程问题

**现象**：JVM GC 线程访问 TLS 变量时 SEGV。

**根因**：最初用预计算方案——加载时计算 `block + offset` 的绝对地址存入 descriptor arg。但不同线程的 TLS block 地址不同，预计算的地址只对主线程有效。

**修复**：arg 存 `tlsdesc_data*`（含 handle + offset），resolver 动态通过 `pthread_getspecific` 获取当前线程的 TLS block。

### 3. pread 对大文件可能短读

**现象**：libjvm.so 加载时 pread 返回的字节数小于请求的。

**根因**：`pread` 不保证一次读完请求的字节数，libjvm.so 的 PT_LOAD 段可达 20+MB。

**修复**：while 循环累积读取直到完成。

### 4. aligned_alloc 的 size 必须是 alignment 的倍数

**现象**：TLS block 分配时可能返回 NULL 或行为未定义。

**根因**：`aligned_alloc(align, size)` 的 C 标准要求 size 是 align 的倍数。

**修复**：`allocSize = (tlsSize + align - 1) & ~(align - 1)`

### 5. new + memset 会破坏 C++ 对象

**现象**：`elf_handle_t` 的 `std::string` 成员 `name` 和 `path` 访问时崩溃。

**根因**：`new elf_handle_t()` 正确构造了 std::string，但紧接着 `memset(h, 0, sizeof(*h))` 把 string 的内部状态全部清零。

**修复**：用 `new elf_handle_t{}` 值初始化（POD 成员清零，C++ 对象正确构造）。

### 6. OHOS zlib.decompressFile 会丢失大文件

**现象**：JDK zip 解压后 `lib/modules`（128MB）缺失。

**根因**：OHOS 的 `zlib.decompressFile` 对大文件处理有问题，可能在解压过程中丢失。

**修复**：解压后验证 `lib/modules` 文件存在且大小合理。增加解压超时到 300 秒。

### 7. Windows 打包的 zip 路径分隔符问题

**现象**：zip 解压后目录结构错误，`lib/` 目录不存在。

**根因**：Windows 上用 PowerShell 打包 zip 时路径分隔符是 `\`，OHOS `zlib.decompressFile` 把 `lib\modules` 当作文件名而不是目录结构。

**修复**：打包时强制用 `/` 作为路径分隔符。

### 8. OHOS sigchain 与 JVM signal handler 的交互

**现象**：JVM 初始化期间 SIGSEGV 导致进程被 DFX crash handler 杀掉。

**根因**：OHOS DFX 通过 `add_special_signal_handler` 注册的 crash handler 在所有普通 sigaction handler 之前执行。JVM 的 SIGSEGV handler 还没来得及处理，DFX 就杀了进程。

**修复**：在 `JNI_CreateJavaVM` 之前用 `add_special_signal_handler` 注册我们自己的 handler，拦截 SEGV 并转发给 JVM handler，阻止 DFX 杀进程。

### 9. HotSpot safepoint polling SEGV

**现象**：JVM 初始化期间反复触发 SIGSEGV（safepoint polling page 被 mprotect 为 PROT_NONE）。

**根因**：HotSpot 用 `mprotect(PROT_NONE)` + SIGSEGV 实现 safepoint polling。ELF-loaded 代码不在 CodeCache 中，JVM handler 无法识别。

**修复**：sigchain handler 把 SEGV 转发给 HotSpot handler，PC 改变则说明 HotSpot 处理了 safepoint，返回 true 阻止 DFX 继续介入。**不要**去修改 HotSpot 的 `safepointMechanism.cpp`（历史上有人改 `MEM_PROT_NONE → MEM_PROT_READ`，结果 Forge `Module.implAddExportsOrOpens(syncVM=true)` 触发全 VM 死锁）。详见 `JDK_ADAPTATION_GUIDE.md` 5.4 节警示框。

### 10. GitHub 镜像缓存旧版文件

**现象**：更新 GitHub Release 的 asset 后，镜像（ghfast.top 等）仍返回旧版。

**根因**：镜像按 URL 缓存文件内容，即使 GitHub 上已更新。

**修复**：改变文件名（如 `jdk17-ohos-full-v3.zip`）或创建新 Release tag 绕过缓存。

### 11. make hotspot 增量构建不重新链接

**现象**：修改 `.cpp` 源码后 `make hotspot` 编译了新 `.o` 但 `libjvm.so` MD5 不变。

**根因**：make 增量构建可能认为链接不需要重做。

**修复**：手动删除旧的 `.o` 文件和 `libjvm.so` 再编译。

### 12. OHOS 应用沙箱权限限制

**现象**：应用无法读取 `/data/local/tmp/` 中的文件。

**根因**：OHOS 应用沙箱严格隔离，即使文件权限是 644，应用 uid 也无法跨沙箱读取。

**影响**：dev helper 的 `/data/local/tmp/libjvm_new.so` 自动复制方案无法工作，必须通过重新下载 JDK 来更新 libjvm.so。

## 注意事项

### ELF Loader 开发
- TLSDESC resolver 是最关键的组件，必须严格遵循 AArch64 TLSDESC ABI
- 所有 caller-saved 寄存器（x0-x17）中除 x0 外都必须保存/恢复
- TLS 方案必须是多线程安全的（每个线程独立的 TLS block）
- pread 对大文件必须循环读取
- C++ 结构体不能用 memset 清零（会破坏非 POD 成员）

### HotSpot 集成
- OHOS sigchain handler 必须在 JNI_CreateJavaVM 之前注册
- sigchain handler 的职责是 **转发给 HotSpot 的 SIGSEGV handler 并根据 PC 是否改变决定 return true/false**
- JVM 的 signal handler 无法识别 ELF-loaded 代码，需要 fallback 处理
- abort_if_unrecognized 必须设为 false（patch signals_posix.cpp）
- PROT_NONE 用于地址空间预留（reserve_memory）不能随意改为 PROT_READ|PROT_WRITE
- ❌ 不要关闭 safepoint polling（`-XX:-UsePollingPageSafepoint`）
- ❌ 不要传 `-XX:+AllowUserSignalHandlers`
- ❌ 不要在 sigchain handler 里对 fault page 做 `mprotect`

### JDK 打包与分发
- zip 文件必须用正斜杠路径分隔符（OHOS zlib 兼容）
- 解压后必须验证关键文件（lib/modules）完整性
- GitHub 镜像有缓存，更新文件需要改文件名或 tag
- lib/modules 是 JVM 必需的 boot class path 文件（~128MB）

### 编译环境
- Docker 容器 `ohos-debug` 包含 OHOS 交叉编译工具链
- `make hotspot JOBS=16 CONF_CHECK=ignore` 编译 libjvm.so
- 修改源码后必须删除旧 .o 和 .so 强制重新编译链接
- libjvm.so 编译产物在 `build/linux-aarch64-server-release/support/modules_libs/java.base/server/libjvm.so`
