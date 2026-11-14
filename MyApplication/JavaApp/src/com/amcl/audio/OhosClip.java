package com.amcl.audio;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.ArrayDeque;
import javax.sound.sampled.*;

/**
 * 内存 Clip：复用真实 SourceDataLine 内核，普通守护线程投递预装 PCM，不在系统音频回调读 Java 堆。
 * 媒体游标和平台累计帧分开；循环不会错误地把累计播放帧当作音频文件当前位置。
 */
final class OhosClip extends OhosSourceDataLine implements Clip {
    // 控制操作按调用取得锁的顺序完成，seek 等待旧 writer 时，stop/close/open 不能穿插后又被 seek 恢复。
    // pump 在投递期间不取得 controlLock，因此控制线程可以在不形成锁环的前提下等待投递退出。
    private final Object controlLock = new Object();
    private final Object clipLock = new Object();
    private volatile byte[] audio;
    private boolean playing;
    private boolean writing;
    private long writingOwner;
    private long epoch;
    // 与 open 的 epoch 分开：loop/start/stop/seek 会改变播放意图，旧 EOF 观察不能停止新意图。
    private long playbackRevision;
    private int cursor;
    private int loopStart;
    private int loopEnd;
    private int remaining;
    private boolean looping;
    private long queuedFrame;
    private final ArrayDeque<Segment> timeline = new ArrayDeque<Segment>();
    private static final class Segment {
        final long nativeStart;
        final int mediaStart;
        final int frames;
        final int repeats;
        Segment(long n, int m, int frames, int repeats) { nativeStart = n; mediaStart = m; this.frames = frames; this.repeats = repeats; }
    }
    OhosClip(OhosMixer mixer, AudioFormat format) { super(mixer, format); }
    public Line.Info getLineInfo() { return new DataLine.Info(Clip.class, format); }
    /** 无音频的 Clip 不能以默认 open 假装已装载；调用者须提供 PCM 或 AudioInputStream。 */
    public void open() throws LineUnavailableException { throw new IllegalArgumentException("Clip requires audio data"); }
    public void open(AudioFormat format, byte[] data, int offset, int length) throws LineUnavailableException {
        AudioFormats.require(format); AudioFormats.range(data, offset, length, format.getFrameSize());
        if (length > AudioFormats.MAX_BUFFER) throw new LineUnavailableException("Clip exceeds 8 MiB memory limit");
        byte[] copy = new byte[length]; System.arraycopy(data, offset, copy, 0, length);
        synchronized (controlLock) {
            synchronized (clipLock) {
                if (isOpen()) throw new IllegalStateException("Clip already open");
                super.open(format, AudioFormats.defaultBuffer(format));
                audio = copy; cursor = 0; loopStart = 0; loopEnd = getFrameLength() - 1; remaining = 0; looping = false;
                queuedFrame = 0; timeline.clear(); epoch++; playbackRevision++; playing = false; writing = false;
                final long owner = epoch;
                Thread pump = new Thread(new Runnable() { public void run() { pump(owner); } }, "AMCL clip playback");
                pump.setDaemon(true); pump.start();
            }
        }
    }
    public void open(AudioInputStream stream) throws LineUnavailableException, IOException {
        if (stream == null) throw new NullPointerException("stream");
        AudioFormats.require(stream.getFormat());
        ByteArrayOutputStream content = new ByteArrayOutputStream();
        byte[] block = new byte[8192 / stream.getFormat().getFrameSize() * stream.getFormat().getFrameSize()];
        for (;;) {
            int read = stream.read(block);
            if (read < 0) break;
            if (read == 0) throw new IOException("AudioInputStream made no progress");
            if (content.size() > AudioFormats.MAX_BUFFER - read) throw new LineUnavailableException("Clip exceeds 8 MiB memory limit");
            content.write(block, 0, read);
        }
        byte[] bytes = content.toByteArray(); open(stream.getFormat(), bytes, 0, bytes.length);
    }
    public int getFrameLength() { byte[] value = audio; return value == null ? AudioSystem.NOT_SPECIFIED : value.length / format.getFrameSize(); }
    public long getMicrosecondLength() { int frames = getFrameLength(); return frames < 0 ? AudioSystem.NOT_SPECIFIED : (long) (frames * 1000000.0 / format.getFrameRate()); }
    public void start() {
        synchronized (controlLock) {
            synchronized (clipLock) {
                requireHandle();
                if (playing) return;
                super.start(); playbackRevision++; playing = true; clipLock.notifyAll();
            }
        }
    }
    public void stop() {
        synchronized (controlLock) {
            synchronized (clipLock) { playbackRevision++; playing = false; remaining = 0; looping = false; clipLock.notifyAll(); }
            super.stop();
        }
    }
    /** seek 先停止阻塞写并等待旧投递退出，再 flush；不会让旧写在新位置后偷偷追加。 */
    public void setFramePosition(int frame) {
        reposition(frame);
    }
    /** Clip 保留原始媒体；flush 丢掉平台预取队列后按实际媒体游标重新投递，重基累计帧。 */
    public void flush() { synchronized (controlLock) { if (isOpen()) reposition(getFramePosition()); } }
    private void reposition(int frame) {
        boolean interrupted = false;
        synchronized (controlLock) {
            boolean resume;
            int repeats;
            synchronized (clipLock) {
                requireHandle();
                if (frame < 0 || frame > getFrameLength()) throw new IllegalArgumentException("Clip frame outside media");
                resume = playing; playing = false; playbackRevision++;
                prune(super.getLongFramePosition());
                Segment current = timeline.peekFirst();
                repeats = looping ? (current == null ? remaining : current.repeats) : 0;
            }
            super.stop();
            synchronized (clipLock) {
                // requestFinish 也计入本次投递；flush 必须在旧请求返回后才清理转换器，
                // 否则旧 EOF 请求可能在新 seek 的第一块 PCM 之后又补一次尾帧。
                while (writing && writingOwner == epoch) try { clipLock.wait(); } catch (InterruptedException signal) { interrupted = true; }
                super.flush(); cursor = frame; remaining = repeats;
                queuedFrame = super.getLongFramePosition(); timeline.clear();
                timeline.add(new Segment(queuedFrame, frame, 0, repeats));
                if (resume && isOpen()) { super.start(); playing = true; clipLock.notifyAll(); }
            }
        }
        if (interrupted) Thread.currentThread().interrupt();
    }
    public void setMicrosecondPosition(long micros) {
        if (micros < 0) throw new IllegalArgumentException("Negative media time");
        long frame = (long) (micros * format.getFrameRate() / 1000000.0);
        if (frame > Integer.MAX_VALUE) throw new IllegalArgumentException("Media time outside clip");
        setFramePosition((int) frame);
    }
    public void setLoopPoints(int start, int end) {
        synchronized (controlLock) {
            synchronized (clipLock) {
                int frames = getFrameLength(); int resolved = end == -1 ? frames - 1 : end;
                if (start < 0 || resolved < start || resolved >= frames) throw new IllegalArgumentException("Invalid clip loop points");
                loopStart = start; loopEnd = resolved;
            }
        }
    }
    public void loop(int count) {
        if (count < 0 && count != LOOP_CONTINUOUSLY) throw new IllegalArgumentException("Negative loop count");
        synchronized (controlLock) {
            synchronized (clipLock) { playbackRevision++; remaining = count; looping = count != 0; clipLock.notifyAll(); }
            start();
        }
    }
    public long getLongFramePosition() {
        synchronized (clipLock) {
            // 读取累计位置与媒体映射必须在同一锁区间，close/reopen 不能把两代数据拼在一起。
            long actual = super.getLongFramePosition();
            prune(actual);
            Segment segment = timeline.peekFirst();
            return segment == null ? cursor : segment.mediaStart + Math.max(0, Math.min(segment.frames, actual - segment.nativeStart));
        }
    }
    public int available() { return 0; }
    /** 仅在 clipLock 内消费已播放的时间段，保留当前段及其尚未发生的循环次数。 */
    private void prune(long actual) {
        while (timeline.size() > 1) {
            Segment first = timeline.removeFirst();
            if (timeline.peekFirst().nativeStart > actual) { timeline.addFirst(first); break; }
        }
    }
    public void close() {
        synchronized (controlLock) {
            synchronized (clipLock) { playing = false; epoch++; playbackRevision++; clipLock.notifyAll(); }
            super.close();
            synchronized (clipLock) { audio = null; }
        }
    }
    /** 旧句柄的延迟异常/中断只退休旧 pump；close/reopen 后不能由旧线程关闭新 Clip。 */
    private void closePump(long owner) {
        synchronized (controlLock) {
            synchronized (clipLock) { if (epoch != owner) return; }
            close();
        }
    }
    /** 工作线程一次仅提交一个小块；stop 保留已排队 PCM，close 通过 native 解除写/drain 等待。 */
    private void pump(long owner) {
        try {
            while (true) {
                byte[] bytes; int begin; int count; int repeats; boolean end; long value; long revision;
                synchronized (clipLock) {
                    while (epoch == owner && isOpen() && !playing) clipLock.wait();
                    if (epoch != owner || !isOpen()) return;
                    int frames = getFrameLength();
                    if (cursor == loopEnd + 1 && remaining != 0) {
                        cursor = loopStart; if (remaining > 0) remaining--;
                    }
                    end = cursor >= frames;
                    int limit = remaining != 0 && cursor <= loopEnd ? loopEnd + 1 : frames;
                    count = Math.min(1024, Math.max(0, limit - cursor));
                    begin = cursor; bytes = audio; writing = true; writingOwner = owner; repeats = remaining;
                    value = requireHandle(); revision = playbackRevision;
                    // 清理已消费的媒体映射，长循环不能积累与播放时长成正比的 Java 对象。
                    long actual = super.getLongFramePosition();
                    prune(actual);
                    if (!end) timeline.add(new Segment(queuedFrame, begin, count, repeats));
                }
                try {
                    if (end) {
                        // 重采样保留的最后一个输入样本，只有 finish 后才会变成完整的平台尾帧。
                        // 此请求仅通知 native worker，既不等待呈现，也不持有 clipLock；
                        // stopped-line 的阻塞 drain 会让 seek 等 writer 时形成死锁，不能用于此处。
                        backend.requestFinish(value);
                        synchronized (clipLock) {
                            if (epoch != owner) return;
                            if (playbackRevision == revision && playing && super.getLongFramePosition() >= queuedFrame) {
                                playing = false; looping = false; super.stop();
                            } else if (playbackRevision == revision && playing) clipLock.wait(10);
                        }
                    } else {
                        int written = super.write(bytes, begin * format.getFrameSize(), count * format.getFrameSize()) / format.getFrameSize();
                        synchronized (clipLock) {
                            if (epoch != owner) return;
                            cursor += written; queuedFrame += written;
                            if (written != count) {
                                timeline.removeLast(); timeline.add(new Segment(queuedFrame - written, begin, written, repeats));
                            }
                        }
                    }
                } finally {
                    synchronized (clipLock) {
                        // close/reopen 后新 pump 可能已写入；旧 finally 不能清掉新 writer 的标记。
                        if (writingOwner == owner) writing = false;
                        clipLock.notifyAll();
                    }
                }
            }
        } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); closePump(owner); }
        catch (RuntimeException failure) { closePump(owner); }
    }
}
