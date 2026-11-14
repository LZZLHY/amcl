/** 四代真实宿主 JVM 的 Invocation/Unicode/异常验证；类文件统一按 Java 8 编译。 */
public final class InvocationFixture {
    public static void main(String[] args) {
        if (args.length == 1 && "throw".equals(args[0])) {
            throw new IllegalStateException("original-main-failure");
        }
        if (args.length != 2 || !"中文".equals(args[0]) || !"emoji-😀".equals(args[1])) {
            throw new AssertionError("JNI argument conversion changed content");
        }
        System.out.println("JNI_MAIN_CONTENT_OK " + System.getProperty("java.version"));
    }
}
