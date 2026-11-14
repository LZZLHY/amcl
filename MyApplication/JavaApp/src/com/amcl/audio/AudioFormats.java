package com.amcl.audio;

import java.util.ArrayList;
import java.util.List;
import javax.sound.sampled.AudioFormat;

/**
 * Java 与平台之间的明确 PCM 格式表。不同字节序在 Java 边界转换，采样率转换归真实平台流。
 * 对未列出的编码/声道/速率准确拒绝，不把任意压缩音频误当 PCM。
 */
final class AudioFormats {
    static final int MAX_BUFFER = 8 * 1024 * 1024;
    static final int[] RATES = {8000, 16000, 22050, 24000, 32000, 44100, 48000};
    static final AudioFormat DEFAULT = new AudioFormat(44100, 16, 2, true, false);
    private AudioFormats() { }
    static AudioFormat[] supported() {
        List<AudioFormat> formats = new ArrayList<AudioFormat>();
        for (int rate : RATES) for (int channels = 1; channels <= 2; channels++)
            for (boolean big : new boolean[]{false, true}) {
                formats.add(new AudioFormat(rate, 16, channels, true, big));
                formats.add(new AudioFormat(AudioFormat.Encoding.PCM_FLOAT, rate, 32, channels, channels * 4, rate, big));
            }
        return formats.toArray(new AudioFormat[formats.size()]);
    }
    static boolean supported(AudioFormat format) {
        if (format == null || (format.getChannels() != 1 && format.getChannels() != 2)) return false;
        boolean rate = false;
        for (int value : RATES) if (format.getSampleRate() == value) rate = true;
        int bits = format.getSampleSizeInBits();
        return rate && format.getFrameRate() == format.getSampleRate()
            && format.getFrameSize() == format.getChannels() * bits / 8
            && ((AudioFormat.Encoding.PCM_SIGNED.equals(format.getEncoding()) && bits == 16)
                || (AudioFormat.Encoding.PCM_FLOAT.equals(format.getEncoding()) && bits == 32));
    }
    static void require(AudioFormat format) {
        if (!supported(format)) throw new IllegalArgumentException("Unsupported AMCL PCM format: " + format);
    }
    static int encoding(AudioFormat format) { return format.getSampleSizeInBits() == 16 ? 1 : 2; }
    static int buffer(AudioFormat format, int bytes) {
        int frame = format.getFrameSize();
        if (bytes <= 0 || bytes > MAX_BUFFER || bytes % frame != 0)
            throw new IllegalArgumentException("Buffer must contain complete PCM frames within 8 MiB");
        return bytes;
    }
    static int defaultBuffer(AudioFormat format) {
        return ((int) format.getSampleRate() / 5) * format.getFrameSize();
    }
    static void range(byte[] data, int offset, int length, int frame) {
        if (data == null) throw new NullPointerException("data");
        if (offset < 0 || length < 0 || offset > data.length - length)
            throw new IndexOutOfBoundsException("PCM array range");
        if (length % frame != 0) throw new IllegalArgumentException("PCM length must contain complete frames");
    }
}
