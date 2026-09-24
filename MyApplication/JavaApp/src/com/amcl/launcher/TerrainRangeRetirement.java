package com.amcl.launcher;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;

/** Delays TLSF range reuse until the owning GL context has consumed old draws. */
public final class TerrainRangeRetirement {
    private static final int MAX_PENDING_BATCHES = 8;
    private static final long MAX_PENDING_BYTES = 64L * 1024L * 1024L;
    private static final int GL_SYNC_GPU_COMMANDS_COMPLETE = 0x9117;
    private static final int GL_SYNC_FLUSH_COMMANDS_BIT = 0x00000001;
    private static final int GL_ALREADY_SIGNALED = 0x911a;
    private static final int GL_TIMEOUT_EXPIRED = 0x911b;
    private static final int GL_CONDITION_SATISFIED = 0x911c;
    private static final int GL_WAIT_FAILED = 0x911d;
    private static final long GL_TIMEOUT_IGNORED = -1L;
    private static final boolean GPU_WAIT_DIAGNOSTICS_ENABLED =
        Boolean.parseBoolean(System.getProperty("amcl.gpuWaitDiagnostics", "false"));

    private static final ThreadLocal<CurrentBatch> currentBatch =
        new ThreadLocal<CurrentBatch>() {
            @Override
            protected CurrentBatch initialValue() {
                return new CurrentBatch();
            }
        };
    private static final Map<Object, ContextState> contexts =
        new IdentityHashMap<Object, ContextState>();
    private static final List<RetiredRange> quarantined =
        new ArrayList<RetiredRange>();
    private static final Map<Class<?>, Method> freeMethods =
        new HashMap<Class<?>, Method>();
    private static final Map<Class<?>, Method> sizeMethods =
        new HashMap<Class<?>, Method>();
    private static final Map<Class<?>, Method> rotateMethods =
        new HashMap<Class<?>, Method>();

    private static FenceBackend fenceBackend;
    private static long deferredRanges;
    private static long deferredBytes;
    private static long releasedRanges;
    private static long releasedBytes;
    private static long completedBatches;
    private static long forcedWaits;
    private static long pendingBytesHighWatermark;
    private static long contextMismatchCount;
    private static boolean activeLogged;
    private static boolean fallbackLogged;
    private static boolean unknownSizeLogged;

    private TerrainRangeRetirement() {}

    /** Replacement for TlsfAllocator.free(Allocation). */
    public static synchronized void deferFree(Object allocator, Object allocation) {
        if (allocator == null || allocation == null) return;

        RetiredRange range = new RetiredRange(allocator, allocation, allocationSize(allocation));
        Object contextKey;
        try {
            contextKey = backend().contextKey();
            if (contextKey == null) throw new IllegalStateException("GL context identity is unavailable");
        } catch (RuntimeException failure) {
            quarantine(range, "context-query-failed", failure);
            return;
        }

        CurrentBatch current = currentBatch.get();
        if (current.contextKey != null && current.contextKey != contextKey && !current.ranges.isEmpty()) {
            contextMismatchCount++;
            quarantined.addAll(current.ranges);
            fallback("context-changed-before-uploader-close", null);
            current.clear();
        }
        current.contextKey = contextKey;
        current.ranges.add(range);
        current.bytes = saturatedAdd(current.bytes, range.bytes);
        deferredRanges++;
        deferredBytes = saturatedAdd(deferredBytes, range.bytes);
        if (!activeLogged) {
            activeLogged = true;
            System.out.println("[AMCL-TERRAIN-RETIRE] schema=2 status=active"
                + " policy=context-fenced-byte-bounded-range-reuse"
                + " max_pending_batches=" + MAX_PENDING_BATCHES
                + " max_pending_mib=" + (MAX_PENDING_BYTES / 1048576L));
        }
    }

    /** Replacement for StagingBuffer.tryClearAndRotate() at Uploader.close(). */
    public static synchronized void finishUploadBatch(Object stagingBuffer) {
        invokeRotate(stagingBuffer);

        if (GPU_WAIT_DIAGNOSTICS_ENABLED) {
            CurrentBatch observed = currentBatch.get();
            TerrainWaitDiagnostics.noteTerrainBatch(observed.ranges.size(), observed.bytes);
        }

        FenceBackend fences;
        Object contextKey;
        try {
            fences = backend();
            contextKey = fences.contextKey();
            if (contextKey == null) throw new IllegalStateException("GL context identity is unavailable");
        } catch (RuntimeException failure) {
            CurrentBatch current = currentBatch.get();
            if (!current.ranges.isEmpty()) {
                quarantined.addAll(current.ranges);
                current.clear();
            }
            fallback("context-query-at-batch-end", failure);
            return;
        }

        ContextState state = contextState(contextKey);
        pollCompletedBatches(state, fences);

        CurrentBatch current = currentBatch.get();
        if (current.ranges.isEmpty()) return;
        if (current.contextKey != contextKey) {
            contextMismatchCount++;
            quarantined.addAll(current.ranges);
            current.clear();
            fallback("context-mismatch-at-batch-end", null);
            return;
        }

        List<RetiredRange> ranges = new ArrayList<RetiredRange>(current.ranges);
        long bytes = current.bytes;
        current.clear();
        boolean enqueued = false;
        try {
            long fence = fences.createFence();
            if (fence == 0L) throw new IllegalStateException("glFenceSync returned zero");
            state.pending.addLast(new RetirementBatch(fence, ranges, bytes));
            state.pendingBytes = saturatedAdd(state.pendingBytes, bytes);
            enqueued = true;
            pendingBytesHighWatermark = Math.max(pendingBytesHighWatermark, totalPendingBytes());
            enforceBudget(state, fences);
            reportProgress();
        } catch (RuntimeException failure) {
            if (enqueued) {
                fallback("budget-wait-or-enqueued-release", failure);
                finishAndDrainState(state, fences);
            } else {
                finishThenReleaseUnqueued(fences, ranges, "fence-create", failure);
            }
        }
    }

    /** Best-effort final drain; called while the game launch is unwinding. */
    public static synchronized void shutdown() {
        long abandonedRanges = quarantined.size();
        try {
            FenceBackend fences = fenceBackend;
            if (fences != null) {
                Object key = fences.contextKey();
                CurrentBatch current = currentBatch.get();
                if (!current.ranges.isEmpty() && current.contextKey == key) {
                    fences.finish();
                    releaseRanges(current.ranges);
                    current.clear();
                } else if (!current.ranges.isEmpty()) {
                    abandonedRanges += current.ranges.size();
                    current.clear();
                }
                ContextState state = contexts.get(key);
                if (state != null) {
                    finishAndDrainState(state, fences);
                }
            }
        } catch (RuntimeException failure) {
            fallback("shutdown-drain", failure);
        }

        for (ContextState state : contexts.values()) {
            for (RetirementBatch batch : state.pending) abandonedRanges += batch.unreleasedCount();
        }
        System.out.println("[AMCL-TERRAIN-RETIRE] schema=2 status=shutdown deferred="
            + deferredRanges + " deferred_mib=" + mib(deferredBytes)
            + " released=" + releasedRanges + " released_mib=" + mib(releasedBytes)
            + " abandoned_ranges=" + abandonedRanges
            + " pending_high_watermark_mib=" + mib(pendingBytesHighWatermark)
            + " forced_waits=" + forcedWaits
            + " context_mismatches=" + contextMismatchCount);

        currentBatch.remove();
        contexts.clear();
        quarantined.clear();
        freeMethods.clear();
        sizeMethods.clear();
        rotateMethods.clear();
        fenceBackend = null;
        deferredRanges = deferredBytes = releasedRanges = releasedBytes = 0L;
        completedBatches = forcedWaits = pendingBytesHighWatermark = contextMismatchCount = 0L;
        activeLogged = fallbackLogged = unknownSizeLogged = false;
    }

    private static ContextState contextState(Object key) {
        ContextState state = contexts.get(key);
        if (state == null) {
            state = new ContextState();
            contexts.put(key, state);
        }
        return state;
    }

    private static void pollCompletedBatches(ContextState state, FenceBackend fences) {
        try {
            while (!state.pending.isEmpty() && fences.isSignaled(state.pending.peekFirst().fence)) {
                releaseOldest(state, fences, false);
            }
        } catch (RuntimeException failure) {
            fallback("nonblocking-fence-poll", failure);
            finishAndDrainState(state, fences);
        }
    }

    private static void enforceBudget(ContextState state, FenceBackend fences) {
        while (state.pending.size() > MAX_PENDING_BATCHES || state.pendingBytes > MAX_PENDING_BYTES) {
            forcedWaits++;
            releaseOldest(state, fences, true);
        }
    }

    private static void releaseOldest(ContextState state, FenceBackend fences, boolean wait) {
        RetirementBatch batch = state.pending.peekFirst();
        if (batch == null) return;
        if (wait) fences.await(batch.fence);
        releaseBatch(batch, fences);
        state.pending.removeFirst();
        state.pendingBytes = Math.max(0L, state.pendingBytes - batch.bytes);
        completedBatches++;
    }

    private static void releaseBatch(RetirementBatch batch, FenceBackend fences) {
        releaseRanges(batch.ranges);
        fences.deleteFence(batch.fence);
    }

    private static void releaseRanges(List<RetiredRange> ranges) {
        RuntimeException firstFailure = null;
        for (RetiredRange range : ranges) {
            if (range.released) continue;
            try {
                invokeFree(range.allocator, range.allocation);
                range.released = true;
                releasedRanges++;
                releasedBytes = saturatedAdd(releasedBytes, range.bytes);
            } catch (RuntimeException failure) {
                if (firstFailure == null) firstFailure = failure;
            }
        }
        if (firstFailure != null) throw firstFailure;
    }

    private static void finishAndDrainState(ContextState state, FenceBackend fences) {
        try {
            fences.finish();
        } catch (RuntimeException failure) {
            fallback("glFinish-before-safe-release", failure);
            return;
        }
        while (!state.pending.isEmpty()) {
            try {
                releaseOldest(state, fences, false);
            } catch (RuntimeException failure) {
                fallback("release-after-glFinish", failure);
                return;
            }
        }
    }

    private static void finishThenReleaseUnqueued(FenceBackend fences, List<RetiredRange> ranges,
                                                   String action, RuntimeException cause) {
        fallback(action, cause);
        try {
            fences.finish();
            releaseRanges(ranges);
        } catch (RuntimeException failure) {
            quarantined.addAll(ranges);
            fallback(action + "-quarantined", failure);
        }
    }

    private static void quarantine(RetiredRange range, String action, RuntimeException cause) {
        quarantined.add(range);
        deferredRanges++;
        deferredBytes = saturatedAdd(deferredBytes, range.bytes);
        fallback(action + "-quarantined", cause);
    }

    private static long allocationSize(Object allocation) {
        Method method = sizeMethods.get(allocation.getClass());
        if (method == null) {
            try {
                method = findMethod(allocation.getClass(), "getSize");
                sizeMethods.put(allocation.getClass(), method);
            } catch (RuntimeException failure) {
                if (!unknownSizeLogged) {
                    unknownSizeLogged = true;
                    System.err.println("[AMCL-TERRAIN-RETIRE] schema=2 status=degraded"
                        + " reason=allocation-size-unavailable accounting=fallback-one-byte detail="
                        + compact(failure));
                }
                return 1L;
            }
        }
        Object result = invokeResult(method, allocation, new Object[0]);
        if (!(result instanceof Number)) return 1L;
        long bytes = ((Number) result).longValue();
        return bytes > 0L ? bytes : 1L;
    }

    private static void invokeFree(Object allocator, Object allocation) {
        Method method = freeMethods.get(allocator.getClass());
        if (method == null) {
            method = findSingleArgumentMethod(allocator.getClass(), "free", allocation.getClass());
            freeMethods.put(allocator.getClass(), method);
        }
        invokeResult(method, allocator, new Object[] {allocation});
    }

    private static void invokeRotate(Object stagingBuffer) {
        if (stagingBuffer == null) throw new NullPointerException("stagingBuffer");
        Method method = rotateMethods.get(stagingBuffer.getClass());
        if (method == null) {
            method = findMethod(stagingBuffer.getClass(), "tryClearAndRotate");
            rotateMethods.put(stagingBuffer.getClass(), method);
        }
        invokeResult(method, stagingBuffer, new Object[0]);
    }

    private static Method findSingleArgumentMethod(Class<?> type, String name, Class<?> argumentType) {
        for (Class<?> current = type; current != null; current = current.getSuperclass()) {
            Method[] methods = current.getDeclaredMethods();
            for (Method method : methods) {
                Class<?>[] parameters = method.getParameterTypes();
                if (method.getName().equals(name) && parameters.length == 1
                    && parameters[0].isAssignableFrom(argumentType)) {
                    method.setAccessible(true);
                    return method;
                }
            }
        }
        throw new IllegalStateException("method not found: " + type.getName() + '.' + name);
    }

    private static Method findMethod(Class<?> type, String name) {
        for (Class<?> current = type; current != null; current = current.getSuperclass()) {
            try {
                Method method = current.getDeclaredMethod(name);
                method.setAccessible(true);
                return method;
            } catch (NoSuchMethodException ignored) {}
        }
        throw new IllegalStateException("method not found: " + type.getName() + '.' + name);
    }

    private static Object invokeResult(Method method, Object target, Object[] arguments) {
        try {
            return method.invoke(target, arguments);
        } catch (IllegalAccessException failure) {
            throw new IllegalStateException("cannot access " + method, failure);
        } catch (InvocationTargetException failure) {
            Throwable cause = failure.getCause();
            if (cause instanceof RuntimeException) throw (RuntimeException) cause;
            if (cause instanceof Error) throw (Error) cause;
            throw new IllegalStateException("invocation failed: " + method, cause);
        }
    }

    private static FenceBackend backend() {
        if (fenceBackend == null) fenceBackend = new ReflectiveGlFenceBackend();
        return fenceBackend;
    }

    private static long totalPendingBytes() {
        long total = currentBatch.get().bytes;
        for (ContextState state : contexts.values()) total = saturatedAdd(total, state.pendingBytes);
        return total;
    }

    private static void reportProgress() {
        long batches = completedBatches;
        int pendingRanges = quarantined.size() + currentBatch.get().ranges.size();
        int pendingBatches = 0;
        for (ContextState state : contexts.values()) {
            batches += state.pending.size();
            pendingBatches += state.pending.size();
            for (RetirementBatch batch : state.pending) pendingRanges += batch.unreleasedCount();
        }
        if (batches <= 4 || (batches & 63L) == 0L) {
            System.out.println("[AMCL-TERRAIN-RETIRE] schema=2 status=running deferred=" + deferredRanges
                + " deferred_mib=" + mib(deferredBytes)
                + " released=" + releasedRanges + " released_mib=" + mib(releasedBytes)
                + " pending_contexts=" + contexts.size()
                + " pending_batches=" + pendingBatches
                + " pending_ranges=" + pendingRanges
                + " pending_mib=" + mib(totalPendingBytes())
                + " forced_waits=" + forcedWaits);
        }
    }

    private static void fallback(String action, RuntimeException failure) {
        if (fallbackLogged) return;
        fallbackLogged = true;
        System.err.println("[AMCL-TERRAIN-RETIRE] schema=2 status=fallback"
            + " action=finish-then-free-or-quarantine reason=" + action
            + (failure == null ? "" : " detail=" + compact(failure)));
    }

    private static String compact(Throwable failure) {
        if (failure == null) return "unknown";
        return String.valueOf(failure).replace('\n', ' ').replace('\r', ' ');
    }

    private static long saturatedAdd(long left, long right) {
        if (right > 0L && left > Long.MAX_VALUE - right) return Long.MAX_VALUE;
        return left + right;
    }

    private static String mib(long bytes) {
        return String.format(java.util.Locale.ROOT, "%.3f", ((double) bytes) / 1048576.0);
    }

    interface FenceBackend {
        long createFence();
        boolean isSignaled(long fence);
        void await(long fence);
        void deleteFence(long fence);
        default Object contextKey() { return this; }
        default void finish() {}
    }

    private static final class ReflectiveGlFenceBackend implements FenceBackend {
        private final Method getCapabilities;
        private final Method fenceSync;
        private final Method clientWaitSync;
        private final Method deleteSync;
        private final Method finish;

        ReflectiveGlFenceBackend() {
            try {
                ClassLoader loader = Thread.currentThread().getContextClassLoader();
                Class<?> gl = Class.forName("org.lwjgl.opengl.GL", true, loader);
                Class<?> gl11 = Class.forName("org.lwjgl.opengl.GL11C", true, loader);
                Class<?> gl32 = Class.forName("org.lwjgl.opengl.GL32C", true, loader);
                getCapabilities = gl.getMethod("getCapabilities");
                finish = gl11.getMethod("glFinish");
                fenceSync = gl32.getMethod("glFenceSync", Integer.TYPE, Integer.TYPE);
                clientWaitSync = gl32.getMethod("glClientWaitSync", Long.TYPE, Integer.TYPE, Long.TYPE);
                deleteSync = gl32.getMethod("glDeleteSync", Long.TYPE);
            } catch (Exception failure) {
                throw new IllegalStateException("LWJGL GL context/fence API unavailable", failure);
            }
        }

        public Object contextKey() {
            Object result = invokeStatic(getCapabilities, new Object[0]);
            if (result == null) throw new IllegalStateException("GL.getCapabilities returned null");
            return result;
        }

        public long createFence() {
            return ((Long) invokeStatic(fenceSync,
                new Object[] {Integer.valueOf(GL_SYNC_GPU_COMMANDS_COMPLETE), Integer.valueOf(0)})).longValue();
        }

        public boolean isSignaled(long fence) {
            int status = ((Integer) invokeStatic(clientWaitSync,
                new Object[] {Long.valueOf(fence), Integer.valueOf(0), Long.valueOf(0L)})).intValue();
            if (status == GL_ALREADY_SIGNALED || status == GL_CONDITION_SATISFIED) return true;
            if (status == GL_TIMEOUT_EXPIRED) return false;
            if (status == GL_WAIT_FAILED) throw new IllegalStateException("glClientWaitSync failed");
            throw new IllegalStateException("unexpected glClientWaitSync status 0x"
                + Integer.toHexString(status));
        }

        public void await(long fence) {
            int status = ((Integer) invokeStatic(clientWaitSync,
                new Object[] {Long.valueOf(fence), Integer.valueOf(GL_SYNC_FLUSH_COMMANDS_BIT),
                    Long.valueOf(GL_TIMEOUT_IGNORED)})).intValue();
            if (status != GL_ALREADY_SIGNALED && status != GL_CONDITION_SATISFIED) {
                throw new IllegalStateException("blocking glClientWaitSync returned 0x"
                    + Integer.toHexString(status));
            }
        }

        public void deleteFence(long fence) {
            invokeStatic(deleteSync, new Object[] {Long.valueOf(fence)});
        }

        public void finish() {
            invokeStatic(finish, new Object[0]);
        }

        private static Object invokeStatic(Method method, Object[] arguments) {
            return invokeResult(method, null, arguments);
        }
    }

    private static final class CurrentBatch {
        Object contextKey;
        final List<RetiredRange> ranges = new ArrayList<RetiredRange>();
        long bytes;

        void clear() {
            contextKey = null;
            ranges.clear();
            bytes = 0L;
        }
    }

    private static final class ContextState {
        final ArrayDeque<RetirementBatch> pending = new ArrayDeque<RetirementBatch>();
        long pendingBytes;
    }

    private static final class RetiredRange {
        final Object allocator;
        final Object allocation;
        final long bytes;
        boolean released;

        RetiredRange(Object allocator, Object allocation, long bytes) {
            this.allocator = allocator;
            this.allocation = allocation;
            this.bytes = bytes;
        }
    }

    private static final class RetirementBatch {
        final long fence;
        final List<RetiredRange> ranges;
        final long bytes;

        RetirementBatch(long fence, List<RetiredRange> ranges, long bytes) {
            this.fence = fence;
            this.ranges = ranges;
            this.bytes = bytes;
        }

        int unreleasedCount() {
            int count = 0;
            for (RetiredRange range : ranges) if (!range.released) count++;
            return count;
        }
    }

    // Test hooks are package-private and are not called by production code.
    static synchronized void setFenceBackendForTests(FenceBackend backend) {
        currentBatch.remove();
        contexts.clear();
        quarantined.clear();
        freeMethods.clear();
        sizeMethods.clear();
        rotateMethods.clear();
        fenceBackend = backend;
        deferredRanges = deferredBytes = releasedRanges = releasedBytes = 0L;
        completedBatches = forcedWaits = pendingBytesHighWatermark = contextMismatchCount = 0L;
        activeLogged = fallbackLogged = unknownSizeLogged = false;
    }

    static synchronized int pendingRangeCountForTests() {
        int result = currentBatch.get().ranges.size() + quarantined.size();
        for (ContextState state : contexts.values()) {
            for (RetirementBatch batch : state.pending) result += batch.unreleasedCount();
        }
        return result;
    }
}
