package com.amcl.compat.test;

import java.nio.ByteBuffer;
import java.nio.file.*;
import java.util.zip.ZipFile;
import org.objectweb.asm.*;
import org.objectweb.asm.tree.*;

/** Execute the actual added wrappers against a deterministic int API, without opening host UI. */
public final class TinyFdCompatibilityTest {
    public static void main(String[] args) throws Exception {
        final String name = "org/lwjgl/util/tinyfd/TinyFileDialogs";
        byte[] original;
        try (ZipFile zip = new ZipFile(args[0])) { original = zip.getInputStream(zip.getEntry(name + ".class")).readAllBytes(); }
        ClassNode node = new ClassNode(); new ClassReader(original).accept(node, 0);
        node.methods.removeIf(m -> m.name.equals("<clinit>"));
        node.fields.add(new FieldNode(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, "testResult", "I", null, null));
        node.fields.add(new FieldNode(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, "testDefault", "I", null, null));
        for (MethodNode method : node.methods) {
            if (!method.name.equals("tinyfd_messageBox") || !method.desc.endsWith("I)I")) continue;
            method.instructions.clear(); method.tryCatchBlocks.clear(); method.localVariables = null;
            method.visibleLocalVariableAnnotations = null; method.invisibleLocalVariableAnnotations = null;
            method.instructions.add(new VarInsnNode(Opcodes.ILOAD, 4));
            method.instructions.add(new FieldInsnNode(Opcodes.PUTSTATIC, name, "testDefault", "I"));
            method.instructions.add(new FieldInsnNode(Opcodes.GETSTATIC, name, "testResult", "I"));
            method.instructions.add(new InsnNode(Opcodes.IRETURN));
        }
        ClassWriter writer = new ClassWriter(ClassWriter.COMPUTE_MAXS); node.accept(writer);
        byte[] bytes = writer.toByteArray();
        Class<?> type = new ClassLoader(TinyFdCompatibilityTest.class.getClassLoader()) {
            Class<?> define() { return defineClass(name.replace('/', '.'), bytes, 0, bytes.length); }
        }.define();
        for (Class<?> argument : new Class<?>[]{CharSequence.class, ByteBuffer.class}) {
            for (int value : new int[]{0, 1, 2, -1, Integer.MIN_VALUE}) for (boolean button : new boolean[]{false, true}) {
                type.getField("testResult").setInt(null, value);
                Object result = type.getMethod("tinyfd_messageBox", argument, argument, argument, argument, boolean.class)
                    .invoke(null, null, null, null, null, button);
                if (!result.equals(value != 0) || type.getField("testDefault").getInt(null) != (button ? 1 : 0)) {
                    throw new AssertionError("TinyFD boolean ABI differs from the original != 0 wrapper");
                }
            }
        }
        System.out.println("[tinyfd-compat] PASS actual old overloads: int defaults, zero/nonzero results, both buffer/string APIs");
    }
}
