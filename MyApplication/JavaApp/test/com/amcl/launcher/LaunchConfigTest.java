package com.amcl.launcher;

/**
 * LaunchConfig 单元测试。
 * 基于规划文档的接口契约编写，不依赖实现。
 *
 * 测试要点：
 * - JSON 解析正确性（正常/异常/边界）
 * - classpath URL 转换
 * - Forge/Fabric 检测
 */
public class LaunchConfigTest {

    static int passed = 0;
    static int failed = 0;

    public static void main(String[] args) {
        System.out.println("=== LaunchConfig Tests ===\n");

        testParseMinimalJson();
        testParseFullJson();
        testParseForgeConfig();
        testParseFabricConfig();
        testParseVanillaConfig();
        testClasspathToUrls();
        testClasspathEmpty();
        testClasspathWithSpaces();
        testParseMalformedJson();
        testParseEmptyJson();
        testParseNullInput();
        testMcArgsPreserveOrder();
        testSpecialCharsInPaths();
        testLongClasspath();

        System.out.println("\n=== Results: " + passed + " passed, " + failed + " failed ===");
        if (failed > 0) System.exit(1);
    }

    // --- 基本解析 ---

    static void testParseMinimalJson() {
        String json = "{" +
            "\"mainClass\":\"net.minecraft.client.main.Main\"," +
            "\"classpath\":[\"/a.jar\",\"/b.jar\"]," +
            "\"mcArgs\":[\"--version\",\"1.20.4\"]," +
            "\"gameDir\":\"/game\"," +
            "\"mcDir\":\"/mc\"," +
            "\"filesDir\":\"/files\"" +
            "}";
        LaunchConfig c = LaunchConfig.parse(json);
        assertNotNull("minimal parse", c);
        assertEquals("mainClass", "net.minecraft.client.main.Main", c.mainClass);
        assertEquals("classpath length", 2, c.classpath.length);
        assertEquals("classpath[0]", "/a.jar", c.classpath[0]);
        assertEquals("mcArgs length", 2, c.mcArgs.length);
        assertEquals("gameDir", "/game", c.gameDir);
        assertEquals("mcDir", "/mc", c.mcDir);
        assertEquals("filesDir", "/files", c.filesDir);
    }

    static void testParseFullJson() {
        String json = "{" +
            "\"mainClass\":\"net.fabricmc.loader.impl.launch.knot.KnotClient\"," +
            "\"classpath\":[\"/mc.jar\",\"/fabric.jar\",\"/lwjgl.jar\"]," +
            "\"mcArgs\":[\"--version\",\"1.20.4\",\"--gameDir\",\"/game\"]," +
            "\"gameDir\":\"/data/files/.minecraft/versions/1.20.4\"," +
            "\"mcDir\":\"/data/files/.minecraft\"," +
            "\"filesDir\":\"/data/files\"," +
            "\"assetsDir\":\"/data/files/.minecraft/assets\"," +
            "\"isForge\":false," +
            "\"isFabric\":true" +
            "}";
        LaunchConfig c = LaunchConfig.parse(json);
        assertNotNull("full parse", c);
        assertEquals("isFabric", true, c.isFabric);
        assertEquals("isForge", false, c.isForge);
        assertEquals("assetsDir", "/data/files/.minecraft/assets", c.assetsDir);
        assertEquals("classpath length", 3, c.classpath.length);
        assertEquals("mcArgs length", 4, c.mcArgs.length);
    }

    // --- Forge/Fabric 检测 ---

    static void testParseForgeConfig() {
        String json = "{" +
            "\"mainClass\":\"net.minecraftforge.bootstrap.ForgeBootstrap\"," +
            "\"classpath\":[\"/forge.jar\"]," +
            "\"mcArgs\":[\"--fml.forgeVersion\",\"49.2.7\"]," +
            "\"gameDir\":\"/game\",\"mcDir\":\"/mc\",\"filesDir\":\"/files\"," +
            "\"isForge\":true,\"isFabric\":false" +
            "}";
        LaunchConfig c = LaunchConfig.parse(json);
        assertNotNull("forge parse", c);
        assertTrue("isForge", c.isForge);
        assertFalse("isFabric", c.isFabric);
    }

    static void testParseFabricConfig() {
        String json = "{" +
            "\"mainClass\":\"net.fabricmc.loader.impl.launch.knot.KnotClient\"," +
            "\"classpath\":[\"/fabric.jar\"]," +
            "\"mcArgs\":[]," +
            "\"gameDir\":\"/game\",\"mcDir\":\"/mc\",\"filesDir\":\"/files\"," +
            "\"isForge\":false,\"isFabric\":true" +
            "}";
        LaunchConfig c = LaunchConfig.parse(json);
        assertNotNull("fabric parse", c);
        assertFalse("isForge", c.isForge);
        assertTrue("isFabric", c.isFabric);
    }

    static void testParseVanillaConfig() {
        String json = "{" +
            "\"mainClass\":\"net.minecraft.client.main.Main\"," +
            "\"classpath\":[\"/mc.jar\"]," +
            "\"mcArgs\":[\"--version\",\"1.20.4\"]," +
            "\"gameDir\":\"/game\",\"mcDir\":\"/mc\",\"filesDir\":\"/files\"," +
            "\"isForge\":false,\"isFabric\":false" +
            "}";
        LaunchConfig c = LaunchConfig.parse(json);
        assertNotNull("vanilla parse", c);
        assertFalse("isForge", c.isForge);
        assertFalse("isFabric", c.isFabric);
    }

    // --- classpath URL 转换 ---

    static void testClasspathToUrls() {
        String json = "{" +
            "\"mainClass\":\"Main\"," +
            "\"classpath\":[\"/data/a.jar\",\"/data/b.jar\",\"/data/c.jar\"]," +
            "\"mcArgs\":[]," +
            "\"gameDir\":\"/g\",\"mcDir\":\"/m\",\"filesDir\":\"/f\"" +
            "}";
        LaunchConfig c = LaunchConfig.parse(json);
        java.net.URL[] urls = c.getClasspathUrls();
        assertEquals("url count", 3, urls.length);
        for (java.net.URL url : urls) {
            assertTrue("url is file protocol: " + url, url.getProtocol().equals("file"));
            assertTrue("url path ends with .jar: " + url, url.getPath().endsWith(".jar"));
        }
    }

    static void testClasspathEmpty() {
        String json = "{" +
            "\"mainClass\":\"Main\"," +
            "\"classpath\":[]," +
            "\"mcArgs\":[]," +
            "\"gameDir\":\"/g\",\"mcDir\":\"/m\",\"filesDir\":\"/f\"" +
            "}";
        LaunchConfig c = LaunchConfig.parse(json);
        java.net.URL[] urls = c.getClasspathUrls();
        assertEquals("empty classpath url count", 0, urls.length);
    }

    static void testClasspathWithSpaces() {
        String json = "{" +
            "\"mainClass\":\"Main\"," +
            "\"classpath\":[\"/data/my folder/a.jar\"]," +
            "\"mcArgs\":[]," +
            "\"gameDir\":\"/g\",\"mcDir\":\"/m\",\"filesDir\":\"/f\"" +
            "}";
        LaunchConfig c = LaunchConfig.parse(json);
        java.net.URL[] urls = c.getClasspathUrls();
        assertEquals("space classpath count", 1, urls.length);
        // URL 应该能正确处理空格路径
        assertTrue("url contains path", urls[0].getPath().contains("my"));
    }

    // --- 异常/边界 ---

    static void testParseMalformedJson() {
        try {
            LaunchConfig c = LaunchConfig.parse("{broken json!!!");
            // 应该抛异常或返回 null
            if (c != null) {
                fail("malformed json should return null or throw");
            } else {
                pass("malformed json returns null");
            }
        } catch (Exception e) {
            pass("malformed json throws: " + e.getClass().getSimpleName());
        }
    }

    static void testParseEmptyJson() {
        try {
            LaunchConfig c = LaunchConfig.parse("{}");
            // 空 JSON 应该返回 null 或有默认值
            if (c == null) {
                pass("empty json returns null");
            } else {
                // 如果不返回 null，mainClass 应该为 null 或空
                assertTrue("empty json mainClass null/empty",
                    c.mainClass == null || c.mainClass.isEmpty());
                pass("empty json has null/empty mainClass");
            }
        } catch (Exception e) {
            pass("empty json throws: " + e.getClass().getSimpleName());
        }
    }

    static void testParseNullInput() {
        try {
            LaunchConfig c = LaunchConfig.parse(null);
            if (c == null) {
                pass("null input returns null");
            } else {
                fail("null input should return null or throw");
            }
        } catch (Exception e) {
            pass("null input throws: " + e.getClass().getSimpleName());
        }
    }

    static void testMcArgsPreserveOrder() {
        String json = "{" +
            "\"mainClass\":\"Main\"," +
            "\"classpath\":[]," +
            "\"mcArgs\":[\"--a\",\"1\",\"--b\",\"2\",\"--c\",\"3\"]," +
            "\"gameDir\":\"/g\",\"mcDir\":\"/m\",\"filesDir\":\"/f\"" +
            "}";
        LaunchConfig c = LaunchConfig.parse(json);
        assertEquals("args[0]", "--a", c.mcArgs[0]);
        assertEquals("args[1]", "1", c.mcArgs[1]);
        assertEquals("args[4]", "--c", c.mcArgs[4]);
        assertEquals("args[5]", "3", c.mcArgs[5]);
    }

    static void testSpecialCharsInPaths() {
        // 中文路径、特殊字符
        String json = "{" +
            "\"mainClass\":\"Main\"," +
            "\"classpath\":[\"/data/\u6e38\u620f/a.jar\"]," +
            "\"mcArgs\":[]," +
            "\"gameDir\":\"/data/\u6e38\u620f\"," +
            "\"mcDir\":\"/data/mc\"," +
            "\"filesDir\":\"/data/files\"" +
            "}";
        LaunchConfig c = LaunchConfig.parse(json);
        assertNotNull("chinese path parse", c);
        assertTrue("gameDir has chinese", c.gameDir.contains("\u6e38\u620f"));
    }

    static void testLongClasspath() {
        // 模拟 100 个 jar 的 classpath
        StringBuilder sb = new StringBuilder("{\"mainClass\":\"Main\",\"classpath\":[");
        for (int i = 0; i < 100; i++) {
            if (i > 0) sb.append(",");
            sb.append("\"/lib/jar" + i + ".jar\"");
        }
        sb.append("],\"mcArgs\":[],\"gameDir\":\"/g\",\"mcDir\":\"/m\",\"filesDir\":\"/f\"}");
        LaunchConfig c = LaunchConfig.parse(sb.toString());
        assertNotNull("long classpath parse", c);
        assertEquals("long classpath count", 100, c.classpath.length);
    }

    // --- 断言工具 ---

    static void assertEquals(String name, Object expected, Object actual) {
        if (expected == null ? actual == null : expected.equals(actual)) {
            pass(name);
        } else {
            fail(name + ": expected=" + expected + " actual=" + actual);
        }
    }

    static void assertEquals(String name, int expected, int actual) {
        if (expected == actual) { pass(name); }
        else { fail(name + ": expected=" + expected + " actual=" + actual); }
    }

    static void assertEquals(String name, boolean expected, boolean actual) {
        if (expected == actual) { pass(name); }
        else { fail(name + ": expected=" + expected + " actual=" + actual); }
    }

    static void assertTrue(String name, boolean condition) {
        if (condition) { pass(name); }
        else { fail(name + ": expected true"); }
    }

    static void assertFalse(String name, boolean condition) {
        if (!condition) { pass(name); }
        else { fail(name + ": expected false"); }
    }

    static void assertNotNull(String name, Object obj) {
        if (obj != null) { pass(name); }
        else { fail(name + ": expected non-null"); }
    }

    static void pass(String name) {
        passed++;
        System.out.println("  PASS: " + name);
    }

    static void fail(String name) {
        failed++;
        System.out.println("  FAIL: " + name);
    }
}
