package com.amcl.compat.mixin;

import com.amcl.compat.CreateFlyPacketThreading26;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.game.ClientGamePacketListener;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * 只修复固定旧 profile 的 28 个客户端 PLAY 缺口。选 typed handle 而不是合成 bridge，
 * 使 Connection→bridge、bundle→typed 和直接 typed 调用经过相同 guard；不改业务方法签名。
 * 目标名单与原始字节指纹在 profile 中整体判定，18 个既有 guard、4 个原版继承包及 CONFIG
 * 包不加入本变换。高优先级使本 guard 先于普通 HEAD 回调，最终组合仍由集成门检查。
 */
@Mixin(targets = {
    "com.zurrtum.create.infrastructure.packet.s2c.ServerSpeedPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.ContraptionStallPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.ContraptionDisassemblyPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.ContraptionBlockChangedPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.ContraptionSeatMappingPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.MountedStorageSyncPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.GantryContraptionUpdatePacket",
    "com.zurrtum.create.infrastructure.packet.s2c.HighlightPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.TunnelFlapPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.SoulPulseEffectPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.SignalEdgeGroupPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.RemoveTrainPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.TrainEditReturnPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.TrainHUDControlUpdatePacket",
    "com.zurrtum.create.infrastructure.packet.s2c.HonkReturnPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.TrainPromptPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.ContraptionRelocationPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.TrackGraphRollCallPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.ArmPlacementRequestPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.EjectorPlacementRequestPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.PackagePortPlacementRequestPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.ContraptionColliderLockPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.ServerDebugInfoPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.ClientboundChainConveyorRidingPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.TrackGraphSyncPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.AddTrainPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.BlueprintPreviewPacket",
    "com.zurrtum.create.infrastructure.packet.s2c.S2CHoldPacket"
}, priority = 2000, remap = false)
public abstract class CreateFlyClientPacketThreadingMixin {
    /**
     * 合并后的 this 就是原 packet；unchecked cast 仅表达 profile 已冻结的泛型接口。
     * CallbackInfo 不取消、不捕获控制异常，同线程返回后执行原业务，异线程原生异常终止原路径。
     */
    @SuppressWarnings("unchecked")
    @Inject(method = "handle(Lnet/minecraft/network/protocol/game/ClientGamePacketListener;)V",
        at = @At("HEAD"), require = 1, allow = 1, remap = false)
    private void amcl$guardClientThread(ClientGamePacketListener listener, CallbackInfo callback) {
        CreateFlyPacketThreading26.client((Packet<ClientGamePacketListener>) (Object) this, listener);
    }
}
