package org.lwjgl.opengl;

import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;

/**
 * 真实旧/新JAR与真实旧/新JNI正文的双向运行期配对。反射只调用该JAR本来就有的
 * AMCLDisplay/Context入口，不伪造marker或替换任何游戏类；平台计数证明拒绝早于副作用。
 */
public final class L2InputContractTest {
    private static native void resetPlatform();
    private static native int[] platformCounts();

    private static Object call(Class<?> type,String name,Class<?>[] signature,Object receiver,Object... args) throws Exception {
        Method method=type.getDeclaredMethod(name,signature); method.setAccessible(true);
        return method.invoke(receiver,args);
    }

    private static void check(boolean value,String message) {
        if(!value) throw new AssertionError(message);
    }

    /** 只接受明确InputContractMismatch；普通missing marker/JNI链接异常不冒充合同拒绝。 */
    private static void rejected(Class<?> type,String method,Class<?>[] signature,Object receiver,Object... args) throws Exception {
        try {
            call(type,method,signature,receiver,args);
            throw new AssertionError("mixed LWJGL2 pair accepted: "+method);
        } catch(InvocationTargetException failure) {
            Throwable cause=failure.getCause();
            check(cause!=null && String.valueOf(cause.getMessage()).contains("InputContractMismatch"),
                "mixed pair must explicitly report InputContractMismatch: "+cause);
        }
        int[] counts=platformCounts();
        check(counts[0]==0 && counts[1]==0,"mixed pair reached real platform create/source read before rejection");
    }

    public static void main(String[] args) throws Exception {
        System.load(args[0]); resetPlatform();
        // 这是合法实际测试初始化，不是宿主预探游戏类。运行classpath决定实际旧/新JAR。
        Class<?> display=Class.forName("org.lwjgl.opengl.AMCLDisplay");
        Constructor<?> constructor=display.getDeclaredConstructor(); constructor.setAccessible(true);
        Object instance=constructor.newInstance();
        Class<?> context=Class.forName("org.lwjgl.opengl.AMCLContextImplementation");
        if(args[1].equals("new-java-old-native")) {
            rejected(display,"init",new Class<?>[0],instance);
        } else if(args[1].equals("old-java-new-native")) {
            rejected(context,"nCreate",new Class<?>[0],null);
            rejected(display,"nCreateWindow",new Class<?>[]{int.class,int.class},null,800,600);
            rejected(display,"nNextEvent",new Class<?>[]{int[].class},null,new int[5]);
        } else {
            call(display,"init",new Class<?>[0],instance);
            check((Boolean)call(display,"nCreateWindow",new Class<?>[]{int.class,int.class},null,800,600),"matching pair creates real platform window");
            call(display,"nNextEvent",new Class<?>[]{int[].class},null,new int[5]);
            int[] counts=platformCounts();
            check(counts[0]==1 && counts[1]==1,"matching calibration must reach actual create/source boundaries");
        }
        System.out.println("L2_INPUT_CONTRACT_PASS "+args[1]);
    }
}
