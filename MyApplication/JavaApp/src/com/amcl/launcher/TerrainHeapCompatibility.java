package com.amcl.launcher;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

/**
 * Bounds RenderPearl terrain destination heaps on OHOS Maleoon devices.
 *
 * <p>Maleoon retains transient backing at buffer-object granularity while a
 * long-lived terrain destination is copied and drawn in flight.  RenderPearl
 * already supports multiple heap objects and stores the concrete buffer in
 * every {@code GpuBufferSlice}; reducing the heap object size therefore keeps
 * unchanged sections valid while bounding the driver's rename/retention unit.
 * Unknown sizes, platforms, and renderers preserve Mojang's original value.</p>
 */
public final class TerrainHeapCompatibility {
    private static final int GL_RENDERER = 0x1f01;
    private static final String OHOS_PROPERTY = "amcl.platform.ohos";
    private static final int ORIGINAL_VERTEX_HEAP = 128 * 1024 * 1024;
    private static final int ORIGINAL_INDEX_HEAP = 32 * 1024 * 1024;
    private static final int MALEOON_VERTEX_SLAB = 16 * 1024 * 1024;
    private static final int MALEOON_INDEX_SLAB = 4 * 1024 * 1024;

    private static final Map<Class<?>, Field> heapSizeFields =
        new HashMap<Class<?>, Field>();
    private static Boolean ohosOverrideForTests;
    private static RendererProbe rendererProbe = new LwjglRendererProbe();
    private static Profile profile;
    private static boolean activeLogged;
    private static boolean fallbackLogged;

    private TerrainHeapCompatibility() {}

    /** Static replacement for audited {@code UberGpuBuffer.heapSize} reads. */
    public static synchronized int effectiveHeapSize(Object uberBuffer) {
        int original;
        try {
            original = readOriginalHeapSize(uberBuffer);
        } catch (RuntimeException failure) {
            fallback("heap-size-access-failed", failure);
            return conservativeOriginal(uberBuffer);
        }
        if (original != ORIGINAL_VERTEX_HEAP && original != ORIGINAL_INDEX_HEAP) {
            return original;
        }

        Profile selected = profile();
        if (!selected.active) return original;
        if (!activeLogged) {
            activeLogged = true;
            System.out.println("[AMCL-TERRAIN-HEAP] schema=1 status=active"
                + " policy=bounded-destination-slabs renderer=" + quoted(selected.renderer)
                + " vertex_original_mib=128 vertex_slab_mib=16"
                + " index_original_mib=32 index_slab_mib=4");
        }
        return original == ORIGINAL_VERTEX_HEAP
            ? MALEOON_VERTEX_SLAB : MALEOON_INDEX_SLAB;
    }

    private static Profile profile() {
        if (profile != null) return profile;
        if (!isOhos()) {
            profile = new Profile(false, "non-ohos");
            return profile;
        }
        // 防御迟到调用/错误变换：非 MG 后端连 renderer 探测也不执行，避免改变其资源策略。
        if (!RendererProfilePolicy.usesMobileGluesCompatibility()) {
            profile = new Profile(false, "backend-out-of-scope");
            return profile;
        }
        try {
            String renderer = rendererProbe.renderer();
            profile = new Profile(isMaleoon(renderer), renderer);
        } catch (RuntimeException failure) {
            fallback("renderer-query-failed", failure);
            profile = new Profile(false, "query-failed");
        }
        return profile;
    }

    private static int readOriginalHeapSize(Object target) {
        if (target == null) throw new IllegalArgumentException("UberGpuBuffer is null");
        Class<?> type = target.getClass();
        Field field = heapSizeFields.get(type);
        if (field == null) {
            field = findField(type, "heapSize");
            field.setAccessible(true);
            heapSizeFields.put(type, field);
        }
        try {
            return field.getInt(target);
        } catch (IllegalAccessException failure) {
            throw new IllegalStateException("cannot read UberGpuBuffer.heapSize", failure);
        }
    }

    private static Field findField(Class<?> type, String name) {
        for (Class<?> current = type; current != null; current = current.getSuperclass()) {
            try {
                return current.getDeclaredField(name);
            } catch (NoSuchFieldException ignored) {}
        }
        throw new IllegalStateException("field not found: " + type.getName() + '.' + name);
    }

    private static int conservativeOriginal(Object target) {
        if (target == null) return ORIGINAL_VERTEX_HEAP;
        try {
            Field field = findField(target.getClass(), "heapSize");
            field.setAccessible(true);
            return field.getInt(target);
        } catch (Exception ignored) {
            // The helper is exact-hash gated, so this is reachable only after
            // a broken runtime reflection contract.  Keep the larger safe size.
            return ORIGINAL_VERTEX_HEAP;
        }
    }

    private static boolean isOhos() {
        return ohosOverrideForTests != null
            ? ohosOverrideForTests.booleanValue()
            : Boolean.parseBoolean(System.getProperty(OHOS_PROPERTY, "false"));
    }

    private static boolean isMaleoon(String renderer) {
        return renderer != null
            && renderer.toLowerCase(Locale.ROOT).contains("maleoon");
    }

    private static void fallback(String reason, RuntimeException failure) {
        if (fallbackLogged) return;
        fallbackLogged = true;
        System.err.println("[AMCL-TERRAIN-HEAP] schema=1 status=fallback action=original-heap-size"
            + " reason=" + reason + " detail=" + compact(failure.toString()));
    }

    private static String quoted(String value) {
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

    private static final class Profile {
        final boolean active;
        final String renderer;

        Profile(boolean active, String renderer) {
            this.active = active;
            this.renderer = renderer;
        }
    }

    /** Clears game-class reflection state after a launch finishes. */
    static synchronized void shutdown() {
        heapSizeFields.clear();
        profile = null;
        activeLogged = fallbackLogged = false;
        rendererProbe = new LwjglRendererProbe();
        ohosOverrideForTests = null;
    }

    static synchronized void setEnvironmentForTests(Boolean ohos, RendererProbe probe) {
        ohosOverrideForTests = ohos;
        rendererProbe = probe == null ? new LwjglRendererProbe() : probe;
        heapSizeFields.clear();
        profile = null;
        activeLogged = fallbackLogged = false;
    }

    static synchronized void resetForTests() {
        setEnvironmentForTests(null, null);
    }
}
