package com.amcl.compat.mixin;

import com.amcl.compat.CreateFlyPacketThreading26;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.game.ServerGamePacketListener;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * 客户端进程内集成服务器的独立 C2S 修复：17 个普通缺口、一个共享 Hold 类，另加
 * ClipboardEdit 原来只保护 targetedBlock 分支的条件缺口，共 19 个实际类。
 * Hold 对应三个注册项，因此注册数不能当类数；原有 46 个首部 guard 与 CONFIG 不变。
 * 兼容模组 environment=client，此处不能表述为已经给远端专用服务器安装了修复。
 */
@Mixin(targets = {
    "com.zurrtum.create.infrastructure.packet.c2s.ConfigureSchematicannonPacket",
    "com.zurrtum.create.infrastructure.packet.c2s.FilterScreenPacket",
    "com.zurrtum.create.infrastructure.packet.c2s.ClientMotionPacket",
    "com.zurrtum.create.infrastructure.packet.c2s.SchematicSyncPacket",
    "com.zurrtum.create.infrastructure.packet.c2s.GhostItemSubmitPacket",
    "com.zurrtum.create.infrastructure.packet.c2s.BlueprintAssignCompleteRecipePacket",
    "com.zurrtum.create.infrastructure.packet.c2s.ConfigureSymmetryWandPacket",
    "com.zurrtum.create.infrastructure.packet.c2s.ConfigureWorldshaperPacket",
    "com.zurrtum.create.infrastructure.packet.c2s.ScheduleEditPacket",
    "com.zurrtum.create.infrastructure.packet.c2s.TrainEditPacket",
    "com.zurrtum.create.infrastructure.packet.c2s.TrainRelocationPacket",
    "com.zurrtum.create.infrastructure.packet.c2s.ControlsInputPacket",
    "com.zurrtum.create.infrastructure.packet.c2s.PlaceExtendedCurvePacket",
    "com.zurrtum.create.infrastructure.packet.c2s.TrainHUDUpdatePacket",
    "com.zurrtum.create.infrastructure.packet.c2s.HonkPacket",
    "com.zurrtum.create.infrastructure.packet.c2s.TrackGraphRequestPacket",
    "com.zurrtum.create.infrastructure.packet.c2s.ContraptionColliderLockPacketRequest",
    "com.zurrtum.create.infrastructure.packet.c2s.C2SHoldPacket",
    "com.zurrtum.create.infrastructure.packet.c2s.ClipboardEditPacket"
}, priority = 2000, remap = false)
public abstract class CreateFlyServerPacketThreadingMixin {
    /** 与客户端同样只注入真实 typed 入口；旧业务 ABI 及 wire 编码完全保留。 */
    @SuppressWarnings("unchecked")
    @Inject(method = "handle(Lnet/minecraft/network/protocol/game/ServerGamePacketListener;)V",
        at = @At("HEAD"), require = 1, allow = 1, remap = false)
    private void amcl$guardServerThread(ServerGamePacketListener listener, CallbackInfo callback) {
        CreateFlyPacketThreading26.server((Packet<ServerGamePacketListener>) (Object) this, listener);
    }
}
