package com.amcl.qa;
import java.io.File;
import java.lang.reflect.InvocationTargetException;
import java.net.URL;
import java.net.URLClassLoader;

/** 两套原Java绑定由各自加载器拥有JNI；同provider的第二ClassLoader必须按JVM合同拒绝。 */
public final class ClassLoaderOwnershipProbe {
    private static URLClassLoader loader(String classes, String jar) throws Exception {
        return new URLClassLoader(new URL[]{new File(classes).toURI().toURL(), new File(jar).toURI().toURL()}, null);
    }
    private static void run(URLClassLoader loader) throws Exception {
        Object value = loader.loadClass("com.amcl.qa.ZstdInteropProbe").getMethod("run").invoke(null);
        if (!value.toString().startsWith("AMCL_ZSTD_INTEROP passed=true")) throw new AssertionError(value);
        System.out.println(value);
    }
    public static void main(String[] args) throws Exception {
        try (URLClassLoader standard = loader(args[0], args[1]); URLClassLoader dh = loader(args[2], args[3]);
             URLClassLoader duplicate = loader(args[0], args[1])) {
            System.setProperty("ZstdNativePath", new File(args[4]).getCanonicalPath()); run(standard);
            System.setProperty("ZstdNativePath", new File(args[5]).getCanonicalPath()); run(dh);
            // Native类已记录各自原生加载归属，后续交替调用不得串用stream/字典字段缓存。
            run(standard); run(dh);
            System.setProperty("ZstdNativePath", new File(args[4]).getCanonicalPath());
            boolean rejected = false;
            try { run(duplicate); }
            catch (InvocationTargetException failure) {
                Throwable cause = failure.getCause();
                while (cause != null) {
                    if (cause instanceof UnsatisfiedLinkError && cause.getMessage().contains("already loaded in another classloader")) rejected = true;
                    cause = cause.getCause();
                }
            }
            if (!rejected) throw new AssertionError("same native provider gained a second ClassLoader owner");
            // 拒绝第二归属后第一owner仍须可用，不能通过卸载/重绑定破坏原消费者。
            run(standard);
            System.out.println("PASS distinct JNI image caches and second ClassLoader rejection");
        }
    }
}
