import java.io.IOException;
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CancellationException;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionException;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Java8/class52的CF专项夹具。生产CF控制流没有替身；仅测试数据与调度规模固定。
 * warmup/measure使用相同同步依赖图，stress同时运行异步图、异常、取消、递归完成、
 * 竞争终态与真实分配压力。主线程每秒持久化各driver进展，外部进程所有者负责硬超时。
 * main正常返回不等于目标资格：外部还必须核对完整LogCompilation、真实CF tier与进程退出。
 */
public final class CompletableFutureQualification {
    private static final AtomicReference<Throwable> FAILURE = new AtomicReference<Throwable>();
    private static FileChannel progress;
    private static Method cpuMethod;
    private static Object osBean;

    private CompletableFutureQualification() {}

    /** driver独占写各自状态；supervisor只读volatile进展，避免每个小图争用全局原子计数器。 */
    private static final class Counter {
        volatile long completed;
        volatile long checksum;
        final byte[][] retained = new byte[8][];
        final long[] cases = new long[6];
    }

    private static final class Phase {
        String name;
        long operations, checksum, wallNanos, cpuNanos, gcBefore, gcAfter;
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    /** 不依赖实现类的反射可达性：调用已导出的管理接口；缺CPU指标明确失败，不用0冒充。 */
    private static long cpu() throws Exception {
        long result = ((Long) cpuMethod.invoke(osBean)).longValue();
        require(result >= 0, "process CPU counter unavailable");
        return result;
    }

    private static long gc() {
        long result = 0;
        for (GarbageCollectorMXBean bean : ManagementFactory.getGarbageCollectorMXBeans()) {
            if (bean.getCollectionCount() >= 0) result += bean.getCollectionCount();
        }
        return result;
    }

    /** 只有supervisor写日志；持续落盘的进展可在JVM无法进入safepoint时由外部监督者读取。 */
    private static void event(String text) throws IOException {
        String line = text + "\n";
        ByteBuffer bytes = ByteBuffer.wrap(line.getBytes(StandardCharsets.UTF_8));
        while (bytes.hasRemaining()) progress.write(bytes);
        progress.force(false);
        System.out.print(line);
        System.out.flush();
    }

    /** 同步依赖图包含outer-CF完成传播与compose/combine，不用无关hotLoop代替其编译。 */
    private static long pipeline(final int seed) {
        CompletableFuture<Integer> source = new CompletableFuture<Integer>();
        CompletableFuture<Integer> left = source.thenApply(value -> value + 1);
        CompletableFuture<Integer> right = source.thenCompose(value -> CompletableFuture.completedFuture(value * 3));
        final int[] seen = new int[1];
        CompletableFuture<Integer> result = left.thenCombine(right, (a, b) -> a + b)
                .whenComplete((value, failure) -> { require(failure == null, "pipeline failed"); ++seen[0]; });
        require(source.complete(seed) && !source.complete(seed + 9), "source completed twice");
        long actual = result.join().intValue();
        require(actual == 4L * seed + 1 && seen[0] == 1, "pipeline result/callback mismatch");
        return actual;
    }

    /** 以下六类都检查终态和值；允许竞争结果不同，但成功转换只能发生一次。 */
    private static long stress(final int seed, int kind, ExecutorService pool) throws Exception {
        if (kind == 0) {
            pipeline(seed);
        } else if (kind == 1) {
            List<CompletableFuture<Integer>> values = new ArrayList<CompletableFuture<Integer>>();
            for (int i = 0; i < 4; ++i) {
                final int index = i;
                values.add(CompletableFuture.supplyAsync(() -> seed + index, pool)
                    .thenCompose(value -> CompletableFuture.completedFuture(value * 2)));
            }
            CompletableFuture<?>[] array = values.toArray(new CompletableFuture<?>[0]);
            Object first = CompletableFuture.anyOf(array).get(10, TimeUnit.SECONDS);
            require(first instanceof Integer && ((Integer) first) >= seed * 2 &&
                    ((Integer) first) <= (seed + 3) * 2, "anyOf returned foreign value");
            CompletableFuture.allOf(array).get(10, TimeUnit.SECONDS);
            long sum = 0;
            for (CompletableFuture<Integer> value : values) sum += value.join();
            require(sum == 8L * seed + 12, "async graph sum mismatch");
        } else if (kind == 2) {
            final IllegalStateException marker = new IllegalStateException("expected-" + seed);
            CompletableFuture<Integer> source = new CompletableFuture<Integer>();
            CompletableFuture<Integer> recovered = source.thenApply(value -> value + 1)
                .handle((value, failure) -> { require(failure != null && failure.getCause() == marker,
                        "exception identity changed"); return seed + 7; });
            require(source.completeExceptionally(marker), "exception completion rejected");
            require(recovered.join() == seed + 7, "exception recovery mismatch");
            try { source.join(); throw new AssertionError("exception lost"); }
            catch (CompletionException expected) { require(expected.getCause() == marker, "root exception changed"); }
        } else if (kind == 3) {
            CompletableFuture<Integer> source = new CompletableFuture<Integer>();
            CompletableFuture<Integer> child = source.thenApply(value -> value + 1);
            CompletableFuture<Integer> recovered = child.handle((value, failure) -> {
                require(failure instanceof CompletionException && failure.getCause() instanceof CancellationException,
                        "cancel propagation mismatch"); return seed;
            });
            require(source.cancel(true) && source.isCancelled() && !source.complete(seed), "cancel terminal mismatch");
            require(recovered.join() == seed, "cancel recovery mismatch");
        } else if (kind == 4) {
            CompletableFuture<Integer> source = new CompletableFuture<Integer>();
            CompletableFuture<Integer> tail = source;
            for (int depth = 0; depth < 128; ++depth)
                tail = tail.thenCompose(value -> CompletableFuture.completedFuture(value + 1));
            // 完成一个future的回调再完成另一个future，覆盖真实递归完成而非仅构造深链。
            final CompletableFuture<Integer> nested = new CompletableFuture<Integer>();
            CompletableFuture<Void> callback = tail.thenAccept(value -> nested.complete(value + 1));
            source.complete(seed);
            callback.join();
            require(nested.join() == seed + 129, "recursive completion mismatch");
            List<CompletableFuture<Integer>> recursive = new ArrayList<CompletableFuture<Integer>>();
            List<CompletableFuture<Void>> callbacks = new ArrayList<CompletableFuture<Void>>();
            for (int depth = 0; depth <= 48; ++depth) recursive.add(new CompletableFuture<Integer>());
            for (int depth = 0; depth < 48; ++depth) {
                final CompletableFuture<Integer> next = recursive.get(depth + 1);
                callbacks.add(recursive.get(depth).thenAccept(value -> next.complete(value + 1)));
            }
            recursive.get(0).complete(seed);
            require(recursive.get(48).join() == seed + 48, "nested complete recursion mismatch");
            for (CompletableFuture<Void> completed : callbacks) completed.join();
        } else {
            final CompletableFuture<Integer> source = new CompletableFuture<Integer>();
            final IllegalStateException marker = new IllegalStateException("race-" + seed);
            final CountDownLatch gate = new CountDownLatch(1), done = new CountDownLatch(3);
            final AtomicInteger winners = new AtomicInteger(), winner = new AtomicInteger(-1), seen = new AtomicInteger();
            CompletableFuture<Integer> observed = source.whenComplete((value, failure) -> seen.incrementAndGet());
            for (int choice = 0; choice < 3; ++choice) {
                final int action = choice;
                pool.execute(() -> {
                    try {
                        gate.await();
                        boolean won = action == 0 ? source.complete(seed) : action == 1 ?
                                source.completeExceptionally(marker) : source.cancel(false);
                        if (won) { winners.incrementAndGet(); winner.set(action); }
                    } catch (Throwable error) { FAILURE.compareAndSet(null, error); }
                    finally { done.countDown(); }
                });
            }
            gate.countDown();
            require(done.await(10, TimeUnit.SECONDS) && winners.get() == 1 && seen.get() == 1, "race terminal count mismatch");
            try {
                require(observed.join() == seed && winner.get() == 0, "race value mismatch");
            } catch (CompletionException expected) {
                require((winner.get() == 1 && expected.getCause() == marker) ||
                        (winner.get() == 2 && expected.getCause() instanceof CancellationException), "race failure mismatch");
            }
        }
        return seed;
    }

    /** 固定操作数且校验闭式checksum；每128个真实完成图才发布进展，未完成工作不计数。 */
    private static Phase phase(String name, final int lanes, final int count, final boolean stressful,
                               final ExecutorService pool) throws Exception {
        final Counter[] counters = new Counter[lanes];
        final CountDownLatch start = new CountDownLatch(1), done = new CountDownLatch(lanes);
        final Thread[] drivers = new Thread[lanes];
        for (int lane = 0; lane < lanes; ++lane) {
            final int identity = lane;
            final Counter counter = counters[lane] = new Counter();
            drivers[lane] = new Thread(() -> {
                try {
                    start.await();
                    long sum = 0;
                    for (int index = 0; index < count && FAILURE.get() == null; ++index) {
                        int seed = (identity << 20) + index;
                        sum += stressful ? stress(seed, index % 6, pool) : pipeline(seed);
                        if (stressful) {
                            ++counter.cases[index % 6];
                            byte[] block = new byte[65536];
                            block[0] = (byte) index; block[block.length - 1] = (byte) (index ^ 0x5a);
                            counter.retained[index % counter.retained.length] = block;
                            require(block[block.length - 1] == (byte) (index ^ 0x5a), "pressure data corruption");
                        }
                        if ((index & 127) == 127 || index + 1 == count) counter.completed = index + 1;
                    }
                    counter.checksum = sum;
                } catch (Throwable error) { FAILURE.compareAndSet(null, error); }
                finally { done.countDown(); }
            }, "cf-driver-" + name + "-" + lane);
            drivers[lane].setDaemon(true);
            drivers[lane].start();
        }
        Phase result = new Phase(); result.name = name; result.gcBefore = gc();
        event("CF_PHASE name=" + name + " expected=" + (long) lanes * count +
            " uptimeMillis=" + ManagementFactory.getRuntimeMXBean().getUptime());
        long lastProgress = System.nanoTime(), lastCount = -1, lastReport = 0;
        long cpuStart = cpu(), begin = System.nanoTime();
        start.countDown();
        while (done.getCount() != 0) {
            long now = System.nanoTime(), total = 0;
            StringBuilder detail = new StringBuilder();
            for (Counter counter : counters) { total += counter.completed; detail.append(counter.completed).append(','); }
            if (total != lastCount) { lastCount = total; lastProgress = now; }
            if (now - lastReport >= TimeUnit.SECONDS.toNanos(1)) {
                event("CF_PROGRESS phase=" + name + " completed=" + total + " lanes=" + detail + " nanos=" + now);
                lastReport = now;
            }
            require(FAILURE.get() == null, "driver failed: " + FAILURE.get());
            require(now - lastProgress < TimeUnit.SECONDS.toNanos(15), "no completed graph for 15 seconds");
            done.await(100, TimeUnit.MILLISECONDS);
        }
        result.wallNanos = System.nanoTime() - begin; result.cpuNanos = cpu() - cpuStart; result.gcAfter = gc();
        require(FAILURE.get() == null, "driver failed: " + FAILURE.get());
        for (int lane = 0; lane < lanes; ++lane) {
            drivers[lane].join();
            Counter counter = counters[lane];
            long seeds = (long) count * (lane << 20) + (long) count * (count - 1) / 2;
            require(counter.completed == count && counter.checksum == (stressful ? seeds : 4 * seeds + count),
                    "phase count/checksum mismatch");
            if (stressful) for (int kind = 0; kind < 6; ++kind)
                require(counter.cases[kind] == (count + 5 - kind) / 6, "stress coverage mismatch");
            result.operations += counter.completed; result.checksum += counter.checksum;
        }
        event("CF_PHASE_DONE name=" + name + " completed=" + result.operations + " checksum=" + result.checksum +
            " wallNanos=" + result.wallNanos + " cpuNanos=" + result.cpuNanos + " gc=" + (result.gcAfter - result.gcBefore) +
            " uptimeMillis=" + ManagementFactory.getRuntimeMXBean().getUptime());
        return result;
    }

    /** main接口由宿主/隔离NCP同用：root arm lanes warmupPerLane measurePerLane stressPerLane。 */
    public static void main(String[] arguments) throws Exception {
        require(arguments.length == 6, "expected root arm lanes warmup measure stress");
        Path root = Paths.get(arguments[0]).toAbsolutePath();
        require(Files.isDirectory(root), "evidence root must already exist");
        String arm = arguments[1];
        require(arm.equals("broad") || arm.equals("c2-only") || arm.equals("full"), "unknown arm");
        int lanes = Integer.parseInt(arguments[2]), warm = Integer.parseInt(arguments[3]);
        int measured = Integer.parseInt(arguments[4]), stressful = Integer.parseInt(arguments[5]);
        require(lanes >= 2 && lanes <= 8 && warm >= 10000 && warm <= 1000000 && measured >= 10000 &&
                measured <= 1000000 && stressful >= 600 && stressful <= 10000, "unbounded workload");
        require(System.getProperty("java.vm.info", "").contains("mixed mode"), "mixed JIT required");
        for (String option : ManagementFactory.getRuntimeMXBean().getInputArguments())
            require(!option.equals("-Xint") && !option.startsWith("-XX:TieredStopAtLevel="), "global tier restriction");
        FAILURE.set(null);
        osBean = ManagementFactory.getOperatingSystemMXBean();
        cpuMethod = Class.forName("com.sun.management.OperatingSystemMXBean").getMethod("getProcessCpuTime");
        final AtomicInteger workerIds = new AtomicInteger();
        ExecutorService pool = Executors.newFixedThreadPool(lanes, new ThreadFactory() {
            @Override public Thread newThread(Runnable task) {
                Thread thread = new Thread(task, "cf-task-" + workerIds.incrementAndGet());
                thread.setDaemon(true); return thread;
            }
        });
        try (FileChannel channel = FileChannel.open(root.resolve("cf-progress.log"), StandardOpenOption.CREATE_NEW,
                                                    StandardOpenOption.WRITE)) {
            progress = channel;
            Path artifact = Paths.get(CompletableFutureQualification.class.getProtectionDomain().getCodeSource().getLocation().toURI());
            require(Files.isRegularFile(artifact), "qualification must run from its real JAR");
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(artifact));
            StringBuilder jarHash = new StringBuilder();
            for (byte value : digest) jarHash.append(String.format("%02x", value & 255));
            event("CF_ID arm=" + arm + " vm=" + ManagementFactory.getRuntimeMXBean().getName() +
                " version=" + System.getProperty("java.runtime.version") + " processors=" + Runtime.getRuntime().availableProcessors() +
                " jarSha256=" + jarHash);
            for (String option : ManagementFactory.getRuntimeMXBean().getInputArguments()) event("CF_ARG " + option);
            phase("warmup", lanes, warm, false, pool);
            Phase measurement = phase("measure", lanes, measured, false, pool);
            Phase stress = phase("stress", lanes, stressful, true, pool);
            require(stress.gcAfter > stress.gcBefore, "stress did not overlap a completed GC");
            pool.shutdown();
            require(pool.awaitTermination(10, TimeUnit.SECONDS), "worker pool did not terminate");
            String result = "schema=1\narm=" + arm + "\nlanes=" + lanes + "\noperations=" + measurement.operations +
                "\nchecksum=" + measurement.checksum + "\nwallNanos=" + measurement.wallNanos + "\ncpuNanos=" + measurement.cpuNanos +
                "\nstressOperations=" + stress.operations + "\nstressChecksum=" + stress.checksum +
                "\nstressGc=" + (stress.gcAfter - stress.gcBefore) + "\npassed=true\n";
            Files.write(root.resolve("cf-result.properties"), result.getBytes(StandardCharsets.UTF_8), StandardOpenOption.CREATE_NEW);
            event("CF_PASS arm=" + arm + " operations=" + measurement.operations + " stress=" + stress.operations);
        } finally {
            pool.shutdownNow();
            progress = null;
        }
    }
}
