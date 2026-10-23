package net.minecraft.server.network;

import java.util.ArrayList;
import java.util.List;
import net.minecraft.network.ConnectionProtocol;
import net.minecraft.network.DisconnectionDetails;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.PacketFlow;
import net.minecraft.network.protocol.game.ServerGamePacketListener;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.server.MinecraftServer;

/** 独立玩家端点；公开 player 字段的描述符与真实 26.2 完全一致。 */
public final class ServerGamePacketListenerImpl implements ServerGamePacketListener {
    public final ServerPlayer player;
    /** 官方新版 C2SHold 使用的实际字段；与 player.level().getServer() 指向相同逻辑侧。 */
    public final MinecraftServer server;
    public boolean accepting = true;
    public final List<Exception> errors = new ArrayList<>();
    public ServerGamePacketListenerImpl(ServerPlayer player) { this.player = player; this.server = player.level().getServer(); }
    public PacketFlow flow() { return PacketFlow.SERVERBOUND; }
    public ConnectionProtocol protocol() { return ConnectionProtocol.PLAY; }
    public void onDisconnect(DisconnectionDetails details) { accepting = false; }
    public boolean isAcceptingMessages() { return accepting; }
    public void onPacketError(Packet packet, Exception error) { errors.add(error); }
}
