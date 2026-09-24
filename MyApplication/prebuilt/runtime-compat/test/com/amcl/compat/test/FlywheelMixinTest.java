package com.amcl.compat.test;

import com.amcl.compat.CompatMixinPlugin;
import java.io.InputStream;
import java.lang.reflect.Constructor;
import java.util.Arrays;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.spongepowered.asm.launch.MixinBootstrap;
import org.spongepowered.asm.mixin.MixinEnvironment;
import org.spongepowered.asm.mixin.Mixins;
import org.spongepowered.asm.mixin.transformer.IMixinTransformer;

/** 使用冻结的真实 Create Fly 类验证指纹门与 Mixin 变换，不在宿主加载 Minecraft 或 GPU。 */
public final class FlywheelMixinTest {
    public static void main(String[] args) throws Exception {
        String name = CompatMixinPlugin.CREATE_TARGET;
        byte[] original;
        try (InputStream input = FlywheelMixinTest.class.getClassLoader().getResourceAsStream(name.replace('.', '/') + ".class")) {
            if (input == null) throw new AssertionError("missing verified fixture");
            original = input.readAllBytes();
        }
        if (!CompatMixinPlugin.matchesCreateFly(original)) throw new AssertionError("real target rejected");
        byte[] changed = original.clone(); changed[changed.length - 1] ^= 1;
        if (CompatMixinPlugin.matchesCreateFly(changed) || CompatMixinPlugin.matchesCreateFly(null))
            throw new AssertionError("unknown or absent target accepted");

        MixinBootstrap.init();
        MixinEnvironment.getDefaultEnvironment().setSide(MixinEnvironment.Side.CLIENT);
        Mixins.addConfiguration("amcl-runtime-compat.mixins.json");
        Constructor<?> factory = Class.forName("org.spongepowered.asm.mixin.transformer.MixinTransformer").getDeclaredConstructor();
        factory.setAccessible(true);
        IMixinTransformer transformer = (IMixinTransformer) factory.newInstance();
        byte[] transformed = transformer.transformClassBytes(name, name, original);
        if (Arrays.equals(original, transformed)) throw new AssertionError("target not transformed");
        ClassNode node = new ClassNode(); new ClassReader(transformed).accept(node, 0);
        int beforeDispatch = 0, flushCalls = 0;
        // 检查实际生成的调用顺序与影子方法绑定，防止注解存在但没有进入真实 GPU 派发路径。
        for (MethodNode method : node.methods) {
            boolean injected = false;
            for (AbstractInsnNode instruction : method.instructions) {
                if (!(instruction instanceof MethodInsnNode call)) continue;
                if (method.name.equals("dispatchScatter") && call.name.contains("amcl$flushScatterBeforeBind")) injected = true;
                if (method.name.equals("dispatchScatter") && call.name.equals("glDispatchCompute") && injected) beforeDispatch++;
                if (method.name.contains("amcl$flushScatterBeforeBind") && call.name.equals("glFlushMappedNamedBufferRange")
                    && call.owner.equals("org/lwjgl/opengl/GL45C")) flushCalls++;
            }
        }
        if (beforeDispatch != 1 || flushCalls != 1) throw new AssertionError("flush injection shape mismatch");
        System.out.println("[flywheel-mixin] PASS real class hash, absent/modified negatives and flush before the only compute dispatch");
    }
}
