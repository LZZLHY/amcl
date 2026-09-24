package com.amcl.launcher;

import java.io.*;
import java.lang.reflect.Method;
import java.net.URL;

/**
 * AMCL Java 启动入口。
 *
 * 由 C 层 jvmCallMain("com.amcl.launcher.AmclLauncher") 调用。
 * 在 MC main() 之前执行预处理，然后通过系统 ClassLoader 加载并调用 MC mainClass。
 *
 * 核心改进（参考 Amethyst-iOS PojavLauncher）：
 *   - 使用 -Djava.system.class.loader=AmclClassLoader 替换系统 CL
 *   - 所有 MC jar 动态添加到系统 CL（不再创建独立的 URLClassLoader）
 *   - Forge/Fabric 保留各自的库分类、模块层与定义规则，不假设会共享系统 CL 的同名类
 *   - 设置 context ClassLoader 为系统 CL，确保 Forge BootstrapLauncher 正确工作
 *
 * 启动流程：
 * 1. 解析 JSON 格式的启动配置
 * 2. 获取系统 ClassLoader（已被替换为 AmclClassLoader）
 * 3. 动态添加所有 MC jar 到系统 CL
 * 4. 设置系统属性
 * 5. Forge 预处理（fml.toml + splash.properties）
 * 6. 设置 context ClassLoader
 * 7. 反射调用 MC mainClass.main(mcArgs)
 */
public class AmclLauncher {

    private static final ThreadLocal<PreparedLaunch> PREPARED = new ThreadLocal<PreparedLaunch>();

    /**
     * classpath 交付方式（ArkTS 世代契约表的产出，经 {@code -Damcl.classpathDelivery=} 下传）。
     * 字面量与 ArkTS 的 {@code ClasspathDelivery} 逐字对应，由
     * {@code scripts/check-launch-generation-contract.mjs} 静态校验两侧一致。
     */
    private static final String DELIVERY_PROP = "amcl.classpathDelivery";
    private static final String DELIVERY_AMCL_LOADER_ONLY = "amcl-loader-only";

    /**
     * {@link #verifyClasspathDelivery} 的结论，留到 Phase 5 复述。
     *
     * <p>校验本身必须留在 Phase 1.5（要在加载器崩之前 fail fast），但那一阶段的
     * `System.out` 写的是被 OHOS 丢弃的原始 stdout ⇒ 结论看不到。
     * 一个看不到的判据等于没有判据，所以把它存下来、换流之后再打一次。</p>
     *
     * <p>用 static 而不是实例字段：一个进程只启动一局游戏（MC 退出即杀进程），
     * 且 prepare/main 由协议要求跑在同一条线程上。</p>
     */
    private static volatile String deliveryVerdictLine = "";

    /**
     * ⭐ 三层防线里的**第 ③ 层，也是唯一能否证"实际值"的一层**。
     *
     * <p>启动契约的核心命题是"{@code java.class.path} 的实际值符合本世代要求"。
     * ArkTS 的 preflight 看不到那个值（它由 C 层在 JVM 创建前写入），C 层写完也不回读 ——
     * 只有跑在 JVM 里的这里能读到 {@code System.getProperty("java.class.path")} 的**真值**。
     * 若这一层缺失，"表里声明了 full"与"实际真的是 full"在日志里长得一模一样。</p>
     *
     * <p>两个方向的处置**刻意不对称**，依据是最坏后果不对称：</p>
     * <ul>
     *   <li><b>声明 full、实际 narrow ⇒ 抛异常。</b> 加载器接下来必定崩
     *       （Forge 新 bootstrap 报 {@code NoSuchElementException}、Fabric 报
     *       {@code couldn't locate the game}），而那两个报错都指不到真正的原因。
     *       在这里失败能给出一条指名道姓的消息。</li>
     *   <li><b>声明 narrow、实际 full ⇒ 只告警。</b> 后果是字节码变换静默失效（掉帧），
     *       游戏仍可玩。为一个性能退化阻断启动与"不希望无法启动"的产品要求相反。</li>
     * </ul>
     */
    private static void verifyClasspathDelivery(LaunchConfig config) {
        String declared = System.getProperty(DELIVERY_PROP, "");
        String actual = System.getProperty("java.class.path", "");
        // narrow 的定义就是"只有 amcl-launcher.jar 一条" ⇒ 条目数即判据，
        // 不去匹配路径内容（那会引入一份对 classpath 组装规则的第二副本）。
        int entries = actual.isEmpty() ? 0 : actual.split(java.io.File.pathSeparator, -1).length;
        boolean actualNarrow = entries <= 1;
        boolean declaredNarrow = DELIVERY_AMCL_LOADER_ONLY.equals(declared);

        deliveryVerdictLine = "[AMCL-CP-DELIVERY] schema=1 declared="
            + (declared.isEmpty() ? "(absent)" : declared)
            + " actual=" + (actualNarrow ? "narrow" : "full")
            + " jvm_cp_entries=" + entries
            + " game_cp_jars=" + config.classpath.length;
        // 这一行在 Phase 1.5 是不可见的（stdout 被丢弃），真正被读到的是
        // launchPrepared 里的那次复述。此处仍然打，是为了在**将来** Phase 1.5 的
        // 输出通道被修好时不需要回来补。
        System.out.println(deliveryVerdictLine);

        if (declared.isEmpty()) {
            // 上游协议破了。不阻断：C 层同样 fail-open 到 full。
            System.err.println("[AMCL-CP-DELIVERY] WARNING: " + DELIVERY_PROP
                + " not set; cannot verify the launch contract for this run");
            return;
        }
        if (!declaredNarrow && actualNarrow) {
            throw new IllegalStateException("Launch contract violated: generation declares '"
                + declared + "' (game classpath must be on java.class.path) but the JVM was"
                + " started with only " + entries + " classpath entry."
                + " This loader reads java.class.path exclusively and would fail with an"
                + " unrelated-looking error. See docs/refactor/启动世代契约规范.md §3.3.");
        }
        if (declaredNarrow && !actualNarrow) {
            System.err.println("[AMCL-CP-DELIVERY] WARNING: generation declares '" + declared
                + "' but java.class.path has " + entries + " entries;"
                + " AmclClassLoader bytecode transforms will be bypassed by parent-first"
                + " delegation (performance regression, not a crash)");
        }
    }

    /** 本次启动是否走"仅 AmclClassLoader 持有游戏 classpath"。隔离断言的作用域判据。 */
    private static boolean isAmclLoaderOnlyDelivery() {
        return DELIVERY_AMCL_LOADER_ONLY.equals(System.getProperty(DELIVERY_PROP, ""));
    }

    /**
     * 原生启动协议的 Java 准备阶段：挂载 classpath 并校验交付，不初始化 SDL/LWJGL。
     * 实际平台类和 JNI 库归上游加载器合法消费者所有；本方法必须与 main 在同一
     * attached 线程执行，ThreadLocal 的 prepared state 不跨线程、不跨游戏复用。
     */
    public static void prepare(String launchConfigJson) throws Throwable {
        if (launchConfigJson == null) {
            throw new IllegalArgumentException("Missing launch config JSON argument");
        }
        if (PREPARED.get() != null) {
            throw new IllegalStateException("A launch is already prepared on this thread");
        }
        PREPARED.set(prepareLaunch(launchConfigJson));
        System.out.println("[AMCL-CLASSLOADER] schema=1 phase=prepare status=active");
    }

    public static void main(String[] args) throws Throwable {
        System.out.println("[AmclLauncher] Starting...");

        if (args == null || args.length == 0 || args[0] == null) {
            throw new IllegalArgumentException("Missing launch config JSON argument");
        }

        PreparedLaunch prepared = PREPARED.get();
        if (prepared == null) {
            prepared = prepareLaunch(args[0]);
        } else if (!prepared.launchConfigJson.equals(args[0])) {
            throw new IllegalStateException("Prepared launch config does not match main() argument");
        }

        try {
            launchPrepared(prepared);
        } finally {
            try {
                TerrainWaitDiagnostics.shutdown();
            } finally {
                try {
                    TerrainRangeRetirement.shutdown();
                } finally {
                    TerrainStagingCompatibility.shutdown();
                    TerrainHeapCompatibility.shutdown();
                    PREPARED.remove();
                }
            }
        }
    }

    private static PreparedLaunch prepareLaunch(String launchConfigJson) throws Throwable {

        AwtRuntime.initialize();

        // 1. 解析启动配置
        LaunchConfig config = LaunchConfig.parse(launchConfigJson);
        if (config == null) {
            throw new IllegalArgumentException("Failed to parse launch config JSON");
        }
        if (config.mainClass == null || config.mainClass.isEmpty()) {
            throw new IllegalArgumentException("mainClass is empty in launch config");
        }

        System.out.println("[AmclLauncher] mainClass=" + config.mainClass
            + " classpath=" + config.classpath.length + " jars"
            + " forge=" + config.isForge + " fabric=" + config.isFabric);

        // 2. 获取系统 ClassLoader（已被 -Djava.system.class.loader 替换为 AmclClassLoader）
        ClassLoader sysCL = ClassLoader.getSystemClassLoader();
        AmclClassLoader loader;
        if (sysCL instanceof AmclClassLoader) {
            loader = (AmclClassLoader) sysCL;
            System.out.println("[AmclLauncher] Using system ClassLoader (AmclClassLoader)");
        } else {
            if (Boolean.parseBoolean(System.getProperty("amcl.platform.ohos", "false"))) {
                throw new IllegalStateException("OHOS launch requires AmclClassLoader as the system "
                    + "ClassLoader, actual=" + sysCL.getClass().getName());
            }
            // 非 OHOS 工具/测试保留独立加载器降级；真机必须走上面的失败即停止契约。
            System.out.println("[AmclLauncher] WARNING: System CL is " + sysCL.getClass().getName()
                + ", falling back to standalone AmclClassLoader");
            URL[] urls = config.getClasspathUrls();
            loader = new AmclClassLoader(urls, sysCL);
        }

        // 3. 动态添加所有 MC jar 到系统 CL
        //    参考 Amethyst-iOS Tools.launchMinecraft():
        //      PojavClassLoader loader = (PojavClassLoader) ClassLoader.getSystemClassLoader();
        //      for (String s : launchClassPath.split(":")) { loader.addURL(...); }
        if (sysCL instanceof AmclClassLoader) {
            // 添加所有 MC jar
            for (String path : config.classpath) {
                if (path != null && !path.isEmpty()) {
                    loader.addJar(path);
                }
            }
            System.out.println("[AmclLauncher] Added " + config.classpath.length
                + " jars to system ClassLoader");
        }

        // 校验实际的 java.class.path 与世代契约一致（第 ③ 层，见 verifyClasspathDelivery）。
        verifyClasspathDelivery(config);

        // 隔离断言**只在 amcl-loader-only 交付下成立**。
        //
        // ⚠️ 它们不是被"删掉"，是被限定到唯一成立的作用域：jvm-classpath-full 下游戏主类
        //    必然由 AppClassLoader 定义（这正是桌面端/HMCL/FCL 的行为），两条断言在那里
        //    恒失败。契约见 docs/refactor/启动世代契约规范.md §3.4。
        if (isAmclLoaderOnlyDelivery()) {
            // Parent-first delegation is safe only when the bootstrap parent cannot
            // see the game entrypoint. Fail before any game class is initialized.
            loader.requireIsolatedGameMain(config.mainClass);
        } else {
            // 刻意打一行而不是静默跳过：否则"作用域外所以不查"与"查了但没执行"
            // 在日志里无法区分（本仓 1000544 那一族）。
            System.out.println("[AMCL-CLASSLOADER] schema=1 phase=isolation status=out-of-scope"
                + " main=" + config.mainClass
                + " delivery=" + System.getProperty(DELIVERY_PROP, "(absent)")
                + " reason=game-classes-owned-by-mod-loader");
        }

        // 4. 设置系统属性
        setupSystemProperties(config);

        // 5. Forge 预处理
        if (config.isForge) {
            System.out.println("[AmclLauncher] Running Forge pre-launch setup...");
            ForgeHelper.disableEarlyDisplay(config);
            ForgeHelper.disableForgeSplash(config);
        }

        // 6. 设置 context ClassLoader
        //    Forge 的 BootstrapLauncher 通过 Thread.currentThread().getContextClassLoader()
        //    获取 parent ClassLoader。必须设置为包含 MC jar 的 ClassLoader。
        Thread.currentThread().setContextClassLoader(loader);
        System.out.println("[AmclLauncher] Set context ClassLoader to " + loader.getClass().getName());

        return new PreparedLaunch(launchConfigJson, config, loader);
    }

    private static void launchPrepared(PreparedLaunch prepared) throws Throwable {
        LaunchConfig config = prepared.config;
        AmclClassLoader loader = prepared.loader;

        AwtRuntime.reportAfterRedirect();

        // Fabric 库清单的可观测判据。放在这里（Phase 5）而不是设置点（Phase 1.5），
        // 因为 stdout 到 Phase 4 才被重定向进 mc_output.log。
        if (config.isFabric) reportFabricGameLibraries();

        // 7. 加载并调用 MC mainClass
        System.out.println("[AmclLauncher] Loading " + config.mainClass + "...");
        Class<?> mainClass;
        try {
            mainClass = loader.loadClass(config.mainClass);
        } catch (ClassNotFoundException e) {
            System.err.println("[AmclLauncher] FATAL: mainClass not found: " + config.mainClass);
            System.err.println("[AmclLauncher] classpath size: " + config.classpath.length + " jars");
            // 输出前 10 个 classpath 条目以辅助诊断
            int preview = Math.min(10, config.classpath.length);
            for (int i = 0; i < preview; i++) {
                System.err.println("[AmclLauncher]   cp[" + i + "]: " + config.classpath[i]);
            }
            if (config.classpath.length > preview) {
                System.err.println("[AmclLauncher]   ... and " + (config.classpath.length - preview) + " more");
            }
            throw e;
        }
        // 复述 Phase 1.5 的两组判定。**必须在这里而不是 Phase 1.5** ——
        // 那一阶段的 System.out 写的是被 OHOS 丢弃的原始 stdout（见各自的注释）。
        if (!deliveryVerdictLine.isEmpty()) System.out.println(deliveryVerdictLine);
        // 与 delivery 无关：两种交付下都要能看到"补丁集算出了什么"。
        loader.reportPatchSetStatesAfterRedirect();
        // 同一条形状的第三处：C0 探针的 premain 结论也发生在换流之前。
        // **探针没装时它也打一行**（status=absent）—— 那是"默认关"的产品实际值。
        if (AmclBuildProfile.DEVELOPER_DIAGNOSTICS) AmclAgentProbe.reportAfterRedirect();

        // 同 requireIsolatedGameMain：只在 amcl-loader-only 交付下成立（§3.4）。
        if (isAmclLoaderOnlyDelivery()) {
            loader.requireOwnedGameMain(mainClass);
        } else {
            System.out.println("[AMCL-CLASSLOADER] schema=1 phase=main-owner status=out-of-scope"
                + " main=" + mainClass.getName()
                + " owner=" + (mainClass.getClassLoader() == null
                    ? "(bootstrap)" : mainClass.getClassLoader().getClass().getName())
                + " delivery=" + System.getProperty(DELIVERY_PROP, "(absent)"));
        }

        Method mainMethod;
        try {
            mainMethod = mainClass.getMethod("main", String[].class);
        } catch (NoSuchMethodException e) {
            System.err.println("[AmclLauncher] FATAL: " + config.mainClass + " has no main(String[]) method");
            throw e;
        }

        // 可选：设置 -Damcl.watchdog=true 开启 Java 层 watchdog (每 10s dump 线程栈)。
        // 默认关闭，避免生产运行时刷屏、增加 CPU 开销。
        if (Boolean.getBoolean("amcl.watchdog")) {
            startJavaWatchdog();
        }

        // MC 26.2 + NeoForge: once the transformed Minecraft client is fully
        // running, default Sodium's oversized buffer-arena F3 heatmap to NEVER.
        // The helper fails closed on every other version/loader and never loads
        // Minecraft classes before NeoForge has loaded them itself.
        DebugProfileCompat.install(config, Thread.currentThread());

        // Boundary-stall attribution (property-gated, diagnosis phase): this
        // thread becomes the render thread inside MC main, so hand exactly it
        // to the sampler instead of guessing by thread name later.
        RenderStallSampler.install(Thread.currentThread());

        System.out.println("[AmclLauncher] Invoking " + config.mainClass + ".main() with "
            + config.mcArgs.length + " args");
        reportGraphicsBackendArgument(config.mcArgs);
        try {
            mainMethod.invoke(null, (Object) config.mcArgs);
        } catch (Throwable t) {
            // 打印完整调用栈有助于模组冲突/Forge 初始化错误定位
            System.err.println("[AmclLauncher] mainClass.main() threw: " + t);
            Throwable root = t;
            while (root.getCause() != null) root = root.getCause();
            if (root != t) {
                System.err.println("[AmclLauncher] root cause: " + root);
            }
            throw t;
        }

        System.out.println("[AmclLauncher] mainClass.main() returned");
    }

    /**
     * Minecraft 26.2+ owns the final RenderPearl API selection.  Keep a
     * compact, non-sensitive echo of the effective argument in the redirected
     * game log so a remote run can distinguish "Vulkan was requested" from
     * "the native Vulkan loader was merely present".
     */
    private static void reportGraphicsBackendArgument(String[] args) {
        if (args == null) {
            System.out.println("[AMCL-GRAPHICS-ARGS] graphicsBackend=absent reason=args-null");
            return;
        }
        for (int i = 0; i < args.length; i++) {
            String arg = args[i];
            if ("--graphicsBackend".equals(arg) && i + 1 < args.length) {
                System.out.println("[AMCL-GRAPHICS-ARGS] graphicsBackend=" + args[i + 1]
                    + " source=launch-config");
                return;
            }
            if (arg != null && arg.startsWith("--graphicsBackend=")) {
                System.out.println("[AMCL-GRAPHICS-ARGS] graphicsBackend="
                    + arg.substring("--graphicsBackend=".length())
                    + " source=launch-config");
                return;
            }
        }
        System.out.println("[AMCL-GRAPHICS-ARGS] graphicsBackend=absent source=launch-config");
    }

    private static final class PreparedLaunch {
        final String launchConfigJson;
        final LaunchConfig config;
        final AmclClassLoader loader;

        PreparedLaunch(String launchConfigJson, LaunchConfig config, AmclClassLoader loader) {
            this.launchConfigJson = launchConfigJson;
            this.config = config;
            this.loader = loader;
        }
    }

    /**
     * 启动 Java 层 watchdog daemon，把所有线程栈写入 stderr
     * (最终进入 mc_output.log)。仅在 -Damcl.watchdog=true 时启用；Vulkan
     * 启动诊断由 -Damcl.vulkan.startupWatchdog=true 限定为 5 个快照。
     *
     * 保留该实现是为了在后续遇到类似 Forge 死锁的难题时，能够不改原生层、
     * 仅加一个 JVM 属性就抓到全部 Java 线程的现场。
     */
    private static void startJavaWatchdog() {
        final boolean boundedVulkanStartup = Boolean.getBoolean("amcl.vulkan.startupWatchdog");
        final long intervalMillis = boundedVulkanStartup ? 8000L : 10000L;
        final int maxRounds = boundedVulkanStartup ? 5 : Integer.MAX_VALUE;
        Thread t = new Thread(() -> {
            int round = 0;
            while (true) {
                try { Thread.sleep(intervalMillis); } catch (InterruptedException ie) { return; }
                round++;
                StringBuilder sb = new StringBuilder();
                sb.append("\n========== [WD #").append(round).append("] Java Thread Dump ==========\n");
                java.util.Map<Thread, StackTraceElement[]> all = Thread.getAllStackTraces();
                for (java.util.Map.Entry<Thread, StackTraceElement[]> e : all.entrySet()) {
                    Thread th = e.getKey();
                    sb.append("\"").append(th.getName()).append("\"")
                      .append(" tid=").append(th.getId())
                      .append(" state=").append(th.getState())
                      .append(" daemon=").append(th.isDaemon())
                      .append(" prio=").append(th.getPriority())
                      .append("\n");
                    StackTraceElement[] st = e.getValue();
                    int limit = Math.min(st.length, 25);
                    for (int i = 0; i < limit; i++) {
                        sb.append("    at ").append(st[i].toString()).append("\n");
                    }
                    if (st.length > limit) {
                        sb.append("    ... ").append(st.length - limit).append(" more\n");
                    }
                }
                sb.append("========== [WD #").append(round).append("] End Dump ==========\n");
                System.err.print(sb);
                System.err.flush();
                if (round >= maxRounds) {
                    System.err.println("[AMCL-VULKAN-STARTUP-WATCHDOG] stopped after "
                        + round + " snapshots");
                    System.err.flush();
                    return;
                }
            }
        }, "amcl-java-watchdog");
        t.setDaemon(true);
        t.setPriority(Thread.MIN_PRIORITY);
        t.start();
        System.out.println("[AmclLauncher] Java watchdog started ("
            + (boundedVulkanStartup ? "8s, 5 snapshots" : "10s interval") + ")");
    }

    /**
     * 设置 MC 运行所需的系统属性。
     */
    private static void setupSystemProperties(LaunchConfig config) {
        // 路径属性
        if (config.gameDir != null) {
            System.setProperty("user.dir", config.gameDir);
            System.setProperty("user.home", config.gameDir);
            System.setProperty("minecraft.applet.TargetDirectory", config.gameDir);
        }

        // OS 伪装（确保一致性）
        System.setProperty("os.name", "Linux");
        System.setProperty("os.version", "5.10");

        // LWJGL 属性
        System.setProperty("org.lwjgl.glfw.checkThread0", "false");
        // ============================================================
        // REGION: amcl-allocator-runtime-set  (历史遗迹，实测可删)
        // ============================================================
        // 历史：2026-03-28 为修复 Forge 运行期 LWJGL Java/native 组合一致性，
        //       此处曾 System.setProperty("org.lwjgl.system.allocator", "system")。
        //       C 层 mc_launcher.cpp:phase_setProperties 也重复设置过同一属性。
        // 结论：2026-05-07 真机三组对照 C 组实测，**两处 setProperty 都不必要**——
        //       LWJGL 默认 allocator (rpmalloc) 在 HarmonyOS 下 Vanilla 1.20.4
        //       与 Forge 1.20.4 均可正常进世界，无黑屏 / 无崩溃。
        //       详见 @docs/archive/allocator-investigation-202605.md §4-§5。
        // 注意：-D 启动参数形式 `-Dorg.lwjgl.system.allocator=system` 仍然禁止
        //       (会触发 Render thread 黑屏)。见 jvm_launcher.cpp REGION 同名注释。
        // ============================================================
        // END REGION: amcl-allocator-runtime-set
        // ============================================================
        // LWJGL 调试默认关闭，需要时通过 -Damcl.lwjgl.debug=true 开启
        if (AmclBuildProfile.DEVELOPER_DIAGNOSTICS && Boolean.getBoolean("amcl.lwjgl.debug")) {
            System.setProperty("org.lwjgl.util.Debug", "true");
            System.setProperty("org.lwjgl.util.DebugLoader", "true");
        }

        // 安全属性
        System.setProperty("log4j2.formatMsgNoLookups", "true");

        // 网络超时（防止 Mojang 认证服务在中国网络下长时间阻塞）
        System.setProperty("sun.net.client.defaultConnectTimeout", "5000");
        System.setProperty("sun.net.client.defaultReadTimeout", "5000");

        // Forge 特有属性
        if (config.isForge) {
            System.setProperty("fml.earlyprogresswindow", "false");
            System.setProperty("forge.enableGameTest", "false");
        }

        // Fabric 特有属性
        if (config.isFabric) {
            setupFabricGameLibraries(config);
        }

        System.out.println("[AmclLauncher] System properties configured"
            + " (gameDir=" + config.gameDir + ", forge=" + config.isForge + ")");
    }

    /**
     * 把完整游戏 classpath 交给 Fabric 的库分类器（属性名 fabric.gameLibraries）。
     *
     * ┌─ 为什么需要它 ───────────────────────────────────────────────────────────┐
     * │ Fabric 的 Knot 只认 `java.class.path` 一个来源：它在自己的 init() 里逐条读   │
     * │ 该属性建内部 classPath，再交给 Minecraft 的 GameProvider 去定位游戏。       │
     * │ 而本项目**刻意**把 `java.class.path` 收窄成只有 amcl-launcher.jar，游戏 jar │
     * │ 全挂在 {@link AmclClassLoader} 上 —— 否则父加载器会抢先定义游戏类、绕过     │
     * │ terrain 兼容变换（见 mc_launcher.cpp 的 phase_initJvmWithClasspath 内注释）。│
     * │ 两个设计相撞的结果：Knot 在一个只含启动器的列表里找不到                     │
     * │ net/minecraft/client/main/Main.class，抛 "Minecraft game provider couldn't  │
     * │ locate the game!" —— Fabric 全线启动即崩，且与装了哪些模组无关（定位发生在  │
     * │ 模组发现之前）。2026-08-10 真机可玩、2026-08-26 之后必崩，成因就是这一条。  │
     * └──────────────────────────────────────────────────────────────────────────┘
     *
     * 用的是 Fabric 官方留的入口（其 SystemProperties 里 GAME_LIBRARIES 的注释原话是
     * 它「替代从 class path 的查找」）。Fabric 的库分类器在**构造时**就处理这个属性，
     * 早于它在定位阶段扫 classpath，因此 MC jar 会被认成客户端本体，定位不再失败。
     *
     * ⚠️ **刻意传完整 classpath（含 MC 本体 jar），而不是只传 MC jar 的 gameJarPath。**
     * 前者与 2026-08-10 那次真机验证可玩的启动**等价**（同一批 jar、同一顺序、进同一个
     * 分类器）；后者会让 Fabric 的 game libraries 分类变成空集，那是一个从未被任何一次
     * 真机启动验证过的状态。修回归要回到已知可用点，不要顺手换成一个更"精简"的新配置。
     *
     * 时序：本方法由 {@code prepareLaunch} 调用，早于 {@code launchPrepared} 加载游戏
     * 主类，而 Knot 是在它自己的 init() 里读该属性的 ⇒ 一定读得到。
     *
     * 幂等：将来若有人恢复完整 `java.class.path`，这条属性也不会造成重复登记 ——
     * Fabric 的分类器对每个库只记第一个来源，第二次遇到同一 jar 直接跳过。
     *
     * 不动 `java.class.path` 是本修法的核心取舍：{@code requireIsolatedGameMain} 与
     * {@code requireOwnedGameMain} 两道隔离断言、以及 terrain 变换的生效条件全部不受影响。
     */
    private static void setupFabricGameLibraries(LaunchConfig config) {
        StringBuilder joined = new StringBuilder();
        int entries = 0;
        if (config.classpath != null) {
            for (String path : config.classpath) {
                if (path == null || path.isEmpty()) continue;
                if (joined.length() > 0) joined.append(File.pathSeparatorChar);
                joined.append(path);
                entries++;
            }
        }
        if (entries == 0) {
            // 走不到这里：classpath 为空时 build() 早就失败了。真出现说明上游协议破了，
            // 此时设一个空属性会让 Fabric 把"库列表已声明但为空"当事实，比不设更糟。
            return;
        }
        System.setProperty("fabric.gameLibraries", joined.toString());
        // ⚠️ **这里刻意不打日志。** 本方法跑在 Phase 1.5（prepareJavaLaunch），而 Java 的
        // stdout 要到 Phase 4（redirectIO）才被重定向进 mc_output.log ⇒ 此刻 println
        // 不落任何文件。2026-08-29 首次真机验证就踩了这个：属性确实生效（Fabric 正常
        // 启动、加载 60 mods），但全设备 grep 不到一行 [AMCL-FABRIC]，于是"设上了"与
        // "没设上"在日志里无法区分 —— 一个看得见却永远抓不到的判据比没有判据更糟。
        // 判据改为在 launchPrepared 里**回读**，见 reportFabricGameLibraries()。
    }

    /**
     * 回读 fabric.gameLibraries 并把条目数打成一行判据。
     *
     * 刻意**回读**而不是复述设置时的入参：回读能同时否证两件事 —— 属性根本没设上、
     * 以及被后来者覆盖成了别的值。复述入参只能证明"我调用过 setProperty"，
     * 而那在真机上与"生效了"长得一模一样（AGENTS §二.3）。
     *
     * status=absent 是**有信息量的失败**：它意味着 Fabric 接下来一定会崩在
     * "couldn't locate the game"，可以据此直接跳过对 Fabric 侧的排查。
     */
    private static void reportFabricGameLibraries() {
        String value = System.getProperty("fabric.gameLibraries");
        if (value == null || value.isEmpty()) {
            System.out.println("[AMCL-FABRIC] schema=1 phase=game-libraries status=absent"
                + " entries=0 reason=" + (value == null ? "property-not-set" : "empty-value"));
            return;
        }
        int entries = 1;
        for (int i = 0; i < value.length(); i++) {
            if (value.charAt(i) == File.pathSeparatorChar) entries++;
        }
        System.out.println("[AMCL-FABRIC] schema=1 phase=game-libraries status=present"
            + " entries=" + entries + " chars=" + value.length());
    }
}
