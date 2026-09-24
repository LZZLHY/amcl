package com.amcl.launcher;

import java.io.*;
import java.net.URL;
import java.net.URLClassLoader;
import java.util.jar.*;

/**
 * AmclClassLoader 单元测试。
 * 基于规划文档的接口契约编写。
 *
 * 测试要点：
 * - 从 URL 数组创建 ClassLoader
 * - 能加载 jar 中的类
 * - 动态添加 jar（addJar）
 * - parent delegation 行为正确
 * - 不同 ClassLoader 实例隔离
 */
public class AmclClassLoaderTest {

    static int passed = 0;
    static int failed = 0;
    static File tempDir;
    /** 测试兼容helper时明确提供已审计MG身份；缺失/错误身份另由隔离ClassLoader负例覆盖。 */
    static final String AUDITED_MG_IDENTITY = "schema=1:source=f52379eb660209ba03689afeb46b2e1409212e38:worktree="
        + "ce84dd8c90b93bfe636a1955d686930e68e2fb474b6b877ac9add7cbc2ddbaf0:state=clean:options="
        + "0000000000000000000000000000000000000000000000000000000000000000";

    public static void main(String[] args) throws Exception {
        String originalIdentity = System.getProperty("amcl.graphics.implementation");
        System.setProperty("amcl.graphics.implementation", AUDITED_MG_IDENTITY);
        tempDir = new File(System.getProperty("java.io.tmpdir"), "amcl_cl_test_" + System.currentTimeMillis());
        tempDir.mkdirs();

        System.out.println("=== AmclClassLoader Tests ===\n");

        try {
            testCreateWithEmptyUrls();
            testCreateWithUrls();
            testLoadClassFromJar();
            testAddJarDynamic();
            testParentDelegation();
            testIsolation();
            testLoadNonExistentClass();
            testLoadFromMultipleJars();
            testGameMainOwnedByAmclLoader();
            testParentVisibleGameMainIsRejected();
            testTransformedClassPreservesJarSigners();
            testBytecodeInvocationPatch();
            testBytecodeFieldReadPatch();
            testChunkQuotaFieldReadPatch();
            testSubmitDepthConstantPatch();
            testSubmitDepthCountMismatchFails();
            testSubmitDepthComposesWithInvocationPatch();
            testUploadTimingDeferAndFlushOrder();
            testUploadTimingStaleWorldDrop();
            testUploadTimingDoubleCallSiteFails();
            testBoundedTerrainHeapPolicy();
            testUnknownTerrainClassIsUnchanged();
            testPersistentStagingSelectionPolicy();
            testPersistentStagingBytecodePatch();
            testAllowTerrainAppendKeepsPhysicalGuard();
            testStagingCapacityGuardBytecodePatch();
            testFenceDelayedRangeRetirement();
            testRetirementBatching();
            testRetirementQueueIsBounded();
            testFenceFailureFallsBackWithoutLeak();
            testDesktopExcludesMobileTerrainPatches();
        } finally {
            // 清理临时文件
            deleteRecursive(tempDir);
            if (originalIdentity == null) System.clearProperty("amcl.graphics.implementation");
            else System.setProperty("amcl.graphics.implementation", originalIdentity);
        }

        System.out.println("\n=== Results: " + passed + " passed, " + failed + " failed ===");
        if (failed > 0) System.exit(1);
    }

    static void testCreateWithEmptyUrls() throws Exception {
        AmclClassLoader cl = new AmclClassLoader(new URL[0], ClassLoader.getSystemClassLoader());
        assertNotNull("empty urls creates loader", cl);
        // 应该能加载 JDK 标准类（通过 parent delegation）
        Class<?> c = cl.loadClass("java.lang.String");
        assertNotNull("can load String via parent", c);
        cl.close();
    }

    static void testDesktopExcludesMobileTerrainPatches() throws Exception {
        String oldPlatform = System.getProperty("amcl.platform.ohos");
        String oldBackend = System.getProperty("amcl.gl.backend");
        String oldProfile = System.getProperty("amcl.graphics.profile");
        String oldIdentity = System.getProperty("amcl.graphics.implementation");
        String auditedIdentity = AUDITED_MG_IDENTITY;
        try {
            System.setProperty("amcl.platform.ohos", "true");
            System.setProperty("amcl.graphics.implementation", auditedIdentity);
            System.clearProperty("amcl.graphics.profile");
            URL source = AmclClassLoader.class.getProtectionDomain().getCodeSource().getLocation();
            for (String backend : new String[]{"nativegl", "mobileglues", "", "mobilegl", "gl4es", "unrecognised"}) {
                System.setProperty("amcl.gl.backend", backend);
                try (URLClassLoader isolated = new URLClassLoader(new URL[]{source}, null)) {
                    Class<?> cls = Class.forName("com.amcl.launcher.AmclClassLoader", true, isolated);
                    java.lang.reflect.Field field = cls.getDeclaredField("TERRAIN_COMPATIBILITY_ENABLED");
                    field.setAccessible(true);
                    assertEquals("terrain transforms gated by backend " + backend,
                        Boolean.valueOf(backend.isEmpty() || "mobileglues".equals(backend)), Boolean.valueOf(field.getBoolean(null)));
                }
            }
            System.setProperty("amcl.gl.backend", "");
            System.setProperty("amcl.graphics.profile", "minecraft-vulkan");
            try (URLClassLoader isolated = new URLClassLoader(new URL[]{source}, null)) {
                Class<?> cls = Class.forName("com.amcl.launcher.AmclClassLoader", true, isolated);
                java.lang.reflect.Field terrain = cls.getDeclaredField(
                    "TERRAIN_COMPATIBILITY_ENABLED");
                terrain.setAccessible(true);
                java.lang.reflect.Field chunk = cls.getDeclaredField("CHUNK_QUOTA_ENABLED");
                chunk.setAccessible(true);
                assertEquals("Vulkan disables GL terrain transforms",
                    Boolean.FALSE, Boolean.valueOf(terrain.getBoolean(null)));
                assertEquals("MG quota must not alter Vulkan",
                    Boolean.FALSE, Boolean.valueOf(chunk.getBoolean(null)));
            }
            // 每次新 ClassLoader 重新初始化静态策略，证明 MobileGL 不会因旧 marker 仍为 MG
            // 而启用任何补丁家族；未知 profile 同样关闭，MobileGlues 正向对照仍开启。
            System.setProperty("amcl.gl.backend", "mobileglues");
            for (String profile : new String[]{"mobilegl", "nativegl", "gl4es", "unrecognised", "mobileglues"}) {
                System.setProperty("amcl.graphics.profile", profile);
                try (URLClassLoader isolated = new URLClassLoader(new URL[]{source}, null)) {
                    Class<?> cls = Class.forName("com.amcl.launcher.AmclClassLoader", true, isolated);
                    for (String name : new String[]{"TERRAIN_COMPATIBILITY_ENABLED", "CHUNK_QUOTA_ENABLED",
                            "SUBMIT_DEPTH_ENABLED", "UPLOAD_TIMING_ENABLED"}) {
                        java.lang.reflect.Field flag = cls.getDeclaredField(name);
                        flag.setAccessible(true);
                        assertEquals(profile + " scoped " + name, Boolean.valueOf("mobileglues".equals(profile)),
                            Boolean.valueOf(flag.getBoolean(null)));
                    }
                }
            }
            // 真正的loader静态初始化验证实现范围，不用一个独立布尔模型代替生产开关。
            System.setProperty("amcl.graphics.profile", "mobileglues");
            for (String identity : new String[]{"", "2.0.0", auditedIdentity.replace("f52379", "000000"),
                    auditedIdentity.replace("ce84dd", "000000"), auditedIdentity.replace("state=clean", "state=dirty"),
                    auditedIdentity + ":extra=1", auditedIdentity}) {
                System.setProperty("amcl.graphics.implementation", identity);
                try (URLClassLoader isolated = new URLClassLoader(new URL[]{source}, null)) {
                    Class<?> cls = Class.forName("com.amcl.launcher.AmclClassLoader", true, isolated);
                    for (String name : new String[]{"TERRAIN_COMPATIBILITY_ENABLED", "CHUNK_QUOTA_ENABLED",
                            "SUBMIT_DEPTH_ENABLED", "UPLOAD_TIMING_ENABLED"}) {
                        java.lang.reflect.Field flag = cls.getDeclaredField(name); flag.setAccessible(true);
                        assertEquals("exact implementation " + name, Boolean.valueOf(identity.equals(auditedIdentity)),
                            Boolean.valueOf(flag.getBoolean(null)));
                    }
                }
            }
        } finally {
            if (oldPlatform == null) System.clearProperty("amcl.platform.ohos"); else System.setProperty("amcl.platform.ohos", oldPlatform);
            if (oldBackend == null) System.clearProperty("amcl.gl.backend"); else System.setProperty("amcl.gl.backend", oldBackend);
            if (oldProfile == null) System.clearProperty("amcl.graphics.profile"); else System.setProperty("amcl.graphics.profile", oldProfile);
            if (oldIdentity == null) System.clearProperty("amcl.graphics.implementation"); else System.setProperty("amcl.graphics.implementation", oldIdentity);
        }
    }

    static void testCreateWithUrls() throws Exception {
        File jar = createTestJar("test1", "com.test.Hello", "public class Hello { public static String greet() { return \"hello\"; } }");
        URL[] urls = { jar.toURI().toURL() };
        AmclClassLoader cl = new AmclClassLoader(urls, ClassLoader.getSystemClassLoader());
        assertNotNull("urls creates loader", cl);
        cl.close();
    }

    static void testLoadClassFromJar() throws Exception {
        File jar = createTestJar("test2", "com.test.Greeter",
            "public class Greeter { public static String greet() { return \"world\"; } }");
        URL[] urls = { jar.toURI().toURL() };
        AmclClassLoader cl = new AmclClassLoader(urls, ClassLoader.getSystemClassLoader());

        Class<?> c = cl.loadClass("com.test.Greeter");
        assertNotNull("loaded Greeter", c);
        assertEquals("class name", "com.test.Greeter", c.getName());

        // 调用静态方法验证类可用
        Object result = c.getMethod("greet").invoke(null);
        assertEquals("greet result", "world", result);
        cl.close();
    }

    static void testAddJarDynamic() throws Exception {
        File jar1 = createTestJar("dyn1", "com.dyn.A",
            "public class A { public static int value() { return 42; } }");
        File jar2 = createTestJar("dyn2", "com.dyn.B",
            "public class B { public static int value() { return 99; } }");

        // 只用 jar1 创建
        URL[] urls = { jar1.toURI().toURL() };
        AmclClassLoader cl = new AmclClassLoader(urls, ClassLoader.getSystemClassLoader());

        // jar1 中的类可以加载
        Class<?> a = cl.loadClass("com.dyn.A");
        assertNotNull("loaded A", a);

        // jar2 中的类还不能加载
        try {
            cl.loadClass("com.dyn.B");
            fail("B should not be loadable yet");
        } catch (ClassNotFoundException e) {
            pass("B not found before addJar");
        }

        // 动态添加 jar2
        cl.addURL(jar2.toURI().toURL());

        // 现在 B 应该可以加载了
        Class<?> b = cl.loadClass("com.dyn.B");
        assertNotNull("loaded B after addJar", b);
        Object val = b.getMethod("value").invoke(null);
        assertEquals("B.value()", 99, val);
        cl.close();
    }

    static void testParentDelegation() throws Exception {
        // AmclClassLoader 的 parent 是系统 ClassLoader
        // JDK 类应该通过 parent 加载，不是通过 AmclClassLoader 自己
        AmclClassLoader cl = new AmclClassLoader(new URL[0], ClassLoader.getSystemClassLoader());

        Class<?> stringClass = cl.loadClass("java.lang.String");
        // String 应该由 bootstrap ClassLoader 加载，不是 AmclClassLoader
        assertTrue("String loaded by bootstrap, not AmclClassLoader",
            stringClass.getClassLoader() == null); // bootstrap CL returns null
        cl.close();
    }

    static void testIsolation() throws Exception {
        File jar = createTestJar("iso", "com.iso.Counter",
            "public class Counter { public static int count = 0; public static int inc() { return ++count; } }");

        // 两个独立的 ClassLoader 加载同一个 jar
        URL[] urls = { jar.toURI().toURL() };
        AmclClassLoader cl1 = new AmclClassLoader(urls, ClassLoader.getSystemClassLoader());
        AmclClassLoader cl2 = new AmclClassLoader(urls, ClassLoader.getSystemClassLoader());

        Class<?> c1 = cl1.loadClass("com.iso.Counter");
        Class<?> c2 = cl2.loadClass("com.iso.Counter");

        // 两个类应该是不同的 Class 对象（不同 ClassLoader）
        assertTrue("different Class objects", c1 != c2);

        // 静态变量应该隔离
        c1.getMethod("inc").invoke(null);
        c1.getMethod("inc").invoke(null);
        Object val1 = c1.getField("count").get(null);
        Object val2 = c2.getField("count").get(null);
        assertEquals("cl1 counter", 2, val1);
        assertEquals("cl2 counter", 0, val2); // cl2 的 counter 未被修改

        cl1.close();
        cl2.close();
    }

    static void testLoadNonExistentClass() throws Exception {
        AmclClassLoader cl = new AmclClassLoader(new URL[0], ClassLoader.getSystemClassLoader());
        try {
            cl.loadClass("com.nonexistent.Foo");
            fail("should throw ClassNotFoundException");
        } catch (ClassNotFoundException e) {
            pass("ClassNotFoundException for non-existent class");
        }
        cl.close();
    }

    static void testLoadFromMultipleJars() throws Exception {
        File jar1 = createTestJar("multi1", "com.multi.X",
            "public class X { public static String name() { return \"X\"; } }");
        File jar2 = createTestJar("multi2", "com.multi.Y",
            "public class Y { public static String name() { return \"Y\"; } }");
        File jar3 = createTestJar("multi3", "com.multi.Z",
            "public class Z { public static String name() { return \"Z\"; } }");

        URL[] urls = { jar1.toURI().toURL(), jar2.toURI().toURL(), jar3.toURI().toURL() };
        AmclClassLoader cl = new AmclClassLoader(urls, ClassLoader.getSystemClassLoader());

        assertEquals("X.name()", "X", cl.loadClass("com.multi.X").getMethod("name").invoke(null));
        assertEquals("Y.name()", "Y", cl.loadClass("com.multi.Y").getMethod("name").invoke(null));
        assertEquals("Z.name()", "Z", cl.loadClass("com.multi.Z").getMethod("name").invoke(null));
        cl.close();
    }

    static void testGameMainOwnedByAmclLoader() throws Exception {
        File jar = createTestJar("owned-main", "com.ownership.GameMain",
            "public class GameMain { public static void main(String[] args) {} }");
        URLClassLoader bootstrap = new URLClassLoader(new URL[0], ClassLoader.getSystemClassLoader());
        AmclClassLoader cl = new AmclClassLoader(new URL[] {jar.toURI().toURL()}, bootstrap);
        cl.requireIsolatedGameMain("com.ownership.GameMain");
        Class<?> main = cl.loadClass("com.ownership.GameMain");
        cl.requireOwnedGameMain(main);
        assertTrue("isolated game main is owned by AmclClassLoader", main.getClassLoader() == cl);
        cl.close();
        bootstrap.close();
    }

    static void testParentVisibleGameMainIsRejected() throws Exception {
        File jar = createTestJar("leaked-main", "com.ownership.LeakedMain",
            "public class LeakedMain { public static void main(String[] args) {} }");
        URLClassLoader bootstrap = new URLClassLoader(
            new URL[] {jar.toURI().toURL()}, ClassLoader.getSystemClassLoader());
        AmclClassLoader cl = new AmclClassLoader(new URL[] {jar.toURI().toURL()}, bootstrap);
        try {
            cl.requireIsolatedGameMain("com.ownership.LeakedMain");
            fail("parent-visible game main must be rejected");
        } catch (IllegalStateException expected) {
            assertTrue("parent-visible game main reports bootstrap ownership",
                expected.getMessage().contains("visible from bootstrap parent"));
        }
        cl.close();
        bootstrap.close();
    }

    static void testTransformedClassPreservesJarSigners() throws Exception {
        File jar = createSignedTestJar("signed-origin", "com.signed.Regular",
            "public class Regular { public static int value() { return 1; } }",
            "com.signed.Transformed",
            "public class Transformed { public static int value() { return 2; } }");
        AmclClassLoader cl = new AmclClassLoader(
            new URL[] {jar.toURI().toURL()}, ClassLoader.getSystemClassLoader());

        Class<?> regular = cl.loadClass("com.signed.Regular");
        URL resource = cl.findResource("com/signed/Transformed.class");
        AmclClassLoader.ClassOrigin origin = AmclClassLoader.readClassOrigin(resource);
        Class<?> transformed = cl.defineTransformedClass(
            "com.signed.Transformed", origin.bytes, origin);

        assertEquals("signed transformed class remains executable", 2,
            transformed.getMethod("value").invoke(null));
        assertTrue("regular class has JAR certificates",
            regular.getProtectionDomain().getCodeSource().getCertificates() != null);
        assertTrue("transformed class has JAR certificates",
            transformed.getProtectionDomain().getCodeSource().getCertificates() != null);
        assertEquals("transformed class keeps the signed JAR code source",
            regular.getProtectionDomain().getCodeSource().getLocation(),
            transformed.getProtectionDomain().getCodeSource().getLocation());
        cl.close();
    }

    static int patchedFreeCalls;

    public static void patchedFree(Object allocator, Object allocation) {
        patchedFreeCalls++;
    }

    public static class BytecodeAllocator {
        public int calls;
        public void free(Object allocation) { calls++; }
    }

    public static class BytecodeSubject {
        public static void invoke(BytecodeAllocator allocator, Object allocation) {
            allocator.free(allocation);
        }
    }

    static class ByteArrayClassLoader extends ClassLoader {
        ByteArrayClassLoader(ClassLoader parent) { super(parent); }
        Class<?> define(String name, byte[] bytes) {
            return defineClass(name, bytes, 0, bytes.length);
        }
    }

    static void testBytecodeInvocationPatch() throws Exception {
        String subjectName = BytecodeSubject.class.getName();
        String resource = subjectName.replace('.', '/') + ".class";
        byte[] original;
        try (InputStream input = AmclClassLoaderTest.class.getClassLoader().getResourceAsStream(resource)) {
            original = TerrainCompatibilityPatcher.readAll(input);
        }
        String allocatorOwner = BytecodeAllocator.class.getName().replace('.', '/');
        byte[] patched = TerrainCompatibilityPatcher.patchInvocation(original,
            allocatorOwner, "free", "(Ljava/lang/Object;)V",
            AmclClassLoaderTest.class.getName().replace('.', '/'), "patchedFree",
            "(Ljava/lang/Object;Ljava/lang/Object;)V");
        patchedFreeCalls = 0;
        ByteArrayClassLoader loader = new ByteArrayClassLoader(AmclClassLoaderTest.class.getClassLoader());
        Class<?> subject = loader.define(subjectName, patched);
        BytecodeAllocator allocator = new BytecodeAllocator();
        subject.getMethod("invoke", BytecodeAllocator.class, Object.class)
            .invoke(null, allocator, new Object());
        assertEquals("patched invocation called static helper", 1, patchedFreeCalls);
        assertEquals("patched invocation bypassed immediate free", 0, allocator.calls);
    }

    public static class BytecodeHeapSubject {
        private final int heapSize;
        BytecodeHeapSubject(int heapSize) { this.heapSize = heapSize; }
        public int heapSize() { return heapSize; }
        public int heapSizeTwice() { return heapSize + heapSize; }
    }

    static void testBytecodeFieldReadPatch() throws Exception {
        String subjectName = BytecodeHeapSubject.class.getName();
        String resource = subjectName.replace('.', '/') + ".class";
        byte[] original;
        try (InputStream input = AmclClassLoaderTest.class.getClassLoader()
                .getResourceAsStream(resource)) {
            original = TerrainCompatibilityPatcher.readAll(input);
        }
        String owner = BytecodeHeapSubject.class.getName().replace('.', '/');
        String helper = TerrainHeapCompatibility.class.getName().replace('.', '/');
        byte[] patched = TerrainCompatibilityPatcher.patchFieldRead(original,
            owner, "heapSize", "I", helper, "effectiveHeapSize", "(Ljava/lang/Object;)I", 3);

        TerrainHeapCompatibility.setEnvironmentForTests(Boolean.TRUE,
            new TerrainHeapCompatibility.RendererProbe() {
                public String renderer() { return "Maleoon 920"; }
            });
        try {
            ByteArrayClassLoader loader = new ByteArrayClassLoader(
                AmclClassLoaderTest.class.getClassLoader());
            Class<?> subject = loader.define(subjectName, patched);
            java.lang.reflect.Constructor<?> constructor = subject.getDeclaredConstructor(Integer.TYPE);
            constructor.setAccessible(true);
            Object instance = constructor.newInstance(Integer.valueOf(128 * 1024 * 1024));
            assertEquals("GETFIELD patch selects the bounded vertex slab", 16 * 1024 * 1024,
                subject.getMethod("heapSize").invoke(instance));
            assertEquals("all audited field reads are replaced", 32 * 1024 * 1024,
                subject.getMethod("heapSizeTwice").invoke(instance));
        } finally {
            TerrainHeapCompatibility.resetForTests();
        }
    }

    public static class BytecodeChunkSenderSubject {
        private final boolean memoryConnection;
        BytecodeChunkSenderSubject(boolean memoryConnection) {
            this.memoryConnection = memoryConnection;
        }
        public boolean bypassesQuota() { return memoryConnection; }
    }

    /**
     * Pin (2026-08-27): the single-player chunk-send quota patch replaces the
     * lone GETFIELD memoryConnection so collectChunksToSend takes the
     * multiplayer quota branch; the opt-out property must restore the original
     * field value exactly.
     */
    static void testChunkQuotaFieldReadPatch() throws Exception {
        String subjectName = BytecodeChunkSenderSubject.class.getName();
        String resource = subjectName.replace('.', '/') + ".class";
        byte[] original;
        try (InputStream input = AmclClassLoaderTest.class.getClassLoader()
                .getResourceAsStream(resource)) {
            original = TerrainCompatibilityPatcher.readAll(input);
        }
        String owner = subjectName.replace('.', '/');
        String helper = ChunkSendQuotaCompatibility.class.getName().replace('.', '/');
        byte[] patched = TerrainCompatibilityPatcher.patchFieldRead(original,
            owner, "memoryConnection", "Z",
            helper, "memoryConnectionForQuota", "(Ljava/lang/Object;)Z", 1);

        String property = "amcl.singleplayerChunkQuota";
        String previous = System.getProperty(property);
        try {
            ByteArrayClassLoader loader = new ByteArrayClassLoader(
                AmclClassLoaderTest.class.getClassLoader());
            Class<?> subject = loader.define(subjectName, patched);
            java.lang.reflect.Constructor<?> constructor =
                subject.getDeclaredConstructor(Boolean.TYPE);
            constructor.setAccessible(true);
            Object memoryInstance = constructor.newInstance(Boolean.TRUE);

            System.clearProperty(property); // default = quota on
            ChunkSendQuotaCompatibility.resetForTests();
            assertEquals("quota default forces the multiplayer send branch", false,
                subject.getMethod("bypassesQuota").invoke(memoryInstance));

            System.setProperty(property, "false"); // opt-out = original bypass
            ChunkSendQuotaCompatibility.resetForTests();
            assertEquals("opt-out restores the original memoryConnection value", true,
                subject.getMethod("bypassesQuota").invoke(memoryInstance));
            Object remoteInstance = constructor.newInstance(Boolean.FALSE);
            assertEquals("opt-out keeps remote connections on the quota branch", false,
                subject.getMethod("bypassesQuota").invoke(remoteInstance));
        } finally {
            if (previous == null) System.clearProperty(property);
            else System.setProperty(property, previous);
            ChunkSendQuotaCompatibility.resetForTests();
        }
    }

    /**
     * Mirrors the audited submit-depth constant shapes: a long[] sized by
     * iconst_2+newarray, an Object[] sized by iconst_2+anewarray, a long
     * field seeded from ldc2_w 2L, an iconst_2 outside any array context,
     * and a modulus method that must survive the method filter untouched.
     */
    public static class BytecodeSubmitDepthSubject {
        public final long[] fences;
        public final Object[] rotations;
        public long submitIndex;
        public int plainTwo;

        public BytecodeSubmitDepthSubject() {
            fences = new long[2];
            rotations = new Object[2];
            submitIndex = 2L;
            plainTwo = 2;
        }

        public long slotOf(long index) { return index % 2L; }
        public long unpatchedSlotOf(long index) { return index % 2L; }
    }

    static byte[] readClassBytes(Class<?> subject) throws Exception {
        String resource = subject.getName().replace('.', '/') + ".class";
        try (InputStream input = AmclClassLoaderTest.class.getClassLoader()
                .getResourceAsStream(resource)) {
            return TerrainCompatibilityPatcher.readAll(input);
        }
    }

    static void testSubmitDepthConstantPatch() throws Exception {
        byte[] patched = TerrainCompatibilityPatcher.patchLongConstantLoads(
            readClassBytes(BytecodeSubmitDepthSubject.class),
            "<init>", "()V", 2L, 4L, 1, new int[] {0xbc, 0x0b}, 1);
        patched = TerrainCompatibilityPatcher.patchLongConstantLoads(patched,
            "<init>", "()V", 2L, 4L, 0, new int[] {0xbd}, 1);
        patched = TerrainCompatibilityPatcher.patchLongConstantLoads(patched,
            "slotOf", "(J)J", 2L, 4L, 1, null, 0);

        ByteArrayClassLoader loader = new ByteArrayClassLoader(
            AmclClassLoaderTest.class.getClassLoader());
        Class<?> subject = loader.define(
            BytecodeSubmitDepthSubject.class.getName(), patched);
        Object instance = subject.getDeclaredConstructor().newInstance();
        assertEquals("newarray-long site deepens to 4", 4,
            ((long[]) subject.getField("fences").get(instance)).length);
        assertEquals("anewarray site deepens to 4", 4,
            ((Object[]) subject.getField("rotations").get(instance)).length);
        assertEquals("ldc2_w seed follows the depth", 4L,
            subject.getField("submitIndex").get(instance));
        assertEquals("iconst_2 outside the declared context is preserved", 2,
            subject.getField("plainTwo").get(instance));
        assertEquals("patched modulus is 4", 2L,
            subject.getMethod("slotOf", Long.TYPE).invoke(instance, Long.valueOf(6L)));
        assertEquals("method filter keeps the sibling modulus at 2", 0L,
            subject.getMethod("unpatchedSlotOf", Long.TYPE).invoke(instance, Long.valueOf(6L)));
    }

    static void testSubmitDepthCountMismatchFails() throws Exception {
        byte[] original = readClassBytes(BytecodeSubmitDepthSubject.class);
        try {
            TerrainCompatibilityPatcher.patchLongConstantLoads(original,
                "slotOf", "(J)J", 2L, 4L, 2, null, 0);
            fail("overdeclared wide-load count must fail closed");
        } catch (IllegalArgumentException expected) {
            pass("overdeclared wide-load count fails closed");
        }
        try {
            TerrainCompatibilityPatcher.patchLongConstantLoads(original,
                "slotOf", "(J)V", 2L, 4L, 1, null, 0);
            fail("missing method must fail closed");
        } catch (IllegalArgumentException expected) {
            pass("missing method fails closed");
        }
        try {
            TerrainCompatibilityPatcher.patchLongConstantLoads(original,
                "<init>", "()V", 2L, 4L, 1, new int[] {0xbc, 0x0b}, 0);
            fail("undeclared context-matching iconst must fail closed");
        } catch (IllegalArgumentException expected) {
            pass("undeclared context-matching iconst fails closed");
        }
    }

    public static class BytecodeCombinedDepthSubject {
        public long awaitAndFree(BytecodeAllocator allocator, long index) {
            allocator.free(this);
            return index % 2L;
        }
    }

    /**
     * The real GlCommandEncoder receives patchInvocation (wait diagnostics)
     * and patchLongConstantLoads (submit depth) in that order and cannot run
     * on the host, so the composition contract is pinned on a synthetic
     * class: both transformations must hold in the final bytes.
     */
    static void testSubmitDepthComposesWithInvocationPatch() throws Exception {
        String allocatorOwner = BytecodeAllocator.class.getName().replace('.', '/');
        byte[] patched = TerrainCompatibilityPatcher.patchInvocation(
            readClassBytes(BytecodeCombinedDepthSubject.class),
            allocatorOwner, "free", "(Ljava/lang/Object;)V",
            AmclClassLoaderTest.class.getName().replace('.', '/'), "patchedFree",
            "(Ljava/lang/Object;Ljava/lang/Object;)V");
        patched = TerrainCompatibilityPatcher.patchLongConstantLoads(patched,
            "awaitAndFree", "(L" + allocatorOwner + ";J)J", 2L, 4L, 1, null, 0);

        patchedFreeCalls = 0;
        ByteArrayClassLoader loader = new ByteArrayClassLoader(
            AmclClassLoaderTest.class.getClassLoader());
        Class<?> subject = loader.define(
            BytecodeCombinedDepthSubject.class.getName(), patched);
        Object instance = subject.getDeclaredConstructor().newInstance();
        BytecodeAllocator allocator = new BytecodeAllocator();
        Object result = subject.getMethod("awaitAndFree", BytecodeAllocator.class, Long.TYPE)
            .invoke(instance, allocator, Long.valueOf(6L));
        assertEquals("invocation redirect survives the constant pass", 1, patchedFreeCalls);
        assertEquals("original callee stays bypassed", 0, allocator.calls);
        assertEquals("constant pass applies on post-invocation bytes", 2L, result);
    }

    static final java.util.List<String> uploadTimingEvents = new java.util.ArrayList<String>();

    public static void recordUploadTimingEvent(String event) {
        uploadTimingEvents.add(event);
    }

    public static class FakeUploadDispatcher {
        public final String name;
        public int staged;
        public int uploads;

        public FakeUploadDispatcher(String name) { this.name = name; }
        public void lock() { recordUploadTimingEvent(name + ".lock"); }
        public void unlock() { recordUploadTimingEvent(name + ".unlock"); }
        public void uploadTerrainBuffersToGpu() {
            uploads++;
            recordUploadTimingEvent(name + ".upload:" + staged);
            staged = 0;
        }
    }

    /**
     * Mirrors the two audited LevelRenderer.render call sites: the private
     * single-call repositionCamera at render entry (invokevirtual, like the
     * device build) and the frame-end lock/upload/unlock block whose middle
     * invocation is the one being deferred.
     */
    public static class BytecodeUploadTimingSubject {
        private FakeUploadDispatcher sectionRenderDispatcher;

        public BytecodeUploadTimingSubject(FakeUploadDispatcher dispatcher) {
            this.sectionRenderDispatcher = dispatcher;
        }

        public void setDispatcher(FakeUploadDispatcher next) {
            this.sectionRenderDispatcher = next;
        }

        private void repositionCamera(Object cameraState) {
            recordUploadTimingEvent("reposition");
        }

        public void render(Object cameraState) {
            repositionCamera(cameraState);
            recordUploadTimingEvent("draw");
            sectionRenderDispatcher.lock();
            sectionRenderDispatcher.uploadTerrainBuffersToGpu();
            sectionRenderDispatcher.unlock();
        }
    }

    static byte[] patchUploadTimingSubject(Class<?> subjectClass) throws Exception {
        String dispatcherOwner = FakeUploadDispatcher.class.getName().replace('.', '/');
        String helper = TerrainUploadTimingCompatibility.class.getName().replace('.', '/');
        byte[] patched = TerrainCompatibilityPatcher.patchInvocation(
            readClassBytes(subjectClass),
            dispatcherOwner, "uploadTerrainBuffersToGpu", "()V",
            helper, "deferFrameEndUpload", "(Ljava/lang/Object;)V");
        return TerrainCompatibilityPatcher.patchInvocation(patched,
            subjectClass.getName().replace('.', '/'), "repositionCamera",
            "(Ljava/lang/Object;)V",
            helper, "uploadPendingThenRepositionCamera",
            "(Ljava/lang/Object;Ljava/lang/Object;)V");
    }

    static void testUploadTimingDeferAndFlushOrder() throws Exception {
        TerrainUploadTimingCompatibility.resetForTests();
        uploadTimingEvents.clear();
        try {
            ByteArrayClassLoader loader = new ByteArrayClassLoader(
                AmclClassLoaderTest.class.getClassLoader());
            Class<?> subject = loader.define(BytecodeUploadTimingSubject.class.getName(),
                patchUploadTimingSubject(BytecodeUploadTimingSubject.class));
            FakeUploadDispatcher dispatcher = new FakeUploadDispatcher("A");
            Object instance = subject.getConstructor(FakeUploadDispatcher.class)
                .newInstance(dispatcher);
            java.lang.reflect.Method render = subject.getMethod("render", Object.class);

            dispatcher.staged = 3;
            render.invoke(instance, new Object());
            assertEquals("frame 1 defers the frame-end flush", 0, dispatcher.uploads);
            assertTrue("frame 1 records the pending dispatcher",
                TerrainUploadTimingCompatibility.pendingDispatcherForTests() == dispatcher);
            assertEquals("frame 1 keeps an empty frame-end critical section",
                "reposition|draw|A.lock|A.unlock", String.join("|", uploadTimingEvents));

            uploadTimingEvents.clear();
            render.invoke(instance, new Object());
            assertEquals("frame 2 flushes the deferred batch exactly once", 1,
                dispatcher.uploads);
            assertEquals("frame 2 flushes under a fresh lock before this frame's draw",
                "A.lock|A.upload:3|A.unlock|reposition|draw|A.lock|A.unlock",
                String.join("|", uploadTimingEvents));

            uploadTimingEvents.clear();
            render.invoke(instance, new Object());
            assertEquals("frame 3 flushes frame 2's (empty) batch without duplication", 2,
                dispatcher.uploads);
            assertEquals("frame 3 shows nothing was re-uploaded",
                "A.lock|A.upload:0|A.unlock|reposition|draw|A.lock|A.unlock",
                String.join("|", uploadTimingEvents));
            assertEquals("helper executed one batch per completed frame", 2L,
                TerrainUploadTimingCompatibility.executedBatchCountForTests());
        } finally {
            TerrainUploadTimingCompatibility.resetForTests();
            uploadTimingEvents.clear();
        }
    }

    static void testUploadTimingStaleWorldDrop() throws Exception {
        TerrainUploadTimingCompatibility.resetForTests();
        uploadTimingEvents.clear();
        try {
            ByteArrayClassLoader loader = new ByteArrayClassLoader(
                AmclClassLoaderTest.class.getClassLoader());
            Class<?> subject = loader.define(BytecodeUploadTimingSubject.class.getName(),
                patchUploadTimingSubject(BytecodeUploadTimingSubject.class));
            FakeUploadDispatcher first = new FakeUploadDispatcher("A");
            FakeUploadDispatcher second = new FakeUploadDispatcher("B");
            Object instance = subject.getConstructor(FakeUploadDispatcher.class)
                .newInstance(first);
            java.lang.reflect.Method render = subject.getMethod("render", Object.class);

            first.staged = 5;
            render.invoke(instance, new Object());
            subject.getMethod("setDispatcher", FakeUploadDispatcher.class)
                .invoke(instance, second);

            uploadTimingEvents.clear();
            render.invoke(instance, new Object());
            assertEquals("a disposed world's dispatcher is never flushed", 0, first.uploads);
            assertEquals("the stale batch is counted as dropped", 1L,
                TerrainUploadTimingCompatibility.droppedBatchCountForTests());
            assertEquals("the drop leaves the new frame untouched",
                "reposition|draw|B.lock|B.unlock", String.join("|", uploadTimingEvents));

            render.invoke(instance, new Object());
            assertEquals("the new world's dispatcher flushes on the next frame", 1,
                second.uploads);
        } finally {
            TerrainUploadTimingCompatibility.resetForTests();
            uploadTimingEvents.clear();
        }
    }

    public static class BytecodeDoubleUploadSubject {
        private FakeUploadDispatcher sectionRenderDispatcher;

        public void render() {
            sectionRenderDispatcher.uploadTerrainBuffersToGpu();
            sectionRenderDispatcher.uploadTerrainBuffersToGpu();
        }
    }

    static void testUploadTimingDoubleCallSiteFails() throws Exception {
        try {
            TerrainCompatibilityPatcher.patchInvocation(
                readClassBytes(BytecodeDoubleUploadSubject.class),
                FakeUploadDispatcher.class.getName().replace('.', '/'),
                "uploadTerrainBuffersToGpu", "()V",
                TerrainUploadTimingCompatibility.class.getName().replace('.', '/'),
                "deferFrameEndUpload", "(Ljava/lang/Object;)V");
            fail("two upload call sites must fail closed");
        } catch (IllegalArgumentException expected) {
            pass("two upload call sites fail closed");
        }
    }

    static void testBoundedTerrainHeapPolicy() {
        String previousGraphicsProfile =
            System.getProperty("amcl.graphics.profile");
        try {
            TerrainHeapCompatibility.setEnvironmentForTests(Boolean.TRUE,
                new TerrainHeapCompatibility.RendererProbe() {
                    public String renderer() { return "Maleoon 920"; }
                });
            assertEquals("Maleoon vertex heap is split into 16 MiB slabs", 16 * 1024 * 1024,
                TerrainHeapCompatibility.effectiveHeapSize(
                    new BytecodeHeapSubject(128 * 1024 * 1024)));
            assertEquals("Maleoon index heap is split into 4 MiB slabs", 4 * 1024 * 1024,
                TerrainHeapCompatibility.effectiveHeapSize(
                    new BytecodeHeapSubject(32 * 1024 * 1024)));
            assertEquals("unknown heap sizes are preserved", 7 * 1024 * 1024,
                TerrainHeapCompatibility.effectiveHeapSize(
                    new BytecodeHeapSubject(7 * 1024 * 1024)));

            TerrainHeapCompatibility.setEnvironmentForTests(Boolean.TRUE,
                new TerrainHeapCompatibility.RendererProbe() {
                    public String renderer() { return "Adreno (TM) 740"; }
                });
            assertEquals("non-Maleoon OHOS keeps Mojang's heap size", 128 * 1024 * 1024,
                TerrainHeapCompatibility.effectiveHeapSize(
                    new BytecodeHeapSubject(128 * 1024 * 1024)));

            TerrainHeapCompatibility.setEnvironmentForTests(Boolean.FALSE,
                new TerrainHeapCompatibility.RendererProbe() {
                    public String renderer() {
                        throw new AssertionError("non-OHOS must not query GL renderer");
                    }
                });
            assertEquals("non-OHOS keeps Mojang's heap size", 32 * 1024 * 1024,
                TerrainHeapCompatibility.effectiveHeapSize(
                    new BytecodeHeapSubject(32 * 1024 * 1024)));

            System.setProperty("amcl.graphics.profile", "minecraft-vulkan");
            TerrainHeapCompatibility.setEnvironmentForTests(Boolean.TRUE,
                new TerrainHeapCompatibility.RendererProbe() {
                    public String renderer() {
                        throw new AssertionError(
                            "Vulkan heap policy must not query GL_RENDERER");
                    }
                });
            assertEquals("Vulkan keeps Mojang's heap size without GL context",
                128 * 1024 * 1024,
                TerrainHeapCompatibility.effectiveHeapSize(
                    new BytecodeHeapSubject(128 * 1024 * 1024)));
        } finally {
            if (previousGraphicsProfile == null) {
                System.clearProperty("amcl.graphics.profile");
            } else {
                System.setProperty("amcl.graphics.profile", previousGraphicsProfile);
            }
            TerrainHeapCompatibility.resetForTests();
        }
    }

    static void testUnknownTerrainClassIsUnchanged() throws Exception {
        String resource = BytecodeSubject.class.getName().replace('.', '/') + ".class";
        byte[] original;
        try (InputStream input = AmclClassLoaderTest.class.getClassLoader().getResourceAsStream(resource)) {
            original = TerrainCompatibilityPatcher.readAll(input);
        }
        byte[] result = TerrainCompatibilityPatcher.patchKnownClass(
            TerrainCompatibilityPatcher.UBER_CLASS, original, false, false);
        assertTrue("unknown target hash is fail-closed", result == original);
    }

    public static class FakeHints {
        final boolean slow;
        int calls;

        FakeHints(boolean slow) { this.slow = slow; }
        public boolean writeToBufferIsSlow() { calls++; return slow; }
    }

    public static class FakeFeatures {
        final boolean persistent;
        int calls;

        FakeFeatures(boolean persistent) { this.persistent = persistent; }
        public boolean persistentMapping() { calls++; return persistent; }
    }

    public static class BytecodeStagingSubject {
        public static boolean choose(FakeHints hints, FakeFeatures features) {
            return hints.writeToBufferIsSlow() && features.persistentMapping();
        }
    }

    static TerrainStagingCompatibility.RendererProbe renderer(final String value) {
        return new TerrainStagingCompatibility.RendererProbe() {
            public String renderer() { return value; }
        };
    }

    static void testPersistentStagingSelectionPolicy() {
        String previousGraphicsProfile =
            System.getProperty("amcl.graphics.profile");
        try {
            TerrainStagingCompatibility.setEnvironmentForTests(Boolean.TRUE,
                renderer("Maleoon 920"));
            FakeHints maleoonHints = new FakeHints(false);
            FakeFeatures persistent = new FakeFeatures(true);
            assertTrue("OHOS Maleoon overrides the desktop-only slow-write hint",
                TerrainStagingCompatibility.writeToBufferIsSlowOrMaleoon(maleoonHints));
            assertTrue("persistent feature remains authoritative",
                TerrainStagingCompatibility.observePersistentMapping(persistent));
            assertEquals("original hint is evaluated once", 1, maleoonHints.calls);
            assertEquals("original persistent feature is evaluated once", 1, persistent.calls);

            TerrainStagingCompatibility.setEnvironmentForTests(Boolean.TRUE,
                renderer("Adreno (TM) 740"));
            assertTrue("non-Maleoon renderer keeps the original false hint",
                !TerrainStagingCompatibility.writeToBufferIsSlowOrMaleoon(new FakeHints(false)));

            TerrainStagingCompatibility.setEnvironmentForTests(Boolean.FALSE,
                renderer("Maleoon 920"));
            assertTrue("Maleoon override is scoped to OHOS",
                !TerrainStagingCompatibility.writeToBufferIsSlowOrMaleoon(new FakeHints(false)));

            TerrainStagingCompatibility.setEnvironmentForTests(Boolean.TRUE,
                renderer("Maleoon 920"));
            assertTrue("Maleoon request does not invent persistent-mapping capability",
                TerrainStagingCompatibility.writeToBufferIsSlowOrMaleoon(new FakeHints(false))
                    && !TerrainStagingCompatibility.observePersistentMapping(
                        new FakeFeatures(false)));

            TerrainStagingCompatibility.setEnvironmentForTests(Boolean.FALSE,
                new TerrainStagingCompatibility.RendererProbe() {
                    public String renderer() {
                        throw new AssertionError("original true hint must not query GL renderer");
                    }
                });
            assertTrue("Mojang's original true heuristic is preserved",
                TerrainStagingCompatibility.writeToBufferIsSlowOrMaleoon(new FakeHints(true)));
            assertTrue("Mojang-selected persistent path remains enabled",
                TerrainStagingCompatibility.observePersistentMapping(new FakeFeatures(true)));

            System.setProperty("amcl.graphics.profile", "minecraft-vulkan");
            TerrainStagingCompatibility.setEnvironmentForTests(Boolean.TRUE,
                new TerrainStagingCompatibility.RendererProbe() {
                    public String renderer() {
                        throw new AssertionError(
                            "Vulkan terrain policy must not query GL_RENDERER");
                    }
                });
            assertTrue("Vulkan terrain policy avoids GL calls without a current context",
                !TerrainStagingCompatibility.writeToBufferIsSlowOrMaleoon(
                    new FakeHints(false)));
        } finally {
            if (previousGraphicsProfile == null) {
                System.clearProperty("amcl.graphics.profile");
            } else {
                System.setProperty("amcl.graphics.profile", previousGraphicsProfile);
            }
            TerrainStagingCompatibility.resetForTests();
        }
    }

    static void testPersistentStagingBytecodePatch() throws Exception {
        String subjectName = BytecodeStagingSubject.class.getName();
        String resource = subjectName.replace('.', '/') + ".class";
        byte[] original;
        try (InputStream input = AmclClassLoaderTest.class.getClassLoader()
                .getResourceAsStream(resource)) {
            original = TerrainCompatibilityPatcher.readAll(input);
        }
        String hintsOwner = FakeHints.class.getName().replace('.', '/');
        String featuresOwner = FakeFeatures.class.getName().replace('.', '/');
        String helper = TerrainStagingCompatibility.class.getName().replace('.', '/');
        byte[] patched = TerrainCompatibilityPatcher.patchInvocation(original,
            hintsOwner, "writeToBufferIsSlow", "()Z",
            helper, "writeToBufferIsSlowOrMaleoon", "(Ljava/lang/Object;)Z");
        patched = TerrainCompatibilityPatcher.patchInvocation(patched,
            featuresOwner, "persistentMapping", "()Z",
            helper, "observePersistentMapping", "(Ljava/lang/Object;)Z");

        TerrainStagingCompatibility.setEnvironmentForTests(Boolean.TRUE,
            renderer("Maleoon 920"));
        try {
            ByteArrayClassLoader loader = new ByteArrayClassLoader(
                AmclClassLoaderTest.class.getClassLoader());
            Class<?> subject = loader.define(subjectName, patched);
            FakeHints hints = new FakeHints(false);
            FakeFeatures features = new FakeFeatures(true);
            Object result = subject.getMethod("choose", FakeHints.class, FakeFeatures.class)
                .invoke(null, hints, features);
            assertEquals("patched create decision selects the persistent ring", true, result);
            assertEquals("patched hint accessor preserves one evaluation", 1, hints.calls);
            assertEquals("patched feature accessor preserves one evaluation", 1, features.calls);
        } finally {
            TerrainStagingCompatibility.resetForTests();
        }
    }

    /**
     * The audited terrain guard is Mojang's ONLY remaining-capacity check for
     * whichever staging buffer reaches it. Every branch of the replacement must
     * therefore preserve `incoming <= capacity - writeOffset`; the soft batch
     * may only narrow it. These cases pin the inactive path, the non-terrain
     * capacity path, and the active path (physical AND soft).
     */
    static void testAllowTerrainAppendKeepsPhysicalGuard() {
        int mib = 1024 * 1024;
        java.nio.ByteBuffer small = java.nio.ByteBuffer.allocate(100);
        try {
            TerrainStagingCompatibility.resetForTests();

            // Soft batch inactive (default): original physical guard, bit for bit.
            assertTrue("inactive: fits remaining capacity",
                TerrainStagingCompatibility.allowTerrainAppend(10, small, 90));
            assertTrue("inactive: overflow past remaining capacity is rejected",
                !TerrainStagingCompatibility.allowTerrainAppend(20, small, 90));
            assertTrue("inactive: exact fill is accepted",
                TerrainStagingCompatibility.allowTerrainAppend(100, small, 0));
            assertTrue("inactive: first item larger than the buffer is rejected",
                !TerrainStagingCompatibility.allowTerrainAppend(101, small, 0));

            // Active but a non-terrain capacity: still the physical guard only.
            TerrainStagingCompatibility.setTerrainSoftBatchActiveForTests(true);
            assertTrue("active non-terrain: physical reject preserved",
                !TerrainStagingCompatibility.allowTerrainAppend(20, small, 90));
            assertTrue("active non-terrain: physical accept preserved",
                TerrainStagingCompatibility.allowTerrainAppend(10, small, 90));

            // Active terrain buffer (98 MiB, Cpu path): soft limit narrows, never widens.
            java.nio.ByteBuffer terrain = java.nio.ByteBuffer.allocate(98 * mib);
            assertTrue("active terrain: oversized first item within capacity is accepted",
                TerrainStagingCompatibility.allowTerrainAppend(8 * mib, terrain, 0));
            assertTrue("active terrain: first item beyond physical capacity is rejected",
                !TerrainStagingCompatibility.allowTerrainAppend(98 * mib + 1, terrain, 0));
            assertTrue("active terrain: append within the soft batch is accepted",
                TerrainStagingCompatibility.allowTerrainAppend(2 * mib, terrain, 1 * mib));
            assertTrue("active terrain: append beyond the soft batch drains",
                !TerrainStagingCompatibility.allowTerrainAppend(3 * mib, terrain, 2 * mib));

            // Regression pin (2026-08-27): the persistently-mapped ring slot the
            // Maleoon profile actually selects reports capacity = 98/2 = 49 MiB
            // (PersistentlyMapped passes size/2 to a 3-slot MappableRingBuffer).
            // Matching only 98 MiB left the soft batch permanently inactive on
            // device; the slot capacity must activate it identically.
            java.nio.ByteBuffer slot = java.nio.ByteBuffer.allocate(49 * mib);
            assertTrue("slot terrain: oversized first item within capacity is accepted",
                TerrainStagingCompatibility.allowTerrainAppend(8 * mib, slot, 0));
            assertTrue("slot terrain: first item beyond slot capacity is rejected",
                !TerrainStagingCompatibility.allowTerrainAppend(49 * mib + 1, slot, 0));
            assertTrue("slot terrain: append within the soft batch is accepted",
                TerrainStagingCompatibility.allowTerrainAppend(2 * mib, slot, 1 * mib));
            assertTrue("slot terrain: append beyond the soft batch drains",
                !TerrainStagingCompatibility.allowTerrainAppend(3 * mib, slot, 2 * mib));
        } finally {
            TerrainStagingCompatibility.resetForTests();
        }
    }

    /**
     * Mirrors the audited 13-byte tryAppend guard shape:
     *   iload_3; aload 4; invokevirtual ByteBuffer.capacity; iload_2; isub;
     *   if_icmple +5; aconst_null; areturn
     * Locals: 0=this, 1=unused, 2=writeOffset, 3=incomingBytes, 4=buffer.
     */
    public static class BytecodeTryAppendSubject {
        private final java.nio.ByteBuffer writeBuffer;

        public BytecodeTryAppendSubject(java.nio.ByteBuffer writeBuffer) {
            this.writeBuffer = writeBuffer;
        }

        public Object tryAppend(Object unused, int writeOffset, int incomingBytes) {
            java.nio.ByteBuffer buffer = this.writeBuffer;
            if (incomingBytes > buffer.capacity() - writeOffset) {
                return null;
            }
            return this;
        }
    }

    static void testStagingCapacityGuardBytecodePatch() throws Exception {
        String subjectName = BytecodeTryAppendSubject.class.getName();
        String resource = subjectName.replace('.', '/') + ".class";
        byte[] original;
        try (InputStream input = AmclClassLoaderTest.class.getClassLoader()
                .getResourceAsStream(resource)) {
            original = TerrainCompatibilityPatcher.readAll(input);
        }
        String helper = TerrainStagingCompatibility.class.getName().replace('.', '/');
        byte[] patched = TerrainCompatibilityPatcher.patchStagingCapacityGuard(original,
            helper, "allowTerrainAppend", "(ILjava/lang/Object;I)Z");
        assertTrue("guard patch produced new bytes", patched != original);

        try {
            TerrainStagingCompatibility.resetForTests();
            ByteArrayClassLoader loader = new ByteArrayClassLoader(
                AmclClassLoaderTest.class.getClassLoader());
            Class<?> subject = loader.define(subjectName, patched);
            java.lang.reflect.Constructor<?> constructor =
                subject.getDeclaredConstructor(java.nio.ByteBuffer.class);
            java.lang.reflect.Method tryAppend = subject.getMethod(
                "tryAppend", Object.class, Integer.TYPE, Integer.TYPE);
            Object instance = constructor.newInstance(java.nio.ByteBuffer.allocate(100));

            // Soft batch inactive: the rewritten guard must still enforce the
            // original physical check (this is the regression the audit found).
            assertTrue("patched guard accepts a fitting append",
                tryAppend.invoke(instance, null, 90, 10) != null);
            assertTrue("patched guard still rejects physical overflow",
                tryAppend.invoke(instance, null, 90, 20) == null);
            assertTrue("patched guard accepts an exact fill",
                tryAppend.invoke(instance, null, 0, 100) != null);
            assertTrue("patched guard rejects an oversized first item",
                tryAppend.invoke(instance, null, 0, 101) == null);
        } finally {
            TerrainStagingCompatibility.resetForTests();
        }
    }

    public static class FakeAllocator {
        int freeCalls;
        final java.util.List<Object> freed = new java.util.ArrayList<Object>();
        public void free(Object allocation) { freeCalls++; freed.add(allocation); }
    }

    public static class FakeStagingBuffer {
        int rotateCalls;
        private void tryClearAndRotate() { rotateCalls++; }
    }

    static class FakeFenceBackend implements TerrainRangeRetirement.FenceBackend {
        long nextFence = 1;
        final java.util.Set<Long> signaled = new java.util.HashSet<Long>();
        final java.util.List<Long> deleted = new java.util.ArrayList<Long>();
        int creates;
        int waits;
        boolean failCreate;

        public long createFence() {
            if (failCreate) throw new IllegalStateException("synthetic fence failure");
            creates++;
            return nextFence++;
        }
        public boolean isSignaled(long fence) { return signaled.contains(Long.valueOf(fence)); }
        public void await(long fence) { waits++; signaled.add(Long.valueOf(fence)); }
        public void deleteFence(long fence) { deleted.add(Long.valueOf(fence)); }
    }

    static void testFenceDelayedRangeRetirement() {
        FakeFenceBackend fences = new FakeFenceBackend();
        TerrainRangeRetirement.setFenceBackendForTests(fences);
        FakeAllocator allocator = new FakeAllocator();
        FakeStagingBuffer staging = new FakeStagingBuffer();
        Object first = new Object();
        Object second = new Object();

        TerrainRangeRetirement.deferFree(allocator, first);
        assertEquals("range is not immediately returned to TLSF", 0, allocator.freeCalls);
        TerrainRangeRetirement.finishUploadBatch(staging);
        assertEquals("uploader close still rotates staging", 1, staging.rotateCalls);
        assertEquals("one fence protects first retirement batch", 1, fences.creates);
        assertEquals("unsignaled range remains unavailable", 0, allocator.freeCalls);

        TerrainRangeRetirement.deferFree(allocator, second);
        assertEquals("next defer only polls and does not block", 0, allocator.freeCalls);
        fences.signaled.add(Long.valueOf(1));
        TerrainRangeRetirement.finishUploadBatch(staging);
        assertEquals("signaled old range returns to TLSF", 1, allocator.freeCalls);
        assertTrue("the first allocation was retired first", allocator.freed.get(0) == first);
        assertEquals("new range remains protected by its own fence", 1,
            TerrainRangeRetirement.pendingRangeCountForTests());
    }

    static void testRetirementBatching() {
        FakeFenceBackend fences = new FakeFenceBackend();
        TerrainRangeRetirement.setFenceBackendForTests(fences);
        FakeAllocator allocator = new FakeAllocator();
        FakeStagingBuffer staging = new FakeStagingBuffer();
        TerrainRangeRetirement.deferFree(allocator, new Object());
        TerrainRangeRetirement.deferFree(allocator, new Object());
        TerrainRangeRetirement.finishUploadBatch(staging);
        assertEquals("one fence batches multiple retired ranges", 1, fences.creates);
        assertEquals("both batched ranges remain protected", 2,
            TerrainRangeRetirement.pendingRangeCountForTests());
    }

    static void testRetirementQueueIsBounded() {
        FakeFenceBackend fences = new FakeFenceBackend();
        TerrainRangeRetirement.setFenceBackendForTests(fences);
        FakeAllocator allocator = new FakeAllocator();
        FakeStagingBuffer staging = new FakeStagingBuffer();
        for (int i = 0; i < 9; i++) {
            TerrainRangeRetirement.deferFree(allocator, new Object());
            TerrainRangeRetirement.finishUploadBatch(staging);
        }
        assertEquals("ninth in-flight batch waits for the oldest fence", 1, fences.waits);
        assertEquals("bounded queue retires the oldest allocation", 1, allocator.freeCalls);
        assertEquals("bounded queue retains at most eight ranges", 8,
            TerrainRangeRetirement.pendingRangeCountForTests());
    }

    static void testFenceFailureFallsBackWithoutLeak() {
        FakeFenceBackend fences = new FakeFenceBackend();
        fences.failCreate = true;
        TerrainRangeRetirement.setFenceBackendForTests(fences);
        FakeAllocator allocator = new FakeAllocator();
        FakeStagingBuffer staging = new FakeStagingBuffer();
        TerrainRangeRetirement.deferFree(allocator, new Object());
        TerrainRangeRetirement.finishUploadBatch(staging);
        assertEquals("fence failure restores baseline free", 1, allocator.freeCalls);
        assertEquals("fence failure leaves no retained range", 0,
            TerrainRangeRetirement.pendingRangeCountForTests());
    }

    // --- 辅助：创建测试 jar ---

    static File createTestJar(String name, String fullClassName, String sourceBody) throws Exception {
        String pkg = fullClassName.substring(0, fullClassName.lastIndexOf('.'));
        String simpleName = fullClassName.substring(fullClassName.lastIndexOf('.') + 1);

        // 创建源文件
        File srcDir = new File(tempDir, name + "_src");
        File pkgDir = new File(srcDir, pkg.replace('.', '/'));
        pkgDir.mkdirs();
        File srcFile = new File(pkgDir, simpleName + ".java");
        try (PrintWriter pw = new PrintWriter(srcFile)) {
            pw.println("package " + pkg + ";");
            pw.println(sourceBody);
        }

        // 编译
        File classDir = new File(tempDir, name + "_classes");
        classDir.mkdirs();
        ProcessBuilder pb = new ProcessBuilder("javac", "-d", classDir.getAbsolutePath(), srcFile.getAbsolutePath());
        pb.redirectErrorStream(true);
        Process p = pb.start();
        String output = new String(p.getInputStream().readAllBytes());
        int rc = p.waitFor();
        if (rc != 0) {
            throw new RuntimeException("javac failed: " + output);
        }

        // 打包 jar
        File jarFile = new File(tempDir, name + ".jar");
        Manifest manifest = new Manifest();
        manifest.getMainAttributes().put(Attributes.Name.MANIFEST_VERSION, "1.0");
        try (JarOutputStream jos = new JarOutputStream(new FileOutputStream(jarFile), manifest)) {
            addFilesToJar(classDir, classDir, jos);
        }
        return jarFile;
    }

    static File createSignedTestJar(String name,
                                    String firstClassName, String firstSource,
                                    String secondClassName, String secondSource) throws Exception {
        File firstJar = createTestJar(name + "-first", firstClassName, firstSource);
        File secondJar = createTestJar(name + "-second", secondClassName, secondSource);
        File merged = new File(tempDir, name + ".jar");
        Manifest manifest = new Manifest();
        manifest.getMainAttributes().put(Attributes.Name.MANIFEST_VERSION, "1.0");
        try (JarOutputStream output = new JarOutputStream(new FileOutputStream(merged), manifest)) {
            copyClassEntries(firstJar, output);
            copyClassEntries(secondJar, output);
        }

        File keyStore = new File(tempDir, name + ".p12");
        runJdkTool("keytool", "-genkeypair", "-alias", "amcl-test", "-keyalg", "RSA",
            "-storetype", "PKCS12", "-keystore", keyStore.getAbsolutePath(),
            "-storepass", "amcl-test-pass", "-keypass", "amcl-test-pass",
            "-dname", "CN=AMCL Test", "-validity", "1", "-noprompt");
        runJdkTool("jarsigner", "-keystore", keyStore.getAbsolutePath(),
            "-storetype", "PKCS12", "-storepass", "amcl-test-pass",
            "-keypass", "amcl-test-pass", merged.getAbsolutePath(), "amcl-test");
        return merged;
    }

    static void copyClassEntries(File sourceJar, JarOutputStream output) throws IOException {
        try (JarFile input = new JarFile(sourceJar)) {
            java.util.Enumeration<JarEntry> entries = input.entries();
            while (entries.hasMoreElements()) {
                JarEntry entry = entries.nextElement();
                if (entry.isDirectory() || !entry.getName().endsWith(".class")) continue;
                output.putNextEntry(new JarEntry(entry.getName()));
                try (InputStream stream = input.getInputStream(entry)) {
                    stream.transferTo(output);
                }
                output.closeEntry();
            }
        }
    }

    static void runJdkTool(String name, String... arguments) throws Exception {
        String executable = new File(new File(System.getProperty("java.home"), "bin"),
            isWindows() ? name + ".exe" : name).getAbsolutePath();
        java.util.List<String> command = new java.util.ArrayList<String>();
        command.add(executable);
        java.util.Collections.addAll(command, arguments);
        ProcessBuilder builder = new ProcessBuilder(command);
        builder.redirectErrorStream(true);
        Process process = builder.start();
        String output = new String(process.getInputStream().readAllBytes());
        int result = process.waitFor();
        if (result != 0) throw new RuntimeException(name + " failed: " + output);
    }

    static boolean isWindows() {
        return System.getProperty("os.name", "").toLowerCase().contains("win");
    }

    static void addFilesToJar(File root, File dir, JarOutputStream jos) throws IOException {
        for (File f : dir.listFiles()) {
            if (f.isDirectory()) {
                addFilesToJar(root, f, jos);
            } else {
                String entryName = root.toPath().relativize(f.toPath()).toString().replace('\\', '/');
                jos.putNextEntry(new JarEntry(entryName));
                try (FileInputStream fis = new FileInputStream(f)) {
                    fis.transferTo(jos);
                }
                jos.closeEntry();
            }
        }
    }

    static void deleteRecursive(File f) {
        if (f.isDirectory()) {
            File[] children = f.listFiles();
            if (children != null) {
                for (File c : children) deleteRecursive(c);
            }
        }
        f.delete();
    }

    // --- 断言工具 ---

    static void assertEquals(String name, Object expected, Object actual) {
        if (expected == null ? actual == null : expected.equals(actual)) { pass(name); }
        else { fail(name + ": expected=" + expected + " actual=" + actual); }
    }

    static void assertTrue(String name, boolean condition) {
        if (condition) { pass(name); } else { fail(name + ": expected true"); }
    }

    static void assertNotNull(String name, Object obj) {
        if (obj != null) { pass(name); } else { fail(name + ": expected non-null"); }
    }

    static void pass(String name) { passed++; System.out.println("  PASS: " + name); }
    static void fail(String name) { failed++; System.out.println("  FAIL: " + name); }
}
