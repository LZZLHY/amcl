/* 真正Linux JVM/原TargetDataLine/原JNI与Capture后端的资格。
 * 平台替身交付固定PCM，验证数组边界和异常合同；不代替麦克风授权/硬件设备验证。 */
package com.sun.media.sound;

import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.Arrays;
import javax.sound.sampled.AudioFormat;
import javax.sound.sampled.AudioSystem;
import javax.sound.sampled.DataLine;
import javax.sound.sampled.LineUnavailableException;
import javax.sound.sampled.TargetDataLine;

public final class DaudioCaptureJniRegression {
    private static final AudioFormat FORMAT = new AudioFormat(48000, 16, 1, true, true);
    private static native void configure(boolean route, boolean allowed);
    private static native void feed(byte[] pcm);
    private static native void fault(String operation);
    private static native int[] stats();

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    private static TargetDataLine open() throws Exception {
        TargetDataLine line = (TargetDataLine)AudioSystem.getLine(new DataLine.Info(TargetDataLine.class, FORMAT));
        line.open(FORMAT, 128);
        return line;
    }

    private static IllegalStateException error(Runnable action, String operation) {
        try { action.run(); } catch (IllegalStateException expected) {
            check(expected.getMessage().contains(operation) && expected.getMessage().contains("code=3"), "native code lost: " + expected);
            return expected;
        }
        throw new AssertionError("missing Capture " + operation + " failure");
    }

    private static int singleNativeRead(TargetDataLine line, byte[] bytes, int offset, int length) throws Exception {
        Class<?> owner = line.getClass(); Field id = null;
        while (owner != null && id == null) {
            try { id = owner.getDeclaredField("id"); } catch (NoSuchFieldException ignored) { owner = owner.getSuperclass(); }
        }
        check(id != null, "actual native DAUDIO id"); id.setAccessible(true);
        Method read = DirectAudioDevice.class.getDeclaredMethod("nRead", long.class, byte[].class, int.class, int.class, int.class);
        read.setAccessible(true);
        try { return (Integer)read.invoke(null, id.getLong(line), bytes, offset, length, 2); }
        catch (InvocationTargetException failure) {
            Throwable cause = failure.getCause();
            if (cause instanceof RuntimeException) throw (RuntimeException)cause;
            if (cause instanceof Error) throw (Error)cause;
            throw failure;
        }
    }

    private static void clean(String where) {
        int[] counts = stats();
        check(counts[0] == 0 && counts[1] == 0 && counts[2] == 0, "Capture leak after " + where);
    }

    public static void main(String[] args) throws Exception {
        boolean old = args.length == 1 && "--old-read-control".equals(args[0]);
        check(Platform.isDirectAudioEnabled(), "real DAUDIO feature");
        configure(true, true);
        try { cases(); }
        catch (AssertionError failure) {
            if (old && "unwritten native read tail changed".equals(failure.getMessage())) {
                System.out.println("EXPECTED-OLD-READ-DEFECT: partial Capture endian conversion corrupts untouched array tail");
                System.exit(77);
            }
            throw failure;
        }
        if (old) throw new AssertionError("old read unexpectedly passed");
    }

    private static void cases() throws Exception {
        byte[] input = new byte[16], bytes = new byte[48];
        for (int i = 0; i < input.length; ++i) input[i] = (byte)(i + 1);
        for (int i = 0; i < bytes.length; ++i) bytes[i] = (byte)(i * 7 + 3);
        byte[] before = bytes.clone();
        TargetDataLine partial = open(); partial.start(); feed(input);
        check(singleNativeRead(partial, bytes, 4, 32) == 16, "actual partial native read");
        for (int i = 0; i < 16; ++i) check(bytes[i + 4] == input[i ^ 1], "received PCM endian conversion");
        for (int i = 0; i < bytes.length; ++i)
            if (i < 4 || i >= 20) check(bytes[i] == before[i], "unwritten native read tail changed");
        before = bytes.clone();
        check(singleNativeRead(partial, bytes, 4, 32) == 0 && Arrays.equals(before, bytes), "empty read leaves array unchanged");
        check(partial.getLongFramePosition() == 8, "position counts actual capture frames");
        feed(input); byte[] normal = new byte[16];
        check(partial.read(normal, 0, normal.length) == normal.length, "public TargetDataLine read");
        for (int i = 0; i < 16; ++i) check(normal[i] == input[i ^ 1], "public Java big-endian PCM");
        partial.stop(); partial.flush(); partial.close(); partial.close(); clean("partial/normal/double close");

        configure(true, false);
        try { open(); throw new AssertionError("permission denial opened Capturer"); }
        catch (LineUnavailableException expected) { /* 不伪装成功或向open外抛未声明异常。 */ }
        configure(true, true); clean("permission denied");
        final TargetDataLine start = open(); fault("CaptureStart");
        error(start::start, "Start"); check(!start.isRunning(), "Capture Start rollback");
        fault(""); start.close(); clean("Start");
        final TargetDataLine stop = open(); stop.start(); fault("CapturePause");
        error(stop::close, "Stop"); check(!stop.isOpen(), "Capture close finally");
        fault(""); stop.close(); clean("Stop failure then close");
        final TargetDataLine failed = open(); failed.start(); feed(input); failed.read(new byte[16], 0, 16);
        fault("CaptureAsyncError");
        error(() -> failed.read(new byte[16], 0, 16), "read");
        fault(""); failed.close(); clean("read error");
        final TargetDataLine release = open(); release.start(); fault("CaptureRelease");
        error(release::close, "Close"); check(!release.isOpen(), "Release error still closes Java state");
        release.close(); check(stats()[0] == 0 && stats()[1] == 1, "only unacknowledged Capture platform object retained");
        System.out.println("PASS real Capture Java/JNI: partial/empty tail, endian conversion, frame position, permission denial, Start rollback, Stop/finally close, native read error and Release failure");
    }
}
