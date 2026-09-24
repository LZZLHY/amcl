package com.amcl.launcher;

import java.lang.reflect.Field;

/**
 * Routes single-player chunk sending through the server's own quota path.
 *
 * <p>Decompiled evidence (26.3-snapshot-6, 2026-08-27): the boundary-crossing
 * hitch is a three-stage unbudgeted pipeline on the render thread, and its
 * first stage is fed by {@code PlayerChunkSender.collectChunksToSend} skipping
 * the adaptive quota whenever {@code memoryConnection} is true — in single
 * player every crossing dumps the whole tracking-view difference (25–100+
 * chunk packets) into the in-memory pipe in one server tick, and the client
 * drains all of them inside one frame. Multiplayer never sees this because the
 * quota path (9 chunks/tick start, ack-adaptive up to 64, at most 10
 * unacknowledged batches) is exactly what this class re-enables.</p>
 *
 * <p>The exact-hash bytecode patch replaces the single {@code GETFIELD
 * memoryConnection} inside {@code collectChunksToSend} with
 * {@link #memoryConnectionForQuota}. Returning {@code false} selects the
 * quota branch; the field itself and every other reader keep their original
 * meaning. {@code -Damcl.singleplayerChunkQuota=false} restores the original
 * bypass by reflecting the real field value.</p>
 */
public final class ChunkSendQuotaCompatibility {
    private static volatile Field memoryConnectionField;
    private static boolean activeLogged;
    private static boolean fallbackLogged;

    private ChunkSendQuotaCompatibility() {}

    /** Replacement for the audited {@code memoryConnection} read. */
    public static boolean memoryConnectionForQuota(Object sender) {
        // 类加载层之外再守住作用域：非 MG 的迟到/错误 helper 调用只读取原字段，不改策略。
        if (RendererProfilePolicy.usesMobileGluesCompatibility()
                && Boolean.parseBoolean(System.getProperty("amcl.singleplayerChunkQuota", "true"))) {
            if (!activeLogged) {
                activeLogged = true;
                System.out.println("[AMCL-CHUNK-QUOTA] schema=1 status=active"
                    + " policy=single-player-uses-multiplayer-send-quota"
                    + " start_chunks_per_tick=9 max_chunks_per_tick=64"
                    + " opt_out=-Damcl.singleplayerChunkQuota=false");
            }
            return false;
        }
        // Opt-out: behave exactly like the original field read.
        try {
            Field field = memoryConnectionField;
            if (field == null) {
                field = sender.getClass().getDeclaredField("memoryConnection");
                field.setAccessible(true);
                memoryConnectionField = field;
            }
            boolean original = field.getBoolean(sender);
            if (!activeLogged) {
                activeLogged = true;
                System.out.println("[AMCL-CHUNK-QUOTA] schema=1 status=opt-out"
                    + " policy=original-memory-connection-bypass value=" + original);
            }
            return original;
        } catch (ReflectiveOperationException failure) {
            // Fail toward the quota path: it is the safe (multiplayer) branch.
            if (!fallbackLogged) {
                fallbackLogged = true;
                System.err.println("[AMCL-CHUNK-QUOTA] schema=1 status=fallback"
                    + " reason=field-reflection-failed detail=" + failure);
            }
            return false;
        }
    }

    static synchronized void resetForTests() {
        memoryConnectionField = null;
        activeLogged = false;
        fallbackLogged = false;
    }
}
