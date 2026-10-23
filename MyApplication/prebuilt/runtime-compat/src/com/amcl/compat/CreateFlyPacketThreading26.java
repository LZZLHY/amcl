package com.amcl.compat;

import java.util.concurrent.atomic.AtomicBoolean;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientPacketListener;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.PacketUtils;
import net.minecraft.network.protocol.game.ClientGamePacketListener;
import net.minecraft.network.protocol.game.ServerGamePacketListener;
import net.minecraft.server.network.ServerGamePacketListenerImpl;

/**
 * 固定 26.2 Create Fly 旧包的线程交接桥，只由通过完整 profile 的 typed handle 调用。
 * 不创建队列、不保存包、不吞异常，也不改变 AllHandle 的旧公开 ABI。Minecraft 原生
 * PacketUtils 决定当前是否直通；异线程时保存原 listener/packet 并抛出原生控制异常，
 * 从而阻止网络线程继续业务，随后仍由原 PacketProcessor 检查有效性、回放和处理错误。
 * 此类与 26.2 专属 Mixin 独立，通用插件不得引用其类字面量，避免 1.21.11/JDK21 提前链接。
 */
public final class CreateFlyPacketThreading26 {
    private static final AtomicBoolean CLIENT_EXECUTED = new AtomicBoolean();
    private static final AtomicBoolean SERVER_EXECUTED = new AtomicBoolean();

    /** 工具类不保存连接或世界，禁止构造跨会话对象。 */
    private CreateFlyPacketThreading26() {}

    /**
     * 恢复上游客户端 guard：仅真实 ClientPacketListener 采用单客户端实例的原生处理器。
     * 保留收到的 listener，不以 getConnection() 猜测替换它；自定义 listener 保持上游
     * instanceof 前提。调用已经在正确线程时直接返回，bundle 子包不会被再次排队。
     * PacketUtils 的控制异常、关闭拒绝及 Error 均原样传播，调用方不可捕获后继续业务。
     */
    public static void client(Packet<ClientGamePacketListener> packet, ClientGamePacketListener listener) {
        if (listener instanceof ClientPacketListener) {
            PacketUtils.ensureRunningOnSameThread(packet, listener, Minecraft.getInstance().packetProcessor());
            if (CLIENT_EXECUTED.compareAndSet(false, true)) {
                System.out.println("[AMCL-CREATE-THREAD] schema=1 rule=create-fly-play-threading stage=first-execution side=client target="
                    + packet.getClass().getName());
            }
        }
    }

    /**
     * 集成服务器使用实际玩家所属 ServerLevel 的原版重载，绝不能复用客户端处理器。
     * player 与 level() 的 public ABI 已按 26.2 原件冻结；不在 guard 前读菜单、实体或背包。
     * 共享 Hold 对象每次投递都调用本方法，不用对象身份去重；排队/失效/拒绝仍归原生机制。
     * 非原版 listener 留给原包的既有强转决定行为，不扩大已审核实现的支持范围。
     */
    public static void server(Packet<ServerGamePacketListener> packet, ServerGamePacketListener listener) {
        if (listener instanceof ServerGamePacketListenerImpl serverListener) {
            PacketUtils.ensureRunningOnSameThread(packet, listener, serverListener.player.level());
            if (SERVER_EXECUTED.compareAndSet(false, true)) {
                System.out.println("[AMCL-CREATE-THREAD] schema=1 rule=create-fly-play-threading stage=first-execution side=server target="
                    + packet.getClass().getName());
            }
        }
    }
}
