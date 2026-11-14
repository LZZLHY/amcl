import java.io.File;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.lang.management.ManagementFactory;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.List;
import java.util.Properties;
import java.util.Set;
import java.security.MessageDigest;

/**
 * 固定两VM只读工具资格，源码/字节码限制Java8。target/client由同一父NCP owner提供真实PID。
 * target在实际PerfData区发布nonce和递增计数；client走标准Attach及jvmstat显式PID读共享正文。
 * 不调用System.exit/halt、不发起网络或录音、不写用户世界。所有控制/结果文件在独占pair目录。
 * 内部等待有界；阻塞的native Attach由父进程现有官方Kill/两个真实退出事件作最终监督。
 */
public final class NativeTempVmQualification {
    private static final String NONCE_KEY = "amcl.native.temp.nonce";
    private static final String COUNT_KEY = "amcl.native.temp.progress";
    private static final long TARGET_NANOS = 45_000_000_000L;

    private static void require(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    /** 反射只适配锁定的四代内部包名/标准接口，绝不探测任意对象或运行外部命令。 */
    private static Object call(Class<?> api, Object receiver, String name, Class<?>[] types, Object... args)
            throws Exception {
        try { return api.getMethod(name, types).invoke(receiver, args); }
        catch (InvocationTargetException error) {
            Throwable cause = error.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            if (cause instanceof Error) throw (Error) cause;
            throw error;
        }
    }
    private static String error(Throwable error) {
        StringWriter text = new StringWriter(); error.printStackTrace(new PrintWriter(text));
        return text.toString();
    }
    /** Properties自带转义，保留Unicode/异常正文；所有一次性证据拒绝覆盖。 */
    private static void save(Path path, Properties props) throws Exception {
        try (OutputStream output = Files.newOutputStream(path, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)) {
            props.store(output, "AMCL_NATIVE_TEMP_PAIR_V1");
        }
    }
    private static Properties load(Path path) throws Exception {
        require(Files.size(path) <= 65536, "oversized fixed readiness file");
        Properties props = new Properties();
        try (InputStream input = Files.newInputStream(path)) { props.load(input); }
        return props;
    }
    private static void marker(Path path, String nonce) throws Exception {
        Files.write(path, (nonce + "\n").getBytes(StandardCharsets.UTF_8), StandardOpenOption.CREATE_NEW);
    }
    private static long pid() {
        return Long.parseLong(ManagementFactory.getRuntimeMXBean().getName().split("@")[0]);
    }
    private static Class<?> perfClass(String major) throws Exception {
        return Class.forName(major.equals("8") ? "sun.misc.Perf" : "jdk.internal.perf.Perf");
    }
    private static String nativeRoot(String major) throws Exception {
        Class<?> api = Class.forName(major.equals("8") ? "sun.misc.VMSupport" : "jdk.internal.vm.VMSupport");
        return (String) call(api, null, "getVMTemporaryDirectory", new Class<?>[0]);
    }
    /** 不通过-D强行开启三项功能；读取实际VM flag，旧包或宿主自动默认残留必须失败。 */
    private static void flags(Properties result) throws Exception {
        Class<?> api = Class.forName("com.sun.management.HotSpotDiagnosticMXBean");
        Object bean = ManagementFactory.class.getMethod("getPlatformMXBean", Class.class).invoke(null, api);
        Class<?> option = Class.forName("com.sun.management.VMOption");
        for (String key : new String[] {"UsePerfData", "PerfDisableSharedMem", "DisableAttachMechanism"}) {
            Object value = call(api, bean, "getVMOption", new Class<?>[] {String.class}, key);
            String actual = (String) call(option, value, "getValue", new Class<?>[0]);
            result.setProperty(key, actual);
            require(actual.equals(key.equals("UsePerfData") ? "true" : "false"), "effective " + key + "=" + actual);
        }
    }
    /** 找实际本PID的共享PerfData文件并读取magic；后续标准jvmstat读取nonce/计数才证明正文功能。 */
    private static Path perfFile(String root, long target, Properties result, String prefix) throws Exception {
        List<Path> matches = new ArrayList<Path>();
        File[] dirs = new File(root).listFiles();
        require(dirs != null, "native temp directory cannot be enumerated");
        for (File dir : dirs) {
            if (!dir.getName().startsWith("hsperfdata_") || !dir.isDirectory()) continue;
            Path file = dir.toPath().resolve(Long.toString(target));
            if (Files.isRegularFile(file)) matches.add(file);
        }
        require(matches.size() == 1, "expected one actual shared PerfData file for PID " + target + ": " + matches.size());
        Path file = matches.get(0).toRealPath();
        long size = Files.size(file); require(size >= 32 && size <= 16 * 1024 * 1024, "invalid PerfData file length");
        byte[] first = new byte[4]; int count = 0;
        try (InputStream input = Files.newInputStream(file)) {
            while (count < first.length) { int n = input.read(first, count, first.length - count); if (n < 0) break; count += n; }
        }
        require(count == 4, "truncated PerfData header");
        int magic = ByteBuffer.wrap(first).order(ByteOrder.BIG_ENDIAN).getInt();
        require(magic == 0xcafec0c0 || magic == 0xc0c0feca, "real PerfData magic missing");
        result.setProperty(prefix + ".path", file.toString());
        result.setProperty(prefix + ".bytes", Long.toString(size));
        result.setProperty(prefix + ".magic", Integer.toHexString(magic));
        return file;
    }
    /** /proc由本VM应用token读取；失败只按真实错误记录，不能拿HDC shell可读性代替。 */
    private static void procObservation(Properties result, String path) {
        try {
            File[] children = new File("/proc").listFiles();
            result.setProperty("proc.enumeration", children == null ? "NULL" : "READABLE");
            if (children != null) result.setProperty("proc.entryCount", Integer.toString(children.length));
            long count = 0;
            for (String line : Files.readAllLines(Paths.get("/proc/self/maps"), StandardCharsets.UTF_8))
                if (line.endsWith(path) || line.endsWith(path + " (deleted)")) ++count;
            result.setProperty("mapping.readable", "true"); result.setProperty("mapping.matches", Long.toString(count));
        } catch (Throwable failure) { result.setProperty("proc.error", error(failure)); }
    }
    /** main线程必须实际结束，non-daemon再写worker；shutdown hook验证完成顺序，不把native返回当退出。 */
    private static void completion(final Path own, final String nonce) {
        final Thread main = Thread.currentThread();
        Thread worker = new Thread(new Runnable() { public void run() {
            try {
                main.join(); require(!main.isAlive(), "main still alive");
                marker(own.resolve("main-ended.txt"), nonce); marker(own.resolve("worker.txt"), nonce);
            } catch (Throwable failure) { failure.printStackTrace(); }
        }}, "native-temp-pair-completion");
        worker.setDaemon(false); worker.start();
    }
    private static void target(Path pair, String major, String nonce, Properties result) throws Exception {
        Class<?> api = perfClass(major); Object perf = call(api, null, "getPerf", new Class<?>[0]);
        // 锁定Units.STRING=5、NONE=1，Variability.CONSTANT=1、MONOTONIC=2。
        call(api, perf, "createString", new Class<?>[] {String.class, int.class, int.class, String.class}, NONCE_KEY, 1, 5, nonce);
        ByteBuffer counter = (ByteBuffer) call(api, perf, "createLong", new Class<?>[] {String.class, int.class, int.class, long.class}, COUNT_KEY, 2, 1, 1L);
        require(counter.isDirect() && counter.capacity() >= 8, "Perf.createLong did not return live native storage");
        counter.order(ByteOrder.nativeOrder());
        perfFile(result.getProperty("nativeTmpdir"), pid(), result, "selfPerf");
        // readiness先写完整临时文件再同目录原子发布，父/client不能读到半条Properties正文。
        Path pending = pair.resolve("target-ready.pending");
        save(pending, result);
        require(!Files.exists(pair.resolve("target-ready.properties")), "readiness already exists");
        Files.move(pending, pair.resolve("target-ready.properties"), StandardCopyOption.ATOMIC_MOVE);
        final long deadline = System.nanoTime() + TARGET_NANOS; long completed = 1;
        Path stop = pair.resolve("stop-target.txt");
        while (!Files.exists(stop)) {
            require(System.nanoTime() < deadline, "target exceeded fixed45s readiness deadline");
            counter.putLong(0, ++completed); Thread.sleep(20);
        }
        require(new String(Files.readAllBytes(stop), StandardCharsets.UTF_8).equals(nonce + "\n"), "wrong parent finish token");
        result.setProperty("completedProgress", Long.toString(completed));
    }
    private static void client(Path pair, String major, String nonce, long target, Properties result) throws Exception {
        Properties ready = load(pair.resolve("target-ready.properties"));
        require(ready.getProperty("pid").equals(Long.toString(target)) && ready.getProperty("nonce").equals(nonce), "target owner readiness mismatch");
        require(result.getProperty("nativeTmpdir").equals(ready.getProperty("nativeTmpdir")), "twoVM native temporary roots differ");
        require(result.getProperty("fixtureJarSha256").equals(ready.getProperty("fixtureJarSha256")), "twoVM fixture JAR differs");
        perfFile(result.getProperty("nativeTmpdir"), pid(), result, "selfPerf");
        Path targetFile = perfFile(result.getProperty("nativeTmpdir"), target, result, "targetPerf");
        require(targetFile.toString().equals(ready.getProperty("selfPerf.path")), "target file identity path changed");
        Class<?> attach = Class.forName("com.sun.tools.attach.VirtualMachine"); Object connected = null;
        try {
            connected = call(attach, null, "attach", new Class<?>[] {String.class}, Long.toString(target));
            Properties props = (Properties) call(attach, connected, "getSystemProperties", new Class<?>[0]);
            require(nonce.equals(props.getProperty(NONCE_KEY)) && "target".equals(props.getProperty("amcl.native.temp.role")), "read-only Attach reached wrongVM");
            require(ready.getProperty("javaTmpdir").equals(props.getProperty("java.io.tmpdir")), "Attach property payload mismatch");
            result.setProperty("attach.propertiesVerified", "true");
        } finally {
            if (connected != null) { call(attach, connected, "detach", new Class<?>[0]); result.setProperty("attach.detached", "true"); }
        }
        // 即使标准发现入口在/proc.listFiles处失败，也先保留本应用token的真实/proc观察。
        procObservation(result, targetFile.toString());
        result.setProperty("discovery.defaultNativeRoot", result.getProperty("nativeTmpdir"));
        Class<?> hostApi = Class.forName("sun.jvmstat.monitor.MonitoredHost");
        Class<?> idApi = Class.forName("sun.jvmstat.monitor.VmIdentifier");
        Class<?> vmApi = Class.forName("sun.jvmstat.monitor.MonitoredVm");
        Class<?> monitorApi = Class.forName("sun.jvmstat.monitor.Monitor");
        Object id = idApi.getConstructor(String.class).newInstance("//" + target + "?mode=r");
        Object host;
        try { host = call(hostApi, null, "getMonitoredHost", new Class<?>[] {idApi}, id); }
        catch (Throwable failure) { result.setProperty("discovery.hostError", error(failure));
            if (failure instanceof Exception) throw (Exception) failure; throw new RuntimeException(failure); }
        // 发现路径独立记录：即使/proc失败，仍继续显式PID验证，最终不把发现失败吞成全通过。
        boolean discovered = false;
        try {
            Set<?> ids = (Set<?>) call(hostApi, host, "activeVms", new Class<?>[0]);
            discovered = ids.contains(Integer.valueOf((int) target));
            result.setProperty("discovery.targetListed", Boolean.toString(discovered));
            result.setProperty("discovery.vmCount", Integer.toString(ids.size()));
        } catch (Throwable failure) { result.setProperty("discovery.error", error(failure)); }
        Object vm = null;
        try {
            vm = call(hostApi, host, "getMonitoredVm", new Class<?>[] {idApi, int.class}, id, 1000);
            Object name = call(vmApi, vm, "findByName", new Class<?>[] {String.class}, NONCE_KEY);
            Object count = call(vmApi, vm, "findByName", new Class<?>[] {String.class}, COUNT_KEY);
            require(name != null && count != null, "actual shared PerfData body counters missing");
            require(nonce.equals(call(monitorApi, name, "getValue", new Class<?>[0])), "shared PerfData nonce mismatch");
            long first = ((Number) call(monitorApi, count, "getValue", new Class<?>[0])).longValue();
            long last = first; long deadline = System.nanoTime() + 3_000_000_000L;
            while (last <= first && System.nanoTime() < deadline) {
                Thread.sleep(40); last = ((Number) call(monitorApi, count, "getValue", new Class<?>[0])).longValue();
            }
            require(first > 0 && last > first, "target PerfData counter did not advance while attached");
            result.setProperty("perf.first", Long.toString(first)); result.setProperty("perf.last", Long.toString(last));
            result.setProperty("perf.bodyVerified", "true"); procObservation(result, targetFile.toString());
        } finally {
            if (vm != null) { call(hostApi, host, "detach", new Class<?>[] {vmApi}, vm); result.setProperty("perf.detachRequested", "true"); }
        }
        // 上游detach并不保证立即unmap，实际映射由Cleaner或进程退出回收；不伪造即时unmap成功。
        result.setProperty("mapping.cleanupBoundary", "both real NCP exit events plus post-exit exact file checks required");
        require(discovered, "explicitPID protocols completed but standard jvmstat discovery failed");
    }
    public static void main(String[] args) throws Exception {
        require(args.length == 7, "fixed seven arguments required");
        final String role = args[0], major = args[2], nonce = args[3];
        require(role.equals("target") || role.equals("client"), "fixed role");
        require(major.equals("8") || major.equals("17") || major.equals("21") || major.equals("25"), "fixed major");
        require(nonce.matches("[a-z0-9-]{1,32}"), "fixed nonce");
        final Path pair = Paths.get(args[1]).toRealPath(), own = pair.resolve(role);
        require(Files.isDirectory(own), "parent must pre-create role evidence directory");
        final long self = Long.parseLong(args[4]), target = Long.parseLong(args[5]);
        require(pid() == self && self > 0 && (role.equals("target") ? self == target : self != target), "actual two PID identity");
        final Properties result = new Properties();
        result.setProperty("schema", "AMCL_NATIVE_TEMP_PAIR_V1");result.setProperty("role", role);
        result.setProperty("pid", Long.toString(self));result.setProperty("targetPid", Long.toString(target));
        result.setProperty("major", major);result.setProperty("nonce", nonce);result.setProperty("passed", "false");
        Runtime.getRuntime().addShutdownHook(new Thread(new Runnable() { public void run() {
            try {
                require(Files.exists(own.resolve("worker.txt")), "non-daemon completion missing before hook");
                marker(own.resolve("shutdown.txt"), nonce);
            } catch (Throwable failure) { failure.printStackTrace(); }
        }}, "native-temp-pair-shutdown"));
        try {
            String actualVersion = System.getProperty("java.specification.version");
            require(actualVersion.equals(major.equals("8") ? "1.8" : major), "actualVM major mismatch");
            Path jar = Paths.get(NativeTempVmQualification.class.getProtectionDomain().getCodeSource().getLocation().toURI());
            require(Files.isRegularFile(jar) && Files.size(jar) <= 16 * 1024 * 1024, "fixed fixture must come from bounded JAR");
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(jar));
            StringBuilder jarHash = new StringBuilder();
            for (byte value : digest) jarHash.append(String.format("%02x", value & 255));
            result.setProperty("fixtureJarSha256", jarHash.toString());
            String root = nativeRoot(major); result.setProperty("nativeTmpdir", root);
            result.setProperty("environmentTMPDIR", String.valueOf(System.getenv("TMPDIR")));
            result.setProperty("javaTmpdir", System.getProperty("java.io.tmpdir"));
            require(root.equals(args[6]) && root.equals(System.getenv("TMPDIR")), "actual startup TMPDIR/VMSupport mismatch");
            flags(result);
            if (role.equals("target")) target(pair, major, nonce, result); else client(pair, major, nonce, target, result);
            result.setProperty("passed", "true"); marker(own.resolve("main-completed.txt"), nonce);
            completion(own, nonce);
        } catch (Throwable failure) {
            result.setProperty("error", error(failure));
            if (failure instanceof Exception) throw (Exception) failure;
            throw new RuntimeException(failure);
        } finally { save(own.resolve("java-result.properties"), result); }
    }
}
