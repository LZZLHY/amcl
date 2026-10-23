package net.minecraft.network.protocol.game;

import net.minecraft.network.PacketListener;

/**
 * 宿主测试专用端点接口，只声明生产桥和真实 bundle 字节码用到的 ABI。
 * 不实现游戏状态，也不冒充真正 Knot/客户端；完整接口和原类另由实物变换与设备门验证。
 */
public interface ClientGamePacketListener extends PacketListener {
    void handleBundlePacket(ClientboundBundlePacket packet);
}
