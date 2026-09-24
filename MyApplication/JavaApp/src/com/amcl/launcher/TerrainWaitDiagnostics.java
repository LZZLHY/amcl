package com.amcl.launcher;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.Locale;

/**
 * Attributes RenderPearl awaitSubmit latency to its two blocking semantic callers.
 * The exact-hash bytecode patch keeps the original wait policy and only routes
 * the two call sites through these timing helpers.
 */
public final class TerrainWaitDiagnostics {
    private static final long REPORT_INTERVAL_NS = 1_000_000_000L;
    private static final long SLOW_WAIT_NS = 2_000_000L;
    private static final int SUBMIT_TIMELINE_SLOTS = 8;
    private static final boolean ENABLED = Boolean.parseBoolean(
        System.getProperty("amcl.gpuWaitDiagnostics", "false"));

    private static final Counters globalSubmit = new Counters();
    private static final Counters sourceRing = new Counters();
    private static final Counters gpuFencePoll = new Counters();
    private static final Counters globalRetiredOwner = new Counters();
    private static final Counters globalUploaderOwner = new Counters();
    private static final Counters globalIdleOwner = new Counters();
    private static final Counters globalUnknownOwner = new Counters();

    private static final ThreadLocal<SubmitTimeline> submitTimeline =
        new ThreadLocal<SubmitTimeline>() {
            @Override
            protected SubmitTimeline initialValue() {
                return new SubmitTimeline();
            }
        };

    // Depth of the game's submit pacer. The bytecode patcher reports the
    // depth it actually applied, so the correlation offsets below track the
    // running build even when the submit-depth patch set fails all-or-none.
    private static volatile int effectiveSubmitDepth = 2;

    private static Class<?> encoderClass;
    private static Method awaitSubmitMethod;
    private static long windowStartNs;
    private static boolean activeLogged;

    private TerrainWaitDiagnostics() {}

    /** Called by TerrainCompatibilityPatcher when the depth transform is applied. */
    static void noteEffectiveSubmitDepth(int depth) {
        effectiveSubmitDepth = depth;
    }

    /** Records one terrain uploader close without adding a GL call or wait. */
    public static void noteTerrainBatch(int retiredRanges, long retiredBytes) {
        if (!ENABLED) return;
        try {
            submitTimeline.get().noteTerrainBatch(retiredRanges, retiredBytes);
        } catch (Throwable ignored) {
            // Diagnostics must never change rendering or fence ownership semantics.
        }
    }

    /** Replacement for the awaitSubmit invocation inside GlCommandEncoder.submit(). */
    public static boolean awaitGlobalSubmit(Object encoder, long submitIndex, long timeoutNs) {
        SubmitCorrelation correlation = beginGlobalSubmitSafely(submitIndex);
        return invokeAwait(encoder, submitIndex, timeoutNs, globalSubmit, "global_submit",
            correlation);
    }

    /** Replacement for the awaitSubmit invocation inside GlFence.awaitCompletion(). */
    public static boolean awaitGpuFence(Object encoder, long submitIndex, long timeoutNs) {
        if (timeoutNs == Long.MAX_VALUE) {
            return invokeAwait(encoder, submitIndex, timeoutNs, sourceRing, "source_ring", null);
        }
        return invokeAwait(encoder, submitIndex, timeoutNs, gpuFencePoll, "gpu_fence_poll", null);
    }

    private static SubmitCorrelation beginGlobalSubmitSafely(long ownerSubmit) {
        if (!ENABLED) return null;
        try {
            return submitTimeline.get().beginGlobalSubmit(ownerSubmit);
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static boolean invokeAwait(Object encoder, long submitIndex, long timeoutNs,
                                       Counters counters, String caller,
                                       SubmitCorrelation correlation) {
        if (encoder == null) throw new NullPointerException("encoder");
        Method method = awaitSubmitMethod(encoder.getClass());
        long started = System.nanoTime();
        try {
            boolean completed = ((Boolean) method.invoke(encoder,
                Long.valueOf(submitIndex), Long.valueOf(timeoutNs))).booleanValue();
            recordSafely(counters, caller, submitIndex, timeoutNs,
                System.nanoTime() - started, completed, null, correlation);
            return completed;
        } catch (InvocationTargetException wrapped) {
            Throwable cause = wrapped.getCause() == null ? wrapped : wrapped.getCause();
            recordSafely(counters, caller, submitIndex, timeoutNs,
                System.nanoTime() - started, false, cause, correlation);
            if (cause instanceof RuntimeException) throw (RuntimeException) cause;
            if (cause instanceof Error) throw (Error) cause;
            throw new IllegalStateException("awaitSubmit threw a checked exception", cause);
        } catch (IllegalAccessException failure) {
            recordSafely(counters, caller, submitIndex, timeoutNs,
                System.nanoTime() - started, false, failure, correlation);
            throw new IllegalStateException("Cannot invoke awaitSubmit", failure);
        }
    }

    private static synchronized Method awaitSubmitMethod(Class<?> owner) {
        if (owner == encoderClass && awaitSubmitMethod != null) return awaitSubmitMethod;
        try {
            Method method = owner.getDeclaredMethod("awaitSubmit", Long.TYPE, Long.TYPE);
            method.setAccessible(true);
            encoderClass = owner;
            awaitSubmitMethod = method;
            return method;
        } catch (ReflectiveOperationException failure) {
            throw new IllegalStateException("Audited awaitSubmit method is unavailable on "
                + owner.getName(), failure);
        }
    }

    private static void recordSafely(Counters counters, String caller, long submitIndex,
                                     long timeoutNs, long elapsedNs, boolean completed,
                                     Throwable failure, SubmitCorrelation correlation) {
        try {
            record(counters, caller, submitIndex, timeoutNs, elapsedNs, completed, failure,
                correlation);
        } catch (Throwable ignored) {
            // Diagnostics must never change rendering or fence ownership semantics.
        }
    }

    private static synchronized void record(Counters counters, String caller, long submitIndex,
                                            long timeoutNs, long elapsedNs, boolean completed,
                                            Throwable failure, SubmitCorrelation correlation) {
        long now = System.nanoTime();
        if (windowStartNs == 0L) windowStartNs = now;
        if (!activeLogged) {
            activeLogged = true;
            System.out.println("[AMCL-GPU-WAIT] schema=2 kind=active"
                + " policy=exact-java-caller-owner-correlation"
                + " submit_depth=" + effectiveSubmitDepth
                + " timeline_slots=" + SUBMIT_TIMELINE_SLOTS
                + " slow_threshold_ms=" + milliseconds(SLOW_WAIT_NS));
        }

        counters.add(elapsedNs, completed, failure != null);
        if (counters == globalSubmit) {
            ownerCounters(correlation).add(elapsedNs, completed, failure != null);
        }
        if (elapsedNs >= SLOW_WAIT_NS || failure != null) {
            System.out.println("[AMCL-GPU-WAIT] schema=2 kind=event caller=" + caller
                + " owner_submit=" + submitIndex
                + correlationFields(correlation)
                + " timeout=" + timeoutClass(timeoutNs)
                + " completed=" + (completed ? 1 : 0)
                + " failed=" + (failure == null ? 0 : 1)
                + " elapsed_ms=" + milliseconds(elapsedNs)
                + (failure == null ? "" : " reason=" + compact(failure)));
        }

        if (now - windowStartNs >= REPORT_INTERVAL_NS) reportAndReset(now, "window");
    }

    public static synchronized void shutdown() {
        if (activeLogged && totalCalls() > 0L) reportAndReset(System.nanoTime(), "final");
        clearCounters();
        submitTimeline.remove();
        encoderClass = null;
        awaitSubmitMethod = null;
        windowStartNs = 0L;
        activeLogged = false;
        effectiveSubmitDepth = 2;
    }

    private static void reportAndReset(long now, String kind) {
        long elapsed = windowStartNs == 0L ? 0L : Math.max(0L, now - windowStartNs);
        System.out.println("[AMCL-GPU-WAIT] schema=2 kind=" + kind
            + " window_ms=" + milliseconds(elapsed)
            + fields("global", globalSubmit)
            + fields("source", sourceRing)
            + fields("poll", gpuFencePoll)
            + fields("owner_retired", globalRetiredOwner)
            + fields("owner_uploader", globalUploaderOwner)
            + fields("owner_idle", globalIdleOwner)
            + fields("owner_unknown", globalUnknownOwner));
        clearCounters();
        windowStartNs = now;
    }

    private static Counters ownerCounters(SubmitCorrelation correlation) {
        if (correlation == null || !correlation.ownerKnown) return globalUnknownOwner;
        if (correlation.ownerRetiredRanges > 0L) return globalRetiredOwner;
        if (correlation.ownerUploaderBatches > 0L) return globalUploaderOwner;
        return globalIdleOwner;
    }

    private static String correlationFields(SubmitCorrelation correlation) {
        if (correlation == null) {
            return " owner_state=unknown owner_known=0 owner_uploader_batches=0"
                + " owner_retired_ranges=0 owner_retired_mib=0.000";
        }
        String state = !correlation.ownerKnown ? "unknown"
            : correlation.ownerRetiredRanges > 0L ? "retired"
            : correlation.ownerUploaderBatches > 0L ? "uploader"
            : "idle";
        return " closed_submit=" + correlation.closedSubmit
            + " next_open_submit=" + correlation.nextOpenSubmit
            + " owner_state=" + state
            + " owner_known=" + (correlation.ownerKnown ? 1 : 0)
            + " owner_uploader_batches=" + correlation.ownerUploaderBatches
            + " owner_retired_ranges=" + correlation.ownerRetiredRanges
            + " owner_retired_mib=" + mebibytes(correlation.ownerRetiredBytes);
    }

    private static String fields(String prefix, Counters value) {
        return " " + prefix + "_calls=" + value.calls
            + " " + prefix + "_ms=" + milliseconds(value.totalNs)
            + " " + prefix + "_max_ms=" + milliseconds(value.maxNs)
            + " " + prefix + "_slow_calls=" + value.slowCalls
            + " " + prefix + "_completed=" + value.completed
            + " " + prefix + "_pending=" + value.pending
            + " " + prefix + "_failed=" + value.failed;
    }

    private static long totalCalls() {
        return globalSubmit.calls + sourceRing.calls + gpuFencePoll.calls;
    }

    private static void clearCounters() {
        globalSubmit.clear();
        sourceRing.clear();
        gpuFencePoll.clear();
        globalRetiredOwner.clear();
        globalUploaderOwner.clear();
        globalIdleOwner.clear();
        globalUnknownOwner.clear();
    }

    private static String timeoutClass(long timeoutNs) {
        if (timeoutNs == 0L) return "zero";
        if (timeoutNs == Long.MAX_VALUE) return "i64max";
        if (timeoutNs == -1L) return "ignored";
        return "other";
    }

    private static String milliseconds(long nanoseconds) {
        return String.format(Locale.ROOT, "%.3f", ((double) nanoseconds) / 1_000_000.0);
    }

    private static String mebibytes(long bytes) {
        return String.format(Locale.ROOT, "%.3f", ((double) bytes) / 1048576.0);
    }

    private static String compact(Throwable failure) {
        String text = failure.getClass().getSimpleName() + ':' + String.valueOf(failure.getMessage());
        return text.replace(' ', '_').replace('\n', '_').replace('\r', '_');
    }

    private static final class SubmitTimeline {
        private final SubmitMetadata[] slots = new SubmitMetadata[SUBMIT_TIMELINE_SLOTS];
        private final SubmitCorrelation correlation = new SubmitCorrelation();
        private long pendingUploaderBatches;
        private long pendingRetiredRanges;
        private long pendingRetiredBytes;

        SubmitTimeline() {
            for (int i = 0; i < slots.length; i++) slots[i] = new SubmitMetadata();
        }

        void noteTerrainBatch(int retiredRanges, long retiredBytes) {
            pendingUploaderBatches = saturatedAdd(pendingUploaderBatches, 1L);
            pendingRetiredRanges = saturatedAdd(pendingRetiredRanges,
                Math.max(0L, (long) retiredRanges));
            pendingRetiredBytes = saturatedAdd(pendingRetiredBytes, Math.max(0L, retiredBytes));
        }

        SubmitCorrelation beginGlobalSubmit(long ownerSubmit) {
            // submit() awaits currentSubmitIndex - depth after incrementing,
            // so the awaited owner trails the just-closed submit by depth - 1.
            long depth = effectiveSubmitDepth;
            long closedSubmit = ownerSubmit + depth - 1L;
            SubmitMetadata owner = slots[index(ownerSubmit)];
            correlation.closedSubmit = closedSubmit;
            correlation.nextOpenSubmit = ownerSubmit + depth;
            correlation.ownerKnown = owner.valid && owner.submitIndex == ownerSubmit;
            correlation.ownerUploaderBatches = correlation.ownerKnown
                ? owner.uploaderBatches : 0L;
            correlation.ownerRetiredRanges = correlation.ownerKnown ? owner.retiredRanges : 0L;
            correlation.ownerRetiredBytes = correlation.ownerKnown ? owner.retiredBytes : 0L;

            SubmitMetadata current = slots[index(closedSubmit)];
            current.valid = true;
            current.submitIndex = closedSubmit;
            current.uploaderBatches = pendingUploaderBatches;
            current.retiredRanges = pendingRetiredRanges;
            current.retiredBytes = pendingRetiredBytes;
            pendingUploaderBatches = 0L;
            pendingRetiredRanges = 0L;
            pendingRetiredBytes = 0L;
            return correlation;
        }

        private int index(long submitIndex) {
            return ((int) submitIndex) & (SUBMIT_TIMELINE_SLOTS - 1);
        }
    }

    private static final class SubmitMetadata {
        boolean valid;
        long submitIndex;
        long uploaderBatches;
        long retiredRanges;
        long retiredBytes;
    }

    private static final class SubmitCorrelation {
        long closedSubmit;
        long nextOpenSubmit;
        boolean ownerKnown;
        long ownerUploaderBatches;
        long ownerRetiredRanges;
        long ownerRetiredBytes;
    }

    private static final class Counters {
        long calls;
        long totalNs;
        long maxNs;
        long slowCalls;
        long completed;
        long pending;
        long failed;

        void add(long elapsedNs, boolean wasCompleted, boolean wasFailed) {
            calls++;
            totalNs = saturatedAdd(totalNs, elapsedNs);
            maxNs = Math.max(maxNs, elapsedNs);
            if (elapsedNs >= SLOW_WAIT_NS) slowCalls++;
            if (wasFailed) failed++;
            else if (wasCompleted) completed++;
            else pending++;
        }

        void clear() {
            calls = totalNs = maxNs = slowCalls = completed = pending = failed = 0L;
        }
    }

    private static long saturatedAdd(long left, long right) {
        if (right > 0L && left > Long.MAX_VALUE - right) return Long.MAX_VALUE;
        return left + right;
    }
}
