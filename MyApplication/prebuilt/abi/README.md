# 应用 ABI provider 修复输入

`source.json` 固定 OpenHarmony 公开 LLVM 15 vendor 源；这不是商业 SDK 编译来源的
追溯声明。现有 SDK `libc++_static.a` 已包含 libc++abi，保留它的真实 guard、EH、RTTI、
分配及 `std::__n1` 对象实现，只用锁定并加补丁的真实 libunwind 替换其展开部分。
产物仍为单一 `libc++_shared.so`，不是在应用进程内再加载第二个 C++ 运行时。

必要性来自所选 SDK 的实际反汇编：动态 FDE cache 扩容在 malloc 之后直接 memcpy。
补丁为真实缓存增加溢出/分配/锁失败返回，原 SDK 导出全部保留。自加载集成使用
`amcl_unwind_register_image` 与 `amcl_unwind_unregister_image`，每个映像仅登记
一个已校验的范围描述符，让 LLVM 沿用 `.eh_frame_hdr` 的二分查找。当前 JDK25
的 libjvm 含 50,243 条 FDE，逐条塞入原线性缓存会放大查询与注销成本，不作为
正式路线。无 EH header 的合法对象仍可用真实 LLVM 扫描/缓存，注销映像时清理
对应缓存分组。空表查询无锁，登记失败原表不变，未知/重叠映像准确拒绝。

接口要求 loader 先完成有界 EH 校验并保持映射直到合法展开结束；它不是对任意
恶意指针的内存安全接口。注册失败时可在任何构造器之前撤销本批。旧 void API
保持兼容。早期按 FDE 的两个状态 API 只存在于未集成原型，已经由当前映像接口
替代，不能混用原型 provider 的身份或资格。

构建使用固定 Compose QA 服务：

```powershell
python -B docker/project.py test --suite unwind-cache --unwind-source <固定 vendor Git 克隆>
python -B docker/project.py test --suite application-abi --unwind-source <固定 vendor Git 克隆> --sysroot <所选 SDK sysroot>
```

执行器从固定 Git commit 导出来源，补丁与完整目标 SDK 输入冻结为只读快照；当前
工作树修改不替代源码身份。`unwind-cache` 用真实上游模板执行 ASan/UBSan 正反控制、
扩容失败/重试及并发 churn；`application-abi` 构建 provider 和包含生产 mapper 的
异常展开夹具，并核对完整导出集合。`jdk-abi-run --test-arg elf-unwind` 使用实际 libc
运行跨系统/自加载帧的异常清理、嵌套调用、含/不含索引的注销/重开及缺登记负控制。
实际 AArch64 跨 DSO 行为、真机 HAP、产品自动 EH 生命周期和性能资格分别执行，不能从符号
集合相同推断全部 ABI 语义。当前集成进度以施工记录为准，未通过前不替换正式 HAP。
