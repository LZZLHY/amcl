package com.amcl.gamepad;

import java.io.File;
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.MessageDigest;
import java.security.ProtectionDomain;
import java.util.concurrent.atomic.AtomicInteger;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Label;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

/** 在游戏加载器首次定义已核实的绑定时，将它选定的 SDL2 库指向本 HAP。 */
public final class Sdl2NativeLoader implements ClassFileTransformer {
    private static final String SDL_GDX = "org/libsdl/SDL";
    private static final String JAMEPAD = "com/studiohartman/jamepad/ControllerManager";
    private static final String JNA = "com/mrcrayfish/controllable_sdl/jna/SdlNativeLibraryLoader";
    private static final String NATIVE_LIB = "com/sun/jna/NativeLibrary";
    // AMCL 六代已核 JNA 的私有查找方法有 List / Collection 两种签名；匹配绑定类而非模组。
    private static final String[] JNA_LOOKUPS = {
        "2750946bb9507d6174804b732ab8be82f9753a3e91b937a3d061de159f182acd",
        "3e7bffe76de2fc9858147a05339560555e7510f6bc8d446f6a9f0f8ce79c361c",
        "7e7aa922cfc772b7fb919326a1e733bbc26fc3cd1a676781e29814e64898454e",
        "ef46a20938e35e57478090eae2bbd85a952cc2fcf29d8a755f18140b3e965c96",
        "7ef332f2261dc71cc9c50ab9778ed7855dac27c24e2dffcf20257d6f7f38aa2f",
        "74eef7400f007fabef14cd50f5ea26993c6a7ce82e2dc9ee20dfea4bb72fef32"
    };
    private static final String JNI_LOADER = "com/badlogic/gdx/jnigen/JniGenSharedLibraryLoader";
    // 只接受原 JAR 或 Forge 14.23.5.2860 的 Side/DeobfuscationTransformer 实际定义字节。
    // 后者重排常量池；仍核整个类摘要和下方原装载调用，绝不重放覆盖其他变换。
    private static final String[] SDL_GDX_CLASSES = {
        "59c428e354b136520ef214a3c814db01b65c7d53838aa70a329b4b99c05d9fb4",
        "3884d9bb92011bcc4c1864963c24ea699550fd100a2d96ea913f6dd321deb0c6"
    };
    private final AtomicInteger rejected = new AtomicInteger();
    private final File nativeDir;

    private Sdl2NativeLoader(File nativeDir) { this.nativeDir = nativeDir; }

    /** 路径在 premain 由宿主冻结，只接手游戏 JVM，和 CPU 采集分开。 */
    public static void install(Instrumentation instrumentation) {
        String path = System.getProperty("amcl.gamepad.sdl2.dir", "");
        File directory = new File(path);
        if (directory.isAbsolute() && directory.isDirectory()) {
            instrumentation.addTransformer(new Sdl2NativeLoader(directory), false);
        }
    }

    @Override
    public byte[] transform(ClassLoader loader, String owner, Class<?> redefining, ProtectionDomain domain, byte[] bytes) {
        if (loader == null || redefining != null) return null;
        String library;
        String[] expected;
        if (SDL_GDX.equals(owner)) {
            library = "libsdl2gdx.so";
            expected = SDL_GDX_CLASSES;
        } else if (JAMEPAD.equals(owner)) {
            library = "libjamepad.so";
            expected = new String[]{"302ea563f950bd961ea7fe3fe2cc1a87b618277f166f42ab804ec7a905f09589"};
        } else if (JNA.equals(owner)) {
            library = "libSDL2.so";
            expected = new String[]{"ed083af84896ae966a8eab02daf29ee0f9d6806d9cb1adcc8ef67526f862b272"};
        } else if (NATIVE_LIB.equals(owner)) {
            library = "libSDL2.so";
            expected = JNA_LOOKUPS;
        } else {
            return null;
        }
        try {
            String identity = sha256(bytes);
            File file = new File(nativeDir, library);
            if (!java.util.Arrays.asList(expected).contains(identity) || !file.isFile()) {
                return reject(owner, loader, domain, identity, file.isFile() ? "unrecognized-class" : "provider-missing");
            }
            ClassReader original = new ClassReader(bytes);
            ClassWriter writer = new ClassWriter(original, 0);
            Redirect redirect = new Redirect(writer, owner, file.getAbsolutePath());
            original.accept(redirect, 0);
            if (redirect.changes != (JNA.equals(owner) ? 2 : 1))
                return reject(owner, loader, domain, identity, "load-site-mismatch");
            System.err.println("[AMCL] SDL2 binding " + owner + " -> " + library);
            return writer.toByteArray();
        } catch (Exception e) {
            return reject(owner, loader, domain, "", e.getClass().getSimpleName());
        }
    }

    /** 拒绝只记录已知目标与来源协议，避免泄露本机路径；同一游戏进程的输出有界。 */
    private byte[] reject(String owner, ClassLoader loader, ProtectionDomain domain, String identity, String reason) {
        if (rejected.getAndIncrement() < 8) {
            String origin = domain == null || domain.getCodeSource() == null || domain.getCodeSource().getLocation() == null
                ? "unknown" : domain.getCodeSource().getLocation().getProtocol();
            System.err.println("[AMCL] SDL2 binding skipped target=" + owner + " loader=" + loader.getClass().getName()
                + " origin=" + origin + " sha256=" + identity + " reason=" + reason);
        }
        return null;
    }

    /** 只为已登记的目标类计算完整的首次定义字节摘要。 */
    private static String sha256(byte[] bytes) throws Exception {
        byte[] sha = MessageDigest.getInstance("SHA-256").digest(bytes);
        StringBuilder hex = new StringBuilder(64);
        for (byte octet : sha) {
            hex.append(Character.forDigit((octet & 255) >>> 4,16));
            hex.append(Character.forDigit(octet & 15,16));
        }
        return hex.toString();
    }

    private static final class Redirect extends ClassVisitor {
        private final String owner, path;
        int changes;

        Redirect(ClassVisitor target, String owner, String path) {
            super(Opcodes.ASM9, target);
            this.owner = owner;
            this.path = path;
        }

        @Override
        public MethodVisitor visitMethod(int access, String name, String desc, String signature, String[] exceptions) {
            MethodVisitor out = super.visitMethod(access, name, desc, signature, exceptions);
            if (NATIVE_LIB.equals(owner) && "findLibraryPath".equals(name)
                && (desc.equals("(Ljava/lang/String;Ljava/util/Collection;)Ljava/lang/String;")
                    || desc.equals("(Ljava/lang/String;Ljava/util/List;)Ljava/lang/String;"))) {
                changes++;
                return new MethodVisitor(Opcodes.ASM9, out) {
                    @Override public void visitCode() {
                        super.visitCode();
                        Label originalLookup = new Label();
                        super.visitLdcInsn("SDL2");
                        super.visitVarInsn(Opcodes.ALOAD,0);
                        super.visitMethodInsn(Opcodes.INVOKEVIRTUAL,"java/lang/String","equals","(Ljava/lang/Object;)Z",false);
                        super.visitJumpInsn(Opcodes.IFEQ,originalLookup);
                        // 保留 JNA 全部查找顺序和显式值；只为这次 SDL2 查找添加最后一个候补目录。
                        super.visitTypeInsn(Opcodes.NEW,"java/util/ArrayList");
                        super.visitInsn(Opcodes.DUP);
                        super.visitVarInsn(Opcodes.ALOAD,1);
                        super.visitMethodInsn(Opcodes.INVOKESPECIAL,"java/util/ArrayList","<init>","(Ljava/util/Collection;)V",false);
                        super.visitInsn(Opcodes.DUP);
                        super.visitLdcInsn(new File(path).getParent());
                        super.visitMethodInsn(Opcodes.INVOKEVIRTUAL,"java/util/ArrayList","add","(Ljava/lang/Object;)Z",false);
                        super.visitInsn(Opcodes.POP);
                        super.visitVarInsn(Opcodes.ASTORE,1);
                        super.visitLabel(originalLookup);
                        super.visitFrame(Opcodes.F_SAME,0,null,0,null);
                    }
                    @Override public void visitMaxs(int stack, int locals) { super.visitMaxs(Math.max(3,stack),locals); }
                };
            }
            if (JNA.equals(owner)) {
                if ("loadSDL2NativeFromEmbeddedResources".equals(name) && "()V".equals(desc)) {
                    // 原模组的两个同步公共入口共享同一缓存；保留其 JNA options 和实际游戏 classloader。
                    out.visitCode();
                    Label loaded = new Label();
                    out.visitFieldInsn(Opcodes.GETSTATIC, owner, "sdl2Library", "L" + NATIVE_LIB + ";");
                    out.visitJumpInsn(Opcodes.IFNONNULL, loaded);
                    out.visitLdcInsn(path);
                    out.visitMethodInsn(Opcodes.INVOKESTATIC, owner, "createOptions", "()Ljava/util/Map;", false);
                    out.visitMethodInsn(Opcodes.INVOKESTATIC, NATIVE_LIB, "getInstance",
                        "(Ljava/lang/String;Ljava/util/Map;)L" + NATIVE_LIB + ";", false);
                    out.visitFieldInsn(Opcodes.PUTSTATIC, owner, "sdl2Library", "L" + NATIVE_LIB + ";");
                    out.visitLabel(loaded);
                    out.visitFrame(Opcodes.F_SAME, 0, null, 0, null);
                    out.visitInsn(Opcodes.RETURN);
                    out.visitMaxs(2, 0);
                    out.visitEnd();
                    changes++;
                    return null;
                }
                if ("loadSDL2InterfaceInstance".equals(name) && "(Ljava/lang/Class;)Lcom/sun/jna/Library;".equals(desc)) {
                    return new MethodVisitor(Opcodes.ASM9, out) {
                        @Override public void visitLdcInsn(Object value) {
                            if ("SDL2".equals(value)) { changes++; super.visitLdcInsn(path); }
                            else super.visitLdcInsn(value);
                        }
                    };
                }
            }
            if ((SDL_GDX.equals(owner) && "<clinit>".equals(name) && "()V".equals(desc))
                || (JAMEPAD.equals(owner) && "<init>".equals(name) && "(ILjava/lang/String;)V".equals(desc))) {
                return new MethodVisitor(Opcodes.ASM9, out) {
                    @Override public void visitMethodInsn(int opcode, String type, String method, String descriptor, boolean itf) {
                        if (opcode == Opcodes.INVOKEVIRTUAL && JNI_LOADER.equals(type)
                            && "load".equals(method) && "(Ljava/lang/String;)V".equals(descriptor)) {
                            // 丢弃原装载器与桌面库短名，在原类发起 System.load，JNI 仍关联其游戏类加载器。
                            super.visitInsn(Opcodes.POP2);
                            super.visitLdcInsn(path);
                            super.visitMethodInsn(Opcodes.INVOKESTATIC, "java/lang/System", "load", descriptor, false);
                            changes++;
                        } else super.visitMethodInsn(opcode, type, method, descriptor, itf);
                    }
                };
            }
            return out;
        }
    }
}
