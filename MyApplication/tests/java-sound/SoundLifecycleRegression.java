/* 直接运行对应上游完整 AbstractLine/DataLine/Mixer 的候选 class，验证真实 Java
 * 所有权/事件与异常路径；不调用系统音频或以纯模拟结果授予目标播放资格。 */
package com.sun.media.sound;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import javax.sound.sampled.AudioFormat;
import javax.sound.sampled.AudioSystem;
import javax.sound.sampled.Control;
import javax.sound.sampled.DataLine;
import javax.sound.sampled.Line;
import javax.sound.sampled.LineEvent;
import javax.sound.sampled.LineUnavailableException;
import javax.sound.sampled.Mixer;

public final class SoundLifecycleRegression {
    private static final AudioFormat FORMAT = new AudioFormat(48000, 16, 2, true, false);
    private static final DataLine.Info INFO = new DataLine.Info(TestLine.class, FORMAT);

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    /** 原样抛同一个未受检异常，便于验证首因身份与 suppressed 顺序。 */
    private static void fail(Throwable failure) {
        if (failure instanceof RuntimeException) throw (RuntimeException) failure;
        if (failure != null) throw (Error) failure;
    }

    private static Throwable thrown(Runnable action) {
        try { action.run(); } catch (RuntimeException | Error failure) { return failure; }
        throw new AssertionError("expected failure");
    }

    private static final class TestMixer extends AbstractMixer {
        int opens, closes, starts, stops;
        Throwable stopFailure, closeFailure;

        TestMixer() {
            super(new Mixer.Info("lifecycle", "AMCL", "failure regression", "1") {},
                  new Control[0], new Line.Info[] {INFO}, new Line.Info[0]);
        }
        @Override public Line getLine(Line.Info info) { return new TestLine(this); }
        @Override public int getMaxLines(Line.Info info) { return AudioSystem.NOT_SPECIFIED; }
        @Override protected void implOpen() { opens++; }
        @Override protected void implClose() { closes++; fail(closeFailure); }
        @Override protected void implStart() { starts++; }
        @Override protected void implStop() { stops++; fail(stopFailure); }
    }

    private static final class TestLine extends AbstractDataLine {
        int opens, closes, starts, stops;
        long position = 100;
        Throwable startFailure, stopFailure, closeFailure, positionFailure;
        final List<LineEvent.Type> events = new CopyOnWriteArrayList<LineEvent.Type>();

        TestLine(TestMixer mixer) {
            super(INFO, mixer, new Control[0], FORMAT, 4096);
            addLineListener(event -> events.add(event.getType()));
        }
        @Override void implOpen(AudioFormat requested, int size) { opens++; format = requested; bufferSize = size; }
        @Override void implClose() { closes++; fail(closeFailure); }
        @Override void implStart() {
            starts++;
            // 故意在已部分开始之后失败，不能只测试完全未改变状态的理想失败。
            setActive(true); setStarted(true); fail(startFailure);
        }
        @Override void implStop() { stops++; fail(stopFailure); setActive(false); setStarted(false); }
        @Override public long getLongFramePosition() { fail(positionFailure); return position; }

        void awaitEvents(LineEvent.Type... expected) throws Exception {
            long deadline = System.nanoTime() + 2000000000L;
            while (events.size() < expected.length && System.nanoTime() < deadline) Thread.sleep(5);
            check(events.size() == expected.length, "event count: " + events);
            for (int i = 0; i < expected.length; i++) check(events.get(i) == expected[i], "event order: " + events);
        }
    }

    public static void main(String[] args) throws Exception {
        boolean oldControl = args.length == 1 && "--old-control".equals(args[0]);
        try {
            runCases();
        } catch (AssertionError error) {
            // 原版负控只能因已知的缺失清理失败，不能把任意异常/编译错误当成反例成立。
            if (oldControl && "Start suppressed cleanup order".equals(error.getMessage())) {
                System.out.println("EXPECTED-OLD-DEFECT: partial Start cleanup and suppressed exceptions absent");
                System.exit(77);
            }
            throw error;
        }
        if (oldControl) throw new AssertionError("old control unexpectedly passed");
    }

    private static void runCases() throws Exception {
        TestMixer mixer = new TestMixer();
        TestLine line = new TestLine(mixer);
        line.open(FORMAT, 4096); line.start(); line.stop(); line.close(); line.close(); mixer.close();
        check(line.opens == 1 && line.closes == 1 && line.starts == 1 && line.stops == 1, "normal native ownership");
        check(mixer.opens == 1 && mixer.closes == 1 && !mixer.isOpen() && !line.isOpen(), "normal mixer ownership");
        line.awaitEvents(LineEvent.Type.OPEN, LineEvent.Type.START, LineEvent.Type.STOP, LineEvent.Type.CLOSE);

        final TestMixer startMixer = new TestMixer();
        final TestLine startLine = new TestLine(startMixer);
        startLine.open(FORMAT, 4096);
        startLine.startFailure = new IllegalStateException("native Start");
        startLine.stopFailure = new IllegalStateException("rollback native Stop");
        startMixer.stopFailure = new AssertionError("rollback mixer Stop");
        Throwable start = thrown(startLine::start);
        check(start == startLine.startFailure, "preserve Start identity");
        check(start.getSuppressed().length == 2 && start.getSuppressed()[0] == startLine.stopFailure &&
              start.getSuppressed()[1] == startMixer.stopFailure, "Start suppressed cleanup order");
        check(!startLine.isRunning() && !startLine.isActive() && !startLine.isStartedRunning(), "Start rollback state");
        startMixer.stopFailure = null; startLine.stopFailure = null; startLine.close();
        check(startLine.closes == 1 && startMixer.closes == 1, "Start failure remains closeable");
        startLine.awaitEvents(LineEvent.Type.OPEN, LineEvent.Type.START, LineEvent.Type.STOP, LineEvent.Type.CLOSE);

        final TestMixer stopMixer = new TestMixer();
        final TestLine stopLine = new TestLine(stopMixer);
        stopLine.open(FORMAT, 4096); stopLine.start();
        stopLine.stopFailure = new IllegalStateException("native Pause");
        Throwable stop = thrown(stopLine::stop);
        check(stop == stopLine.stopFailure && !stopLine.isRunning() && !stopLine.isStartedRunning(), "Stop reports and commits state");
        stopLine.close(); stopLine.close();
        check(stopLine.stops == 1 && stopLine.closes == 1 && stopMixer.closes == 1, "Stop failure then close/double close");
        stopLine.awaitEvents(LineEvent.Type.OPEN, LineEvent.Type.START, LineEvent.Type.STOP, LineEvent.Type.CLOSE);

        final TestMixer closeMixer = new TestMixer();
        final TestLine closeLine = new TestLine(closeMixer);
        closeLine.open(FORMAT, 4096); closeLine.start();
        closeLine.stopFailure = new IllegalStateException("close Stop");
        closeLine.closeFailure = new AssertionError("native Close");
        closeMixer.closeFailure = new IllegalStateException("mixer Close");
        Throwable close = thrown(closeLine::close);
        check(close == closeLine.stopFailure && close.getSuppressed().length == 2, "Close first exception and suppressed");
        check(close.getSuppressed()[0] == closeLine.closeFailure && close.getSuppressed()[1] == closeMixer.closeFailure,
              "Close suppressed identities");
        check(!closeLine.isOpen() && !closeMixer.isOpen() && closeMixer.getSourceLines().length == 0,
              "Close failure still releases owners");
        closeLine.close(); closeMixer.close();
        check(closeLine.closes == 1 && closeMixer.closes == 1, "Close failure no repeated native release");

        final TestMixer multi = new TestMixer();
        TestLine first = new TestLine(multi), second = new TestLine(multi);
        first.open(FORMAT, 4096); second.open(FORMAT, 4096); first.start(); second.start();
        first.stopFailure = new IllegalStateException("first line"); second.closeFailure = new AssertionError("second line");
        Throwable multiple = thrown(multi::close);
        check(multiple == first.stopFailure && multiple.getSuppressed().length == 1 &&
              multiple.getSuppressed()[0] == second.closeFailure, "Mixer close preserves all failures");
        check(first.closes == 1 && second.closes == 1 && multi.closes == 1 &&
              !first.isOpen() && !second.isOpen() && !multi.isOpen(), "Mixer closes every line once");

        final TestMixer positionMixer = new TestMixer();
        final TestLine positionLine = new TestLine(positionMixer);
        positionLine.open(FORMAT, 4096); positionLine.start();
        positionLine.positionFailure = new IllegalStateException("failed position query");
        check(thrown(positionLine::close) == positionLine.positionFailure, "position first failure");
        check(!positionLine.isOpen() && !positionLine.isRunning() && positionLine.closes == 1 &&
              positionMixer.closes == 1, "position exception cannot skip state/native release");
        positionLine.close();
        System.out.println("PASS real Java lifecycle: normal events, partial Start rollback, Stop propagation, close finally, suppressed identities, double-close, multi-line mixer ownership, failed position query");
    }
}
