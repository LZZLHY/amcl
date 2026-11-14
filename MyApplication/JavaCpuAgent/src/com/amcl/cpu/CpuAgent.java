package com.amcl.cpu;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

/**
 * 鸿蒙 CPU 的生产兼容 Agent。Java 8 字节码，无游戏或加载器编译依赖。
 * premain 只冻结宿主事实并安装首次定义变换；绝不提前解析 OSHI 或更改游戏类加载拓扑。
 * ASM 在构建时重定位，注入的方法只调用 JDK/OSHI 类型，不依赖本类的可见性或身份。
 */
public final class CpuAgent {
    private CpuAgent() { }

    /** 无合法的宿主协议时不启用；可选信息采集失败不阻止 JVM 启动。 */
    public static void premain(String arguments, Instrumentation instrumentation) {
        try {
            Facts facts = Facts.read();
            instrumentation.addTransformer(new CpuTransformer(facts), false);
            System.setProperty("amcl.cpu.agent.status", "installed");
            System.setProperty("amcl.cpu.agent.logical", Integer.toString(facts.ids.length));
            System.setProperty("amcl.cpu.agent.logicalSource", facts.logicalSource);
        } catch (Throwable failure) {
            System.setProperty("amcl.cpu.agent.status", "unavailable:" + failure.getClass().getSimpleName());
            System.err.println("[AMCL-CPU] installation unavailable: " + failure);
        }
    }

    /** 一次 JVM 的不可变事实；-1 拓扑编号与 0 个物理对象明确表示未取得该信息。 */
    static final class Facts {
        final String model;
        final boolean cpu64;
        final int[] ids;
        final int[] cores;
        final int[] packages;
        final int physicalCount;
        final int packageCount;
        final String logicalSource;

        private Facts(String model, boolean cpu64, int[] ids, int[] cores, int[] packages,
                      int physicalCount, int packageCount, String logicalSource) {
            this.model = model; this.cpu64 = cpu64; this.ids = ids; this.cores = cores;
            this.packages = packages; this.physicalCount = physicalCount;
            this.packageCount = packageCount; this.logicalSource = logicalSource;
        }

        /** 验证长度、唯一性和完整拓扑，避免非法宿主参数形成可执行大方法或错误映射。 */
        static Facts read() {
            if (!"1".equals(System.getProperty("amcl.cpu.schema"))) throw new IllegalArgumentException("CPU schema");
            String model = System.getProperty("amcl.cpu.model", "").trim();
            if (model.length() > 128 || model.matches("(?s).*[\\p{Cntrl}].*")) throw new IllegalArgumentException("CPU model");
            if (model.isEmpty()) model = "unknown";
            String abi = System.getProperty("amcl.cpu.abi", System.getProperty("os.arch", ""));
            if (abi.isEmpty()) abi = System.getProperty("os.arch", "");
            String online = System.getProperty("amcl.cpu.online", "");
            int[] ids;
            String source;
            if (online.isEmpty()) {
                int count = Math.max(1, Math.min(1024, Runtime.getRuntime().availableProcessors()));
                ids = new int[count];
                for (int i = 0; i < count; i++) ids[i] = i;
                source = "jvm.availableProcessors";
            } else {
                ids = numbers(online);
                source = "sysfs.cpu.online";
            }
            int[] cores = new int[ids.length];
            int[] packages = new int[ids.length];
            java.util.Arrays.fill(cores, -1); java.util.Arrays.fill(packages, -1);
            String topology = System.getProperty("amcl.cpu.topology", "");
            Set<String> physical = new HashSet<String>();
            Set<Integer> sockets = new HashSet<Integer>();
            if (!topology.isEmpty()) {
                String[] rows = topology.split(";", -1);
                if (online.isEmpty() || rows.length != ids.length) throw new IllegalArgumentException("CPU topology count");
                for (int i = 0; i < rows.length; i++) {
                    String[] row = rows[i].split(",", -1);
                    if (row.length != 3 || number(row[0]) != ids[i]) throw new IllegalArgumentException("CPU topology order");
                    cores[i] = number(row[1]); packages[i] = number(row[2]);
                    physical.add(packages[i] + ":" + cores[i]); sockets.add(packages[i]);
                }
            }
            return new Facts(model, abi.contains("64"), ids, cores, packages, physical.size(), sockets.size(), source);
        }

        /** online 的启动协议是已展开且唯一的十进制 CPU 编号，不接受范围或负数。 */
        private static int[] numbers(String text) {
            String[] parts = text.split(",", -1);
            if (parts.length == 0 || parts.length > 1024) throw new IllegalArgumentException("CPU count");
            int[] result = new int[parts.length];
            Set<Integer> seen = new HashSet<Integer>();
            for (int i = 0; i < parts.length; i++) {
                result[i] = number(parts[i]);
                if (!seen.add(result[i])) throw new IllegalArgumentException("duplicate CPU");
            }
            return result;
        }

        /** 仅接受可界定的小型内核编号；异常不被吞掉成为部分可信的数据。 */
        private static int number(String text) {
            if (!text.matches("[0-9]{1,5}")) throw new IllegalArgumentException("CPU number");
            int value = Integer.parseInt(text);
            if (value > 65535) throw new IllegalArgumentException("CPU number range");
            return value;
        }
    }

    /**
     * 按确切类名和方法描述符选择受支持 ABI。所有替换都在同一 class 字节事务中生成；
     * 任一形状或生成失败返回原字节，由原库决定回退，不能交付半份 class 修改。
     */
    static final class CpuTransformer implements ClassFileTransformer, Opcodes {
        private static final String MODERN = "oshi/hardware/platform/linux/LinuxCentralProcessor";
        private static final String BASE = "oshi/hardware/common/AbstractCentralProcessor";
        private static final String LEGACY_HAL = "oshi/software/os/linux/LinuxHardwareAbstractionLayer";
        private static final String LEGACY_CPU = "oshi/software/os/linux/proc/CentralProcessor";
        private static final String LOGICAL = "oshi/hardware/CentralProcessor$LogicalProcessor";
        private static final String IDENTIFIER = "oshi/hardware/CentralProcessor$ProcessorIdentifier";
        private static final String IDENTIFIER_DESC = "()L" + IDENTIFIER + ";";
        private static final String IDENTIFIER_CTOR = "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;"
                + "Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;ZJ)V";
        private final Facts facts;
        private final AtomicInteger adapted = new AtomicInteger();

        CpuTransformer(Facts facts) { this.facts = facts; }

        /** 首次定义回调不调用 Class.forName，允许 Forge 模块层和 Fabric 子加载器独立拥有 OSHI。 */
        @Override
        public byte[] transform(ClassLoader loader, String name, Class<?> redefined,
                                ProtectionDomain domain, byte[] bytes) {
            if (redefined != null || (!MODERN.equals(name) && !BASE.equals(name)
                    && !LEGACY_HAL.equals(name))) return null;
            try {
                final Set<String> methods = new HashSet<String>();
                final ClassReader reader = new ClassReader(bytes);
                reader.accept(new ClassVisitor(ASM9) {
                    @Override public MethodVisitor visitMethod(int access, String method, String desc,
                                                               String signature, String[] exceptions) {
                        methods.add(method + desc); return null;
                    }
                }, ClassReader.SKIP_CODE | ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
                if (MODERN.equals(name) && (!methods.contains("queryProcessorId" + IDENTIFIER_DESC)
                        || topologyDescriptor(methods) == null)) return null;
                if (LEGACY_HAL.equals(name) && !methods.contains("getProcessors()[Loshi/hardware/Processor;")) return null;
                final ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_FRAMES | ClassWriter.COMPUTE_MAXS);
                final String target = name;
                final boolean legacyIntConstructor = LEGACY_HAL.equals(name) && hasIntConstructor(loader);
                final int[] changes = {0};
                reader.accept(new ClassVisitor(ASM9, writer) {
                    @Override public MethodVisitor visitMethod(int access, String method, String desc,
                                                               String signature, String[] exceptions) {
                        MethodVisitor mv = super.visitMethod(access, method, desc, signature, exceptions);
                        if (MODERN.equals(target) && "initProcessorCounts".equals(method)
                                && desc.equals(topologyDescriptor(methods))) {
                            topology(mv, desc); changes[0]++; return null;
                        }
                        if (MODERN.equals(target) && "queryProcessorId".equals(method) && IDENTIFIER_DESC.equals(desc)) {
                            identifier(mv); changes[0]++; return null;
                        }
                        if (BASE.equals(target) && "()I".equals(desc)
                                && ("getPhysicalProcessorCount".equals(method) || "getPhysicalPackageCount".equals(method))) {
                            mv.visitCode(); integer(mv, "getPhysicalProcessorCount".equals(method)
                                    ? facts.physicalCount : facts.packageCount);
                            mv.visitInsn(IRETURN); end(mv); changes[0]++; return null;
                        }
                        if (BASE.equals(target) && facts.physicalCount == 0 && "getPhysicalProcessors".equals(method)
                                && "()Ljava/util/List;".equals(desc)) {
                            // 基类会从逻辑列表推导物理对象；未知拓扑时不公开那个合成占位对象。
                            mv.visitCode(); mv.visitMethodInsn(INVOKESTATIC, "java/util/Collections", "emptyList", "()Ljava/util/List;", false);
                            mv.visitInsn(ARETURN); end(mv); changes[0]++; return null;
                        }
                        if (LEGACY_HAL.equals(target) && "getProcessors".equals(method)
                                && "()[Loshi/hardware/Processor;".equals(desc)) {
                            legacy(mv, legacyIntConstructor); changes[0]++; return null;
                        }
                        return mv;
                    }
                }, 0);
                if (changes[0] == 0) return null;
                byte[] result = writer.toByteArray();
                int count = adapted.incrementAndGet();
                System.setProperty("amcl.cpu.agent.adapted", Integer.toString(count));
                System.err.println("[AMCL-CPU] adapted=" + count + " class=" + name + " methods=" + changes[0]
                        + " model=" + facts.model + " logical=" + facts.ids.length + " physical=" + facts.physicalCount
                        + " source=" + facts.logicalSource + " loader=" + (loader == null ? "bootstrap" : loader.getClass().getName()));
                return result;
            } catch (Throwable failure) {
                System.err.println("[AMCL-CPU] unsupported class=" + name + " reason=" + failure);
                return null;
            }
        }

        /** 初始化返回形状随 OSHI 世代变化；显式白名单避免误把未知类型当 Pair。 */
        private static String topologyDescriptor(Set<String> methods) {
            for (String type : new String[]{"java/util/List", "oshi/util/tuples/Pair", "oshi/util/tuples/Triplet", "oshi/util/tuples/Quartet"}) {
                String desc = "()L" + type + ";";
                if (methods.contains("initProcessorCounts" + desc)) return desc;
            }
            return null;
        }

        /** 仅读目标资源判定旧 CPU 构造器，不定义类；读取失败仍可使用 OSHI 1.1 的默认构造器。 */
        private static boolean hasIntConstructor(ClassLoader loader) throws Exception {
            InputStream input = loader == null ? null : loader.getResourceAsStream(LEGACY_CPU + ".class");
            if (input == null) return false;
            try {
                ByteArrayOutputStream data = new ByteArrayOutputStream();
                byte[] chunk = new byte[4096]; int length;
                while ((length = input.read(chunk)) != -1) data.write(chunk, 0, length);
                final boolean[] found = {false};
                new ClassReader(data.toByteArray()).accept(new ClassVisitor(ASM9) {
                    @Override public MethodVisitor visitMethod(int access, String name, String desc,
                                                               String signature, String[] exceptions) {
                        if ("<init>".equals(name) && "(I)V".equals(desc)) found[0] = true;
                        return null;
                    }
                }, ClassReader.SKIP_CODE | ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
                return found[0];
            } finally { input.close(); }
        }

        /** 用真实逻辑编号和可选真实物理映射构造列表；缺少拓扑时编号为 -1 并独立返回未知物理数量。 */
        private void topology(MethodVisitor mv, String descriptor) {
            mv.visitCode(); mv.visitTypeInsn(NEW, "java/util/ArrayList"); mv.visitInsn(DUP);
            mv.visitMethodInsn(INVOKESPECIAL, "java/util/ArrayList", "<init>", "()V", false);
            mv.visitVarInsn(ASTORE, 1);
            for (int i = 0; i < facts.ids.length; i++) {
                mv.visitVarInsn(ALOAD, 1); mv.visitTypeInsn(NEW, LOGICAL); mv.visitInsn(DUP);
                integer(mv, facts.ids[i]); integer(mv, facts.cores[i]); integer(mv, facts.packages[i]);
                mv.visitMethodInsn(INVOKESPECIAL, LOGICAL, "<init>", "(III)V", false);
                mv.visitMethodInsn(INVOKEINTERFACE, "java/util/List", "add", "(Ljava/lang/Object;)Z", true); mv.visitInsn(POP);
            }
            String type = descriptor.substring(3, descriptor.length() - 1);
            if ("java/util/List".equals(type)) mv.visitVarInsn(ALOAD, 1);
            else {
                mv.visitTypeInsn(NEW, type); mv.visitInsn(DUP); mv.visitVarInsn(ALOAD, 1); mv.visitInsn(ACONST_NULL);
                String ctor = "(Ljava/lang/Object;Ljava/lang/Object;";
                if (type.endsWith("Triplet") || type.endsWith("Quartet")) { mv.visitInsn(ACONST_NULL); ctor += "Ljava/lang/Object;"; }
                if (type.endsWith("Quartet")) {
                    mv.visitMethodInsn(INVOKESTATIC, "java/util/Collections", "emptyList", "()Ljava/util/List;", false);
                    ctor += "Ljava/lang/Object;";
                }
                mv.visitMethodInsn(INVOKESPECIAL, type, "<init>", ctor + ")V", false);
            }
            mv.visitInsn(ARETURN); end(mv);
        }

        /** 直接建立 OSHI 标准标识对象；未知厂商/型号细分/频率留空或 -1，不猜测硬件能力。 */
        private void identifier(MethodVisitor mv) {
            mv.visitCode(); mv.visitTypeInsn(NEW, IDENTIFIER); mv.visitInsn(DUP);
            mv.visitLdcInsn(""); mv.visitLdcInsn(facts.model);
            for (int i = 0; i < 4; i++) mv.visitLdcInsn("");
            mv.visitInsn(facts.cpu64 ? ICONST_1 : ICONST_0); mv.visitLdcInsn(-1L);
            mv.visitMethodInsn(INVOKESPECIAL, IDENTIFIER, "<init>", IDENTIFIER_CTOR, false);
            mv.visitInsn(ARETURN); end(mv);
        }

        /** OSHI 1.x 的数组接口由宿主逻辑 CPU 列表构建，每个对象通过旧库的公开 setter 设置事实。 */
        private void legacy(MethodVisitor mv, boolean intConstructor) {
            mv.visitCode(); integer(mv, facts.ids.length); mv.visitTypeInsn(ANEWARRAY, "oshi/hardware/Processor");
            mv.visitVarInsn(ASTORE, 1);
            for (int i = 0; i < facts.ids.length; i++) {
                mv.visitTypeInsn(NEW, LEGACY_CPU); mv.visitInsn(DUP);
                if (intConstructor) integer(mv, facts.ids[i]);
                mv.visitMethodInsn(INVOKESPECIAL, LEGACY_CPU, "<init>", intConstructor ? "(I)V" : "()V", false);
                mv.visitVarInsn(ASTORE, 2); mv.visitVarInsn(ALOAD, 2); mv.visitLdcInsn(facts.model);
                mv.visitMethodInsn(INVOKEVIRTUAL, LEGACY_CPU, "setName", "(Ljava/lang/String;)V", false);
                mv.visitVarInsn(ALOAD, 2); mv.visitInsn(facts.cpu64 ? ICONST_1 : ICONST_0);
                mv.visitMethodInsn(INVOKEVIRTUAL, LEGACY_CPU, "setCpu64", "(Z)V", false);
                mv.visitVarInsn(ALOAD, 1); integer(mv, i); mv.visitVarInsn(ALOAD, 2); mv.visitInsn(AASTORE);
            }
            mv.visitVarInsn(ALOAD, 1); mv.visitInsn(ARETURN); end(mv);
        }

        /** 交给 ASM 计算 maxStack/frames，避免手工偏移随 CPU 数变化产生无效字节码。 */
        private static void end(MethodVisitor mv) { mv.visitMaxs(0, 0); mv.visitEnd(); }

        /** CPU 编号不限定于小常量，统一由常量池承载并由 ASM 选择合法 ldc 编码。 */
        private static void integer(MethodVisitor mv, int value) { mv.visitLdcInsn(value); }
    }
}
