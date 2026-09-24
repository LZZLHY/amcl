package com.amcl.launcher;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

/** Regression tests for the MC 26.2 debug-profile compatibility gate. */
public class DebugProfileCompatTest {
    static int passed;
    static int failed;
    static File tempDir;

    public static void main(String[] args) throws Exception {
        tempDir = Files.createTempDirectory("amcl_debug_profile_compat_").toFile();
        try {
            testExactLaunchGate();
            testMinecraftRunObservation();
            testOneTimeMarkerDecision();
            testPersistedNeverRecognition();
            testProfileWinsOverCustom();
            testNonNeverAndMissingFiles();
        } finally {
            deleteRecursive(tempDir);
        }

        System.out.println("Results: " + passed + " passed, " + failed + " failed");
        if (failed > 0) System.exit(1);
    }

    static void testExactLaunchGate() {
        LaunchConfig target = config("26.2-neoforge-26.2.0.40-beta", true, false,
                "net.neoforged.fml.startup.Client");
        assertTrue("26.2 NeoForge target accepted", DebugProfileCompat.isTargetLaunch(target));

        LaunchConfig wrongMc = config("26.20-neoforge-test", true, false,
                "net.neoforged.fml.startup.Client");
        assertFalse("26.20 is not mistaken for 26.2", DebugProfileCompat.isTargetLaunch(wrongMc));

        LaunchConfig patchVersion = config("26.2.1-neoforge-test", true, false,
                "net.neoforged.fml.startup.Client");
        assertFalse("unknown 26.2.1 API is fail-closed", DebugProfileCompat.isTargetLaunch(patchVersion));

        LaunchConfig fabric = config("26.2-fabric", false, true,
                "net.fabricmc.loader.impl.launch.knot.KnotClient");
        assertFalse("Fabric is out of scope", DebugProfileCompat.isTargetLaunch(fabric));

        LaunchConfig vanilla = config("26.2", false, false,
                "net.minecraft.client.main.Main");
        assertFalse("Vanilla is out of scope", DebugProfileCompat.isTargetLaunch(vanilla));
    }

    static void testMinecraftRunObservation() {
        StackTraceElement[] running = {
                new StackTraceElement("org.lwjgl.glfw.GLFW", "glfwPollEvents", "GLFW.java", 1),
                new StackTraceElement("net.minecraft.client.Minecraft", "run", "Minecraft.java", 1200)
        };
        StackTraceElement[] constructing = {
                new StackTraceElement("net.minecraft.client.Minecraft", "<init>", "Minecraft.java", 713)
        };
        assertTrue("Minecraft.run proves class is already loaded",
                DebugProfileCompat.isInsideMinecraftRun(running));
        assertFalse("constructor is deliberately too early",
                DebugProfileCompat.isInsideMinecraftRun(constructing));
        assertFalse("null stack fails closed", DebugProfileCompat.isInsideMinecraftRun(null));
    }

    static void testOneTimeMarkerDecision() {
        assertEquals("first run applies non-NEVER default",
                DebugProfileCompat.StatusAction.APPLY,
                DebugProfileCompat.decideStatusAction(false, false));
        assertEquals("existing NEVER is kept",
                DebugProfileCompat.StatusAction.ALREADY_NEVER,
                DebugProfileCompat.decideStatusAction(false, true));
        assertEquals("marker preserves a later user re-enable",
                DebugProfileCompat.StatusAction.RESPECT_MIGRATED,
                DebugProfileCompat.decideStatusAction(true, false));
        assertEquals("marker plus NEVER remains idempotent",
                DebugProfileCompat.StatusAction.ALREADY_NEVER,
                DebugProfileCompat.decideStatusAction(true, true));
    }

    static void testPersistedNeverRecognition() throws Exception {
        File file = new File(tempDir, "never.json");
        write(file, "{\n"
                + "  \"DataVersion\": 4649,\n"
                + "  \"custom\": {\n"
                + "    \"minecraft:fps\": \"inOverlay\",\n"
                + "    \"sodium:buffer_arena\" : \"never\"\n"
                + "  }\n"
                + "}");
        assertTrue("custom NEVER persistence recognized",
                DebugProfileCompat.profileContainsPersistedNever(file));
    }

    static void testProfileWinsOverCustom() throws Exception {
        File file = new File(tempDir, "profile-wins.json");
        write(file, "{\"profile\":\"default\",\"custom\":{"
                + "\"sodium:buffer_arena\":\"never\"}}");
        assertFalse("profile field makes custom inactive",
                DebugProfileCompat.profileContainsPersistedNever(file));
    }

    static void testNonNeverAndMissingFiles() throws Exception {
        File enabled = new File(tempDir, "enabled.json");
        write(enabled, "{\"custom\":{\"sodium:buffer_arena\":\"inOverlay\"}}");
        assertFalse("inOverlay is not accepted as persisted fix",
                DebugProfileCompat.profileContainsPersistedNever(enabled));

        File valueOnly = new File(tempDir, "value-only.json");
        write(valueOnly, "{\"custom\":{\"example:key\":\"sodium:buffer_arena\"}}");
        assertFalse("identifier appearing as a value is not mistaken for a key",
                DebugProfileCompat.profileContainsPersistedNever(valueOnly));

        assertFalse("missing file fails closed",
                DebugProfileCompat.profileContainsPersistedNever(new File(tempDir, "missing.json")));
    }

    static LaunchConfig config(String version, boolean forge, boolean fabric, String mainClass) {
        LaunchConfig config = new LaunchConfig();
        config.mainClass = mainClass;
        config.classpath = new String[] { "/minecraft/libraries/net/neoforged/loader.jar" };
        config.mcArgs = new String[] { "--version", version };
        config.gameDir = tempDir.getAbsolutePath();
        config.isForge = forge;
        config.isFabric = fabric;
        return config;
    }

    static void write(File file, String value) throws Exception {
        try (FileOutputStream output = new FileOutputStream(file)) {
            output.write(value.getBytes(StandardCharsets.UTF_8));
        }
    }

    static void deleteRecursive(File file) {
        if (file.isDirectory()) {
            File[] children = file.listFiles();
            if (children != null) for (File child : children) deleteRecursive(child);
        }
        file.delete();
    }

    static void assertTrue(String name, boolean condition) {
        if (condition) pass(name); else fail(name);
    }

    static void assertFalse(String name, boolean condition) {
        assertTrue(name, !condition);
    }

    static void assertEquals(String name, Object expected, Object actual) {
        if (expected == null ? actual == null : expected.equals(actual)) pass(name);
        else fail(name + ": expected=" + expected + " actual=" + actual);
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
