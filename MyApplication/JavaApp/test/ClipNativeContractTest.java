import java.lang.reflect.Method;
import java.util.List;
import java.util.ArrayList;
import java.util.Collections;
import java.util.concurrent.Callable;
import java.util.concurrent.TimeUnit;
import javax.sound.sampled.*;

/**
 * 真实 Clip→Java provider→JNI→PCM Runtime→Converter→系统 ring 的离线回归。
 * 唯一替身是 Native 已有的显式系统平台夹具；consume 更新真实的 transferred 计数。
 * 通过测试反射复用 AudioNativeSmoke 的私有夹具入口，不增加任何生产测试后门或假帧位置。
 */
public final class ClipNativeContractTest {
    private static int checks;
    private static volatile boolean consuming;
    private static final Object deviceLock = new Object();
    private static Method begin, consume, end;

    /** 三秒上限只约束测试本身；生产 Clip 不通过超时伪造播放完成。 */
    private static void waitFor(Callable<Boolean> predicate, String label) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
        while (!predicate.call() && System.nanoTime() < deadline) Thread.sleep(2);
        check(predicate.call(), label);
    }
    private static void check(boolean value, String label) {
        checks++; if (!value) throw new AssertionError(label);
    }
    /** 使用标准 API 选择生产 SPI；160 个业务帧在未 finish 时只有 478 个系统帧。 */
    private static Clip open(int rate, int frames) throws Exception {
        AudioFormat format = new AudioFormat(rate, 16, 1, true, false);
        Clip clip = AudioSystem.getClip(); byte[] pcm = new byte[frames * 2];
        for (int i = 0; i < frames; i++) { pcm[i * 2] = 0; pcm[i * 2 + 1] = 32; }
        clip.open(format, pcm, 0, pcm.length);
        check(clip.getClass().getName().equals("com.amcl.audio.OhosClip"), "standard Clip selects production provider");
        return clip;
    }
    /** 真实系统替身尚未消费时，应用仍可取消、seek 或 flush；这里不能调用阻塞 drain。 */
    private static void expectQueued(Clip clip) throws Exception {
        Thread.sleep(40);
        check(clip.isOpen() && clip.isRunning() && clip.getFramePosition() == 0, "unconsumed Clip remains running at real position zero");
    }
    private static void completed(final Clip clip, int frames) throws Exception {
        consuming = true;
        try {
            waitFor(new Callable<Boolean>() { public Boolean call() { return !clip.isRunning(); } }, "resampled Clip reaches real rendered end");
        } catch (AssertionError failure) {
            throw new AssertionError(failure.getMessage() + " actualFrame=" + clip.getFramePosition() + " expected=" + frames, failure);
        }
        check(clip.isOpen() && clip.getFramePosition() == frames, "completed Clip retains exact media position");
    }
    /** 先等待可能正在进行的消费返回，再关掉下一次消费，防止新流刚打开就被旧循环消费。 */
    private static void pauseConsumption() { synchronized (deviceLock) { consuming = false; } }
    public static void main(String[] args) throws Exception {
        // 此夹具由 native tests/run-host.sh 用真实生产核心编译；调用者显式提供该 DSO。
        System.load(args[0]); Class<?> fixture = Class.forName("AudioNativeSmoke");
        begin = fixture.getDeclaredMethod("begin"); consume = fixture.getDeclaredMethod("consume"); end = fixture.getDeclaredMethod("end");
        begin.setAccessible(true); consume.setAccessible(true); end.setAccessible(true);
        check(((Integer) begin.invoke(null)).intValue() == 0, "native host fixture begins one real audio session");
        final List<Throwable> failures = Collections.synchronizedList(new ArrayList<Throwable>());
        Thread consumer = new Thread(new Runnable() { public void run() {
            try { while (!Thread.currentThread().isInterrupted()) {
                synchronized (deviceLock) { if (consuming) consume.invoke(null); }
                Thread.sleep(2);
            } }
            catch (InterruptedException expected) { }
            catch (Throwable failure) { failures.add(failure); }
        } }, "explicit native Clip platform consumer");
        consumer.setDaemon(true); consumer.start();
        Clip clip = null;
        try {
            final List<LineEvent.Type> events = Collections.synchronizedList(new ArrayList<LineEvent.Type>());
            clip = open(16000, 160);
            clip.addLineListener(new LineListener() { public void update(LineEvent event) { events.add(event.getType()); } });
            clip.start(); expectQueued(clip); completed(clip, 160);
            waitFor(new Callable<Boolean>() { public Boolean call() { return events.contains(LineEvent.Type.STOP); } }, "finished resampling delivers actual STOP event");
            clip.loop(1); completed(clip, 160); clip.close();

            // Piper 的 22050Hz 同样必须补齐非整数倍率尾部，包括一个业务帧的极短 Clip。
            clip = open(22050, 2205); clip.start(); completed(clip, 2205); clip.close();
            clip = open(22050, 1); clip.start(); completed(clip, 1); clip.close();

            pauseConsumption(); clip = open(16000, 160); clip.start(); expectQueued(clip);
            long started = System.nanoTime(); clip.setFramePosition(80); clip.flush(); clip.stop();
            check(System.nanoTime() - started < TimeUnit.SECONDS.toNanos(1), "seek flush stop at pending EOF finish stay cancellable");
            check(clip.isOpen() && !clip.isRunning() && clip.getFramePosition() == 80, "seek flush preserve selected media position");
            clip.start(); completed(clip, 160); clip.close();

            pauseConsumption(); clip = open(16000, 160); clip.start(); expectQueued(clip); clip.stop();
            check(clip.isOpen() && !clip.isRunning(), "stop preserves pending finished segment without closing");
            clip.start(); completed(clip, 160); clip.close();

            pauseConsumption(); clip = open(16000, 160); clip.start(); expectQueued(clip);
            Clip reopened = clip; clip.close();
            AudioFormat format = new AudioFormat(16000, 16, 1, true, false);
            reopened.open(format, new byte[320], 0, 320); reopened.start();
            completed(reopened, 160); reopened.close(); clip = null;
            check(failures.isEmpty(), "native platform consumer has no hidden exception");
            System.out.println("PASS real Clip JNI/core resampling checks=" + checks + " runtime=" + System.getProperty("java.version"));
        } finally {
            if (clip != null) clip.close(); consumer.interrupt(); consumer.join(); end.invoke(null);
        }
    }
}
