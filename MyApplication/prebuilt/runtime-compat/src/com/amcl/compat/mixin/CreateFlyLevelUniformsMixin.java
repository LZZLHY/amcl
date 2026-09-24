package com.amcl.compat.mixin;

import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.ModifyArg;

/**
 * 修正已审查 LevelUniforms 的堆越界：四个16字节向量后还有13个4字节标量，
 * 实际写入116字节，原构造只分配112。最后的dimensionId会破坏相邻原生分配。
 * 分配与GPU绑定共用UniformBuffer大小，修为按std140的16字节边界向上对齐的128字节。
 * Plugin同时核对LevelUniforms、UniformWriter及UniformBuffer字节指纹，未知版本不注入。
 */
@Mixin(targets = "com.zurrtum.create.client.flywheel.backend.engine.uniform.LevelUniforms", remap = false)
public abstract class CreateFlyLevelUniformsMixin {
    /** 只增加该静态缓冲区的容量，不缩小其他兼容模块已经扩大后的分配。 */
    @ModifyArg(method = "<clinit>", at = @At(value = "INVOKE",
        target = "Lcom/zurrtum/create/client/flywheel/backend/engine/uniform/UniformBuffer;<init>(II)V"),
        index = 1, require = 1)
    private static int amcl$levelUniformCapacity(int requested) {
        int capacity = Math.max(requested, 128);
        System.out.println("[AMCL-FLYWHEEL] schema=1 stage=level-uniform-capacity requested=" + requested + " actual=" + capacity);
        return capacity;
    }
}
