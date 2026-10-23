package com.amcl.compat.test.foreign;

import net.minecraft.network.protocol.game.ClientGamePacketListener;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** 可读且可注册，但没有匹配本次 S2CHold 目标的负控，不能算作实际组合参与。 */
@Mixin(targets = "com.zurrtum.create.infrastructure.packet.s2c.ServerSpeedPacket", priority = 1000, remap = false)
public abstract class ForeignUnmatchedMixin {
    @Inject(method = "handle(Lnet/minecraft/network/protocol/game/ClientGamePacketListener;)V", at = @At("HEAD"), require = 1, remap = false)
    private void foreign$unmatched(ClientGamePacketListener listener, CallbackInfo callback) { ForeignHooks.touch(); }
}
