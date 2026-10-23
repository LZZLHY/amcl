package com.amcl.compat.test.foreign;

import net.minecraft.network.protocol.game.ClientGamePacketListener;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** 可取消的第三方 HEAD；组合验证要证明取消前没有绕过本方线程边界。 */
@Mixin(targets = "com.zurrtum.create.infrastructure.packet.s2c.S2CHoldPacket", priority = 1000, remap = false)
public abstract class ForeignCancelMixin {
    @Inject(method = "handle(Lnet/minecraft/network/protocol/game/ClientGamePacketListener;)V", at = @At("HEAD"), cancellable = true, require = 1, remap = false)
    private void foreign$cancel(ClientGamePacketListener listener, CallbackInfo callback) { ForeignHooks.touch(); callback.cancel(); }
}
