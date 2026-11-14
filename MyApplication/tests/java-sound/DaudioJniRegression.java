/* 真正 Linux JVM → 原 JavaSound classes → 原 JNI → 自有 DAUDIO 的故障回归。
 * 只有最末端 OHAudio 是受控 SDK 接口替身；本测试不授予目标听感/硬件资格。 */
package com.sun.media.sound;

import java.util.concurrent.CopyOnWriteArrayList;
import java.util.List;
import javax.sound.sampled.AudioFormat;
import javax.sound.sampled.AudioSystem;
import javax.sound.sampled.DataLine;
import javax.sound.sampled.LineEvent;
import javax.sound.sampled.LineUnavailableException;
import javax.sound.sampled.Mixer;
import javax.sound.sampled.SourceDataLine;

public final class DaudioJniRegression {
    private static final AudioFormat FORMAT = new AudioFormat(48000, 16, 2, true, false);
    private static native void setFault(String operation);
    private static native int[] stats();

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    private static SourceDataLine line(Mixer mixer) throws Exception {
        SourceDataLine line = (SourceDataLine)mixer.getLine(new DataLine.Info(SourceDataLine.class, FORMAT));
        line.open(FORMAT, 4096);
        return line;
    }

    private static IllegalStateException stateError(Runnable action, String operation) {
        try { action.run(); } catch (IllegalStateException error) {
            check(error.getMessage().contains(operation) && error.getMessage().contains("code=3"), "preserve native code: " + error);
            return error;
        }
        throw new AssertionError("missing native " + operation + " failure");
    }

    private static void noLiveStreams(String where) {
        int[] counters = stats();
        check(counters[0] == 0 && counters[1] == 0, "resource leak after " + where);
    }

    public static void main(String[] args) throws Exception {
        boolean oldControl = args.length == 1 && "--old-jni-control".equals(args[0]);
        try { runCases(); }
        catch (AssertionError error) {
            if (oldControl && "missing native Start failure".equals(error.getMessage())) {
                System.out.println("EXPECTED-OLD-JNI-DEFECT: native Start failure was discarded");
                System.exit(77);
            }
            throw error;
        }
        if (oldControl) throw new AssertionError("old JNI unexpectedly passed");
    }

    private static void runCases() throws Exception {
        Mixer selected = null;
        for (Mixer.Info info : AudioSystem.getMixerInfo()) {
            if (info.getName().equals("OHAudio system output") || info.getName().equals("OHAudio system audio"))
                selected = AudioSystem.getMixer(info);
        }
        check(selected != null, "actual OHOS DAUDIO provider visible");
        final Mixer mixer = selected;
        // 同一 loader 内解析额外测试 JNI，未由应用类加载器另行 loadLibrary 抢占 jsound。
        setFault(""); noLiveStreams("enumeration");
        final SourceDataLine normal = line(mixer);
        List<LineEvent.Type> events = new CopyOnWriteArrayList<LineEvent.Type>();
        normal.addLineListener(event -> events.add(event.getType()));
        byte[] pcm = new byte[4800];
        for (int i = 0; i < pcm.length; i++) pcm[i] = (byte)(i * 17);
        normal.start(); check(normal.write(pcm, 0, pcm.length) == pcm.length, "full JNI write");
        normal.drain(); check(normal.getLongFramePosition() == pcm.length / FORMAT.getFrameSize(), "actual native frame count");
        normal.stop(); normal.flush(); normal.close(); normal.close(); noLiveStreams("normal and double-close");
        long deadline = System.nanoTime() + 2000000000L;
        while (events.size() < 3 && System.nanoTime() < deadline) Thread.sleep(5);
        check(events.size() == 3 && events.get(0) == LineEvent.Type.START && events.get(1) == LineEvent.Type.STOP &&
              events.get(2) == LineEvent.Type.CLOSE, "JNI normal events: " + events);

        final SourceDataLine start = line(mixer); setFault("Start");
        stateError(start::start, "Start"); check(!start.isRunning(), "failed Start cannot publish running");
        setFault(""); start.close(); noLiveStreams("Start rollback");

        final SourceDataLine stop = line(mixer); stop.start(); setFault("Pause");
        stateError(stop::stop, "Stop"); check(!stop.isRunning(), "failed Stop clears Java running state");
        setFault(""); stop.close(); stop.close(); noLiveStreams("Stop then close");

        final SourceDataLine close = line(mixer); close.start(); setFault("Pause");
        stateError(close::close, "Stop"); check(!close.isOpen(), "close finally closes Java state");
        setFault(""); close.close(); noLiveStreams("close throws original Stop");

        final SourceDataLine flush = line(mixer); flush.start(); flush.write(pcm, 0, pcm.length); flush.drain();
        setFault("Flush"); stateError(flush::flush, "Flush"); setFault(""); flush.close(); noLiveStreams("Flush failure");

        final SourceDataLine a = line(mixer), b = line(mixer); a.start(); b.start(); setFault("Pause");
        IllegalStateException all = stateError(mixer::close, "Stop");
        check(all.getSuppressed().length >= 1 && !a.isOpen() && !b.isOpen(), "mixer closes all JNI handles");
        setFault(""); noLiveStreams("multi-line close");

        setFault("SetSampleFormat");
        try { line(mixer); throw new AssertionError("open failure swallowed"); }
        catch (LineUnavailableException expected) { /* 公开 open 的原有受检异常合同保持。 */ }
        setFault(""); noLiveStreams("open LineUnavailableException");
        final SourceDataLine async = line(mixer); async.start(); async.write(pcm, 0, 4); setFault("AsyncError");
        stateError(() -> async.write(pcm, 0, pcm.length), "write");
        setFault(""); async.close(); noLiveStreams("asynchronous device error cannot become zero-byte busy loop");
        final SourceDataLine position = line(mixer); position.start(); position.write(pcm, 0, pcm.length); position.drain();
        setFault("GetAudioTimestampInfo"); stateError(() -> position.getLongFramePosition(), "position");
        setFault(""); position.close(); noLiveStreams("position reports first platform error without duplicating cleanup errors");
        // 真实 Release 失败在 wrapper 释放后抛出，并作为同次 Stop 首错的 suppressed。
        final SourceDataLine release = line(mixer); release.start(); setFault("Pause+Release");
        IllegalStateException releaseError = stateError(release::close, "Stop");
        check(!release.isOpen() && releaseError.getSuppressed().length == 1 &&
              releaseError.getSuppressed()[0].getMessage().contains("Close failed (code=3)"), "Release failure preserved after cleanup");
        int releaseCalls = stats()[2]; release.close(); check(stats()[2] == releaseCalls, "failed Release not repeated on double-close");
        check(stats()[0] == 0 && stats()[1] == 1, "only unacknowledged platform renderer retained");
        setFault("");
        System.out.println("PASS real Java/JNI/DAUDIO: write/drain/position, events, Start rollback, Stop propagation, finally close, double-close, Flush failure, multi-line suppressed cleanup, open contract");
    }
}
