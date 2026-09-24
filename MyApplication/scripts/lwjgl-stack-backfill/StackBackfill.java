/*
 * StackBackfill.java — re-add the LWJGL 3.2.x `*Stack` static allocator API to a
 * post-3.3.1 LWJGL jar (modern slot currently ships 3.4.2) so that Minecraft 1.13–1.19.x bytecode that
 * calls `GLFWImage.mallocStack(...)` etc. links again instead of crashing with
 * NoSuchMethodError at startup.
 *
 * Background:
 *   LWJGL deprecated `mallocStack/callocStack` in 3.2.x and *removed* them after
 *   3.3.1. MC 1.19–1.19.2 pin LWJGL 3.3.1 and their compiled bytecode still calls
 *   `GLFWImage.mallocStack(int, MemoryStack)` (Window.setIcon). AMCL ships a single
 *   3.4.1 native+jar set for "LWJGL 3.3+", which lacks these methods -> boot crash.
 *
 * Fix (FCL/Pojav-style superset, native untouched):
 *   For every Struct class that still has the modern stack-aware allocators
 *   (`malloc(MemoryStack)` / `malloc(int, MemoryStack)` and the calloc twins), add
 *   back the removed `*Stack` siblings as trivial pure-Java delegates:
 *
 *     mallocStack()                 -> malloc(MemoryStack.stackGet())
 *     mallocStack(MemoryStack s)    -> malloc(s)
 *     mallocStack(int n)            -> malloc(n, MemoryStack.stackGet())
 *     mallocStack(int n, MemoryStack s) -> malloc(n, s)
 *     (and the callocStack twins)
 *
 *   Detection is by the presence of the corresponding `malloc(...)` target, so this
 *   only touches genuine Struct types and is automatically future-proof. Methods that
 *   already exist are skipped (idempotent).
 *
 * Usage:
 *   java -cp <asm>;<asm-tree>;. StackBackfill <in.jar> <out.jar>
 *
 * Returns nonzero on error. Prints a per-jar summary of (classes patched / methods added).
 */
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.VarInsnNode;
import org.objectweb.asm.tree.InsnNode;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.time.LocalDateTime;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import java.util.zip.ZipOutputStream;

public final class StackBackfill {
    private static final LocalDateTime REPRODUCIBLE_ZIP_TIME =
        LocalDateTime.of(2000, 1, 1, 0, 0, 0);

    static final String MEMORY_STACK = "org/lwjgl/system/MemoryStack";

    public static void main(String[] args) throws Exception {
        if (args.length != 2) {
            System.err.println("usage: StackBackfill <in.jar> <out.jar>");
            System.exit(2);
        }
        Path in = Paths.get(args[0]);
        Path out = Paths.get(args[1]);

        int classesPatched = 0;
        int methodsAdded = 0;
        int futureClassesSkipped = 0;

        byte[] inBytes = Files.readAllBytes(in);
        try (ZipOutputStream zos = new ZipOutputStream(Files.newOutputStream(out))) {
            try (ZipInputStream zis = new ZipInputStream(new java.io.ByteArrayInputStream(inBytes))) {
                ZipEntry e;
                while ((e = zis.getNextEntry()) != null) {
                    byte[] data = readAll(zis);
                    byte[] outData = data;
                    if (e.getName().endsWith(".class")) {
                        int[] added = new int[]{0};
                        byte[] patched;
                        try {
                            patched = patchClass(data, added);
                        } catch (IllegalArgumentException ex) {
                            // Multi-release jars may contain variants for a JDK newer than
                            // the vendored ASM understands (LWJGL 3.4.2 includes Java 27,
                            // class major 71). Those variants are not selected by AMCL's
                            // JDK 8/17/21/25 runtimes. Preserve them byte-for-byte and keep
                            // processing the base/JDK 25 views that actually need backfill.
                            if (ex.getMessage() == null
                                    || !ex.getMessage().startsWith("Unsupported class file major version")) {
                                throw ex;
                            }
                            patched = null;
                            futureClassesSkipped++;
                        }
                        if (patched != null) {
                            outData = patched;
                            classesPatched++;
                            methodsAdded += added[0];
                        }
                    }
                    // Re-store every entry. Use DEFLATED; copy name + comment.
                    ZipEntry ne = new ZipEntry(e.getName());
                    // A fresh upgrade must produce the same jar bytes on every
                    // invocation and host timezone. ZipEntry's default is the
                    // current clock time; setTime(long) is timezone-sensitive,
                    // so pin the ZIP-local timestamp explicitly instead.
                    ne.setTimeLocal(REPRODUCIBLE_ZIP_TIME);
                    zos.putNextEntry(ne);
                    zos.write(outData);
                    zos.closeEntry();
                }
            }
        }
        System.out.println("[stack-backfill] " + in.getFileName()
                + ": classes patched=" + classesPatched + " methods added=" + methodsAdded
                + " future classes preserved=" + futureClassesSkipped);
    }

    /** @return new class bytes if any method was added, else null (unchanged). */
    static byte[] patchClass(byte[] classBytes, int[] addedOut) {
        ClassReader cr = new ClassReader(classBytes);
        ClassNode cn = new ClassNode();
        // IMPORTANT: flags=0, NOT SKIP_FRAMES. We only append brand-new branch-free
        // methods and must keep every existing method's StackMapTable intact, or
        // Java 8+ verification fails (VerifyError: Expecting a stackmap frame).
        // Keeping FrameNodes lets ClassWriter(COMPUTE_MAXS) re-emit them verbatim for
        // untouched methods; our added methods have no branches so need no frames.
        cr.accept(cn, 0);

        String self = cn.name; // internal name, e.g. org/lwjgl/glfw/GLFWImage

        // Index existing static methods by name+desc to: (a) find delegate targets,
        // (b) avoid re-adding methods that already exist.
        Set<String> present = new HashSet<>();
        for (MethodNode m : cn.methods) {
            if ((m.access & Opcodes.ACC_STATIC) != 0) present.add(m.name + m.desc);
        }

        // Target descriptors of the modern allocators we delegate to.
        // Single-instance variant returns L<self>; , buffer variant returns L<self>$Buffer; .
        String selfDesc = "L" + self + ";";
        String bufDesc = "L" + self + "$Buffer;";

        boolean hasMallocStackInstance = present.contains("malloc(L" + MEMORY_STACK + ";)" + selfDesc);
        boolean hasCallocStackInstance = present.contains("calloc(L" + MEMORY_STACK + ";)" + selfDesc);
        boolean hasMallocStackBuffer = present.contains("malloc(IL" + MEMORY_STACK + ";)" + bufDesc);
        boolean hasCallocStackBuffer = present.contains("calloc(IL" + MEMORY_STACK + ";)" + bufDesc);

        if (!hasMallocStackInstance && !hasCallocStackInstance
                && !hasMallocStackBuffer && !hasCallocStackBuffer) {
            return null; // not a struct with stack allocators -> leave untouched
        }

        List<MethodNode> toAdd = new ArrayList<>();

        // ---- instance variants (no count) ----
        if (hasMallocStackInstance) {
            maybeAdd(toAdd, present, "mallocStack", "()" + selfDesc, self,
                    instanceNoArg(self, "malloc", selfDesc));
            maybeAdd(toAdd, present, "mallocStack", "(L" + MEMORY_STACK + ";)" + selfDesc, self,
                    instanceWithStack(self, "malloc", selfDesc));
        }
        if (hasCallocStackInstance) {
            maybeAdd(toAdd, present, "callocStack", "()" + selfDesc, self,
                    instanceNoArg(self, "calloc", selfDesc));
            maybeAdd(toAdd, present, "callocStack", "(L" + MEMORY_STACK + ";)" + selfDesc, self,
                    instanceWithStack(self, "calloc", selfDesc));
        }
        // ---- buffer variants (int count) ----
        if (hasMallocStackBuffer) {
            maybeAdd(toAdd, present, "mallocStack", "(I)" + bufDesc, self,
                    bufferCountOnly(self, "malloc", bufDesc));
            maybeAdd(toAdd, present, "mallocStack", "(IL" + MEMORY_STACK + ";)" + bufDesc, self,
                    bufferCountStack(self, "malloc", bufDesc));
        }
        if (hasCallocStackBuffer) {
            maybeAdd(toAdd, present, "callocStack", "(I)" + bufDesc, self,
                    bufferCountOnly(self, "calloc", bufDesc));
            maybeAdd(toAdd, present, "callocStack", "(IL" + MEMORY_STACK + ";)" + bufDesc, self,
                    bufferCountStack(self, "calloc", bufDesc));
        }

        if (toAdd.isEmpty()) return null;

        cn.methods.addAll(toAdd);
        addedOut[0] = toAdd.size();

        ClassWriter cw = new ClassWriter(ClassWriter.COMPUTE_MAXS);
        cn.accept(cw);
        return cw.toByteArray();
    }

    static void maybeAdd(List<MethodNode> toAdd, Set<String> present,
                         String name, String desc, String self, InsnList body) {
        if (present.contains(name + desc)) return;
        MethodNode mn = new MethodNode(Opcodes.ASM9,
                Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, name, desc, null, null);
        mn.instructions = body;
        // maxs computed by COMPUTE_MAXS
        toAdd.add(mn);
    }

    // body: return <self>.<target>(MemoryStack.stackGet());   [-> selfDesc]
    static InsnList instanceNoArg(String self, String target, String selfDesc) {
        InsnList il = new InsnList();
        il.add(new MethodInsnNode(Opcodes.INVOKESTATIC, MEMORY_STACK, "stackGet",
                "()L" + MEMORY_STACK + ";", false));
        il.add(new MethodInsnNode(Opcodes.INVOKESTATIC, self, target,
                "(L" + MEMORY_STACK + ";)" + selfDesc, false));
        il.add(new InsnNode(Opcodes.ARETURN));
        return il;
    }

    // body: return <self>.<target>(stack);   arg0 = MemoryStack   [-> selfDesc]
    static InsnList instanceWithStack(String self, String target, String selfDesc) {
        InsnList il = new InsnList();
        il.add(new VarInsnNode(Opcodes.ALOAD, 0));
        il.add(new MethodInsnNode(Opcodes.INVOKESTATIC, self, target,
                "(L" + MEMORY_STACK + ";)" + selfDesc, false));
        il.add(new InsnNode(Opcodes.ARETURN));
        return il;
    }

    // body: return <self>.<target>(n, MemoryStack.stackGet());  arg0 = int  [-> bufDesc]
    static InsnList bufferCountOnly(String self, String target, String bufDesc) {
        InsnList il = new InsnList();
        il.add(new VarInsnNode(Opcodes.ILOAD, 0));
        il.add(new MethodInsnNode(Opcodes.INVOKESTATIC, MEMORY_STACK, "stackGet",
                "()L" + MEMORY_STACK + ";", false));
        il.add(new MethodInsnNode(Opcodes.INVOKESTATIC, self, target,
                "(IL" + MEMORY_STACK + ";)" + bufDesc, false));
        il.add(new InsnNode(Opcodes.ARETURN));
        return il;
    }

    // body: return <self>.<target>(n, stack);  arg0 = int, arg1 = MemoryStack  [-> bufDesc]
    static InsnList bufferCountStack(String self, String target, String bufDesc) {
        InsnList il = new InsnList();
        il.add(new VarInsnNode(Opcodes.ILOAD, 0));
        il.add(new VarInsnNode(Opcodes.ALOAD, 1));
        il.add(new MethodInsnNode(Opcodes.INVOKESTATIC, self, target,
                "(IL" + MEMORY_STACK + ";)" + bufDesc, false));
        il.add(new InsnNode(Opcodes.ARETURN));
        return il;
    }

    static byte[] readAll(InputStream is) throws Exception {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = is.read(buf)) != -1) bos.write(buf, 0, n);
        return bos.toByteArray();
    }
}
