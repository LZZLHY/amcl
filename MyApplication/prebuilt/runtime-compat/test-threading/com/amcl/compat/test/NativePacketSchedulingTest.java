package com.amcl.compat.test;

import com.amcl.compat.CreateFlyPacketThreading26;
import java.util.ArrayList;
import java.util.ConcurrentModificationException;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.atomic.AtomicReference;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientPacketListener;
import net.minecraft.network.PacketProcessor;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.PacketType;
import net.minecraft.network.protocol.game.ClientGamePacketListener;
import net.minecraft.network.protocol.game.ClientboundBundlePacket;
import net.minecraft.network.protocol.game.ServerGamePacketListener;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.RunningOnDifferentThreadException;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.server.network.ServerGamePacketListenerImpl;

/**
 * 原件调度集成试验：队列、控制异常、有效性和错误路径均来自固定 MC26.2 字节码。
 * 游戏/GPU/玩家仅用明确隔离的端点承载 ABI；这里不能作为 Knot 或真实世界回归通过。
 */
public final class NativePacketSchedulingTest {
    private static final Thread OWNER = Thread.currentThread();
    private static final List<String> EVENTS = new ArrayList<>();

    /** 每个包保留独立投递身份；共享单例可重复调用，不用对象 Set 计数。 */
    private static final class ClientPacket implements Packet<ClientGamePacketListener> {
        private final boolean guarded;
        private final Runnable action;
        ClientPacket(boolean guarded, Runnable action) { this.guarded = guarded; this.action = action; }
        public PacketType<ClientPacket> type() { return null; }
        public void handle(ClientGamePacketListener listener) {
            if (guarded) CreateFlyPacketThreading26.client(this, listener);
            action.run();
        }
    }

    /** 服务器包只调用服务器生产桥；业务断言验证运行于逻辑服务器所属线程。 */
    private static final class ServerPacket implements Packet<ServerGamePacketListener> {
        private final Runnable action;
        ServerPacket(Runnable action) { this.action = action; }
        public PacketType<ServerPacket> type() { return null; }
        public void handle(ServerGamePacketListener listener) {
            CreateFlyPacketThreading26.server(this, listener);
            action.run();
        }
    }

    private static void check(boolean condition, String reason) {
        if (!condition) throw new AssertionError(reason);
    }

    /** 等待网络投递实际结束并透传异常；没有 sleep，也不把后台线程异常漏报成成功。 */
    private static Throwable network(Runnable action) throws InterruptedException {
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread thread = new Thread(() -> {
            try { action.run(); } catch (Throwable error) { failure.set(error); }
        }, "AMCL-Test-Network");
        thread.setDaemon(true);
        thread.start(); thread.join(5000);
        if (thread.isAlive()) { thread.interrupt(); thread.join(500); }
        check(!thread.isAlive(), "network submission did not terminate");
        return failure.get();
    }

    /** 受控负例保留故障机制：迭代开始后，网络回调结构修改普通 HashMap。 */
    private static void cmeControl() throws Exception {
        Map<Integer, String> trains = new HashMap<>();
        trains.put(1, "train-a"); trains.put(2, "train-b");
        Iterator<String> rendering = trains.values().iterator();
        ClientPacketListener listener = new ClientPacketListener();
        Throwable error = network(() -> new ClientPacket(false, () -> trains.put(3, "train-c")).handle(listener));
        check(error == null, "negative control packet unexpectedly failed");
        try { rendering.next(); throw new AssertionError("old unsynchronized iteration did not fail"); }
        catch (ConcurrentModificationException expected) { /* 原错误必须被稳定重现。 */ }
        PacketProcessor processor = new PacketProcessor(OWNER); Minecraft.install(processor);
        trains.remove(3); rendering = trains.values().iterator();
        error = network(() -> new ClientPacket(true, () -> trains.put(3, "train-c")).handle(listener));
        check(error == RunningOnDifferentThreadException.RUNNING_ON_DIFFERENT_THREAD, "guard must preserve native control exception");
        check(trains.size() == 2, "network thread accessed train state before queue replay");
        rendering.next(); rendering.next();
        processor.processQueuedPackets();
        check(trains.size() == 3 && "train-c".equals(trains.get(3)), "valid queued state update lost");
    }

    /** 同一 Hold 对象的 N 次交付必须 N 次执行；同线程直接调用立即执行，零额外队列。 */
    private static void holdAndBundle() throws Exception {
        PacketProcessor processor = new PacketProcessor(OWNER); Minecraft.install(processor);
        ClientPacketListener listener = new ClientPacketListener(); EVENTS.clear();
        ClientPacket hold = new ClientPacket(true, () -> {
            check(Thread.currentThread() == OWNER, "client callback on network thread"); EVENTS.add("hold");
        });
        for (int i = 0; i < 64; i++)
            check(network(() -> hold.handle(listener)) == RunningOnDifferentThreadException.RUNNING_ON_DIFFERENT_THREAD, "missing hold scheduling signal");
        check(EVENTS.isEmpty(), "hold executed before drain");
        processor.processQueuedPackets(); check(EVENTS.size() == 64, "same singleton lost or duplicated a delivery");
        hold.handle(listener); check(EVENTS.size() == 65, "same-thread packet did not pass through");
        processor.processQueuedPackets(); check(EVENTS.size() == 65, "same-thread packet double-queued");
        EVENTS.clear();
        ClientPacket first = new ClientPacket(true, () -> EVENTS.add("first"));
        ClientPacket second = new ClientPacket(true, () -> EVENTS.add("second"));
        ClientboundBundlePacket bundle = new ClientboundBundlePacket(List.of(first, second, hold, hold));
        check(network(() -> bundle.handle(listener)) == RunningOnDifferentThreadException.RUNNING_ON_DIFFERENT_THREAD, "bundle dispatch did not queue");
        processor.processQueuedPackets();
        check(EVENTS.equals(List.of("first", "second", "hold", "hold")), "bundle children reordered, deferred or deduplicated");
        processor.processQueuedPackets(); check(EVENTS.size() == 4, "bundle children leaked another queued delivery");
    }

    /** 区分有效执行、失效忽略、关闭拒绝和业务异常，不能强行把它们全算作执行成功。 */
    private static void lifetimeAndErrors() throws Exception {
        PacketProcessor processor = new PacketProcessor(OWNER); Minecraft.install(processor);
        ClientPacketListener old = new ClientPacketListener(); ClientPacketListener fresh = new ClientPacketListener();
        EVENTS.clear();
        ClientPacket packet = new ClientPacket(true, () -> EVENTS.add("executed"));
        check(network(() -> packet.handle(old)) == RunningOnDifferentThreadException.RUNNING_ON_DIFFERENT_THREAD, "old connection did not queue");
        old.accepting = false;
        check(network(() -> packet.handle(fresh)) == RunningOnDifferentThreadException.RUNNING_ON_DIFFERENT_THREAD, "fresh connection did not queue");
        processor.processQueuedPackets();
        check(EVENTS.equals(List.of("executed")), "disconnected listener wrote state or valid new listener was lost");
        RuntimeException cause = new IllegalStateException("controlled business failure");
        check(network(() -> new ClientPacket(true, () -> { throw cause; }).handle(fresh))
            == RunningOnDifferentThreadException.RUNNING_ON_DIFFERENT_THREAD, "business action ran on submission");
        processor.processQueuedPackets(); check(fresh.errors.equals(List.of(cause)), "native onPacketError contract changed");
        AssertionError fatal = new AssertionError("controlled fatal");
        check(network(() -> new ClientPacket(true, () -> { throw fatal; }).handle(fresh))
            == RunningOnDifferentThreadException.RUNNING_ON_DIFFERENT_THREAD, "fatal action ran on submission");
        try { processor.processQueuedPackets(); throw new AssertionError("fatal Error swallowed"); }
        catch (AssertionError expected) { check(expected == fatal, "wrong fatal error"); }
        processor.close();
        check(network(() -> packet.handle(fresh)) instanceof RejectedExecutionException, "closed processor submission not rejected");
        check(EVENTS.size() == 1, "rejected packet executed");
    }

    /**
     * 独立服务器线程处理两个玩家；客户端队列在试验期间保持空闲。主线程不能假装为
     * 逻辑服务器 drain。玩家断线只忽略其自己的投递，其他玩家的队列工作继续有效。
     */
    private static void serverOwnership() throws Exception {
        AtomicReference<PacketProcessor> processor = new AtomicReference<>();
        AtomicReference<Throwable> failure = new AtomicReference<>();
        java.util.concurrent.CountDownLatch initialized = new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.CountDownLatch submitted = new java.util.concurrent.CountDownLatch(1);
        List<String> handled = new ArrayList<>();
        Thread server = new Thread(() -> {
            PacketProcessor value = new PacketProcessor(Thread.currentThread()); processor.set(value); initialized.countDown();
            try { check(submitted.await(5, java.util.concurrent.TimeUnit.SECONDS), "server submissions timed out"); value.processQueuedPackets(); }
            catch (Throwable error) { failure.set(error); }
        }, "AMCL-Test-Integrated-Server");
        server.setDaemon(true);
        server.start(); check(initialized.await(5, java.util.concurrent.TimeUnit.SECONDS), "server initialization timed out");
        MinecraftServer owner = new MinecraftServer(processor.get());
        ServerGamePacketListenerImpl playerA = new ServerGamePacketListenerImpl(new ServerPlayer(new ServerLevel(owner)));
        ServerGamePacketListenerImpl playerB = new ServerGamePacketListenerImpl(new ServerPlayer(new ServerLevel(owner)));
        ServerPacket hold = new ServerPacket(() -> {
            check(Thread.currentThread() == server, "server callback ran on client or network thread"); handled.add("valid");
        });
        try {
            for (int i = 0; i < 32; i++)
                check(network(() -> hold.handle(playerA)) == RunningOnDifferentThreadException.RUNNING_ON_DIFFERENT_THREAD, "server hold not queued");
            check(network(() -> hold.handle(playerB)) == RunningOnDifferentThreadException.RUNNING_ON_DIFFERENT_THREAD, "other player not queued");
            playerB.accepting = false;
        } finally { submitted.countDown(); }
        server.join(5000);
        if (server.isAlive()) { server.interrupt(); server.join(500); }
        check(!server.isAlive(), "server processor did not finish");
        check(failure.get() == null, "server processor failed: " + failure.get());
        check(handled.size() == 32, "server shared hold executions or per-player ignore changed");
        processor.get().close();
        check(network(() -> hold.handle(playerA)) instanceof RejectedExecutionException, "closed server processor not rejected");
    }

    /** 入口只运行受控宿主试验；每项证据强度独立标注，绝不冒充完整游戏运行。 */
    public static void main(String[] args) throws Exception {
        check(args.length == 2, "usage: official-minecraft.jar derived-scheduling-view.jar");
        SchedulingViewProvenance.verify(java.nio.file.Path.of(args[0]), java.nio.file.Path.of(args[1]));
        cmeControl(); holdAndBundle(); lifetimeAndErrors(); serverOwnership();
        System.out.println("[native-packet-scheduling] PASS original MC26.2 PacketProcessor/PacketUtils bytecode, production bridge with isolated ABI endpoints; CME old/fixed, control exception, hold64, bundle, same-thread, disconnect, reject, errors, integrated-server32/two listeners");
    }
}
