package com.amcl.qa;

import com.sun.management.HotSpotDiagnosticMXBean;
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.concurrent.atomic.AtomicReference;

/**
 * 四代真实VM的默认GC/普通引用布局观察与有存活对象的并发分配回归。class52只依赖Java8
 * 已有API；不修改VM选项，不触碰游戏类。必须在调用方已经选定的真实JDK/参数下执行。
 * 通过只表示这组分配/引用保持及GC行为，不代替大型整合包或紧凑对象头资格。
 */
public final class RuntimePolicyProbe {
    private static volatile byte[] allocationSink;
    private static final class Node {
        final int value;
        final Node previous;
        Node(int value, Node previous) { this.value = value; this.previous = previous; }
    }
    private static void check(boolean valid, String reason) {
        if (!valid) throw new IllegalStateException(reason);
    }
    /** Unsafe只读数组引用槽宽，不读写任意地址；被观察的是自身JDK类，非模组反射。 */
    private static int referenceWidth() throws Exception {
        Class<?> type = Class.forName("sun.misc.Unsafe");
        Field singleton = type.getDeclaredField("theUnsafe"); singleton.setAccessible(true);
        Method scale = type.getMethod("arrayIndexScale", Class.class);
        return ((Integer) scale.invoke(singleton.get(null), Object[].class)).intValue();
    }
    public static void main(String[] args) throws Exception {
        HotSpotDiagnosticMXBean options = ManagementFactory.getPlatformMXBean(HotSpotDiagnosticMXBean.class);
        boolean compressed = Boolean.parseBoolean(options.getVMOption("UseCompressedOops").getValue());
        int width = referenceWidth();
        check(width == (compressed ? 4 : 8), "VM flag/reference layout mismatch");
        final Node[] roots = new Node[4];
        final AtomicReference<Throwable> failure = new AtomicReference<Throwable>();
        Thread[] workers = new Thread[4];
        for (int index = 0; index < workers.length; index++) {
            final int slot = index;
            workers[index] = new Thread(new Runnable() {
                public void run() {
                    try {
                        Node chain = null;
                        for (int value = 0; value < 100000; value++) {
                            chain = new Node(value, chain);
                            if ((value & 1023) == 0) allocationSink = new byte[128 * 1024];
                        }
                        roots[slot] = chain;
                    } catch (Throwable error) { failure.compareAndSet(null, error); }
                }
            }, "AMCL-GC-Probe-" + index);
            workers[index].start();
        }
        // 跨工作线程真实GC，随后join建立可见性；不把只创建几个对象称为GC回归。
        System.gc();
        for (Thread worker : workers) worker.join();
        if (failure.get() != null) throw new IllegalStateException("allocation worker failed", failure.get());
        System.gc();
        for (Node root : roots) {
            Node cursor = root;
            for (int value = 99999; value >= 0; value--) {
                check(cursor != null && cursor.value == value, "live chain corrupted at " + value);
                cursor = cursor.previous;
            }
            check(cursor == null, "unexpected chain tail");
        }
        StringBuilder collectors = new StringBuilder();
        long count = 0;
        for (GarbageCollectorMXBean collector : ManagementFactory.getGarbageCollectorMXBeans()) {
            if (collectors.length() > 0) collectors.append(',');
            collectors.append(collector.getName());
            if (collector.getCollectionCount() > 0) count += collector.getCollectionCount();
        }
        check(count > 0, "no actual collection observed");
        System.out.println("AMCL_RUNTIME_POLICY_PROBE {\"passed\":true,\"java\":\"" + System.getProperty("java.version")
            + "\",\"compressedOops\":" + compressed + ",\"referenceBytes\":" + width
            + ",\"collectors\":\"" + collectors + "\",\"collections\":" + count
            + ",\"maximumHeapBytes\":" + Runtime.getRuntime().maxMemory() + ",\"retainedNodes\":400000}");
        System.exit(0);
    }
}
