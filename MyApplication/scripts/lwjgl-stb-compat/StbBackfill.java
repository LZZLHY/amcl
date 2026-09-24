import java.io.*;
import java.nio.file.*;
import java.time.LocalDateTime;
import java.util.*;
import java.util.zip.*;
import org.objectweb.asm.*;
import org.objectweb.asm.tree.*;

/** Binary compatibility: legacy descriptors delegate to a separately compiled v1 implementation. */
public final class StbBackfill {
    static final String OWNER = "org/lwjgl/stb/STBImageResize";
    static final String LEGACY = OWNER + "V1";
    static Map<String, byte[]> read(Path path) throws IOException {
        Map<String, byte[]> entries = new LinkedHashMap<>();
        try (ZipInputStream in = new ZipInputStream(Files.newInputStream(path))) {
            for (ZipEntry e; (e = in.getNextEntry()) != null;) {
                if (entries.put(e.getName(), in.readAllBytes()) != null) throw new IOException("Duplicate ZIP entry: " + e.getName());
            }
        }
        return entries;
    }
    static ClassNode node(byte[] bytes) {
        if (bytes == null) throw new IllegalArgumentException("Required class missing");
        ClassNode node = new ClassNode(); new ClassReader(bytes).accept(node, 0); return node;
    }
    static String key(MethodNode method) { return method.name + method.desc; }
    static boolean api(MethodNode method) {
        return (method.access & (Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC)) == (Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC);
    }
    static MethodNode delegate(MethodNode source) {
        MethodNode result = new MethodNode(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, source.name, source.desc, null, null);
        int slot = 0;
        for (Type arg : Type.getArgumentTypes(source.desc)) {
            result.instructions.add(new VarInsnNode(arg.getOpcode(Opcodes.ILOAD), slot)); slot += arg.getSize();
        }
        result.instructions.add(new MethodInsnNode(Opcodes.INVOKESTATIC, LEGACY, source.name, source.desc, false));
        result.instructions.add(new InsnNode(Type.getReturnType(source.desc).getOpcode(Opcodes.IRETURN)));
        return result;
    }
    static boolean isDelegate(MethodNode method, MethodNode reference) {
        AbstractInsnNode[] actual = Arrays.stream(method.instructions.toArray()).filter(n -> n.getOpcode() >= 0).toArray(AbstractInsnNode[]::new);
        AbstractInsnNode[] expected = delegate(reference).instructions.toArray();
        if (actual.length != expected.length || (method.access & Opcodes.ACC_NATIVE) != 0) return false;
        for (int i = 0; i < actual.length; i++) {
            if (actual[i].getOpcode() != expected[i].getOpcode()) return false;
            if (expected[i] instanceof VarInsnNode && ((VarInsnNode)actual[i]).var != ((VarInsnNode)expected[i]).var) return false;
            if (expected[i] instanceof MethodInsnNode) {
                MethodInsnNode a = (MethodInsnNode)actual[i], e = (MethodInsnNode)expected[i];
                if (!a.owner.equals(e.owner) || !a.name.equals(e.name) || !a.desc.equals(e.desc)) return false;
            }
        }
        return true;
    }
    public static void main(String[] args) throws Exception {
        Path target = Paths.get(args[0]);
        boolean check = Arrays.asList(args).contains("--check");
        if (Arrays.asList(args).contains("--tinyfd-only")) {
            tinyFd(target, check);
            return;
        }
        byte[] legacyBytes = Files.readAllBytes(Paths.get(args[1]));
        Map<String, byte[]> entries = read(target);
        ClassNode reference = node(read(Paths.get(args[2])).get(OWNER + ".class"));
        ClassNode legacy = node(legacyBytes);
        ClassNode modern = node(entries.get(OWNER + ".class"));
        if (!legacy.name.equals(LEGACY)) throw new IllegalStateException("Incorrect legacy class owner");
        Map<String, MethodNode> present = new HashMap<>(), legacyApi = new HashMap<>();
        for (MethodNode method : modern.methods) if (present.put(key(method), method) != null) throw new IllegalStateException("Duplicate method");
        for (MethodNode method : legacy.methods) if (api(method)) legacyApi.put(key(method), method);
        int added = 0, checked = 0;
        for (MethodNode method : reference.methods) {
            if (!api(method)) continue;
            if (!legacyApi.containsKey(key(method))) throw new IllegalStateException("Legacy API was lost: " + key(method));
            MethodNode current = present.get(key(method));
            if (current == null) { modern.methods.add(delegate(method)); added++; }
            else if (!isDelegate(current, method)) throw new IllegalStateException("Unaudited API collision: " + key(method));
            checked++;
        }
        Set<String> fields = new HashSet<>();
        for (FieldNode f : modern.fields) fields.add(f.name);
        for (FieldNode f : reference.fields) if (!fields.contains(f.name)) { modern.fields.add(f); added++; }
        boolean changed = added != 0 || !Arrays.equals(entries.get(LEGACY + ".class"), legacyBytes);
        if (check) {
            if (changed) throw new IllegalStateException("STB compatibility payload is incomplete");
        } else if (changed) {
            if (added != 0) {
                ClassWriter writer = new ClassWriter(new ClassReader(entries.get(OWNER + ".class")), ClassWriter.COMPUTE_MAXS);
                modern.accept(writer); entries.put(OWNER + ".class", writer.toByteArray());
            }
            entries.put(LEGACY + ".class", legacyBytes);
            Path temp = target.resolveSibling(target.getFileName() + ".stb.tmp");
            try (ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(temp))) {
                for (Map.Entry<String, byte[]> e : entries.entrySet()) {
                    ZipEntry entry = new ZipEntry(e.getKey()); entry.setTimeLocal(LocalDateTime.of(2000, 1, 1, 0, 0));
                    out.putNextEntry(entry); out.write(e.getValue()); out.closeEntry();
                }
            }
            Files.move(temp, target, StandardCopyOption.REPLACE_EXISTING);
        }
        System.out.println("[stb-compat] legacy API=" + checked + " additions=" + added + " changed=" + changed);
        if (!Arrays.asList(args).contains("--stb-only")) tinyFd(target.resolveSibling("lwjgl-tinyfd.jar"), check);
    }

    // LWJGL changed the public default-button/result from boolean to int. The
    // underlying native API already returned int in 3.3.3; preserve its old != 0 wrapper.
    static void tinyFd(Path target, boolean check) throws Exception {
        Map<String, byte[]> entries = read(target);
        String owner = "org/lwjgl/util/tinyfd/TinyFileDialogs", path = owner + ".class";
        ClassNode type = node(entries.get(path));
        int added = 0;
        for (String arg : new String[]{"Ljava/nio/ByteBuffer;", "Ljava/lang/CharSequence;"}) {
            String modernDesc = "(" + arg.repeat(4) + "I)I", oldDesc = "(" + arg.repeat(4) + "Z)Z";
            if (type.methods.stream().noneMatch(m -> m.name.equals("tinyfd_messageBox") && m.desc.equals(modernDesc))) throw new IllegalStateException("Modern TinyFD API missing");
            if (type.methods.stream().anyMatch(m -> m.name.equals("tinyfd_messageBox") && m.desc.equals(oldDesc))) continue;
            MethodNode method = new MethodNode(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, "tinyfd_messageBox", oldDesc, null, null);
            for (int i = 0; i < 4; i++) method.instructions.add(new VarInsnNode(Opcodes.ALOAD, i));
            method.instructions.add(new VarInsnNode(Opcodes.ILOAD, 4));
            method.instructions.add(new MethodInsnNode(Opcodes.INVOKESTATIC, owner, "tinyfd_messageBox", modernDesc, false));
            method.instructions.add(new MethodInsnNode(Opcodes.INVOKESTATIC, "java/lang/Integer", "signum", "(I)I", false));
            method.instructions.add(new InsnNode(Opcodes.ICONST_1));
            method.instructions.add(new InsnNode(Opcodes.IAND));
            method.instructions.add(new InsnNode(Opcodes.IRETURN));
            type.methods.add(method); added++;
        }
        if (check && added != 0) throw new IllegalStateException("Legacy TinyFD API missing");
        if (!check && added != 0) {
            ClassWriter writer = new ClassWriter(new ClassReader(entries.get(path)), ClassWriter.COMPUTE_MAXS);
            type.accept(writer); entries.put(path, writer.toByteArray());
            Path temp = target.resolveSibling(target.getFileName() + ".compat.tmp");
            try (ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(temp))) {
                for (Map.Entry<String, byte[]> e : entries.entrySet()) {
                    ZipEntry entry = new ZipEntry(e.getKey()); entry.setTimeLocal(LocalDateTime.of(2000, 1, 1, 0, 0));
                    out.putNextEntry(entry); out.write(e.getValue()); out.closeEntry();
                }
            }
            Files.move(temp, target, StandardCopyOption.REPLACE_EXISTING);
        }
        System.out.println("[tinyfd-compat] legacy boolean overloads added=" + added);
    }
}
