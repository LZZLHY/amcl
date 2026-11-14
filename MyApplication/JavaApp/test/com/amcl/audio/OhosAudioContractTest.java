package com.amcl.audio;

import java.io.ByteArrayOutputStream;
import java.util.*;
import java.util.concurrent.*;
import javax.sound.sampled.*;
import javax.sound.sampled.spi.MixerProvider;

/**
 * 宿主契约回放：显式构造独立 Mixer 并注入确定性驱动，生产 SPI 始终使用真实 JNI。
 * 测试逐字节读取生产转换结果，并验证标准 API 的等待/唤醒与 Clip 游标，不把驱动伪装成设备验收。
 */
public final class OhosAudioContractTest {
    private static int checks;
    private static final AudioFormat MONO = new AudioFormat(16000, 16, 1, true, false);
    private static final ExecutorService TASKS = Executors.newCachedThreadPool();
    private static void check(boolean value, String label) { checks++; if (!value) throw new AssertionError(label); }
    private static void waitFor(Callable<Boolean> predicate, String label) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
        while (!predicate.call() && System.nanoTime() < deadline) Thread.sleep(2);
        check(predicate.call(), label);
    }
    private static SourceDataLine source(OhosMixer mixer, AudioFormat format) throws Exception {
        return (SourceDataLine) mixer.getLine(new DataLine.Info(SourceDataLine.class, format));
    }
    private static void testDiscovery() throws Exception {
        java.io.DataInputStream bytecode = new java.io.DataInputStream(OhosMixerProvider.class.getResourceAsStream("OhosMixerProvider.class"));
        try { check(bytecode.readInt() == 0xcafebabe && bytecode.readUnsignedShort() >= 0 && bytecode.readUnsignedShort() == 52, "actual provider uses Java 8 bytecode"); }
        finally { bytecode.close(); }
        int count = 0;
        for (MixerProvider provider : ServiceLoader.load(MixerProvider.class))
            if (provider instanceof OhosMixerProvider) { count++; check(provider.getMixerInfo().length == 1, "side-effect free service enumeration"); }
        check(count == 1, "one production service descriptor");
        System.setProperty("javax.sound.sampled.SourceDataLine", "com.amcl.audio.OhosMixerProvider#AMCL OHAudio");
        check(AudioSystem.getSourceDataLine(MONO) instanceof OhosSourceDataLine, "standard AudioSystem default selection reaches production provider");
        System.setProperty("javax.sound.sampled.Clip", "com.amcl.audio.OhosMixerProvider#AMCL OHAudio");
        check(AudioSystem.getClip() instanceof OhosClip, "standard getClip accepts unspecified-rate PCM template before open");
        SourceDataLine actual = source((OhosMixer) new OhosMixerProvider().getMixer(null), MONO);
        boolean refused = false;
        try { actual.open(MONO); } catch (LineUnavailableException expected) { refused = true; }
        check(refused && !actual.isOpen(), "production missing native path never becomes fake device");
        ClassLoader previous = Thread.currentThread().getContextClassLoader();
        ClassLoader child = new java.net.URLClassLoader(new java.net.URL[0], previous);
        try {
            Thread.currentThread().setContextClassLoader(child); count = 0;
            for (MixerProvider provider : ServiceLoader.load(MixerProvider.class))
                if (provider.getClass() == OhosMixerProvider.class) count++;
            check(count == 1, "child TCCL uses parent provider identity");
        } finally { Thread.currentThread().setContextClassLoader(previous); ((java.net.URLClassLoader) child).close(); }
        java.net.URL origin = OhosMixerProvider.class.getProtectionDomain().getCodeSource().getLocation();
        java.net.URLClassLoader childFirst = new java.net.URLClassLoader(new java.net.URL[]{origin}, previous) {
            protected synchronized Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
                if (name.startsWith("com.amcl.audio.")) {
                    Class<?> value = findLoadedClass(name); if (value == null) value = findClass(name);
                    if (resolve) resolveClass(value); return value;
                }
                return super.loadClass(name, resolve);
            }
        };
        String previousPath = System.getProperty("amcl.audio.jni.path");
        try {
            System.setProperty("amcl.audio.jni.path", new java.io.File("nonexistent-audio-owner-fixture.so").getAbsolutePath());
            MixerProvider duplicate = (MixerProvider) childFirst.loadClass(OhosMixerProvider.class.getName()).getConstructor().newInstance();
            SourceDataLine duplicateLine = (SourceDataLine) duplicate.getMixer(null).getLine(new DataLine.Info(SourceDataLine.class, MONO));
            boolean rejected = false;
            try { duplicateLine.open(MONO); }
            catch (LineUnavailableException expected) { rejected = expected.getMessage().contains("redefined by a child ClassLoader"); }
            check(rejected, "child-first duplicate bridge is refused before loading a second native owner");
        } finally {
            if (previousPath == null) System.clearProperty("amcl.audio.jni.path"); else System.setProperty("amcl.audio.jni.path", previousPath);
            childFirst.close();
        }
    }
    private static void testPlayback() throws Exception {
        FakeBackend driver = new FakeBackend(); OhosMixer mixer = new OhosMixer(driver);
        SourceDataLine line = source(mixer, MONO); line.open(MONO, 32);
        check(line.getBufferSize() == 32 && line.available() == 32, "mono public buffer remains in original frame units");
        ((FloatControl) line.getControl(FloatControl.Type.PAN)).setValue(1);
        byte[] pcm = {0, 4, 0, 8};
        check(line.write(pcm, 0, pcm.length) == pcm.length, "unstarted line accepts bounded queued PCM");
        check(driver.bytes(driver.last).length == 0, "no playback before start");
        line.start(); line.drain();
        check(Arrays.equals(driver.bytes(driver.last), new byte[]{0, 0, 0, 4, 0, 0, 0, 8}), "mono PAN changes actual stereo samples");
        check(line.getLongFramePosition() == 2, "position counts rendered frames");
        ((BooleanControl) line.getControl(BooleanControl.Type.MUTE)).setValue(true);
        line.write(pcm, 0, pcm.length); line.drain();
        byte[] consumed = driver.bytes(driver.last);
        check(Arrays.equals(Arrays.copyOfRange(consumed, 8, 16), new byte[8]), "mute modifies PCM");
        line.close(); check(mixer.getSourceLines().length == 0, "closed line no longer retained by global mixer");
        AudioFormat big = new AudioFormat(22050, 16, 2, true, true);
        line = source(mixer, big); line.open(big, 32); line.start();
        line.write(new byte[]{1, 2, 3, 4}, 0, 4); line.drain();
        check(Arrays.equals(driver.bytes(driver.last), new byte[]{2, 1, 4, 3}), "big endian stereo canonical conversion"); line.close();
        AudioFormat floating = new AudioFormat(AudioFormat.Encoding.PCM_FLOAT, 24000, 32, 1, 4, 24000, false);
        line = source(mixer, floating); line.open(floating, 32); line.start();
        line.write(new byte[]{0, 0, 0, 63}, 0, 4); line.drain();
        check(Arrays.equals(driver.bytes(driver.last), new byte[]{0, 0, 0, 63, 0, 0, 0, 63}), "float PCM mono expansion"); line.close();
        line = source(mixer, MONO); line.open(MONO, 32);
        ((FloatControl) line.getControl(FloatControl.Type.MASTER_GAIN)).setValue(-6.0206f);
        line.start(); line.write(new byte[]{0, 8}, 0, 2); line.drain();
        byte[] half = driver.bytes(driver.last);
        check((half[0] & 255) + ((half[1] & 255) << 8) == 1024, "MASTER_GAIN changes actual PCM amplitude"); line.close();
        boolean invalid = false;
        try { source(mixer, MONO).open(MONO, 3); } catch (IllegalArgumentException expected) { invalid = true; }
        check(invalid, "buffer rejects incomplete frames");
        check(!mixer.isLineSupported(new DataLine.Info(SourceDataLine.class, new AudioFormat(12345, 16, 1, true, false))), "unsupported sample rate is not advertised");
    }
    private static void testBlocking() throws Exception {
        final FakeBackend driver = new FakeBackend(); OhosMixer mixer = new OhosMixer(driver);
        final SourceDataLine line = source(mixer, MONO); line.open(MONO, 8);
        final long id = driver.last;
        Future<Integer> write = TASKS.submit(new Callable<Integer>() { public Integer call() { return line.write(new byte[32], 0, 32); } });
        waitFor(new Callable<Boolean>() { public Boolean call() { return line.available() == 0; } }, "write fills bounded buffer");
        check(!write.isDone(), "large write blocks"); line.stop();
        check(write.get(2, TimeUnit.SECONDS) == 8, "stop releases write with partial count");
        check(driver.queued(id) == 16, "stop preserves queued stereo frames");
        Future<?> drain = TASKS.submit(new Runnable() { public void run() { line.drain(); } });
        Thread.sleep(40); check(!drain.isDone(), "drain on stopped nonempty line remains blocked");
        line.start(); drain.get(2, TimeUnit.SECONDS);
        line.stop(); line.write(new byte[8], 0, 8);
        drain = TASKS.submit(new Runnable() { public void run() { line.drain(); } });
        Thread.sleep(30); line.close(); drain.get(2, TimeUnit.SECONDS);
        check(!line.isOpen(), "close unblocks drain without pretending queue drained");
        final SourceDataLine flushed = source(mixer, MONO); flushed.open(MONO, 8);
        Future<Integer> flushing = TASKS.submit(new Callable<Integer>() { public Integer call() { return flushed.write(new byte[32768], 0, 32768); } });
        waitFor(new Callable<Boolean>() { public Boolean call() { return flushed.available() == 0; } }, "flush test fills buffer");
        flushed.flush(); check(flushing.get(2, TimeUnit.SECONDS) == 8, "flush cancels whole multi-chunk write with actual partial count");
        check(driver.queued(driver.last) == 0, "flush discards queued frames"); flushed.close();
        final TargetDataLine capture = (TargetDataLine) mixer.getLine(new DataLine.Info(TargetDataLine.class, MONO));
        capture.open(MONO, 16); capture.start();
        Future<Integer> read = TASKS.submit(new Callable<Integer>() { public Integer call() { return capture.read(new byte[8], 0, 8); } });
        Thread.sleep(30); check(!read.isDone(), "capture waits for actual supplied samples");
        capture.close(); check(read.get(2, TimeUnit.SECONDS) == 0, "close releases capture read");
    }
    private static void testCaptureAndFailure() throws Exception {
        FakeBackend driver = new FakeBackend(); OhosMixer mixer = new OhosMixer(driver);
        AudioFormat big = new AudioFormat(16000, 16, 1, true, true);
        TargetDataLine line = (TargetDataLine) mixer.getLine(new DataLine.Info(TargetDataLine.class, big));
        line.open(big, 16); line.start(); driver.supply(driver.last, new byte[]{2, 1, 4, 3});
        byte[] output = new byte[4]; check(line.read(output, 0, 4) == 4, "read real supplied bytes");
        check(Arrays.equals(output, new byte[]{1, 2, 3, 4}), "capture endian conversion");
        check(line.getLongFramePosition() == 2, "capture frames reflect supplied samples");
        line.close();
        final SourceDataLine failed = source(mixer, MONO); failed.open(MONO, 16); driver.fail(driver.last);
        waitFor(new Callable<Boolean>() { public Boolean call() { return !failed.isOpen(); } }, "FAILED native state explicitly closes line");
        driver.permission = false;
        boolean denied = false;
        try { line.open(big, 16); } catch (SecurityException expected) { denied = true; }
        check(denied && !line.isOpen(), "permission failure remains failure");
    }
    private static void testClipAndEvents() throws Exception {
        final FakeBackend driver = new FakeBackend(); OhosMixer mixer = new OhosMixer(driver);
        final Clip clip = (Clip) mixer.getLine(new DataLine.Info(Clip.class, MONO));
        final List<LineEvent.Type> events = Collections.synchronizedList(new ArrayList<LineEvent.Type>());
        clip.addLineListener(new LineListener() { public void update(LineEvent event) { events.add(event.getType()); } });
        clip.open(MONO, new byte[]{1, 0, 2, 0, 3, 0, 4, 0}, 0, 8);
        check(clip.getFrameLength() == 4, "clip media length"); clip.setLoopPoints(1, 2); clip.loop(2);
        waitFor(new Callable<Boolean>() { public Boolean call() { return !clip.isRunning(); } }, "clip finite loop reaches rendered end");
        byte[] bytes = driver.bytes(driver.last); int[] samples = new int[bytes.length / 4];
        for (int i = 0; i < samples.length; i++) samples[i] = (bytes[i * 4] & 255) | ((bytes[i * 4 + 1] & 255) << 8);
        check(Arrays.equals(samples, new int[]{1, 2, 3, 2, 3, 2, 3, 4}), "clip exact finite loop sample order");
        clip.setFramePosition(1); check(clip.getFramePosition() == 1, "clip seek uses media cursor");
        clip.start(); waitFor(new Callable<Boolean>() { public Boolean call() { return !clip.isRunning(); } }, "clip replay after seek");
        clip.close();
        waitFor(new Callable<Boolean>() { public Boolean call() { return events.contains(LineEvent.Type.CLOSE); } }, "close event delivered asynchronously");
        check(events.get(0) == LineEvent.Type.OPEN && events.get(events.size() - 1) == LineEvent.Type.CLOSE, "line event outer ordering");
        check(events.contains(LineEvent.Type.START) && events.contains(LineEvent.Type.STOP), "short PCM still reports actual start/stop");
        final SourceDataLine reentrant = source(mixer, MONO);
        reentrant.addLineListener(new LineListener() { public void update(LineEvent event) { if (event.getType() == LineEvent.Type.OPEN) reentrant.close(); } });
        reentrant.open(MONO, 16);
        waitFor(new Callable<Boolean>() { public Boolean call() { return !reentrant.isOpen(); } }, "listener may close without lock inversion");
        final Clip continuous = (Clip) mixer.getLine(new DataLine.Info(Clip.class, MONO));
        continuous.open(MONO, new byte[8192], 0, 8192); continuous.loop(Clip.LOOP_CONTINUOUSLY);
        Thread.sleep(20);
        Future<?> seek = TASKS.submit(new Runnable() { public void run() { continuous.setFramePosition(2); continuous.stop(); } });
        seek.get(2, TimeUnit.SECONDS); check(continuous.isOpen(), "seek while writer blocked never deadlocks or closes clip");
        continuous.close();
        final Clip flushing = (Clip) mixer.getLine(new DataLine.Info(Clip.class, MONO));
        flushing.open(MONO, new byte[8192], 0, 8192); flushing.start(); Thread.sleep(20); flushing.flush();
        waitFor(new Callable<Boolean>() { public Boolean call() { return !flushing.isRunning(); } }, "Clip flush rebases native queue accounting and still reaches end");
        flushing.close();
    }
    /** 用受控的 finish 入口停顿精确制造控制交错；不依赖线程恰好在某个 sleep 窗口竞争。 */
    private static void testClipFinishCancellation() throws Exception {
        final FakeBackend driver = new FakeBackend(); final OhosMixer mixer = new OhosMixer(driver);
        final Clip clip = (Clip) mixer.getLine(new DataLine.Info(Clip.class, MONO));
        FakeBackend.FinishGate gate = new FakeBackend.FinishGate(false); driver.finishGate = gate;
        clip.open(MONO, new byte[320], 0, 320); clip.start();
        check(gate.entered.await(2, TimeUnit.SECONDS), "Clip reaches explicit input finish request");
        Future<?> stop = TASKS.submit(new Runnable() { public void run() { clip.stop(); } });
        stop.get(2, TimeUnit.SECONDS);
        check(!clip.isRunning(), "stop does not wait on finish while clipLock is released");
        // 新 loop 意图在旧 EOF 仍未返回时发布；旧 EOF 不能停止它。
        clip.loop(1); gate.release.countDown();
        waitFor(new Callable<Boolean>() { public Boolean call() { return !clip.isRunning(); } }, "new loop survives stale EOF observation");
        check(driver.bytes(driver.last).length == 320 * 4, "EOF loop appends exactly one full media pass"); clip.close();

        gate = new FakeBackend.FinishGate(false); driver.finishGate = gate;
        clip.open(MONO, new byte[320], 0, 320); clip.start();
        check(gate.entered.await(2, TimeUnit.SECONDS), "seek test reaches pending finish");
        Future<?> seek = TASKS.submit(new Runnable() { public void run() { clip.setFramePosition(80); } });
        Thread.sleep(20); check(!seek.isDone(), "seek waits for old finish before clearing converter state");
        gate.release.countDown(); seek.get(2, TimeUnit.SECONDS);
        waitFor(new Callable<Boolean>() { public Boolean call() { return !clip.isRunning(); } }, "seek after pending finish completes");
        check(clip.getFramePosition() == 160 && clip.isOpen(), "seek retains correct final media position"); clip.close();

        gate = new FakeBackend.FinishGate(true); driver.finishGate = gate;
        clip.open(MONO, new byte[320], 0, 320); clip.start();
        check(gate.entered.await(2, TimeUnit.SECONDS), "reopen test retains an old finish call");
        clip.close(); clip.open(MONO, new byte[320], 0, 320);
        final long reopened = driver.last;
        gate.release.countDown(); Thread.sleep(20);
        check(clip.isOpen(), "old finish failure cannot close a reopened Clip");
        clip.start(); waitFor(new Callable<Boolean>() { public Boolean call() { return !clip.isRunning(); } }, "reopened Clip owns its pump lifecycle");
        check(driver.bytes(reopened).length == 160 * 4, "reopened Clip delivers its own PCM exactly once"); clip.close();
    }
    public static void main(String[] args) throws Exception {
        try { testDiscovery(); testPlayback(); testBlocking(); testCaptureAndFailure(); testClipAndEvents(); testClipFinishCancellation();
            System.out.println("PASS Java Sound production semantics checks=" + checks + " runtime=" + System.getProperty("java.version"));
        } finally { TASKS.shutdownNow(); }
    }

    /**
     * 明确的宿主驱动：仅消费真实写入字节，录音必须由测试显式供样。有限缓冲和停止代次遵守native端口契约。
     * 每条流的驱动线程只用于宿主回放，测试文件不进入生产 JAR。
     */
    private static final class FakeBackend implements AudioBackend {
        private final Map<Long, Stream> streams = new ConcurrentHashMap<Long, Stream>();
        private long sequence; volatile long last; volatile boolean permission = true;
        volatile FinishGate finishGate;
        /** 仅测试使用的入口屏障；模拟调用被调度器挂起后，控制线程仍须能取消或重开流。 */
        private static final class FinishGate {
            final CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
            final boolean fail; boolean claimed;
            FinishGate(boolean fail) { this.fail = fail; }
        }
        private static final class Stream {
            final boolean capture; final int capacity; final int frame;
            final ArrayDeque<Byte> queue = new ArrayDeque<Byte>(); final ByteArrayOutputStream consumed = new ByteArrayOutputStream();
            boolean open = true, running, active, failed; long frames, interrupt;
            Stream(boolean c, int bytes, int channels, int encoding) { capture = c; capacity = bytes; frame = channels * (encoding == 1 ? 2 : 4); }
        }
        public synchronized long open(boolean capture, int rate, int channels, int encoding, int bytes) {
            if (capture && !permission) throw new SecurityException("test permission denied");
            final Stream stream = new Stream(capture, bytes, channels, encoding); final long id = ++sequence;
            streams.put(id, stream); last = id;
            if (!capture) {
                Thread consumer = new Thread(new Runnable() { public void run() {
                    while (true) {
                        synchronized (stream) {
                            if (!stream.open) return;
                            stream.active = stream.running && !stream.queue.isEmpty();
                            if (stream.active) {
                                int amount = Math.min(stream.queue.size(), stream.frame * 16);
                                for (int i = 0; i < amount; i++) stream.consumed.write(stream.queue.removeFirst());
                                stream.frames += amount / stream.frame; stream.notifyAll();
                            }
                        }
                        try { Thread.sleep(2); } catch (InterruptedException stopped) { return; }
                    }
                } }, "explicit test PCM consumer"); consumer.setDaemon(true); consumer.start();
            }
            return id;
        }
        private Stream stream(long id) { Stream value = streams.get(id); if (value == null) throw new IllegalStateException("bad test handle"); return value; }
        public void start(long id) { Stream s = stream(id); synchronized (s) { s.running = true; s.notifyAll(); } }
        public void stop(long id) { Stream s = stream(id); synchronized (s) { s.running = false; s.active = false; s.interrupt++; s.notifyAll(); } }
        public void flush(long id) { Stream s = stream(id); synchronized (s) { s.queue.clear(); s.interrupt++; s.notifyAll(); } }
        public void requestFinish(long id) {
            // 此驱动不重采样，因此没有尾帧；真实转换尾部由另一个 JNI/core 回归覆盖。
            FinishGate gate = finishGate;
            if (gate != null) {
                synchronized (gate) { if (gate.claimed) return; gate.claimed = true; }
                gate.entered.countDown();
                try { gate.release.await(); }
                catch (InterruptedException failure) { Thread.currentThread().interrupt(); throw new IllegalStateException(failure); }
                if (gate.fail) throw new IllegalStateException("retired finish request");
            }
        }
        public void close(long id) { Stream s = stream(id); synchronized (s) { s.open = false; s.running = false; s.active = false; s.interrupt++; s.notifyAll(); } }
        public void drain(long id) { Stream s = stream(id); synchronized (s) {
            while (s.open && !s.failed && !s.queue.isEmpty()) waitOn(s);
        } }
        public int read(long id, byte[] bytes, int off, int len) { return transfer(id, bytes, off, len, true); }
        public int write(long id, byte[] bytes, int off, int len) { return transfer(id, bytes, off, len, false); }
        private int transfer(long id, byte[] bytes, int off, int len, boolean read) {
            Stream s = stream(id); synchronized (s) {
                long epoch = s.interrupt; int total = 0;
                while (total < len && s.open && !s.failed && s.interrupt == epoch) {
                    int available = read ? s.queue.size() : s.capacity - s.queue.size();
                    int amount = Math.min(len - total, available) / s.frame * s.frame;
                    for (int i = 0; i < amount; i++) { if (read) bytes[off + total + i] = s.queue.removeFirst(); else s.queue.add(bytes[off + total + i]); }
                    total += amount; s.notifyAll(); if (total < len) waitOn(s);
                }
                return total;
            }
        }
        private static void waitOn(Stream s) { try { s.wait(); } catch (InterruptedException failure) { Thread.currentThread().interrupt(); throw new IllegalStateException(failure); } }
        public int available(long id) { Stream s = stream(id); synchronized (s) { return s.capture ? s.queue.size() : s.capacity - s.queue.size(); } }
        public int bufferSize(long id) { return stream(id).capacity; }
        public int state(long id) { Stream s = stream(id); synchronized (s) { return (s.open ? 1 : 0) | (s.running ? 2 : 0) | (s.active ? 4 : 0) | (s.failed ? 8 : 0); } }
        public long framePosition(long id) { Stream s = stream(id); synchronized (s) { return s.frames; } }
        void supply(long id, byte[] bytes) { Stream s = stream(id); synchronized (s) {
            for (byte b : bytes) s.queue.add(b); s.frames += bytes.length / s.frame; s.active = s.running; s.notifyAll();
        } }
        void fail(long id) { Stream s = stream(id); synchronized (s) { s.failed = true; s.notifyAll(); } }
        byte[] bytes(long id) { Stream s = stream(id); synchronized (s) { return s.consumed.toByteArray(); } }
        int queued(long id) { Stream s = stream(id); synchronized (s) { return s.queue.size(); } }
    }
}
