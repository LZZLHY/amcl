import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;

/**
 * JNI Invocation 退出语义的 Java 消费者。只写测试临时文件，不访问 AMCL 或用户实例。
 * 所有场景都注册同一个 Java shutdown hook，便于区分 System.exit、Runtime.halt
 * 和主入口正常返回；每个场景由宿主脚本启动全新 native 进程和全新 JVM。
 */
public final class JniExitFixture {
    /** 禁止实例化；本类只有 JNI 直接调用的静态 main。 */
    private JniExitFixture() { }

    /**
     * args[0] 指定退出动作；args[1] 是只属于本测试进程的 shutdown hook 证据路径。
     * hook 写入失败会保留 stderr，宿主也会因为缺少精确文件内容判为失败。
     */
    public static void main(String[] args) {
        if (args.length != 2) throw new IllegalArgumentException("action and shutdown marker are required");
        final String marker = args[1];
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            try {
                Files.write(Paths.get(marker), "SHUTDOWN_HOOK\n".getBytes(StandardCharsets.UTF_8),
                        StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE);
            } catch (IOException error) {
                error.printStackTrace(System.err);
            }
        }, "jni-exit-fixture-shutdown"));
        System.out.println("FIXTURE_READY action=" + args[0]
                + " runtime=" + System.getProperty("java.runtime.version"));
        System.out.flush();
        switch (args[0]) {
            case "system-exit-0":
                System.exit(0);
                break;
            case "system-exit-7":
                System.exit(7);
                break;
            case "runtime-halt-9":
                Runtime.getRuntime().halt(9);
                break;
            case "main-return":
                return;
            default:
                throw new IllegalArgumentException("unknown fixture action: " + args[0]);
        }
        throw new AssertionError("exit/halt unexpectedly returned to Java");
    }
}
