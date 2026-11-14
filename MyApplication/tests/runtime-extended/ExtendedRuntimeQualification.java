import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.PrintStream;
import java.io.PrintWriter;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.TimeUnit;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLHandshakeException;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLServerSocket;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.TrustManager;
import javax.net.ssl.TrustManagerFactory;
import javax.net.ssl.X509TrustManager;
import javax.tools.DocumentationTool;
import javax.tools.JavaCompiler;
import javax.tools.ToolProvider;

/**
 * 四代完整 JDK 的独立扩展资格入口，源码只依赖 Java 8 API，交付 class 52。
 * 固定两参为已有绝对 run 目录、主版本；只创建其 extended-runtime 子目录，不覆盖旧证据。
 * 工具在同一 VM 中使用已核实的非退出入口；网络只连接回环，具有连接/读写/accept 时限、
 * close 和 join。编译器及 JFR 的最外层硬时限由独立进程 owner 提供，本类不伪造超时退出。
 * 每项 PASS/FAIL/NOT_SUPPORTED/NOT_RUN 单列；宿主成功不等于 OHOS 或 CLI exec 成功。
 */
public final class ExtendedRuntimeQualification {
    private static final String TEXT = "AMCL 编译与回环验证 \u2713";
    private static final String PASSWORD = "AMCL-test-only-2026";
    private static final int SOCKET_TIMEOUT_MS = 5000;
    private static volatile long cpuSink;
    private final Path root;
    private final String major;
    private final List<Map<String, Object>> cases = new ArrayList<Map<String, Object>>();
    private JavaCompiler compiler;
    private Path source, classes, serverStore, wrongStore;
    private X509Certificate serverCertificate, wrongCertificate;
    private Map<String, Object> cpuResult;

    private interface Check { Map<String, Object> run() throws Exception; }
    /** 平台/API 确实不可提供时单列，不能与实际执行报错混为同一种“跳过”。 */
    private static final class NotSupported extends Exception {
        NotSupported(String message) { super(message); }
    }
    private ExtendedRuntimeQualification(Path root, String major) { this.root = root; this.major = major; }

    /** 简单 JSON 编码不依赖外部库，保证控制字符和 Unicode 能在四代 VM 上一致保存。 */
    private static String json(Object value) {
        if (value == null) return "null";
        if (value instanceof Number || value instanceof Boolean) return value.toString();
        if (value instanceof Map) {
            StringBuilder out = new StringBuilder("{");
            for (Object item : ((Map<?, ?>) value).entrySet()) {
                Map.Entry<?, ?> entry = (Map.Entry<?, ?>) item;
                if (out.length() > 1) out.append(',');
                out.append(json(entry.getKey().toString())).append(':').append(json(entry.getValue()));
            }
            return out.append('}').toString();
        }
        if (value instanceof Iterable) {
            StringBuilder out = new StringBuilder("[");
            for (Object item : (Iterable<?>) value) { if (out.length() > 1) out.append(','); out.append(json(item)); }
            return out.append(']').toString();
        }
        StringBuilder out = new StringBuilder("\"");
        for (char c : value.toString().toCharArray()) {
            if (c == '\\' || c == '"') out.append('\\').append(c);
            else if (c < 32) out.append(String.format("\\u%04x", (int)c));
            else out.append(c);
        }
        return out.append('"').toString();
    }
    private static Map<String, Object> values(Object... pairs) {
        Map<String, Object> result = new LinkedHashMap<String, Object>();
        for (int i = 0; i < pairs.length; i += 2) result.put((String)pairs[i], pairs[i + 1]);
        return result;
    }
    private static void require(boolean value, String message) { if (!value) throw new AssertionError(message); }
    private static String digest(byte[] bytes) throws Exception {
        byte[] sum = MessageDigest.getInstance("SHA-256").digest(bytes);
        StringBuilder text = new StringBuilder();
        for (byte b : sum) text.append(String.format("%02x", b & 255));
        return text.toString();
    }
    private static byte[] readAll(InputStream input) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buffer = new byte[4096];
        for (int count; (count = input.read(buffer)) != -1;) out.write(buffer, 0, count);
        return out.toByteArray();
    }
    /** 失败之前先持久化开始记录，最后结果之外仍有定位卡住阶段的证据。 */
    private void progress(Map<String, Object> row) throws IOException {
        byte[] line = (json(row) + "\n").getBytes(StandardCharsets.UTF_8);
        try (FileOutputStream out = new FileOutputStream(root.resolve("progress.jsonl").toFile(), true)) {
            out.write(line); out.getFD().sync();
        }
        System.out.println("EXTENDED_RUNTIME " + new String(line, StandardCharsets.UTF_8).trim());
    }
    private void writeResult(String name, Object object) throws IOException {
        Files.write(root.resolve(name), (json(object) + "\n").getBytes(StandardCharsets.UTF_8), StandardOpenOption.CREATE_NEW);
    }
    /** 独立项失败后继续其它不相关项；required 控制总体资格，不能把 NOT_SUPPORTED 算 PASS。 */
    private void check(String name, boolean required, Check check) throws IOException {
        long start = System.nanoTime();
        progress(values("case", name, "stage", "start"));
        Map<String, Object> row = values("name", name, "required", required);
        try { row.put("details", check.run()); row.put("status", "PASS"); }
        catch (NotSupported unavailable) { row.put("status", "NOT_SUPPORTED"); row.put("error", unavailable.toString()); }
        catch (Throwable error) { row.put("status", "FAIL"); row.put("error", error.toString()); error.printStackTrace(System.out); }
        row.put("elapsedNanos", System.nanoTime() - start); cases.add(row); progress(row);
    }
    private void notRun(String name, String dependency) throws IOException {
        Map<String, Object> row = values("name", name, "required", true, "status", "NOT_RUN", "dependency", dependency);
        cases.add(row); progress(row);
    }
    /** 反射只用于跨代公共接口/已固定内部工具入口；真实异常原样向上返回，绝不吞掉执行失败。 */
    private static Object invoke(Method method, Object receiver, Object... args) throws Exception {
        try { return method.invoke(receiver, args); }
        catch (InvocationTargetException wrapper) {
            Throwable error = wrapper.getCause();
            if (error instanceof Exception) throw (Exception)error;
            if (error instanceof Error) throw (Error)error;
            throw new RuntimeException(error);
        }
    }

    /** 真正编译 UTF-8 Java 源码并从生成的 class 载入执行，不用工具存在性代替功能。 */
    private Map<String, Object> compile() throws Exception {
        Path tools = Files.createDirectory(root.resolve("tools"));
        Path sources = Files.createDirectory(tools.resolve("源码"));
        classes = Files.createDirectory(tools.resolve("classes"));
        source = sources.resolve("GeneratedUtf8.java");
        String code = "package amcl.ext; /** 编译文档验证。 */ public class GeneratedUtf8 { " +
            "/** 返回 UTF-8 常量。 @return 文本 */ public static String message() { return \"" + TEXT + "\"; } }\n";
        Files.write(source, code.getBytes(StandardCharsets.UTF_8), StandardOpenOption.CREATE_NEW);
        compiler = ToolProvider.getSystemJavaCompiler();
        if (compiler == null) throw new NotSupported("ToolProvider returned no JavaCompiler; complete JDK/tools.jar required");
        ByteArrayOutputStream diagnostic = new ByteArrayOutputStream();
        int status = compiler.run(null, diagnostic, diagnostic, "-encoding", "UTF-8", "-source", "8", "-target", "8",
            "-d", classes.toString(), source.toString());
        Files.write(tools.resolve("compiler.log"), diagnostic.toByteArray(), StandardOpenOption.CREATE_NEW);
        require(status == 0, "actual JavaCompiler failed: " + status);
        byte[] bytes = Files.readAllBytes(classes.resolve("amcl/ext/GeneratedUtf8.class"));
        require(bytes.length > 8 && bytes[6] == 0 && (bytes[7] & 255) == 52, "generated class is not class52");
        try (URLClassLoader loader = new URLClassLoader(new URL[] {classes.toUri().toURL()}, null)) {
            require(TEXT.equals(loader.loadClass("amcl.ext.GeneratedUtf8").getMethod("message").invoke(null)), "compiled UTF-8 result mismatch");
        }
        Files.write(classes.resolve("数据.txt"), TEXT.getBytes(StandardCharsets.UTF_8), StandardOpenOption.CREATE_NEW);
        return values("compiler", compiler.getClass().getName(), "classMajor", 52, "classSha256", digest(bytes), "returnedText", TEXT);
    }
    /** 现代 JDK 使用公开工具 SPI；8 用固定源码确认不退出进程的 Main.run，明确避开 Main.main。 */
    private Map<String, Object> jar() throws Exception {
        Path archive = root.resolve("tools/generated.jar");
        String[] args = {"cf", archive.toString(), "-C", classes.toString(), "."};
        ByteArrayOutputStream log = new ByteArrayOutputStream();
        String entry;
        if (major.equals("8")) {
            Class<?> type = Class.forName("sun.tools.jar.Main", true, compiler.getClass().getClassLoader());
            PrintStream stream = new PrintStream(log, true, "UTF-8");
            Object tool = type.getConstructor(PrintStream.class, PrintStream.class, String.class).newInstance(stream, stream, "jar");
            require(Boolean.TRUE.equals(invoke(type.getMethod("run", String[].class), tool, (Object)args)), "JDK8 jar.run returned false");
            stream.flush(); entry = "sun.tools.jar.Main.run";
        } else {
            Class<?> provider = Class.forName("java.util.spi.ToolProvider");
            Optional<?> selected = (Optional<?>)invoke(provider.getMethod("findFirst", String.class), null, "jar");
            if (!selected.isPresent()) throw new NotSupported("jar ToolProvider unavailable");
            PrintWriter writer = new PrintWriter(log, true);
            int status = ((Integer)invoke(provider.getMethod("run", PrintWriter.class, PrintWriter.class, String[].class),
                selected.get(), writer, writer, args)).intValue();
            writer.flush(); require(status == 0, "jar ToolProvider failed: " + status); entry = "java.util.spi.ToolProvider:jar";
        }
        Files.write(root.resolve("tools/jar.log"), log.toByteArray(), StandardOpenOption.CREATE_NEW);
        try (JarFile zip = new JarFile(archive.toFile())) {
            JarEntry resource = zip.getJarEntry("数据.txt"); require(resource != null, "jar lost Unicode entry");
            try (InputStream input = zip.getInputStream(resource)) { require(Arrays.equals(readAll(input), TEXT.getBytes(StandardCharsets.UTF_8)), "jar resource bytes changed"); }
            try (InputStream input = zip.getInputStream(zip.getJarEntry("amcl/ext/GeneratedUtf8.class"))) {
                require(Arrays.equals(readAll(input), Files.readAllBytes(classes.resolve("amcl/ext/GeneratedUtf8.class"))), "jar class bytes changed");
            }
        }
        try (URLClassLoader loader = new URLClassLoader(new URL[] {archive.toUri().toURL()}, null)) {
            require(TEXT.equals(loader.loadClass("amcl.ext.GeneratedUtf8").getMethod("message").invoke(null)), "jar-loaded class result mismatch");
        }
        return values("entry", entry, "archiveBytes", Files.size(archive), "archiveSha256", digest(Files.readAllBytes(archive)), "loadedFromJar", true);
    }
    /** 实际运行公共 DocumentationTool 并检查类页面内容；输出编码固定为 UTF-8。 */
    private Map<String, Object> javadoc() throws Exception {
        DocumentationTool tool = ToolProvider.getSystemDocumentationTool();
        if (tool == null) throw new NotSupported("ToolProvider returned no DocumentationTool");
        Path directory = root.resolve("tools/javadoc");
        ByteArrayOutputStream log = new ByteArrayOutputStream();
        int status = tool.run(null, log, log, "-quiet", "-encoding", "UTF-8", "-docencoding", "UTF-8", "-charset", "UTF-8",
            "-d", directory.toString(), source.toString());
        Files.write(root.resolve("tools/javadoc.log"), log.toByteArray(), StandardOpenOption.CREATE_NEW);
        require(status == 0, "actual javadoc failed: " + status);
        String html = new String(Files.readAllBytes(directory.resolve("amcl/ext/GeneratedUtf8.html")), StandardCharsets.UTF_8);
        require(html.contains("编译文档验证") && html.contains("message"), "javadoc class page missing expected content");
        return values("tool", tool.getClass().getName(), "htmlBytes", html.getBytes(StandardCharsets.UTF_8).length, "utf8Documentation", true);
    }

    /** keytool 参数完全由本测试构造。8/17/21 首参 -debug 使 run/tinyHelp 失败抛异常；
     * 25 使用公开 int run，绝不走会 System.exit 的 main。模块导出只由资格 profile 提供。 */
    private void keytool(String label, String... arguments) throws Exception {
        List<String> fixed = new ArrayList<String>(); fixed.add("-debug"); Collections.addAll(fixed, arguments);
        Class<?> type = Class.forName("sun.security.tools.keytool.Main");
        PrintStream savedOut = System.out, savedError = System.err;
        try (PrintStream log = new PrintStream(new FileOutputStream(root.resolve("security/" + label + ".log").toFile()), true, "UTF-8")) {
            System.setOut(log); System.setErr(log);
            String[] args = fixed.toArray(new String[fixed.size()]);
            if (major.equals("25")) {
                Object tool = type.getConstructor().newInstance();
                int result = ((Integer)invoke(type.getMethod("run", String[].class, PrintStream.class), tool, args, log)).intValue();
                if (result != 0) throw new IOException("keytool.run returned " + result);
            } else invoke(type.getMethod("main", String[].class), null, (Object)args);
        } finally { System.setOut(savedOut); System.setErr(savedError); }
    }
    private KeyStore loadStore(Path path) throws Exception {
        KeyStore store = KeyStore.getInstance("PKCS12");
        try (InputStream input = Files.newInputStream(path)) { store.load(input, PASSWORD.toCharArray()); }
        return store;
    }
    /** 真实 keytool 生成两个不同信任身份，并导出证书；错误口令为受控工具失败负例。 */
    private Map<String, Object> security() throws Exception {
        Path directory = Files.createDirectory(root.resolve("security"));
        serverStore = directory.resolve("loopback.p12"); wrongStore = directory.resolve("wrong-authority.p12");
        keytool("generate-loopback", "-genkeypair", "-alias", "loopback", "-keyalg", "RSA", "-keysize", "2048",
            "-sigalg", "SHA256withRSA", "-dname", "CN=localhost", "-ext", "SAN=dns:localhost,ip:127.0.0.1",
            "-startdate", "-1d", "-validity", "3", "-storetype", "PKCS12", "-keystore", serverStore.toString(),
            "-storepass", PASSWORD, "-keypass", PASSWORD, "-noprompt");
        keytool("generate-wrong", "-genkeypair", "-alias", "wrong", "-keyalg", "RSA", "-keysize", "2048",
            "-sigalg", "SHA256withRSA", "-dname", "CN=Wrong-Authority", "-startdate", "-1d", "-validity", "3",
            "-storetype", "PKCS12", "-keystore", wrongStore.toString(), "-storepass", PASSWORD, "-keypass", PASSWORD, "-noprompt");
        keytool("export-certificate", "-exportcert", "-rfc", "-alias", "loopback", "-keystore", serverStore.toString(),
            "-storepass", PASSWORD, "-file", directory.resolve("certificate.pem").toString());
        serverCertificate = (X509Certificate)loadStore(serverStore).getCertificate("loopback");
        wrongCertificate = (X509Certificate)loadStore(wrongStore).getCertificate("wrong");
        serverCertificate.checkValidity(); serverCertificate.verify(serverCertificate.getPublicKey());
        wrongCertificate.checkValidity(); wrongCertificate.verify(wrongCertificate.getPublicKey());
        // 导出返回正常还不够，必须从实际 PEM 解析并核对与 keystore 中同一份证书的字节。
        try (InputStream pem = Files.newInputStream(directory.resolve("certificate.pem"))) {
            java.security.cert.Certificate exported = java.security.cert.CertificateFactory.getInstance("X.509").generateCertificate(pem);
            require(Arrays.equals(exported.getEncoded(), serverCertificate.getEncoded()), "keytool PEM export differs from keystore certificate");
        }
        require(!Arrays.equals(serverCertificate.getEncoded(), wrongCertificate.getEncoded()), "negative trust identity is not distinct");
        String before = digest(Files.readAllBytes(serverStore)); boolean rejected = false;
        try { keytool("wrong-password", "-list", "-keystore", serverStore.toString(), "-storepass", "deliberately-wrong-password"); }
        catch (Exception expected) { rejected = true; }
        require(rejected && before.equals(digest(Files.readAllBytes(serverStore))), "wrong password did not reject or changed keystore");
        TrustManagerFactory defaults = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()); defaults.init((KeyStore)null);
        int issuerCount = 0;
        for (TrustManager manager : defaults.getTrustManagers()) if (manager instanceof X509TrustManager)
            issuerCount += ((X509TrustManager)manager).getAcceptedIssuers().length;
        require(issuerCount > 0, "default JDK trust manager has no accepted issuers");
        return values("keytoolEntry", major.equals("25") ? "Main.run" : "Main.main with -debug first",
            "certificateSha256", digest(serverCertificate.getEncoded()), "wrongCertificateSha256", digest(wrongCertificate.getEncoded()),
            "pemReadbackMatches", true, "wrongPasswordRejectedWithoutExit", true, "defaultAcceptedIssuers", issuerCount);
    }
    /** TLS 信任只来自明确的受控证书，没有 trust-all，也不修改 JDK 全局信任库或安全属性。 */
    private SSLContext serverContext() throws Exception {
        KeyManagerFactory keys = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        keys.init(loadStore(serverStore), PASSWORD.toCharArray());
        SSLContext context = SSLContext.getInstance("TLS"); context.init(keys.getKeyManagers(), null, null); return context;
    }
    private SSLContext clientContext(X509Certificate trusted) throws Exception {
        KeyStore anchors = KeyStore.getInstance("PKCS12"); anchors.load(null, null); anchors.setCertificateEntry("only-approved-anchor", trusted);
        TrustManagerFactory trust = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()); trust.init(anchors);
        SSLContext context = SSLContext.getInstance("TLS"); context.init(null, trust.getTrustManagers(), null); return context;
    }
    private static void closeSocket(Socket socket) { if (socket != null) try { socket.close(); } catch (IOException ignored) { } }
    /** 长度有界的 UTF-8 帧避免将 EOF/短读或仅建立连接误当成完整网络往返。 */
    private static byte[] receive(Socket socket) throws IOException {
        DataInputStream in = new DataInputStream(socket.getInputStream()); int length = in.readInt();
        if (length < 1 || length > 4096) throw new IOException("invalid bounded frame length " + length);
        byte[] bytes = new byte[length]; in.readFully(bytes); return bytes;
    }
    private static void send(Socket socket, byte[] bytes) throws IOException {
        DataOutputStream out = new DataOutputStream(socket.getOutputStream()); out.writeInt(bytes.length); out.write(bytes); out.flush();
    }
    /** 每次只接受一个回环连接；所有路径先关闭 listener/accepted/client，再有限 join 线程。
     * 证书负例必须是客户端握手拒绝，连接超时、重置或服务线程失败不能冒充验证成功。 */
    private Map<String, Object> exchange(final InetAddress address, final String protocol, String peerName,
                                         X509Certificate trust, boolean expectRejection) throws Exception {
        final byte[] request = TEXT.getBytes(StandardCharsets.UTF_8), response = ("ACK:" + TEXT).getBytes(StandardCharsets.UTF_8);
        final ServerSocket listener = protocol == null ? new ServerSocket() : serverContext().getServerSocketFactory().createServerSocket();
        final AtomicReference<Socket> accepted = new AtomicReference<Socket>();
        final AtomicReference<Throwable> serverFailure = new AtomicReference<Throwable>();
        Thread server = new Thread(new Runnable() { public void run() {
            try (Socket socket = listener.accept()) {
                accepted.set(socket); socket.setSoTimeout(SOCKET_TIMEOUT_MS);
                if (socket instanceof SSLSocket) ((SSLSocket)socket).startHandshake();
                require(Arrays.equals(receive(socket), request), "server received different UTF-8 payload"); send(socket, response);
            } catch (Throwable error) { serverFailure.set(error); }
        } }, "AMCL-extended-loopback");
        server.setDaemon(true);
        Socket raw = null, client = null; Throwable clientFailure = null; String cipher = "plain";
        try {
            // bind/协议配置/thread.start 也在资源保护范围内，IPv6不可用或启动失败不能漏listener。
            listener.setSoTimeout(SOCKET_TIMEOUT_MS); listener.bind(new InetSocketAddress(address, 0));
            if (listener instanceof SSLServerSocket) ((SSLServerSocket)listener).setEnabledProtocols(new String[] {protocol});
            server.start();
            raw = new Socket(); raw.connect(new InetSocketAddress(address, listener.getLocalPort()), SOCKET_TIMEOUT_MS);
            client = raw;
            if (protocol != null) {
                SSLSocket ssl = (SSLSocket)clientContext(trust).getSocketFactory().createSocket(raw, peerName, listener.getLocalPort(), true);
                client = ssl; ssl.setEnabledProtocols(new String[] {protocol});
                SSLParameters parameters = ssl.getSSLParameters(); parameters.setEndpointIdentificationAlgorithm("HTTPS"); ssl.setSSLParameters(parameters);
            }
            client.setSoTimeout(SOCKET_TIMEOUT_MS);
            if (client instanceof SSLSocket) {
                SSLSocket ssl = (SSLSocket)client; ssl.startHandshake();
                require(protocol.equals(ssl.getSession().getProtocol()), "negotiated wrong TLS protocol");
                require(Arrays.equals(ssl.getSession().getPeerCertificates()[0].getEncoded(), serverCertificate.getEncoded()), "unexpected peer certificate");
                cipher = ssl.getSession().getCipherSuite();
            }
            send(client, request); require(Arrays.equals(receive(client), response), "client response bytes differ");
        } catch (Throwable failure) { clientFailure = failure; }
        finally {
            closeSocket(client); if (raw != client) closeSocket(raw);
            try { listener.close(); }
            finally {
                closeSocket(accepted.get());
                long until = System.nanoTime() + (SOCKET_TIMEOUT_MS + 1000L) * 1000000L;
                boolean interrupted = false;
                while (server.isAlive() && System.nanoTime() < until) {
                    try { server.join(Math.max(1L, (until - System.nanoTime()) / 1000000L)); }
                    catch (InterruptedException stop) { interrupted = true; }
                }
                if (interrupted) { Thread.currentThread().interrupt(); throw new InterruptedException("interrupted while joining closed loopback server"); }
            }
        }
        require(!server.isAlive(), "loopback server did not terminate after close/deadline");
        if (expectRejection) {
            require(clientFailure instanceof SSLHandshakeException, "expected certificate handshake rejection, got " + clientFailure);
            boolean certificateCause = false;
            for (Throwable cause = clientFailure; cause != null; cause = cause.getCause())
                certificateCause |= cause instanceof java.security.cert.CertificateException ||
                    cause instanceof java.security.cert.CertPathValidatorException;
            require(certificateCause, "handshake failed without a certificate-validation cause: " + clientFailure);
        }
        else {
            if (clientFailure != null) throw new AssertionError("client exchange failed", clientFailure);
            if (serverFailure.get() != null) throw new AssertionError("server exchange failed", serverFailure.get());
        }
        return values("address", address.getHostAddress(), "protocol", protocol == null ? "TCP" : protocol, "cipher", cipher,
            "requestBytes", request.length, "responseBytes", expectRejection ? 0 : response.length,
            "certificateRejected", expectRejection, "clientError", clientFailure == null ? "" : clientFailure.toString(), "serverJoined", true);
    }

    /** 只运行固定控制程序。launchMechanism 在 VM 启动时选择，测试不会在类初始化后
     * 修改属性；default/FORK 对照必须来自两个新 VM。存在性/可执行位只作诊断，只有
     * start + 真实 wait/exit 才能通过，IOException 原样持久化，不冒充平台能力缺失。 */
    private Map<String, Object> processBuilder() throws Exception {
        Path directory = Files.createDirectory(root.resolve("process"));
        boolean ohos = Boolean.getBoolean("amcl.platform.ohos");
        boolean windows = !ohos && System.getProperty("os.name").startsWith("Windows");
        String[] command = ohos ? new String[] {"/system/bin/true"} : windows ?
            new String[] {Paths.get(System.getProperty("java.home"), "bin", "java.exe").toString(), "-version"} : new String[] {"/bin/true"};
        Map<String, Object> observation = values("command", Arrays.asList(command), "javaHome", System.getProperty("java.home"),
            "requestedLaunchMechanism", System.getProperty("jdk.lang.Process.launchMechanism", "<default>"),
            "started", false, "waitCompleted", false, "timedOut", false, "actualExitCode", null);
        Process child = null;
        long began = System.nanoTime();
        try {
            if (windows) observation.put("effectiveLaunchMechanism", "NOT_APPLICABLE_WINDOWS");
            else {
                String implementation = major.equals("8") ? "java.lang.UNIXProcess" : "java.lang.ProcessImpl";
                observation.put("processImplementation", implementation);
                try {
                    Class<?> type = Class.forName(implementation);
                    Field mechanism = type.getDeclaredField("launchMechanism"); mechanism.setAccessible(true);
                    observation.put("effectiveLaunchMechanism", mechanism.get(null).toString());
                    Field helper = type.getDeclaredField("helperpath"); helper.setAccessible(true);
                    byte[] name = (byte[])helper.get(null); int count = name.length;
                    if (count != 0 && name[count - 1] == 0) --count;
                    Path path = Paths.get(new String(name, 0, count, StandardCharsets.UTF_8));
                    observation.put("helperPath", path.toString()); observation.put("helperExists", Files.isRegularFile(path));
                    observation.put("helperExecutableBit", Files.isExecutable(path));
                } catch (Throwable diagnostic) { observation.put("mechanismReadError", diagnostic.toString()); }
            }
            ProcessBuilder builder = new ProcessBuilder(command).directory(directory.toFile());
            builder.redirectOutput(directory.resolve("stdout.log").toFile());
            builder.redirectError(directory.resolve("stderr.log").toFile());
            try { child = builder.start(); }
            catch (IOException failure) { observation.put("startIOException", failure.toString()); throw failure; }
            observation.put("started", true); observation.put("actualProcessClass", child.getClass().getName());
            child.getOutputStream().close();
            boolean completed = child.waitFor(5, TimeUnit.SECONDS);
            if (!completed) {
                observation.put("timedOut", true); child.destroyForcibly();
                completed = child.waitFor(5, TimeUnit.SECONDS);
            }
            observation.put("waitCompleted", completed);
            if (completed) observation.put("actualExitCode", child.exitValue());
            require(completed && !Boolean.TRUE.equals(observation.get("timedOut")), "fixed ProcessBuilder child exceeded deadline");
            require(child.exitValue() == 0, "fixed ProcessBuilder child exited " + child.exitValue());
            require(windows || observation.containsKey("effectiveLaunchMechanism"), "actual POSIX launchMechanism was not observable");
            return observation;
        } finally {
            try {
                if (child != null) {
                    if (child.isAlive()) child.destroyForcibly();
                    boolean interrupted = false; long until = System.nanoTime() + 5000000000L;
                    while (child.isAlive() && System.nanoTime() < until) {
                        try { child.waitFor(Math.max(1L, until - System.nanoTime()), TimeUnit.NANOSECONDS); }
                        catch (InterruptedException stop) { interrupted = true; }
                    }
                    observation.put("aliveAfterCleanup", child.isAlive());
                    try { child.getInputStream().close(); } catch (IOException ignored) { }
                    try { child.getErrorStream().close(); } catch (IOException ignored) { }
                    try { child.getOutputStream().close(); } catch (IOException ignored) { }
                    if (interrupted) Thread.currentThread().interrupt();
                    require(!child.isAlive(), "ProcessBuilder child was not reaped after forceful termination");
                }
            } finally {
                observation.put("elapsedNanos", System.nanoTime() - began);
                for (String name : new String[] {"stdout.log", "stderr.log"}) {
                    Path path = directory.resolve(name);
                    if (Files.isRegularFile(path)) {
                        long size = Files.size(path); observation.put(name + "Bytes", size);
                        if (size <= 65536) observation.put(name + "Text", new String(Files.readAllBytes(path), StandardCharsets.UTF_8));
                        else observation.put(name + "OverBound", true);
                    }
                }
                writeResult("process.json", observation);
            }
        }
    }

    /** JFR 通过反射保持 class52；调用公共 Recording/consumer API，读回真正发出的事件。 */
    private Map<String, Object> jfr() throws Exception {
        Class<?> recordingType;
        try { recordingType = Class.forName("jdk.jfr.Recording"); }
        catch (ClassNotFoundException missing) { throw new NotSupported("JFR API absent; JDK8 requires its installed jfr.jar runtime path"); }
        Class<?> settingsType = Class.forName("jdk.jfr.EventSettings");
        Class<?> fileType = Class.forName("jdk.jfr.consumer.RecordingFile");
        Class<?> eventType = Class.forName("jdk.jfr.consumer.RecordedEvent");
        Class<?> eventDescription = Class.forName("jdk.jfr.EventType");
        Class<?> threadType = Class.forName("jdk.jfr.consumer.RecordedThread");
        Object recording = recordingType.getConstructor().newInstance();
        Path recordingPath = root.resolve("recording.jfr");
        boolean cpuSupported = major.equals("25") && (Boolean.getBoolean("amcl.platform.ohos") || System.getProperty("os.name").startsWith("Linux"));
        long threadId = Thread.currentThread().getId(); String oldName = Thread.currentThread().getName();
        try {
            Object sleep = invoke(recordingType.getMethod("enable", String.class), recording, "jdk.ThreadSleep");
            invoke(settingsType.getMethod("withThreshold", Duration.class), sleep, Duration.ZERO);
            if (cpuSupported) {
                Object cpu = invoke(recordingType.getMethod("enable", String.class), recording, "jdk.CPUTimeSample");
                invoke(settingsType.getMethod("with", String.class, String.class), cpu, "throttle", "10ms");
            }
            Thread.currentThread().setName("AMCL-extended-JFR-" + major);
            invoke(recordingType.getMethod("start"), recording);
            for (int i = 0; i < 4; ++i) Thread.sleep(30);
            if (cpuSupported) {
                long until = System.nanoTime() + 1500000000L, value = 0x1234567;
                do { for (int i = 0; i < 10000; ++i) value = (value * 6364136223846793005L + i) ^ (value >>> 17); cpuSink = value; }
                while (System.nanoTime() < until);
                Thread.sleep(50); // 给队列消费者排空的机会；是否实际产生事件仍由读回证明。
            }
            require(Boolean.TRUE.equals(invoke(recordingType.getMethod("stop"), recording)), "JFR stop did not complete");
            invoke(recordingType.getMethod("dump", Path.class), recording, recordingPath);
        } finally {
            try { invoke(recordingType.getMethod("close"), recording); }
            finally { Thread.currentThread().setName(oldName); }
        }
        List<?> events = (List<?>)invoke(fileType.getMethod("readAllEvents", Path.class), null, recordingPath);
        int sleepCount = 0, cpuCount = 0, usableCpu = 0; Map<String, Object> counts = new LinkedHashMap<String, Object>();
        for (Object event : events) {
            Object description = invoke(eventType.getMethod("getEventType"), event);
            String name = (String)invoke(eventDescription.getMethod("getName"), description);
            counts.put(name, ((Number)(counts.containsKey(name) ? counts.get(name) : 0)).intValue() + 1);
            Object thread = invoke(eventType.getMethod("getThread"), event);
            boolean ours = thread != null && ((Long)invoke(threadType.getMethod("getJavaThreadId"), thread)).longValue() == threadId;
            if (name.equals("jdk.ThreadSleep") && ours) ++sleepCount;
            if (name.equals("jdk.CPUTimeSample") && ours) {
                ++cpuCount;
                boolean failed = ((Boolean)invoke(eventType.getMethod("getBoolean", String.class), event, "failed")).booleanValue();
                Object stack = invoke(eventType.getMethod("getStackTrace"), event);
                if (!failed && stack != null && !((List<?>)invoke(stack.getClass().getMethod("getFrames"), stack)).isEmpty()) ++usableCpu;
            }
        }
        writeResult("jfr-events.json", values("counts", counts, "ownThreadId", threadId, "ownSleepEvents", sleepCount,
            "ownCpuEvents", cpuCount, "usableOwnCpuEvents", usableCpu, "recordingBytes", Files.size(recordingPath)));
        require(sleepCount >= 1, "no actual own-thread ThreadSleep event was read back");
        cpuResult = values("applicable", cpuSupported, "introducedIn", 25, "ownCpuEvents", cpuCount, "usableOwnCpuEvents", usableCpu,
            "reason", major.equals("25") ? (cpuSupported ? "Linux/OHOS implementation" : "fixed JDK25 source supports Linux CPU timer sampling only") : "CPUTimeSample is introduced in JDK25");
        return values("recordingBytes", Files.size(recordingPath), "eventCount", events.size(), "ownSleepEvents", sleepCount,
            "recordingSha256", digest(Files.readAllBytes(recordingPath)));
    }

    /** 固定入口没有退出调用；结果先持久化，再对必须项失败抛异常供 owner 正常收口。 */
    public static void main(String[] args) throws Exception {
        if (args.length != 2 || !Arrays.asList("8", "17", "21", "25").contains(args[1])) throw new IllegalArgumentException("absolute run directory and exact major required");
        Path parent = Paths.get(args[0]);
        if (!parent.isAbsolute() || !Files.isDirectory(parent)) throw new IllegalArgumentException("existing absolute run directory required");
        String actual = System.getProperty("java.specification.version"); if (actual.startsWith("1.")) actual = actual.substring(2);
        require(actual.equals(args[1]), "actual Java major " + actual + " differs from " + args[1]);
        final ExtendedRuntimeQualification test = new ExtendedRuntimeQualification(Files.createDirectory(parent.resolve("extended-runtime")), args[1]);
        test.progress(values("stage", "identity", "major", actual, "javaVersion", System.getProperty("java.version"),
            "javaHome", System.getProperty("java.home"), "classPath", System.getProperty("java.class.path"), "osName", System.getProperty("os.name"), "ownerDeadlineSeconds", 180));
        test.check("compiler-utf8-load", true, new Check() { public Map<String, Object> run() throws Exception { return test.compile(); } });
        if (test.compiler != null && Files.exists(test.classes.resolve("amcl/ext/GeneratedUtf8.class")))
            test.check("jar-create-load", true, new Check() { public Map<String, Object> run() throws Exception { return test.jar(); } });
        else test.notRun("jar-create-load", "compiler-utf8-load");
        test.check("javadoc", true, new Check() { public Map<String, Object> run() throws Exception { return test.javadoc(); } });
        test.check("keytool-and-certificates", true, new Check() { public Map<String, Object> run() throws Exception { return test.security(); } });
        test.check("process-builder-fixed-command", true, new Check() { public Map<String, Object> run() throws Exception { return test.processBuilder(); } });
        final InetAddress ipv4 = InetAddress.getByAddress(new byte[] {127, 0, 0, 1});
        byte[] bytes6 = new byte[16]; bytes6[15] = 1; final InetAddress ipv6 = InetAddress.getByAddress(bytes6);
        test.check("tcp-ipv4", true, new Check() { public Map<String, Object> run() throws Exception { return test.exchange(ipv4, null, null, null, false); } });
        test.check("tcp-ipv6", true, new Check() { public Map<String, Object> run() throws Exception { return test.exchange(ipv6, null, null, null, false); } });
        if (test.serverCertificate != null && test.wrongCertificate != null) {
            for (final String protocol : new String[] {"TLSv1.2", "TLSv1.3"}) {
                test.check(protocol + "-verified", true, new Check() { public Map<String, Object> run() throws Exception { return test.exchange(ipv4, protocol, "localhost", test.serverCertificate, false); } });
            }
            test.check("tls-ipv6-verified", true, new Check() { public Map<String, Object> run() throws Exception { return test.exchange(ipv6, "TLSv1.2", "localhost", test.serverCertificate, false); } });
            test.check("tls-wrong-certificate-rejected", true, new Check() { public Map<String, Object> run() throws Exception { return test.exchange(ipv4, "TLSv1.2", "localhost", test.wrongCertificate, true); } });
            test.check("tls-wrong-hostname-rejected", true, new Check() { public Map<String, Object> run() throws Exception { return test.exchange(ipv4, "TLSv1.2", "wrong.invalid", test.serverCertificate, true); } });
        } else test.notRun("tls", "keytool-and-certificates");
        test.check("jfr-record-read", true, new Check() { public Map<String, Object> run() throws Exception { return test.jfr(); } });
        if (test.cpuResult != null) {
            final boolean applicable = Boolean.TRUE.equals(test.cpuResult.get("applicable"));
            test.check("jfr-cpu-time", applicable, new Check() { public Map<String, Object> run() throws Exception {
                if (!applicable) throw new NotSupported(test.cpuResult.get("reason").toString());
                require(((Number)test.cpuResult.get("usableOwnCpuEvents")).intValue() > 0, "no usable own-thread CPUTimeSample event"); return test.cpuResult;
            } });
        } else test.notRun("jfr-cpu-time", "jfr-record-read");
        boolean passed = true;
        for (Map<String, Object> row : test.cases) if (Boolean.TRUE.equals(row.get("required")) && !"PASS".equals(row.get("status"))) passed = false;
        List<Map<String, Object>> network = new ArrayList<Map<String, Object>>();
        for (Map<String, Object> row : test.cases) {
            String name = row.get("name").toString();
            if (name.startsWith("tcp-") || name.startsWith("tls-") || name.startsWith("TLSv")) network.add(row);
        }
        test.writeResult("network.json", values("cases", network));
        test.writeResult("result.json", values("schema", 1, "major", actual, "passed", passed, "cases", test.cases,
            "scope", "actual Java tools, loopback TCP/TLS and JFR in this VM; no CLI exec or other-platform qualification"));
        if (!passed) throw new AssertionError("extended runtime qualification failed; see persisted per-case results");
    }
}
