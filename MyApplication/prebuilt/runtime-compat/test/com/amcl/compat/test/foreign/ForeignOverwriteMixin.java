package com.amcl.compat.test.foreign;

import net.minecraft.network.protocol.game.ClientGamePacketListener;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Overwrite;

/** 第三方替换 typed handle 的组合负例，不能因原类已匹配就继续认定最终入口受保护。 */
@Mixin(targets = "com.zurrtum.create.infrastructure.packet.s2c.S2CHoldPacket", priority = 1000, remap = false)
public abstract class ForeignOverwriteMixin {
    /**
     * 仅组合测试的故意替换。
     * @author AMCL test
     * @reason 验证本方 guard 在真实 overwrite 组合中的覆盖或明确拒绝。
     */
    @Overwrite(remap = false)
    public void handle(ClientGamePacketListener listener) { ForeignHooks.touch(); }
}
