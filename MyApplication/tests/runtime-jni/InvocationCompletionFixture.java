import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;

/** main 返回后仍有合法非 daemon 产物，随后 shutdown hook 必须看到完整产物。 */
public final class InvocationCompletionFixture {
    public static void main(String[] args) {
        final String prefix = args[0];
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            try {
                String worker = new String(Files.readAllBytes(Paths.get(prefix + ".worker")), StandardCharsets.UTF_8);
                if (!"worker\n".equals(worker)) throw new AssertionError("worker result incomplete");
                Files.write(Paths.get(prefix + ".hook"), "hook-after-worker\n".getBytes(StandardCharsets.UTF_8),
                    StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE);
            } catch (Exception error) { throw new RuntimeException(error); }
        }, "completion-fixture-hook"));
        Thread worker = new Thread(() -> {
            try {
                Thread.sleep(100);
                Files.write(Paths.get(prefix + ".worker"), "worker\n".getBytes(StandardCharsets.UTF_8),
                    StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE);
            } catch (Exception error) { throw new RuntimeException(error); }
        }, "completion-fixture-non-daemon");
        worker.setDaemon(false);
        worker.start();
        if (args.length > 1 && "throw".equals(args[1])) throw new IllegalStateException("main failed after starting worker");
    }
}
