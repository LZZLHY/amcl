package com.amcl.launcher;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

/**
 * Selects RenderPearl's existing fenced persistent staging ring on affected
 * OpenHarmony Maleoon devices and bounds one terrain upload batch.
 *
 * <p>This class is called by an exact-hash bytecode compatibility patch. It
 * preserves Mojang's original feature values and changes only the
 * {@code writeToBufferIsSlow} hint for the audited Maleoon profile. The
 * separate persistent-mapping accessor is observed so the runtime log records
 * the implementation that RenderPearl actually selected, rather than merely
 * the requested hint.</p>
 *
 * <p>The audited terrain staging allocation is 98 MiB. On the CPU staging
 * path that is also the write buffer's capacity; on the persistently-mapped
 * ring path {@code StagingBuffer$PersistentlyMapped.<init>} passes
 * {@code size / 2} to a three-slot {@code MappableRingBuffer} (bytecode:
 * {@code iconst_2; idiv}), so the per-slot write buffer seen by
 * {@code tryAppend} is 49 MiB. Both capacities identify the terrain staging
 * buffer; matching only 98 MiB left the soft batch permanently inactive on
 * the very path this class selects (found 2026-08-27 by decompilation after
 * boundary-crossing copy bursts stayed at tens of MiB per frame). A 4 MiB
 * soft batch limit reuses RenderPearl's existing {@code tryAppend(false) ->
 * drain -> retry} backpressure path. The first physically valid item is
 * always accepted, even when it exceeds the soft limit, so the policy cannot
 * starve an oversized mesh. The physical capacity, fence policy, submit
 * slots, and resource ownership are unchanged.</p>
 *
 * <p>The replaced bytecode guard was Mojang's physical remaining-capacity
 * check ({@code incoming <= capacity - writeOffset}). {@link #allowTerrainAppend}
 * therefore re-evaluates that check on <b>every</b> path — including inactive
 * soft-batch, non-terrain buffer sizes, and every fallback — and only tightens
 * it with the soft limit when the audited Maleoon profile is active. Returning
 * an unconditional {@code true} here would delete the game's own overflow
 * protection for whichever staging buffer hits this guard.</p>
 */
public final class TerrainStagingCompatibility {
    private static final int GL_RENDERER = 0x1f01;
    private static final String OHOS_PROPERTY = "amcl.platform.ohos";
    private static final String SOFT_BATCH_MIB_PROPERTY = "amcl.terrainUploadBatchMiB";
    private static final String DIAGNOSTICS_PROPERTY = "amcl.gpuWaitDiagnostics";
    private static final int MEBIBYTE = 1024 * 1024;
    private static final int TERRAIN_PHYSICAL_CAPACITY = 98 * MEBIBYTE;
    // Per-slot capacity of the persistently-mapped ring actually selected on
    // Maleoon: PersistentlyMapped hands MappableRingBuffer `size / 2` and the
    // ring keeps three such slots, so tryAppend's write buffer reports 49 MiB.
    private static final int TERRAIN_SLOT_CAPACITY = TERRAIN_PHYSICAL_CAPACITY / 2;
    private static final int DEFAULT_SOFT_BATCH_MIB = 4;
    private static final int SOFT_BATCH_BYTES = configuredSoftBatchBytes();
    private static final boolean BUDGET_DIAGNOSTICS = Boolean.parseBoolean(
        System.getProperty(DIAGNOSTICS_PROPERTY, "false"));
    private static final long REPORT_INTERVAL_NS = 1_000_000_000L;

    private static final Map<Class<?>, Method> booleanAccessors =
        new HashMap<Class<?>, Method>();
    private static final ThreadLocal<Decision> pendingDecision =
        new ThreadLocal<Decision>();
    private static final Object budgetStatsLock = new Object();

    private static RendererProbe rendererProbe = new LwjglRendererProbe();
    private static Boolean ohosOverrideForTests;
    private static volatile boolean terrainSoftBatchActive;
    private static long budgetWindowStartNs;
    private static long acceptedAppends;
    private static long acceptedBytes;
    private static long softRejects;
    private static long maxBatchBytes;
    private static long maxRejectedItemBytes;
    private static long oversizedFirstItems;

    private TerrainStagingCompatibility() {}

    /** Replacement for HintsAndWorkarounds.writeToBufferIsSlow(). */
    public static synchronized boolean writeToBufferIsSlowOrMaleoon(Object hints) {
        boolean original;
        try {
            original = invokeBooleanAccessor(hints, "writeToBufferIsSlow");
        } catch (RuntimeException failure) {
            pendingDecision.remove();
            log("status=fallback mode=cpu reason=hint-access-failed detail="
                + compact(failure.getMessage()));
            return false;
        }

        if (original) {
            pendingDecision.set(new Decision("game-heuristic", null));
            return true;
        }
        if (!isOhos()) {
            pendingDecision.remove();
            log("status=baseline mode=cpu reason=non-ohos");
            return false;
        }

        // The Vulkan profile deliberately sets org.lwjgl.opengl.libname to
        // libglfw.so only so LWJGL's early GL bootstrap has a non-null provider.
        // It does not create an OpenGL context. Calling GL11C.glGetString here
        // would therefore abort the JVM in native LWJGL code instead of being
        // caught by the reflection wrapper. Terrain staging remains correct on
        // the original CPU path; the Maleoon GL heuristic is only meaningful
        // when an actual current OpenGL context exists.
        // 这条设备策略只为 MobileGlues/GLES 定义；MobileGL 自己决定上传资源和同步。
        if (!RendererProfilePolicy.usesMobileGluesCompatibility()) {
            pendingDecision.remove();
            log("status=baseline mode=cpu reason=backend-out-of-scope");
            return false;
        }

        String renderer;
        try {
            renderer = rendererProbe.renderer();
        } catch (RuntimeException failure) {
            pendingDecision.remove();
            log("status=fallback mode=cpu reason=renderer-query-failed detail="
                + compact(failure.getMessage()));
            return false;
        }
        if (!isMaleoon(renderer)) {
            pendingDecision.remove();
            log("status=baseline mode=cpu reason=renderer-not-maleoon renderer="
                + quoted(renderer));
            return false;
        }

        pendingDecision.set(new Decision("ohos-maleoon-profile", renderer));
        log("status=override-requested mode=persistently-mapped-ring renderer="
            + quoted(renderer));
        return true;
    }

    /**
     * Replacement for DeviceFeatures.persistentMapping(). This preserves the
     * feature result and records the final branch selected by StagingBuffer.
     */
    public static synchronized boolean observePersistentMapping(Object features) {
        Decision decision = pendingDecision.get();
        pendingDecision.remove();
        boolean persistent;
        try {
            persistent = invokeBooleanAccessor(features, "persistentMapping");
        } catch (RuntimeException failure) {
            log("status=fallback mode=cpu reason=feature-access-failed detail="
                + compact(failure.getMessage()));
            return false;
        }

        String source = decision == null ? "unknown" : decision.source;
        String renderer = decision == null || decision.renderer == null
            ? "" : " renderer=" + quoted(decision.renderer);
        if (persistent) {
            log("status=active mode=persistently-mapped-ring slots=3 source="
                + source + renderer);
            if (decision != null && "ohos-maleoon-profile".equals(decision.source)
                    && SOFT_BATCH_BYTES < TERRAIN_PHYSICAL_CAPACITY) {
                terrainSoftBatchActive = true;
                log("status=active mode=soft-terrain-upload-backpressure"
                    + " soft_batch_mib=" + (SOFT_BATCH_BYTES / MEBIBYTE)
                    + " capacity_match_mib=98-or-49-per-slot"
                    + " oversized_policy=allow-first" + renderer);
            }
        } else {
            log("status=fallback mode=cpu reason=persistent-mapping-unavailable source="
                + source + renderer);
        }
        return persistent;
    }

    /**
     * Fixed-width replacement for the audited {@code tryAppend} capacity guard.
     *
     * <p>Base semantics on every path are the original guard, bit for bit:
     * {@code incomingBytes <= capacity - writeOffset} (signed int math, same as
     * the replaced {@code if_icmple}). The soft batch limit only ever narrows
     * that result; no branch may widen it, because for non-terrain buffers and
     * for every inactive/fallback state this method IS the game's only
     * remaining-capacity check.</p>
     */
    public static boolean allowTerrainAppend(int incomingBytes, Object writeBuffer,
                                             int writeOffset) {
        // Unreachable in the audited build: the verifier proves local 4 is a
        // ByteBuffer before the original invokevirtual. Kept as a fail-open
        // mirror of "cannot evaluate the guard" rather than a fabricated reject
        // (a permanent reject would spin the caller's drain-and-retry loop).
        if (!(writeBuffer instanceof ByteBuffer)) return true;
        int capacity = ((ByteBuffer) writeBuffer).capacity();
        boolean physicallyFits = incomingBytes <= capacity - writeOffset;

        boolean terrainCapacity = capacity == TERRAIN_PHYSICAL_CAPACITY
            || capacity == TERRAIN_SLOT_CAPACITY;
        if (!terrainSoftBatchActive || !terrainCapacity) {
            return physicallyFits;
        }

        boolean firstItem = writeOffset == 0;
        boolean accepted = physicallyFits
            && allowWithinSoftLimit(incomingBytes, writeOffset, SOFT_BATCH_BYTES);
        recordBudgetDecision(incomingBytes, writeOffset, accepted, firstItem);
        return accepted;
    }

    static boolean allowWithinSoftLimit(int incomingBytes, int writeOffset, int softLimitBytes) {
        return writeOffset == 0
            || (incomingBytes >= 0 && writeOffset >= 0
                && incomingBytes <= softLimitBytes - writeOffset);
    }

    static boolean isMaleoon(String renderer) {
        return renderer != null
            && renderer.toLowerCase(Locale.ROOT).contains("maleoon");
    }

    private static boolean isOhos() {
        return ohosOverrideForTests != null
            ? ohosOverrideForTests.booleanValue()
            : Boolean.parseBoolean(System.getProperty(OHOS_PROPERTY, "false"));
    }

    private static int configuredSoftBatchBytes() {
        String text = System.getProperty(SOFT_BATCH_MIB_PROPERTY,
            Integer.toString(DEFAULT_SOFT_BATCH_MIB));
        int mebibytes;
        try {
            mebibytes = Integer.parseInt(text);
        } catch (NumberFormatException ignored) {
            mebibytes = DEFAULT_SOFT_BATCH_MIB;
        }
        if (mebibytes <= 0) return TERRAIN_PHYSICAL_CAPACITY;
        return Math.min(mebibytes, TERRAIN_PHYSICAL_CAPACITY / MEBIBYTE) * MEBIBYTE;
    }

    private static void recordBudgetDecision(int incomingBytes, int writeOffset,
                                             boolean accepted, boolean firstItem) {
        if (!BUDGET_DIAGNOSTICS) return;
        long now = System.nanoTime();
        synchronized (budgetStatsLock) {
            if (budgetWindowStartNs == 0L) budgetWindowStartNs = now;
            long safeIncoming = Math.max(0L, (long) incomingBytes);
            long safeOffset = Math.max(0L, (long) writeOffset);
            if (accepted) {
                acceptedAppends = saturatedAdd(acceptedAppends, 1L);
                acceptedBytes = saturatedAdd(acceptedBytes, safeIncoming);
                maxBatchBytes = Math.max(maxBatchBytes, saturatedAdd(safeOffset, safeIncoming));
                if (firstItem && safeIncoming > SOFT_BATCH_BYTES) {
                    oversizedFirstItems = saturatedAdd(oversizedFirstItems, 1L);
                }
            } else {
                softRejects = saturatedAdd(softRejects, 1L);
                maxBatchBytes = Math.max(maxBatchBytes, safeOffset);
                maxRejectedItemBytes = Math.max(maxRejectedItemBytes, safeIncoming);
                if (softRejects == 1L) {
                    System.out.println("[AMCL-TERRAIN-BUDGET] schema=1 kind=event"
                        + " action=drain-and-retry batch_mib=" + mebibytes(safeOffset)
                        + " next_mib=" + mebibytes(safeIncoming)
                        + " limit_mib=" + (SOFT_BATCH_BYTES / MEBIBYTE));
                }
            }
            if (now - budgetWindowStartNs >= REPORT_INTERVAL_NS) {
                reportBudgetAndReset(now, "window");
            }
        }
    }

    private static void reportBudgetAndReset(long now, String kind) {
        long elapsed = budgetWindowStartNs == 0L
            ? 0L : Math.max(0L, now - budgetWindowStartNs);
        System.out.println("[AMCL-TERRAIN-BUDGET] schema=1 kind=" + kind
            + " window_ms=" + milliseconds(elapsed)
            + " accepted_appends=" + acceptedAppends
            + " accepted_mib=" + mebibytes(acceptedBytes)
            + " soft_rejects=" + softRejects
            + " batch_max_mib=" + mebibytes(maxBatchBytes)
            + " rejected_item_max_mib=" + mebibytes(maxRejectedItemBytes)
            + " oversized_first=" + oversizedFirstItems);
        budgetWindowStartNs = now;
        acceptedAppends = acceptedBytes = softRejects = maxBatchBytes = 0L;
        maxRejectedItemBytes = oversizedFirstItems = 0L;
    }

    private static boolean hasBudgetStats() {
        return acceptedAppends != 0L || softRejects != 0L || oversizedFirstItems != 0L;
    }

    private static Method invokeBooleanAccessorMethod(Object target, String name) {
        Method method = booleanAccessors.get(target.getClass());
        if (method == null || !name.equals(method.getName())) {
            try {
                method = target.getClass().getMethod(name);
                booleanAccessors.put(target.getClass(), method);
            } catch (NoSuchMethodException failure) {
                throw new IllegalStateException(name + " accessor is missing", failure);
            }
        }
        return method;
    }

    private static boolean invokeBooleanAccessor(Object target, String name) {
        if (target == null) throw new IllegalArgumentException(name + " target is null");
        Method method = invokeBooleanAccessorMethod(target, name);
        try {
            return ((Boolean) method.invoke(target)).booleanValue();
        } catch (IllegalAccessException failure) {
            throw new IllegalStateException(name + " accessor is inaccessible", failure);
        } catch (InvocationTargetException failure) {
            Throwable cause = failure.getCause();
            throw new IllegalStateException(name + " accessor failed: "
                + (cause == null ? failure : cause), cause == null ? failure : cause);
        }
    }

    private static long saturatedAdd(long left, long right) {
        if (right > 0L && left > Long.MAX_VALUE - right) return Long.MAX_VALUE;
        return left + right;
    }

    private static String milliseconds(long nanoseconds) {
        return String.format(Locale.ROOT, "%.3f", ((double) nanoseconds) / 1_000_000.0);
    }

    private static String mebibytes(long bytes) {
        return String.format(Locale.ROOT, "%.3f", ((double) bytes) / MEBIBYTE);
    }

    private static void log(String fields) {
        System.out.println("[AMCL-TERRAIN-STAGING] schema=1 " + fields);
    }

    private static String quoted(String value) {
        if (value == null) return "\"<null>\"";
        return "\"" + compact(value).replace("\"", "'") + "\"";
    }

    private static String compact(String value) {
        if (value == null || value.isEmpty()) return "unknown";
        return value.replace('\n', ' ').replace('\r', ' ');
    }

    interface RendererProbe {
        String renderer();
    }

    private static final class LwjglRendererProbe implements RendererProbe {
        public String renderer() {
            ClassLoader loader = Thread.currentThread().getContextClassLoader();
            try {
                Class<?> gl11 = Class.forName("org.lwjgl.opengl.GL11C", true, loader);
                Method getString = gl11.getMethod("glGetString", Integer.TYPE);
                return (String) getString.invoke(null, Integer.valueOf(GL_RENDERER));
            } catch (Exception failure) {
                throw new IllegalStateException("GL_RENDERER unavailable", failure);
            }
        }
    }

    private static final class Decision {
        final String source;
        final String renderer;

        Decision(String source, String renderer) {
            this.source = source;
            this.renderer = renderer;
        }
    }

    /** Clears game-class reflection state after a launch finishes. */
    static synchronized void shutdown() {
        synchronized (budgetStatsLock) {
            if (BUDGET_DIAGNOSTICS && hasBudgetStats()) {
                reportBudgetAndReset(System.nanoTime(), "final");
            }
            budgetWindowStartNs = 0L;
            acceptedAppends = acceptedBytes = softRejects = maxBatchBytes = 0L;
            maxRejectedItemBytes = oversizedFirstItems = 0L;
        }
        terrainSoftBatchActive = false;
        pendingDecision.remove();
        booleanAccessors.clear();
        rendererProbe = new LwjglRendererProbe();
        ohosOverrideForTests = null;
    }

    static synchronized void setEnvironmentForTests(Boolean ohos, RendererProbe probe) {
        terrainSoftBatchActive = false;
        ohosOverrideForTests = ohos;
        rendererProbe = probe == null ? new LwjglRendererProbe() : probe;
        pendingDecision.remove();
        booleanAccessors.clear();
    }

    /** Drives the soft-batch flag directly so guard tests need no 98 MiB GL setup. */
    static void setTerrainSoftBatchActiveForTests(boolean active) {
        terrainSoftBatchActive = active;
    }

    static synchronized void resetForTests() {
        shutdown();
    }
}
