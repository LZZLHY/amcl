package com.amcl.audio;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import javax.sound.sampled.*;

/**
 * 同进程默认 Mixer。每条 line 独立拥有流；平台统一管理实际采集共享和资源上限。
 * Mixer 不声称硬件同步、Port 或 MIDI 能力；关闭只退休本 Mixer 已创建的流。
 */
final class OhosMixer implements Mixer {
    static final Mixer.Info INFO = new Mixer.Info("AMCL OHAudio", "AMCL", "OHOS PCM playback and capture", "1") { };
    final AudioBackend backend;
    private final List<OhosDataLine> lines = new ArrayList<OhosDataLine>();
    private final CopyOnWriteArrayList<LineListener> listeners = new CopyOnWriteArrayList<LineListener>();
    private volatile boolean open;
    OhosMixer(AudioBackend backend) { this.backend = backend; }
    public Mixer.Info getMixerInfo() { return INFO; }
    public Line.Info getLineInfo() { return new Line.Info(Mixer.class); }
    private Line.Info[] infos(boolean source) {
        AudioFormat[] formats = AudioFormats.supported();
        return source ? new Line.Info[]{new DataLine.Info(SourceDataLine.class, formats, 1, AudioFormats.MAX_BUFFER),
            new DataLine.Info(Clip.class, formats, 1, AudioFormats.MAX_BUFFER)}
            : new Line.Info[]{new DataLine.Info(TargetDataLine.class, formats, 1, AudioFormats.MAX_BUFFER)};
    }
    public Line.Info[] getSourceLineInfo() { return infos(true); }
    public Line.Info[] getTargetLineInfo() { return infos(false); }
    private Line.Info[] filter(Line.Info wanted, boolean source) {
        List<Line.Info> result = new ArrayList<Line.Info>();
        for (Line.Info candidate : infos(source)) if (matches(wanted, candidate)) result.add(candidate);
        return result.toArray(new Line.Info[result.size()]);
    }
    /**
     * AudioSystem.getClip() 先用采样率为 NOT_SPECIFIED 的 PCM 模板取未打开的 Clip。
     * AudioFormat.matches 只把参数中的 NOT_SPECIFIED 当通配，因此必须用具体能力匹配请求模板；
     * DataLine.Info 默认反向调用会把未知采样率当实值，导致标准 getClip 在 open 前就被拒绝。
     * 此处仍要求模板至少对应表内一种真实格式，并沿用 DataLine.Info 的类型与缓冲边界。
     */
    private boolean matches(Line.Info wanted, Line.Info candidate) {
        if (!(wanted instanceof DataLine.Info)) return wanted.matches(candidate);
        if (!wanted.getClass().isInstance(candidate) || !wanted.getLineClass().isAssignableFrom(candidate.getLineClass())) return false;
        DataLine.Info request = (DataLine.Info) wanted, capability = (DataLine.Info) candidate;
        if (request.getMaxBufferSize() >= 0 && capability.getMaxBufferSize() >= 0
            && request.getMaxBufferSize() > capability.getMaxBufferSize()) return false;
        if (request.getMinBufferSize() >= 0 && capability.getMinBufferSize() >= 0
            && request.getMinBufferSize() < capability.getMinBufferSize()) return false;
        for (AudioFormat requested : request.getFormats()) {
            if (requested == null) continue;
            boolean supported = false;
            for (AudioFormat provided : capability.getFormats()) if (provided.matches(requested)) { supported = true; break; }
            if (!supported) return false;
        }
        return true;
    }
    public Line.Info[] getSourceLineInfo(Line.Info info) { return filter(info, true); }
    public Line.Info[] getTargetLineInfo(Line.Info info) { return filter(info, false); }
    public boolean isLineSupported(Line.Info info) {
        if (info == null) return false;
        return getSourceLineInfo(info).length != 0 || getTargetLineInfo(info).length != 0;
    }
    public synchronized Line getLine(Line.Info info) throws LineUnavailableException {
        if (!isLineSupported(info)) throw new IllegalArgumentException("Unsupported AMCL line: " + info);
        AudioFormat format = AudioFormats.DEFAULT;
        if (info instanceof DataLine.Info) {
            for (AudioFormat candidate : ((DataLine.Info) info).getFormats())
                if (AudioFormats.supported(candidate)) format = candidate;
        }
        Class<?> kind = info.getLineClass();
        OhosDataLine line = kind == Clip.class ? new OhosClip(this, format)
            : kind == TargetDataLine.class ? new OhosTargetDataLine(this, format)
            : new OhosSourceDataLine(this, format);
        return line;
    }
    public int getMaxLines(Line.Info info) { return isLineSupported(info) ? AudioSystem.NOT_SPECIFIED : 0; }
    /** 只持有当前打开的 line；反复枚举/创建/关闭不能在全局 Mixer 中永久保留对象。 */
    synchronized void opened(OhosDataLine line) { if (!lines.contains(line)) lines.add(line); }
    synchronized void closed(OhosDataLine line) { lines.remove(line); }
    private synchronized Line[] opened(boolean source) {
        List<Line> result = new ArrayList<Line>();
        for (OhosDataLine line : lines) if (line.isOpen() && line.capture != source) result.add(line);
        return result.toArray(new Line[result.size()]);
    }
    public Line[] getSourceLines() { return opened(true); }
    public Line[] getTargetLines() { return opened(false); }
    public boolean isSynchronizationSupported(Line[] requested, boolean maintainSync) { return false; }
    public void synchronize(Line[] requested, boolean maintainSync) { throw new IllegalArgumentException("Hardware synchronization unavailable"); }
    public void unsynchronize(Line[] requested) { throw new IllegalArgumentException("Hardware synchronization unavailable"); }
    public void open() { if (!open) { open = true; event(LineEvent.Type.OPEN); } }
    public boolean isOpen() { return open || getSourceLines().length != 0 || getTargetLines().length != 0; }
    public void close() {
        OhosDataLine[] snapshot;
        synchronized (this) { snapshot = lines.toArray(new OhosDataLine[lines.size()]); }
        boolean was = isOpen();
        for (OhosDataLine line : snapshot) line.close();
        open = false; if (was) event(LineEvent.Type.CLOSE);
    }
    private void event(LineEvent.Type type) {
        LineEvent event = new LineEvent(this, type, 0);
        for (LineListener listener : listeners) try { listener.update(event); } catch (RuntimeException ignored) { }
    }
    public Control[] getControls() { return new Control[0]; }
    public boolean isControlSupported(Control.Type type) { return false; }
    public Control getControl(Control.Type type) { throw new IllegalArgumentException("No mixer-level control: " + type); }
    public void addLineListener(LineListener listener) { if (listener == null) throw new NullPointerException("listener"); listeners.addIfAbsent(listener); }
    public void removeLineListener(LineListener listener) { listeners.remove(listener); }
}
