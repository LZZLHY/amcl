package com.amcl.launcher;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Phase C0 探针：把"字节码变换能不能搬到 java.lang.instrument"这件事的三个未知量一遍。
 *
 * <h3>⛔ 结论已取：批次 C 已证伪并归档（2026-09-05）</h3>
 *
 * <p><b>本类不是"通往 C1 的半成品"，它是一个已经交付了结论的量具。</b>
 * 三条结论（Forge + Fabric 双路线真机，施工记录 §S10）：</p>
 * <ul>
 *   <li><b>C0-1 为否</b> —— {@code helperResolved=1} 但 <b>{@code sameClassAsHost=0}</b>：
 *       {@code SecureModuleClassLoader} 与 {@code KnotClassLoader} <b>各自又定义了一份</b>
 *       {@code com.amcl.launcher.*} helper ⇒ 变换写进去的调用会链接到那一份的静态状态上，
 *       宿主那份永远是空的。按方案 §5.5 自己预设的闸门，整批停止（结案理由见 §S13）。</li>
 *   <li>C0-2 成立 —— 结构判据在 agent 看到的<b>原始</b>字节上成立（{@code amclOwnerRefs=0}）。</li>
 *   <li>C0-3 成立 —— JVM <b>确实静默吞掉</b> transformer 的异常（canary 照常定义）。</li>
 * </ul>
 *
 * <p>⚠️ <b>只保留在 default 开发产品里且默认关</b>：重启这条路时它是唯一现成的量具，
 * 而 {@code scripts/check-launch-agent-probe.mjs} 的七条纪律保证它不会悄悄变成
 * "默认开"或"开始变换字节"。<b>要往下推进 C1 之前，先读 §S13.3 —— 方向应该换，
 * 而不是接着往下走。</b></p>
 *
 * <p>方案 {@code docs/refactor/启动变换Agent化与诊断收口方案.md} §5.2。三个未知在当时都是
 * <b>C 级</b>（必须由真机回答，写下任何结论都是猜）：</p>
 * <ul>
 *   <li><b>C0-1（go/no-go 闸门）</b>：被变换的类由 FML 的 {@code TransformingClassLoader}
 *       或 Knot 定义，它能否解析 {@code com.amcl.launcher.*}？若不能，变换会**成功写入
 *       但在链接时抛 NoClassDefFoundError** —— 比不变换更糟。判据不止"能加载"，
 *       还要求**加载到的是与宿主同一份**（比对 Class 身份）。</li>
 *   <li><b>C0-2</b>：agent 看到的是 Mixin/coremod 跑完之后的字节，结构判据在那份字节上
 *       是否还成立？由 {@link TerrainCompatibilityPatcher#probeStructuralCriteria} 只读复述
 *       （判据没有第二份实现）。</li>
 *   <li><b>C0-3</b>：{@code transform()} 抛异常时 JVM 的实际处置。JPLIS 规范说异常被忽略、
 *       类以原字节定义（= 默认 fail-open），但那是规范不是本平台的实测。</li>
 * </ul>
 *
 * <h3>本类刻意不做的四件事</h3>
 * <ol>
 *   <li><b>不变换任何字节</b> —— {@code transform} 的每一条 return 都是 {@code null}。
 *       C0 只回答"看得到什么"，变换是 C2 的事（方案 §5.3 的排期纪律）。</li>
 *   <li><b>不引入 ASM</b>（方案 §7.1）：会与 Forge 模块层里的 {@code org.objectweb.asm}
 *       具体版本纠缠，那是一类全新的冲突面。</li>
 *   <li><b>不用 retransform/redefine</b>（方案 §7.2）：{@code addTransformer} 单参调用
 *       即 {@code canRetransform=false}，JVM 因此不必为目标类保留额外元数据。</li>
 *   <li><b>不默认开启</b>：premain 先看 {@code -Damcl.agentProbe=1}。ArkTS 侧
 *       {@code LaunchAgentProbe.resolveAgentProbe} 也只在该 marker 存在时才注入
 *       {@code -javaagent:} ⇒ 两道独立的门（C0-A2）。</li>
 * </ol>
 *
 * <p>⚠️ <b>输出可见性</b>：premain 跑在 JVM 启动期，那时 {@code System.out} 写的是被 OHOS
 * 丢弃的应用原始 stdout（施工记录 §S05.5）。所以 premain 的结论存下来，由
 * {@link #reportAfterRedirect()} 在 Phase 5 复述 —— 与 {@code AmclClassLoader
 * .reportPatchSetStatesAfterRedirect} 同一条既有形状。目标类的命中发生在 MC 跑起来之后
 * （已换流），那些行直接 println 即可见。</p>
 */
public final class AmclAgentProbe implements ClassFileTransformer {

    /** 开关键。**与 ArkTS 的 {@code AGENT_PROBE_ARG_KEY} 逐字对应**，由门禁静态校验两侧一致。 */
    static final String PROBE_PROP = "amcl.agentProbe";
    static final String PROBE_ON = "1";

    /**
     * 跨局保留的结论文件路径（由 ArkTS 侧连同 {@code -javaagent:} 一起下传）。
     * 空 = 没给 ⇒ 只走 stdout。键名与 {@code LaunchAgentProbe.AGENT_PROBE_LOG_ARG_KEY} 对应。
     */
    static final String PROBE_LOG_PROP = "amcl.agentProbe.log";

    private static final SimpleDateFormat TIMESTAMP =
        new SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS");

    /** C0-1 要解析的 helper。取变换实际改写成的那个调用目标，不另挑一个"代表"。 */
    static final String HELPER_CLASS = "com.amcl.launcher.TerrainRangeRetirement";

    /** C0-3 的靶子：**我们自己的类**，不碰任何游戏类。见 {@link #probeTransformThrow}。 */
    private static final String CANARY_INTERNAL = "com/amcl/launcher/AmclAgentProbe$Canary";

    /**
     * 快路径过滤用的内部名（斜杠形式）。
     *
     * <p>⭐ **从产品自己的目标表机械推出**（{@code TerrainCompatibilityPatcher} 的五组
     * 目标数组），不在这里另写一份类名清单 —— 否则探针会开始报告一个与产品不同的目标集。</p>
     */
    private static final String[] TARGETS = internalTargets();

    private static final AtomicLong SEEN = new AtomicLong();
    private static final AtomicLong MATCHED = new AtomicLong();
    private static final AtomicLong TRANSFORMED = new AtomicLong();
    private static final AtomicLong FAILED = new AtomicLong();

    /** 每个类名只探一次；每个 ClassLoader 身份只探一次 C0-1。 */
    private static final ConcurrentHashMap<String, Boolean> PROBED_CLASSES =
        new ConcurrentHashMap<String, Boolean>();
    private static final ConcurrentHashMap<String, Boolean> PROBED_LOADERS =
        new ConcurrentHashMap<String, Boolean>();

    /** premain 的结论，留到换流之后复述（premain 期的 stdout 会被 OHOS 丢弃）。 */
    private static volatile String premainLine = "";
    private static volatile boolean canaryThrowArmed = false;
    private static volatile boolean installed = false;

    private AmclAgentProbe() {}

    /** JPLIS 入口。清单属性 {@code Premain-Class} 指向本方法所在的类。 */
    public static void premain(String agentArgs, Instrumentation instrumentation) {
        try {
            String requested = System.getProperty(PROBE_PROP, "");
            if (!PROBE_ON.equals(requested)) {
                // 第二道门。走到这里说明有人手工加了 -javaagent 却没给 marker ⇒ 什么都不做，
                // 但要留痕：静默返回会让"探针没装"与"探针装了没命中"无法区分。
                premainLine = line("premain") + " status=skipped reason=marker-absent"
                    + " prop=" + PROBE_PROP + " value=" + (requested.isEmpty() ? "(absent)" : requested);
                report(premainLine);
                return;
            }
            instrumentation.addTransformer(new AmclAgentProbe());
            installed = true;
            String canary = probeTransformThrow();
            premainLine = line("premain") + " status=installed targets=" + TARGETS.length
                + " retransform=0 " + canary;
            report(premainLine);
        } catch (Throwable failure) {
            // agent 起不来绝不能拖垮启动：C0 的全部价值是"量一遍"，不是"改行为"。
            premainLine = line("premain") + " status=failed error="
                + failure.getClass().getName() + " message=" + failure.getMessage();
            report(premainLine);
        }
    }

    /**
     * 在 Phase 5（{@code System.setOut} 已指向 mc_output.log）复述 premain 的结论。
     *
     * <p>由 {@code AmclLauncher.launchPrepared} 调用。**探针没装时打一行 absent** ——
     * 那正是"默认关"这条声明的产品实际值（AGENTS §二.5：声明默认值与产品实际值是两个事实）。</p>
     */
    public static void reportAfterRedirect() {
        if (!premainLine.isEmpty()) {
            // 复述到 mc_output.log；跨局文件在 premain 时已经写过一次，不重复追加。
            System.out.println(premainLine);
        } else {
            System.out.println(line("premain") + " status=absent reason=agent-not-loaded");
        }
        System.out.println(summary("post-redirect"));
    }

    // ============================================================
    //  transformer
    // ============================================================

    /**
     * ⚠️ **每一条 return 都是 {@code null}（= 用原字节定义）。** C0 不变换，
     * 门禁 {@code scripts/check-launch-agent-probe.mjs} 会机械核对这一点。
     *
     * <p>⚠️ **显式 {@code catch (Throwable)} 是必需的，不是防御性编程**：C0-3 要量的就是
     * "transform 抛异常时 JVM 是否静默"。若结论是静默，那么不自己 catch + 计数，
     * "探针挂了"与"探针没命中"在真机上完全不可区分（本仓 {@code 1000544} 那一族）。</p>
     */
    @Override
    public byte[] transform(ClassLoader loader, String className, Class<?> beingRedefined,
                            ProtectionDomain protectionDomain, byte[] classfileBuffer) {
        SEEN.incrementAndGet();
        if (className == null) return null;
        if (canaryThrowArmed && CANARY_INTERNAL.equals(className)) {
            // C0-3：故意抛。这是本类唯一会抛出 transform 的路径，靶子是我们自己的类。
            throw new IllegalStateException("AMCL C0-3 deliberate transform failure");
        }
        // 快路径：transformer 对**每一个**类都会被调用（方案 §6 风险 4）。
        // 两次 startsWith 就能挡掉全部 JDK 与加载器自身的类。
        if (!isProbeTarget(className)) return null;
        MATCHED.incrementAndGet();
        try {
            probeTarget(loader, className, classfileBuffer);
        } catch (Throwable failure) {
            FAILED.incrementAndGet();
            report(line("target") + " class=" + className
                + " status=probe-failed error=" + failure.getClass().getName()
                + " message=" + failure.getMessage());
        }
        return null;
    }

    private static boolean isProbeTarget(String internalName) {
        if (!internalName.startsWith("com/mojang/") && !internalName.startsWith("net/minecraft/")) {
            return false;
        }
        for (int i = 0; i < TARGETS.length; i++) {
            if (TARGETS[i].equals(internalName)) return true;
        }
        return false;
    }

    private static void probeTarget(ClassLoader loader, String internalName, byte[] bytes) {
        String dotted = internalName.replace('/', '.');
        if (PROBED_CLASSES.putIfAbsent(dotted, Boolean.TRUE) != null) return;

        // C0-1：helper 在**定义这个类的加载器**下可见吗，且是不是与宿主同一份？
        String loaderKey = loaderName(loader) + "@" + System.identityHashCode(loader);
        if (PROBED_LOADERS.putIfAbsent(loaderKey, Boolean.TRUE) == null) {
            report(line("c0-1") + " class=" + dotted
                + " definingLoader=" + loaderKey + " " + probeHelperVisibility(loader));
        }

        // C0-2：结构判据在 agent 看到的这份字节上还成立吗（只读复述，判据无第二份实现）。
        report(line("c0-2") + " class=" + dotted + " bytes=" + bytes.length
            + " " + TerrainCompatibilityPatcher.probeStructuralCriteria(dotted, bytes));
        report(summary("target"));
    }

    /**
     * C0-1 的判据。**两问而不是一问**：能不能加载，以及加载到的是不是宿主那一份。
     *
     * <p>只答第一问是不够的：若加载器自己又定义了一份 {@code com.amcl.launcher.*}，
     * 变换写进去的调用会链接到那一份的静态状态上 —— 计数器、队列全都是另一套，
     * 表现是"变换生效了但行为侧计数永远是 0"，而那恰好与"变换没生效"长得一样。</p>
     */
    private static String probeHelperVisibility(ClassLoader loader) {
        try {
            Class<?> viaLoader = (loader == null)
                ? Class.forName(HELPER_CLASS, false, null)
                : loader.loadClass(HELPER_CLASS);
            boolean sameAsHost = viaLoader == TerrainRangeRetirement.class;
            return "helperResolved=1 sameClassAsHost=" + (sameAsHost ? 1 : 0)
                + " helperLoader=" + loaderName(viaLoader.getClassLoader())
                + " hostLoader=" + loaderName(TerrainRangeRetirement.class.getClassLoader());
        } catch (Throwable failure) {
            // 这就是 go/no-go 的"否"：写进去的调用会在链接时抛 NoClassDefFoundError。
            return "helperResolved=0 error=" + failure.getClass().getName()
                + " message=" + failure.getMessage();
        }
    }

    /**
     * C0-3：给自己的 canary 类抛一次 transform 异常，回读 JVM 的实际处置。
     *
     * <p>⭐ **靶子刻意是我们自己的类，不是"一个无害的 MC 类"**（方案 §5.2 原文的写法）：
     * 游戏类的加载时机因路线而异（原版在 Phase 5、模组路线在加载器起来之后），
     * 拿它当靶子会让这条探针的结论依赖"那个类这一局有没有被加载"。canary 由 premain
     * 自己触发加载，三条路线上都必然发生且时机一致。</p>
     *
     * <p>{@code defined=1} = JVM 忽略了异常并用原字节定义了类（JPLIS 规范说的 fail-open
     * 在本平台成立）⇒ C1 的 transformer **必须**自己 catch + 计数。
     * {@code defined=0} 则说明本平台会把异常传播出去，C1 的形状要另设计。</p>
     */
    private static String probeTransformThrow() {
        canaryThrowArmed = true;
        try {
            int value = Canary.value();
            return "canaryThrew=1 canaryDefined=1 canaryValue=" + value;
        } catch (Throwable failure) {
            return "canaryThrew=1 canaryDefined=0 error=" + failure.getClass().getName();
        } finally {
            canaryThrowArmed = false;
        }
    }

    /** C0-3 的靶子。只在 {@link #probeTransformThrow} 里被引用一次。 */
    static final class Canary {
        static int value() { return 42; }
    }

    // ============================================================
    //  输出
    // ============================================================

    private static String line(String phase) {
        return "[AMCL-AGENT] schema=1 phase=" + phase;
    }

    /**
     * ⭐ 每一条结论**同时**追加进一个跨局保留的文件，而不是只写 `System.out`。
     *
     * <p>⚠️ 这条是 2026-09-04 真机第一次跑探针时付的学费（施工记录 §S09.2）：
     * `mc_output.log` **每局都会被截断重写**，而 C0 的结论是"跑一次就有"的一次性事实 ——
     * 用户为了对比又启动了一次同一个版本，那一局把上一局的三条结论整个冲掉了，
     * 于是"探针跑过并得出了结论"与"探针从未装上"在设备上不可区分。</p>
     *
     * <p>⇒ 判据：**一次性探针的结论不得只写在会被下一局覆盖的文件里。**
     * 这里用追加写 + 每行带时间戳，`logs/` 目录由启动器侧保证存在（launcher log 就在那）。
     * 写失败只吞掉（探针不得影响启动），但会在 stdout 留一行说明。</p>
     */
    private static void report(String text) {
        System.out.println(text);
        String path = System.getProperty(PROBE_LOG_PROP, "");
        if (path.isEmpty()) return;   // ArkTS 没给路径（= 探针没被注入）⇒ 只走 stdout
        Writer writer = null;
        try {
            File target = new File(path);
            File parent = target.getParentFile();
            if (parent != null && !parent.isDirectory() && !parent.mkdirs()) return;
            writer = new OutputStreamWriter(new FileOutputStream(target, true), "UTF-8");
            writer.write(TIMESTAMP.format(new Date()) + " " + text + "\n");
        } catch (IOException failure) {
            System.out.println(line("probe-log") + " status=write-failed error="
                + failure.getClass().getName());
        } catch (RuntimeException failure) {
            System.out.println(line("probe-log") + " status=write-failed error="
                + failure.getClass().getName());
        } finally {
            if (writer != null) {
                try { writer.close(); } catch (IOException ignored) { /* 关不上不影响启动 */ }
            }
        }
    }

    /**
     * 计数快照。**单调增长的计数而不是一次性的就绪声明**（AGENTS §二.3）：
     * "transformer 装上了但一个目标类都没过"与"工作正常"必须长得不一样。
     */
    private static String summary(String phase) {
        return line(phase) + " installed=" + (installed ? 1 : 0)
            + " seen=" + SEEN.get() + " matched=" + MATCHED.get()
            + " transformed=" + TRANSFORMED.get() + " failed=" + FAILED.get();
    }

    private static String loaderName(ClassLoader loader) {
        return loader == null ? "(bootstrap)" : loader.getClass().getName();
    }

    private static String[] internalTargets() {
        List<String> out = new ArrayList<String>();
        addTargets(out, TerrainCompatibilityPatcher.PATCH_SET_CLASSES);
        addTargets(out, TerrainCompatibilityPatcher.WAIT_DIAGNOSTIC_CLASSES);
        addTargets(out, TerrainCompatibilityPatcher.CHUNK_QUOTA_CLASSES);
        addTargets(out, TerrainCompatibilityPatcher.UPLOAD_TIMING_CLASSES);
        addTargets(out, TerrainCompatibilityPatcher.SUBMIT_DEPTH_CLASSES);
        return out.toArray(new String[out.size()]);
    }

    private static void addTargets(List<String> out, String[] classNames) {
        for (int i = 0; i < classNames.length; i++) {
            String internal = classNames[i].replace('.', '/');
            if (!out.contains(internal)) out.add(internal);
        }
    }
}
