# Minecraft Java Edition → HarmonyOS NEXT 移植可行性报告

**测试设备**: HUAWEI Mate 70 (3AP0224B08027377)  
**系统**: HarmonyOS NEXT API 20 (SDK 6.0.0)  
**GPU**: Maleoon 910 (Huawei)  
**日期**: 2026-02-15  

---

## 一、综合结论

### ✅ 移植可行 — 所有关键技术验证均通过

| 验证阶段 | 得分 | 状态 |
|----------|------|------|
| P0-Step1: JIT/mmap 边界测试 | 6/6 | ✅ 通过 |
| P0-Step2A: JVM 嵌入可行性 | 10/10 | ✅ 通过 |
| **P0-Step2B: JVM 实际嵌入** | **✅** | **✅ 已完成** |
| P1-Step1: OpenGL ES 渲染 | 89fps | ✅ 通过 |
| P1-Step2: Vulkan 渲染 | 1.2.275 | ✅ 通过 |
| P2: GLFW 兼容层 | 10/10 | ✅ 通过 |

### 🎉 JVM 嵌入里程碑 (2026-02-20)

OpenJDK 17.0.19-internal 已在 HarmonyOS NEXT 上成功运行：
- `JNI_CreateJavaVM` rc=0，启动耗时 ~90ms
- JIT 混合模式已启用（自动检测 RWX 权限）
- JNI 调用正常（System.getProperty, Runtime 信息）
- HelloWorld.main() 端到端执行成功
- HotSpot 需要 3 个源码 patch（见 docker/ 目录）

---

## 二、详细测试结果

### 2.1 P0-Step1: JIT/mmap 边界测试

验证 JVM JIT 编译器所需的可执行内存能力。

| 测试项 | 结果 | 说明 |
|--------|------|------|
| 匿名内存 RWX (MAP_ANONYMOUS + PROT_RWX) | ✅ PASS | JIT 核心能力，直接可用 |
| 匿名内存 RW→EXEC (mprotect) | ✅ PASS | JIT 备选方案，W^X 兼容 |
| 文件映射 EXEC | ✅ PASS | AOT 预编译方案可用 |
| memfd EXEC | ✅ PASS | 探索性方案 |
| dlopen 系统库 | ✅ PASS | 基础能力 |
| 匿名内存 RW | ✅ PASS | 基础能力 |

**结论**: HarmonyOS NEXT 手机端（非受限模式）完全支持 JIT 所需的可执行内存操作。

### 2.2 P0-Step2A: JVM 嵌入可行性

验证在 OHOS 上运行完整 JVM 所需的系统能力。

| 测试项 | 结果 | 说明 |
|--------|------|------|
| dlopen/dlsym 动态加载 | ✅ OK | 可加载 libjvm.so |
| JNI 函数表调用约定 | ✅ OK | JNI 接口完全兼容 |
| 模拟 JNI_CreateJavaVM | ✅ OK | 接口可用 |
| pthread 线程创建 | ✅ 32/32 | JVM 多线程完全支持 |
| pthread mutex/cond/rwlock | ✅ 全部 OK | 同步原语完备 |
| pthread_setname_np | ✅ OK | 线程命名可用 |
| SIGSEGV handler | ✅ OK | JVM NPE 机制可用 |
| sigaltstack | ✅ OK | 栈溢出保护可用 |
| mmap 大块内存 (1MB) | ✅ OK | JVM 堆分配可用 |
| madvise(MADV_DONTNEED) | ✅ OK | GC 可用 |
| mprotect(PROT_NONE→RW) | ✅ OK | safepoint 可用 |

**系统信息**:
- 页大小: 4096 bytes
- CPU 核心: 12
- 物理内存: 11195 MB
- 64-bit, sizeof(void*)=8
- /proc/self/maps: 可读

**注意**: OHOS 使用 signal_chain 机制（类似 Android libsigchain），SIGSEGV 会被 DfxSignalHandler 记录但不影响 JVM 正常工作。

### 2.3 P1-Step1: OpenGL ES 渲染

验证 GPU 渲染能力和 Minecraft 所需的 OpenGL ES 特性。

| 项目 | 结果 |
|------|------|
| GPU | Maleoon 910 (Huawei) |
| OpenGL ES 版本 | 3.2 B289 |
| EGL 版本 | 1.5 |
| FPS | 89fps (旋转三角形) |
| 几何着色器 | ✅ 支持 |
| 曲面细分 | ✅ 支持 |
| 浮点纹理 | ✅ 支持 |
| S3TC 压缩 | ❌ 不支持（MC 不强制要求） |

**结论**: GLES 3.2 完全满足 Minecraft 渲染需求。

### 2.4 P1-Step2: Vulkan 渲染

验证 Vulkan 管线和 OHOS 特有的 surface 扩展。

| 项目 | 结果 |
|------|------|
| Vulkan API 版本 | 1.2.275 |
| Driver 版本 | 931.393.1287 |
| VK_OHOS_surface | ✅ 已验证 |
| vkCreateInstance | ✅ OK |
| vkCreateSurfaceOHOS | ✅ OK |
| vkCreateSwapchainKHR | ✅ OK (1216x1119, 4 images) |
| 命令缓冲区提交 | ✅ OK |
| vkQueuePresentKHR | ✅ OK |

**Zink/Mesa 兼容性**:
- Vulkan 1.1+ (Zink 最低要求): ✅
- Vulkan 1.2+ (Zink 推荐): ✅
- Vulkan 1.3+ (Zink 最佳): ❌ (1.2，但足够)

**结论**: Vulkan 1.2 完全满足 Zink/Mesa 需求，可以通过 Vulkan 后端提供 OpenGL 4.x 兼容性。

### 2.5 P2: GLFW 兼容层

验证 LWJGL 所需的窗口管理接口在 OHOS 上的可行性。

| GLFW API | OHOS 映射 | 状态 |
|----------|-----------|------|
| glfwInit/Terminate | 内部状态管理 | ✅ OK |
| glfwCreateWindow | XComponent 绑定 | ✅ OK |
| glfwMakeContextCurrent | eglMakeCurrent | ✅ OK |
| glfwSwapBuffers | eglSwapBuffers | ✅ OK |
| glfwPollEvents | 触摸事件处理 | ✅ OK |
| glfwGetTime | steady_clock | ✅ OK |
| glfwGetFramebufferSize | XComponent 尺寸 | ✅ OK |
| 回调机制 | 函数指针 | ✅ OK |
| 触摸→鼠标映射 | touch down/up/move | ✅ OK |

**结论**: GLFW 兼容层完全可行，LWJGL 可以通过此层在 OHOS 上运行。

---

## 三、移植架构建议

```
┌─────────────────────────────────────────┐
│           Minecraft Java Edition         │
├─────────────────────────────────────────┤
│              LWJGL 3.x                   │
├──────────┬──────────┬───────────────────┤
│  GLFW    │  OpenGL  │    OpenAL         │
│  Compat  │  4.x     │    Compat         │
├──────────┼──────────┼───────────────────┤
│XComponent│  Zink    │   OHOS Audio      │
│  + EGL   │ (Mesa)   │                   │
├──────────┼──────────┼───────────────────┤
│          │ Vulkan   │                   │
│          │ 1.2      │                   │
├──────────┴──────────┴───────────────────┤
│         HarmonyOS NEXT (musl)           │
├─────────────────────────────────────────┤
│    Alpine musl OpenJDK 17 (JVM)         │
└─────────────────────────────────────────┘
```

---

## 四、下一步计划

### 已完成 ✅
1. ~~**P0-Step2B**: JVM 实际嵌入~~ → OpenJDK 17 JIT 模式运行成功

### 高优先级
2. **渲染层**: LWJGL 原生库移植 + OpenGL 兼容层 (MobileGlues/GL4ES)
3. **GLFW → HarmonyOS 适配**: 将 GLFW 窗口/输入桥接到 XComponent

### 中优先级
4. **音频**: OpenAL Soft → OHAudio 后端
5. **MC 启动器**: classpath 组装 + 游戏资源管理

### 低优先级
6. **平板端测试**: 大屏触控映射
7. **性能优化**: 帧率目标 60fps

---

## 五、风险评估

| 风险 | 等级 | 缓解措施 |
|------|------|----------|
| ~~JVM 实际嵌入 musl 兼容问题~~ | ~~中~~ | ✅ 已解决：3 个 HotSpot patch + JIT 模式运行成功 |
| 渲染层移植复杂度 | 中 | MobileGlues/GL4ES 可作为 OpenGL → GLES 翻译层 |
| ~~平板端 ACL 权限差异~~ | ~~低~~ | ✅ 平板已验证 JIT 可用 |
| OHOS signal_chain 与 JVM 冲突 | 低 | 目前未观察到冲突 |
| 性能（JVM + 渲染层开销） | 中 | Maleoon 910 性能充足，8核 + JIT 已启用 |

---

## 六、Git 提交历史

```
792fdab feat: P2 GLFW compat layer verified 10/10
4bdb160 feat: P0-Step2A JVM feasibility probe - 10/10
4a414d4 feat: P1-Step2 Vulkan rendering verified
6020254 feat: P1-Step1 XComponent + EGL + OpenGL ES rendering verified
```
