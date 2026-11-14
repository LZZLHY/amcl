package com.amcl.audio;

import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;
import javax.sound.sampled.*;

/**
 * 标准流状态与监听器边界。Java 监视器只保护句柄发布和状态，绝不跨 native 阻塞操作持有。
 * 事件在每条流的守护线程串行派发；平台实时回调不会调用 JVM。关闭可从监听器重入。
 */
abstract class OhosDataLine implements DataLine {
    final OhosMixer mixer;
    final AudioBackend backend;
    final boolean capture;
    final Object lock = new Object();
    volatile AudioFormat format;
    volatile long handle;
    volatile boolean requestedRunning;
    volatile long transferEpoch;
    private volatile boolean active;
    private long finalFrames;
    private long observedFrames;
    private int bufferBytes;
    private volatile long generation;
    private ExecutorService events;
    private final CopyOnWriteArrayList<LineListener> listeners = new CopyOnWriteArrayList<LineListener>();
    OhosDataLine(OhosMixer mixer, AudioFormat format, boolean capture) {
        this.mixer = mixer; this.backend = mixer.backend; this.format = format; this.capture = capture;
    }
    /** 输出 mono 在平台侧使用 stereo，以提供真实 PAN；采集保持原通道。 */
    int nativeChannels() { return capture ? format.getChannels() : 2; }
    int nativeScale() { return nativeChannels() / format.getChannels(); }
    public void open() throws LineUnavailableException { openFormat(format, AudioFormats.defaultBuffer(format)); }
    void openFormat(AudioFormat requested, int bytes) throws LineUnavailableException {
        AudioFormats.require(requested); AudioFormats.buffer(requested, bytes);
        if (capture) {
            SecurityManager manager = System.getSecurityManager();
            if (manager != null) manager.checkPermission(new AudioPermission("record"));
        }
        synchronized (lock) {
            if (handle != 0) throw new IllegalStateException("Line is already open");
            AudioFormat previous = format; format = requested;
            try {
                int scale = nativeScale();
                if (bytes > AudioFormats.MAX_BUFFER / scale) throw new IllegalArgumentException("Native buffer exceeds 8 MiB");
                long opened = backend.open(capture, (int) requested.getSampleRate(), nativeChannels(), AudioFormats.encoding(requested), bytes * scale);
                if (opened == 0) throw new LineUnavailableException("Platform did not create an audio stream");
                int actual;
                try { actual = backend.bufferSize(opened) / scale; }
                catch (RuntimeException failure) { backend.close(opened); throw failure; }
                handle = opened; bufferBytes = actual; mixer.opened(this);
                finalFrames = 0; observedFrames = 0; requestedRunning = false; active = false; generation++; transferEpoch++;
                final long epoch = generation;
                events = Executors.newSingleThreadExecutor(new ThreadFactory() {
                    public Thread newThread(Runnable task) { Thread t = new Thread(task, "AMCL sound events"); t.setDaemon(true); return t; }
                });
                emit(LineEvent.Type.OPEN, 0);
                Thread monitor = new Thread(new Runnable() { public void run() { monitor(epoch); } }, "AMCL sound state");
                monitor.setDaemon(true); monitor.start();
            } catch (RuntimeException failure) { format = previous; throw failure; }
            catch (LineUnavailableException failure) { format = previous; throw failure; }
        }
    }
    /** 查询只观察当前句柄；失效不会被解释成一个新的空流。 */
    final long requireHandle() {
        long value = handle;
        if (value == 0) throw new IllegalStateException("Audio line is closed");
        return value;
    }
    private void monitor(long epoch) {
        while (handle != 0 && generation == epoch) {
            try { observe(epoch); Thread.sleep(10); }
            catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return; }
            catch (RuntimeException failure) { closeEpoch(epoch); return; }
        }
    }
    /** FAILED 是终止故障，显式 close 唤醒所有等待；不伪造一直返回零的工作设备。 */
    final void observe() { observe(generation); }
    private void observe(long epoch) {
        if (generation != epoch) return;
        long value = handle; if (value == 0) return;
        int state;
        try { state = backend.state(value); }
        catch (RuntimeException failure) { if (handle != value || generation != epoch) return; throw failure; }
        if ((state & 8) != 0 || (state & 1) == 0) { closeEpoch(epoch); return; }
        synchronized (lock) {
            if (handle != value || generation != epoch) return;
            boolean now = (state & 4) != 0;
            long frames = position(value);
            // 极短音频可能在两次状态采样间完整开始/结束。真实累计帧证明它确实流转过，
            // 仍派发对应 START/STOP，避免把轮询漏窗误当从未播放。
            if (!active && !now && frames > observedFrames) {
                emit(LineEvent.Type.START, observedFrames); emit(LineEvent.Type.STOP, frames);
            }
            if (active != now) {
                active = now;
                emit(now ? LineEvent.Type.START : LineEvent.Type.STOP, frames);
            }
            observedFrames = frames;
        }
    }
    public void start() {
        long value = requireHandle(); backend.start(value);
        synchronized (lock) { if (handle == value) requestedRunning = true; }
        observe();
    }
    public void stop() {
        long value = handle; if (value == 0) return;
        synchronized (lock) { if (handle == value) transferEpoch++; }
        // stop 的 native 实现保留队列；不能以 flush/close 代替停止来解除 write/read。
        try { backend.stop(value); }
        catch (RuntimeException failure) { if (handle != value) return; throw failure; }
        synchronized (lock) { if (handle == value) requestedRunning = false; }
        observe();
    }
    public void flush() {
        long value = handle;
        synchronized (lock) { if (handle == value) transferEpoch++; }
        if (value != 0) try { backend.flush(value); }
        catch (RuntimeException failure) { if (handle == value) throw failure; }
    }
    public void drain() {
        long value = handle;
        if (value != 0) try { backend.drain(value); }
        catch (RuntimeException failure) { if (handle == value) throw failure; }
    }
    public void close() { closeEpoch(-1); }
    /** 旧 monitor 只能退休自己观察的代次，不能在 close/reopen 交错后关闭新流。 */
    private void closeEpoch(long expected) {
        long value;
        ExecutorService retired;
        synchronized (lock) {
            value = handle; if (value == 0 || (expected >= 0 && generation != expected)) return;
            finalFrames = position(value); handle = 0; generation++; transferEpoch++; requestedRunning = false;
            if (!active && finalFrames > observedFrames) {
                emit(LineEvent.Type.START, observedFrames); emit(LineEvent.Type.STOP, finalFrames);
            }
            if (active) { active = false; emit(LineEvent.Type.STOP, finalFrames); }
            emit(LineEvent.Type.CLOSE, finalFrames); retired = events; events = null; lock.notifyAll();
        }
        // 先退休 Java 句柄，再让 native 关闭唤醒阻塞调用；close 不能等待 drain 清空。
        try { backend.close(value); } finally { mixer.closed(this); if (retired != null) retired.shutdown(); }
    }
    private long position(long value) {
        try { return backend.framePosition(value); } catch (RuntimeException ignored) { return finalFrames; }
    }
    public long getLongFramePosition() { long value = handle; return value == 0 ? finalFrames : position(value); }
    public int getFramePosition() { return (int) getLongFramePosition(); }
    public long getMicrosecondPosition() { return (long) (getLongFramePosition() * 1000000.0 / format.getFrameRate()); }
    public int available() {
        long value = handle; if (value == 0) return 0;
        try { return backend.available(value) / nativeScale(); }
        catch (RuntimeException failure) { if (handle == 0) return 0; throw failure; }
    }
    public int getBufferSize() { return bufferBytes; }
    public AudioFormat getFormat() { return format; }
    public boolean isOpen() { return handle != 0; }
    public boolean isRunning() {
        long value = handle; if (value == 0) return false;
        try { return (backend.state(value) & (1 | 2 | 8)) == (1 | 2); }
        catch (RuntimeException failure) { if (handle != value) return false; throw failure; }
    }
    public boolean isActive() { return isOpen() && active; }
    public float getLevel() { return AudioSystem.NOT_SPECIFIED; }
    public Control[] getControls() { return new Control[0]; }
    public boolean isControlSupported(Control.Type type) { for (Control c : getControls()) if (c.getType().equals(type)) return true; return false; }
    public Control getControl(Control.Type type) {
        for (Control c : getControls()) if (c.getType().equals(type)) return c;
        throw new IllegalArgumentException("Unsupported audio control: " + type);
    }
    public void addLineListener(LineListener listener) { if (listener == null) throw new NullPointerException("listener"); listeners.addIfAbsent(listener); }
    public void removeLineListener(LineListener listener) { listeners.remove(listener); }
    private void emit(final LineEvent.Type type, long frames) {
        final LineEvent event = new LineEvent(this, type, frames);
        ExecutorService dispatcher = events;
        if (dispatcher != null) dispatcher.execute(new Runnable() {
            public void run() { for (LineListener listener : listeners) try { listener.update(event); } catch (RuntimeException ignored) { } }
        });
    }
}
