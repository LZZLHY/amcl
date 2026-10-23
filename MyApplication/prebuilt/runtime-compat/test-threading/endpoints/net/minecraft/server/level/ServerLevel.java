package net.minecraft.server.level;

import net.minecraft.server.MinecraftServer;

/** 只提供真实 PacketUtils 的 ServerLevel 重载所需的 getServer() ABI。 */
public final class ServerLevel {
    private final MinecraftServer server;
    public ServerLevel(MinecraftServer server) { this.server = server; }
    public MinecraftServer getServer() { return server; }
}
