package com.amcl.audioagent;

import java.lang.instrument.Instrumentation;
import java.lang.reflect.Proxy;
import java.net.URL;
import java.security.MessageDigest;
import java.util.*;
import com.amcl.audioagent.internal.asm.*;

/**
 * 注入策略反例。合成类仅用于精确安排 JDK 枚举/错误路径，不能冒充真实 Forge 资格。
 * 真 Forge/SecureJar/ModuleLayer 的首次定义与 SPI 链由独立 loader qualification 测试覆盖。
 */
public final class AudioServicePolicyTest implements Opcodes {
    private static final String TARGET = "cpw/mods/cl/ModuleClassLoader";
    private static final String SERVICE = "META-INF/services/javax.sound.sampled.spi.MixerProvider";
    private static final String DESC = "(Ljava/lang/String;)Ljava/util/Enumeration;";
    private static int checks;
    private static void check(boolean value, String label) { checks++; if (!value) throw new AssertionError(label); }
    private static String hash(byte[] bytes) throws Exception {
        StringBuilder value = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(bytes)) value.append(String.format(Locale.ROOT, "%02x", b & 255));
        return value.toString();
    }
    /** 合成同名最小类，固定的 own 枚举允许检查先后顺序和普通资源不被合并。 */
    private static byte[] sample(boolean method) {
        ClassWriter writer = new ClassWriter(ClassWriter.COMPUTE_MAXS);
        writer.visit(V1_8, ACC_PUBLIC, TARGET, null, "java/lang/ClassLoader", null);
        writer.visitField(ACC_PRIVATE, "own", "Ljava/util/List;", null, null).visitEnd();
        MethodVisitor init = writer.visitMethod(ACC_PUBLIC, "<init>", "(Ljava/util/List;)V", null, null);
        init.visitCode(); init.visitVarInsn(ALOAD, 0);
        init.visitMethodInsn(INVOKESPECIAL, "java/lang/ClassLoader", "<init>", "()V", false);
        init.visitVarInsn(ALOAD, 0); init.visitVarInsn(ALOAD, 1);
        init.visitFieldInsn(PUTFIELD, TARGET, "own", "Ljava/util/List;"); init.visitInsn(RETURN); init.visitMaxs(0, 0); init.visitEnd();
        if (method) {
            // 这个原始方法会留下可观察标记，证明非白名单仍走原路，白名单新入口没有先取得旧类锁。
            MethodVisitor load = writer.visitMethod(ACC_PROTECTED, "loadClass", "(Ljava/lang/String;Z)Ljava/lang/Class;",
                null, new String[]{"java/lang/ClassNotFoundException"});
            load.visitCode(); load.visitLdcInsn("amcl.audio.test.originalClass"); load.visitVarInsn(ALOAD, 1);
            load.visitMethodInsn(INVOKESTATIC, "java/lang/System", "setProperty", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;", false);
            load.visitInsn(POP); load.visitVarInsn(ALOAD, 0); load.visitVarInsn(ALOAD, 1); load.visitVarInsn(ILOAD, 2);
            load.visitMethodInsn(INVOKESPECIAL, "java/lang/ClassLoader", "loadClass", "(Ljava/lang/String;Z)Ljava/lang/Class;", false);
            load.visitInsn(ARETURN); load.visitMaxs(0, 0); load.visitEnd();
            MethodVisitor resources = writer.visitMethod(ACC_PUBLIC, "getResources", DESC, null, new String[]{"java/io/IOException"});
            resources.visitCode(); resources.visitVarInsn(ALOAD, 0); resources.visitFieldInsn(GETFIELD, TARGET, "own", "Ljava/util/List;");
            resources.visitMethodInsn(INVOKESTATIC, "java/util/Collections", "enumeration", "(Ljava/util/Collection;)Ljava/util/Enumeration;", false);
            resources.visitInsn(ARETURN); resources.visitMaxs(0, 0); resources.visitEnd();
        }
        writer.visitEnd(); return writer.toByteArray();
    }
    /** 目标只依赖 JDK，不需要把 Agent helper 放进目标域；每个变体由独立 loader 首次定义。 */
    private static Class<?> define(final byte[] bytes) {
        return new ClassLoader(AudioServicePolicyTest.class.getClassLoader()) {
            Class<?> define() { return defineClass(TARGET.replace('/', '.'), bytes, 0, bytes.length); }
        }.define();
    }
    private static AudioServiceAgent.ServiceTransformer transformer(byte[] bytes) throws Exception {
        Map<String, String> profile = new HashMap<String, String>(); profile.put(hash(bytes), "explicit-unit-fixture");
        return new AudioServiceAgent.ServiceTransformer(profile);
    }
    private static List<String> resources(ClassLoader loader, String name) throws Exception {
        List<String> values = new ArrayList<String>(); Enumeration<URL> entries = loader.getResources(name);
        while (entries.hasMoreElements()) values.add(entries.nextElement().toExternalForm()); return values;
    }
    public static void main(String[] args) throws Exception {
        byte[] original = sample(true);
        AudioServiceAgent.ServiceTransformer transformer = transformer(original);
        check(transformer.transform(null, "other/Loader", null, null, original) == null, "non-target class remains unchanged");
        byte[] transformed = transformer.transform(null, TARGET, null, null, original);
        check(transformed != null, "explicit test identity produces transformed bytes");
        // 本地指向启动器的 URL 与父枚举重复；相同 externalForm 必须只留下首次原 URL。
        URL local = new URL("file:/amcl-unit-local-provider");
        String fault = System.getProperty("amcl.audio.test.parentFault", "");
        List<URL> own = new ArrayList<URL>(); own.add(local);
        if (fault.isEmpty()) own.add(ClassLoader.getSystemClassLoader().getResource(SERVICE));
        Class<?> target = define(transformed);
        ClassLoader loader = (ClassLoader) target.getConstructor(List.class).newInstance(own);
        // 直接调用受保护的 resolve=true 方法；这里只对显式合成的未命名测试类做反射，不给真 Forge 添加 opens。
        java.lang.reflect.Method load = target.getDeclaredMethod("loadClass", String.class, boolean.class); load.setAccessible(true);
        String initClass = "com.amcl.audio.AudioBackend$UnitInitialization";
        Class<?> canonical = Class.forName(initClass, false, ClassLoader.getSystemClassLoader());
        System.clearProperty("amcl.audio.test.originalClass"); System.clearProperty("amcl.audio.test.initialized");
        check(load.invoke(loader, initClass, true) == canonical, "resolve=true returns system canonical nested class");
        check(System.getProperty("amcl.audio.test.initialized") == null, "resolve=true canonical delegation does not initialize class");
        check(System.getProperty("amcl.audio.test.originalClass") == null, "canonical request bypasses original loader method");
        check(load.invoke(loader, "java.lang.String", true) == String.class, "ordinary class still resolves through original method");
        check("java.lang.String".equals(System.getProperty("amcl.audio.test.originalClass")), "ordinary class keeps observable original path");
        System.clearProperty("amcl.audio.test.originalClass"); boolean missing = false;
        try { load.invoke(loader, "com.amcl.audio.OhosClip$NoSuchNested", false); }
        catch (java.lang.reflect.InvocationTargetException expected) { missing = expected.getCause() instanceof ClassNotFoundException; }
        check(missing && System.getProperty("amcl.audio.test.originalClass") == null,
            "missing canonical nested class reports CNFE without original fallback");
        List<String> merged = resources(loader, SERVICE);
        check(merged.get(0).equals(local.toExternalForm()), "original provider URL stays first");
        if (fault.isEmpty()) {
            // Java8 的 rt.jar 还可能提供自己的 SPI 描述；保留父枚举全集而非假定父资源只有一个。
            LinkedHashSet<String> expected = new LinkedHashSet<String>();
            for (URL url : own) expected.add(url.toExternalForm());
            expected.addAll(resources(ClassLoader.getSystemClassLoader(), SERVICE));
            check(merged.equals(new ArrayList<String>(expected)) && new HashSet<String>(merged).size() == merged.size(),
                "all parent resources merge in original order and duplicate system URL is emitted once");
            check(merged.get(1).equals(own.get(1).toExternalForm()), "original system duplicate retains its existing position");
        } else check(merged.size() == 1, "new parent IO/security failure returns untouched original enumeration");
        check(resources(loader, "java/lang/String.class").size() == own.size(), "ordinary resource never consults system enumeration");

        check(transformer.transform(null, TARGET, Object.class, null, original) == null, "redefinition is never transformed");
        check("not-covered:redefinition".equals(System.getProperty("amcl.audio.service.agent.status")), "redefinition has named uncovered diagnostic");
        check(new AudioServiceAgent.ServiceTransformer(Collections.<String, String>emptyMap())
            .transform(null, TARGET, null, null, original) == null, "unrecognized byte identity remains original");
        check("not-covered:class-sha256".equals(System.getProperty("amcl.audio.service.agent.status")), "unrecognized identity is not marked prepared");
        byte[] wrongAbi = sample(false);
        check(transformer(wrongAbi).transform(null, TARGET, null, null, wrongAbi) == null, "matching test hash cannot bypass wrong method ABI");
        check("not-covered:transform-failed".equals(System.getProperty("amcl.audio.service.agent.status")), "failed generation is not marked prepared");

        System.clearProperty("amcl.audio.service.schema"); System.clearProperty("amcl.audio.enabled");
        AudioServiceAgent.premain(null, null);
        check("disabled".equals(System.getProperty("amcl.audio.service.agent.status")), "missing early schema disables installation before instrument access");
        System.setProperty("amcl.audio.service.schema", "1"); System.setProperty("amcl.audio.enabled", "false");
        AudioServiceAgent.premain(null, null);
        check("disabled".equals(System.getProperty("amcl.audio.service.agent.status")), "audio disabled leaves loader unchanged");
        System.setProperty("amcl.audio.enabled", "true");
        Instrumentation instrumentation = (Instrumentation) Proxy.newProxyInstance(AudioServicePolicyTest.class.getClassLoader(),
            new Class<?>[]{Instrumentation.class}, (proxy, method, parameters) -> {
                if (method.getName().equals("getAllLoadedClasses")) return new Class<?>[]{target};
                if (method.getName().equals("addTransformer")) throw new AssertionError("late target must not install a transformer");
                return null;
            });
        AudioServiceAgent.premain(null, instrumentation);
        check("late-definition".equals(System.getProperty("amcl.audio.service.agent.status")), "already defined target produces named uncovered state");
        System.out.println("PASS audio service injection policy checks=" + checks + " parentFault=" + fault + " runtime=" + System.getProperty("java.version"));
    }
}
