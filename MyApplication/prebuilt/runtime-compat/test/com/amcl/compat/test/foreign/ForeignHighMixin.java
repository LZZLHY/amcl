package com.amcl.compat.test.foreign;

import net.minecraft.network.protocol.game.ClientGamePacketListener;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** 比生产 Mixin 更高优先级的 HEAD 业务访问，用于检查最终组合顺序而非只看单步结果。 */
@Mixin(targets = "com.zurrtum.create.infrastructure.packet.s2c.S2CHoldPacket", priority = 3000, remap = false)
public abstract class ForeignHighMixin {
    @Inject(method = "handle(Lnet/minecraft/network/protocol/game/ClientGamePacketListener;)V", at = @At("HEAD"), require = 1, remap = false)
    private void foreign$headHigh(ClientGamePacketListener listener, CallbackInfo callback) { ForeignHooks.touch(); }
}
