package com.amcl.gamepad;

import java.io.File;
import java.lang.reflect.Field;
import java.net.URL;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.HashMap;
import net.minecraft.launchwrapper.IClassTransformer;
import net.minecraft.launchwrapper.Launch;
import net.minecraft.launchwrapper.LaunchClassLoader;
import net.minecraftforge.fml.common.asm.transformers.deobf.FMLDeobfuscatingRemapper;
import net.minecraftforge.fml.relauncher.FMLLaunchHandler;
import net.minecraftforge.fml.relauncher.Side;

/** 用 1.12.2 正式 Forge 的客户端筛选、反混淆及 LaunchClassLoader 定义绑定，保留其真实 CodeSource。 */
public final class ForgeModLoadProbe {
    public static void main(String[] args) throws Exception {
        File mod = new File(args[1]);
        boolean gdx = "gdx".equals(args[0]);
        String owner = gdx ? "org.libsdl.SDL" : "com.studiohartman.jamepad.ControllerManager";
        Launch.blackboard = new HashMap<String,Object>();
        Launch.blackboard.put("fml.deobfuscatedEnvironment", false);
        // 模拟 Forge 客户端启动已设的 side；类读取、变换、defineClass 与首个 JNI 调用均由原件执行。
        Field side = FMLLaunchHandler.class.getDeclaredField("side");
        side.setAccessible(true);
        side.set(null, Side.CLIENT);
        try (LaunchClassLoader child = new LaunchClassLoader(new URL[]{mod.toURI().toURL()})) {
            Launch.classLoader = child;
            child.addClassLoaderExclusion("net.minecraftforge.");
            child.addClassLoaderExclusion("com.google.common.");
            FMLDeobfuscatingRemapper.INSTANCE.setup(null, child, "/deobfuscation_data-1.12.2.lzma");
            child.registerTransformer("net.minecraftforge.fml.common.asm.transformers.SideTransformer");
            child.registerTransformer("net.minecraftforge.fml.common.asm.transformers.DeobfuscationTransformer");
            if (child.getTransformers().size() != 2) throw new AssertionError("Missing Forge transformer");
            byte[] raw = child.getClassBytes(owner);
            byte[] defined = raw;
            for (IClassTransformer transformer : child.getTransformers()) defined = transformer.transform(owner, owner, defined);
            if (gdx && Arrays.equals(raw, defined)) throw new AssertionError("Missing Forge rewrite");
            Class<?> binding = Class.forName(owner, true, child);
            URL origin = binding.getProtectionDomain().getCodeSource().getLocation();
            if (binding.getClassLoader() != child || !origin.getProtocol().equals("jar"))
                throw new AssertionError("Missing LaunchWrapper ownership");
            if (gdx) {
                if (binding.getField("SDL_INIT_TIMER").getInt(null) != 1) throw new AssertionError("Wrong SDL_INIT_TIMER");
            } else {
                Object manager = binding.getConstructor(int.class).newInstance(1);
                java.lang.reflect.Method count = binding.getDeclaredMethod("nativeGetNumRollers");
                count.setAccessible(true);
                count.invoke(manager);
            }
            StringBuilder hash = new StringBuilder(64);
            for (byte b : MessageDigest.getInstance("SHA-256").digest(defined)) hash.append(String.format("%02x", b & 255));
            System.out.println("SDL2_BINDING_OK Forge112 " + args[0] + " class=" + hash + " origin=" + origin.getProtocol());
        }
    }
}
