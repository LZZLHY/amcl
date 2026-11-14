package com.amcl.launcher;

import java.io.*;
import java.util.*;
import static com.amcl.launcher.NativeBindingInspector.*;

/**
 * 模组首次初始化前的 zstd-JNI ABI 选择。只读已选 classpath/实例 mods 的 ZIP 中央目录和已知 Java 字节，
 * 不加载类、不解包原生库、不改mod。此入口位于launcher.prepare，不覆盖premain已提前消费的情况。
 */
public final class ZstdNativeBootstrap {
    private static final String[] PREFIXES = {"com/github/luben/zstd/", "dhcomgithubluben/zstd/"};
    private static final String RESOURCE = "zstd-bindings.properties";
    private ZstdNativeBootstrap() { }
    /** 结果只含状态和已核绑定ID，不含压缩内容或文件正文，换流后由launcher日志复述。 */
    public static final class Result {
        public final String status, profile, detail;
        public final int candidates;
        Result(String status, String profile, int candidates) { this(status, profile, candidates, ""); }
        Result(String status, String profile, int candidates, String detail) { this.status = status; this.profile = profile; this.candidates = candidates; this.detail = detail; }
        public String toString() { return "status=" + status + " profile=" + profile + " candidates=" + candidates + (detail.isEmpty() ? "" : " archive=" + detail); }
    }
    /** 用户已提供官方属性时原样保留；只有唯一完整已核 ABI 和真实 native 文件同时存在才配置。 */
    public static Result configure(String[] classpath, String gameDir, String metadataLoader) {
        if (System.getProperty("ZstdNativePath") != null) return new Result("user-path-preserved", "none", 0);
        // 一个混合JAR可声明两套不同的依赖。只看实际加载器会消费的声明，不能把另一套也当作classpath。
        if (!Arrays.asList("fabric", "forge", "none").contains(metadataLoader)) return new Result("deferred-loader-unsupported", "none", 0);
        String path = System.getProperty("amcl.zstd.native.path", "");
        File directory = new File(path);
        if (path.length() == 0 || !directory.isAbsolute() || !directory.isDirectory()
            || !artifact(directory, "libamcl_zstdjni_std.so") || !artifact(directory, "libamcl_zstdjni_dh.so"))
            return new Result("native-artifacts-unavailable", "none", 0);
        try {
            Scan scan = new Scan(loadProfiles(), metadataLoader, "ZstdNativePath");
            for (File file : archives(classpath, gameDir, scan)) {
                try { scan.file(file); }
                catch (IOException invalid) {
                    // 只记有界文件名，不泄露用户根路径；保留首个失败来源便于原包定位。
                    String name = file.getName().replaceAll("[^a-zA-Z0-9._+-]", "_");
                    if (name.length() > 120) name = name.substring(0, 120);
                    return new Result("deferred-" + safeReason(invalid.getMessage()), "none", scan.matches.size(), name);
                }
            }
            if (scan.unknown) return new Result("unknown-or-mixed-binding", "none", scan.matches.size());
            if (scan.matches.size() != 1) return new Result(scan.matches.isEmpty() ? "no-known-binding" : "multiple-bindings", "none", scan.matches.size());
            // 保留扫描期间出现的用户配置，不能覆盖迟到但明确的消费者选择。
            synchronized (System.getProperties()) {
                if (System.getProperty("ZstdNativePath") != null) return new Result("user-path-preserved", "none", scan.matches.size());
                // 只设置上游属性，Native类稍后在自己的ClassLoader中System.load，bootstrap绝不预加载。
                System.setProperty("ZstdNativePath", new File(directory, scan.matches.get(0).filename).getCanonicalPath());
            }
            return new Result("configured", scan.matches.get(0).id, 1);
        } catch (IOException invalid) { return new Result("deferred-" + safeReason(invalid.getMessage()), "none", 0); }
        catch (RuntimeException invalid) { return new Result("deferred-input-error", "none", 0); }
    }
    /** 当前HAP路径由Native冻结；SDK制品门审核摘要，此处拒绝丢失/空文件，不执行探测加载。 */
    private static boolean artifact(File directory, String name) { File file = new File(directory, name); return file.isFile() && file.length() > 0; }
    private static String safeReason(String reason) {
        if (reason != null) reason = reason.replace('_', '-');
        return reason != null && reason.matches("[a-z0-9-]{1,64}") ? reason : "invalid-archive";
    }
    /** 构建器从权威 JSON 生成 properties；运行时不再维护第二份手写 class 摘要表。 */
    private static List<Profile> loadProfiles() throws IOException {
        InputStream input = ZstdNativeBootstrap.class.getResourceAsStream(RESOURCE);
        if (input == null) throw new IOException("binding-resource-missing");
        Properties props = new Properties();
        try { props.load(new ByteArrayInputStream(read(input, 512 * 1024))); } finally { input.close(); }
        if (!"1".equals(props.getProperty("schema")) || !"zstd-jni".equals(props.getProperty("family"))) throw new IOException("binding-resource-schema");
        int count = number(props, "profile.count", 1, 16); List<Profile> result = new ArrayList<Profile>();
        Set<String> ids = new HashSet<String>();
        for (int i = 0; i < count; i++) {
            String key = "profile." + i + "."; Profile profile = new Profile();
            profile.id = props.getProperty(key + "id", "");
            profile.prefix = props.getProperty(key + "prefix", ""); profile.filename = props.getProperty(key + "filename", "");
            if (!Arrays.asList(PREFIXES).contains(profile.prefix) || !Arrays.asList("libamcl_zstdjni_std.so", "libamcl_zstdjni_dh.so").contains(profile.filename)) throw new IOException("binding-resource-provider");
            if (!profile.id.matches("[a-zA-Z0-9.-]{1,80}") || !ids.add(profile.id)) throw new IOException("binding-resource-profile");
            int classes = number(props, key + "class.count", 1, 1024);
            for (int c = 0; c < classes; c++) {
                String name = props.getProperty(key + "class." + c + ".path", "");
                String sha = props.getProperty(key + "class." + c + ".sha256", "");
                if (!name.startsWith(profile.prefix) || !name.endsWith(".class") || !sha.matches("[0-9a-f]{64}")
                    || profile.classes.put(name, sha) != null) throw new IOException("binding-resource-class");
            }
            result.add(profile);
        }
        return result;
    }
    /** 构建资源的数量也有上界，损坏资源不能导致无界分配或部分选择。 */
    private static int number(Properties props, String key, int min, int max) throws IOException {
        try { int value = Integer.parseInt(props.getProperty(key, "")); if (value < min || value > max) throw new NumberFormatException(); return value; }
        catch (NumberFormatException invalid) { throw new IOException("binding-resource-count"); }
    }
}
