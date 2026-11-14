package com.amcl.qa;
import java.io.File;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;

/**
 * 只读诊断生产选择器的具体失败来源。反射仅访问本应用自己的扫描类，不加载任何模组类，
 * 不调用configure、不改System属性/文件。沿同一Scan实例保留全局预算，避免逐JAR重置掩盖问题。
 */
public final class ZstdArchiveAuditProbe {
    public static void main(String[] args) throws Exception {
        if (args.length < 1) throw new IllegalArgumentException("original mods directory required");
        Class<?> owner = Class.forName("com.amcl.launcher.ZstdNativeBootstrap");
        Method profiles = owner.getDeclaredMethod("loadProfiles"); profiles.setAccessible(true);
        Class<?> scannerClass = Class.forName("com.amcl.launcher.ZstdNativeBootstrap$Scan");
        Constructor<?> constructor = scannerClass.getDeclaredConstructor(List.class, String.class); constructor.setAccessible(true);
        Object scanner = constructor.newInstance(profiles.invoke(null), "fabric");
        Method file = scannerClass.getDeclaredMethod("file", File.class); file.setAccessible(true);
        LinkedHashMap<String, File> paths = new LinkedHashMap<String, File>();
        for (String entry : System.getProperty("java.class.path").split(File.pathSeparator)) {
            File path = new File(entry);
            if (path.isFile()) paths.put(path.getCanonicalPath(), path);
        }
        File[] mods = new File(args[0]).listFiles();
        if (mods == null || mods.length > 2048) throw new IllegalStateException("mods unavailable/limit");
        Arrays.sort(mods);
        for (File mod : mods) if (mod.isFile() && mod.getName().endsWith(".jar")) paths.put(mod.getCanonicalPath(), mod);
        int count = 0;
        for (File path : paths.values()) {
            try { file.invoke(scanner, path); count++; }
            catch (InvocationTargetException failure) {
                System.out.println("AMCL_ZSTD_ARCHIVE_AUDIT failedAt=" + path.getName() + " scanned=" + count + " cause=" + failure.getCause());
                System.exit(0); return;
            }
        }
        System.out.println("AMCL_ZSTD_ARCHIVE_AUDIT scanComplete=true archives=" + count);
        System.exit(0);
    }
}
