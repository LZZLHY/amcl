package net.minecraft.client;

import net.minecraft.network.PacketProcessor;

/**
 * 不启动 GPU 的测试端点，仅把测试指定的真实 Mojang PacketProcessor 暴露给生产桥。
 * 与真实 Minecraft 同名仅为测试子进程链接固定 ABI；此目录永不进入生产编译或制品。
 */
public final class Minecraft {
    private static Minecraft instance;
    private final PacketProcessor processor;
    public Minecraft(PacketProcessor processor) { this.processor = processor; }
    /** 每个试验显式安装所属线程，避免各试验误共用队列或遗留连接。 */
    public static void install(PacketProcessor processor) { instance = new Minecraft(processor); }
    public static Minecraft getInstance() { return instance; }
    public PacketProcessor packetProcessor() { return processor; }
}
