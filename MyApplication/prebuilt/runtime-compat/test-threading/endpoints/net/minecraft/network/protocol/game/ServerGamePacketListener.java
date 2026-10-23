package net.minecraft.network.protocol.game;

import net.minecraft.network.PacketListener;

/** 宿主端点仅保留真实生产 guard 的参数类型；不模拟服务器业务、连接或网络。 */
public interface ServerGamePacketListener extends PacketListener {}
