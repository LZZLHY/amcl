package com.amcl.qa.safepoint;

import com.sun.management.HotSpotDiagnosticMXBean;
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.locks.LockSupport;

/**
 * 隔离进程使用的安全点回归夹具，不依赖Minecraft、Fabric或应用测试替身。
 *
 * 热循环线程只按自身单调时钟截止，不等待请求线程改变标志；即使坏轮询页使
 * ThreadDump/GC等待，该循环也应在约定时长后自然返回。外部运行器仍须用原生
 * 进程硬超时兜住VM本身的未知故障，Java计时器不能保证在全局安全点挂起时运行。
 *
 * 本类只报告实际执行和延时结果。hotLoop确实生成C2 nmethod的证明由外部运行器
 * 从本次LogCompilation原件核验；没有方法级编译证据，不能把执行成功叫C2通过。
 */
public final class SafepointRegression {
    private static final String PREFIX = "AMCL-SP-REGRESSION ";
    private static final String RUN_ID = UUID.randomUUID().toString();
    private static final List<GarbageCollectorMXBean> COLLECTORS =
            ManagementFactory.getGarbageCollectorMXBeans();
    private static volatile long consumedChecksum;
    private static volatile boolean stopping;
    private static volatile Case hotJob;
    private static volatile Case requestJob;

    /** 每轮独占的发布对象；volatile字段只用于发布结果，不放入被测热循环。 */
    private static final class Case {
        final int sequence;
        final boolean gc;
        final long durationNanos;
        volatile long enteredAt;
        volatile long deadline;
        volatile long exitedAt;
        volatile long requestAt;
        volatile long returnedAt;
        volatile long gcBefore = -1;
        volatile long gcAfter = -1;
        volatile int observedThreads;
        volatile boolean hotFrameObserved;
        volatile boolean requestDone;
        volatile Throwable failure;

        Case(int sequence, boolean gc, long durationNanos) {
            this.sequence = sequence;
            this.gc = gc;
            this.durationNanos = durationNanos;
        }
    }

    private SafepointRegression() {}

    /**
     * 热方法必须单独编译，运行器会加dontinline并验证其C2编译记录。
     * System.nanoTime是实际时钟读取，checksum被volatile消费，循环不会成为死代码。
     * 截止时间完全独立于其他线程，不用无限循环人为制造无法结束的负例。
     */
    private static long hotLoop(long deadline, long salt) {
        long value = salt;
        while (System.nanoTime() < deadline) {
            value = Long.rotateLeft(value ^ 0x9e3779b97f4a7c15L, 7) + 0x632be59bd9b4e019L;
            Thread.onSpinWait();
        }
        return value;
    }

    /** 热线程生命周期早于测量，避免测量期间创建线程所需的类加载干扰。 */
    private static void hotWorker() {
        int previous = 0;
        while (!stopping) {
            Case current = hotJob;
            if (current == null || current.sequence == previous) {
                LockSupport.parkNanos(100_000L);
                continue;
            }
            previous = current.sequence;
            long start = System.nanoTime();
            current.deadline = start + current.durationNanos;
            current.enteredAt = start;
            try {
                consumedChecksum ^= hotLoop(current.deadline, current.sequence);
            } catch (Throwable problem) {
                current.failure = problem;
            } finally {
                current.exitedAt = System.nanoTime();
            }
        }
    }

    /** 请求线程调用真实JDK入口；不手工释放热线程、不模拟安全点完成。 */
    private static void requestWorker() {
        int previous = 0;
        while (!stopping) {
            Case current = requestJob;
            if (current == null || current.sequence == previous) {
                LockSupport.parkNanos(100_000L);
                continue;
            }
            previous = current.sequence;
            try {
                current.gcBefore = gcCount();
                current.requestAt = System.nanoTime();
                if (current.gc) {
                    System.gc();
                } else {
                    Map<Thread, StackTraceElement[]> traces = Thread.getAllStackTraces();
                    current.observedThreads = traces.size();
                    for (Map.Entry<Thread, StackTraceElement[]> entry : traces.entrySet()) {
                        if (!entry.getKey().getName().equals("amcl-sp-hot")) continue;
                        for (StackTraceElement frame : entry.getValue()) {
                            if (frame.getClassName().equals(SafepointRegression.class.getName())
                                    && frame.getMethodName().equals("hotLoop")) {
                                current.hotFrameObserved = true;
                            }
                        }
                    }
                }
                current.returnedAt = System.nanoTime();
                current.gcAfter = gcCount();
            } catch (Throwable problem) {
                current.failure = problem;
                current.returnedAt = System.nanoTime();
            } finally {
                current.requestDone = true;
            }
        }
    }

    /** GC计数必须来自真实MXBean，拒绝把被DisableExplicitGC忽略的请求当通过。 */
    private static long gcCount() {
        long count = 0;
        for (GarbageCollectorMXBean collector : COLLECTORS) {
            long value = collector.getCollectionCount();
            if (value < 0) return -1;
            count += value;
        }
        return count;
    }

    /** 读取实际VM选项；未知或无法读取会明确保留，不能默认为期望值。 */
    private static String option(String name) {
        try {
            return ManagementFactory.getPlatformMXBean(HotSpotDiagnosticMXBean.class)
                    .getVMOption(name).getValue();
        } catch (Exception problem) {
            return "unavailable:" + problem.getClass().getSimpleName();
        }
    }

    /** 从本类实际CodeSource读取JAR摘要，不能用参数中声称的摘要冒充已运行制品。 */
    private static String ownJarSha256() {
        try {
            Path source = Path.of(SafepointRegression.class.getProtectionDomain()
                    .getCodeSource().getLocation().toURI());
            if (!Files.isRegularFile(source)) return "unavailable:not-a-jar-file";
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            try (var input = Files.newInputStream(source)) {
                byte[] buffer = new byte[8192];
                int count;
                while ((count = input.read(buffer)) >= 0) digest.update(buffer, 0, count);
            }
            return java.util.HexFormat.of().formatHex(digest.digest());
        } catch (Exception problem) {
            return "unavailable:" + problem.getClass().getSimpleName();
        }
    }

    /** 只在控制线程上有界等待；真正的进程级硬超时由外部原生运行器提供。 */
    private static void await(Case current, int stage, long budgetNanos) {
        long limit = System.nanoTime() + budgetNanos;
        while (true) {
            boolean done = stage == 0 ? current.enteredAt != 0
                    : stage == 1 ? current.requestDone : current.exitedAt != 0;
            if (done) return;
            if (System.nanoTime() > limit) {
                throw new IllegalStateException("stage_timeout:" + current.sequence + ":" + stage);
            }
            LockSupport.parkNanos(100_000L);
        }
    }

    /** 不引入JSON依赖，只序列化本夹具固定的标量字段，并正确转义异常文本。 */
    private static String quote(Object value) {
        if (value == null) return "null";
        if (value instanceof Number || value instanceof Boolean) return value.toString();
        String text = value.toString();
        StringBuilder result = new StringBuilder("\"");
        for (int i = 0; i < text.length(); i++) {
            char ch = text.charAt(i);
            if (ch == '"' || ch == '\\') result.append('\\').append(ch);
            else if (ch == '\n') result.append("\\n");
            else if (ch == '\r') result.append("\\r");
            else if (ch == '\t') result.append("\\t");
            else if (ch < 32) result.append(String.format("\\u%04x", (int) ch));
            else result.append(ch);
        }
        return result.append('"').toString();
    }

    /** 机器记录只在被测循环之外输出，不持日志锁执行ThreadDump或GC。 */
    private static synchronized void emit(String event, Object... fields) {
        StringBuilder out = new StringBuilder("{\"schema\":1,\"runId\":")
                .append(quote(RUN_ID)).append(",\"time\":").append(quote(Instant.now()))
                .append(",\"uptimeMillis\":").append(ManagementFactory.getRuntimeMXBean().getUptime())
                .append(",\"event\":").append(quote(event));
        for (int i = 0; i < fields.length; i += 2) {
            out.append(',').append(quote(fields[i])).append(':').append(quote(fields[i + 1]));
        }
        System.out.println(PREFIX + out.append('}'));
        System.out.flush();
    }

    /**
     * 参数为轮数、热循环毫秒、请求延时上限毫秒。每轮分别执行一次Dump和GC。
     * 默认8个有限热循环约16秒，硬超时不得小于本配置的总热循环时长。
     */
    public static void main(String[] args) throws Exception {
        int rounds = args.length > 0 ? Integer.parseInt(args[0]) : 4;
        int hotMillis = args.length > 1 ? Integer.parseInt(args[1]) : 2000;
        int maxLatencyMillis = args.length > 2 ? Integer.parseInt(args[2]) : 750;
        if (rounds < 1 || rounds > 8 || hotMillis < 500 || hotMillis > 5000
                || maxLatencyMillis < 100 || maxLatencyMillis * 2 >= hotMillis) {
            throw new IllegalArgumentException("invalid_bounded_configuration");
        }
        boolean explicitGcEnabled = option("DisableExplicitGC").equals("false");
        emit("start", "pid", ProcessHandle.current().pid(), "jarSha256", ownJarSha256(),
                "javaVersion", System.getProperty("java.version"),
                "javaVm", System.getProperty("java.vm.name"),
                "compiler", ManagementFactory.getCompilationMXBean() == null ? "absent"
                        : ManagementFactory.getCompilationMXBean().getName(),
                "UseCompiler", option("UseCompiler"), "TieredCompilation", option("TieredCompilation"),
                "BackgroundCompilation", option("BackgroundCompilation"),
                "DisableExplicitGC", option("DisableExplicitGC"), "rounds", rounds,
                "hotMillis", hotMillis, "maxLatencyMillis", maxLatencyMillis,
                "compilerProofRequired", true);

        // 先加载请求所需的JDK入口，预热不计为测量结果或C2证据。
        Thread.getAllStackTraces();
        gcCount();
        for (int i = 0; i < 350; i++) {
            consumedChecksum ^= hotLoop(System.nanoTime() + 1_000_000L, i);
        }
        Thread hot = new Thread(SafepointRegression::hotWorker, "amcl-sp-hot");
        Thread requester = new Thread(SafepointRegression::requestWorker, "amcl-sp-request");
        hot.setDaemon(true);
        requester.setDaemon(true);
        hot.start();
        requester.start();
        // 解释执行可作为独立对照；C2准入由外部收据另行判断，不能混进延时断言。
        boolean executionPassed = explicitGcEnabled;
        int completed = 0;
        try {
            for (int sequence = 1; sequence <= rounds * 2; sequence++) {
                Case current = new Case(sequence, (sequence & 1) == 0, hotMillis * 1_000_000L);
                emit("case_begin", "sequence", sequence, "kind", current.gc ? "gc" : "dump");
                hotJob = current;
                LockSupport.unpark(hot);
                await(current, 0, 5_000_000_000L);
                long remaining = current.deadline - System.nanoTime();
                boolean concurrentSetup = remaining > maxLatencyMillis * 2_000_000L;
                requestJob = current;
                LockSupport.unpark(requester);
                await(current, 1, (hotMillis + 6000L) * 1_000_000L);
                await(current, 2, (hotMillis + 6000L) * 1_000_000L);
                long latency = current.returnedAt - current.requestAt;
                boolean insideHotWindow = current.requestAt >= current.enteredAt
                        && current.deadline - current.requestAt > maxLatencyMillis * 2_000_000L;
                boolean resultObserved = current.gc
                        ? current.gcBefore >= 0 && current.gcAfter > current.gcBefore
                        : current.hotFrameObserved && current.observedThreads > 0;
                boolean passed = concurrentSetup && insideHotWindow && resultObserved
                        && current.failure == null && latency >= 0
                        && latency <= maxLatencyMillis * 1_000_000L;
                executionPassed &= passed;
                completed++;
                emit("case_result", "sequence", sequence, "kind", current.gc ? "gc" : "dump",
                        "executionPassed", passed, "requestLatencyNanos", latency,
                        "hotElapsedNanos", current.exitedAt - current.enteredAt,
                        "requestRemainingNanos", current.deadline - current.requestAt,
                        "requestWithinHotWindow", insideHotWindow, "concurrentSetup", concurrentSetup,
                        "hotFrameObserved", current.hotFrameObserved, "observedThreads", current.observedThreads,
                        "gcBefore", current.gcBefore, "gcAfter", current.gcAfter,
                        "failure", current.failure == null ? null : current.failure.toString());
            }
        } finally {
            stopping = true;
            LockSupport.unpark(hot);
            LockSupport.unpark(requester);
            hot.join(3000);
            requester.join(3000);
        }
        executionPassed &= !hot.isAlive() && !requester.isAlive() && completed == rounds * 2;
        emit("execution_result", "executionPassed", executionPassed, "completed", completed,
                "expected", rounds * 2, "workersStopped", !hot.isAlive() && !requester.isAlive(),
                "checksum", consumedChecksum, "compilerProofRequired", true,
                "verdictScope", "execution-only-until-external-c2-verification");
        // 嵌入JVM的main返回不等于VM关闭；必须在worker停止和终态flush之后主动
        // 结束这个独立夹具VM，让HotSpot关闭LogCompilation。此退出不能被用作
        // Minecraft保存退出或AMCL游戏生命周期已经通过的证明。
        System.exit(executionPassed ? 0 : 2);
    }
}
