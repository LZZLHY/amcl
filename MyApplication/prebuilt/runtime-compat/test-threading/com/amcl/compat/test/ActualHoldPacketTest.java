package com.amcl.compat.test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Consumer;
import java.util.jar.JarFile;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientPacketListener;
import net.minecraft.network.PacketProcessor;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.PacketType;
import net.minecraft.network.protocol.game.ClientGamePacketListener;
import net.minecraft.network.protocol.game.ServerGamePacketListener;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.RunningOnDifferentThreadException;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.server.network.ServerGamePacketListenerImpl;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.MethodNode;

/**
 * 实际执行原件旧 Hold、真实 Mixin 变换的旧 Hold 和官方新版 Hold，比较同一队列语义。
 * 唯一裁剪是上游 AllHandle.forceMainThread 方法原字节移入窄 AllClientHandle 端点，
 * 无重写方法体；报告必须明确这是宿主方法级集成，仍不是完整 Create 世界/Loader。
 */
public final class ActualHoldPacketTest {
    private static final String CLIENT = "com.zurrtum.create.infrastructure.packet.s2c.S2CHoldPacket";
    private static final String SERVER = "com.zurrtum.create.infrastructure.packet.c2s.C2SHoldPacket";
    private static final String DISPATCH = "com.zurrtum.create.AllClientHandle";

    /** 每组原件/变换/新版必须独立定义，避免 JVM 按先加载版本复用类。 */
    private static final class BytesLoader extends ClassLoader {
        private final Map<String, byte[]> definitions;
        BytesLoader(Map<String, byte[]> definitions) { super(ActualHoldPacketTest.class.getClassLoader()); this.definitions = definitions; }
        @Override protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
            if (!definitions.containsKey(name)) return super.loadClass(name, resolve);
            synchronized (getClassLoadingLock(name)) {
                Class<?> result = findLoadedClass(name);
                if (result == null) {
                    byte[] value = definitions.get(name); result = defineClass(name, value, 0, value.length);
                }
                if (resolve) resolveClass(result);
                return result;
            }
        }
    }

    private static void check(boolean condition, String reason) { if (!condition) throw new AssertionError(reason); }
    private static byte[] bytes(JarFile jar, String name) throws Exception {
        try (var stream = jar.getInputStream(jar.getJarEntry(name.replace('.', '/') + ".class"))) { return stream.readAllBytes(); }
    }

    /**
     * 上游调度方法从锁定官方新包提取，直接保留 instructions、try/catch 和 stack frame。
     * 外壳只有默认构造与 INSTANCE 初始化，无自主调度实现，禁止误称完整原 AllHandle 已加载。
     */
    private static byte[] upstreamDispatch(byte[] original) {
        ClassNode originalNode = new ClassNode(); new ClassReader(original).accept(originalNode, 0);
        String descriptor = "(Lnet/minecraft/network/protocol/game/ClientGamePacketListener;Lnet/minecraft/network/protocol/Packet;)V";
        MethodNode selected = originalNode.methods.stream().filter(method -> method.name.equals("forceMainThread")
            && method.desc.equals(descriptor)).findFirst().orElseThrow();
        String owner = DISPATCH.replace('.', '/');
        ClassWriter output = new ClassWriter(0); output.visit(69, Opcodes.ACC_PUBLIC, owner, null, "java/lang/Object", null);
        output.visitField(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, "INSTANCE", "L" + owner + ";", null, null).visitEnd();
        var constructor = output.visitMethod(Opcodes.ACC_PUBLIC, "<init>", "()V", null, null);
        constructor.visitCode(); constructor.visitVarInsn(Opcodes.ALOAD, 0);
        constructor.visitMethodInsn(Opcodes.INVOKESPECIAL, "java/lang/Object", "<init>", "()V", false);
        constructor.visitInsn(Opcodes.RETURN); constructor.visitMaxs(1, 1); constructor.visitEnd();
        var initializer = output.visitMethod(Opcodes.ACC_STATIC, "<clinit>", "()V", null, null);
        initializer.visitCode(); initializer.visitTypeInsn(Opcodes.NEW, owner); initializer.visitInsn(Opcodes.DUP);
        initializer.visitMethodInsn(Opcodes.INVOKESPECIAL, owner, "<init>", "()V", false);
        initializer.visitFieldInsn(Opcodes.PUTSTATIC, owner, "INSTANCE", "L" + owner + ";");
        initializer.visitInsn(Opcodes.RETURN); initializer.visitMaxs(2, 0); initializer.visitEnd();
        selected.accept(output); output.visitEnd(); return output.toByteArray();
    }

    /** 子线程真正完成后才观察结果；同步关系既避免测试自己的竞态，也核实控制异常身份。 */
    private static Throwable network(Runnable task) throws Exception {
        AtomicReference<Throwable> result = new AtomicReference<>();
        Thread worker = new Thread(() -> { try { task.run(); } catch (Throwable error) { result.set(error); } }, "Actual-Hold-Network");
        worker.setDaemon(true); worker.start(); worker.join(5000);
        if (worker.isAlive()) { worker.interrupt(); worker.join(500); }
        check(!worker.isAlive(), "actual hold worker stuck"); return result.get();
    }

    /** 实际 canonical constructor 不创建 Identifier/codec；回调只是观察执行线程和次数。 */
    @SuppressWarnings("unchecked")
    private static void runClient(String label, ClassLoader loader, boolean guarded) throws Exception {
        PacketProcessor processor = new PacketProcessor(Thread.currentThread()); Minecraft.install(processor);
        ClientPacketListener listener = new ClientPacketListener(); List<Thread> callbacks = new ArrayList<>();
        Class<?> type = Class.forName(CLIENT, true, loader);
        Packet<ClientGamePacketListener> packet = (Packet<ClientGamePacketListener>) type.getConstructor(PacketType.class, Consumer.class)
            .newInstance(null, (Consumer<Object>) ignored -> callbacks.add(Thread.currentThread()));
        for (int index = 0; index < 16; index++) {
            Throwable signal = network(() -> packet.handle(listener));
            check(guarded ? signal == RunningOnDifferentThreadException.RUNNING_ON_DIFFERENT_THREAD : signal == null,
                label + " actual client hold control mismatch");
        }
        check(callbacks.size() == (guarded ? 0 : 16), label + " actual client hold wrong pre-drain count");
        processor.processQueuedPackets(); check(callbacks.size() == 16, label + " actual client hold lost/duplicated singleton");
        for (Thread callback : callbacks) check((callback == Thread.currentThread()) == guarded, label + " actual client owner mismatch");
        packet.handle(listener); check(callbacks.size() == 17, label + " same-thread client hold deferred");
        processor.processQueuedPackets(); check(callbacks.size() == 17, label + " same-thread client hold duplicated");
    }

    /** 服务器实际 Hold 使用独立逻辑侧入口；其 guard 由旧、变换、新原件共同对照。 */
    @SuppressWarnings("unchecked")
    private static void runServer(String label, ClassLoader loader, boolean guarded) throws Exception {
        PacketProcessor processor = new PacketProcessor(Thread.currentThread());
        ServerGamePacketListenerImpl listener = new ServerGamePacketListenerImpl(new ServerPlayer(new ServerLevel(new MinecraftServer(processor))));
        List<Thread> callbacks = new ArrayList<>();
        Class<?> type = Class.forName(SERVER, true, loader);
        Packet<ServerGamePacketListener> packet = (Packet<ServerGamePacketListener>) type.getConstructor(PacketType.class, Consumer.class)
            .newInstance(null, (Consumer<Object>) ignored -> callbacks.add(Thread.currentThread()));
        for (int index = 0; index < 16; index++) {
            Throwable signal = network(() -> packet.handle(listener));
            check(guarded ? signal == RunningOnDifferentThreadException.RUNNING_ON_DIFFERENT_THREAD : signal == null,
                label + " actual server hold control mismatch");
        }
        check(callbacks.size() == (guarded ? 0 : 16), label + " server hold wrong pre-drain count");
        processor.processQueuedPackets(); check(callbacks.size() == 16, label + " actual server singleton lost/duplicated");
        for (Thread callback : callbacks) check((callback == Thread.currentThread()) == guarded, label + " server owner mismatch");
    }

    /** 参数均指向固定外置实物和先前真实变换输出；不保存或发布游戏/模组类。 */
    public static void main(String[] args) throws Exception {
        check(args.length == 5, "usage: old.jar fixed.jar transformed-directory official-minecraft.jar derived-scheduling-view.jar");
        SchedulingViewProvenance.verify(Path.of(args[3]), Path.of(args[4]));
        try (JarFile old = new JarFile(args[0]); JarFile fixed = new JarFile(args[1])) {
            byte[] dispatch = upstreamDispatch(bytes(fixed, "com.zurrtum.create.client.AllHandle"));
            for (String label : List.of("original-old", "actual-mixin", "official-fixed")) {
                Map<String, byte[]> definitions = new HashMap<>(); definitions.put(DISPATCH, dispatch);
                for (String name : List.of(CLIENT, SERVER)) definitions.put(name, label.equals("actual-mixin")
                    ? Files.readAllBytes(Path.of(args[2]).resolve(name.replace('.', '/') + ".class"))
                    : bytes(label.equals("original-old") ? old : fixed, name));
                BytesLoader loader = new BytesLoader(definitions);
                runClient(label, loader, !label.equals("original-old"));
                runServer(label, loader, !label.equals("original-old"));
            }
        }
        System.out.println("[actual-hold] PASS original old / actual Mixin / official fixed S2C+C2S Hold bytecode, 16 deliveries each, native queue, exact upstream dispatch method with isolated endpoints; not full Loader/world validation");
    }
}
