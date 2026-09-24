package com.amcl.launcher;

import java.io.*;
import java.nio.file.*;

/**
 * ForgeHelper 单元测试。
 * 基于规划文档的接口契约编写。
 *
 * 测试要点：
 * - fml.toml 创建（新文件）
 * - fml.toml 更新（已有文件，保留其他配置）
 * - Forge 1.17+ 扁平顶层 key（不得残留历史 [fmlClient] section）
 * - earlyWindowControl=false 写入
 * - 多路径写入（gameDir + mcDir）
 * - 非 Forge 时不写入
 */
public class ForgeHelperTest {

    static int passed = 0;
    static int failed = 0;
    static File tempDir;

    public static void main(String[] args) throws Exception {
        tempDir = new File(System.getProperty("java.io.tmpdir"), "amcl_fh_test_" + System.currentTimeMillis());
        tempDir.mkdirs();

        System.out.println("=== ForgeHelper Tests ===\n");

        try {
            testCreateNewFmlToml();
            testUpdateExistingFmlToml();
            testPreserveOtherConfig();
            testFmlClientSection();
            testMultiPathWrite();
            testNonForgeSkip();
            testEarlyWindowControlFalse();
            testIdempotent();
        } finally {
            deleteRecursive(tempDir);
        }

        System.out.println("\n=== Results: " + passed + " passed, " + failed + " failed ===");
        if (failed > 0) System.exit(1);
    }

    static void testCreateNewFmlToml() throws Exception {
        File gameDir = new File(tempDir, "test1/game");
        LaunchConfig config = makeForgeConfig(gameDir.getAbsolutePath(), gameDir.getAbsolutePath());

        ForgeHelper.disableEarlyDisplay(config);

        File toml = new File(gameDir, "config/fml.toml");
        assertTrue("fml.toml created", toml.exists());
        String content = Files.readString(toml.toPath());
        assertFalse("does not contain legacy [fmlClient]", content.contains("[fmlClient]"));
        assertTrue("contains earlyWindowControl = false", content.contains("earlyWindowControl = false"));
    }

    static void testUpdateExistingFmlToml() throws Exception {
        File gameDir = new File(tempDir, "test2/game");
        File configDir = new File(gameDir, "config");
        configDir.mkdirs();
        File toml = new File(configDir, "fml.toml");

        // 写入已有内容（earlyWindowControl=true）
        Files.writeString(toml.toPath(),
            "[fmlClient]\nearlyWindowControl = true\nsomeOtherKey = \"value\"\n");

        LaunchConfig config = makeForgeConfig(gameDir.getAbsolutePath(), gameDir.getAbsolutePath());
        ForgeHelper.disableEarlyDisplay(config);

        String content = Files.readString(toml.toPath());
        assertTrue("earlyWindowControl changed to false",
            content.contains("earlyWindowControl = false"));
        assertFalse("earlyWindowControl=true removed",
            content.contains("earlyWindowControl = true"));
    }

    static void testPreserveOtherConfig() throws Exception {
        File gameDir = new File(tempDir, "test3/game");
        File configDir = new File(gameDir, "config");
        configDir.mkdirs();
        File toml = new File(configDir, "fml.toml");

        Files.writeString(toml.toPath(),
            "[fmlClient]\nearlyWindowControl = true\n\n[other]\ncustomKey = 123\n");

        LaunchConfig config = makeForgeConfig(gameDir.getAbsolutePath(), gameDir.getAbsolutePath());
        ForgeHelper.disableEarlyDisplay(config);

        String content = Files.readString(toml.toPath());
        assertTrue("other section preserved", content.contains("[other]"));
        assertTrue("customKey preserved", content.contains("customKey = 123"));
    }

    static void testFmlClientSection() throws Exception {
        File gameDir = new File(tempDir, "test4/game");
        LaunchConfig config = makeForgeConfig(gameDir.getAbsolutePath(), gameDir.getAbsolutePath());
        ForgeHelper.disableEarlyDisplay(config);

        File toml = new File(gameDir, "config/fml.toml");
        String content = Files.readString(toml.toPath());

        // Forge 1.17+ 的 fml.toml 是扁平 schema；历史 [fmlClient] 会让 Forge
        // 忽略段内 earlyWindowControl 并退回默认 true。
        assertFalse("legacy [fmlClient] removed", content.contains("[fmlClient]"));
        assertTrue("top-level earlyWindowControl exists",
            content.contains("earlyWindowControl = false"));
    }

    static void testMultiPathWrite() throws Exception {
        File gameDir = new File(tempDir, "test5/game/versions/1.20.4-forge");
        File mcDir = new File(tempDir, "test5/game");

        LaunchConfig config = makeForgeConfig(gameDir.getAbsolutePath(), mcDir.getAbsolutePath());
        ForgeHelper.disableEarlyDisplay(config);

        // 两个路径都应该有 fml.toml
        File toml1 = new File(gameDir, "config/fml.toml");
        File toml2 = new File(mcDir, "config/fml.toml");
        assertTrue("gameDir fml.toml exists", toml1.exists());
        assertTrue("mcDir fml.toml exists", toml2.exists());
    }

    static void testNonForgeSkip() throws Exception {
        File gameDir = new File(tempDir, "test6/game");
        LaunchConfig config = makeVanillaConfig(gameDir.getAbsolutePath());

        ForgeHelper.disableEarlyDisplay(config);

        File toml = new File(gameDir, "config/fml.toml");
        assertFalse("fml.toml not created for vanilla", toml.exists());
    }

    static void testEarlyWindowControlFalse() throws Exception {
        File gameDir = new File(tempDir, "test7/game");
        LaunchConfig config = makeForgeConfig(gameDir.getAbsolutePath(), gameDir.getAbsolutePath());
        ForgeHelper.disableEarlyDisplay(config);

        File toml = new File(gameDir, "config/fml.toml");
        String content = Files.readString(toml.toPath());

        // 所有 EarlyDisplay 相关的 key 都应该是 false
        assertTrue("earlyWindowControl=false", content.contains("earlyWindowControl = false"));
    }

    static void testIdempotent() throws Exception {
        File gameDir = new File(tempDir, "test8/game");
        LaunchConfig config = makeForgeConfig(gameDir.getAbsolutePath(), gameDir.getAbsolutePath());

        // 调用两次
        ForgeHelper.disableEarlyDisplay(config);
        String content1 = Files.readString(new File(gameDir, "config/fml.toml").toPath());

        ForgeHelper.disableEarlyDisplay(config);
        String content2 = Files.readString(new File(gameDir, "config/fml.toml").toPath());

        assertEquals("idempotent", content1, content2);
    }

    // --- 辅助 ---

    static LaunchConfig makeForgeConfig(String gameDir, String mcDir) {
        String json = "{" +
            "\"mainClass\":\"net.minecraftforge.bootstrap.ForgeBootstrap\"," +
            "\"classpath\":[]," +
            "\"mcArgs\":[]," +
            "\"gameDir\":\"" + gameDir.replace("\\", "\\\\") + "\"," +
            "\"mcDir\":\"" + mcDir.replace("\\", "\\\\") + "\"," +
            "\"filesDir\":\"/files\"," +
            "\"isForge\":true,\"isFabric\":false" +
            "}";
        return LaunchConfig.parse(json);
    }

    static LaunchConfig makeVanillaConfig(String gameDir) {
        String json = "{" +
            "\"mainClass\":\"net.minecraft.client.main.Main\"," +
            "\"classpath\":[]," +
            "\"mcArgs\":[]," +
            "\"gameDir\":\"" + gameDir.replace("\\", "\\\\") + "\"," +
            "\"mcDir\":\"" + gameDir.replace("\\", "\\\\") + "\"," +
            "\"filesDir\":\"/files\"," +
            "\"isForge\":false,\"isFabric\":false" +
            "}";
        return LaunchConfig.parse(json);
    }

    static void deleteRecursive(File f) {
        if (f.isDirectory()) {
            File[] children = f.listFiles();
            if (children != null) for (File c : children) deleteRecursive(c);
        }
        f.delete();
    }

    // --- 断言 ---

    static void assertEquals(String name, Object expected, Object actual) {
        if (expected == null ? actual == null : expected.equals(actual)) { pass(name); }
        else { fail(name + ": expected=" + expected + " actual=" + actual); }
    }
    static void assertTrue(String name, boolean c) { if (c) pass(name); else fail(name); }
    static void assertFalse(String name, boolean c) { if (!c) pass(name); else fail(name); }
    static void pass(String name) { passed++; System.out.println("  PASS: " + name); }
    static void fail(String name) { failed++; System.out.println("  FAIL: " + name); }
}
