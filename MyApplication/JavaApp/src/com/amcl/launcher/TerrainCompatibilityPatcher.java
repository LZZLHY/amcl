package com.amcl.launcher;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HashMap;
import java.util.Map;

/**
 * Exact-build compatibility patch for RenderPearl's terrain upload lifecycle.
 *
 * <p>The supported Snapshot 6 and Snapshot 9 classes free a TLSF range before
 * the two-frames-in-flight GL encoder has proved that the previous draw stopped
 * reading it.  Maleoon is also excluded from RenderPearl's existing fenced
 * persistent staging path by a desktop-only heuristic.  This patch changes
 * only the audited fixed-width bytecodes needed to select that staging path,
 * route retirement through {@link TerrainRangeRetirement}, and bound Maleoon's
 * destination-buffer hazard granularity through
 * {@link TerrainHeapCompatibility}.  Every class hash that has not been
 * audited is returned unchanged.</p>
 */
final class TerrainCompatibilityPatcher {
    static final String UBER_CLASS = "com.mojang.blaze3d.vertex.UberGpuBuffer";
    static final String STAGING_CLASS = "com.mojang.blaze3d.vertex.StagingBuffer";
    static final String UPLOADER_CLASS = "com.mojang.blaze3d.vertex.StagingBuffer$Uploader";
    static final String GL_COMMAND_ENCODER_CLASS =
        "com.mojang.renderpearl.backend.opengl.GlCommandEncoder";
    static final String GL_FENCE_CLASS = "com.mojang.renderpearl.backend.opengl.GlFence";
    static final String GL_TRANSIENT_PM_CLASS =
        "com.mojang.renderpearl.backend.opengl.GlTransientMemory$PersistentMapping";
    static final String PLAYER_CHUNK_SENDER_CLASS =
        "net.minecraft.server.network.PlayerChunkSender";
    static final String LEVEL_RENDERER_CLASS = "net.minecraft.client.renderer.LevelRenderer";

    static final String UBER_SHA256 =
        "3686a310e6dcd49aa8202354a642ccf6006eed2d6398f6e2cd39c95b68728b42";
    static final String STAGING_SHA256 =
        "241c02cbb568961adea3a160e0eb42def1f6a79aa18526cfcb7f04a30a43d1be";
    static final String UPLOADER_SHA256 =
        "7c5fae41b98b67cc95d7e39caa4e63f2cd69bd0b72b175fea5d902deb180514f";
    static final String GL_COMMAND_ENCODER_SHA256 =
        "2a7b83e6b8e684ac5253cbc53b2e57987365f2682ed999ce7d3f998b26b4160b";
    static final String GL_FENCE_SHA256 =
        "aca92617853f70104f1e1c1865a08848575fd54d1d85a60e21359d13ea38f43b";
    static final String GL_TRANSIENT_PM_SHA256 =
        "38f4b2ff0fdc9c718c7232dc2ee2d8b9d741617fa66eee2f26db4762b2f43f3e";
    static final String PLAYER_CHUNK_SENDER_SHA256 =
        "e0234c1c964e62bf6af1eaba79a190d518da9f44ee7cf60cec5f26f2cbfba750";
    static final String LEVEL_RENDERER_SHA256 =
        "6895b37a9fd277f6433f04b40a322a1e9c888f3eabe17a18bf30d91ffa4daec5";
    private static final String HELPER = "com/amcl/launcher/TerrainRangeRetirement";
    private static final String HEAP_HELPER =
        "com/amcl/launcher/TerrainHeapCompatibility";
    private static final String STAGING_HELPER =
        "com/amcl/launcher/TerrainStagingCompatibility";
    private static final String WAIT_HELPER =
        "com/amcl/launcher/TerrainWaitDiagnostics";
    private static final String CHUNK_QUOTA_HELPER =
        "com/amcl/launcher/ChunkSendQuotaCompatibility";
    private static final String UPLOAD_TIMING_HELPER =
        "com/amcl/launcher/TerrainUploadTimingCompatibility";

    static final String[] PATCH_SET_CLASSES = {
        UBER_CLASS, STAGING_CLASS, UPLOADER_CLASS
    };
    static final String[] WAIT_DIAGNOSTIC_CLASSES = {
        GL_COMMAND_ENCODER_CLASS, GL_FENCE_CLASS
    };
    static final String[] CHUNK_QUOTA_CLASSES = { PLAYER_CHUNK_SENDER_CLASS };
    static final String[] UPLOAD_TIMING_CLASSES = { LEVEL_RENDERER_CLASS };
    // All-or-none pair: a deepened encoder with 2-slot rotations would recycle
    // transient memory the GPU may still read (or index past the array).
    static final String[] SUBMIT_DEPTH_CLASSES = {
        GL_COMMAND_ENCODER_CLASS, GL_TRANSIENT_PM_CLASS
    };

    // iconst_2 rewrite contexts: the audited sites size a `newarray long`
    // (0xbc + array-type tag 11) and an `anewarray` (pool operand varies).
    private static final int[] NEWARRAY_LONG_CONTEXT = {0xbc, 0x0b};
    private static final int[] ANEWARRAY_CONTEXT = {0xbd};

    private TerrainCompatibilityPatcher() {}

    static boolean isTerrainTarget(String className) {
        return UBER_CLASS.equals(className) || STAGING_CLASS.equals(className)
            || UPLOADER_CLASS.equals(className);
    }

    static boolean isWaitDiagnosticsTarget(String className) {
        return GL_COMMAND_ENCODER_CLASS.equals(className) || GL_FENCE_CLASS.equals(className);
    }

    static boolean isChunkQuotaTarget(String className) {
        return PLAYER_CHUNK_SENDER_CLASS.equals(className);
    }

    static boolean isUploadTimingTarget(String className) {
        return LEVEL_RENDERER_CLASS.equals(className);
    }

    static boolean isSubmitDepthTarget(String className) {
        return GL_COMMAND_ENCODER_CLASS.equals(className)
            || GL_TRANSIENT_PM_CLASS.equals(className);
    }

    static boolean isTarget(String className) {
        return isTerrainTarget(className) || isWaitDiagnosticsTarget(className)
            || isChunkQuotaTarget(className) || isSubmitDepthTarget(className)
            || isUploadTimingTarget(className);
    }

    static String expectedHash(String className) {
        if (UBER_CLASS.equals(className)) return UBER_SHA256;
        if (STAGING_CLASS.equals(className)) return STAGING_SHA256;
        if (UPLOADER_CLASS.equals(className)) return UPLOADER_SHA256;
        if (GL_COMMAND_ENCODER_CLASS.equals(className)) return GL_COMMAND_ENCODER_SHA256;
        if (GL_FENCE_CLASS.equals(className)) return GL_FENCE_SHA256;
        if (GL_TRANSIENT_PM_CLASS.equals(className)) return GL_TRANSIENT_PM_SHA256;
        if (PLAYER_CHUNK_SENDER_CLASS.equals(className)) return PLAYER_CHUNK_SENDER_SHA256;
        if (LEVEL_RENDERER_CLASS.equals(className)) return LEVEL_RENDERER_SHA256;
        return null;
    }

    static boolean isExpectedClass(String className, byte[] classBytes) {
        String expected = expectedHash(className);
        return expected != null && expected.equals(sha256(classBytes));
    }

    /**
     * The two flags select which independently gated features may transform
     * the shared GlCommandEncoder; the caller has already cleared each
     * feature's all-or-none patch set before passing {@code true}.
     */
    static byte[] patchKnownClass(String className, byte[] classBytes,
                                  boolean applyWaitDiagnostics, boolean applySubmitDepth) {
        String hash = sha256(classBytes);
        try {
            if (UBER_CLASS.equals(className) && UBER_SHA256.equals(hash)) {
                byte[] patched = patchInvocation(classBytes,
                    "com/mojang/blaze3d/vertex/TlsfAllocator", "free",
                    "(Lcom/mojang/blaze3d/vertex/TlsfAllocator$Allocation;)V",
                    HELPER, "deferFree", "(Ljava/lang/Object;Ljava/lang/Object;)V");
                patched = patchFieldRead(patched,
                    "com/mojang/blaze3d/vertex/UberGpuBuffer", "heapSize", "I",
                    HEAP_HELPER, "effectiveHeapSize", "(Ljava/lang/Object;)I", 2);
                activated(className, hash,
                    "fence-delayed-range-retirement+maleoon-bounded-destination-slabs");
                return patched;
            }
            if (STAGING_CLASS.equals(className) && STAGING_SHA256.equals(hash)) {
                byte[] patched = patchInvocation(classBytes,
                    "com/mojang/renderpearl/api/device/HintsAndWorkarounds",
                    "writeToBufferIsSlow", "()Z",
                    STAGING_HELPER, "writeToBufferIsSlowOrMaleoon",
                    "(Ljava/lang/Object;)Z");
                patched = patchInvocation(patched,
                    "com/mojang/renderpearl/api/device/DeviceFeatures",
                    "persistentMapping", "()Z",
                    STAGING_HELPER, "observePersistentMapping",
                    "(Ljava/lang/Object;)Z");
                patched = patchStagingCapacityGuard(patched,
                    STAGING_HELPER, "allowTerrainAppend", "(ILjava/lang/Object;I)Z");
                activated(className, hash,
                    "maleoon-persistent-staging-selection+soft-upload-backpressure");
                return patched;
            }
            if (UPLOADER_CLASS.equals(className) && UPLOADER_SHA256.equals(hash)) {
                byte[] patched = patchInvocation(classBytes,
                    "com/mojang/blaze3d/vertex/StagingBuffer", "tryClearAndRotate", "()V",
                    HELPER, "finishUploadBatch", "(Ljava/lang/Object;)V");
                activated(className, hash, "fence-delayed-range-retirement");
                return patched;
            }
            if (GL_COMMAND_ENCODER_CLASS.equals(className)
                    && GL_COMMAND_ENCODER_SHA256.equals(hash)) {
                // Diagnostics first: it only retargets the awaitSubmit call
                // sites and appends pool entries, so the constant pass still
                // sees the original method structure it was audited against.
                byte[] patched = classBytes;
                if (applyWaitDiagnostics) {
                    patched = patchInvocation(patched,
                        "com/mojang/renderpearl/backend/opengl/GlCommandEncoder",
                        "awaitSubmit", "(JJ)Z",
                        WAIT_HELPER, "awaitGlobalSubmit", "(Ljava/lang/Object;JJ)Z");
                    waitDiagnosticsActivated(className, hash, "global-submit-caller");
                }
                if (applySubmitDepth) {
                    patched = applySubmitDepthTransform(className, patched);
                    TerrainWaitDiagnostics.noteEffectiveSubmitDepth(4);
                    submitDepthActivated(className, hash, "fences4-and-submit-arithmetic");
                }
                return patched;
            }
            if (GL_FENCE_CLASS.equals(className) && GL_FENCE_SHA256.equals(hash)) {
                if (!applyWaitDiagnostics) return classBytes;
                byte[] patched = patchInvocation(classBytes,
                    "com/mojang/renderpearl/backend/opengl/GlCommandEncoder", "awaitSubmit", "(JJ)Z",
                    WAIT_HELPER, "awaitGpuFence", "(Ljava/lang/Object;JJ)Z");
                waitDiagnosticsActivated(className, hash, "gpu-fence-caller");
                return patched;
            }
            if (GL_TRANSIENT_PM_CLASS.equals(className) && GL_TRANSIENT_PM_SHA256.equals(hash)) {
                if (!applySubmitDepth) return classBytes;
                byte[] patched = applySubmitDepthTransform(className, classBytes);
                submitDepthActivated(className, hash, "rotations4");
                return patched;
            }
            if (LEVEL_RENDERER_CLASS.equals(className) && LEVEL_RENDERER_SHA256.equals(hash)) {
                // The loader's upload-timing gate cleared before this class
                // could reach the patcher, so both call-site rewrites apply.
                byte[] patched = applyUploadTimingTransform(className, classBytes);
                System.out.println("[AMCL-UPLOAD-TIMING-PATCH] schema=1 status=active class="
                    + className + " sha256=" + hash
                    + " mode=frame-start-upload route=A");
                return patched;
            }
            if (PLAYER_CHUNK_SENDER_CLASS.equals(className)
                    && PLAYER_CHUNK_SENDER_SHA256.equals(hash)) {
                // The lone memoryConnection read sits in collectChunksToSend;
                // rewriting it forces single player onto the ack-adaptive
                // multiplayer quota (9..64 chunks/tick, <=10 unacked batches)
                // instead of dumping the whole crossing burst into one tick.
                byte[] patched = patchFieldRead(classBytes,
                    "net/minecraft/server/network/PlayerChunkSender", "memoryConnection", "Z",
                    CHUNK_QUOTA_HELPER, "memoryConnectionForQuota", "(Ljava/lang/Object;)Z", 1);
                System.out.println("[AMCL-CHUNK-QUOTA-PATCH] schema=1 status=active class="
                    + className + " sha256=" + hash
                    + " mode=single-player-send-quota");
                return patched;
            }
        } catch (RuntimeException failure) {
            System.err.println(markerFor(className) + " schema=1 status=failed class=" + className
                + " sha256=" + hash + " reason=" + failure.getMessage());
            return classBytes;
        }
        System.out.println(markerFor(className) + " schema=1 status=unsupported class=" + className
            + " sha256=" + hash + " action=unchanged");
        return classBytes;
    }

    /**
     * C0 探针用：**只读**复述这个类上的结构判据。不改字节、不返回字节。
     *
     * <p>存在的理由（方案 §5.2 C0-2）：agent 化之后被变换的类由 FML/Knot 定义，
     * 而 agent 看到的是 Mixin/coremod 跑完之后的字节 —— "结构判据在那份字节上还成立吗"
     * 是一个 C 级未知，只能真机量。</p>
     *
     * <p>⚠️ **判据一条都没有在这里重写。** 每个计数都调用产品自己的匹配器
     * （{@code findMethodReference} / {@code replaceCodeReference} /
     * {@code matchesStagingCapacityGuard} / {@code replaceMethodConstantLoads}），
     * 只是把"新引用"传成"旧引用"、把目标常量池槽传成 0 ⇒ 写入退化成同值写或不写。
     * 若在这里抄一份判据，探针就会开始报告一份**与产品不同**的判据，
     * 那比没有探针更糟。入参再 clone 一次是第二道保险。</p>
     *
     * <p>约定：计数 {@code -1} 表示常量池里连那个引用都没有（判据的前置条件就不成立）。</p>
     */
    static String probeStructuralCriteria(String className, byte[] classBytes) {
        String hash = sha256(classBytes);
        String expected = expectedHash(className);
        StringBuilder out = new StringBuilder();
        out.append("sha256=").append(hash).append(" pinned=")
            .append(expected == null ? "none" : (expected.equals(hash) ? "hit" : "miss"));
        try {
            // 先答"这份字节是原始的还是旧路径改过的"，否则下面的计数会被误读（见 countOwnerRefs）。
            out.append(" amclOwnerRefs=")
                .append(new ClassFile(classBytes.clone()).countOwnerRefs("com/amcl/launcher/"));
        } catch (RuntimeException failure) {
            out.append(" amclOwnerRefs=err(").append(failure.getMessage()).append(')');
        }
        try {
            if (UBER_CLASS.equals(className)) {
                out.append(" tlsfFreeCalls=").append(countInvocations(classBytes,
                    "com/mojang/blaze3d/vertex/TlsfAllocator", "free",
                    "(Lcom/mojang/blaze3d/vertex/TlsfAllocator$Allocation;)V"));
                out.append(" heapSizeReads=").append(countFieldReads(classBytes,
                    "com/mojang/blaze3d/vertex/UberGpuBuffer", "heapSize", "I"));
            } else if (STAGING_CLASS.equals(className)) {
                out.append(" writeToBufferIsSlowCalls=").append(countInvocations(classBytes,
                    "com/mojang/renderpearl/api/device/HintsAndWorkarounds",
                    "writeToBufferIsSlow", "()Z"));
                out.append(" persistentMappingCalls=").append(countInvocations(classBytes,
                    "com/mojang/renderpearl/api/device/DeviceFeatures",
                    "persistentMapping", "()Z"));
                out.append(" capacityGuards=").append(countStagingCapacityGuards(classBytes));
            } else if (UPLOADER_CLASS.equals(className)) {
                out.append(" tryClearAndRotateCalls=").append(countInvocations(classBytes,
                    "com/mojang/blaze3d/vertex/StagingBuffer", "tryClearAndRotate", "()V"));
            } else if (GL_COMMAND_ENCODER_CLASS.equals(className)) {
                out.append(" awaitSubmitCalls=").append(countInvocations(classBytes,
                    "com/mojang/renderpearl/backend/opengl/GlCommandEncoder",
                    "awaitSubmit", "(JJ)Z"));
                out.append(" initLoads=").append(countConstantLoads(classBytes, "<init>",
                    "(Lcom/mojang/renderpearl/backend/opengl/GlDevice;)V",
                    2L, NEWARRAY_LONG_CONTEXT));
                out.append(" currentSubmitSlotLoads=").append(countConstantLoads(classBytes,
                    "currentSubmitSlot", "()I", 2L, null));
                out.append(" submitLoads=").append(countConstantLoads(classBytes,
                    "submit", "()V", 2L, null));
                out.append(" awaitSubmitLoads=").append(countConstantLoads(classBytes,
                    "awaitSubmit", "(JJ)Z", 2L, null));
            } else if (GL_FENCE_CLASS.equals(className)) {
                out.append(" awaitSubmitCalls=").append(countInvocations(classBytes,
                    "com/mojang/renderpearl/backend/opengl/GlCommandEncoder",
                    "awaitSubmit", "(JJ)Z"));
            } else if (GL_TRANSIENT_PM_CLASS.equals(className)) {
                out.append(" initLoads=").append(countConstantLoads(classBytes, "<init>",
                    "(Lcom/mojang/renderpearl/backend/opengl/GlDevice;"
                        + "Lcom/mojang/renderpearl/backend/opengl/GlCommandEncoder;)V",
                    2L, ANEWARRAY_CONTEXT));
            } else if (PLAYER_CHUNK_SENDER_CLASS.equals(className)) {
                out.append(" memoryConnectionReads=").append(countFieldReads(classBytes,
                    "net/minecraft/server/network/PlayerChunkSender", "memoryConnection", "Z"));
            } else if (LEVEL_RENDERER_CLASS.equals(className)) {
                out.append(" uploadTerrainCalls=").append(countInvocations(classBytes,
                    "net/minecraft/client/renderer/chunk/SectionRenderDispatcher",
                    "uploadTerrainBuffersToGpu", "()V"));
                out.append(" repositionCameraCalls=").append(countInvocations(classBytes,
                    "net/minecraft/client/renderer/LevelRenderer", "repositionCamera",
                    "(Lnet/minecraft/client/renderer/state/level/CameraRenderState;)V"));
            } else {
                out.append(" criteria=none-for-class");
            }
        } catch (RuntimeException failure) {
            out.append(" probeError=").append(failure.getMessage());
        }
        return out.toString();
    }

    /** 只读地数 invokevirtual 调用点。新旧引用与新旧操作码都传同一个 ⇒ 写入是同值写。 */
    private static int countInvocations(byte[] bytes, String owner, String name, String desc) {
        ClassFile file = new ClassFile(bytes.clone());
        int reference = file.findMethodReference(owner, name, desc);
        if (reference == 0) return -1;
        return file.replaceCodeReference(0xb6, 0xb6, reference, reference);
    }

    /** 只读地数 getfield 读取点。 */
    private static int countFieldReads(byte[] bytes, String owner, String name, String desc) {
        ClassFile file = new ClassFile(bytes.clone());
        int reference = file.findFieldReference(owner, name, desc);
        if (reference == 0) return -1;
        return file.replaceCodeReference(0xb4, 0xb4, reference, reference);
    }

    private static int countStagingCapacityGuards(byte[] bytes) {
        ClassFile file = new ClassFile(bytes.clone());
        int capacity = file.findMethodReference("java/nio/ByteBuffer", "capacity", "()I");
        if (capacity == 0) return -1;
        return file.countStagingCapacityGuards(capacity);
    }

    /**
     * 只读地数一个方法里的 {ldc2_w, iconst} 命中数，格式 {@code wide/iconst}。
     * 目标常量池槽传 0 ⇒ ldc2_w 只计数不改写；iconst 的新旧操作码相同 ⇒ 同值写。
     * 方法匹配数不为 1 时产品判据本身就会抛，这里把它的原话带出来（那正是要量的东西）。
     */
    private static String countConstantLoads(byte[] bytes, String methodName,
                                             String methodDescriptor, long fromValue,
                                             int[] context) {
        try {
            ClassFile file = new ClassFile(bytes.clone());
            boolean matchIconst = context != null && context.length > 0;
            int fromIconst = matchIconst ? 0x03 + (int) fromValue : -1;
            int[] counts = file.replaceMethodConstantLoads(methodName, methodDescriptor,
                fromValue, 0, fromIconst, fromIconst, context);
            return counts[0] + "/" + counts[1];
        } catch (RuntimeException failure) {
            return "err(" + failure.getMessage() + ")";
        }
    }

    private static String markerFor(String className) {
        if (isWaitDiagnosticsTarget(className)) return "[AMCL-GPU-WAIT-PATCH]";
        if (isSubmitDepthTarget(className)) return "[AMCL-SUBMIT-DEPTH-PATCH]";
        if (isChunkQuotaTarget(className)) return "[AMCL-CHUNK-QUOTA-PATCH]";
        if (isUploadTimingTarget(className)) return "[AMCL-UPLOAD-TIMING-PATCH]";
        return "[AMCL-TERRAIN-PATCH]";
    }

    private static void activated(String className, String hash) {
        activated(className, hash, "fence-delayed-range-retirement");
    }

    private static void activated(String className, String hash, String mode) {
        System.out.println("[AMCL-TERRAIN-PATCH] schema=1 status=active class=" + className
            + " sha256=" + hash + " mode=" + mode);
    }

    private static void waitDiagnosticsActivated(String className, String hash, String mode) {
        System.out.println("[AMCL-GPU-WAIT-PATCH] schema=1 status=active class=" + className
            + " sha256=" + hash + " mode=" + mode);
    }

    private static void submitDepthActivated(String className, String hash, String mode) {
        System.out.println("[AMCL-SUBMIT-DEPTH-PATCH] schema=1 status=active class=" + className
            + " sha256=" + hash + " mode=" + mode + " depth=4");
    }

    static byte[] readAll(InputStream input) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        int count;
        while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
        return output.toByteArray();
    }

    static String sha256(byte[] bytes) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] value = digest.digest(bytes);
            StringBuilder text = new StringBuilder(value.length * 2);
            for (byte b : value) text.append(String.format("%02x", b & 0xff));
            return text.toString();
        } catch (NoSuchAlgorithmException impossible) {
            throw new AssertionError(impossible);
        }
    }

    /** Package-private so the bytecode contract can be tested with a synthetic class. */
    static byte[] patchInvocation(byte[] original,
                                  String oldOwner, String oldName, String oldDescriptor,
                                  String newOwner, String newName, String newDescriptor) {
        ClassFile file = new ClassFile(original);
        int oldReference = file.findMethodReference(oldOwner, oldName, oldDescriptor);
        if (oldReference == 0) throw new IllegalArgumentException("source method reference missing");

        byte[] additions = constantPoolAdditions(file.constantPoolCount,
            newOwner, newName, newDescriptor);
        int newReference = file.constantPoolCount + 5;
        int newCount = file.constantPoolCount + 6;
        if (newCount > 0xffff) throw new IllegalArgumentException("constant pool overflow");

        byte[] patched = new byte[original.length + additions.length];
        System.arraycopy(original, 0, patched, 0, 8);
        putU2(patched, 8, newCount);
        System.arraycopy(original, 10, patched, 10, file.constantPoolEnd - 10);
        System.arraycopy(additions, 0, patched, file.constantPoolEnd, additions.length);
        System.arraycopy(original, file.constantPoolEnd, patched,
            file.constantPoolEnd + additions.length, original.length - file.constantPoolEnd);

        ClassFile expanded = new ClassFile(patched);
        int replacements = expanded.replaceCodeInvocation(oldReference, newReference);
        if (replacements != 1) {
            throw new IllegalArgumentException("expected one invocation, found " + replacements);
        }
        return patched;
    }

    /** Replaces fixed-width GETFIELD reads with an equivalent static accessor. */
    static byte[] patchFieldRead(byte[] original,
                                 String oldOwner, String oldName, String oldDescriptor,
                                 String newOwner, String newName, String newDescriptor,
                                 int expectedReplacements) {
        ClassFile file = new ClassFile(original);
        int oldReference = file.findFieldReference(oldOwner, oldName, oldDescriptor);
        if (oldReference == 0) throw new IllegalArgumentException("source field reference missing");

        byte[] additions = constantPoolAdditions(file.constantPoolCount,
            newOwner, newName, newDescriptor);
        int newReference = file.constantPoolCount + 5;
        int newCount = file.constantPoolCount + 6;
        if (newCount > 0xffff) throw new IllegalArgumentException("constant pool overflow");

        byte[] patched = new byte[original.length + additions.length];
        System.arraycopy(original, 0, patched, 0, 8);
        putU2(patched, 8, newCount);
        System.arraycopy(original, 10, patched, 10, file.constantPoolEnd - 10);
        System.arraycopy(additions, 0, patched, file.constantPoolEnd, additions.length);
        System.arraycopy(original, file.constantPoolEnd, patched,
            file.constantPoolEnd + additions.length, original.length - file.constantPoolEnd);

        ClassFile expanded = new ClassFile(patched);
        int replacements = expanded.replaceCodeReference(0xb4, 0xb8,
            oldReference, newReference);
        if (replacements != expectedReplacements) {
            throw new IllegalArgumentException("expected " + expectedReplacements
                + " field reads, found " + replacements);
        }
        return patched;
    }

    /**
     * Rewrites the audited 13-byte {@code tryAppend} remaining-capacity guard
     * without moving code, branches, exception ranges, or stack-map frames.
     *
     * <p>The original stack sequence computes
     * {@code incoming <= capacity - writeOffset}. The replacement passes those
     * three existing values to a static boolean helper, branches to the same
     * success target, and pads the two spare bytes with NOPs.</p>
     */
    static byte[] patchStagingCapacityGuard(byte[] original,
                                            String newOwner, String newName,
                                            String newDescriptor) {
        ClassFile file = new ClassFile(original);
        int capacityReference = file.findMethodReference(
            "java/nio/ByteBuffer", "capacity", "()I");
        if (capacityReference == 0) {
            throw new IllegalArgumentException("ByteBuffer.capacity reference missing");
        }

        byte[] additions = constantPoolAdditions(file.constantPoolCount,
            newOwner, newName, newDescriptor);
        int newReference = file.constantPoolCount + 5;
        int newCount = file.constantPoolCount + 6;
        if (newCount > 0xffff) throw new IllegalArgumentException("constant pool overflow");

        byte[] patched = new byte[original.length + additions.length];
        System.arraycopy(original, 0, patched, 0, 8);
        putU2(patched, 8, newCount);
        System.arraycopy(original, 10, patched, 10, file.constantPoolEnd - 10);
        System.arraycopy(additions, 0, patched, file.constantPoolEnd, additions.length);
        System.arraycopy(original, file.constantPoolEnd, patched,
            file.constantPoolEnd + additions.length, original.length - file.constantPoolEnd);

        ClassFile expanded = new ClassFile(patched);
        int replacements = expanded.replaceStagingCapacityGuard(
            capacityReference, newReference);
        if (replacements != 1) {
            throw new IllegalArgumentException(
                "expected one staging capacity guard, found " + replacements);
        }
        return patched;
    }

    /**
     * In-flight submit depth 2 -> 4 for the audited RenderPearl GL frame
     * pacer (report 2026-08-27_MC261_VS_263_RENDER_ARCH_DIFF §2/§6). The five
     * GlCommandEncoder sites (fences array size, currentSubmitIndex seed, the
     * slot moduli, submit()'s awaited distance, awaitSubmit's recycled-slot
     * cutoff) and PersistentMapping's rotations array only work as one unit;
     * expected counts below are pinned against the hashed build's javap.
     */
    static byte[] applySubmitDepthTransform(String className, byte[] classBytes) {
        if (GL_COMMAND_ENCODER_CLASS.equals(className)) {
            byte[] patched = patchLongConstantLoads(classBytes, "<init>",
                "(Lcom/mojang/renderpearl/backend/opengl/GlDevice;)V",
                2L, 4L, 1, NEWARRAY_LONG_CONTEXT, 1);
            patched = patchLongConstantLoads(patched, "currentSubmitSlot", "()I",
                2L, 4L, 1, null, 0);
            patched = patchLongConstantLoads(patched, "submit", "()V",
                2L, 4L, 1, null, 0);
            return patchLongConstantLoads(patched, "awaitSubmit", "(JJ)Z",
                2L, 4L, 2, null, 0);
        }
        if (GL_TRANSIENT_PM_CLASS.equals(className)) {
            return patchLongConstantLoads(classBytes, "<init>",
                "(Lcom/mojang/renderpearl/backend/opengl/GlDevice;"
                    + "Lcom/mojang/renderpearl/backend/opengl/GlCommandEncoder;)V",
                2L, 4L, 0, ANEWARRAY_CONTEXT, 1);
        }
        throw new IllegalArgumentException("not a submit-depth target: " + className);
    }

    /**
     * Terrain upload timing, frame end -> next frame start (report
     * 2026-08-27_MC261_VS_263_RENDER_ARCH_DIFF §1.3/§6 第二刀). Two audited
     * LevelRenderer.render call sites move as one unit: the frame-end
     * uploadTerrainBuffersToGpu() (javap offset 766, inside lock 749/unlock
     * 773) becomes a deferral, and the render-entry repositionCamera(...)
     * (offset 34, before prepareChunkRenders and the frame graph) gains the
     * deferred flush under a fresh lock/unlock. RenderSection's staging-full
     * inline flush is a different class and stays untouched on purpose: it is
     * the render thread's only self-drain when staging saturates mid-compile.
     */
    static byte[] applyUploadTimingTransform(String className, byte[] classBytes) {
        if (!LEVEL_RENDERER_CLASS.equals(className)) {
            throw new IllegalArgumentException("not an upload-timing target: " + className);
        }
        byte[] patched = patchInvocation(classBytes,
            "net/minecraft/client/renderer/chunk/SectionRenderDispatcher",
            "uploadTerrainBuffersToGpu", "()V",
            UPLOAD_TIMING_HELPER, "deferFrameEndUpload", "(Ljava/lang/Object;)V");
        return patchInvocation(patched,
            "net/minecraft/client/renderer/LevelRenderer", "repositionCamera",
            "(Lnet/minecraft/client/renderer/state/level/CameraRenderState;)V",
            UPLOAD_TIMING_HELPER, "uploadPendingThenRepositionCamera",
            "(Ljava/lang/Object;Ljava/lang/Object;)V");
    }

    /**
     * Rewrites the constant loads of exactly one method: every {@code ldc2_w}
     * whose CONSTANT_Long equals {@code fromValue} is redirected to an entry
     * holding {@code toValue} (reused if present, else appended; the original
     * entry is never edited because unrelated code may share it), and every
     * {@code iconst_<from>} immediately followed by
     * {@code requiredFollowingBytes} becomes {@code iconst_<to>}. Rewrites
     * keep instruction widths, so branches, exception tables, and stack maps
     * stay valid. Both counts must match exactly or nothing is returned.
     */
    static byte[] patchLongConstantLoads(byte[] original,
                                         String methodName, String methodDescriptor,
                                         long fromValue, long toValue,
                                         int expectedWideLoads,
                                         int[] requiredFollowingBytes,
                                         int expectedIconstLoads) {
        if (expectedWideLoads < 0 || expectedIconstLoads < 0
                || expectedWideLoads + expectedIconstLoads == 0) {
            throw new IllegalArgumentException("no expected replacements in " + methodName);
        }
        // A provided context always participates in matching so that a count
        // of 0 asserts the absence of context-matching iconst sites.
        boolean matchIconst = requiredFollowingBytes != null
            && requiredFollowingBytes.length > 0;
        if (expectedIconstLoads > 0 && !matchIconst) {
            throw new IllegalArgumentException("iconst rewrite requires a context");
        }
        if (matchIconst
                && (fromValue < -1L || fromValue > 5L || toValue < -1L || toValue > 5L)) {
            throw new IllegalArgumentException("iconst rewrite requires values in [-1,5]");
        }

        ClassFile file = new ClassFile(original);
        byte[] working;
        int toIndex = 0;
        if (expectedWideLoads > 0) {
            toIndex = file.findLongConstant(toValue);
            if (toIndex == 0) {
                // A CONSTANT_Long occupies two pool slots (JVMS 4.4.5).
                if (file.constantPoolCount + 2 > 0xffff) {
                    throw new IllegalArgumentException("constant pool overflow");
                }
                byte[] additions = longConstantAddition(toValue);
                toIndex = file.constantPoolCount;
                working = new byte[original.length + additions.length];
                System.arraycopy(original, 0, working, 0, 8);
                putU2(working, 8, file.constantPoolCount + 2);
                System.arraycopy(original, 10, working, 10, file.constantPoolEnd - 10);
                System.arraycopy(additions, 0, working, file.constantPoolEnd, additions.length);
                System.arraycopy(original, file.constantPoolEnd, working,
                    file.constantPoolEnd + additions.length,
                    original.length - file.constantPoolEnd);
            } else {
                working = original.clone();
            }
        } else {
            working = original.clone();
        }

        ClassFile expanded = new ClassFile(working);
        int fromIconst = matchIconst ? 0x03 + (int) fromValue : -1;
        int toIconst = matchIconst ? 0x03 + (int) toValue : -1;
        int[] counts = expanded.replaceMethodConstantLoads(methodName, methodDescriptor,
            fromValue, toIndex, fromIconst, toIconst, requiredFollowingBytes);
        if (counts[0] != expectedWideLoads || counts[1] != expectedIconstLoads) {
            throw new IllegalArgumentException(methodName + methodDescriptor
                + " expected " + expectedWideLoads + " wide/" + expectedIconstLoads
                + " iconst loads of " + fromValue + ", found "
                + counts[0] + "/" + counts[1]);
        }
        return working;
    }

    private static byte[] longConstantAddition(long value) {
        byte[] addition = new byte[9];
        addition[0] = 5; // CONSTANT_Long
        for (int i = 0; i < 8; i++) {
            addition[1 + i] = (byte) (value >>> (56 - 8 * i));
        }
        return addition;
    }

    private static byte[] constantPoolAdditions(int firstIndex,
                                                String owner, String name, String descriptor) {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        writeUtf8(output, owner);                 // firstIndex
        output.write(7); writeU2(output, firstIndex); // Class
        writeUtf8(output, name);                  // firstIndex + 2
        writeUtf8(output, descriptor);            // firstIndex + 3
        output.write(12);                         // NameAndType
        writeU2(output, firstIndex + 2);
        writeU2(output, firstIndex + 3);
        output.write(10);                         // Methodref
        writeU2(output, firstIndex + 1);
        writeU2(output, firstIndex + 4);
        return output.toByteArray();
    }

    private static void writeUtf8(ByteArrayOutputStream output, String value) {
        try {
            byte[] bytes = value.getBytes("UTF-8");
            if (bytes.length > 0xffff) throw new IllegalArgumentException("UTF-8 constant too long");
            output.write(1);
            writeU2(output, bytes.length);
            output.write(bytes);
        } catch (IOException impossible) {
            throw new AssertionError(impossible);
        }
    }

    private static void writeU2(ByteArrayOutputStream output, int value) {
        output.write((value >>> 8) & 0xff);
        output.write(value & 0xff);
    }

    private static void putU2(byte[] bytes, int offset, int value) {
        bytes[offset] = (byte) (value >>> 8);
        bytes[offset + 1] = (byte) value;
    }

    private static final class ClassFile {
        final byte[] bytes;
        final int constantPoolCount;
        final int constantPoolEnd;
        final int[] tags;
        final int[] offsets;
        final Map<Integer, String> utf8 = new HashMap<Integer, String>();

        ClassFile(byte[] bytes) {
            this.bytes = bytes;
            if (bytes.length < 10 || u4(bytes, 0) != 0xcafebabeL) {
                throw new IllegalArgumentException("not a class file");
            }
            constantPoolCount = u2(bytes, 8);
            tags = new int[constantPoolCount];
            offsets = new int[constantPoolCount];
            int cursor = 10;
            for (int index = 1; index < constantPoolCount; index++) {
                require(cursor, 1);
                int tag = u1(bytes, cursor++);
                tags[index] = tag;
                offsets[index] = cursor;
                switch (tag) {
                    case 1: {
                        int length = u2(bytes, cursor);
                        cursor += 2;
                        require(cursor, length);
                        try {
                            utf8.put(index, new String(bytes, cursor, length, "UTF-8"));
                        } catch (IOException impossible) {
                            throw new AssertionError(impossible);
                        }
                        cursor += length;
                        break;
                    }
                    case 3: case 4: cursor += 4; break;
                    case 5: case 6: cursor += 8; index++; break;
                    case 7: case 8: case 16: case 19: case 20: cursor += 2; break;
                    case 9: case 10: case 11: case 12: case 17: case 18: cursor += 4; break;
                    case 15: cursor += 3; break;
                    default: throw new IllegalArgumentException("unknown constant-pool tag " + tag);
                }
                require(cursor, 0);
            }
            constantPoolEnd = cursor;
        }

        int findMethodReference(String owner, String name, String descriptor) {
            return findReference(10, owner, name, descriptor);
        }

        int findFieldReference(String owner, String name, String descriptor) {
            return findReference(9, owner, name, descriptor);
        }

        private int findReference(int referenceTag,
                                  String owner, String name, String descriptor) {
            for (int index = 1; index < constantPoolCount; index++) {
                if (tags[index] != referenceTag) continue;
                int classIndex = u2(bytes, offsets[index]);
                int nameTypeIndex = u2(bytes, offsets[index] + 2);
                if (owner.equals(className(classIndex)) && tags[nameTypeIndex] == 12) {
                    int nameIndex = u2(bytes, offsets[nameTypeIndex]);
                    int descriptorIndex = u2(bytes, offsets[nameTypeIndex] + 2);
                    if (name.equals(utf8.get(nameIndex)) && descriptor.equals(utf8.get(descriptorIndex))) {
                        return index;
                    }
                }
            }
            return 0;
        }

        private String className(int classIndex) {
            if (classIndex <= 0 || classIndex >= tags.length || tags[classIndex] != 7) return null;
            return utf8.get(u2(bytes, offsets[classIndex]));
        }

        /**
         * 常量池里 owner 落在某个包前缀下的 {@code CONSTANT_Class} 条目数（C0 探针用）。
         *
         * <p>存在的理由是**区分"agent 看到的是原始字节"与"看到的是旧路径改过的字节"**：
         * 原版路线上 {@code AmclClassLoader.findClass} 先改再 {@code defineClass}，
         * 而 JVM 的 class-file-load hook 在 defineClass 里才调 transformer ⇒ agent 看到的是
         * **改后**的字节。没有这个计数的话，那种情形下的 {@code pinned=miss} 会被误读成
         * "结构判据在真机上不成立"。</p>
         */
        int countOwnerRefs(String internalPrefix) {
            int found = 0;
            for (int index = 1; index < constantPoolCount; index++) {
                if (tags[index] != 7) continue;
                String name = className(index);
                if (name != null && name.startsWith(internalPrefix)) found++;
            }
            return found;
        }

        int findLongConstant(long value) {
            for (int index = 1; index < constantPoolCount; index++) {
                if (tags[index] == 5 && longAt(index) == value) return index;
            }
            return 0;
        }

        private long longAt(int index) {
            return (u4(bytes, offsets[index]) << 32) | u4(bytes, offsets[index] + 4);
        }

        /** Returns {ldc2_w, iconst} replacement counts inside the one matching method. */
        int[] replaceMethodConstantLoads(String methodName, String methodDescriptor,
                                         long fromValue, int toLongIndex,
                                         int fromIconstOpcode, int toIconstOpcode,
                                         int[] requiredFollowingBytes) {
            int cursor = constantPoolEnd;
            require(cursor, 8);
            cursor += 6; // access, this, super
            int interfaceCount = u2(bytes, cursor); cursor += 2 + interfaceCount * 2;
            int fieldCount = u2(bytes, cursor); cursor += 2;
            for (int i = 0; i < fieldCount; i++) cursor = skipMember(cursor, null);
            int methodCount = u2(bytes, cursor); cursor += 2;
            int[] counts = new int[] {0, 0};
            int matchedMethods = 0;
            for (int i = 0; i < methodCount; i++) {
                require(cursor, 8);
                boolean target = methodName.equals(utf8.get(u2(bytes, cursor + 2)))
                    && methodDescriptor.equals(utf8.get(u2(bytes, cursor + 4)));
                if (target) matchedMethods++;
                cursor += 6;
                int attributeCount = u2(bytes, cursor); cursor += 2;
                for (int a = 0; a < attributeCount; a++) {
                    int nameIndex = u2(bytes, cursor);
                    long length = u4(bytes, cursor + 2);
                    int info = cursor + 6;
                    if (length > Integer.MAX_VALUE) {
                        throw new IllegalArgumentException("attribute too large");
                    }
                    require(info, (int) length);
                    if (target && "Code".equals(utf8.get(nameIndex))) {
                        require(info, 8);
                        int codeLength = (int) u4(bytes, info + 4);
                        int codeStart = info + 8;
                        require(codeStart, codeLength);
                        rewriteConstantLoads(codeStart, codeStart + codeLength, counts,
                            fromValue, toLongIndex, fromIconstOpcode, toIconstOpcode,
                            requiredFollowingBytes);
                    }
                    cursor = info + (int) length;
                }
            }
            if (matchedMethods != 1) {
                throw new IllegalArgumentException(matchedMethods + " methods match "
                    + methodName + methodDescriptor);
            }
            return counts;
        }

        private void rewriteConstantLoads(int codeStart, int codeEnd, int[] counts,
                                          long fromValue, int toLongIndex,
                                          int fromIconstOpcode, int toIconstOpcode,
                                          int[] requiredFollowingBytes) {
            for (int p = codeStart; p < codeEnd; p = nextInstruction(p, codeStart, codeEnd)) {
                int opcode = u1(bytes, p);
                if (opcode == 0x14 && p + 2 < codeEnd) { // ldc2_w
                    int operand = u2(bytes, p + 1);
                    if (operand > 0 && operand < constantPoolCount
                            && tags[operand] == 5 && longAt(operand) == fromValue) {
                        // Counted even when no destination entry was prepared
                        // so an undeclared wide load fails the expected-count
                        // check instead of being silently skipped.
                        if (toLongIndex != 0) putU2(bytes, p + 1, toLongIndex);
                        counts[0]++;
                    }
                } else if (opcode == fromIconstOpcode
                        && followedBy(p + 1, codeEnd, requiredFollowingBytes)) {
                    bytes[p] = (byte) toIconstOpcode;
                    counts[1]++;
                }
            }
        }

        private boolean followedBy(int offset, int codeEnd, int[] expected) {
            if (expected == null || offset > codeEnd - expected.length) return false;
            for (int i = 0; i < expected.length; i++) {
                if (u1(bytes, offset + i) != expected[i]) return false;
            }
            return true;
        }

        int replaceCodeInvocation(int oldReference, int newReference) {
            return replaceCodeReference(0xb6, 0xb8, oldReference, newReference);
        }

        int replaceCodeReference(int oldOpcode, int newOpcode,
                                 int oldReference, int newReference) {
            int cursor = constantPoolEnd;
            require(cursor, 8);
            cursor += 6; // access, this, super
            int interfaceCount = u2(bytes, cursor); cursor += 2 + interfaceCount * 2;
            int fieldCount = u2(bytes, cursor); cursor += 2;
            for (int i = 0; i < fieldCount; i++) cursor = skipMember(cursor, null);
            int methodCount = u2(bytes, cursor); cursor += 2;
            int[] replacements = new int[] {0};
            for (int i = 0; i < methodCount; i++) cursor = skipMember(cursor, replacements,
                oldOpcode, newOpcode, oldReference, newReference);
            return replacements[0];
        }

        int replaceStagingCapacityGuard(int capacityReference, int helperReference) {
            int cursor = constantPoolEnd;
            require(cursor, 8);
            cursor += 6; // access, this, super
            int interfaceCount = u2(bytes, cursor); cursor += 2 + interfaceCount * 2;
            int fieldCount = u2(bytes, cursor); cursor += 2;
            for (int i = 0; i < fieldCount; i++) cursor = skipMember(cursor, null);
            int methodCount = u2(bytes, cursor); cursor += 2;
            int[] replacements = new int[] {0};
            for (int i = 0; i < methodCount; i++) {
                cursor = rewriteStagingCapacityGuard(cursor, replacements,
                    capacityReference, helperReference);
            }
            return replacements[0];
        }

        /**
         * {@link #replaceStagingCapacityGuard} 的只读孪生（C0 探针用）。
         *
         * <p>它复述的判据本身**没有第二份**：命中与否仍由
         * {@link #matchesStagingCapacityGuard} 回答，这里只是不写那 13 个字节。
         * 那个改写不是同值写（它换掉整段守卫），所以这一条是唯一不能靠
         * "把新引用传成旧引用"退化成只读的判据。</p>
         */
        int countStagingCapacityGuards(int capacityReference) {
            int cursor = constantPoolEnd;
            require(cursor, 8);
            cursor += 6; // access, this, super
            int interfaceCount = u2(bytes, cursor); cursor += 2 + interfaceCount * 2;
            int fieldCount = u2(bytes, cursor); cursor += 2;
            for (int i = 0; i < fieldCount; i++) cursor = skipMember(cursor, null);
            int methodCount = u2(bytes, cursor); cursor += 2;
            int found = 0;
            for (int i = 0; i < methodCount; i++) {
                require(cursor, 8);
                cursor += 6;
                int attributeCount = u2(bytes, cursor); cursor += 2;
                for (int a = 0; a < attributeCount; a++) {
                    int nameIndex = u2(bytes, cursor);
                    long length = u4(bytes, cursor + 2);
                    int info = cursor + 6;
                    if (length > Integer.MAX_VALUE) {
                        throw new IllegalArgumentException("attribute too large");
                    }
                    require(info, (int) length);
                    if ("Code".equals(utf8.get(nameIndex))) {
                        require(info, 8);
                        int codeLength = (int) u4(bytes, info + 4);
                        int codeStart = info + 8;
                        require(codeStart, codeLength);
                        int codeEnd = codeStart + codeLength;
                        for (int p = codeStart; p < codeEnd;
                                p = nextInstruction(p, codeStart, codeEnd)) {
                            if (matchesStagingCapacityGuard(p, codeEnd, capacityReference)) found++;
                        }
                    }
                    cursor = info + (int) length;
                }
            }
            return found;
        }

        private int rewriteStagingCapacityGuard(int cursor, int[] replacements,
                                                int capacityReference,
                                                int helperReference) {
            require(cursor, 8);
            cursor += 6;
            int attributeCount = u2(bytes, cursor); cursor += 2;
            for (int i = 0; i < attributeCount; i++) {
                int nameIndex = u2(bytes, cursor);
                long length = u4(bytes, cursor + 2);
                int info = cursor + 6;
                if (length > Integer.MAX_VALUE) {
                    throw new IllegalArgumentException("attribute too large");
                }
                require(info, (int) length);
                if ("Code".equals(utf8.get(nameIndex))) {
                    require(info, 8);
                    int codeLength = (int) u4(bytes, info + 4);
                    int codeStart = info + 8;
                    require(codeStart, codeLength);
                    int codeEnd = codeStart + codeLength;
                    for (int p = codeStart; p < codeEnd;
                            p = nextInstruction(p, codeStart, codeEnd)) {
                        if (matchesStagingCapacityGuard(p, codeEnd, capacityReference)) {
                            // iload_3, aload 4, iload_2
                            bytes[p + 1] = 0x19;
                            bytes[p + 2] = 0x04;
                            bytes[p + 3] = 0x1c;
                            // invokestatic allowTerrainAppend(int, Object, int)
                            bytes[p + 4] = (byte) 0xb8;
                            putU2(bytes, p + 5, helperReference);
                            // ifne original success target (offset +6 from p+7 to p+13)
                            bytes[p + 7] = (byte) 0x9a;
                            bytes[p + 8] = 0x00;
                            bytes[p + 9] = 0x06;
                            // Keep all three rejection bytes reachable so the existing
                            // StackMapTable needs no additional frame before offset 57.
                            bytes[p + 10] = 0x00;
                            bytes[p + 11] = 0x01;
                            bytes[p + 12] = (byte) 0xb0;
                            replacements[0]++;
                        }
                    }
                }
                cursor = info + (int) length;
            }
            return cursor;
        }

        private boolean matchesStagingCapacityGuard(int offset, int codeEnd,
                                                    int capacityReference) {
            return offset <= codeEnd - 13
                && u1(bytes, offset) == 0x1d              // iload_3: incoming bytes
                && u1(bytes, offset + 1) == 0x19          // aload 4: write buffer
                && u1(bytes, offset + 2) == 0x04
                && u1(bytes, offset + 3) == 0xb6          // ByteBuffer.capacity()
                && u2(bytes, offset + 4) == capacityReference
                && u1(bytes, offset + 6) == 0x1c          // iload_2: write offset
                && u1(bytes, offset + 7) == 0x64          // isub
                && u1(bytes, offset + 8) == 0xa4          // if_icmple
                && u2(bytes, offset + 9) == 5
                && u1(bytes, offset + 11) == 0x01         // aconst_null
                && u1(bytes, offset + 12) == 0xb0;        // areturn
        }

        private int skipMember(int cursor, int[] replacements, int... references) {
            require(cursor, 8);
            cursor += 6;
            int attributeCount = u2(bytes, cursor); cursor += 2;
            for (int i = 0; i < attributeCount; i++) {
                int nameIndex = u2(bytes, cursor);
                long length = u4(bytes, cursor + 2);
                int info = cursor + 6;
                if (length > Integer.MAX_VALUE) throw new IllegalArgumentException("attribute too large");
                require(info, (int) length);
                if (replacements != null && "Code".equals(utf8.get(nameIndex))) {
                    require(info, 8);
                    int codeLength = (int) u4(bytes, info + 4);
                    int codeStart = info + 8;
                    require(codeStart, codeLength);
                    int oldOpcode = references[0];
                    int newOpcode = references[1];
                    int oldReference = references[2];
                    int newReference = references[3];
                    int codeEnd = codeStart + codeLength;
                    for (int p = codeStart; p < codeEnd; p = nextInstruction(p, codeStart, codeEnd)) {
                        if (u1(bytes, p) == oldOpcode && p + 2 < codeEnd
                            && u2(bytes, p + 1) == oldReference) {
                            bytes[p] = (byte) newOpcode;
                            putU2(bytes, p + 1, newReference);
                            replacements[0]++;
                        }
                    }
                }
                cursor = info + (int) length;
            }
            return cursor;
        }

        private int skipMember(int cursor, int[] replacements) {
            return skipMember(cursor, replacements, 0, 0, 0, 0);
        }

        private int nextInstruction(int opcodeOffset, int codeStart, int codeEnd) {
            int opcode = u1(bytes, opcodeOffset);
            int length;
            switch (opcode) {
                case 0x10: case 0x12:
                case 0x15: case 0x16: case 0x17: case 0x18: case 0x19:
                case 0x36: case 0x37: case 0x38: case 0x39: case 0x3a:
                case 0xa9: case 0xbc:
                    length = 2;
                    break;
                case 0x11: case 0x13: case 0x14: case 0x84:
                case 0x99: case 0x9a: case 0x9b: case 0x9c: case 0x9d: case 0x9e:
                case 0x9f: case 0xa0: case 0xa1: case 0xa2: case 0xa3: case 0xa4:
                case 0xa5: case 0xa6: case 0xa7: case 0xa8:
                case 0xb2: case 0xb3: case 0xb4: case 0xb5:
                case 0xb6: case 0xb7: case 0xb8: case 0xbb:
                case 0xbd: case 0xc0: case 0xc1: case 0xc6: case 0xc7:
                    length = 3;
                    break;
                case 0xb9: case 0xba: case 0xc8: case 0xc9:
                    length = 5;
                    break;
                case 0xc5:
                    length = 4;
                    break;
                case 0xaa: {
                    int cursor = opcodeOffset + 1;
                    while (((cursor - codeStart) & 3) != 0) cursor++;
                    require(cursor, 12);
                    int low = signedU4(bytes, cursor + 4);
                    int high = signedU4(bytes, cursor + 8);
                    long entries = (long) high - low + 1L;
                    if (entries < 0L || entries > Integer.MAX_VALUE / 4) {
                        throw new IllegalArgumentException("invalid tableswitch");
                    }
                    length = (cursor - opcodeOffset) + 12 + (int) entries * 4;
                    break;
                }
                case 0xab: {
                    int cursor = opcodeOffset + 1;
                    while (((cursor - codeStart) & 3) != 0) cursor++;
                    require(cursor, 8);
                    int pairs = signedU4(bytes, cursor + 4);
                    if (pairs < 0 || pairs > Integer.MAX_VALUE / 8) {
                        throw new IllegalArgumentException("invalid lookupswitch");
                    }
                    length = (cursor - opcodeOffset) + 8 + pairs * 8;
                    break;
                }
                case 0xc4: {
                    require(opcodeOffset, 2);
                    length = u1(bytes, opcodeOffset + 1) == 0x84 ? 6 : 4;
                    break;
                }
                default:
                    length = 1;
                    break;
            }
            if (length <= 0 || opcodeOffset > codeEnd - length) {
                throw new IllegalArgumentException("truncated bytecode at "
                    + (opcodeOffset - codeStart));
            }
            return opcodeOffset + length;
        }

        private void require(int offset, int count) {
            if (offset < 0 || count < 0 || offset > bytes.length - count) {
                throw new IllegalArgumentException("truncated class file");
            }
        }

        private static int u1(byte[] bytes, int offset) {
            return bytes[offset] & 0xff;
        }

        private static int u2(byte[] bytes, int offset) {
            return (u1(bytes, offset) << 8) | u1(bytes, offset + 1);
        }

        private static long u4(byte[] bytes, int offset) {
            return ((long) u1(bytes, offset) << 24) | ((long) u1(bytes, offset + 1) << 16)
                | ((long) u1(bytes, offset + 2) << 8) | u1(bytes, offset + 3);
        }

        private static int signedU4(byte[] bytes, int offset) {
            return (int) u4(bytes, offset);
        }
    }
}
