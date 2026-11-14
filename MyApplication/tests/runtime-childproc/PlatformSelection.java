/* 反射读取完整候选java.lang.ProcessImpl的真实静态选择结果；每个情形独占新VM。
 * 不把源码字符串匹配当作Java功能执行，也不运行目标JDK bin或真实目标ProcessBuilder。
 */
public final class PlatformSelection {
    public static void main(String[] args) throws Exception {
        if (args.length != 1) throw new IllegalArgumentException("expected mechanism or INVALID");
        try {
            Class<?> type = Class.forName("java.lang.ProcessImpl");
            java.lang.reflect.Field value = type.getDeclaredField("launchMechanism");
            value.setAccessible(true);
            String actual = value.get(null).toString();
            if (!actual.equals(args[0])) throw new AssertionError(actual + " != " + args[0]);
            System.out.println("PASS actual ProcessImpl selection " + actual);
        } catch (Error failure) {
            if (!args[0].equals("INVALID") || failure.getMessage() == null ||
                    !failure.getMessage().contains("not a supported")) throw failure;
            System.out.println("PASS original invalid-mechanism rejection " + failure.getClass().getName());
        }
    }
}
