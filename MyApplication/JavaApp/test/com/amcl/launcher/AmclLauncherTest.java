package com.amcl.launcher;

import java.io.*;
import java.net.URL;
import java.util.jar.*;

/**
 * AmclLauncher integration test.
 * Tests the full launch flow: parse config, create ClassLoader, load and invoke mainClass.
 * Uses mock mainClass (not real MC) to verify the launch pipeline.
 */
public class AmclLauncherTest {

    static int passed = 0;
    static int failed = 0;
    static File tempDir;

    /**
     * 所有 AmclLauncher.setupSystemProperties 会写入的 system property keys。
     * 必须与 @JavaApp/src/com/amcl/launcher/AmclLauncher.java:setupSystemProperties 同步。
     * 用于 cleanRuntimeState() 隔离测试。如果你在 AmclLauncher 加 / 删 setProperty key，
     * 一定要更新这个清单，否则测试会因 JVM 内属性泄漏而出现"顺序敏感"假阴/假阳。
     */
    static final String[] RUNTIME_KEYS = {
        // 路径
        "user.dir", "user.home", "minecraft.applet.TargetDirectory",
        // OS 伪装
        "os.name", "os.version",
        // LWJGL
        "org.lwjgl.glfw.checkThread0", "org.lwjgl.system.allocator",
        "org.lwjgl.util.Debug", "org.lwjgl.util.DebugLoader",
        // 安全
        "log4j2.formatMsgNoLookups",
        // 网络
        "sun.net.client.defaultConnectTimeout", "sun.net.client.defaultReadTimeout",
        // Forge 特有
        "fml.earlyprogresswindow", "forge.enableGameTest",
        // 调试控制
        "amcl.lwjgl.debug",
    };

    /**
     * 清理上一轮测试遗留的 system property，让每个 test 都从干净状态开始。
     * 必须在每个 test 方法开头第一行调用。
     */
    static void cleanRuntimeState() {
        for (String k : RUNTIME_KEYS) System.clearProperty(k);
    }

    public static void main(String[] args) throws Throwable {
        tempDir = new File(System.getProperty("java.io.tmpdir"), "amcl_launcher_test_" + System.currentTimeMillis());
        tempDir.mkdirs();

        System.out.println("=== AmclLauncher Integration Tests ===\n");

        try {
            testLaunchMockMainClass();
            testTwoPhaseLaunchProtocol();
            testLaunchWithArgs();
            testLaunchForgeDetection();
            testLaunchMissingMainClass();
            testLaunchEmptyClasspath();
            testSystemPropertiesSet();
            testSystemPropertiesForgeExtras();
            testSystemPropertiesFabricNoExtras();
            testSystemPropertiesLwjglAllocatorLocked();
            testSystemPropertiesIsolation();
        } finally {
            deleteRecursive(tempDir);
        }

        System.out.println("\n=== Results: " + passed + " passed, " + failed + " failed ===");
        if (failed > 0) System.exit(1);
    }

    static void testLaunchMockMainClass() throws Throwable {
        cleanRuntimeState();
        File marker = new File(tempDir, "mock1_called.txt");
        File jar = createMockMainJar("mock1", "com.mock.MockMain",
            "public class MockMain {\n" +
            "  public static void main(String[] args) throws Exception {\n" +
            "    new java.io.File(\"" + esc(marker) + "\").createNewFile();\n" +
            "  }\n" +
            "}");

        String json = buildJson("com.mock.MockMain", new String[]{esc(jar)}, new String[]{});
        AmclLauncher.main(new String[]{ json });
        assertTrue("mock main was called", marker.exists());
    }

    static void testTwoPhaseLaunchProtocol() throws Throwable {
        cleanRuntimeState();
        File marker = new File(tempDir, "two_phase_called.txt");
        File jar = createMockMainJar("two_phase", "com.mock.TwoPhaseMain",
            "public class TwoPhaseMain { public static void main(String[] args) throws Exception {"
            + " new java.io.File(\"" + esc(marker) + "\").createNewFile(); } }");
        String json = buildJson("com.mock.TwoPhaseMain", new String[]{esc(jar)}, new String[]{});

        AmclLauncher.prepare(json);
        assertTrue("prepare mounts classpath without invoking game main", !marker.exists());
        AmclLauncher.main(new String[]{json});
        assertTrue("main consumes prepared launch on same thread", marker.exists());
    }

    static void testLaunchWithArgs() throws Throwable {
        cleanRuntimeState();
        File argsFile = new File(tempDir, "mock2_args.txt");
        File jar = createMockMainJar("mock2", "com.mock.ArgsMain",
            "public class ArgsMain {\n" +
            "  public static void main(String[] args) throws Exception {\n" +
            "    java.io.PrintWriter pw = new java.io.PrintWriter(\"" + esc(argsFile) + "\");\n" +
            "    for (String a : args) pw.println(a);\n" +
            "    pw.close();\n" +
            "  }\n" +
            "}");

        String json = buildJsonFull("com.mock.ArgsMain",
            new String[]{esc(jar)},
            new String[]{"--version", "1.20.4", "--gameDir", "/test"},
            false, false);
        AmclLauncher.main(new String[]{ json });

        assertTrue("args file created", argsFile.exists());
        String content = new String(java.nio.file.Files.readAllBytes(argsFile.toPath())).trim();
        String[] lines = content.split("\n");
        assertEquals("arg count", 4, lines.length);
        assertEquals("arg[0]", "--version", lines[0].trim());
        assertEquals("arg[1]", "1.20.4", lines[1].trim());
    }

    static void testLaunchForgeDetection() throws Throwable {
        cleanRuntimeState();
        File gameDir = new File(tempDir, "forge_test");
        File marker = new File(tempDir, "mock3_called.txt");
        File jar = createMockMainJar("mock3", "com.mock.ForgeMain",
            "public class ForgeMain {\n" +
            "  public static void main(String[] args) throws Exception {\n" +
            "    new java.io.File(\"" + esc(marker) + "\").createNewFile();\n" +
            "  }\n" +
            "}");

        String json = "{" +
            "\"mainClass\":\"com.mock.ForgeMain\"," +
            "\"classpath\":[\"" + esc(jar) + "\"]," +
            "\"mcArgs\":[]," +
            "\"gameDir\":\"" + esc(gameDir) + "\"," +
            "\"mcDir\":\"" + esc(gameDir) + "\"," +
            "\"filesDir\":\"" + esc(tempDir) + "\"," +
            "\"isForge\":true,\"isFabric\":false" +
            "}";

        AmclLauncher.main(new String[]{ json });

        File fmlToml = new File(gameDir, "config/fml.toml");
        assertTrue("fml.toml created for Forge", fmlToml.exists());
        assertTrue("mock main was called", marker.exists());
    }

    static void testLaunchMissingMainClass() throws Throwable {
        cleanRuntimeState();
        String json = buildJson("com.nonexistent.Missing", new String[]{}, new String[]{});
        try {
            AmclLauncher.main(new String[]{ json });
            fail("should throw for missing mainClass");
        } catch (ClassNotFoundException e) {
            pass("ClassNotFoundException for missing mainClass");
        } catch (Exception e) {
            if (e.getCause() instanceof ClassNotFoundException) {
                pass("wrapped ClassNotFoundException");
            } else {
                pass("exception for missing mainClass: " + e.getClass().getSimpleName());
            }
        }
    }

    static void testLaunchEmptyClasspath() throws Throwable {
        cleanRuntimeState();
        String json = buildJson("com.test.SomeClass", new String[]{}, new String[]{});
        try {
            AmclLauncher.main(new String[]{ json });
            fail("should throw for empty classpath");
        } catch (Exception e) {
            pass("exception for empty classpath: " + e.getClass().getSimpleName());
        }
    }

    static void testSystemPropertiesSet() throws Throwable {
        cleanRuntimeState();
        File propsFile = new File(tempDir, "mock_props.txt");
        File jar = createMockMainJar("mock_props", "com.mock.PropsMain",
            "public class PropsMain {\n" +
            "  public static void main(String[] args) throws Exception {\n" +
            "    java.io.PrintWriter pw = new java.io.PrintWriter(\"" + esc(propsFile) + "\");\n" +
            "    String[] keys = {\"os.name\",\"os.version\",\"user.dir\",\"user.home\",\n" +
            "      \"org.lwjgl.glfw.checkThread0\",\"org.lwjgl.system.allocator\",\n" +
            "      \"log4j2.formatMsgNoLookups\",\n" +
            "      \"sun.net.client.defaultConnectTimeout\",\"sun.net.client.defaultReadTimeout\",\n" +
            "      \"minecraft.applet.TargetDirectory\"};\n" +
            "    for (String k : keys) pw.println(k+\"=\"+System.getProperty(k));\n" +
            "    pw.close();\n" +
            "  }\n" +
            "}");

        String json = buildJsonFull("com.mock.PropsMain",
            new String[]{esc(jar)}, new String[]{}, false, false);
        AmclLauncher.main(new String[]{ json });

        assertTrue("props file created", propsFile.exists());
        java.util.Map<String,String> props = readKvFile(propsFile);
        assertEquals("os.name=Linux", "Linux", props.get("os.name"));
        assertEquals("os.version=5.10", "5.10", props.get("os.version"));
        assertEquals("user.dir=<tempDir>", tempDir.getAbsolutePath(), props.get("user.dir"));
        assertEquals("user.home=<tempDir>", tempDir.getAbsolutePath(), props.get("user.home"));
        assertEquals("minecraft.applet.TargetDirectory",
            tempDir.getAbsolutePath(), props.get("minecraft.applet.TargetDirectory"));
        assertEquals("glfw.checkThread0 disabled", "false", props.get("org.lwjgl.glfw.checkThread0"));
        assertEquals("log4j2 formatMsgNoLookups hardened", "true", props.get("log4j2.formatMsgNoLookups"));
        assertEquals("connect timeout 5s", "5000", props.get("sun.net.client.defaultConnectTimeout"));
        assertEquals("read timeout 5s", "5000", props.get("sun.net.client.defaultReadTimeout"));
    }

    /**
     * Regression test for Forge-specific system properties.
     * Lock in: when isForge=true, fml.earlyprogresswindow=false + forge.enableGameTest=false.
     */
    static void testSystemPropertiesForgeExtras() throws Throwable {
        cleanRuntimeState();
        File propsFile = new File(tempDir, "mock_forge_props.txt");
        File jar = createMockMainJar("mock_forge_props", "com.mock.ForgePropsMain",
            "public class ForgePropsMain {\n" +
            "  public static void main(String[] args) throws Exception {\n" +
            "    java.io.PrintWriter pw = new java.io.PrintWriter(\"" + esc(propsFile) + "\");\n" +
            "    pw.println(\"fml.earlyprogresswindow=\"+System.getProperty(\"fml.earlyprogresswindow\"));\n" +
            "    pw.println(\"forge.enableGameTest=\"+System.getProperty(\"forge.enableGameTest\"));\n" +
            "    pw.close();\n" +
            "  }\n" +
            "}");
        String json = buildJsonFull("com.mock.ForgePropsMain",
            new String[]{esc(jar)}, new String[]{}, true, false);
        AmclLauncher.main(new String[]{ json });
        assertTrue("forge props file created", propsFile.exists());
        java.util.Map<String,String> props = readKvFile(propsFile);
        assertEquals("fml.earlyprogresswindow off", "false", props.get("fml.earlyprogresswindow"));
        assertEquals("forge.enableGameTest off", "false", props.get("forge.enableGameTest"));
    }

    /**
     * Regression test: Fabric path must NOT set Forge-specific properties.
     */
    static void testSystemPropertiesFabricNoExtras() throws Throwable {
        cleanRuntimeState();
        File propsFile = new File(tempDir, "mock_fabric_props.txt");
        File jar = createMockMainJar("mock_fabric_props", "com.mock.FabricPropsMain",
            "public class FabricPropsMain {\n" +
            "  public static void main(String[] args) throws Exception {\n" +
            "    java.io.PrintWriter pw = new java.io.PrintWriter(\"" + esc(propsFile) + "\");\n" +
            "    pw.println(\"fml.earlyprogresswindow=\"+System.getProperty(\"fml.earlyprogresswindow\",\"<unset>\"));\n" +
            "    pw.close();\n" +
            "  }\n" +
            "}");
        // Clear any prior Forge prop leaked from earlier tests in same JVM
        System.clearProperty("fml.earlyprogresswindow");
        System.clearProperty("forge.enableGameTest");
        String json = buildJsonFull("com.mock.FabricPropsMain",
            new String[]{esc(jar)}, new String[]{}, false, true);
        AmclLauncher.main(new String[]{ json });
        java.util.Map<String,String> props = readKvFile(propsFile);
        assertEquals("fabric path does not set Forge prop",
            "<unset>", props.get("fml.earlyprogresswindow"));
    }

    /**
     * 防回归测试：`org.lwjgl.system.allocator` 必须**不**被 setupSystemProperties 设置。
     *
     * 历史：2026-03-28 ~ 2026-05-07 期间，C 层 mc_launcher.cpp 与 Java 层
     * AmclLauncher.setupSystemProperties 都曾 setProperty 为 "system"。
     * 2026-05-07 真机三组对照实验（C 组）确认两处都不必要——LWJGL 默认 allocator
     * (rpmalloc) 在 HarmonyOS Vanilla 1.20.4 + Forge 1.20.4 均可正常进世界。
     * 详见 @docs/archive/allocator-investigation-202605.md。
     *
     * 本测试锁"不设置"为期望，防止任何回归再次写入此属性。
     *
     * 注意：ROADMAP 关于 -Dorg.lwjgl.system.allocator=system **JVM 启动参数**形式
     * 的禁令仍然有效（实测黑屏，与 setProperty 路径不同）。详见
     * jvm_launcher.cpp REGION amcl-allocator-runtime-set 同名注释。
     */
    static void testSystemPropertiesLwjglAllocatorLocked() throws Throwable {
        cleanRuntimeState();
        File propsFile = new File(tempDir, "mock_allocator.txt");
        File jar = createMockMainJar("mock_allocator", "com.mock.AllocatorMain",
            "public class AllocatorMain {\n" +
            "  public static void main(String[] args) throws Exception {\n" +
            "    java.io.PrintWriter pw = new java.io.PrintWriter(\"" + esc(propsFile) + "\");\n" +
            "    pw.println(\"org.lwjgl.system.allocator=\"+System.getProperty(\"org.lwjgl.system.allocator\",\"<unset>\"));\n" +
            "    pw.close();\n" +
            "  }\n" +
            "}");
        String json = buildJsonFull("com.mock.AllocatorMain",
            new String[]{esc(jar)}, new String[]{}, false, false);
        AmclLauncher.main(new String[]{ json });
        java.util.Map<String,String> props = readKvFile(propsFile);
        assertEquals("lwjgl allocator NOT set (deleted 2026-05-07, see investigation doc)",
            "<unset>", props.get("org.lwjgl.system.allocator"));
    }

    /**
     * 测试隔离回归：连续跑多个 case 之间 cleanRuntimeState() 真的清干净。
     * 思路：先跑一次 Forge case 让 Forge 专属 prop 被设置，cleanRuntimeState() 清，
     * 再跑一次 Vanilla case，断言 Forge 专属 prop 没泄漏。
     *
     * 这是 P1-2 的关键防护：tests 在同一 JVM 进程跑，缺了这个测试，
     * 顺序敏感的回归（forge prop 泄到 vanilla）就会成为隐藏 bug。
     */
    static void testSystemPropertiesIsolation() throws Throwable {
        // 1) 跑 Forge case：fml.earlyprogresswindow 应该被设
        cleanRuntimeState();
        File jar1 = createMockMainJar("iso_forge", "com.mock.IsoForgeMain",
            "public class IsoForgeMain { public static void main(String[] a) {} }");
        AmclLauncher.main(new String[]{ buildJsonFull("com.mock.IsoForgeMain",
            new String[]{esc(jar1)}, new String[]{}, true, false) });
        assertEquals("forge prop set after Forge run", "false",
            System.getProperty("fml.earlyprogresswindow"));

        // 2) cleanRuntimeState() 后立即检查必须清干净
        cleanRuntimeState();
        assertNull("fml.earlyprogresswindow cleared by cleanRuntimeState",
            System.getProperty("fml.earlyprogresswindow"));
        assertNull("forge.enableGameTest cleared by cleanRuntimeState",
            System.getProperty("forge.enableGameTest"));
        assertNull("os.name cleared by cleanRuntimeState",
            System.getProperty("os.name"));

        // 3) 接着跑 Vanilla case：fml prop 不应该回来
        File propsFile = new File(tempDir, "iso_vanilla_props.txt");
        File jar2 = createMockMainJar("iso_vanilla", "com.mock.IsoVanillaMain",
            "public class IsoVanillaMain {\n" +
            "  public static void main(String[] args) throws Exception {\n" +
            "    java.io.PrintWriter pw = new java.io.PrintWriter(\"" + esc(propsFile) + "\");\n" +
            "    pw.println(\"fml.earlyprogresswindow=\"+System.getProperty(\"fml.earlyprogresswindow\",\"<unset>\"));\n" +
            "    pw.close();\n" +
            "  }\n" +
            "}");
        AmclLauncher.main(new String[]{ buildJsonFull("com.mock.IsoVanillaMain",
            new String[]{esc(jar2)}, new String[]{}, false, false) });
        java.util.Map<String,String> props = readKvFile(propsFile);
        assertEquals("Forge prop did NOT leak into Vanilla run",
            "<unset>", props.get("fml.earlyprogresswindow"));
    }

    /**
     * Simple key=value line reader that does NOT interpret backslashes as escapes.
     * Required for Windows paths like `D:\test\path` which would otherwise be mangled
     * by {@link java.util.Properties#load}.
     */
    static java.util.Map<String,String> readKvFile(File f) throws IOException {
        java.util.Map<String,String> map = new java.util.LinkedHashMap<>();
        for (String line : java.nio.file.Files.readAllLines(f.toPath())) {
            int eq = line.indexOf('=');
            if (eq < 0) continue;
            map.put(line.substring(0, eq), line.substring(eq + 1));
        }
        return map;
    }

    // --- helpers ---

    static String esc(File f) { return f.getAbsolutePath().replace("\\", "\\\\"); }

    static String buildJson(String mainClass, String[] cp, String[] mcArgs) {
        return buildJsonFull(mainClass, cp, mcArgs, false, false);
    }

    static String buildJsonFull(String mainClass, String[] cp, String[] mcArgs, boolean forge, boolean fabric) {
        StringBuilder sb = new StringBuilder("{");
        sb.append("\"mainClass\":\"").append(mainClass).append("\",");
        sb.append("\"classpath\":[");
        for (int i = 0; i < cp.length; i++) { if (i > 0) sb.append(","); sb.append("\"").append(cp[i]).append("\""); }
        sb.append("],\"mcArgs\":[");
        for (int i = 0; i < mcArgs.length; i++) { if (i > 0) sb.append(","); sb.append("\"").append(mcArgs[i]).append("\""); }
        sb.append("],");
        sb.append("\"gameDir\":\"").append(esc(tempDir)).append("\",");
        sb.append("\"mcDir\":\"").append(esc(tempDir)).append("\",");
        sb.append("\"filesDir\":\"").append(esc(tempDir)).append("\",");
        sb.append("\"isForge\":").append(forge).append(",");
        sb.append("\"isFabric\":").append(fabric);
        sb.append("}");
        return sb.toString();
    }

    static File createMockMainJar(String name, String fullClassName, String sourceBody) throws Throwable {
        String pkg = fullClassName.substring(0, fullClassName.lastIndexOf('.'));
        String simpleName = fullClassName.substring(fullClassName.lastIndexOf('.') + 1);
        File srcDir = new File(tempDir, name + "_src");
        File pkgDir = new File(srcDir, pkg.replace('.', '/'));
        pkgDir.mkdirs();
        File srcFile = new File(pkgDir, simpleName + ".java");
        try (PrintWriter pw = new PrintWriter(srcFile)) {
            pw.println("package " + pkg + ";");
            pw.println(sourceBody);
        }
        File classDir = new File(tempDir, name + "_classes");
        classDir.mkdirs();
        ProcessBuilder pb = new ProcessBuilder("javac", "-d", classDir.getAbsolutePath(), srcFile.getAbsolutePath());
        pb.redirectErrorStream(true);
        Process p = pb.start();
        String output = new String(p.getInputStream().readAllBytes());
        if (p.waitFor() != 0) throw new RuntimeException("javac failed: " + output);
        File jarFile = new File(tempDir, name + ".jar");
        Manifest manifest = new Manifest();
        manifest.getMainAttributes().put(Attributes.Name.MANIFEST_VERSION, "1.0");
        try (JarOutputStream jos = new JarOutputStream(new FileOutputStream(jarFile), manifest)) {
            addFiles(classDir, classDir, jos);
        }
        return jarFile;
    }

    static void addFiles(File root, File dir, JarOutputStream jos) throws IOException {
        for (File f : dir.listFiles()) {
            if (f.isDirectory()) { addFiles(root, f, jos); continue; }
            String entry = root.toPath().relativize(f.toPath()).toString().replace('\\', '/');
            jos.putNextEntry(new JarEntry(entry));
            try (FileInputStream fis = new FileInputStream(f)) { fis.transferTo(jos); }
            jos.closeEntry();
        }
    }

    static void deleteRecursive(File f) {
        if (f.isDirectory()) { File[] c = f.listFiles(); if (c != null) for (File x : c) deleteRecursive(x); }
        f.delete();
    }

    static void assertEquals(String n, Object e, Object a) { if (e == null ? a == null : e.equals(a)) pass(n); else fail(n + ": expected=" + e + " actual=" + a); }
    static void assertEquals(String n, int e, int a) { if (e == a) pass(n); else fail(n + ": expected=" + e + " actual=" + a); }
    static void assertTrue(String n, boolean c) { if (c) pass(n); else fail(n); }
    static void assertNull(String n, Object a) { if (a == null) pass(n); else fail(n + ": expected null but got `" + a + "`"); }
    static void pass(String n) { passed++; System.out.println("  PASS: " + n); }
    static void fail(String n) { failed++; System.out.println("  FAIL: " + n); }
}
