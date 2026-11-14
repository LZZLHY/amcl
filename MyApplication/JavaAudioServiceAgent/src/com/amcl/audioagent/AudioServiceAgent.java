package com.amcl.audioagent;

import java.io.InputStream;
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.MessageDigest;
import java.security.ProtectionDomain;
import java.util.HashMap;
import java.util.Map;
import java.util.Properties;
import java.util.concurrent.atomic.AtomicInteger;
import org.objectweb.asm.*;

/**
 * Java Sound 服务资源与提供器类身份的限定加载器适配，只处理已核版本的首次类定义。
 * BOOT 的默认 Platform fallback 与 GAME 的 BOOT fallback 均不能解析启动器的未命名模块，
 * 因此服务描述可见后，还须让确切的 AMCL 音频类回到系统 canonical owner。
 * 不重写 JDK 或游戏业务类，不改变其他类的原加载顺序。
 * ASM 构建时重定位；目标方法只注入 JDK 类型，模块层无需解析本 Agent 或复制启动器 JNI 声明类。
 */
public final class AudioServiceAgent {
    private static final String TARGET = "cpw/mods/cl/ModuleClassLoader";
    private static final String SERVICE = "META-INF/services/javax.sound.sampled.spi.MixerProvider";
    private static final String DESCRIPTOR = "(Ljava/lang/String;)Ljava/util/Enumeration;";
    private static final String LOAD_DESCRIPTOR = "(Ljava/lang/String;Z)Ljava/lang/Class;";
    // 仅冻结生产音频源集中的九个顶层类及其 $ 内部类；不是 com.amcl.audio.* 包通配。
    // 新增顶层生产类时须显式审查这里的 owner 契约，避免把模组同包自有类也抢到系统域。
    private static final String[] AUDIO_CLASSES = {
        "com.amcl.audio.AudioBackend", "com.amcl.audio.AudioFormats", "com.amcl.audio.OhosAudioNative",
        "com.amcl.audio.OhosClip", "com.amcl.audio.OhosDataLine", "com.amcl.audio.OhosMixer",
        "com.amcl.audio.OhosMixerProvider", "com.amcl.audio.OhosSourceDataLine", "com.amcl.audio.OhosTargetDataLine"
    };
    private static boolean installed;
    private AudioServiceAgent() { }

    /**
     * 两个早读值由本局启动计划冻结。关闭音频或未知 schema 时保持原加载行为。
     * 已定义目标类不做 retransformation；晚装必须具名报告，而不能声称已接通服务。
     */
    public static synchronized void premain(String arguments, Instrumentation instrumentation) {
        if (!"1".equals(System.getProperty("amcl.audio.service.schema"))
            || !"true".equals(System.getProperty("amcl.audio.enabled"))) {
            System.setProperty("amcl.audio.service.agent.status", "disabled"); return;
        }
        if (installed) {
            System.err.println("[AMCL-AUDIO-SPI] already-installed"); return;
        }
        try {
            for (Class<?> loaded : instrumentation.getAllLoadedClasses()) {
                if (TARGET.replace('/', '.').equals(loaded.getName())) {
                    System.setProperty("amcl.audio.service.agent.status", "late-definition");
                    System.err.println("[AMCL-AUDIO-SPI] not-covered reason=late-definition class=" + TARGET); return;
                }
            }
            instrumentation.addTransformer(new ServiceTransformer(profiles()), false);
            installed = true;
            System.setProperty("amcl.audio.service.agent.status", "installed");
        } catch (Throwable failure) {
            System.setProperty("amcl.audio.service.agent.status", "unavailable:" + failure.getClass().getSimpleName());
            System.err.println("[AMCL-AUDIO-SPI] installation-unavailable reason=" + failure);
        }
    }

    /** 只读当前 Agent JAR 自有的构建资源；不信任 TCCL 上的同名文件或远端运行策略。 */
    private static Map<String, String> profiles() throws Exception {
        Properties properties = new Properties();
        try (InputStream stream = AudioServiceAgent.class.getResourceAsStream("supported-loaders.properties")) {
            if (stream == null) throw new IllegalStateException("loader profiles missing");
            properties.load(stream);
        }
        if (!"1".equals(properties.getProperty("schema")) || !SERVICE.equals(properties.getProperty("service")))
            throw new IllegalStateException("loader profile schema");
        Map<String, String> profiles = new HashMap<String, String>();
        for (String key : properties.stringPropertyNames()) {
            if (!key.startsWith("sha256.")) continue;
            String hash = key.substring(7), id = properties.getProperty(key);
            if (!hash.matches("[0-9a-f]{64}") || !id.matches("[a-zA-Z0-9._-]{1,96}"))
                throw new IllegalStateException("loader profile identity");
            profiles.put(hash, id);
        }
        if (profiles.isEmpty()) throw new IllegalStateException("loader profiles empty");
        return profiles;
    }

    /** 完整类摘要限制到实际审阅过的原始实现，不能把同名新版本当作同一 ABI。 */
    private static String sha256(byte[] bytes) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
        StringBuilder text = new StringBuilder(64);
        for (byte value : digest) text.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
        return text.toString();
    }

    /** 全部改写是单个 class 字节事务；任何身份或方法形状不匹配均返回原字节。 */
    static final class ServiceTransformer implements ClassFileTransformer, Opcodes {
        private final Map<String, String> profiles;
        private final AtomicInteger transformed = new AtomicInteger();
        ServiceTransformer(Map<String, String> profiles) { this.profiles = profiles; }

        @Override public byte[] transform(ClassLoader loader, String name, Class<?> redefined,
                                           ProtectionDomain domain, byte[] bytes) {
            if (!TARGET.equals(name)) return null;
            if (redefined != null) {
                System.setProperty("amcl.audio.service.agent.status", "not-covered:redefinition");
                System.err.println("[AMCL-AUDIO-SPI] not-covered class=" + name + " reason=redefinition"); return null;
            }
            try {
                String hash = sha256(bytes), profile = profiles.get(hash);
                if (profile == null) {
                    System.setProperty("amcl.audio.service.agent.status", "not-covered:class-sha256");
                    System.err.println("[AMCL-AUDIO-SPI] not-covered class=" + name + " sha256=" + hash); return null;
                }
                ClassReader reader = new ClassReader(bytes);
                final int[] methods = {0}, returns = {0}, classMethods = {0};
                ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_FRAMES | ClassWriter.COMPUTE_MAXS);
                reader.accept(new ClassVisitor(ASM9, writer) {
                    @Override public MethodVisitor visitMethod(int access, String method, String descriptor,
                                                               String signature, String[] exceptions) {
                        MethodVisitor original = super.visitMethod(access, method, descriptor, signature, exceptions);
                        if ("loadClass".equals(method) && LOAD_DESCRIPTOR.equals(descriptor)) {
                            if (access != ACC_PROTECTED) throw new IllegalStateException("loadClass access");
                            classMethods[0]++;
                            return new MethodVisitor(ASM9, original) {
                                @Override public void visitCode() {
                                    super.visitCode(); delegateAudioClass(original);
                                }
                            };
                        }
                        if (!"getResources".equals(method) || !DESCRIPTOR.equals(descriptor)) return original;
                        if (access != ACC_PUBLIC) throw new IllegalStateException("getResources access");
                        methods[0]++;
                        return new MethodVisitor(ASM9, original) {
                            @Override public void visitInsn(int opcode) {
                                if (opcode == ARETURN) { returns[0]++; merge(original); }
                                super.visitInsn(opcode);
                            }
                        };
                    }
                }, ClassReader.EXPAND_FRAMES);
                if (methods[0] != 1 || returns[0] != 1 || classMethods[0] != 1)
                    throw new IllegalStateException("getResources/loadClass shape");
                byte[] result = writer.toByteArray();
                // prepared 仅表示生成了变换字节，不冒充 JVM 验证、SPI 调用或设备验收成功。
                int count = transformed.incrementAndGet();
                System.setProperty("amcl.audio.service.agent.transformed", Integer.toString(count));
                System.setProperty("amcl.audio.service.agent.status", "prepared:" + profile);
                System.err.println("[AMCL-AUDIO-SPI] prepared class=" + name + " profile=" + profile
                    + " count=" + count + " bridges=resources,canonical-audio-classes");
                return result;
            } catch (Throwable failure) {
                System.setProperty("amcl.audio.service.agent.status", "not-covered:transform-failed");
                System.err.println("[AMCL-AUDIO-SPI] not-covered class=" + name + " reason=" + failure); return null;
            }
        }

        /**
         * 在原 loadClass 取得自身类锁以前，仅为已知音频类或其 $ 内部类返回系统 owner 的 Class。
         * 该入口使用 Class.forName(name, false, system)，加载/链接但不初始化；resolve=true 也不会
         * 为目标域复制类或提前运行静态初始化。系统域定义锁仍负责并发首次定义和唯一 Class 身份。
         * 命中类若在系统域缺失，保留可见的 ClassNotFoundException，不回落 GAME 创建第二个 owner。
         * 未命中名称、无系统 owner 或 system==this 时，原 loadClass 的指令和异常路径继续执行。
         */
        private static void delegateAudioClass(MethodVisitor mv) {
            Label selected = new Label(), original = new Label();
            for (String name : AUDIO_CLASSES) {
                mv.visitLdcInsn(name); mv.visitVarInsn(ALOAD, 1);
                mv.visitMethodInsn(INVOKEVIRTUAL, "java/lang/String", "equals", "(Ljava/lang/Object;)Z", false);
                mv.visitJumpInsn(IFNE, selected);
                mv.visitVarInsn(ALOAD, 1); mv.visitLdcInsn(name + "$");
                mv.visitMethodInsn(INVOKEVIRTUAL, "java/lang/String", "startsWith", "(Ljava/lang/String;)Z", false);
                mv.visitJumpInsn(IFNE, selected);
            }
            mv.visitJumpInsn(GOTO, original); mv.visitLabel(selected);
            mv.visitMethodInsn(INVOKESTATIC, "java/lang/ClassLoader", "getSystemClassLoader", "()Ljava/lang/ClassLoader;", false);
            mv.visitVarInsn(ASTORE, 3); mv.visitVarInsn(ALOAD, 3); mv.visitJumpInsn(IFNULL, original);
            mv.visitVarInsn(ALOAD, 3); mv.visitVarInsn(ALOAD, 0); mv.visitJumpInsn(IF_ACMPEQ, original);
            mv.visitVarInsn(ALOAD, 1); mv.visitInsn(ICONST_0); mv.visitVarInsn(ALOAD, 3);
            mv.visitMethodInsn(INVOKESTATIC, "java/lang/Class", "forName",
                "(Ljava/lang/String;ZLjava/lang/ClassLoader;)Ljava/lang/Class;", false);
            mv.visitInsn(ARETURN); mv.visitLabel(original);
        }

        /**
         * 保留原方法计算的枚举；只对一个平台服务附加父域资源，原 URL 优先且按 externalForm 去重。
         * 系统 owner 与当前目标相同、无系统 owner、权限拒绝或父枚举 IO 失败时原样返回旧枚举。
         * 父枚举必须在消费旧枚举之前取得，异常回退才不会把已消费的空枚举交还调用者。
         */
        private static void merge(MethodVisitor mv) {
            Label original = new Label(), parent = new Label(), guarded = new Label(), obtained = new Label(), failed = new Label();
            Label ownLoop = new Label(), ownEnd = new Label(), parentLoop = new Label(), parentEnd = new Label();
            mv.visitVarInsn(ASTORE, 2);
            mv.visitLdcInsn(SERVICE); mv.visitVarInsn(ALOAD, 1);
            mv.visitMethodInsn(INVOKEVIRTUAL, "java/lang/String", "equals", "(Ljava/lang/Object;)Z", false);
            mv.visitJumpInsn(IFEQ, original);
            mv.visitTryCatchBlock(guarded, obtained, failed, "java/io/IOException");
            mv.visitTryCatchBlock(guarded, obtained, failed, "java/lang/SecurityException");
            mv.visitLabel(guarded);
            mv.visitMethodInsn(INVOKESTATIC, "java/lang/ClassLoader", "getSystemClassLoader", "()Ljava/lang/ClassLoader;", false);
            mv.visitVarInsn(ASTORE, 3); mv.visitVarInsn(ALOAD, 3); mv.visitJumpInsn(IFNULL, original);
            mv.visitVarInsn(ALOAD, 3); mv.visitVarInsn(ALOAD, 0); mv.visitJumpInsn(IF_ACMPEQ, original);
            mv.visitVarInsn(ALOAD, 3); mv.visitVarInsn(ALOAD, 1);
            mv.visitMethodInsn(INVOKEVIRTUAL, "java/lang/ClassLoader", "getResources", DESCRIPTOR, false);
            mv.visitVarInsn(ASTORE, 4); mv.visitLabel(obtained); mv.visitJumpInsn(GOTO, parent);
            mv.visitLabel(failed); mv.visitInsn(POP); mv.visitJumpInsn(GOTO, original);
            mv.visitLabel(parent);
            mv.visitTypeInsn(NEW, "java/util/LinkedHashMap"); mv.visitInsn(DUP);
            mv.visitMethodInsn(INVOKESPECIAL, "java/util/LinkedHashMap", "<init>", "()V", false); mv.visitVarInsn(ASTORE, 5);
            appendEnumeration(mv, 2, ownLoop, ownEnd);
            appendEnumeration(mv, 4, parentLoop, parentEnd);
            mv.visitVarInsn(ALOAD, 5);
            mv.visitMethodInsn(INVOKEVIRTUAL, "java/util/LinkedHashMap", "values", "()Ljava/util/Collection;", false);
            mv.visitMethodInsn(INVOKESTATIC, "java/util/Collections", "enumeration", "(Ljava/util/Collection;)Ljava/util/Enumeration;", false);
            mv.visitInsn(ARETURN);
            mv.visitLabel(original); mv.visitVarInsn(ALOAD, 2);
        }

        /** 两个枚举共用相同有界局部变量，先放原结果、再放父结果，重复 URL 不改变首次位置。 */
        private static void appendEnumeration(MethodVisitor mv, int enumeration, Label loop, Label end) {
            mv.visitLabel(loop); mv.visitVarInsn(ALOAD, enumeration);
            mv.visitMethodInsn(INVOKEINTERFACE, "java/util/Enumeration", "hasMoreElements", "()Z", true);
            mv.visitJumpInsn(IFEQ, end); mv.visitVarInsn(ALOAD, enumeration);
            mv.visitMethodInsn(INVOKEINTERFACE, "java/util/Enumeration", "nextElement", "()Ljava/lang/Object;", true);
            mv.visitTypeInsn(CHECKCAST, "java/net/URL"); mv.visitVarInsn(ASTORE, 6);
            mv.visitVarInsn(ALOAD, 5); mv.visitVarInsn(ALOAD, 6);
            mv.visitMethodInsn(INVOKEVIRTUAL, "java/net/URL", "toExternalForm", "()Ljava/lang/String;", false);
            mv.visitVarInsn(ALOAD, 6);
            mv.visitMethodInsn(INVOKEVIRTUAL, "java/util/LinkedHashMap", "putIfAbsent", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;", false);
            mv.visitInsn(POP); mv.visitJumpInsn(GOTO, loop); mv.visitLabel(end);
        }
    }
}
