/**
 * 真实 JVM + JNI 双类加载器回归：使用产品 CallbackBridge、注册表与 JNI_OnLoad。
 * parent 已定义但未初始化不应抢 native owner；合法委派应共享 owner；独立复制必须失败。
 */
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.file.Paths;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;

public final class NativeOwnershipTest {
    private static final String BRIDGE = "org.lwjgl.glfw.CallbackBridge";
    private static native int setup(String mode);
    private static native int nativeCalls();

    /** 只对测试目标 child-first，其余 JDK 类仍走正式父级协议。 */
    private static final class ChildLoader extends URLClassLoader {
        ChildLoader(URL url, ClassLoader parent) { super(new URL[]{url}, parent); }
        @Override protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
            synchronized (getClassLoadingLock(name)) {
                Class<?> type = findLoadedClass(name);
                if (type == null) type = BRIDGE.equals(name) ? findClass(name) : super.loadClass(name, false);
                if (resolve) resolveClass(type);
                return type;
            }
        }
    }

    /** 以已实现的按键入口验证注册；旧手柄共享缓冲区必须保持明确 unsupported。 */
    private static void exercise(Class<?> type) throws Exception {
        int before = nativeCalls();
        Method query = type.getDeclaredMethod("nativeGetKeyDown", int.class);
        query.setAccessible(true);
        type.getMethod("sendKeyPress", int.class, int.class, boolean.class).invoke(null, 32, 0, true);
        check(((Integer)query.invoke(null, 32)) == 1, "native key press did not reach owner");
        type.getMethod("sendKeyPress", int.class, int.class, boolean.class).invoke(null, 32, 0, false);
        check(((Integer)query.invoke(null, 32)) == 0, "native key release did not reach owner");
        check(nativeCalls() >= before + 4, "native event/query counter did not advance");
        check(type.getField("sGamepadButtonBuffer").get(null) == null, "dummy button buffer hides unsupported capability");
        check(type.getField("sGamepadAxisBuffer").get(null) == null, "dummy axis buffer hides unsupported capability");
        check(!type.getField("GAMEPAD_SHARED_BUFFER_SUPPORTED").getBoolean(null), "unsupported capability marked ready");
        type.getMethod("enableGamepadDirectInput").invoke(null);
        check(!type.getField("sGamepadDirectEnabled").getBoolean(null), "enable created fake readiness");
        try {
            type.getMethod("sendData", int.class, String.class).invoke(null, 2002, "unsupported");
            throw new AssertionError("unsupported sendData silently succeeded");
        } catch (InvocationTargetException expected) {
            check(expected.getCause() instanceof UnsupportedOperationException, "wrong unsupported exception");
        }
    }

    /** 初始化失败只能是明确 JNI 链接错误；若发生 VM 崩溃、任意异常或假成功都算测试失败。 */
    private static void expectLoadFailure(ClassLoader loader, boolean duplicate) throws Exception {
        try {
            Class.forName(BRIDGE, true, loader);
            throw new AssertionError("invalid native ownership/descriptor unexpectedly succeeded");
        } catch (LinkageError expected) {
            Throwable cause = expected;
            while (cause.getCause() != null) cause = cause.getCause();
            check(cause instanceof UnsatisfiedLinkError || cause instanceof NoSuchMethodError,
                  "unexpected linkage failure: " + expected);
            if (duplicate) check(cause.getMessage().contains("already loaded in another classloader"),
                                 "not genuine JVM duplicate-library rejection: " + cause);
        }
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    public static void main(String[] args) throws Exception {
        String mode = args[0];
        System.load(Paths.get(args[1]).toAbsolutePath().toString());
        check(setup(mode) == 0, "host publication failed");
        URL url = Paths.get(args[2]).toUri().toURL();
        try (URLClassLoader parent = new URLClassLoader(new URL[]{url}, NativeOwnershipTest.class.getClassLoader());
             ChildLoader child = new ChildLoader(url, parent)) {
            if ("child-first".equals(mode)) {
                Class<?> uninitializedParent = Class.forName(BRIDGE, false, parent);
                Class<?> actual = Class.forName(BRIDGE, true, child);
                check(actual != uninitializedParent && actual.getClassLoader() == child, "test did not isolate class identities");
                exercise(actual);
                check(Class.forName(BRIDGE, true, child) == actual, "reinitialization changed class identity");
            } else if ("delegated-parent".equals(mode)) {
                try (URLClassLoader delegated = new URLClassLoader(new URL[]{url}, parent)) {
                    Class<?> actual = Class.forName(BRIDGE, true, delegated);
                    check(actual == Class.forName(BRIDGE, true, parent), "legal delegation did not share class");
                    exercise(actual);
                }
            } else if ("parent-preload-conflict".equals(mode)) {
                exercise(Class.forName(BRIDGE, true, parent));
                expectLoadFailure(child, true);
            } else if ("two-isolated-consumers".equals(mode)) {
                exercise(Class.forName(BRIDGE, true, child));
                try (ChildLoader second = new ChildLoader(url, parent)) { expectLoadFailure(second, true); }
            } else {
                expectLoadFailure(child, false);
                check(nativeCalls() == 0, "invalid descriptor reached a native device callback");
            }
        }
        System.out.println("PASS " + mode + " nativeCalls=" + nativeCalls());
    }
}
