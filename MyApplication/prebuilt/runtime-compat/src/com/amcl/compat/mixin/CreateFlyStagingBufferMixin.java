package com.amcl.compat.mixin;

import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.lwjgl.opengl.GL45;
import org.lwjgl.opengl.GL45C;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

/**
 * 修正已审查 Create Fly 的显式映射刷新顺序。
 * 原 dispatchScatter 在旧范围已经 flush 后才追加 scatter 描述符，GPU 派发前缺少刷新。
 * 此处只刷新正要绑定的新增描述符范围，不重复上传先前负载，也不改变全局 GL 映射语义。
 * 精确目标指纹由 CompatMixinPlugin 把关，其他实现不会登记本 Mixin。
 */
@Mixin(targets = "com.zurrtum.create.client.flywheel.backend.engine.indirect.StagingBuffer", remap = false)
public abstract class CreateFlyStagingBufferMixin {
    @Unique private boolean amcl$scatterFlushReported;

    /**
     * 该绑定仅存在于直接映射分支，offset/size 就是刚刚 memCopy 的描述符子范围；
     * 映射起点为 0，因此 GL flush 的相对偏移与绑定偏移相同。overflow 分支已经使用
     * glBufferData 上传，不经过这里。先刷新再保持原绑定，避免按每个目的 VBO 重传整段负载。
     */
    @Redirect(method = "dispatchScatter(I)V", at = @At(value = "INVOKE",
        target = "Lorg/lwjgl/opengl/GL45;glBindBufferRange(IIIJJ)V"), require = 1)
    private void amcl$flushScatterBeforeBind(int target, int binding, int buffer, long offset, long size) {
        GL45C.glFlushMappedNamedBufferRange(buffer, offset, size);
        GL45.glBindBufferRange(target, binding, buffer, offset, size);
        if (!amcl$scatterFlushReported) {
            amcl$scatterFlushReported = true;
            System.out.println("[AMCL-FLYWHEEL] schema=1 stage=scatter-flush applied=true");
        }
    }
}
