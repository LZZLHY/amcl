package com.amcl.compat.test;

import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;
import java.util.jar.JarFile;

/**
 * 调度子进程的加载来源断言：原生调度/Bundle/控制异常必须来自派生view、原class字节
 * 与官方原件完全相同且signer为空；八个手写端点必须来自单独的测试目录。这里不关掉
 * ClassLoader安全检查，也不把unsigned域称为真实Knot或原版签名已保留。
 */
public final class SchedulingViewProvenance {
    private SchedulingViewProvenance() {}
    private static void check(boolean condition, String reason) { if (!condition) throw new AssertionError(reason); }

    /** 只做不初始化的Class加载/来源核实；调度与业务执行由各suite后续显式驱动。 */
    public static void verify(Path official, Path view) throws Exception {
        ClassLoader loader = SchedulingViewProvenance.class.getClassLoader();
        Path actualView = view.toRealPath();
        try (JarFile original = new JarFile(official.toFile())) {
            for (String name : List.of("net.minecraft.network.PacketProcessor", "net.minecraft.network.PacketProcessor$ListenerAndPacket",
                "net.minecraft.network.protocol.PacketUtils", "net.minecraft.network.protocol.Packet", "net.minecraft.network.PacketListener",
                "net.minecraft.network.protocol.BundlePacket", "net.minecraft.network.protocol.game.ClientboundBundlePacket",
                "net.minecraft.server.RunningOnDifferentThreadException")) {
                Class<?> type = Class.forName(name, false, loader);
                check(Path.of(type.getProtectionDomain().getCodeSource().getLocation().toURI()).toRealPath().equals(actualView),
                    "Original scheduling class not loaded from declared view: " + name);
                check(type.getSigners() == null || type.getSigners().length == 0, "Scheduling class unexpectedly retains another signer domain: " + name);
                String entry = name.replace('.', '/') + ".class";
                try (var source = original.getInputStream(original.getJarEntry(entry)); var loaded = type.getResourceAsStream("/" + entry)) {
                    check(loaded != null && Arrays.equals(source.readAllBytes(), loaded.readAllBytes()), "Loaded original class bytes changed: " + name);
                }
            }
        }
        Path endpointRoot = Path.of(SchedulingViewProvenance.class.getProtectionDomain().getCodeSource().getLocation().toURI()).toRealPath();
        for (String name : List.of("net.minecraft.client.Minecraft", "net.minecraft.client.multiplayer.ClientPacketListener",
            "net.minecraft.network.protocol.game.ClientGamePacketListener", "net.minecraft.network.protocol.game.ServerGamePacketListener",
            "net.minecraft.server.MinecraftServer", "net.minecraft.server.level.ServerLevel", "net.minecraft.server.level.ServerPlayer",
            "net.minecraft.server.network.ServerGamePacketListenerImpl")) {
            Class<?> type = Class.forName(name, false, loader);
            check(Path.of(type.getProtectionDomain().getCodeSource().getLocation().toURI()).toRealPath().equals(endpointRoot), "Endpoint loaded outside isolated test root: " + name);
            check(type.getSigners() == null || type.getSigners().length == 0, "Endpoint signer domain changed: " + name);
        }
        System.out.println("[scheduling-view-provenance] PASS original-class-payload=equal native-source=derived-unsigned-view endpoints=8 signer-checks=enabled actualKnot=false");
    }
}
