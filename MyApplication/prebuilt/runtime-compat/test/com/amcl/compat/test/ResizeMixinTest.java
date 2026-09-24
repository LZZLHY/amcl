package com.amcl.compat.test;

import java.io.*;
import java.lang.reflect.*;
import java.util.Arrays;
import org.spongepowered.asm.launch.MixinBootstrap;
import org.spongepowered.asm.mixin.*;
import org.spongepowered.asm.mixin.transformer.IMixinTransformer;

public final class ResizeMixinTest {
    static final String NAME = "net.minecraft.class_310";
    static class TargetLoader extends ClassLoader {
        TargetLoader() { super(ResizeMixinTest.class.getClassLoader()); }
        Class<?> define(byte[] bytes) { return defineClass(NAME, bytes, 0, bytes.length); }
    }
    static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
    public static void main(String[] args) throws Exception {
        byte[] original;
        try (InputStream in = ResizeMixinTest.class.getClassLoader().getResourceAsStream(NAME.replace('.', '/') + ".class")) {
            original = in.readAllBytes();
        }
        try {
            new TargetLoader().define(original).getConstructor().newInstance();
            throw new AssertionError("Negative control did not fail");
        } catch (InvocationTargetException expected) {
            check(expected.getCause() instanceof IllegalStateException, "Unexpected negative control");
        }
        MixinBootstrap.init();
        MixinEnvironment.getDefaultEnvironment().setSide(MixinEnvironment.Side.CLIENT);
        Mixins.addConfiguration("amcl-runtime-compat.mixins.json");
        Constructor<?> constructor = Class.forName("org.spongepowered.asm.mixin.transformer.MixinTransformer").getDeclaredConstructor();
        constructor.setAccessible(true);
        IMixinTransformer transformer = (IMixinTransformer)constructor.newInstance();
        byte[] transformed = transformer.transformClassBytes(NAME, NAME, original);
        check(!Arrays.equals(original, transformed), "Mixin did not transform target");
        Class<?> cls = new TargetLoader().define(transformed);
        Object instance = cls.getConstructor().newInstance();
        check(cls.getField("calls").getInt(instance) == 1, "Construction resize was not coalesced");
        check(cls.getField("appliedWidth").getInt(instance) == 2090, "Latest constructor size was lost");
        cls.getField("reenter").setInt(instance, 2);
        cls.getMethod("method_15993").invoke(instance);
        check(cls.getField("maxDepth").getInt(instance) == 1, "Resize recursed into render resources");
        check(cls.getField("appliedWidth").getInt(instance) == 2088, "Latest reentrant size was lost");
        int calls = cls.getField("calls").getInt(instance);
        cls.getMethod("close").invoke(instance);
        cls.getMethod("method_15993").invoke(instance);
        check(cls.getField("calls").getInt(instance) == calls, "Resize accessed closed resources");
        System.out.println("[resize-mixin] PASS actual Mixin transformation, construction, coalescing, reentry and close");
    }
}
