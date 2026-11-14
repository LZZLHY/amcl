package com.amcl.launcher;

import java.io.*;
import java.nio.file.*;
import java.util.*;
import static com.amcl.launcher.NativeBindingInspector.*;

/**
 * 为已核验SQLite绑定补充私有native解包目录。业务数据库仍留在原实例目录；
 * 不改java.io.tmpdir、不替换模组JAR、不提前加载JNI，UUID命名与ClassLoader归属由原库负责。
 */
public final class SqliteNativeTempBootstrap {
    private static final String PREFIX = "dh_sqlite/";
    private static final String[] USER_KEYS = {"dh_sqlite.tmpdir", "dh_sqlite.lib.path", "dh_sqlite.lib.name"};
    private SqliteNativeTempBootstrap() { }

    /** 默认值只在OHOS、已发布私有TMPDIR和精确绑定同时成立时提供；包括空串在内的显式值均保留。 */
    public static String configure(String[] classpath, String gameDir, String filesDir, String metadataLoader) {
        return configure(classpath, gameDir, filesDir, metadataLoader, System.getenv("TMPDIR"));
    }

    /** 环境作为包内参数供独立进程测试；生产入口始终读取Native在CreateVM前发布的TMPDIR。 */
    static String configure(String[] classpath, String gameDir, String filesDir, String metadataLoader, String nativeTemp) {
        if (hasUserPath()) return "status=user-path-preserved";
        if (!Boolean.parseBoolean(System.getProperty("amcl.platform.ohos", "false"))) return "status=not-ohos";
        if (!Arrays.asList("fabric", "forge", "none").contains(metadataLoader)) return "status=deferred-loader-unsupported";
        try {
            File directory = privateTemp(filesDir, nativeTemp);
            if (directory == null) return "status=private-temp-unavailable";
            Profile profile = profile();
            Scan scan = new Scan(Collections.singletonList(profile), metadataLoader, null);
            for (File file : archives(classpath, gameDir, scan)) scan.file(file);
            if (scan.unknown) return "status=unknown-or-mixed-binding";
            if (scan.matches.size() != 1) return "status=" + (scan.matches.isEmpty() ? "no-known-binding" : "multiple-bindings");
            synchronized (System.getProperties()) {
                if (hasUserPath()) return "status=user-path-preserved";
                // 只设置原库支持的属性；lib.path/lib.name和OS探测均维持原状。
                System.setProperty("dh_sqlite.tmpdir", directory.getPath());
            }
            return "status=configured profile=" + profile.id;
        } catch (IOException failure) {
            // 有界状态即可定位策略失败，不将用户路径或归档正文写入日志。
            return "status=deferred-archive-or-directory-error";
        } catch (RuntimeException failure) { return "status=deferred-input-error"; }
    }

    private static boolean hasUserPath() {
        for (String key : USER_KEYS) if (System.getProperty(key) != null) return true;
        return false;
    }

    /**
     * 拒绝公共目录回退、任意继承环境和符号链接。这里不创建或chmod目录；
     * Native的PreparedNativeTempRoot负责权限与生命周期，Java只复核本次可信filesDir/tmp身份。
     * 旧JDK未发布该目录时保持原加载路径，不把旧系统TMPDIR误认为可用的私有目录。
     */
    private static File privateTemp(String filesDir, String value) throws IOException {
        if (filesDir == null || filesDir.isEmpty() || value == null || value.isEmpty()) return null;
        File root = new File(filesDir), actual = new File(value);
        if (!root.isAbsolute() || !actual.isAbsolute()) return null;
        File expected = new File(root, "tmp");
        if (!expected.getCanonicalFile().equals(actual.getCanonicalFile())) return null;
        for (Path at = actual.toPath(); at != null; at = at.getParent()) if (Files.isSymbolicLink(at)) return null;
        for (Path at = root.toPath(); at != null; at = at.getParent()) if (Files.isSymbolicLink(at)) return null;
        if (!Files.isDirectory(actual.toPath(), LinkOption.NOFOLLOW_LINKS) || !actual.canRead() || !actual.canWrite()) return null;
        return actual.getCanonicalFile();
    }

    /** 构建资源绑定完整126类和实际使用的Musl/aarch64资源；未知版本不据文件名启用。 */
    private static Profile profile() throws IOException {
        InputStream input = SqliteNativeTempBootstrap.class.getResourceAsStream("sqlite-bindings.properties");
        if (input == null) throw new IOException("missing-binding-resource");
        Properties props = new Properties();
        try { props.load(new ByteArrayInputStream(read(input, 128 * 1024))); } finally { input.close(); }
        if (!"1".equals(props.getProperty("schema")) || !"dh-sqlite-3.53.2.1".equals(props.getProperty("id"))) throw new IOException("binding-schema");
        Profile profile = new Profile(); profile.id = props.getProperty("id"); profile.prefix = PREFIX;
        for (String key : props.stringPropertyNames()) {
            if (!key.startsWith("class.") && !key.startsWith("resource.")) continue;
            boolean clazz = key.startsWith("class."); String path = key.substring(clazz ? 6 : 9), sha = props.getProperty(key);
            if (!path.matches("[a-zA-Z0-9_/$.-]+") || path.contains("..") || !sha.matches("[0-9a-f]{64}")) throw new IOException("binding-entry");
            if (clazz && (!path.startsWith(PREFIX) || !path.endsWith(".class"))) throw new IOException("binding-class");
            (clazz ? profile.classes : profile.resources).put(path, sha);
        }
        if (profile.classes.size() != 126 || profile.resources.size() != 4) throw new IOException("binding-incomplete");
        return profile;
    }
}
