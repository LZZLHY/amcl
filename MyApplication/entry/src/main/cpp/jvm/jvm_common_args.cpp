/**
 * jvm_common_args.cpp — 见 .h 文件注释
 *
 * 修改这里之前务必看清注释，错一个参数可能导致 Forge 黑屏或 installer 失败。
 * 具体原因详见 docs/adaptation/JDK_ADAPTATION_GUIDE.md 5 节的警示框。
 */
#include "jvm_common_args.h"

namespace amcl {

const std::vector<std::string>& getCommonJvmArgs() {
    // 使用 function-local static：保证 C++11 线程安全初始化，懒加载。
    static const std::vector<std::string> args = {
        // --------------------------------------------------
        // 基础 VM 配置（主/子进程一致）
        //   UseParallelGC:        默认 GC。与 SerialGC 同一套分代堆布局（无 G1 的 region
        //       元数据 / remembered set / mark bitmap），所以内存占用与 SerialGC 基本一致，
        //       但年轻代与全堆回收都是多线程的。
        //
        //       ⚠️ 换掉 SerialGC 的依据是真机实测（Maleoon 920 平板，MC 26.2-neoforge +
        //       Sodium，飞行 66 秒，1818 Hz 采样 VM Thread 状态；连续处于 R 的一段即一次
        //       stop-the-world 停顿）：
        //
        //           停顿次数        26 次 / 66 秒（约每 2.5 秒一次）
        //           停顿中位数      110.6 ms      p90 142.5 ms      最长 173.3 ms
        //           ≥50 ms          19 次         ≥100 ms  15 次
        //           停顿期间渲染线程被冻结  几乎每次都是整段 100%
        //           停顿总量        仅占墙上时间 3.6%
        //
        //       110 ms 停顿在 60 fps 下等于连丢 6~7 帧，173 ms 连丢 10 帧。总量只有 3.6%
        //       所以平均帧率几乎看不出来，但这正是「飞行时一瞬间掉帧」的来源。同一轮排查
        //       已用 hiperf（718443 个样本）确认 GL 翻译层 libglfw.so 只占 0.65% CPU 周期，
        //       整机 12 核只有 51% 忙 —— 不是算力不足，是所有 Java 线程被周期性冻结。
        //
        //       为什么不是 G1：1000253 曾因 G1 每堆约 10~15% 元数据开销，让重型整合包
        //       （ATM8）在模型烘焙阶段 Java OOM 而回退 SerialGC。ParallelGC 不带那份开销，
        //       所以那条回退理由对它不成立；重型整合包的 G1 路由保持原样不动。
        //
        //       ⚠️ 2026-08-06 更正：下面这段「重型整合包按堆大小路由 G1GC」**在代码里不存在**。
        //       全仓 grep UseG1GC / SoftMaxHeapSize 只命中注释与 CHANGELOG；
        //       mc_launcher.cpp 的对应位置明确写着「保持 SSOT 的收集器（不路由 G1）」。
        //       保留原文如下仅作历史，不要据此判断当前行为：
        //         「重型整合包（大堆）启动时仍由 mc_launcher 按堆大小路由改用 G1GC：
        //           在 extraArgs 注入 -XX:+UseG1GC + SoftMaxHeapSize，jvm_launcher 据此
        //           跳过这里的默认收集器。」
        //       jvm_launcher 里那套「启动方或用户显式选了收集器就跳过 SSOT 默认收集器」
        //       的机制是真实存在且有效的（isGcSelector），只是目前没有任何代码去用它注入 G1。
        //   -UseCompressedOops:   关闭对 narrow oop 的编码，简化 safepoint 处理
        //   -UsePerfData:         禁用 /tmp/hsperfdata 文件（OHOS 沙箱不可写）
        //   -XX:UseSVE=0:         禁用 ARM SVE 指令（HotSpot 检测 SVE 在某些鸿蒙内核上不稳）
        //   +UnlockExperimentalVMOptions / +UnlockDiagnosticVMOptions: 允许下列参数
        //   +DisablePrimordialThreadGuardPages:
        //       OHOS 线程栈 guard page 分配失败会导致随机 crash（Amethyst-iOS 同款修复）
        //   +DisableAttachMechanism:
        //       禁用 JVM attach API，减少对 /tmp 的依赖和安全面
        // --------------------------------------------------
        "-XX:+UseParallelGC",
        "-XX:-UseCompressedOops",
        "-XX:-UsePerfData",
        "-XX:+DisableAttachMechanism",
        "-XX:UseSVE=0",
        "-XX:+UnlockExperimentalVMOptions",
        "-XX:+UnlockDiagnosticVMOptions",
        "-XX:+DisablePrimordialThreadGuardPages",
#ifdef AMCL_STACK_SAMPLER
        // 诊断（仅 -DAMCL_STACK_SAMPLER=ON 构建）：让 JIT 保留 x29 帧指针，使栈采样器
        //   能走出完整 Java 调用链。生产构建不带此项（极小寄存器压力开销）。
        "-XX:+PreserveFramePointer",
#endif
        // 2026-06-06 根因修复（渲染线程黑屏空转）：本机沙箱 sched_getaffinity 在 JVM
        //   启动时常只看到 1 个核 → Runtime.availableProcessors()==1 → MC/Forge 的所有
        //   线程池（含 Forge 并行 mod 加载 ModWorkManager 池、MC Util 后台池）退化为单
        //   线程。Forge 并行 mod 生命周期在单线程池上自依赖饥饿死锁，主线程
        //   ModLoader.waitForTransition 的 while(!future.isDone()) syncExecutor.drive()
        //   忙等永不完成的 future → 100% CPU 空转黑屏（栈采样器定位）。
        //   强制 JVM 报告固定核数，恢复多线程池。
        "-XX:ActiveProcessorCount=8",
        // 2026-06-06 根因修复：自定义 aarch64 OpenJDK 的 C2 误编译 CompletableFuture
        //   的完成传播代码，生成无 safepoint 死循环 → Forge 并行 mod 加载（主线程
        //   ModLoader.waitForTransition 忙等 future）100% CPU 空转黑屏（栈采样器 +
        //   class+init 日志定位；C1-only 验证为 C2 codegen bug；详见
        //   docs/reports/render-thread-spin-c2-completablefuture-202606.md）。
        //   修复：把 java.util.concurrent.CompletableFuture（外层类）所有方法排除出
        //   编译，强制解释执行，绕开 C2。其余全部保留 C2。
        //   收窄说明：曾试过只排 postComplete，因问题间歇性 + 误编译方法可能不止一个，
        //   单方法排除不可靠（仍复现黑屏）→ 收敛到"类级排除"这个可靠且低开销的粒度。
        //   （CompletableFuture 仅做异步编排、不在渲染热路径，解释执行对 FPS 基本无感；
        //    真正的业务 lambda/任务仍正常 C2 编译。）
        //   注：'.' 分隔类名用 '/'；用 '::' 时类名须用 '.'（混用会 CompileCommand 解析失败）。
        "-XX:CompileCommand=exclude,java/util/concurrent/CompletableFuture.*",

        // --------------------------------------------------
        // Forge / Fabric 反射 JDK 内部 API（add-opens java.base）
        // 1.17+ 模组加载器运行时 Unsafe/LambdaMetafactory 反射需要
        // --------------------------------------------------
        "--add-opens=java.base/java.lang=ALL-UNNAMED",
        "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED",
        "--add-opens=java.base/java.util=ALL-UNNAMED",
        "--add-opens=java.base/java.io=ALL-UNNAMED",
        "--add-opens=java.base/java.net=ALL-UNNAMED",
        "--add-opens=java.base/java.nio=ALL-UNNAMED",
        "--add-opens=java.base/sun.security.ssl=ALL-UNNAMED",

        // --------------------------------------------------
        // Cacio AWT 模块打开（Forge installer 固定启用；MC 主进程仅 cacio/ 存在时启用）
        // 主进程即便没启用 Cacio，这些 args 也应该列入 ArkTS 去重表，
        // 避免 version.json 的同名参数被重复传入。
        // --------------------------------------------------
        "--add-exports=java.desktop/java.awt=ALL-UNNAMED",
        "--add-exports=java.desktop/java.awt.peer=ALL-UNNAMED",
        "--add-exports=java.desktop/java.awt.dnd.peer=ALL-UNNAMED",
        "--add-exports=java.desktop/sun.awt=ALL-UNNAMED",
        "--add-exports=java.desktop/sun.awt.image=ALL-UNNAMED",
        "--add-exports=java.desktop/sun.awt.event=ALL-UNNAMED",
        "--add-exports=java.desktop/sun.awt.datatransfer=ALL-UNNAMED",
        "--add-exports=java.desktop/sun.java2d=ALL-UNNAMED",
        "--add-exports=java.desktop/sun.font=ALL-UNNAMED",
        "--add-exports=java.base/sun.security.action=ALL-UNNAMED",
        "--add-opens=java.desktop/java.awt=ALL-UNNAMED",
        "--add-opens=java.desktop/sun.font=ALL-UNNAMED",
        "--add-opens=java.desktop/sun.java2d=ALL-UNNAMED",

        // --------------------------------------------------
        // Forge BootstrapLauncher 内部反射
        // --------------------------------------------------
        "--add-exports=cpw.mods.bootstraplauncher/cpw.mods.bootstraplauncher=ALL-UNNAMED",

        // --------------------------------------------------
        // OHOS 关键兼容性修复（绝对不要删）
        //
        // add-reads org.lwjgl.glfw=jdk.unsupported:
        //   OHOS 版 lwjgl jar 为 automatic module，不会 transitive read jdk.unsupported，
        //   导致访问 sun.misc.Unsafe 抛 IllegalAccessError。
        //
        // java.security.egd=file:/dev/./urandom:
        //   OHOS 沙箱禁止访问 /dev/random，SecureRandom 打开失败会死循环；
        //   /dev/./urandom 绕过 JDK 别名表，走 getrandom(2)。
        // --------------------------------------------------
        "--add-reads=org.lwjgl.glfw=jdk.unsupported",
        "-Djava.security.egd=file:/dev/./urandom",

        // --------------------------------------------------
        // 中文路径修复（2026-06：消除版本目录/游戏目录含中文导致的乱码 / NoSuchFileException）
        //
        // file.encoding=UTF-8:
        //   默认文本 I/O 字符集。JDK 18+（JEP 400）已默认 UTF-8，但 JDK 17 仍跟随 locale，
        //   显式钉死保证 17/21/25 三版本一致。
        // sun.jnu.encoding=UTF-8:
        //   【关键】JVM 在 String 文件名 ↔ 原生字节 之间转换用的编码（open/stat/classpath
        //   解析都走它）。它在 VM 早期由 OS locale 的 CODESET 推断——musl 默认 "C" locale
        //   的 CODESET 报 ASCII → 含中文的 classpath / user.dir / 文件名被损坏 →
        //   NoSuchFileException / 乱码。这里用 -D 覆盖属性值；真正的 locale 源头另在
        //   jvm_launcher.cpp / fork_run_java.cpp 用 setenv(LC_ALL/LANG=...UTF-8) 钉死
        //   （两道一起才能让原生路径转换也走 UTF-8）。
        // --------------------------------------------------
        "-Dfile.encoding=UTF-8",
        "-Dsun.jnu.encoding=UTF-8",

        // --------------------------------------------------
        // Mod 兼容（2026-06）：放行 Sodium / Iris 在定制 LWJGL 上启动
        //
        // sodium.checks.issue2561=false:
        //   Sodium 有一道启动前硬校验（caffeinemc GH#2561）：运行时 LWJGL 版本必须 == MC 捆绑
        //   的版本，否则 System.exit 拒绝启动（连更高版本也拒）。但移动端启动器（AMCL/FCL/Pojav）
        //   本就用定制 LWJGL（GLES 后端），版本必然"不符"——Sodium 官方为此提供了这个关闭开关。
        //   FoldCraftLauncher 的 DefaultLauncher 也是无条件 addDefault 这一条（实测对齐）。
        //   不加则 MC 1.21.x + Sodium/Iris 启动即崩（真机日志：Required 3.3.3 / Installed 3.4.1）。
        //   用户若想恢复检查，可在"自定义 JVM 参数"里写 -Dsodium.checks.issue2561=true 覆盖
        //   （用户参数优先级最高，见 LaunchProfileBuilder.mergeUserJvmArgs）。
        // --------------------------------------------------
        "-Dsodium.checks.issue2561=false",
    };
    return args;
}

} // namespace amcl
