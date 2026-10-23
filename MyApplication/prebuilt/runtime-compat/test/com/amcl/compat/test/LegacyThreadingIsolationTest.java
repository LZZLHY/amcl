package com.amcl.compat.test;

import java.net.URL;
import java.net.URLClassLoader;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * 在没有任何 named Minecraft 类型的隔离加载器中运行通用插件/profile。
 * 由脚本选择真实 JDK21 子进程时还能证明 class65 的旧运行路径可以执行；新桥仅当
 * 26.2 profile 启用时才允许解析，不能靠 JDK25 恰好能读全部类来隐藏提前链接。
 */
public final class LegacyThreadingIsolationTest {
    /** 任何尝试解析 26.2 游戏或专用桥都立即暴露，而不是从系统 classpath 偷取。 */
    private static final class LegacyLoader extends URLClassLoader {
        final List<String> rejected = new ArrayList<>();
        LegacyLoader(URL[] urls) { super(urls, ClassLoader.getPlatformClassLoader()); }
        @Override protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
            if (name.startsWith("net.minecraft.") || name.equals("com.amcl.compat.CreateFlyPacketThreading26")
                || name.contains("CreateFlyClientPacketThreadingMixin") || name.contains("CreateFlyServerPacketThreadingMixin")) {
                rejected.add(name); throw new ClassNotFoundException("26.2 type forbidden on legacy path: " + name);
            }
            return super.loadClass(name, resolve);
        }
    }

    /** 参数只含兼容 JAR、Loader 与 Mixin/ASM；禁止把完整游戏放进此隔离测试。 */
    public static void main(String[] args) throws Exception {
        URL[] urls = new URL[args.length];
        for (int index = 0; index < args.length; index++) urls[index] = Path.of(args[index]).toUri().toURL();
        try (LegacyLoader loader = new LegacyLoader(urls)) {
            Class<?> profileClass = Class.forName("com.amcl.compat.CreateFlyThreadingProfile", true, loader);
            Object profile = profileClass.getConstructor().newInstance();
            if (!Boolean.FALSE.equals(profileClass.getMethod("enableForLoadedMods").invoke(profile)))
                throw new AssertionError("Absent Create enabled thread profile");
            Class<?> pluginClass = Class.forName("com.amcl.compat.CompatMixinPlugin", true, loader);
            Object plugin = pluginClass.getConstructor().newInstance();
            pluginClass.getMethod("onLoad", String.class).invoke(plugin, "com.amcl.compat.mixin");
            if (!loader.rejected.isEmpty()) throw new AssertionError("Legacy path tried 26.2 linkage: " + loader.rejected);
        }
        System.out.println("[legacy-threading-isolation] PASS java=" + Runtime.version().feature()
            + " common plugin/profile load with named Minecraft and dedicated 26.2 bridge forbidden");
    }
}
