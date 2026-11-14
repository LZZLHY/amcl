package com.amcl.qa;

import java.io.*;
import java.lang.instrument.Instrumentation;
import java.lang.management.ManagementFactory;
import java.nio.charset.StandardCharsets;
import javax.management.ObjectName;

/**
 * 显式启用的原生内存 QA 观察器，与五秒 Java 堆观察器配套使用。
 * 仅调用本 JVM 的只读 NMT 命令并流式保存 self smaps；不 attach、不触发 GC、
 * 不变换模组字节码，也不改变堆和渲染设置。NMT 不覆盖第三方原生库的分配，
 * smaps、NMT 和 Java 堆各有采集窗口，不能把它们相减后宣称发现了泄漏。
 */
public final class JvmNativeMemorySampler {
    private static final int MAX_SNAPSHOTS = 60;
    private static final long MAX_TOTAL_BYTES = 128L * 1024 * 1024;
    private static final long MAX_PROC_BYTES = 8L * 1024 * 1024;
    // 为本组smaps、meminfo、NMT最大UTF-8字节与index预留足量空间，避免最后一组越过总额。
    private static final long MAX_SNAPSHOT_BYTES = MAX_PROC_BYTES + 128L * 1024 + 3L * 1024 * 1024 + 16384;

    private JvmNativeMemorySampler() { }

    /** 只接受 Native 已准备的私有 TMPDIR；创建独占目录，禁止覆盖已有诊断原件。 */
    public static void premain(String arguments, Instrumentation instrumentation) {
        try {
            String temp = System.getenv("TMPDIR");
            if (temp == null) throw new IOException("missing native TMPDIR");
            File root = new File(temp);
            if (!root.isAbsolute() || !root.isDirectory()) throw new IOException("invalid TMPDIR");
            String pid = ManagementFactory.getRuntimeMXBean().getName().split("@", 2)[0];
            if (!pid.matches("[0-9]+")) throw new IOException("invalid PID");
            File folder = File.createTempFile("amcl-native-memory-" + pid + "-", "", root);
            if (!folder.delete() || !folder.mkdir()) throw new IOException("cannot create unique folder");
            System.err.println("AMCL_NATIVE_MEMORY_SAMPLER path=" + folder.getCanonicalPath());
            Thread worker = new Thread(new Runnable() {
                public void run() { sample(folder, pid); }
            }, "AMCL-native-memory-sampler");
            worker.setDaemon(true);
            worker.start();
        } catch (OutOfMemoryError exhausted) {
            // 观察器自身内存不足时退出；不尝试分配错误消息，不触发游戏全局异常处理器。
        } catch (Exception failure) {
            System.err.println("AMCL_NATIVE_MEMORY_SAMPLER unavailable=" + failure.getClass().getSimpleName());
        }
    }

    /** 每三十秒保存一组，最多60组且总量不超过128 MiB；daemon 不阻碍游戏退出。 */
    private static void sample(File folder, String pid) {
        try (FileOutputStream stream = new FileOutputStream(new File(folder, "index.jsonl"));
             Writer writer = new OutputStreamWriter(stream, StandardCharsets.UTF_8)) {
            long bytes = 0;
            for (int sequence = 0; sequence < MAX_SNAPSHOTS && bytes <= MAX_TOTAL_BYTES - MAX_SNAPSHOT_BYTES; sequence++) {
                long begin = System.currentTimeMillis();
                String prefix = String.format("%03d", sequence);
                File smaps = new File(folder, prefix + "-smaps.txt");
                String smapsStatus = copyProc("/proc/self/smaps", smaps, MAX_PROC_BYTES);
                File meminfo = new File(folder, prefix + "-meminfo.txt");
                String meminfoStatus = copyProc("/proc/meminfo", meminfo, 128L * 1024);
                File nmt = new File(folder, prefix + "-nmt.txt");
                String nmtStatus = writeNmt(nmt);
                bytes += smaps.length() + meminfo.length() + nmt.length();
                writer.write("{\"pid\":" + pid + ",\"sequence\":" + sequence
                        + ",\"beginEpochMs\":" + begin + ",\"endEpochMs\":" + System.currentTimeMillis()
                        + ",\"smaps\":" + quote(smapsStatus) + ",\"meminfo\":" + quote(meminfoStatus)
                        + ",\"nmt\":" + quote(nmtStatus) + ",\"totalBytes\":" + bytes + "}\n");
                writer.flush();
                stream.getFD().sync();
                try { Thread.sleep(30000); } catch (InterruptedException stop) { break; }
            }
        } catch (OutOfMemoryError exhausted) {
            // 同 premain：记录不完整必须由宿主识别，不能在低内存现场无限重试。
        } catch (Exception failure) {
            System.err.println("AMCL_NATIVE_MEMORY_SAMPLER stopped=" + failure.getClass().getSimpleName());
        }
    }

    /** 逐块拷贝本进程的只读 proc 文件；达到上限明确标记截断，读权限失败保留错误类型。 */
    private static String copyProc(String source, File target, long limit) {
        try (InputStream input = new FileInputStream(source);
             FileOutputStream output = new FileOutputStream(target)) {
            byte[] buffer = new byte[32768];
            long count = 0;
            int read;
            while ((read = input.read(buffer)) != -1) {
                if (count + read > limit) return "byte-budget";
                output.write(buffer, 0, read);
                count += read;
            }
            output.getFD().sync();
            return "complete";
        } catch (Exception failure) { return failure.getClass().getSimpleName(); }
    }

    /** 读取 DiagnosticCommand 的 VM.native_memory summary；未启用/未支持 NMT 也保留原文。 */
    private static String writeNmt(File target) {
        try {
            Object raw = ManagementFactory.getPlatformMBeanServer().invoke(
                    new ObjectName("com.sun.management:type=DiagnosticCommand"), "vmNativeMemory",
                    new Object[] {new String[] {"summary", "scale=KB"}},
                    new String[] {"[Ljava.lang.String;"});
            if (!(raw instanceof String)) return "invalid-result-type";
            String result = (String) raw;
            if (result.length() > 1024 * 1024) return "character-budget";
            try (FileOutputStream output = new FileOutputStream(target)) {
                output.write(result.getBytes(StandardCharsets.UTF_8));
                output.getFD().sync();
            }
            return result.contains("Native memory tracking is not enabled") ? "disabled" : "captured";
        } catch (Exception failure) { return failure.getClass().getSimpleName(); }
    }

    /** JSON 字符串仅用于状态字段，保留反斜杠与控制字符，避免破坏逐行收据。 */
    private static String quote(String value) {
        return '"' + value.replace("\\", "\\\\").replace("\"", "\\\"")
                .replace("\n", "\\n").replace("\r", "\\r") + '"';
    }
}
