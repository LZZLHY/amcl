package com.amcl.compat.probe;

import com.google.gson.Gson;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.zurrtum.create.client.Create;
import com.zurrtum.create.content.trains.entity.Train;
import com.zurrtum.create.infrastructure.packet.c2s.C2SHoldPacket;
import com.zurrtum.create.infrastructure.packet.s2c.AddTrainPacket;
import com.zurrtum.create.infrastructure.packet.s2c.RemoveTrainPacket;
import com.zurrtum.create.infrastructure.packet.s2c.S2CHoldPacket;
import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientPacketListener;
import net.minecraft.client.server.IntegratedServer;
import net.minecraft.network.PacketListener;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.game.ClientGamePacketListener;
import net.minecraft.network.protocol.game.ClientboundBundlePacket;
import net.minecraft.server.RunningOnDifferentThreadException;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.server.network.ServerGamePacketListenerImpl;

import java.nio.charset.StandardCharsets;
import java.lang.invoke.MethodType;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/**
 * MC26.2 + 官方旧 Create 专用的真机 QA；实际 typed handle 是被测对象，原生
 * PacketProcessor 的调度和游戏帧循环是执行者。这里只构造测试输入和观测结果，
 * 不调用生产 helper、复制线程保护算法、提供假的 listener/队列，或改变游戏调度。
 *
 * 必须同时存在显式启用配置、独立 QA gameDir 和约定名称的新建单人世界。测试
 * 临时 Train 没有车厢/轨道，只在同一次 tick/队列 drain 内加入并移出客户端表；
 * 不让空车厢对象进入 renderAll（上游会 getFirst），不加入服务器铁路表，不写世界方块、
 * 玩家背包或存档。完成/失败后只按 UUID + 对象身份清理自己创建的客户端对象。
 */
public final class CreateThreadDeviceProbe {
    private static final Gson JSON = new Gson();
    private static final int ROUNDS = 32;
    private static final int BATCHES = 8;
    private static final int SERVER_REPEATS = 64;
    private static final long TIMEOUT_NANOS = 30_000_000_000L;
    private static boolean configured;
    private static JsonObject configuration;
    private static Run active;

    private CreateThreadDeviceProbe() {}

    /**
     * 配置只读一次。缺配置保持完全静默；错误配置只输出错误并禁用，不猜测目标。
     * 等真实世界和集成服务器 listener 就绪后开始；主菜单/远端服务器不启动测试。
     */
    public static void tick(Minecraft minecraft) {
        if (!configured) {
            configured = true;
            Path config = FabricLoader.getInstance().getGameDir().resolve("config/amcl-create-thread-probe.json");
            if (Files.isRegularFile(config)) {
                try {
                    JsonObject candidate = JsonParser.parseString(Files.readString(config)).getAsJsonObject();
                    if (candidate.get("schema").getAsInt() != 1 || !candidate.get("enabled").getAsBoolean()) return;
                    String expected = candidate.get("expectedGameDirectory").getAsString();
                    if (!expected.endsWith("-create-thread-qa")
                            || !FabricLoader.getInstance().getGameDir().getFileName().toString().equals(expected)
                            || !candidate.get("expectedWorldNamePrefix").getAsString().startsWith("AMCL Create Thread QA")) {
                        throw new IllegalArgumentException("QA instance/world isolation configuration mismatch");
                    }
                    configuration = candidate;
                } catch (Exception failure) {
                    System.out.println("[AMCL Create Probe] disabled: " + failure);
                }
            }
        }
        if (active != null) {
            active.tick();
            return;
        }
        if (configuration == null || minecraft.level == null || minecraft.player == null
                || minecraft.getConnection() == null || minecraft.getSingleplayerServer() == null) return;
        IntegratedServer server = minecraft.getSingleplayerServer();
        if (!server.getWorldData().getLevelName().startsWith(configuration.get("expectedWorldNamePrefix").getAsString())) return;
        if (!minecraft.getConnection().isAcceptingMessages()) return;
        active = new Run(minecraft, server);
        active.tick();
    }

    /** 独立于 tick 的真实渲染边界，覆盖 drain→零 tick→render 的帧。 */
    public static void beforeRender() {
        if (active != null) active.beforeRender();
    }

    /**
     * 单次进程内测试状态。客户端阶段只由客户端线程推进；服务器结果通过 volatile
     * 和原子计数发布。错误仅记录，不从 packet callback 抛出 Error 破坏原生队列。
     */
    private static final class Run {
        private final Minecraft minecraft;
        private final IntegratedServer server;
        private final ClientPacketListener listener;
        private final UUID playerId;
        private final UUID trainId = UUID.randomUUID();
        private final Train train;
        private final String run = UUID.randomUUID().toString();
        private final Path output;
        private final long started = System.nanoTime();
        private final AtomicReference<String> failure = new AtomicReference<>();
        private final AtomicInteger deferred = new AtomicInteger();
        private final AtomicInteger clientHolds = new AtomicInteger();
        private final AtomicInteger serverHolds = new AtomicInteger();
        private final Object workerLifecycle = new Object();
        private volatile boolean clientBatchDone;
        private volatile boolean ordinaryDone;
        private volatile boolean serverStarted;
        private volatile boolean serverDone;
        private volatile Thread worker;
        private volatile boolean workerStopped = true;
        private volatile boolean cancelled;
        private volatile boolean preflightDone;
        private boolean preflightSubmitted;
        private boolean knotVerified;
        private int batch;
        private int postTicks;
        private boolean finished;

        /** 固定当前真实 listener 和服务器身份；输入对象从客户端线程构造且只属 QA。 */
        private Run(Minecraft minecraft, IntegratedServer server) {
            this.minecraft = minecraft;
            this.server = server;
            this.listener = minecraft.getConnection();
            this.playerId = minecraft.player.getUUID();
            this.output = FabricLoader.getInstance().getGameDir().resolve("logs/amcl-create-thread-probe.jsonl");
            this.train = new Train(trainId, null, null, new ArrayList<>(), new ArrayList<>(), false, 0);
            emit("start", Map.of("gameDir", FabricLoader.getInstance().getGameDir().toString(),
                    "world", server.getWorldData().getLevelName(), "clientThread", Thread.currentThread().getName(),
                    "serverThread", server.getRunningThread().getName(), "trainId", trainId.toString(),
                    "expectedClientHolds", ROUNDS * 2 * BATCHES, "expectedServerHolds", SERVER_REPEATS));
        }

        /**
         * 每个批次跨真实帧执行，持续检查列车 values 迭代。测试超时/连接切换判失败；
         * 终止后仍清理自己的客户端对象，以覆盖已经排入原生队列的晚到 QA Add 包。
         */
        private void tick() {
            if (finished) {
                cleanup();
                return;
            }
            if (System.nanoTime() - started > TIMEOUT_NANOS) fail("timeout");
            if (minecraft.getConnection() != listener || minecraft.getSingleplayerServer() != server) fail("connection_changed");
            if (failure.get() != null) {
                stopAndFinishFailure();
                return;
            }
            try {
                // 遍历真实原表而非快照；不调用 renderer，避免为复现改变渲染资源生命周期。
                for (Train ignored : Create.RAILWAYS.trains.values()) { /* 每帧真实迭代 */ }
                if (!preflightSubmitted) {
                    beginPreflight();
                } else if (!preflightDone || !workerHasStopped()) {
                    return;
                } else if (!knotVerified) {
                    verifyKnotDefinitions();
                } else if (batch < BATCHES && (batch == 0 || (clientBatchDone && ordinaryDone))) {
                    beginClientBatch();
                } else if (batch == BATCHES && clientBatchDone && ordinaryDone && !serverStarted) {
                    serverStarted = true;
                    server.execute(this::beginServer);
                } else if (serverDone && ++postTicks >= 60) {
                    check(clientHolds.get() == ROUNDS * 2 * BATCHES, "client_count");
                    check(serverHolds.get() == SERVER_REPEATS, "server_count");
                    check(deferred.get() == 1 + BATCHES * (ROUNDS * 4 + 1) + SERVER_REPEATS + 1, "deferred_count");
                    cleanup();
                    check(!Create.RAILWAYS.trains.containsKey(trainId), "cleanup");
                    if (failure.get() == null && workerHasStopped()) {
                        cancelWorker();
                        publishResult(true);
                    }
                }
            } catch (Throwable unexpected) {
                fail("client_tick:" + unexpected);
            }
        }

        /**
         * 先投递无业务副作用的真实 S2C Hold，核对 guard 存在且回调在真实客户端
         * processor执行。旧/未生效兼容会在这里失败，尚未向列车表放任何测试对象。
         */
        private void beginPreflight() throws InterruptedException {
            preflightSubmitted = true;
            startWorker("AMCL-Create-QA-preflight", () -> dispatch(
                    new S2CHoldPacket("amcl_qa_preflight", ignored -> {
                        if (check(minecraft.packetProcessor().isSameThread(), "preflight_thread")) {
                            preflightDone = true;
                            emit("preflight_passed", Map.of("deferred", deferred.get()));
                        }
                    }), listener));
            awaitWorker("preflight_worker_timeout");
        }

        /**
         * 每次实际渲染前撤走本 QA 对象。正常链路在 tick/drain 内已撤走；这里一旦
         * 发现残留就失败并取消后续投递。无 tick 帧仍执行本方法，不能仅等下一 tick。
         */
        private void beforeRender() {
            if (Create.RAILWAYS != null && Create.RAILWAYS.trains.get(trainId) == train) {
                fail("train_reached_render_boundary");
            }
            cleanup();
            if (!finished && failure.get() != null) stopAndFinishFailure();
        }

        /**
         * 从实际正式兼容 JAR 的 profile 读取目标，不复制47项名单，不依赖已生成的
         * 兼容 JAR作编译输入。Class.forName(false) 经真实 Knot 定义/链接目标而不运行
         * Create 静态初始化；只解析 typed/bridge/已合并注入方法，不调用其他业务。
         * 此证据只声明真实加载器组合下的定义/链接，绝不冒充所有47项业务都执行。
         */
        private void verifyKnotDefinitions() {
            try {
                ClassLoader knot = CreateThreadDeviceProbe.class.getClassLoader();
                if (!check(knot != null && knot.getClass().getName().equals(
                        "net.fabricmc.loader.impl.launch.knot.KnotClassLoader"), "actual_knot_loader")) return;
                Class<?> profileClass = Class.forName("com.amcl.compat.CreateFlyThreadingProfile", false, knot);
                Object profile = profileClass.getConstructor().newInstance();
                String profileId = (String) profileClass.getMethod("id").invoke(profile);
                Method targets = profileClass.getMethod("targets", String.class);
                Method descriptor = profileClass.getMethod("descriptor", String.class);
                String createSource = codeSource(Create.class);
                int count = 0;
                for (String side : List.of("client", "server")) {
                    Object value = targets.invoke(profile, side);
                    if (!(value instanceof Set<?> names)) throw new IllegalStateException("Profile targets is not a Set");
                    String typed = (String) descriptor.invoke(profile, side);
                    MethodType signature = MethodType.fromMethodDescriptorString(typed.substring("handle".length()), knot);
                    Class<?> listenerType = signature.parameterType(0);
                    String guard = "client".equals(side) ? "amcl$guardClientThread" : "amcl$guardServerThread";
                    for (Object item : names) {
                        if (failure.get() != null) return;
                        if (!(item instanceof String name)) throw new IllegalStateException("Profile target is not a String");
                        Class<?> target = Class.forName(name, false, knot);
                        Method handle = target.getDeclaredMethod("handle", listenerType);
                        Method bridge = target.getDeclaredMethod("handle", PacketListener.class);
                        int guards = 0;
                        for (Method method : target.getDeclaredMethods()) {
                            Class<?>[] parameters = method.getParameterTypes();
                            if (method.getName().contains(guard) && method.getReturnType() == void.class
                                    && Modifier.isPrivate(method.getModifiers()) && parameters.length == 2
                                    && parameters[0] == listenerType && parameters[1].getName().equals(
                                    "org.spongepowered.asm.mixin.injection.callback.CallbackInfo")) guards++;
                        }
                        boolean valid = target.getClassLoader() == knot && codeSource(target).equals(createSource)
                                && handle.getReturnType() == void.class && !handle.isBridge()
                                && !Modifier.isStatic(handle.getModifiers()) && bridge.isBridge()
                                && bridge.isSynthetic() && bridge.getReturnType() == void.class && guards == 1;
                        emit("knot_target_defined", Map.of("profile", profileId, "side", side, "target", name,
                                "loader", target.getClassLoader().getClass().getName(), "codeSource", codeSource(target),
                                "typedDescriptor", typed, "guards", guards, "valid", valid, "definitionOnly", true));
                        if (!check(valid, "knot_target_linkage:" + name)) return;
                        count++;
                    }
                }
                if (check(count == 47, "knot_target_count:" + count)) {
                    knotVerified = emit("knot_definition_gate", Map.of("actualKnot", true, "definedAndLinked", count,
                            "profile", profileId, "profileCodeSource", codeSource(profileClass), "definitionOnly", true));
                }
            } catch (Throwable problem) {
                fail("knot_definition_gate:" + problem);
            }
        }

        /** CodeSource 必须存在；不把 null 或未知来源视作实际官方 Create 字节身份。 */
        private String codeSource(Class<?> type) {
            if (type.getProtectionDomain().getCodeSource() == null) {
                throw new IllegalStateException("Missing CodeSource: " + type.getName());
            }
            return type.getProtectionDomain().getCodeSource().getLocation().toExternalForm();
        }

        /**
         * 注册与取消在同一短锁内完成；锁内不 join、不执行包。服务器 setup 即使在
         * 失败之后晚执行，也不能再启动 worker。worker finally 发布停止握手并把
         * 最终清理交回真实客户端线程，不从 worker 直接改客户端表。
         */
        private boolean startWorker(String name, Runnable operation) {
            String problem = null;
            synchronized (workerLifecycle) {
                if (cancelled || failure.get() != null) return false;
                if (!workerHasStopped()) {
                    problem = "worker_overlap";
                } else {
                    try {
                        workerStopped = false;
                        worker = new Thread(() -> {
                            try {
                                operation.run();
                            } catch (Throwable unexpected) {
                                fail(name + ":" + unexpected);
                            } finally {
                                try {
                                    minecraft.execute(this::cleanup);
                                } catch (Throwable handoffFailure) {
                                    fail("worker_cleanup_handoff:" + handoffFailure);
                                } finally {
                                    workerStopped = true;
                                }
                            }
                        }, name);
                        worker.setDaemon(true);
                        worker.start();
                    } catch (Throwable startFailure) {
                        workerStopped = true;
                        worker = null;
                        problem = "worker_start:" + startFailure;
                    }
                }
            }
            // 生命周期锁不包日志/文件IO，也不与 emit 的证据锁形成反向取锁。
            if (problem != null) fail(problem);
            return problem == null;
        }

        /** 只做有界等待，绝不在持有 worker 注册/证据锁时等待线程终止。 */
        private void awaitWorker(String reason) throws InterruptedException {
            Thread current = worker;
            if (current == null) return;
            try {
                current.join(1000);
                if (!workerHasStopped()) fail(reason);
            } catch (InterruptedException interrupted) {
                fail("join_interrupted:" + reason);
                throw interrupted;
            } finally {
                if (failure.get() != null) cancelWorker();
            }
        }

        /** 停止握手和实际 Thread 生命周期都结束才允许发布终态。 */
        private boolean workerHasStopped() {
            Thread current = worker;
            return workerStopped && (current == null || !current.isAlive());
        }

        /** 锁住注册边界后取消；每次 packet 投递前还会重新检查取消和 interrupt。 */
        private void cancelWorker() {
            synchronized (workerLifecycle) {
                cancelled = true;
                Thread current = worker;
                if (current != null && current.isAlive()) current.interrupt();
            }
        }

        /** 取消中的活 worker 不发布终态；tick/render 持续收口，停止后才给唯一结果。 */
        private void stopAndFinishFailure() {
            cancelWorker();
            cleanup();
            if (workerHasStopped()) publishResult(false);
        }

        /**
         * 已先通过安全 Hold 和 Knot 定义门；此处证明同线程 Add/Hold 即时生效，
         * 随后持有真实 HashMap iterator，短暂等待
         * worker 完成投递。等待期间客户端不会 drain；因此可确定观测“异线程仅排队”。
         * 原版队列在后续真实帧自然执行，guard 缺失会以直接执行/CME被记录为失败。
         */
        private void beginClientBatch() throws InterruptedException {
            final int number = ++batch;
            clientBatchDone = false;
            ordinaryDone = false;
            try {
                new AddTrainPacket(train).handle(listener);
                check(Create.RAILWAYS.trains.get(trainId) == train, "same_thread_add");
                AtomicInteger immediate = new AtomicInteger();
                new S2CHoldPacket("amcl_qa_inline", ignored -> immediate.incrementAndGet()).handle(listener);
                check(immediate.get() == 1, "same_thread_hold");
                Iterator<Train> iterator = Create.RAILWAYS.trains.values().iterator();
                int base = clientHolds.get();
                S2CHoldPacket repeated = new S2CHoldPacket("amcl_qa_repeated", ignored -> {
                    if (cancelled) return;
                    if (!check(minecraft.packetProcessor().isSameThread(), "client_thread")) return;
                    int position = clientHolds.getAndIncrement() - base;
                    check(Create.RAILWAYS.trains.get(trainId) == ((position & 1) == 0 ? null : train), "client_fifo:" + position);
                });
                startWorker("AMCL-Create-QA-client-" + number, () -> {
                    try {
                        // 普通任务先提交，包随后提交；真实客户端循环应先处理 packet 队列。
                        minecraft.execute(() -> {
                            check(clientBatchDone, "native_queue_before_ordinary:" + number);
                            ordinaryDone = true;
                        });
                        for (int index = 0; index < ROUNDS && failure.get() == null; index++) {
                            dispatch(new RemoveTrainPacket(trainId), listener);
                            dispatch(repeated, listener);
                            dispatch(new AddTrainPacket(train), listener);
                            dispatch(repeated, listener);
                        }
                        AtomicInteger bundleSteps = new AtomicInteger();
                        List<Packet<? super ClientGamePacketListener>> children = List.of(
                                new S2CHoldPacket("amcl_qa_bundle_first", ignored -> bundleSteps.incrementAndGet()),
                                new S2CHoldPacket("amcl_qa_bundle_last", ignored -> {
                                    try {
                                        check(minecraft.packetProcessor().isSameThread(), "bundle_thread");
                                        check(bundleSteps.get() == 1, "bundle_child_order");
                                        check(clientHolds.get() - base == ROUNDS * 2, "batch_count:" + number);
                                        // 空车厢 Train 只用于表结构测试，不能逃逸到真实渲染阶段。
                                        new RemoveTrainPacket(trainId).handle(listener);
                                    } finally {
                                        cleanup();
                                    }
                                    clientBatchDone = true;
                                }));
                        dispatch(new ClientboundBundlePacket(children), listener);
                    } catch (Throwable unexpected) {
                        fail("client_worker:" + unexpected);
                    }
                });
                awaitWorker("client_worker_timeout");
                // 至少有本测试 Train；next 检查构建 iterator 后的结构变更，不靠 hasNext。
                while (iterator.hasNext()) iterator.next();
                check(Create.RAILWAYS.trains.get(trainId) == train, "worker_did_not_mutate");
            } finally {
                // tick 返回后这一帧即可渲染。即使失败，也必须先撤走空车厢测试对象。
                cleanup();
            }
            emit("client_batch_submitted", Map.of("batch", number, "deferred", deferred.get()));
        }

        /**
         * 在真实集成服务器线程取当前玩家 listener。C2S Hold 的 callback 只改 QA
         * 计数，不调用清背包等真实业务；复用同一 packet 实例验证不按对象去重。
         */
        private void beginServer() {
            try {
                if (cancelled || failure.get() != null) return;
                ServerPlayer player = server.getPlayerList().getPlayer(playerId);
                if (!check(player != null && player.connection != null, "server_player")) return;
                ServerGamePacketListenerImpl target = player.connection;
                AtomicInteger immediate = new AtomicInteger();
                new C2SHoldPacket("amcl_qa_inline", ignored -> {
                    check(server.packetProcessor().isSameThread(), "server_inline_thread");
                    immediate.incrementAndGet();
                }).handle(target);
                check(immediate.get() == 1, "server_same_thread");
                C2SHoldPacket repeated = new C2SHoldPacket("amcl_qa_repeated", ignored -> {
                    if (cancelled) return;
                    if (check(server.packetProcessor().isSameThread(), "server_thread")) serverHolds.incrementAndGet();
                });
                startWorker("AMCL-Create-QA-server", () -> {
                    try {
                        for (int index = 0; index < SERVER_REPEATS && failure.get() == null; index++) dispatch(repeated, target);
                        dispatch(new C2SHoldPacket("amcl_qa_done", ignored -> {
                            check(server.packetProcessor().isSameThread(), "server_marker_thread");
                            check(serverHolds.get() == SERVER_REPEATS, "server_fifo_and_count");
                            serverDone = true;
                            emit("server_done", Map.of("serverHolds", serverHolds.get()));
                        }), target);
                    } catch (Throwable unexpected) {
                        fail("server_worker:" + unexpected);
                    }
                });
                awaitWorker("server_worker_timeout");
                check(serverHolds.get() == 0, "server_worker_did_not_execute");
            } catch (Throwable unexpected) {
                fail("server_setup:" + unexpected);
            }
        }

        /**
         * 每一次投递前重新检查取消/interrupt，不能只在外层循环检查；投递异常由
         * worker finally停止握手收口。只接住原版控制流，不改生产 queue 或手工 drain。
         */
        private <T extends PacketListener> void dispatch(Packet<T> packet, T target) {
            if (cancelled || failure.get() != null || Thread.currentThread().isInterrupted()) return;
            try {
                packet.handle(target);
                fail("worker_not_deferred:" + packet.getClass().getName());
            } catch (RunningOnDifferentThreadException expected) {
                deferred.incrementAndGet();
            }
        }

        /** 失败保持首因并写机器可读事件；不向真实业务/队列抛出异常。 */
        private boolean check(boolean condition, String message) {
            if (!condition) fail(message);
            return condition;
        }

        private void fail(String message) {
            if (failure.compareAndSet(null, message)) {
                cancelWorker();
                emit("failure", Map.of("message", message));
            }
        }

        /** 仅客户端线程调用；身份不符不删除其他对象，不清空实际铁路管理器。 */
        private void cleanup() {
            if (Create.RAILWAYS != null) Create.RAILWAYS.trains.remove(trainId, train);
        }

        /** 为普通事件和终态构造同一套机器字段，不在这里发布或写文件。 */
        private String recordLine(String event, Map<String, ?> details) {
            Map<String, Object> record = new LinkedHashMap<>();
            record.put("schema", 1);
            record.put("runId", run);
            record.put("time", Instant.now().toString());
            record.put("thread", Thread.currentThread().getName());
            record.put("event", event);
            record.putAll(details);
            return JSON.toJson(record);
        }

        /**
         * 普通事件先落 JSONL 再镜像 stdout；写入失败立即取消，只输出 evidence_error，
         * 由真实客户端 tick/render 在 worker 停止后发布唯一失败终态，不递归记录错误。
         */
        private synchronized boolean emit(String event, Map<String, ?> details) {
            if (finished) return false;
            String line = recordLine(event, details);
            try {
                Files.createDirectories(output.getParent());
                Files.writeString(output, line + "\n", StandardCharsets.UTF_8,
                        StandardOpenOption.CREATE, StandardOpenOption.APPEND);
                System.out.println("[AMCL Create Probe] " + line);
                return true;
            } catch (Exception problem) {
                failure.compareAndSet(null, "evidence_write:" + problem);
                cancelWorker();
                System.out.println("[AMCL Create Probe] " + recordLine("evidence_error",
                        Map.of("message", problem.toString())));
                return false;
            }
        }

        /**
         * 终态采用同目录临时文件 + ATOMIC_MOVE 替换完整 JSONL；成功记录在 move 返回
         * 前不会出现在公开 JSONL 或 stdout，不把 append 的部分写入当成成功。设备若
         * 不支持原子移动则失败关闭，不降级为会残留半条 passed=true 的非原子覆盖。
         */
        private void writeTerminal(String line) throws Exception {
            Files.createDirectories(output.getParent());
            Path pending = output.resolveSibling(".amcl-create-thread-probe-" + run + ".terminal.pending");
            try {
                String previous = Files.exists(output) ? Files.readString(output, StandardCharsets.UTF_8) : "";
                if (!previous.isEmpty() && !previous.endsWith("\n")) previous += "\n";
                Files.writeString(pending, previous + line + "\n", StandardCharsets.UTF_8,
                        StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE);
                Files.move(pending, output, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            } finally {
                // 只清理本 run 明确创建的单个临时文件，不递归清理 logs 或既有证据。
                try { Files.deleteIfExists(pending); } catch (Exception ignored) { /* 发布失败由调用者记录 */ }
            }
        }

        /**
         * 先核实 worker 真正结束和身份清理，再提交终态；提交失败只向可用 stdout
         * 发布 passed=false，不曾输出成功。失败终态也尝试原子落盘，磁盘仍不可用时
         * evidence=stdout_only 明确区分证据通道。整个 run 只发布一次 result。
         */
        private synchronized void publishResult(boolean requestedPass) {
            if (finished || !workerHasStopped()) return;
            cancelWorker();
            cleanup();
            boolean passed = requestedPass && failure.get() == null;
            Map<String, Object> details = new LinkedHashMap<>();
            details.put("passed", passed);
            details.put("batches", batch);
            details.put("postTicks", postTicks);
            details.put("deferred", deferred.get());
            details.put("clientHolds", clientHolds.get());
            details.put("serverHolds", serverHolds.get());
            details.put("actualKnot", knotVerified);
            details.put("trainAbsent", Create.RAILWAYS == null || Create.RAILWAYS.trains.get(trainId) != train);
            details.put("workerStopped", true);
            details.put("evidence", "jsonl_committed");
            if (!passed) details.put("failure", String.valueOf(failure.get()));
            String line = recordLine("result", details);
            try {
                writeTerminal(line);
            } catch (Exception problem) {
                String issue = "evidence_write:" + problem;
                failure.compareAndSet(null, issue);
                details.put("passed", false);
                details.put("failure", failure.get());
                details.put("evidence", "stdout_only");
                details.put("evidenceError", issue);
                line = recordLine("result", details);
                try {
                    writeTerminal(line);
                } catch (Exception unavailable) {
                    // stdout 的失败终态仍是可用证据；不重试发布成功或打印第二条 result。
                }
            }
            System.out.println("[AMCL Create Probe] " + line);
            finished = true;
        }
    }
}
