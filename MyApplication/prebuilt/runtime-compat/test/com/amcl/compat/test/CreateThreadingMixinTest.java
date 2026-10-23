package com.amcl.compat.test;

import com.amcl.compat.CompatMixinPlugin;
import com.amcl.compat.CreateFlyThreadingProfile;
import java.io.InputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Modifier;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.jar.JarFile;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FieldInsnNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.JumpInsnNode;
import org.objectweb.asm.tree.LabelNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.analysis.Analyzer;
import org.objectweb.asm.tree.analysis.BasicVerifier;
import org.spongepowered.asm.launch.MixinBootstrap;
import org.spongepowered.asm.mixin.MixinEnvironment;
import org.spongepowered.asm.mixin.Mixins;
import org.spongepowered.asm.mixin.transformer.IMixinTransformer;

/**
 * 固定旧/新版真实 JAR 的 profile 全域负例与真实 Mixin 全目标变换。只检查实物字节，
 * 不把解包/ASM 模型声称为真实游戏已运行；实际生产 pre/post 检查也参与本测试。
 */
public final class CreateThreadingMixinTest {
    private static void check(boolean condition, String reason) { if (!condition) throw new AssertionError(reason); }

    /** profile 原始资源均从选定 JAR 读取，不从混杂 classpath 猜测目标来源。 */
    private static Map<String, byte[]> readEntries(Path artifact, Set<String> entries) throws Exception {
        Map<String, byte[]> result = new LinkedHashMap<>();
        try (JarFile jar = new JarFile(artifact.toFile())) {
            for (String name : entries) {
                var entry = jar.getJarEntry(name); check(entry != null, "frozen artifact missing " + name);
                try (InputStream stream = jar.getInputStream(entry)) { result.put(name, stream.readAllBytes()); }
            }
        }
        return result;
    }

    /** 任一目标或关联 dispatch/helper 变化/缺失都使整组退出；无目标和新版本也单独对照。 */
    private static void profiles(CreateFlyThreadingProfile profile, Map<String, byte[]> old, Map<String, byte[]> fixed) {
        check(CreateFlyThreadingProfile.OLD.equals(profile.classify(old::get)), "old profile rejected");
        check(CreateFlyThreadingProfile.FIXED.equals(profile.classify(fixed::get)), "upstream fixed profile not withdrawn");
        check(CreateFlyThreadingProfile.UNKNOWN.equals(profile.classify(name -> null)), "absent Create accepted");
        for (String name : profile.entries()) {
            Map<String, byte[]> variant = new HashMap<>(old);
            variant.remove(name);
            check(CreateFlyThreadingProfile.UNKNOWN.equals(profile.classify(variant::get)), "missing input partially enabled: " + name);
            byte[] changed = old.get(name).clone(); changed[changed.length - 1] ^= 1; variant.put(name, changed);
            check(CreateFlyThreadingProfile.UNKNOWN.equals(profile.classify(variant::get)), "changed input partially enabled: " + name);
        }
        // 撤回开关应在任何 Loader 初始化之前返回；它只撤回线程规则，不改变已有两项原始判据。
        String original = System.getProperty("amcl.compat.createPacketThreading");
        try {
            System.setProperty("amcl.compat.createPacketThreading", "false");
            check(!profile.enableForLoadedMods(), "cold-start withdrawal ignored");
        } finally {
            if (original == null) System.clearProperty("amcl.compat.createPacketThreading");
            else System.setProperty("amcl.compat.createPacketThreading", original);
        }
    }

    /**
     * 容器与实际类选择是两个独立输入：逐个资源替换、丢失或遮蔽都必须整组退出。
     * 同 FQCN 的旧/新同摘要类无语义变化，因此“另一来源”负控使用明确不同字节，不能
     * 仅凭 URL 不同假装发生了字节冲突；URL 契约由实际 Loader/设备门另行验证。
     */
    private static void visibleProfiles(CreateFlyThreadingProfile profile, Map<String, byte[]> old,
        Map<String, byte[]> fixed, Map<String, byte[]> minecraft) {
        Map<String, byte[]> selected = new HashMap<>(old); selected.putAll(minecraft);
        check(CreateFlyThreadingProfile.OLD.equals(profile.classifyVisible(old::get, minecraft::get, selected::get)), "visible old profile rejected");
        Map<String, byte[]> fixedSelection = new HashMap<>(fixed); fixedSelection.putAll(minecraft);
        check(CreateFlyThreadingProfile.FIXED.equals(profile.classifyVisible(fixed::get, minecraft::get, fixedSelection::get)), "visible fixed profile did not withdraw");
        for (String name : profile.entries()) {
            Map<String, byte[]> missing = new HashMap<>(old); missing.remove(name);
            check(CreateFlyThreadingProfile.UNKNOWN.equals(profile.classifyVisible(missing::get, minecraft::get, selected::get)), "visible gate accepted missing Create container entry " + name);
            Map<String, byte[]> changed = new HashMap<>(old);
            byte[] replacement = old.get(name).clone(); replacement[replacement.length - 1] ^= 1; changed.put(name, replacement);
            check(CreateFlyThreadingProfile.UNKNOWN.equals(profile.classifyVisible(changed::get, minecraft::get, selected::get)), "visible gate accepted changed Create container entry " + name);
            if (!name.endsWith(".class")) continue;
            Map<String, byte[]> shadow = new HashMap<>(selected); shadow.remove(name);
            check(CreateFlyThreadingProfile.UNKNOWN.equals(profile.classifyVisible(old::get, minecraft::get, shadow::get)), "missing actual Create class accepted " + name);
            shadow.put(name, replacement);
            check(CreateFlyThreadingProfile.UNKNOWN.equals(profile.classifyVisible(old::get, minecraft::get, shadow::get)), "same-FQCN shadowed Create class accepted " + name);
            Map<String, byte[]> fixedShadow = new HashMap<>(fixedSelection); fixedShadow.put(name, replacement);
            check(CreateFlyThreadingProfile.UNKNOWN.equals(profile.classifyVisible(fixed::get, minecraft::get, fixedShadow::get)), "fixed profile shadow not detected " + name);
        }
        for (String name : profile.minecraftEntries()) {
            Map<String, byte[]> missing = new HashMap<>(minecraft); missing.remove(name);
            check(CreateFlyThreadingProfile.UNKNOWN.equals(profile.classifyVisible(old::get, missing::get, selected::get)), "missing Minecraft container class accepted " + name);
            Map<String, byte[]> changed = new HashMap<>(minecraft);
            byte[] replacement = minecraft.get(name).clone(); replacement[replacement.length - 1] ^= 1; changed.put(name, replacement);
            check(CreateFlyThreadingProfile.UNKNOWN.equals(profile.classifyVisible(old::get, changed::get, selected::get)), "changed Minecraft container class accepted " + name);
            Map<String, byte[]> shadow = new HashMap<>(selected); shadow.remove(name);
            check(CreateFlyThreadingProfile.UNKNOWN.equals(profile.classifyVisible(old::get, minecraft::get, shadow::get)), "missing selected Minecraft class accepted " + name);
            shadow.put(name, replacement);
            check(CreateFlyThreadingProfile.UNKNOWN.equals(profile.classifyVisible(old::get, minecraft::get, shadow::get)), "shadowed Minecraft class accepted " + name);
        }
    }

    /**
     * 使用真正 URLClassLoader/JAR 资源复验生产 URL 判据：同一个首资源才允许读，不同
     * 来源即使字节相同也拒绝；动态缺失而父侧可见的 fallback 也拒绝。这里只调用私有
     * 资源比较器，不伪造真正 Knot 父链已成立，实际 Knot 来源仍由设备门确认。
     */
    private static void resourceUrls(Path output, String resource, byte[] contents) throws Exception {
        Path first = output.resolve("resource-url-a.jar"), second = output.resolve("resource-url-b.jar");
        for (Path destination : List.of(first, second)) {
            try (var jar = new java.util.jar.JarOutputStream(Files.newOutputStream(destination))) {
                jar.putNextEntry(new java.util.jar.JarEntry(resource)); jar.write(contents); jar.closeEntry();
            }
        }
        var reader = CreateFlyThreadingProfile.class.getDeclaredMethod("readSelectedKnotResource", ClassLoader.class, ClassLoader.class, String.class);
        reader.setAccessible(true);
        try (URLClassLoader a = new URLClassLoader(new java.net.URL[]{first.toUri().toURL()}, ClassLoader.getPlatformClassLoader());
             URLClassLoader same = new URLClassLoader(new java.net.URL[]{first.toUri().toURL()}, ClassLoader.getPlatformClassLoader());
             URLClassLoader b = new URLClassLoader(new java.net.URL[]{second.toUri().toURL()}, ClassLoader.getPlatformClassLoader());
             URLClassLoader empty = new URLClassLoader(new java.net.URL[0], ClassLoader.getPlatformClassLoader())) {
            check(Arrays.equals(contents, (byte[]) reader.invoke(null, a, same, resource)), "same URL resource rejected");
            check(reader.invoke(null, a, b, resource) == null, "different source URL accepted despite equal bytes");
            check(reader.invoke(null, a, empty, resource) == null, "parent-only fallback accepted");
            check(reader.invoke(null, empty, a, resource) == null, "target missing selected resource accepted");
        }
    }

    private static ClassNode node(byte[] bytes) {
        ClassNode result = new ClassNode(); new ClassReader(bytes).accept(result, 0); return result;
    }

    /** 所有已声明方法的 ABI 必须保留；尤其 typed 与合成 bridge 不能被新参数替换。 */
    private static Set<String> methods(ClassNode node) {
        Set<String> result = new TreeSet<>();
        for (MethodNode method : node.methods)
            result.add(method.name + method.desc + ":" + method.access);
        return result;
    }

    /** 真实 bridge 必须仍只向本包 typed 方法分派一次，不能绕开或再次调用业务。 */
    private static List<String> bridgeCalls(ClassNode node) {
        List<String> result = new ArrayList<>();
        for (MethodNode method : node.methods) {
            if (!method.name.equals("handle") || !method.desc.equals("(Lnet/minecraft/network/PacketListener;)V")) continue;
            for (AbstractInsnNode instruction : method.instructions)
                if (instruction instanceof MethodInsnNode call) result.add(call.owner + "." + call.name + call.desc);
        }
        return result;
    }

    /** 每个真实生成方法做 ASM 数据流校验；不初始化 Create 的注册表、世界或 GL。 */
    private static void verify(ClassNode node) throws Exception {
        for (MethodNode method : node.methods)
            if ((method.access & (Opcodes.ACC_ABSTRACT | Opcodes.ACC_NATIVE)) == 0)
                new Analyzer<>(new BasicVerifier()).analyze(node.name, method);
    }

    /**
     * 直接用实际 Mixin 产物和生产 prefix 验证器回归 unused CallbackInfo 的 null 参数。
     * 再在同一真实方法前插入业务调用、字段访问、分支及非允许栈常量，证明这次修正没有
     * 将“存在 guard”当作充分条件。这里只验证静态拒绝边界，不替代后续真实组合运行。
     */
    private static void guardPrefixControls(Map<String, byte[]> transformed) throws Exception {
        byte[] bytes = transformed.get("com.zurrtum.create.infrastructure.packet.s2c.ServerSpeedPacket");
        check(bytes != null, "actual ServerSpeed Mixin output missing");
        String descriptor = "(Lnet/minecraft/network/protocol/game/ClientGamePacketListener;)V";
        var validator = CompatMixinPlugin.class.getDeclaredMethod("verifyGuardPrefix", ClassNode.class, String.class, String.class);
        validator.setAccessible(true);
        ClassNode actual = node(bytes);
        MethodNode typed = actual.methods.stream().filter(method -> method.name.equals("handle")
            && method.desc.equals(descriptor)).findFirst().orElseThrow();
        boolean unusedNull = false;
        for (AbstractInsnNode instruction : typed.instructions) {
            if (instruction instanceof MethodInsnNode call && call.name.contains("amcl$guardClientThread")) break;
            if (instruction.getOpcode() == Opcodes.ACONST_NULL) unusedNull = true;
        }
        check(unusedNull, "locked Mixin unused CallbackInfo null optimization not observed");
        validator.invoke(null, actual, "client", descriptor);

        Map<String, InsnList> forbidden = new LinkedHashMap<>();
        InsnList businessCall = new InsnList();
        businessCall.add(new MethodInsnNode(Opcodes.INVOKESTATIC, "fixture/ForeignHooks", "touch", "()V", false));
        forbidden.put("business-call", businessCall);
        InsnList field = new InsnList();
        field.add(new FieldInsnNode(Opcodes.GETSTATIC, "fixture/ForeignState", "shared", "Ljava/lang/Object;"));
        field.add(new InsnNode(Opcodes.POP));
        forbidden.put("field-access", field);
        InsnList branch = new InsnList(); LabelNode join = new LabelNode();
        branch.add(new JumpInsnNode(Opcodes.GOTO, join)); branch.add(join);
        forbidden.put("branch", branch);
        InsnList otherConstant = new InsnList();
        otherConstant.add(new InsnNode(Opcodes.ICONST_1)); otherConstant.add(new InsnNode(Opcodes.POP));
        forbidden.put("other-stack-constant", otherConstant);
        InsnList cancel = new InsnList(); cancel.add(new InsnNode(Opcodes.ACONST_NULL));
        cancel.add(new MethodInsnNode(Opcodes.INVOKEVIRTUAL,
            "org/spongepowered/asm/mixin/injection/callback/CallbackInfo", "cancel", "()V", false));
        forbidden.put("callback-cancel", cancel);
        for (Map.Entry<String, InsnList> control : forbidden.entrySet()) {
            ClassNode changed = node(bytes);
            MethodNode method = changed.methods.stream().filter(candidate -> candidate.name.equals("handle")
                && candidate.desc.equals(descriptor)).findFirst().orElseThrow();
            method.instructions.insert(control.getValue());
            try {
                validator.invoke(null, changed, "client", descriptor);
                throw new AssertionError("unsafe prefix accepted: " + control.getKey());
            } catch (InvocationTargetException expected) {
                Throwable reason = expected.getCause();
                check(reason instanceof IllegalStateException && (reason.getMessage().startsWith("Call before Create threading guard:")
                    || reason.getMessage().startsWith("Instruction before Create threading guard:")),
                    "unexpected prefix rejection: " + control.getKey() + " " + reason);
            }
        }
        System.out.println("[threading-guard-prefix] PASS actual-unused-callback-null=true forbidden-business-field-branch-constant-cancel=5");
    }

    /**
     * 全目标用真实游戏/模组依赖闭包链接；只对47个变换目标 child-first，其他类型由
     * 本轮精确 classpath 提供。define/resolve/成员解析均不触发类初始化，此处没有
     * Knot、class tweaker 或游戏线程；它们仍须独立集成/设备证据。
     */
    private static final class VerifyLoader extends ClassLoader {
        private final Map<String, byte[]> definitions;
        VerifyLoader(Map<String, byte[]> definitions) { super(CreateThreadingMixinTest.class.getClassLoader()); this.definitions = definitions; }
        @Override protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
            if (!definitions.containsKey(name)) return super.loadClass(name, resolve);
            synchronized (getClassLoadingLock(name)) {
                Class<?> result = findLoadedClass(name);
                if (result == null) { byte[] value = definitions.get(name); result = defineClass(name, value, 0, value.length); }
                if (resolve) resolveClass(result);
                return result;
            }
        }
        Class<?> defineAndResolve(String name) throws ClassNotFoundException { return loadClass(name, true); }
    }

    /** public helper 的实际符号必须能和固定原版公开 ABI 对接，不能只看方法描述符字符串。 */
    private static void publicHelperAbi() throws Exception {
        ClassLoader loader = CreateThreadingMixinTest.class.getClassLoader();
        Class<?> bridge = Class.forName("com.amcl.compat.CreateFlyPacketThreading26", false, loader);
        Class<?> packet = Class.forName("net.minecraft.network.protocol.Packet", false, loader);
        for (String side : List.of("client", "server")) {
            Class<?> listener = Class.forName("net.minecraft.network.protocol.game." + (side.equals("client") ? "Client" : "Server") + "GamePacketListener", false, loader);
            check(Modifier.isPublic(bridge.getMethod(side, packet, listener).getModifiers()), "helper not publicly linkable " + side);
        }
        Class<?> minecraft = Class.forName("net.minecraft.client.Minecraft", false, loader);
        check(Modifier.isPublic(minecraft.getMethod("getInstance").getModifiers()), "Minecraft.getInstance not public");
        check(Modifier.isPublic(minecraft.getMethod("packetProcessor").getModifiers()), "Minecraft.packetProcessor not public");
        Class<?> listener = Class.forName("net.minecraft.server.network.ServerGamePacketListenerImpl", false, loader);
        check(Modifier.isPublic(listener.getField("player").getModifiers()), "server player access not public");
        Class<?> player = Class.forName("net.minecraft.server.level.ServerPlayer", false, loader);
        check(Modifier.isPublic(player.getMethod("level").getModifiers()), "ServerPlayer.level not public");
    }

    /** JVM验证的受控负例：缺依赖的父类必须产生链接失败，非法栈图必须被JVM拒绝。 */
    private static void jvmNegativeControls() throws Exception {
        org.objectweb.asm.ClassWriter writer = new org.objectweb.asm.ClassWriter(0);
        writer.visit(65, Opcodes.ACC_PUBLIC, "com/amcl/compat/test/BrokenParent", null, "missing/NotPresent", null); writer.visitEnd();
        try {
            new VerifyLoader(Map.of("com.amcl.compat.test.BrokenParent", writer.toByteArray())).defineAndResolve("com.amcl.compat.test.BrokenParent");
            throw new AssertionError("Missing dependency linkage negative control accepted");
        } catch (NoClassDefFoundError expected) { /* 实际JVM链接失败，而非本方字符串判定。 */ }
        writer = new org.objectweb.asm.ClassWriter(0);
        writer.visit(65, Opcodes.ACC_PUBLIC, "com/amcl/compat/test/BrokenStack", null, "java/lang/Object", null);
        var method = writer.visitMethod(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, "broken", "()V", null, null);
        method.visitCode(); method.visitInsn(Opcodes.ICONST_0); method.visitInsn(Opcodes.ARETURN); method.visitMaxs(1, 0); method.visitEnd(); writer.visitEnd();
        try {
            Class<?> broken = new VerifyLoader(Map.of("com.amcl.compat.test.BrokenStack", writer.toByteArray())).defineAndResolve("com.amcl.compat.test.BrokenStack");
            broken.getDeclaredMethods(); throw new AssertionError("Invalid JVM bytecode negative control accepted");
        } catch (VerifyError expected) { /* 成员解析触发实际JVM字节码验证。 */ }
    }

    private static String digest(byte[] value) throws Exception {
        return java.util.HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(value));
    }

    /**
     * 真实发布包的旧 AllHandle ABI 不经变换，仍独立记录公开签名以便附属模组复验。
     * 不把新上游移除/改变方法签名误当成兼容目标：本方只改 packet 入口。
     */
    private static List<String> oldBusinessAbi(Map<String, byte[]> old) {
        List<String> result = new ArrayList<>();
        for (String name : List.of("com/zurrtum/create/AllHandle.class", "com/zurrtum/create/AllClientHandle.class", "com/zurrtum/create/client/AllHandle.class")) {
            for (MethodNode method : node(old.get(name)).methods)
                if ((method.access & (Opcodes.ACC_PUBLIC | Opcodes.ACC_PROTECTED)) != 0)
                    result.add(name + ":" + method.name + method.desc);
        }
        return result;
    }

    /** 主过程把每个目标的原始、变换字节和覆盖表外置，供后续 Loader/设备收据关联。 */
    public static void main(String[] args) throws Exception {
        check(args.length == 4, "usage: old.jar fixed.jar minecraft.jar external-output");
        Path output = Path.of(args[3]); Files.createDirectories(output);
        CreateFlyThreadingProfile profile = new CreateFlyThreadingProfile();
        Map<String, byte[]> old = readEntries(Path.of(args[0]), profile.entries());
        Map<String, byte[]> fixed = readEntries(Path.of(args[1]), profile.entries());
        Map<String, byte[]> minecraft = readEntries(Path.of(args[2]), profile.minecraftEntries());
        profiles(profile, old, fixed);
        visibleProfiles(profile, old, fixed, minecraft);
        String urlResource = profile.targets("client").iterator().next().replace('.', '/') + ".class";
        resourceUrls(output, urlResource, old.get(urlResource));
        MixinBootstrap.init(); MixinEnvironment.getDefaultEnvironment().setSide(MixinEnvironment.Side.CLIENT);
        Mixins.addConfiguration("amcl-threading-test.mixins.json");
        Constructor<?> factory = Class.forName("org.spongepowered.asm.mixin.transformer.MixinTransformer").getDeclaredConstructor();
        factory.setAccessible(true); IMixinTransformer transformer = (IMixinTransformer) factory.newInstance();
        List<String> coverage = new ArrayList<>();
        Map<String, byte[]> transformed = new LinkedHashMap<>();
        for (String side : List.of("client", "server")) {
            for (String target : profile.targets(side)) {
                String entry = target.replace('.', '/') + ".class";
                byte[] original = old.get(entry);
                byte[] changed = transformer.transformClassBytes(target, target, original);
                check(!Arrays.equals(original, changed), "target not transformed: " + target);
                ClassNode before = node(original), after = node(changed);
                check(methods(after).containsAll(methods(before)), "old packet ABI removed: " + target);
                check(bridgeCalls(before).equals(bridgeCalls(after)), "bridge semantics modified: " + target);
                verify(after);
                transformed.put(target, changed);
                Path destination = output.resolve(entry); Files.createDirectories(destination.getParent()); Files.write(destination, changed);
                coverage.add(side + "\t" + target + "\t" + digest(original) + "\t" + digest(changed)
                    + "\tactual-mixin\tasm-dataflow\told-abi-preserved");
            }
        }
        check(coverage.size() == 47, "incomplete client/server coverage");
        guardPrefixControls(transformed);
        jvmNegativeControls(); publicHelperAbi();
        VerifyLoader verifier = new VerifyLoader(transformed);
        List<String> jvm = new ArrayList<>();
        for (String side : List.of("client", "server")) {
            String parameter = "net.minecraft.network.protocol.game." + (side.equals("client") ? "Client" : "Server") + "GamePacketListener";
            Class<?> listenerType = Class.forName(parameter, false, verifier);
            Class<?> baseListener = Class.forName("net.minecraft.network.PacketListener", false, verifier);
            for (String target : profile.targets(side)) {
                Class<?> defined = verifier.defineAndResolve(target);
                defined.getDeclaredConstructors(); defined.getDeclaredFields(); defined.getDeclaredMethods();
                check(defined.getDeclaredMethod("handle", listenerType) != null, "JVM typed ABI missing " + target);
                check(defined.getDeclaredMethod("handle", baseListener).isBridge(), "JVM bridge ABI missing " + target);
                String marker = "amcl$guard" + (side.equals("client") ? "Client" : "Server") + "Thread";
                check(Arrays.stream(defined.getDeclaredMethods()).filter(method -> method.getName().contains(marker)).count() == 1,
                    "JVM injected handler ABI mismatch " + target);
                jvm.add(side + "\t" + target + "\tdefine-resolve-declared-abi\tno-initialization\tplain-child-loader\tactual-knot=false");
            }
        }
        check(jvm.size() == 47, "incomplete JVM verification coverage");
        Files.write(output.resolve("coverage.tsv"), coverage, StandardCharsets.UTF_8);
        Files.write(output.resolve("jvm-coverage.tsv"), jvm, StandardCharsets.UTF_8);
        Files.write(output.resolve("old-business-abi.txt"), oldBusinessAbi(old), StandardCharsets.UTF_8);
        System.out.println("[create-threading-mixin] PASS fixed old/new profile, all " + profile.entries().size()
            + " changed/missing + visible-class negatives, withdrawal, real Mixin client28/server19, typed+bridge ABI, ASM dataflow, plain-JVM47 define/resolve/declared ABI without initialization; no Knot/class-tweaker/world validation");
    }
}
