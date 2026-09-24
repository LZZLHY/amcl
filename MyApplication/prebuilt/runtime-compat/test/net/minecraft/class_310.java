package net.minecraft;

/** Adversarial lifecycle fixture: resize during construction, then synchronous reentry. */
public class class_310 implements AutoCloseable {
    public boolean resources;
    public int width, appliedWidth, calls, reenter, depth, maxDepth;
    public class_310() {
        width = 3120; method_15993();
        width = 2090; method_15993();
        resources = true;
    }
    public void method_15993() {
        if (!resources) throw new IllegalStateException("render resources not initialized");
        depth++; maxDepth = Math.max(depth, maxDepth); calls++;
        appliedWidth = width;
        if (reenter > 0) { reenter--; width--; method_15993(); }
        depth--;
    }
    public void close() { resources = false; }
}
