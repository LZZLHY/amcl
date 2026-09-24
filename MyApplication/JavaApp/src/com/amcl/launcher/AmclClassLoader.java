package com.amcl.launcher;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.net.JarURLConnection;
import java.net.MalformedURLException;
import java.net.URL;
import java.net.URLClassLoader;
import java.net.URLConnection;
import java.security.CodeSigner;
import java.security.CodeSource;
import java.util.jar.JarEntry;
import java.util.jar.Manifest;

/**
 * AMCL 自定义 ClassLoader — 替换系统 ClassLoader。
 *
 * 通过 JVM 参数 -Djava.system.class.loader=com.amcl.launcher.AmclClassLoader
 * 在 JVM 启动时替换系统 ClassLoader。
 *
 * 参考 Amethyst-iOS 的 PojavClassLoader：
 *   所有 MC jar 通过 addURL() 动态添加到系统 CL，
 *   Forge/Fabric 的自定义 ClassLoader 以此为 parent，
 *   从根本上解决 ClassLoader 隔离问题。
 *
 * JVM 要求：替换系统 CL 的类必须有 public Constructor(ClassLoader parent) 签名。
 */
public class AmclClassLoader extends URLClassLoader {

    private static final boolean PLATFORM_COMPATIBILITY_ENABLED =
        Boolean.parseBoolean(System.getProperty("amcl.platform.ohos", "false"))
        && RendererProfilePolicy.usesMobileGluesCompatibility();
    private static final boolean TERRAIN_COMPATIBILITY_ENABLED =
        PLATFORM_COMPATIBILITY_ENABLED;
    private static final String TERRAIN_DISABLED_REASON = terrainDisabledReason(
        Boolean.parseBoolean(System.getProperty("amcl.platform.ohos", "false")),
        System.getProperty("amcl.gl.backend", ""),
        RendererProfilePolicy.profile());
    private static final boolean GPU_WAIT_DIAGNOSTICS_ENABLED =
        TERRAIN_COMPATIBILITY_ENABLED && Boolean.parseBoolean(
            System.getProperty("amcl.gpuWaitDiagnostics", "false"));
    // Default on for OHOS: the un-quota'd single-player burst is a measured
    // stutter source (25-100+ chunk packets in one frame at boundary
    // crossings). -Damcl.singleplayerChunkQuota=false restores vanilla.
    private static final boolean CHUNK_QUOTA_ENABLED =
        PLATFORM_COMPATIBILITY_ENABLED && Boolean.parseBoolean(
            System.getProperty("amcl.singleplayerChunkQuota", "true"));
    // RenderPearl 26.3 blocks each frame until the GPU trails by at most 2
    // submits; on MG+Maleoon that wait is the top render-thread stall (report
    // 2026-08-27 §2/§6). Depth 4 buys burst absorption for ~2 frames of input
    // latency. Recognized values: "4" (default) and "2" (vanilla); anything
    // else fails closed to vanilla and is reported as requested->effective.
    private static final String SUBMIT_DEPTH_REQUESTED =
        System.getProperty("amcl.renderpearl.submitDepth", "4");
    private static final boolean SUBMIT_DEPTH_ENABLED =
        TERRAIN_COMPATIBILITY_ENABLED && "4".equals(SUBMIT_DEPTH_REQUESTED);
    // 26.3 flushes terrain staging after the frame graph's draws; Maleoon
    // serializes that copy against the same-frame reads (report 2026-08-27
    // §1.3/§6 第二刀). Default on moves the flush to the next frame start.
    // Recognized values: "true" (default) and "false" (vanilla frame-end);
    // anything else fails closed to vanilla, reported as requested->effective.
    private static final String UPLOAD_TIMING_REQUESTED =
        System.getProperty("amcl.renderpearl.uploadAtFrameStart", "true");
    private static final boolean UPLOAD_TIMING_ENABLED =
        TERRAIN_COMPATIBILITY_ENABLED && "true".equals(UPLOAD_TIMING_REQUESTED);

    /** Per-loader, all-or-none activation state for the audited terrain patch set. */
    private Boolean terrainPatchSetReady;
    /** Independent exact-build gate so diagnostics cannot disable the terrain correctness patch. */
    private Boolean gpuWaitDiagnosticsPatchSetReady;
    /** Independent exact-build gate for the single-player chunk-send quota patch. */
    private Boolean chunkQuotaPatchSetReady;
    /** Independent exact-build gate for the submit-depth (frames in flight) patch pair. */
    private Boolean submitDepthPatchSetReady;
    /** Independent exact-build gate for the frame-start terrain upload patch. */
    private Boolean uploadTimingPatchSetReady;

    /**
     * JVM 要求的构造函数签名。
     * 当 -Djava.system.class.loader 指定此类时，JVM 会调用此构造函数，
     * 传入默认的系统 ClassLoader 作为 parent。
     */
    public AmclClassLoader(ClassLoader parent) {
        super(new URL[0], parent);
    }

    /**
     * 兼容旧代码的构造函数（保留向后兼容）。
     */
    public AmclClassLoader(URL[] urls, ClassLoader parent) {
        super(urls, parent);
    }

    /**
     * 公开 addURL，允许动态添加 jar 到搜索路径。
     * Forge/Fabric 的 ClassLoader 会通过 parent delegation 找到这些类。
     */
    @Override
    public void addURL(URL url) {
        super.addURL(url);
    }

    /**
     * 动态添加 jar 文件路径。
     */
    public void addJar(String path) {
        if (path == null || path.isEmpty()) return;
        try {
            File f = new File(path);
            addURL(f.toURI().toURL());
        } catch (MalformedURLException e) {
            System.err.println("[AmclClassLoader] Bad jar path: " + path + ": " + e.getMessage());
        }
    }

    /**
     * java.lang.instrument 兼容接口。
     * 某些 Java agent（如 Forge 的 patchjna_agent）会调用此方法。
     */
    public void appendToClassPathForInstrumentation(String path) {
        try {
            File f = new File(path).getCanonicalFile();
            addURL(f.toURI().toURL());
        } catch (IOException e) {
            System.err.println("[AmclClassLoader] appendToClassPath failed: " + path + ": " + e.getMessage());
        }
    }

    /**
     * Verifies the bootstrap/game classpath boundary before game code is loaded.
     * The parent is allowed to own the launcher only; a parent-visible game main
     * would make URLClassLoader's parent-first delegation bypass this loader and
     * all compatibility transformations.
     */
    public void requireIsolatedGameMain(String mainClassName) {
        if (mainClassName == null || mainClassName.isEmpty()) {
            throw new IllegalArgumentException("mainClassName");
        }
        if (TERRAIN_COMPATIBILITY_ENABLED) ensureTerrainPatchSetReady();
        if (GPU_WAIT_DIAGNOSTICS_ENABLED) ensureGpuWaitDiagnosticsPatchSetReady();
        if (CHUNK_QUOTA_ENABLED) ensureChunkQuotaPatchSetReady();
        if (SUBMIT_DEPTH_ENABLED) ensureSubmitDepthPatchSetReady();
        else if (TERRAIN_COMPATIBILITY_ENABLED) logSubmitDepthVanilla();
        if (UPLOAD_TIMING_ENABLED) ensureUploadTimingPatchSetReady();
        else if (TERRAIN_COMPATIBILITY_ENABLED) logUploadTimingVanilla();
        ClassLoader parent = getParent();
        try {
            Class<?> leaked = Class.forName(mainClassName, false, parent);
            throw new IllegalStateException("Game main is visible from bootstrap parent: "
                + mainClassName + " owner=" + ownerName(leaked.getClassLoader())
                + ". JVM java.class.path must contain amcl-launcher.jar only.");
        } catch (ClassNotFoundException expected) {
            System.out.println("[AMCL-CLASSLOADER] schema=1 phase=isolation status=active main="
                + mainClassName + " parent=" + ownerName(parent)
                + " game_urls=" + getURLs().length);
        }
    }

    /** Ensures the direct game entrypoint was actually defined by this loader. */
    public void requireOwnedGameMain(Class<?> mainClass) {
        if (mainClass == null) throw new NullPointerException("mainClass");
        ClassLoader owner = mainClass.getClassLoader();
        if (owner != this) {
            throw new IllegalStateException("Game main bypassed AmclClassLoader: "
                + mainClass.getName() + " owner=" + ownerName(owner));
        }
        System.out.println("[AMCL-CLASSLOADER] schema=1 phase=main-owner status=active main="
            + mainClass.getName() + " owner=" + ownerName(owner)
            + " game_urls=" + getURLs().length);
    }

    /**
     * ⭐ 把 Phase 1.5 已判定的补丁集状态**在换流之后**复述一次。
     *
     * <p>存在的唯一理由是**可见性**：所有 `ensureXxxPatchSetReady()` 都在
     * `requireIsolatedGameMain`（Phase 1.5）里跑，而那时 `System.out` 写的是
     * 应用原始 stdout —— `jvm_launcher.cpp` 在 `JNI_CreateJavaVM` 一返回就把
     * fd 1/2 `dup2` 回原始值，OHOS 直接丢弃。⇒ Phase 1.5 的每一行诊断都看不到，
     * 恰好包括"启动失败时最该看到的那几行"。</p>
     *
     * <p>⚠️ 本方法**不重新判定**，只复述已 memoize 的结果（`null` = 该门从未被求值，
     * 例如开关关闭）。重新判定会掩盖"Phase 1.5 到底算出了什么"这个事实。</p>
     *
     * <p>⚰️ 2026-09-04 曾尝试在 native 侧 `phase_redirectIO` 里 flush 旧 `System.out`
     * 来救回这些行，**真机实测无效**（成因假设错了，见 `mc_launcher.cpp` 的墓碑注释）。
     * 复述是有效的那条路：它跑在 Phase 5，`System.setOut` 已经指向 `mc_output.log`。</p>
     */
    public void reportPatchSetStatesAfterRedirect() {
        System.out.println("[AMCL-RENDERER-QUIRKS] " + RendererProfilePolicy.quirkRuleReport());
        if (!TERRAIN_COMPATIBILITY_ENABLED) {
            System.out.println("[AMCL-PATCH-SETS] schema=1 status=disabled"
                + " family=terrain reason=" + TERRAIN_DISABLED_REASON
                + " chunkQuota=" + describeGate(chunkQuotaPatchSetReady));
            return;
        }
        System.out.println("[AMCL-PATCH-SETS] schema=1 status=reported"
            + " terrain=" + describeGate(terrainPatchSetReady)
            + " chunkQuota=" + describeGate(chunkQuotaPatchSetReady)
            + " gpuWait=" + describeGate(gpuWaitDiagnosticsPatchSetReady)
            + " submitDepth=" + describeGate(submitDepthPatchSetReady)
            + " uploadTiming=" + describeGate(uploadTimingPatchSetReady)
            + " game_urls=" + getURLs().length);
    }

    /**
     * 三值渲染。`not-evaluated` 与 `disabled` **必须能区分** ——
     * 前者意味着那道门从未被求值（开关关闭或作用域外），后者意味着求值了但没通过。
     * 合并成一个词会让"没跑"和"跑了没过"在日志里长得一样（本仓 1000544 那一族）。
     */
    private static String describeGate(Boolean state) {
        if (state == null) return "not-evaluated";
        return state.booleanValue() ? "active" : "disabled";
    }

    static String terrainDisabledReason(boolean ohos, String backend) {
        return terrainDisabledReason(ohos, backend, RendererProfilePolicy.profile());
    }

    static String terrainDisabledReason(boolean ohos, String backend, String profile) {
        if (!ohos) return "platform-marker-missing";
        if ("minecraft-vulkan".equals(profile)) return "game-api-vulkan";
        if (!RendererProfilePolicy.usesMobileGluesCompatibility(profile, backend)) return "backend-out-of-scope";
        String implementation = RendererProfilePolicy.implementationRuleReason(
            System.getProperty("amcl.graphics.implementation", ""));
        if (!"audited-source".equals(implementation)) return implementation;
        return "disabled-at-class-initialization";
    }

    /**
     * Preflights every audited class before transforming any one of them. This
     * prevents an UberGpuBuffer-only patch from retaining ranges forever when a
     * sibling class changed or was supplied by a different game build.
     */
    private synchronized boolean ensureTerrainPatchSetReady() {
        if (terrainPatchSetReady != null) return terrainPatchSetReady.booleanValue();
        String failure = patchSetFailure(TerrainCompatibilityPatcher.PATCH_SET_CLASSES);
        boolean ready = failure == null;
        terrainPatchSetReady = Boolean.valueOf(ready);
        System.out.println("[AMCL-TERRAIN-PATCH-SET] schema=1 status="
            + (ready ? "active" : "disabled")
            + " policy=all-or-none targets=" + TerrainCompatibilityPatcher.PATCH_SET_CLASSES.length
            + (ready ? "" : " reason=" + failure));
        return ready;
    }

    private synchronized boolean ensureGpuWaitDiagnosticsPatchSetReady() {
        if (gpuWaitDiagnosticsPatchSetReady != null) {
            return gpuWaitDiagnosticsPatchSetReady.booleanValue();
        }
        String failure = patchSetFailure(TerrainCompatibilityPatcher.WAIT_DIAGNOSTIC_CLASSES);
        boolean ready = failure == null;
        gpuWaitDiagnosticsPatchSetReady = Boolean.valueOf(ready);
        System.out.println("[AMCL-GPU-WAIT-PATCH-SET] schema=1 status="
            + (ready ? "active" : "disabled")
            + " policy=all-or-none targets="
            + TerrainCompatibilityPatcher.WAIT_DIAGNOSTIC_CLASSES.length
            + (ready ? "" : " reason=" + failure));
        return ready;
    }

    private synchronized boolean ensureChunkQuotaPatchSetReady() {
        if (chunkQuotaPatchSetReady != null) return chunkQuotaPatchSetReady.booleanValue();
        String failure = patchSetFailure(TerrainCompatibilityPatcher.CHUNK_QUOTA_CLASSES);
        boolean ready = failure == null;
        chunkQuotaPatchSetReady = Boolean.valueOf(ready);
        System.out.println("[AMCL-CHUNK-QUOTA-PATCH-SET] schema=1 status="
            + (ready ? "active" : "disabled")
            + " policy=all-or-none targets="
            + TerrainCompatibilityPatcher.CHUNK_QUOTA_CLASSES.length
            + (ready ? "" : " reason=" + failure));
        return ready;
    }

    private synchronized boolean ensureSubmitDepthPatchSetReady() {
        if (submitDepthPatchSetReady != null) return submitDepthPatchSetReady.booleanValue();
        String failure = patchSetFailure(TerrainCompatibilityPatcher.SUBMIT_DEPTH_CLASSES);
        if (failure == null) failure = submitDepthDryRunFailure();
        boolean ready = failure == null;
        submitDepthPatchSetReady = Boolean.valueOf(ready);
        System.out.println("[AMCL-SUBMIT-DEPTH-PATCH-SET] schema=1 status="
            + (ready ? "active" : "disabled")
            + " policy=all-or-none targets="
            + TerrainCompatibilityPatcher.SUBMIT_DEPTH_CLASSES.length
            + " requested=" + SUBMIT_DEPTH_REQUESTED
            + " effective=" + (ready ? "4" : "2")
            + (ready ? "" : " reason=" + failure));
        return ready;
    }

    /**
     * Proves both depth transforms on this exact build before either class
     * loads. Classes are transformed lazily as they load, so a hash-only gate
     * could still deepen the encoder and then fail on PersistentMapping —
     * exactly the split this all-or-none set exists to prevent.
     */
    private String submitDepthDryRunFailure() {
        for (String className : TerrainCompatibilityPatcher.SUBMIT_DEPTH_CLASSES) {
            String resourceName = className.replace('.', '/') + ".class";
            URL resource = findResource(resourceName);
            if (resource == null) return "missing:" + className;
            try (InputStream input = resource.openStream()) {
                TerrainCompatibilityPatcher.applySubmitDepthTransform(className,
                    TerrainCompatibilityPatcher.readAll(input));
            } catch (IOException readFailure) {
                return "read-failed:" + className + ':' + readFailure;
            } catch (RuntimeException transformFailure) {
                return "transform-failed:" + className + ':' + transformFailure.getMessage();
            }
        }
        return null;
    }

    private static void logSubmitDepthVanilla() {
        System.out.println("[AMCL-SUBMIT-DEPTH-PATCH-SET] schema=1 status=vanilla"
            + " requested=" + SUBMIT_DEPTH_REQUESTED + " effective=2 reason="
            + ("2".equals(SUBMIT_DEPTH_REQUESTED)
                ? "property-opt-out" : "invalid-property-value"));
    }

    private synchronized boolean ensureUploadTimingPatchSetReady() {
        if (uploadTimingPatchSetReady != null) return uploadTimingPatchSetReady.booleanValue();
        String failure = patchSetFailure(TerrainCompatibilityPatcher.UPLOAD_TIMING_CLASSES);
        if (failure == null) failure = uploadTimingDryRunFailure();
        boolean ready = failure == null;
        uploadTimingPatchSetReady = Boolean.valueOf(ready);
        System.out.println("[AMCL-UPLOAD-TIMING-PATCH-SET] schema=1 status="
            + (ready ? "active" : "disabled")
            + " policy=all-or-none targets="
            + TerrainCompatibilityPatcher.UPLOAD_TIMING_CLASSES.length
            + " route=A requested=" + UPLOAD_TIMING_REQUESTED
            + " effective=" + (ready ? "frame-start" : "frame-end")
            + (ready ? "" : " reason=" + failure));
        return ready;
    }

    /** Both call-site rewrites are proven on this exact build before the class loads. */
    private String uploadTimingDryRunFailure() {
        for (String className : TerrainCompatibilityPatcher.UPLOAD_TIMING_CLASSES) {
            String resourceName = className.replace('.', '/') + ".class";
            URL resource = findResource(resourceName);
            if (resource == null) return "missing:" + className;
            try (InputStream input = resource.openStream()) {
                TerrainCompatibilityPatcher.applyUploadTimingTransform(className,
                    TerrainCompatibilityPatcher.readAll(input));
            } catch (IOException readFailure) {
                return "read-failed:" + className + ':' + readFailure;
            } catch (RuntimeException transformFailure) {
                return "transform-failed:" + className + ':' + transformFailure.getMessage();
            }
        }
        return null;
    }

    private static void logUploadTimingVanilla() {
        System.out.println("[AMCL-UPLOAD-TIMING-PATCH-SET] schema=1 status=vanilla"
            + " requested=" + UPLOAD_TIMING_REQUESTED + " effective=frame-end reason="
            + ("false".equals(UPLOAD_TIMING_REQUESTED)
                ? "property-opt-out" : "invalid-property-value"));
    }

    private String patchSetFailure(String[] classNames) {
        for (String className : classNames) {
            String resourceName = className.replace('.', '/') + ".class";
            URL resource = findResource(resourceName);
            if (resource == null) return "missing:" + className;
            try (InputStream input = resource.openStream()) {
                byte[] bytes = TerrainCompatibilityPatcher.readAll(input);
                if (!TerrainCompatibilityPatcher.isExpectedClass(className, bytes)) {
                    return "hash-mismatch:" + className + ':'
                        + TerrainCompatibilityPatcher.sha256(bytes);
                }
            } catch (IOException readFailure) {
                return "read-failed:" + className + ':' + readFailure;
            }
        }
        return null;
    }

    private static String ownerName(ClassLoader loader) {
        return loader == null ? "bootstrap" : loader.getClass().getName();
    }

    @Override
    protected Class<?> findClass(String name) throws ClassNotFoundException {
        if ((!TERRAIN_COMPATIBILITY_ENABLED && !CHUNK_QUOTA_ENABLED)
                || !TerrainCompatibilityPatcher.isTarget(name)) {
            return super.findClass(name);
        }
        if (TerrainCompatibilityPatcher.isTerrainTarget(name)
                && (!TERRAIN_COMPATIBILITY_ENABLED || !ensureTerrainPatchSetReady())) {
            return super.findClass(name);
        }
        if (TerrainCompatibilityPatcher.isChunkQuotaTarget(name)
                && (!CHUNK_QUOTA_ENABLED || !ensureChunkQuotaPatchSetReady())) {
            return super.findClass(name);
        }
        if (TerrainCompatibilityPatcher.isUploadTimingTarget(name)
                && (!UPLOAD_TIMING_ENABLED || !ensureUploadTimingPatchSetReady())) {
            return super.findClass(name);
        }
        // GlCommandEncoder belongs to both GL patch sets: each feature clears
        // its own gate and the class is transformed when at least one applies.
        boolean applyWaitDiagnostics = TerrainCompatibilityPatcher.isWaitDiagnosticsTarget(name)
            && GPU_WAIT_DIAGNOSTICS_ENABLED && ensureGpuWaitDiagnosticsPatchSetReady();
        boolean applySubmitDepth = TerrainCompatibilityPatcher.isSubmitDepthTarget(name)
            && SUBMIT_DEPTH_ENABLED && ensureSubmitDepthPatchSetReady();
        if ((TerrainCompatibilityPatcher.isWaitDiagnosticsTarget(name)
                || TerrainCompatibilityPatcher.isSubmitDepthTarget(name))
                && !applyWaitDiagnostics && !applySubmitDepth) {
            return super.findClass(name);
        }

        String resourceName = name.replace('.', '/') + ".class";
        URL resource = findResource(resourceName);
        if (resource == null) return super.findClass(name);
        try {
            ClassOrigin origin = readClassOrigin(resource);
            byte[] patched = TerrainCompatibilityPatcher.patchKnownClass(name, origin.bytes,
                applyWaitDiagnostics, applySubmitDepth);
            if (patched == origin.bytes) return super.findClass(name);
            return defineTransformedClass(name, patched, origin);
        } catch (IOException failure) {
            throw new ClassNotFoundException("Cannot read compatibility target " + name, failure);
        }
    }

    /**
     * Reads the class and its security metadata through the same connection.
     * JarEntry signers are populated only after the entry stream reaches EOF.
     */
    static ClassOrigin readClassOrigin(URL resource) throws IOException {
        URLConnection connection = resource.openConnection();
        byte[] bytes;
        try (InputStream input = connection.getInputStream()) {
            bytes = TerrainCompatibilityPatcher.readAll(input);
        }

        if (connection instanceof JarURLConnection) {
            JarURLConnection jar = (JarURLConnection) connection;
            JarEntry entry = jar.getJarEntry();
            CodeSigner[] signers = entry == null ? null : entry.getCodeSigners();
            return new ClassOrigin(bytes, jar.getManifest(), jar.getJarFileURL(),
                new CodeSource(jar.getJarFileURL(), signers));
        }
        return new ClassOrigin(bytes, null, resource,
            new CodeSource(resource, (CodeSigner[]) null));
    }

    /** Defines transformed bytes in the original JAR's package and protection domain. */
    Class<?> defineTransformedClass(String name, byte[] transformed, ClassOrigin origin) {
        definePackageIfNecessary(name, origin);
        return defineClass(name, transformed, 0, transformed.length, origin.codeSource);
    }

    private void definePackageIfNecessary(String className, ClassOrigin origin) {
        int separator = className.lastIndexOf('.');
        if (separator <= 0) return;
        String packageName = className.substring(0, separator);
        if (getPackage(packageName) != null) return;
        try {
            if (origin.manifest != null) {
                definePackage(packageName, origin.manifest, origin.sealBase);
            } else {
                definePackage(packageName, null, null, null, null, null, null, null);
            }
        } catch (IllegalArgumentException race) {
            if (getPackage(packageName) == null) throw race;
        }
    }

    /** Immutable origin metadata used by both production loading and signer tests. */
    static final class ClassOrigin {
        final byte[] bytes;
        final Manifest manifest;
        final URL sealBase;
        final CodeSource codeSource;

        ClassOrigin(byte[] bytes, Manifest manifest, URL sealBase, CodeSource codeSource) {
            this.bytes = bytes;
            this.manifest = manifest;
            this.sealBase = sealBase;
            this.codeSource = codeSource;
        }
    }
}
