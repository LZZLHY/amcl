package com.amcl.launcher;

import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;

/**
 * Moves RenderPearl 26.3's terrain staging flush from frame end (after the
 * frame graph's draws) to the start of the next frame's render, restoring the
 * 26.1.1 copy-before-draw order that Maleoon's per-buffer hazard tracking
 * needs (report 2026-08-27_MC261_VS_263_RENDER_ARCH_DIFF §1.3/§6 第二刀).
 * Both patched call sites run on the render thread inside LevelRenderer.render,
 * so all state here is render-thread confined and no lock is held across frames.
 */
public final class TerrainUploadTimingCompatibility {
    private static Object pendingDispatcher;
    private static long executedBatches;
    private static long droppedBatches;
    private static boolean firstFlushLogged;

    private static Class<?> rendererClass;
    private static Field dispatcherField;
    private static Method repositionCameraMethod;
    private static Class<?> dispatcherClass;
    private static Method lockMethod;
    private static Method uploadMethod;
    private static Method unlockMethod;

    private static final Object[] NO_ARGS = new Object[0];

    private TerrainUploadTimingCompatibility() {}

    /**
     * Replacement for the frame-end uploadTerrainBuffersToGpu() call site.
     * Only records which dispatcher owes a flush; the surrounding vanilla
     * lock()/unlock() pair still runs as an empty critical section.
     */
    public static void deferFrameEndUpload(Object dispatcher) {
        if (dispatcher == null) throw new NullPointerException("dispatcher");
        pendingDispatcher = dispatcher;
    }

    /**
     * Replacement for the render-entry repositionCamera(...) call site: flush
     * the previous frame's deferred batch before anything else in this frame
     * (repositionCamera precedes prepareChunkRenders and the frame graph, so
     * visibility callbacks still land before this frame's draw list is built),
     * then delegate to the original private method.
     */
    public static void uploadPendingThenRepositionCamera(Object levelRenderer,
                                                         Object cameraRenderState) {
        if (levelRenderer == null) throw new NullPointerException("levelRenderer");
        uploadPendingBatch(levelRenderer);
        invoke(repositionCameraMethod(levelRenderer.getClass()), levelRenderer,
            new Object[] {cameraRenderState}, "repositionCamera");
    }

    /**
     * A dispatcher disposed by resetLevelRenderData has closed its staging and
     * heap buffers, so a batch that no longer matches the renderer's current
     * sectionRenderDispatcher field is dropped instead of flushed.
     */
    private static void uploadPendingBatch(Object levelRenderer) {
        Object pending = pendingDispatcher;
        if (pending == null) return;
        pendingDispatcher = null;
        if (pending != currentDispatcher(levelRenderer)) {
            droppedBatches++;
            System.out.println("[AMCL-UPLOAD-TIMING-PATCH] schema=1 kind=dropped-stale-batch"
                + " dropped=" + droppedBatches);
            return;
        }
        Method lock = dispatcherMethod(pending.getClass(), 0);
        Method upload = dispatcherMethod(pending.getClass(), 1);
        Method unlock = dispatcherMethod(pending.getClass(), 2);
        invoke(lock, pending, NO_ARGS, "lock");
        try {
            invoke(upload, pending, NO_ARGS, "uploadTerrainBuffersToGpu");
            executedBatches++;
            if (!firstFlushLogged) {
                firstFlushLogged = true;
                System.out.println("[AMCL-UPLOAD-TIMING-PATCH] schema=1 kind=first-flush"
                    + " route=A position=frame-start");
            }
        } finally {
            invoke(unlock, pending, NO_ARGS, "unlock");
        }
    }

    private static Object currentDispatcher(Object levelRenderer) {
        Field field = dispatcherField(levelRenderer.getClass());
        try {
            return field.get(levelRenderer);
        } catch (IllegalAccessException failure) {
            throw new IllegalStateException("Cannot read sectionRenderDispatcher", failure);
        }
    }

    private static synchronized Field dispatcherField(Class<?> owner) {
        if (owner == rendererClass && dispatcherField != null) return dispatcherField;
        try {
            Field field = owner.getDeclaredField("sectionRenderDispatcher");
            field.setAccessible(true);
            rendererClass = owner;
            dispatcherField = field;
            repositionCameraMethod = null;
            return field;
        } catch (ReflectiveOperationException failure) {
            throw new IllegalStateException("Audited sectionRenderDispatcher field is"
                + " unavailable on " + owner.getName(), failure);
        }
    }

    private static synchronized Method repositionCameraMethod(Class<?> owner) {
        if (owner == rendererClass && repositionCameraMethod != null) {
            return repositionCameraMethod;
        }
        Method found = null;
        for (Method method : owner.getDeclaredMethods()) {
            if (!"repositionCamera".equals(method.getName())
                    || method.getParameterTypes().length != 1) {
                continue;
            }
            if (found != null) {
                throw new IllegalStateException("Ambiguous repositionCamera on "
                    + owner.getName());
            }
            found = method;
        }
        if (found == null) {
            throw new IllegalStateException("Audited repositionCamera method is unavailable on "
                + owner.getName());
        }
        found.setAccessible(true);
        rendererClass = owner;
        repositionCameraMethod = found;
        return found;
    }

    private static synchronized Method dispatcherMethod(Class<?> owner, int which) {
        if (owner != dispatcherClass || lockMethod == null) {
            try {
                Method lock = owner.getMethod("lock");
                Method upload = owner.getMethod("uploadTerrainBuffersToGpu");
                Method unlock = owner.getMethod("unlock");
                lock.setAccessible(true);
                upload.setAccessible(true);
                unlock.setAccessible(true);
                dispatcherClass = owner;
                lockMethod = lock;
                uploadMethod = upload;
                unlockMethod = unlock;
            } catch (ReflectiveOperationException failure) {
                throw new IllegalStateException("Audited dispatcher flush methods are"
                    + " unavailable on " + owner.getName(), failure);
            }
        }
        return which == 0 ? lockMethod : which == 1 ? uploadMethod : unlockMethod;
    }

    private static void invoke(Method method, Object receiver, Object[] arguments,
                               String label) {
        try {
            method.invoke(receiver, arguments);
        } catch (InvocationTargetException wrapped) {
            Throwable cause = wrapped.getCause() == null ? wrapped : wrapped.getCause();
            if (cause instanceof RuntimeException) throw (RuntimeException) cause;
            if (cause instanceof Error) throw (Error) cause;
            throw new IllegalStateException(label + " threw a checked exception", cause);
        } catch (IllegalAccessException failure) {
            throw new IllegalStateException("Cannot invoke " + label, failure);
        }
    }

    static Object pendingDispatcherForTests() {
        return pendingDispatcher;
    }

    static long executedBatchCountForTests() {
        return executedBatches;
    }

    static long droppedBatchCountForTests() {
        return droppedBatches;
    }

    static synchronized void resetForTests() {
        pendingDispatcher = null;
        executedBatches = 0L;
        droppedBatches = 0L;
        firstFlushLogged = false;
        rendererClass = null;
        dispatcherField = null;
        repositionCameraMethod = null;
        dispatcherClass = null;
        lockMethod = null;
        uploadMethod = null;
        unlockMethod = null;
    }
}
