package com.amcl.compat.test.foreign;

import net.minecraft.network.protocol.game.ClientGamePacketListener;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** 普通优先级 HEAD 业务访问对照；必须检查真实最终字节中的 guard 相对位置。 */
@Mixin(targets = "com.zurrtum.create.infrastructure.packet.s2c.S2CHoldPacket", priority = 1000, remap = false)
public abstract class ForeignLowMixin {
    @Inject(method = "handle(Lnet/minecraft/network/protocol/game/ClientGamePacketListener;)V", at = @At("HEAD"), require = 1, remap = false)
    private void foreign$headLow(ClientGamePacketListener listener, CallbackInfo callback) { ForeignHooks.touch(); }
}
