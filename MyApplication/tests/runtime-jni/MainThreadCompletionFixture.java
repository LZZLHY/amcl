import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.util.concurrent.CountDownLatch;

/** 独立launcher的真实Java语义：main返回后worker必须能join原main，然后正常产出并执行hook。
 * 不使用sleep判定退出、不强杀线程；旧直接Destroy路径会被外部期限准确识别为未完成。
 */
public final class MainThreadCompletionFixture {
    public static void main(String[] args) throws Exception {
        final Thread originalMain = Thread.currentThread();
        final String prefix = args[0];
        final CountDownLatch entered = new CountDownLatch(1);
        Thread worker = new Thread(() -> {
            try {
                entered.countDown();
                originalMain.join();
                if (originalMain.isAlive()) throw new AssertionError("original main still alive");
                Files.write(Paths.get(prefix + ".worker"), "main-ended\n".getBytes(StandardCharsets.UTF_8),
                    StandardOpenOption.CREATE_NEW);
            } catch (Exception error) { throw new RuntimeException(error); }
        }, "join-original-main");
        worker.setDaemon(false);
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            try {
                String value = new String(Files.readAllBytes(Paths.get(prefix + ".worker")), StandardCharsets.UTF_8);
                if (!value.equals("main-ended\n")) throw new AssertionError("worker did not finish");
                Files.write(Paths.get(prefix + ".hook"), "hook-after-main-join\n".getBytes(StandardCharsets.UTF_8),
                    StandardOpenOption.CREATE_NEW);
            } catch (Exception error) { throw new RuntimeException(error); }
        }, "main-join-hook"));
        worker.start();
        entered.await();
    }
}
