package com.amcl.gamepad;

import java.io.File;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.lang.instrument.ClassFileTransformer;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.net.URL;
import java.net.URLClassLoader;

/** 使用真实模组的子类加载器执行 JNI 或 JNA，宿主库只用于验证装载和绑定归属。 */
public final class ModLoadProbe {
    public static void main(String[] args) throws Exception {
        URL[] urls = new URL[args.length - 1];
        for (int i = 1; i < args.length; i++) urls[i - 1] = new File(args[i]).toURI().toURL();
        try (URLClassLoader child = new URLClassLoader(urls, null)) {
            String mode = args[0];
            if ("gdx".equals(mode)) {
                Class<?> sdl = Class.forName("org.libsdl.SDL", true, child);
                if (sdl.getClassLoader() != child || sdl.getField("SDL_INIT_TIMER").getInt(null) != 1) {
                    throw new AssertionError("SDL JNI binding");
                }
                sdl.getMethod("SDL_WasInit", int.class).invoke(null, 0);
            } else if ("jamepad".equals(mode)) {
                Class<?> manager = Class.forName("com.studiohartman.jamepad.ControllerManager", true, child);
                Object value = manager.getConstructor().newInstance();
                Method count = manager.getDeclaredMethod("nativeGetNumRollers");
                count.setAccessible(true);
                count.invoke(value);
            } else if ("jna".equals(mode)) {
                Class<?> api = Class.forName("com.mrcrayfish.controllable_sdl.api.joystick.SdlJoystick", true, child);
                api.getMethod("SDL_NumJoysticks").invoke(null);
                // 可变参数 API 使用 Native.load 接口，错误回读使用 Native.register，必须共享同一份 SDL。
                Class<?> error = Class.forName("com.mrcrayfish.controllable_sdl.api.error.SdlError", true, child);
                error.getMethod("SDL_SetError",String.class,Object[].class).invoke(null,"amcl-sdl2-probe",new Object[0]);
                if (!"amcl-sdl2-probe".equals(error.getMethod("SDL_GetError").invoke(null))) throw new AssertionError("JNA mixed SDL images");
                Class<?> loader = child.loadClass("com.mrcrayfish.controllable_sdl.jna.SdlNativeLibraryLoader");
                Field cached = loader.getDeclaredField("sdl2Library");
                cached.setAccessible(true);
                Object lib = cached.get(null);
                File file = (File) lib.getClass().getMethod("getFile").invoke(lib);
                File expected = new File(System.getProperty("amcl.gamepad.sdl2.dir"), "libSDL2.so");
                if (!file.getCanonicalFile().equals(expected.getCanonicalFile())) throw new AssertionError(file);
            } else if ("jna-name".equals(mode) || "jna-user".equals(mode)) {
                // 任意消费者都走 JNA 公开裸名入口，返回的实际路径区分 HAP 候补和用户原目录。
                String oldPath = System.getProperty("jna.library.path");
                Class<?> api = child.loadClass("com.sun.jna.NativeLibrary");
                Method get = api.getMethod("getInstance",String.class);
                Object handle = get.invoke(null,"SDL2");
                File file = (File) api.getMethod("getFile").invoke(handle);
                File expected = new File(System.getProperty("amcl.test.expected"));
                if (!file.getCanonicalFile().equals(expected.getCanonicalFile())) throw new AssertionError(file);
                Object function = api.getMethod("getFunction",String.class).invoke(handle,"SDL_WasInit");
                function.getClass().getMethod("invokeInt",Object[].class).invoke(function,(Object)new Object[]{0});
                // HAP 中还放有同样可用的对照库；非 SDL2 名字必须继续沿用自己的搜索范围。
                try {
                    get.invoke(null,"amcl_unrelated_compat");
                    throw new AssertionError("unexpected search directory for unrelated library");
                } catch (java.lang.reflect.InvocationTargetException e) {
                    if (!(e.getCause() instanceof UnsatisfiedLinkError)) throw e;
                }
                if (!java.util.Objects.equals(oldPath,System.getProperty("jna.library.path"))) throw new AssertionError("global search path changed");
            } else if ("unknown".equals(mode)) {
                // 仅将修改的内存字节交给真实 transformer，原签名 JAR 始终按原件读取。
                String name = "com/studiohartman/jamepad/ControllerManager";
                byte[] bytes;
                try (InputStream stream = child.getResourceAsStream(name + ".class")) {
                    ByteArrayOutputStream buffer = new ByteArrayOutputStream();
                    byte[] chunk = new byte[4096];
                    int n;
                    while ((n = stream.read(chunk)) >= 0) buffer.write(chunk, 0, n);
                    bytes = buffer.toByteArray();
                }
                Constructor<?> constructor = Class.forName("com.amcl.gamepad.Sdl2NativeLoader").getDeclaredConstructor(File.class);
                constructor.setAccessible(true);
                ClassFileTransformer transformer = (ClassFileTransformer) constructor.newInstance(new File(System.getProperty("amcl.gamepad.sdl2.dir")));
                bytes[bytes.length - 1] ^= 1;
                if (transformer.transform(child,name,null,null,bytes) != null) throw new AssertionError("unknown class accepted");
            } else throw new IllegalArgumentException(mode);
            System.out.println("SDL2_BINDING_OK " + mode + " Java " + System.getProperty("java.version"));
        }
    }
}
