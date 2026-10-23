package com.amcl.compat;

import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.function.Function;
import net.fabricmc.loader.api.FabricLoader;
import net.fabricmc.loader.api.ModContainer;
import net.fabricmc.loader.impl.launch.FabricLauncherBase;

/**
 * Create Fly 26.2 PLAY 线程规则的完整、不可变原始输入身份。只读取真实 ModContainer
 * 内资源，不加载任何 Minecraft/Create 类；该通用类在 JDK21 和无 Create 时也能安全链接。
 * 一次判定全部两侧包与关联 dispatch/注册/widen/元数据，不允许逐包“尽力”应用。
 * 摘要只证明原始身份；实际变换与运行证据由独立阶段记录，不能把 gate 命中当成修复完成。
 */
public final class CreateFlyThreadingProfile {
    public static final String OLD = "supported-old";
    public static final String FIXED = "upstream-fixed";
    public static final String UNKNOWN = "unknown-profile-skipped";
    private static final String RESOURCE = "/create-fly-threading-26.2.properties";
    private final Properties values;
    private final Map<String, String[]> entries;
    private final Map<String, String> minecraftEntries;
    private final Set<String> clientTargets;
    private final Set<String> serverTargets;

    /**
     * 读取随兼容制品冻结的清单，并验证目标描述符、摘要形态和目标集合完整性。
     * 清单损坏属于本方交付错误，必须终止；用户未知模组属于未覆盖，两者不能混为一谈。
     */
    public CreateFlyThreadingProfile() {
        values = new Properties();
        try (InputStream stream = CreateFlyThreadingProfile.class.getResourceAsStream(RESOURCE)) {
            if (stream == null) throw new IOException("Missing " + RESOURCE);
            values.load(new InputStreamReader(stream, StandardCharsets.UTF_8));
        } catch (IOException error) {
            throw new IllegalStateException("AMCL Create threading profile unavailable", error);
        }
        require("schema", "1");
        require("minecraft", "26.2");
        require("loader.resource-contract", "0.19.5-knot-dynamic-v1");
        require("client.descriptor", "handle(Lnet/minecraft/network/protocol/game/ClientGamePacketListener;)V");
        require("server.descriptor", "handle(Lnet/minecraft/network/protocol/game/ServerGamePacketListener;)V");
        require("bridge.descriptor", "handle(Lnet/minecraft/network/PacketListener;)V");
        entries = new LinkedHashMap<>();
        minecraftEntries = new LinkedHashMap<>();
        for (String key : new java.util.TreeSet<>(values.stringPropertyNames())) {
            if (key.startsWith("entry.")) {
                String[] hashes = values.getProperty(key).split(",", -1);
                if (hashes.length != 2 || !isHash(hashes[0]) || !isHash(hashes[1])) {
                    throw new IllegalStateException("Invalid Create profile digest: " + key);
                }
                entries.put(key.substring("entry.".length()), hashes);
            } else if (key.startsWith("minecraft.entry.")) {
                String hash = values.getProperty(key);
                if (!isHash(hash)) throw new IllegalStateException("Invalid Minecraft profile digest: " + key);
                minecraftEntries.put(key.substring("minecraft.entry.".length()), hash);
            }
        }
        clientTargets = readTargets("client", 28);
        serverTargets = readTargets("server", 19);
        if (entries.size() != 133 || minecraftEntries.size() != 9) {
            throw new IllegalStateException("Incomplete AMCL Create threading input inventory");
        }
    }

    /** 清单关键字段只接受已审核值；这些检查不访问目标类。 */
    private void require(String key, String expected) {
        if (!expected.equals(values.getProperty(key))) {
            throw new IllegalStateException("Unexpected AMCL Create threading profile field: " + key);
        }
    }

    /** 按逻辑侧读真实类集合，排除重复、跨方向及没有原始字节身份的目标。 */
    private Set<String> readTargets(String side, int expectedCount) {
        String list = values.getProperty(side + ".targets", "");
        Set<String> result = new LinkedHashSet<>(Arrays.asList(list.split(",", -1)));
        String prefix = "com.zurrtum.create.infrastructure.packet." + ("client".equals(side) ? "s2c." : "c2s.");
        if (result.size() != expectedCount || result.size() != list.split(",", -1).length) {
            throw new IllegalStateException("Incomplete or duplicate Create threading targets: " + side);
        }
        for (String target : result) {
            if (!target.startsWith(prefix) || !entries.containsKey(target.replace('.', '/') + ".class")) {
                throw new IllegalStateException("Unbound Create threading target: " + target);
            }
        }
        return Collections.unmodifiableSet(result);
    }

    /** 固定 profile ID 用于 gate/transform/执行日志相互关联，不代表运行变换已全部完成。 */
    public String id() { return values.getProperty("profile"); }

    /** 返回冻结目标集合供 Mixin plugin 和完整覆盖测试使用，不允许调用方改写。 */
    public Set<String> targets(String side) {
        if ("client".equals(side)) return clientTargets;
        if ("server".equals(side)) return serverTargets;
        throw new IllegalArgumentException("Unknown logical side: " + side);
    }

    /** 返回精确 typed handle 描述符，避免把 bridge 或同名重载当作已覆盖入口。 */
    public String descriptor(String side) { return values.getProperty(side + ".descriptor"); }

    /**
     * 纯原始字节判据供生产 gate 和逐目标变化/缺失负例共用；读取每一项而非提前短路。
     * Function 只应从选定模组容器读取，null 表示缺失/不可读，不得回退任意 classpath 同名类。
     */
    public String classify(Function<String, byte[]> reader) {
        boolean old = true;
        boolean fixed = true;
        for (Map.Entry<String, String[]> entry : entries.entrySet()) {
            String digest = digest(reader.apply(entry.getKey()));
            old &= entry.getValue()[0].equals(digest);
            fixed &= entry.getValue()[1].equals(digest);
        }
        return old ? OLD : fixed ? FIXED : UNKNOWN;
    }

    /** 公开只读路径集合，使验证能够逐项变异，而不复制一份可能漂移的目标规则。 */
    public Set<String> entries() { return Collections.unmodifiableSet(entries.keySet()); }

    /** 原版调度及公开 ABI 的冻结路径集合，供实际类资源遮蔽负例逐项覆盖。 */
    public Set<String> minecraftEntries() { return Collections.unmodifiableSet(minecraftEntries.keySet()); }

    /**
     * 可测试的双来源纯判据：容器完整旧/新 profile 与实际定义候选必须同时匹配。
     * 元数据/Mixin 配置/class tweaker 仍从各自真实容器验证，不能使用 classpath 上随便
     * 一个 fabric.mod.json。所有 Create .class（含 dispatch/内部类）和原版九类另逐项
     * 比较实际首候选原始字节；官方 Create 容器完整但被同名类遮蔽时整组退出。
     * reader 只读取资源，不定义或初始化类；原生 vanilla identity 也在此方法独立冻结。
     */
    public String classifyVisible(Function<String, byte[]> createReader, Function<String, byte[]> minecraftReader,
        Function<String, byte[]> selectedClassReader) {
        boolean[] sameSelection = {true};
        String status = classify(path -> {
            byte[] original = createReader.apply(path);
            if (path.endsWith(".class")) {
                sameSelection[0] &= original != null && Arrays.equals(original, selectedClassReader.apply(path));
            }
            return original;
        });
        for (Map.Entry<String, String> entry : minecraftEntries.entrySet()) {
            byte[] original = minecraftReader.apply(entry.getKey());
            sameSelection[0] &= entry.getValue().equals(digest(original))
                && original != null && Arrays.equals(original, selectedClassReader.apply(entry.getKey()));
        }
        return sameSelection[0] ? status : UNKNOWN;
    }

    /**
     * 运行时仅在本次真实 Minecraft/Create 模组容器均匹配时登记整组策略。撤回开关只影响
     * 下一次冷启动的线程规则；容量/scatter/resize 由原插件独立判定，不热撤销已定义类。
     * 未知/缺失输入沿既有启动策略跳过；已接受 profile 后变换失败由 required Mixin 致命退出。
     */
    public boolean enableForLoadedMods() {
        if ("false".equalsIgnoreCase(System.getProperty("amcl.compat.createPacketThreading", "true"))) {
            log("withdrawn", "cold-start-property");
            return false;
        }
        FabricLoader loader = FabricLoader.getInstance();
        ModContainer create = loader.getModContainer("create").orElse(null);
        if (create == null) return false;
        ModContainer minecraft = loader.getModContainer("minecraft").orElse(null);
        if (minecraft == null || !values.getProperty("minecraft").equals(minecraft.getMetadata().getVersion().getFriendlyString())) {
            log(UNKNOWN, "minecraft-version");
            return false;
        }
        ModContainer fabric = loader.getModContainer("fabricloader").orElse(null);
        if (fabric == null || !"0.19.5".equals(fabric.getMetadata().getVersion().getFriendlyString())) {
            log(UNKNOWN, "loader-resource-contract-unsupported");
            return false;
        }
        Function<String, byte[]> selectedReader = selectedKnotResources();
        if (selectedReader == null) {
            log(UNKNOWN, "actual-knot-resource-query-unavailable");
            return false;
        }
        String status = classifyVisible(path -> readContainer(create, path),
            path -> readContainer(minecraft, path), selectedReader);
        String version = create.getMetadata().getVersion().getFriendlyString();
        if ((OLD.equals(status) && !values.getProperty("create.old.version").equals(version))
            || (FIXED.equals(status) && !values.getProperty("create.new.version").equals(version))) {
            status = UNKNOWN;
        }
        log(status, OLD.equals(status) ? "container-and-knot-profile-registered" : "no-thread-transform");
        return OLD.equals(status);
    }

    /**
     * 绑定已审查 Loader 0.19.5 的实际 Knot target，而非 TCCL 或本插件的类加载器。
     * 该版本 KnotClassLoader 的 parent 正是 DynamicURLClassLoader；其 parent 为返回
     * null 资源的 DummyClassLoader，所以 dynamic.getResource 与 findResourceFwd 使用
     * 相同动态首候选。先核具体父链，再查询两个 URL 一致，避免误接任意 parent fallback。
     * 不调用有 unlocked 时机门的 getClassByteArray，也不反射打开类或初始化游戏类。
     * 未知 Loader 后端/未就绪/查询失败保守整组退出；仅扩展已验证资源契约后才支持它们。
     */
    private static Function<String, byte[]> selectedKnotResources() {
        try {
            if (FabricLauncherBase.getLauncher() == null) return null;
            ClassLoader target = FabricLauncherBase.getLauncher().getTargetClassLoader();
            if (target == null || !target.getClass().getName().equals("net.fabricmc.loader.impl.launch.knot.KnotClassLoader")) return null;
            ClassLoader dynamic = target.getParent();
            if (dynamic == null || !dynamic.getClass().getName().equals("net.fabricmc.loader.impl.launch.knot.KnotClassLoader$DynamicURLClassLoader")) return null;
            ClassLoader dummy = dynamic.getParent();
            if (dummy == null || !dummy.getClass().getName().equals("net.fabricmc.loader.impl.launch.knot.DummyClassLoader")) return null;
            return path -> readSelectedKnotResource(target, dynamic, path);
        } catch (RuntimeException | LinkageError error) {
            return null;
        }
    }

    /**
     * 只读动态 first candidate；动态缺失但 target 从 originalLoader 找到资源时也返回
     * null，因为该 fallback 还受类加载专用 parent URL 白名单约束，不能仅凭 getResource
     * 宣称可定义。当前 profile 的已支持路径要求动态候选完整，安全地拒绝未核实 fallback。
     * URL 用文本比较避免 URL.equals 的潜在 DNS 行为；限长读取防止异常资源占满内存。
     */
    private static byte[] readSelectedKnotResource(ClassLoader target, ClassLoader dynamic, String resource) {
        try {
            URL selected = dynamic.getResource(resource);
            URL visible = target.getResource(resource);
            if (selected == null || visible == null || !selected.toExternalForm().equals(visible.toExternalForm())) return null;
            try (InputStream stream = selected.openStream()) {
                byte[] bytes = stream.readNBytes(4 * 1024 * 1024 + 1);
                return bytes.length <= 4 * 1024 * 1024 ? bytes : null;
            }
        } catch (IOException | RuntimeException error) {
            return null;
        }
    }

    /**
     * 通过 loader 选定容器查找原始资源，避免另一模组的同名资源冒充 Create。
     * 正常 profile 类均小于该保守上限；异常超大/缺失/读取失败一律记未匹配，不初始化类。
     */
    private static byte[] readContainer(ModContainer container, String resource) {
        try {
            Path path = container.findPath(resource).orElse(null);
            return path != null && Files.isRegularFile(path) && Files.size(path) <= 4L * 1024 * 1024
                ? Files.readAllBytes(path) : null;
        } catch (IOException | RuntimeException error) {
            return null;
        }
    }

    /** 固定长度小写 SHA256；缺字节返回空串，绝不把读取失败误判为某个支持版本。 */
    private static String digest(byte[] bytes) {
        if (bytes == null) return "";
        try {
            return java.util.HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (java.security.NoSuchAlgorithmException error) {
            throw new IllegalStateException("SHA-256 unavailable", error);
        }
    }

    /** 校验内置清单摘要格式，不把不受约束字符串交给版本判据。 */
    private static boolean isHash(String value) { return value.matches("[0-9a-f]{64}"); }

    /** gate 只报告原始匹配与登记，后续 transform/first-execution 有各自独立证据。 */
    private void log(String status, String reason) {
        System.out.println("[AMCL-CREATE-THREAD] schema=1 rule=create-fly-play-threading stage=profile profile="
            + id() + " status=" + status + " reason=" + reason);
    }
}
