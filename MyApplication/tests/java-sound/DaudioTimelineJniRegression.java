/* 真实Java/JNI/平台源的尾部时钟对照。系统替身只在实际提交新帧时推进延迟后位置，
 * 模拟已实测的0返回停滞；旧0025应在原Java drain自保后精确77，不修改夹具判断。 */
package com.sun.media.sound;

import javax.sound.sampled.AudioFormat;
import javax.sound.sampled.AudioSystem;
import javax.sound.sampled.DataLine;
import javax.sound.sampled.SourceDataLine;

public final class DaudioTimelineJniRegression {
    private static native void setDelayFrames(int frames);
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    public static void main(String[] args) throws Exception {
        boolean old = args.length == 1 && "--old-timeline-control".equals(args[0]);
        check(Platform.isDirectAudioEnabled(), "actual DAUDIO feature");
        setDelayFrames(1000);
        AudioFormat format = new AudioFormat(48000, 16, 2, true, false);
        SourceDataLine line = (SourceDataLine)AudioSystem.getLine(new DataLine.Info(SourceDataLine.class, format));
        try {
            line.open(format, 4096); line.start();
            byte[] pcm = new byte[1200 * 4];
            java.util.Arrays.fill(pcm, (byte)0x21);
            check(line.write(pcm, 0, pcm.length) == pcm.length, "all original user PCM written");
            line.drain();
            long position = line.getLongFramePosition();
            if (old && position == 200) {
                System.out.println("EXPECTED-OLD-TIMELINE-DEFECT: 1200 user frames submitted, real delayed timestamp stuck at200 after zero returns");
                line.close(); System.exit(77);
            }
            check(position == 1200, "actual user end not reached: " + position);
            line.stop(); line.flush();
            check(line.getLongFramePosition() == 1200, "Flush preserves Java origin");
            line.start();
            check(line.write(pcm, 0, pcm.length) == pcm.length, "second full write");
            line.drain();
            check(line.getLongFramePosition() == 2400, "Flush resets system clock without counting silence");
            System.out.println("PASS real Java/JNI tail mapping: actual delayed presentation reaches user end, silence excluded, second drain after Flush reset");
        } finally { line.close(); }
        if (old) throw new AssertionError("old timeline unexpectedly passed");
    }
}
