package com.amcl.audioprobe;

import java.io.InputStream;
import java.lang.reflect.Field;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Enumeration;
import java.util.ServiceLoader;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.*;
import java.util.jar.JarFile;
import javax.sound.sampled.*;
import javax.sound.sampled.spi.MixerProvider;

/**
 * 真加载器中的应用调用方。探针本身必须由待验加载器定义，不能只更换父线程 TCCL 后自证。
 * 仅验服务资源、标准默认选择和唯一 JNI 声明类；不 open、不加载 Native、不模拟设备通过。
 */
public final class AudioLoaderProbe {
    private static int checks;
    private static void check(boolean value, String message) {
        checks++; if (!value) throw new AssertionError(message);
    }
    /** 从实际最终 launcher 的 class 清单逐个检查并发 owner，包括包私有类与匿名 $ 内部类。 */
    private static void canonicalFamily(final ClassLoader caller, Class<?> canonical) throws Exception {
        final ClassLoader owner = canonical.getClassLoader();
        final List<Class<?>> classes = new ArrayList<Class<?>>();
        try (JarFile jar = new JarFile(new java.io.File(canonical.getProtectionDomain().getCodeSource().getLocation().toURI()))) {
            for (Enumeration<java.util.jar.JarEntry> entries = jar.entries(); entries.hasMoreElements();) {
                String path = entries.nextElement().getName();
                if (path.startsWith("com/amcl/audio/") && path.endsWith(".class"))
                    classes.add(Class.forName(path.substring(0, path.length() - 6).replace('/', '.'), false, owner));
            }
        }
        check(classes.size() >= 9, "actual launcher audio family includes nine known top-level classes");
        ExecutorService threads = Executors.newFixedThreadPool(4);
        try {
            List<Future<Boolean>> results = new ArrayList<Future<Boolean>>();
            for (int worker = 0; worker < 4; worker++) results.add(threads.submit(new Callable<Boolean>() {
                public Boolean call() throws Exception {
                    for (int repeat = 0; repeat < 8; repeat++) for (Class<?> type : classes)
                        if (Class.forName(type.getName(), false, caller) != type) return false;
                    return true;
                }
            }));
            for (Future<Boolean> result : results) check(result.get(5, TimeUnit.SECONDS), "concurrent audio family requests retain canonical Class identity");
        } finally {
            threads.shutdownNow(); check(threads.awaitTermination(2, TimeUnit.SECONDS), "all qualification threads retire");
        }
        if (caller.getClass().getName().equals("cpw.mods.cl.ModuleClassLoader")) {
            check(Class.forName("com.amcl.audio.Unlisted", false, caller).getClassLoader() == caller,
                "unlisted same-package class stays in actual module loader");
            check(Class.forName("com.amcl.audio.OhosClipEvil", false, caller).getClassLoader() == caller,
                "top-level name lookalike stays in actual module loader");
            boolean rejected = false;
            try { Class.forName("com.amcl.audio.OhosClip$NoSuchNested", false, caller); }
            catch (ClassNotFoundException expected) { rejected = true; }
            check(rejected, "missing canonical nested class never falls back to a game-owned duplicate");
        }
    }
    /** 调用者传入启动器父域的 canonical bridge，逐个比较真正的 Class 对象身份。 */
    public static String run(String label, String expectedLoader, Class<?> canonical, boolean named) throws Exception {
        ClassLoader caller = AudioLoaderProbe.class.getClassLoader();
        ClassLoader context = Thread.currentThread().getContextClassLoader();
        check(caller.getClass().getName().equals(expectedLoader), "probe is defined by real requested loader");
        check(context == caller, "SPI caller and TCCL use the same target loader");
        check(AudioLoaderProbe.class.getModule().isNamed() == named, "probe named-module state is explicit");
        check(Class.forName("com.amcl.audio.OhosAudioNative", false, caller) == canonical, "target loader resolves canonical bridge Class identity");
        check(Class.forName("com.amcl.audio.OhosAudioNative", false, context) == canonical, "context loader resolves canonical bridge Class identity");
        Field loaded = canonical.getDeclaredField("loaded"); loaded.setAccessible(true);
        check(!loaded.getBoolean(null), "service discovery starts without native load");
        canonicalFamily(caller, canonical);

        String service = "META-INF/services/javax.sound.sampled.spi.MixerProvider";
        int resources = 0; String origin = "";
        for (Enumeration<URL> urls = caller.getResources(service); urls.hasMoreElements();) {
            URL url = urls.nextElement(); String content;
            try (InputStream stream = url.openStream()) { content = new String(stream.readAllBytes(), StandardCharsets.UTF_8); }
            if (content.contains("com.amcl.audio.OhosMixerProvider")) { resources++; origin = url.toString(); }
        }
        int providers = 0;
        Class<?> providerClass = Class.forName("com.amcl.audio.OhosMixerProvider", false, canonical.getClassLoader());
        for (MixerProvider provider : ServiceLoader.load(MixerProvider.class)) {
            if (provider.getClass().getName().equals(providerClass.getName())) {
                providers++; check(provider.getClass() == providerClass, "SPI instance uses launcher provider Class identity");
            }
        }
        AudioFormat format = new AudioFormat(16000, 16, 1, true, false);
        check(AudioSystem.isLineSupported(new DataLine.Info(TargetDataLine.class, format)),
            "Verity exact 16000Hz S16 monoLE TargetDataLine is supported before open");
        Line source = null, target = null, clip = null;
        String sourceResult, targetResult, clipResult;
        try { source = AudioSystem.getSourceDataLine(format); sourceResult = source.getClass().getName(); }
        catch (IllegalArgumentException unavailable) { sourceResult = unavailable.toString(); }
        try { target = AudioSystem.getTargetDataLine(format); targetResult = target.getClass().getName(); }
        catch (IllegalArgumentException unavailable) { targetResult = unavailable.toString(); }
        try { clip = AudioSystem.getClip(); clipResult = clip.getClass().getName(); }
        catch (IllegalArgumentException unavailable) { clipResult = unavailable.toString(); }
        // 在断言前保留完整观察，真实加载器失败时仍可区分类解析、单资源、资源枚举与默认选择。
        System.out.println("OBSERVE loader=" + label + " actual=" + caller.getClass().getName()
            + " named=" + named + " canonicalBridge=true resourceCount=" + resources + " providerCount=" + providers
            + " singleResource=" + caller.getResource(service) + " source=" + sourceResult + " target=" + targetResult + " clip=" + clipResult);
        check(resources == 1, "exactly one AMCL SPI service resource is visible; actual=" + resources);
        check(providers == 1, "ServiceLoader returns one production provider; actual=" + providers);
        check(source != null && target != null && clip != null, "all standard defaults resolve without device open");
        check(source.getClass().getName().equals("com.amcl.audio.OhosSourceDataLine"), "default SourceDataLine is AMCL");
        check(target.getClass().getName().equals("com.amcl.audio.OhosTargetDataLine"), "default TargetDataLine is AMCL");
        check(clip.getClass().getName().equals("com.amcl.audio.OhosClip"), "default Clip is AMCL");
        check(!source.isOpen() && !target.isOpen() && !clip.isOpen(), "enumeration does not open devices");
        check(source.getClass().getClassLoader() == canonical.getClassLoader()
            && target.getClass().getClassLoader() == canonical.getClassLoader()
            && clip.getClass().getClassLoader() == canonical.getClassLoader(), "all default lines retain canonical launcher owner");
        check(!loaded.getBoolean(null), "all discovery and default choices leave native unloaded");
        return "PASS loader=" + label + " actual=" + caller.getClass().getName()
            + " module=" + AudioLoaderProbe.class.getModule().getName() + " checks=" + checks
            + " providerCount=" + providers + " resourceCount=" + resources + " resource=" + origin
            + " bridgeOwner=" + canonical.getClassLoader().getClass().getName();
    }
}
