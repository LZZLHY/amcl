package net.minecraft.client.multiplayer;

import java.util.ArrayList;
import java.util.List;
import net.minecraft.client.Minecraft;
import net.minecraft.network.ConnectionProtocol;
import net.minecraft.network.DisconnectionDetails;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.PacketFlow;
import net.minecraft.network.protocol.PacketUtils;
import net.minecraft.network.protocol.game.ClientGamePacketListener;
import net.minecraft.network.protocol.game.ClientboundBundlePacket;

/**
 * 可控 listener 端点：连接是否接收由试验设置，错误归档而不引发真实游戏退出。
 * 队列与有效性检查完全使用原件 PacketProcessor；此类不复制或替代其实现。
 */
public final class ClientPacketListener implements ClientGamePacketListener {
    /** 上游真实 forceMainThread 字节码读取的字段；测试实例绑定安装时的处理器。 */
    public final Minecraft minecraft = Minecraft.getInstance();
    public boolean accepting = true;
    public final List<Exception> errors = new ArrayList<>();
    public PacketFlow flow() { return PacketFlow.CLIENTBOUND; }
    public ConnectionProtocol protocol() { return ConnectionProtocol.PLAY; }
    public void onDisconnect(DisconnectionDetails details) { accepting = false; }
    public boolean isAcceptingMessages() { return accepting; }
    public void onPacketError(Packet packet, Exception error) { errors.add(error); }
    /**
     * 仅提供 bundle 的测试分派端点，使用真实 ClientboundBundlePacket.subPackets()。
     * 原生 bundle handler 的整体 guard 与子包连续直通契约在这里显式驱动；最终真实
     * ClientPacketListener 的调用链仍须单独字节码审计与真机验证。
     */
    public void handleBundlePacket(ClientboundBundlePacket bundle) {
        PacketUtils.ensureRunningOnSameThread(bundle, this, Minecraft.getInstance().packetProcessor());
        for (Packet<? super ClientGamePacketListener> child : bundle.subPackets()) child.handle(this);
    }
}
