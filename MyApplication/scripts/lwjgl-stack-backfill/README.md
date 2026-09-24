# LWJGL `*Stack` 回填（mallocStack / callocStack）

## 为什么需要

LWJGL 在 3.2.x 把结构体的 `mallocStack` / `callocStack` 静态便捷分配方法标为 deprecated，
**3.3.1 之后移除**。但 Minecraft **1.13–1.19.x** 的字节码仍调用它们（典型：MC 1.19.2 的
`Window.setIcon` 调 `GLFWImage.mallocStack(int, MemoryStack)`）。

AMCL 对「声明 LWJGL 3.3+」的 MC 统一用单套 **3.4.1**（`prebuilt/lwjgl3/jars` →
`rawfile/lwjgl/` → 运行时部署到 `<mcDir>/lwjgl-ohos/`），其中这些方法已不存在 →
启动崩 `NoSuchMethodError: GLFWImage.mallocStack(...)`。

> 真机定位：ATM8（MC 1.19.2 / Forge）越过 MobileGlues 的 Quartz 扩展门后，崩在
> `Window.m_85395_(Window.java:169)`。MC 1.19–1.19.2 锁 LWJGL 3.3.1（还有 mallocStack），
> 落到 341 套（3.4.1，已移除）。1.19.3+/1.20.x 声明 3.3.2/3.3.3，Mojang 那时已改用
> `malloc(stack)`，故在 3.4.1 上无此问题。

## 方案（FCL/Pojav 同款"超集"，native 零改动）

对每个仍带现代 stack 分配器（`malloc(MemoryStack)` / `malloc(int, MemoryStack)` 及
calloc 双胞胎）的 Struct 类，**字节码注入回**被删的 `*Stack` 静态方法，全是纯 Java 薄委托：

```
mallocStack()                  -> malloc(MemoryStack.stackGet())
mallocStack(MemoryStack s)     -> malloc(s)
mallocStack(int n)             -> malloc(n, MemoryStack.stackGet())
mallocStack(int n, MemoryStack s) -> malloc(n, s)
（callocStack 四个同理）
```

按「目标 `malloc(...)` 是否存在」探测，只动真正的 Struct 类、自动随上游演进；**幂等**
（已有的方法跳过，重跑加 0）。native（liblwjgl*.so）完全不动，jar 体积仅微增。

## 文件

- `StackBackfill.java` — ASM(tree) 字节码注入器。
- `apply.mjs` — 编译并对给定目录下所有 `*.jar` 跑注入器（幂等）。
- `lib/asm-9.9.jar`, `lib/asm-tree-9.9.jar` — vendored ASM（免依赖 gradle 缓存）。
- `out/` — 编译产物（gitignore，按需重建）。

## 用法

```bash
# 需 JDK（javac+java）在 PATH 或 JAVA_HOME
node scripts/lwjgl-stack-backfill/apply.mjs \
  prebuilt/lwjgl3/jars \
  entry/src/main/resources/rawfile/lwjgl
```

## 与构建管线的关系（durability）

回填结果已**提交进** `prebuilt/lwjgl3/jars/*.jar` 与 `entry/.../rawfile/lwjgl/*.jar`
（与 `patch-lwjgl-module-info.py` 的根 module-info 补丁同一"提交进制品"模式）。
`scripts/sync_prebuilt.sh` 在重新拉/同步 LWJGL jar 后会再跑本注入器（幂等），保证
重建 LWJGL 时回填不丢。运行时 `RuntimeDeployer.extractLwjglJars` 每次都从 rawfile
重新解包到设备，故升级 HAP 后设备上的 jar 会被刷新为回填版。

## 升级 LWJGL 时

升级 341 套后，本注入器幂等，直接重跑 `apply.mjs` 即可；若上游某天又把 `*Stack` 加回
（不太可能），探测会因目标已存在而跳过，安全。
