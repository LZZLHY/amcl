import java.lang.module.Configuration;
import java.lang.module.ModuleFinder;
import java.lang.reflect.Array;
import java.lang.reflect.Method;
import java.nio.file.Path;
import java.util.List;
import java.util.Set;

/**
 * 独立离线装配器：反射调用实际 Fabric/Forge 类，不重写或继承伪造其 loadClass 策略。
 * 只装一个无游戏依赖的小探针模块；不初始化 Mixin、ModLauncher 服务或 Minecraft 游戏状态。
 * Forge 模式使用真实 SecureJar/JarModuleFinder/ModuleClassLoader，与其公开 fallback 接口。
 */
public final class AudioLoaderQualification {
    private static final String MODULE = "amcl.audio.loader.probe";
    private static final String BOOT_MODULE = "amcl.audio.loader.boot.probe";
    private static final String PROBE = "com.amcl.audioprobe.AudioLoaderProbe";
    private static final ClassLoader SYSTEM = ClassLoader.getSystemClassLoader();

    /** 方法所在 Fabric 接口是包私有；仅测试反射打开入口，不对生产 JVM 增加 opens。 */
    private static Object invoke(Object owner, Class<?> type, String name, Class<?>[] parameters, Object... args) throws Exception {
        Method method = type.getDeclaredMethod(name, parameters); method.setAccessible(true); return method.invoke(owner, args);
    }
    private static void run(ClassLoader loader, String label, String expected, boolean named) throws Exception {
        ClassLoader previous = Thread.currentThread().getContextClassLoader();
        try {
            Thread.currentThread().setContextClassLoader(loader);
            Class<?> canonical = Class.forName("com.amcl.audio.OhosAudioNative", false, SYSTEM);
            Class<?> probe = Class.forName(PROBE, true, loader);
            System.out.println(probe.getMethod("run", String.class, String.class, Class.class, boolean.class)
                .invoke(null, label, expected, canonical, named));
        } finally { Thread.currentThread().setContextClassLoader(previous); }
    }
    /** 非 transform 阶段的实际 Knot 工厂；probe 进子域，launcher 保持既有父域。 */
    private static void knot(Path probe) throws Exception {
        Class<?> api = Class.forName("net.fabricmc.loader.impl.launch.knot.KnotClassLoaderInterface");
        Class<?> env = Class.forName("net.fabricmc.api.EnvType");
        Class<?> provider = Class.forName("net.fabricmc.loader.impl.game.GameProvider");
        @SuppressWarnings({"rawtypes", "unchecked"}) Object client = Enum.valueOf((Class) env, "CLIENT");
        Object delegate = invoke(null, api, "create", new Class<?>[]{boolean.class, boolean.class, env, provider}, false, false, client, null);
        invoke(delegate, api, "addCodeSource", new Class<?>[]{Path.class}, probe);
        ClassLoader loader = (ClassLoader) invoke(delegate, api, "getClassLoader", new Class<?>[0]);
        run(loader, "Fabric-Knot-0.19.5-pre-transform", "net.fabricmc.loader.impl.launch.knot.KnotClassLoader", false);
    }
    /** JDK 真命名模块调用者，launcher 仍是父 classpath 的唯一未命名模块 owner。 */
    private static void layer(Path probe) throws Exception {
        Configuration configuration = ModuleLayer.boot().configuration().resolve(ModuleFinder.of(probe), ModuleFinder.of(), Set.of(MODULE));
        ModuleLayer layer = ModuleLayer.boot().defineModulesWithOneLoader(configuration, SYSTEM);
        run(layer.findLoader(MODULE), "JDK-named-ModuleLayer", "jdk.internal.loader.Loader", true);
    }
    /** 使用真实 SecureJar/JarModuleFinder，保留明确的命名模块与 class 字节读取路径。 */
    private static ModuleFinder forgeFinder(Path probe) throws Exception {
        Class<?> secureJar = Class.forName("cpw.mods.jarhandling.SecureJar");
        Object jar = secureJar.getMethod("from", Path[].class).invoke(null, (Object) new Path[]{probe});
        Object jars = Array.newInstance(secureJar, 1); Array.set(jars, 0, jar);
        Class<?> finderType = Class.forName("cpw.mods.cl.JarModuleFinder");
        return (ModuleFinder) finderType.getMethod("of", jars.getClass()).invoke(null, jars);
    }
    /**
     * 复现实际 BootstrapLauncher/ModLauncher 的拓扑：BOOT 保留构造器的 Platform fallback，
     * GAME fallback 只指向 BOOT。不能再人为将任一层 fallback 改为 SYSTEM 来掩盖类解析缺口。
     * 两个场景各用独立 JVM，避免 AudioSystem 缓存上一层的 provider 后导致假通过。
     */
    private static void forge(Path probe, Path bootProbe, boolean game) throws Exception {
        Class<?> loaderType = Class.forName("cpw.mods.cl.ModuleClassLoader");
        Configuration bootConfig = ModuleLayer.boot().configuration().resolve(forgeFinder(bootProbe), ModuleFinder.of(), Set.of(BOOT_MODULE));
        ClassLoader boot = (ClassLoader) loaderType.getConstructor(String.class, Configuration.class, List.class)
            .newInstance("MC-BOOTSTRAP", bootConfig, List.of(ModuleLayer.boot()));
        ModuleLayer bootLayer = ModuleLayer.defineModules(bootConfig, List.of(ModuleLayer.boot()), name -> boot).layer();
        if (bootLayer.findLoader(BOOT_MODULE) != boot || boot.getParent() != null) throw new AssertionError("BOOT owner differs");
        System.out.println("TOPOLOGY BOOT=actual ModuleClassLoader default Platform fallback; system fallback was not installed");
        if (!game) {
            run(boot, "Forge47-BOOT-default-Platform", "cpw.mods.cl.ModuleClassLoader", true); return;
        }
        Configuration gameConfig = bootConfig.resolve(forgeFinder(probe), ModuleFinder.of(), Set.of(MODULE));
        ClassLoader gameLoader = (ClassLoader) loaderType.getConstructor(String.class, Configuration.class, List.class)
            .newInstance("GAME", gameConfig, List.of(bootLayer));
        loaderType.getMethod("setFallbackClassLoader", ClassLoader.class).invoke(gameLoader, boot);
        ModuleLayer gameLayer = ModuleLayer.defineModules(gameConfig, List.of(bootLayer), name -> gameLoader).layer();
        if (gameLayer.findLoader(MODULE) != gameLoader || gameLoader.getParent() != null) throw new AssertionError("GAME owner differs");
        System.out.println("TOPOLOGY GAME=actual ModuleClassLoader fallback BOOT -> Platform; no SYSTEM fallback");
        run(gameLoader, "Forge47-GAME-nested-BOOT", "cpw.mods.cl.ModuleClassLoader", true);
    }
    public static void main(String[] args) throws Exception {
        System.setProperty("javax.sound.sampled.SourceDataLine", "com.amcl.audio.OhosMixerProvider#AMCL OHAudio");
        System.setProperty("javax.sound.sampled.TargetDataLine", "com.amcl.audio.OhosMixerProvider#AMCL OHAudio");
        System.setProperty("javax.sound.sampled.Clip", "com.amcl.audio.OhosMixerProvider#AMCL OHAudio");
        System.clearProperty("amcl.audio.jni.path");
        System.out.println("AGENT status=" + System.getProperty("amcl.audio.service.agent.status", "absent")
            + " audioEnabled=" + System.getProperty("amcl.audio.enabled", "unset"));
        Path probe = Path.of(args[1]).toAbsolutePath();
        switch (args[0]) {
            case "knot": knot(probe); break;
            case "layer": layer(probe); break;
            case "forge-boot": forge(probe, Path.of(args[2]).toAbsolutePath(), false); break;
            case "forge": forge(probe, Path.of(args[2]).toAbsolutePath(), true); break;
            default: throw new IllegalArgumentException("mode must be knot, layer, forge-boot, or forge");
        }
        if (args[0].startsWith("forge") && "1".equals(System.getProperty("amcl.audio.service.schema"))) {
            String status = System.getProperty("amcl.audio.service.agent.status", "absent");
            if (!status.startsWith("prepared:") || !"1".equals(System.getProperty("amcl.audio.service.agent.transformed")))
                throw new AssertionError("actual Forge SPI pass must correspond to one verified emitted transform: " + status);
            System.out.println("PASS audio service agent status=" + status + " transformed=1");
        }
        System.out.println("PASS loader qualification runtime=" + System.getProperty("java.version") + " devicesOpened=0 nativeLoaded=false");
    }
}
