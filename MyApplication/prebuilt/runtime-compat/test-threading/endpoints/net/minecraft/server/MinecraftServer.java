package net.minecraft.server;

import net.minecraft.network.PacketProcessor;

/** 宿主逻辑服务器端点，只携带独立原生队列；不借用客户端队列。 */
public final class MinecraftServer {
    private final PacketProcessor processor;
    public MinecraftServer(PacketProcessor processor) { this.processor = processor; }
    public PacketProcessor packetProcessor() { return processor; }
}
