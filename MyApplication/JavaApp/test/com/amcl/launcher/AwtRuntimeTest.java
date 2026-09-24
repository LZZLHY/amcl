package com.amcl.launcher;

import java.awt.GraphicsEnvironment;
import java.awt.Rectangle;
import java.awt.Toolkit;
import java.awt.image.BufferedImage;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.TimeUnit;

/** Each case needs a new JVM: AWT mode is intentionally immutable after its first query. */
public final class AwtRuntimeTest {
    public static void main(String[] args) throws Exception {
        if (args.length != 0) {
            child(args[0]);
            return;
        }
        int passed = 0;
        for (String mode : new String[]{"mod-override", "already-headful", "non-ohos"}) {
            String java = new File(System.getProperty("java.home"), "bin/java").getPath();
            Process process = new ProcessBuilder(java, "-Djava.awt.headless=true", "-cp",
                System.getProperty("java.class.path"), AwtRuntimeTest.class.getName(), mode)
                .redirectErrorStream(true).start();
            if (!process.waitFor(30, TimeUnit.SECONDS)) {
                process.destroyForcibly();
                throw new AssertionError("Timed out: " + mode);
            }
            String output = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
            if (process.exitValue() != 0 || !output.contains("PASS " + mode)) {
                throw new AssertionError(mode + ": " + output);
            }
            passed++;
        }
        if (!"backend-out-of-scope".equals(AmclClassLoader.terrainDisabledReason(true, "nativegl"))
                || !"platform-marker-missing".equals(AmclClassLoader.terrainDisabledReason(false, "nativegl"))) {
            throw new AssertionError("Incorrect patch family reason");
        }
        System.out.println("Results: " + (passed + 1) + " passed, 0 failed");
    }

    private static void child(String mode) {
        System.setProperty("amcl.platform.ohos", Boolean.toString(!mode.equals("non-ohos")));
        if (mode.equals("already-headful")) {
            System.setProperty("java.awt.headless", "false");
            if (GraphicsEnvironment.isHeadless()) throw new AssertionError("Invalid negative control");
            try {
                AwtRuntime.initialize();
                throw new AssertionError("Accepted a previously headful JVM");
            } catch (IllegalStateException expected) {
                if (!expected.getMessage().contains("new game JVM")) throw expected;
            }
        } else if (mode.equals("non-ohos")) {
            System.setProperty("java.awt.headless", "false");
            AwtRuntime.initialize();
            if (!"false".equals(System.getProperty("java.awt.headless"))) throw new AssertionError("Changed host policy");
        } else {
            AwtRuntime.initialize();
            // MidnightLib 1.9.2 performs this write immediately before using UIManager.
            System.setProperty("java.awt.headless", "false");
            if (!GraphicsEnvironment.isHeadless()) throw new AssertionError("Mod changed effective AWT mode");
            if (!Toolkit.getDefaultToolkit().getClass().getName().equals("sun.awt.HeadlessToolkit")) throw new AssertionError("Wrong toolkit");
            if (!new Rectangle(0, 0, 8, 8).intersects(new Rectangle(4, 4, 8, 8))) throw new AssertionError("Geometry failed");
            BufferedImage image = new BufferedImage(2, 2, BufferedImage.TYPE_INT_ARGB);
            image.setRGB(1, 1, 0xff123456);
            if (image.getRGB(1, 1) != 0xff123456) throw new AssertionError("Image failed");
        }
        System.out.println("PASS " + mode);
    }
}
