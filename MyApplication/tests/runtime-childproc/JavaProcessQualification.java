import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.Field;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.PosixFilePermission;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.EnumSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TreeMap;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 四代 ProcessBuilder 的固定行为资格：已有绝对 run 目录、实际主版本两个参数。
 * OHOS 只执行已确认存在的 /system/bin/sh 与本类常量脚本；脚本全部使用 shell builtin，
 * 不运行任意 Want 文本，不派生孙进程。Windows 的固定 Child 类仅证明宿主路径。
 * 不设置全局 VM/环境选项，不调用父 VM 的 System.exit。每个启动、等待和 I/O join 有界；
 * Java 无法强杀卡在 native start/close 的线程，独立 NCP owner 仍必须提供最外层硬时限。
 */
public final class JavaProcessQualification {
    private static final int ROWS = 8192;
    private static final int START_MS = 8000, RUN_MS = 20000, JOIN_MS = 3000;
    private static final int MAX_CAPTURE = 4 * 1024 * 1024;
    private static final String ROW_TEXT = "|AMCL 数据 Ελληνικά العربية עברית हिन्दी ไทย 日本語 한국어 🙂|$x;\"'\\%|0123456789abcdef";
    private static final String ENV_KEY = "AMCL_PROCESS_QUALIFICATION";
    private static final String ENV_VALUE = "AMCL 固定子环境 🙂";
    private static final byte[] READY = "AMCL_PROCESS_READY_V1\n".getBytes(StandardCharsets.UTF_8);
    private static final String DATA_SCRIPT = "while IFS= read -r line; do printf '%s\\n' \"$line\" || exit 42; "
            + "printf 'ERR:%s\\n' \"$line\" >&2 || exit 43; done; exit 0";
    private static final String ENV_SCRIPT = "printf '%s\\n' \"$AMCL_PROCESS_QUALIFICATION\"; pwd -P; "
            + "printf '%s\\n' \"$AMCL_PROCESS_QUALIFICATION\" >&2";
    private static final String WAIT_SCRIPT = "printf 'AMCL_PROCESS_READY_V1\\n'; IFS= read -r line; exit 91";
    private static final String FORCE_SCRIPT = "trap '' TERM; printf 'AMCL_PROCESS_READY_V1\\n'; "
            + "while :; do IFS= read -r line || :; done";
    private final Path root;
    private final String major, platform, executable;
    private final List<Map<String, Object>> cases = new ArrayList<Map<String, Object>>();
    private final Map<String, String> originalEnv = new TreeMap<String, String>(System.getenv());
    private final String originalUserDir = System.getProperty("user.dir");
    private final List<OwnedProcess> owned = new ArrayList<OwnedProcess>();
    private FileChannel progress;
    private boolean cleanupSafe = true;

    private interface Check { void run(Map<String, Object> result) throws Exception; }

    /** JSON 不依赖第三方；报告只保存测试环境值和父环境摘要，不写父环境原值。 */
    private static String json(Object value) {
        if (value == null) return "null";
        if (value instanceof Number || value instanceof Boolean) return value.toString();
        if (value instanceof Map) {
            StringBuilder text = new StringBuilder("{");
            for (Map.Entry<?, ?> item : ((Map<?, ?>) value).entrySet()) {
                if (text.length() > 1) text.append(',');
                text.append(json(item.getKey().toString())).append(':').append(json(item.getValue()));
            }
            return text.append('}').toString();
        }
        if (value instanceof Iterable) {
            StringBuilder text = new StringBuilder("[");
            for (Object item : (Iterable<?>) value) { if (text.length() > 1) text.append(','); text.append(json(item)); }
            return text.append(']').toString();
        }
        StringBuilder text = new StringBuilder("\"");
        for (char c : value.toString().toCharArray()) {
            if (c == '\\' || c == '"') text.append('\\').append(c);
            else if (c < 32) text.append(String.format(Locale.ROOT, "\\u%04x", (int) c));
            else text.append(c);
        }
        return text.append('"').toString();
    }

    private static Map<String, Object> map() { return new LinkedHashMap<String, Object>(); }
    private static void require(boolean value, String text) { if (!value) throw new AssertionError(text); }
    private static String sha(byte[] bytes) throws Exception {
        StringBuilder out = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(bytes)) out.append(String.format(Locale.ROOT, "%02x", b & 255));
        return out.toString();
    }

    /** 新文件独占创建并 force；任何同名残留都拒绝，不能覆盖前一轮失败证据。 */
    private static void writeNew(Path path, byte[] bytes) throws IOException {
        try (FileChannel file = FileChannel.open(path, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)) {
            ByteBuffer data = ByteBuffer.wrap(bytes); while (data.hasRemaining()) file.write(data); file.force(true);
        }
    }
    private void event(String phase, String name, Map<String, Object> details) throws IOException {
        Map<String, Object> row = map(); row.put("phase", phase); row.put("case", name); row.put("nanoTime", System.nanoTime());
        row.put("details", details); ByteBuffer data = ByteBuffer.wrap((json(row) + "\n").getBytes(StandardCharsets.UTF_8));
        while (data.hasRemaining()) progress.write(data); progress.force(true);
    }

    /** 保留原异常类型/消息/有限 cause 链，不能将失败 start 改写成假退出码。 */
    private static List<Map<String, Object>> errors(Throwable failure) {
        List<Map<String, Object>> out = new ArrayList<Map<String, Object>>();
        for (int i = 0; failure != null && i < 8; i++, failure = failure.getCause()) {
            Map<String, Object> row = map(); row.put("class", failure.getClass().getName());
            String message = String.valueOf(failure.getMessage()); row.put("message", message.substring(0, Math.min(message.length(), 2048))); out.add(row);
        }
        return out;
    }

    /** 锁定17/21源码为error=%d，较新上游为error: %d (...)；精确取数，2不能误匹配20。 */
    private static int posixErrno(Throwable failure) {
        Pattern format = Pattern.compile("(?:^|[ ,])error(?:=(\\d+),|: (\\d+) \\()");
        int observed = -1;
        for (int i = 0; failure != null && i < 8; i++, failure = failure.getCause()) {
            Matcher matches = format.matcher(String.valueOf(failure.getMessage()));
            while (matches.find()) {
                int value = Integer.parseInt(matches.group(1) == null ? matches.group(2) : matches.group(1));
                require(observed == -1 || observed == value, "inconsistent native errno cause chain"); observed = value;
            }
        }
        require(observed >= 0, "unrecognized original native errno format"); return observed;
    }

    private JavaProcessQualification(Path root, String major) {
        this.root = root; this.major = major;
        String name = System.getProperty("os.name", "");
        platform = name.equals("HarmonyOS") || name.equals("OHOS") ? "ohos" : name.startsWith("Windows") ? "windows-host" : "unix-host";
        executable = platform.equals("ohos") ? "/system/bin/sh" : platform.equals("unix-host") ? "/bin/sh"
                : Paths.get(System.getProperty("java.home"), "bin", "java.exe").toString();
    }

    /** 命令选择来自内部枚举，run 路径只用于 directory 和受控输出，绝不拼接进脚本。 */
    private ProcessBuilder builder(String mode, Path cwd) throws Exception {
        List<String> command = new ArrayList<String>(); command.add(executable);
        if (platform.equals("windows-host")) {
            command.add("-cp"); command.add(Paths.get(JavaProcessQualification.class.getProtectionDomain().getCodeSource().getLocation().toURI()).toString());
            command.add(Child.class.getName()); command.add(mode);
        } else {
            String script;
            if (mode.equals("data")) script = DATA_SCRIPT;
            else if (mode.equals("env")) script = ENV_SCRIPT;
            else if (mode.equals("exit7")) script = "exit 7";
            else if (mode.equals("exit255")) script = "exit 255";
            else if (mode.equals("wait")) script = WAIT_SCRIPT;
            else if (mode.equals("force")) script = FORCE_SCRIPT;
            else if (mode.equals("zero")) script = "exit 0";
            else throw new IllegalArgumentException("unknown fixed process mode");
            command.add("-c"); command.add(script);
        }
        return new ProcessBuilder(command).directory(cwd.toFile());
    }

    /** I/O 各有单独 daemon 泵；限制累计量，成功必须 EOF、无异常且实际 join。 */
    private static final class Pump implements Runnable {
        final InputStream input; final OutputStream output; final byte[] source; final Thread thread;
        final ByteArrayOutputStream capture = new ByteArrayOutputStream();
        volatile long count; volatile boolean eof; volatile Throwable failure;
        Pump(String name, InputStream input, OutputStream output, byte[] source) {
            this.input = input; this.output = output; this.source = source;
            thread = new Thread(this, "amcl-process-" + name); thread.setDaemon(true);
        }
        public void run() {
            try {
                if (input != null) {
                    byte[] block = new byte[8192]; int got;
                    while ((got = input.read(block)) != -1) {
                        if (count + got > MAX_CAPTURE) throw new IOException("capture bound exceeded");
                        capture.write(block, 0, got); count += got;
                    }
                    eof = true;
                } else {
                    for (int at = 0; at < source.length; at += 8192) {
                        int size = Math.min(8192, source.length - at); output.write(source, at, size); count += size;
                    }
                    output.flush(); eof = true;
                }
            } catch (Throwable error) { failure = error; }
            finally {
                try { if (input != null) input.close(); else output.close(); }
                catch (Throwable error) { if (failure == null) failure = error; }
            }
        }
        boolean join() throws InterruptedException { thread.join(JOIN_MS); return !thread.isAlive(); }
    }

    /**
     * 唯一直接 child 所有者。native start 在独立 daemon 线程内有等待上限；若迟到返回，
     * 取消标志使该线程立即 kill/wait。未回收或未 join 明确 FAIL，并停止后续启动。
     */
    private final class OwnedProcess {
        final String name; final ProcessBuilder command; final Map<String, Object> result;
        volatile Process process; volatile Throwable startError; volatile boolean cancelled;
        Thread starter; Pump stdout, stderr, stdin;
        boolean waitObserved, cleaned;
        OwnedProcess(String name, ProcessBuilder command, Map<String, Object> result) {
            this.name = name; this.command = command; this.result = result; owned.add(this);
        }
        void start() throws Exception {
            final long begin = System.nanoTime();
            starter = new Thread(new Runnable() { public void run() {
                try {
                    Process value = command.start(); process = value;
                    if (cancelled) { value.destroyForcibly(); value.waitFor(JOIN_MS, TimeUnit.MILLISECONDS); }
                } catch (Throwable error) { startError = error; }
            }}, "amcl-process-start-" + name);
            starter.setDaemon(true); starter.start(); starter.join(START_MS);
            result.put("startMicros", (System.nanoTime() - begin) / 1000);
            if (starter.isAlive()) { cancelled = true; throw new IOException("native process start exceeded deadline"); }
            if (startError != null) {
                if (startError instanceof Exception) throw (Exception) startError;
                if (startError instanceof Error) throw (Error) startError;
                throw new AssertionError(startError);
            }
            require(process != null, "start returned no process");
            result.put("pid", pid(process)); result.put("commandKind", platform.equals("windows-host") ? "fixed-java-child" : "fixed-shell-builtins");
        }
        void pumps(byte[] bytes, boolean holdStdin) {
            stdout = new Pump(name + "-stdout", process.getInputStream(), null, null);
            stderr = new Pump(name + "-stderr", process.getErrorStream(), null, null);
            stdout.thread.start(); stderr.thread.start();
            if (!holdStdin) { stdin = new Pump(name + "-stdin", null, process.getOutputStream(), bytes); stdin.thread.start(); }
        }
        void waitExit(int expected) throws Exception {
            boolean complete = process.waitFor(RUN_MS, TimeUnit.MILLISECONDS); result.put("waitCompleted", complete);
            waitObserved |= complete; require(complete, "child wait deadline exceeded");
            result.put("exitCode", process.exitValue()); require(process.exitValue() == expected, "child exit mismatch");
        }
        void checkPumps() throws Exception {
            require(stdout.join() && stderr.join() && (stdin == null || stdin.join()), "I/O threads did not finish");
            require(stdout.failure == null && stderr.failure == null && (stdin == null || stdin.failure == null), "I/O pump failed");
            require(stdout.eof && stderr.eof && (stdin == null || stdin.eof), "I/O did not reach EOF/flush");
        }
        /** 回收先于关闭管道，避免活 child 持有写端造成 read 线程永远等 EOF。 */
        void cleanup() {
            if (cleaned) return; cleaned = true; cancelled = true; boolean joined = true;
            List<Map<String, Object>> failures = new ArrayList<Map<String, Object>>();
            try {
                if (process != null) {
                    if (process.isAlive()) process.destroyForcibly();
                    waitObserved |= process.waitFor(JOIN_MS, TimeUnit.MILLISECONDS);
                    if (!process.isAlive()) {
                        process.getOutputStream().close(); process.getInputStream().close(); process.getErrorStream().close();
                    }
                }
                if (starter != null) { starter.join(JOIN_MS); joined &= !starter.isAlive(); }
                // start 可能恰好在前一轮检查后返回；再核实际引用并实际 wait，而非只看取消请求。
                if (process != null) {
                    if (process.isAlive()) process.destroyForcibly();
                    waitObserved |= process.waitFor(JOIN_MS, TimeUnit.MILLISECONDS);
                    result.put("finalAlive", process.isAlive());
                    if (!process.isAlive()) result.put("finalExitCode", process.exitValue());
                }
                for (Pump pump : new Pump[]{stdout, stderr, stdin}) if (pump != null) joined &= pump.join();
            } catch (Throwable failure) { failures.addAll(errors(failure)); joined = false; }
            boolean reaped = process == null ? starter == null || !starter.isAlive() : waitObserved && !process.isAlive();
            result.put("waitObserved", waitObserved); result.put("reaped", reaped); result.put("allThreadsJoined", joined);
            result.put("cleanupErrors", failures); cleanupSafe &= reaped && joined && failures.isEmpty();
            try {
                if (stdout != null) capture("stdout", stdout);
                if (stderr != null) capture("stderr", stderr);
                if (stdin != null) { result.put("stdinWritten", stdin.count); if (stdin.failure != null) result.put("stdinError", errors(stdin.failure)); }
            } catch (Throwable failure) { result.put("evidenceError", errors(failure)); cleanupSafe = false; }
        }
        void capture(String stream, Pump pump) throws Exception {
            // 仍在运行的线程不能并发读取其缓冲，保存计数和失败即可，不能假造完成证据。
            if (pump.thread.isAlive()) { result.put(stream + "Unjoined", true); return; }
            byte[] bytes = pump.capture.toByteArray(); String file = name + "." + stream + ".bin";
            writeNew(root.resolve(file), bytes);
            Map<String, Object> proof = map(); proof.put("file", file); proof.put("bytes", bytes.length); proof.put("sha256", sha(bytes));
            proof.put("eof", pump.eof); proof.put("error", pump.failure == null ? null : errors(pump.failure)); result.put(stream, proof);
        }
    }

    /** Java 9+ 使用公开 pid；Java 8 仅诊断读取已有 pid 字段，不改变访问/启动机制。 */
    private static Object pid(Process process) {
        try { return Process.class.getMethod("pid").invoke(process); }
        catch (NoSuchMethodException oldVm) {
            try { Field field = process.getClass().getDeclaredField("pid"); field.setAccessible(true); return field.get(process); }
            catch (Throwable unavailable) { return null; }
        } catch (Throwable unavailable) { return null; }
    }

    /** 每项失败保留后继续不依赖它的项；资源未收敛时停止新增 child，交给外层 owner。 */
    private void check(String name, Check operation) throws IOException {
        Map<String, Object> result = map(); result.put("name", name); long begin = System.nanoTime();
        event("BEGIN", name, map());
        if (!cleanupSafe) { result.put("status", "NOT_RUN"); result.put("reason", "prior resource cleanup incomplete"); }
        else try { operation.run(result); result.put("status", "PASS"); }
        catch (Throwable failure) { result.put("status", "FAIL"); result.put("error", errors(failure)); }
        if (!cleanupSafe && "PASS".equals(result.get("status"))) result.put("status", "FAIL");
        result.put("elapsedMicros", (System.nanoTime() - begin) / 1000); cases.add(result); event("END", name, result);
    }

    private byte[] payload(boolean errorStream) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        for (int i = 0; i < ROWS; i++) output.write(((errorStream ? "ERR:" : "") + String.format(Locale.ROOT, "%05d", i)
                + ROW_TEXT + "\n").getBytes(StandardCharsets.UTF_8));
        return output.toByteArray();
    }
    private static void exactUtf8(byte[] actual, byte[] expected) throws Exception {
        StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(actual));
        require(Arrays.equals(actual, expected), "complete UTF-8 byte stream differs");
    }

    private void finite(String name, String mode, int code, Map<String, Object> row) throws Exception {
        OwnedProcess child = new OwnedProcess(name, builder(mode, root), row);
        try { child.start(); child.pumps(new byte[0], false); child.waitExit(code); child.checkPumps();
            exactUtf8(child.stdout.capture.toByteArray(), new byte[0]); exactUtf8(child.stderr.capture.toByteArray(), new byte[0]); }
        finally { child.cleanup(); }
    }

    private void badStart(String name, ProcessBuilder builder, int errno, Map<String, Object> row) throws Exception {
        OwnedProcess child = new OwnedProcess(name, builder, row); boolean rejected = false;
        try {
            try { child.start(); }
            catch (IOException expected) {
                // 超时是本测试产生的 IOException，不能冒充原 ProcessBuilder 返回的错误。
                require(child.startError == expected && child.process == null, "expected original start IOException");
                row.put("originalIOException", errors(expected)); row.put("expectedPosixErrno", errno);
                if (!platform.equals("windows-host")) {
                    int actual = posixErrno(expected); row.put("observedPosixErrno", actual);
                    require(actual == errno, "original native errno mismatch");
                }
                rejected = true;
            }
            require(rejected, "invalid executable/cwd unexpectedly started");
        } finally { child.cleanup(); }
    }

    private void cancel(String name, boolean force, Map<String, Object> row) throws Exception {
        OwnedProcess child = new OwnedProcess(name, builder(force ? "force" : "wait", root), row);
        try {
            child.start(); child.pumps(new byte[0], true);
            long until = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(START_MS);
            while (child.stdout.count < READY.length && child.stdout.failure == null && System.nanoTime() < until) Thread.sleep(5);
            require(child.stdout.count >= READY.length, "child ready protocol not observed");
            boolean early = child.process.waitFor(200, TimeUnit.MILLISECONDS); row.put("boundedWaitCompletedEarly", early);
            require(!early && child.process.isAlive(), "child exited before cancellation");
            row.put("cancelMethod", force ? "destroyForcibly" : "destroy");
            if (force) child.process.destroyForcibly(); else child.process.destroy();
            boolean reaped = child.process.waitFor(JOIN_MS, TimeUnit.MILLISECONDS); child.waitObserved |= reaped;
            row.put("cancelWaitCompleted", reaped); require(reaped && !child.process.isAlive(), "cancel did not reap actual child");
            row.put("exitCode", child.process.exitValue()); require(child.process.exitValue() != 0, "cancel returned ordinary success");
            child.checkPumps(); exactUtf8(child.stdout.capture.toByteArray(), READY); exactUtf8(child.stderr.capture.toByteArray(), new byte[0]);
        } finally { child.cleanup(); }
    }

    private void run() throws Exception {
        final byte[] input = payload(false), expectedError = payload(true);
        final Path cwd = Files.createDirectory(root.resolve("cwd-验证"));
        final Path denied = root.resolve("denied-exec"), notDirectory = root.resolve("cwd-file");
        writeNew(denied, "#!/system/bin/sh\nexit 0\n".getBytes(StandardCharsets.UTF_8)); writeNew(notDirectory, new byte[]{1});
        if (!platform.equals("windows-host")) Files.setPosixFilePermissions(denied, EnumSet.of(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE));
        try (FileChannel log = FileChannel.open(root.resolve("progress.jsonl"), StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)) {
            progress = log;
            check("default-selection", row -> {
                String selected = System.getProperty("jdk.lang.Process.launchMechanism"); row.put("launchMechanismProperty", selected);
                row.put("executable", executable); row.put("platform", platform);
                require(selected == null, "qualification requires unforced default launch mechanism");
                require(Files.isRegularFile(Paths.get(executable)), "fixed executable missing");
            });
            check("utf8-backpressure", row -> {
                writeNew(root.resolve("utf8-backpressure.stdin.bin"), input);
                row.put("rows", ROWS); row.put("inputBytes", input.length); row.put("inputSha256", sha(input)); row.put("expectedStderrSha256", sha(expectedError));
                OwnedProcess child = new OwnedProcess("utf8-backpressure", builder("data", root), row);
                try { child.start(); child.pumps(input, false); child.waitExit(0); child.checkPumps();
                    exactUtf8(child.stdout.capture.toByteArray(), input); exactUtf8(child.stderr.capture.toByteArray(), expectedError);
                    require(child.stdin.count == input.length, "stdin incomplete"); }
                finally { child.cleanup(); }
            });
            check("environment-cwd", row -> {
                ProcessBuilder command = builder("env", cwd); command.environment().put(ENV_KEY, ENV_VALUE);
                row.put("childEnvironment", ENV_VALUE); row.put("expectedCwd", cwd.toRealPath().toString());
                OwnedProcess child = new OwnedProcess("environment-cwd", command, row);
                try { child.start(); child.pumps(new byte[0], false); child.waitExit(0); child.checkPumps();
                    exactUtf8(child.stdout.capture.toByteArray(), (ENV_VALUE + "\n" + cwd.toRealPath() + "\n").getBytes(StandardCharsets.UTF_8));
                    exactUtf8(child.stderr.capture.toByteArray(), (ENV_VALUE + "\n").getBytes(StandardCharsets.UTF_8)); }
                finally { child.cleanup(); }
            });
            check("exit-7", row -> finite("exit-7", "exit7", 7, row));
            check("exit-255", row -> finite("exit-255", "exit255", 255, row));
            check("missing-program", row -> badStart("missing-program", new ProcessBuilder(root.resolve("missing-program").toString()).directory(root.toFile()), 2, row));
            check("denied-exec", row -> badStart("denied-exec", new ProcessBuilder(denied.toString()).directory(root.toFile()), 13, row));
            check("cwd-is-file", row -> badStart("cwd-is-file", builder("zero", notDirectory), 20, row));
            check("cwd-missing", row -> badStart("cwd-missing", builder("zero", root.resolve("missing-cwd")), 2, row));
            check("destroy", row -> cancel("destroy", false, row));
            check("destroy-forcibly", row -> cancel("destroy-forcibly", true, row));
            check("parent-unchanged", row -> {
                boolean environment = originalEnv.equals(new TreeMap<String, String>(System.getenv()));
                boolean directory = originalUserDir.equals(System.getProperty("user.dir"));
                row.put("environmentUnchanged", environment); row.put("userDirUnchanged", directory);
                row.put("environmentBeforeSha256", sha(json(originalEnv).getBytes(StandardCharsets.UTF_8)));
                row.put("environmentAfterSha256", sha(json(new TreeMap<String, String>(System.getenv())).getBytes(StandardCharsets.UTF_8)));
                require(environment && directory, "parent environment or user.dir changed");
            });
        } finally { for (OwnedProcess child : owned) child.cleanup(); }
        boolean passed = cleanupSafe; for (Map<String, Object> row : cases) passed &= "PASS".equals(row.get("status"));
        Map<String, Object> report = map(); report.put("schemaVersion", 1); report.put("protocol", "AMCL_JAVA_PROCESS_V1");
        report.put("major", major); report.put("javaVersion", System.getProperty("java.version")); report.put("osName", System.getProperty("os.name"));
        report.put("platform", platform); report.put("runDirectory", root.getParent().toString()); report.put("passed", passed);
        report.put("cleanupSafe", cleanupSafe); report.put("cases", cases);
        report.put("scope", "one Java VM; fixed direct child ProcessBuilder data, exit, error and cancel behavior; no arbitrary commands, JDK CLI exec, device matrix or performance qualification");
        byte[] bytes = (json(report) + "\n").getBytes(StandardCharsets.UTF_8); writeNew(root.resolve("result.json"), bytes);
        Map<String, Object> marker = map(); marker.put("protocol", "AMCL_JAVA_PROCESS_COMPLETE_V1"); marker.put("resultSha256", sha(bytes)); marker.put("passed", passed);
        writeNew(root.resolve("complete.json"), (json(marker) + "\n").getBytes(StandardCharsets.UTF_8));
    }

    /** 主入口返回调用者，不退出同一 VM；结果中的 passed 才是资格，完成 marker 只是结束证据。 */
    public static void main(String[] args) throws Exception {
        require(args.length == 2, "expected existingAbsoluteRunDir, major"); Path requested = Paths.get(args[0]);
        require(requested.isAbsolute() && Files.isDirectory(requested, LinkOption.NOFOLLOW_LINKS), "run directory must already exist and be absolute");
        Path run = requested.toRealPath(); require(run.equals(requested.toAbsolutePath().normalize()), "run directory must be canonical without links");
        String actual = System.getProperty("java.specification.version"); if (actual.startsWith("1.")) actual = actual.substring(2);
        require(Arrays.asList("8", "17", "21", "25").contains(args[1]) && args[1].equals(actual), "major does not match actual VM");
        new JavaProcessQualification(Files.createDirectory(run.resolve("java-process")), args[1]).run();
    }

    /** Windows 宿主固定 child。System.exit 只存在该独立进程入口，父资格 main 从不调用它。 */
    public static final class Child {
        public static void main(String[] args) throws Exception {
            require(args.length == 1, "one fixed child mode required"); String mode = args[0];
            if (mode.equals("data")) {
                java.io.BufferedReader input = new java.io.BufferedReader(new java.io.InputStreamReader(System.in, StandardCharsets.UTF_8));
                String line; while ((line = input.readLine()) != null) {
                    System.out.write((line + "\n").getBytes(StandardCharsets.UTF_8)); System.out.flush();
                    System.err.write(("ERR:" + line + "\n").getBytes(StandardCharsets.UTF_8)); System.err.flush();
                }
            } else if (mode.equals("env")) {
                String value = System.getenv(ENV_KEY); System.out.write((value + "\n" + Paths.get("").toRealPath() + "\n").getBytes(StandardCharsets.UTF_8));
                System.err.write((value + "\n").getBytes(StandardCharsets.UTF_8));
            } else if (mode.equals("exit7")) System.exit(7);
            else if (mode.equals("exit255")) System.exit(255);
            else if (mode.equals("wait") || mode.equals("force")) { System.out.write(READY); System.out.flush(); while (System.in.read() >= 0) { } }
            else if (!mode.equals("zero")) throw new IllegalArgumentException("unknown child mode");
        }
    }
}
