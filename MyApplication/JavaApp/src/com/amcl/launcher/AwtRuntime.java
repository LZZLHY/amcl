package com.amcl.launcher;

import java.awt.GraphicsEnvironment;

/** Establishes the headless JDK capability before any game or mod initializes AWT. */
final class AwtRuntime {
    private static boolean initialized;
    private static String decision = "not-evaluated";

    private AwtRuntime() {}

    static synchronized void initialize() {
        if (initialized) return;
        if (!Boolean.parseBoolean(System.getProperty("amcl.platform.ohos", "false"))) {
            decision = "out-of-scope";
            return;
        }
        System.setProperty("java.awt.headless", "true");
        try {
            // The public query establishes GraphicsEnvironment's cached mode.
            // A later mod's property write must not switch a headless-only JDK to X11.
            if (!GraphicsEnvironment.isHeadless()) {
                throw new IllegalStateException("AWT was already initialized in headful mode; a new game JVM is required");
            }
            initialized = true;
            decision = "headless";
        } catch (LinkageError failure) {
            decision = "unavailable";
            throw new IllegalStateException("OHOS JDK cannot provide the required headless AWT capability", failure);
        } catch (RuntimeException failure) {
            decision = "failed";
            throw failure;
        }
    }

    static synchronized void reportAfterRedirect() {
        System.out.println("[AMCL-AWT] schema=1 phase=before-game status=" + decision
            + " effectiveHeadless=" + (initialized ? "true" : "not-evaluated")
            + " property=" + System.getProperty("java.awt.headless", "(absent)"));
    }
}
