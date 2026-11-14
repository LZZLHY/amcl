package com.amcl.audio;

import javax.sound.sampled.*;

/**
 * PCM 播放流。Java 线程完成有界格式/增益/声像转换，实时回调只消费平台环形缓冲。
 * mono 明确展开 stereo，因此 Verity 的 PAN 对单声道语音同样有效。
 */
class OhosSourceDataLine extends OhosDataLine implements SourceDataLine {
    // 控件可能由 UI/模组线程修改，写 PCM 的线程通过相同监视器获得最新值。
    private final FloatControl gain = new FloatControl(FloatControl.Type.MASTER_GAIN, -80, 6, 0.1f, -1, 0, "dB") {
        public synchronized void setValue(float value) { super.setValue(value); }
        public synchronized float getValue() { return super.getValue(); }
    };
    private final FloatControl pan = new FloatControl(FloatControl.Type.PAN, -1, 1, 0.01f, -1, 0, "") {
        public synchronized void setValue(float value) { super.setValue(value); }
        public synchronized float getValue() { return super.getValue(); }
    };
    private final BooleanControl mute = new BooleanControl(BooleanControl.Type.MUTE, false) {
        public synchronized void setValue(boolean value) { super.setValue(value); }
        public synchronized boolean getValue() { return super.getValue(); }
    };
    OhosSourceDataLine(OhosMixer mixer, AudioFormat format) { super(mixer, format, false); }
    public Line.Info getLineInfo() { return new DataLine.Info(SourceDataLine.class, format); }
    public void open(AudioFormat format) throws LineUnavailableException { open(format, AudioFormats.defaultBuffer(format)); }
    public void open(AudioFormat format, int bytes) throws LineUnavailableException { openFormat(format, bytes); }
    public Control[] getControls() { return new Control[]{gain, pan, mute}; }

    public int write(byte[] data, int offset, int length) {
        AudioFormat current = format; AudioFormats.range(data, offset, length, current.getFrameSize());
        long value = requireHandle(); if (length == 0) return 0;
        long operation = transferEpoch;
        int total = 0, frame = current.getFrameSize();
        // 单次转换上限 16KiB 输入，避免大 TTS 音频产生等长临时副本。
        while (total < length && handle == value && transferEpoch == operation) {
            int size = Math.min(length - total, Math.max(frame, 16384 / frame * frame));
            byte[] converted = convert(data, offset + total, size, current);
            int written;
            try { written = backend.write(value, converted, 0, converted.length); }
            catch (RuntimeException failure) { if (handle == 0) return total; throw failure; }
            if (written < 0 || written > converted.length || written % (frame * nativeScale()) != 0)
                throw new IllegalStateException("Platform returned invalid PCM write count");
            total += written / nativeScale();
            if (written != converted.length) break;
        }
        if (handle == value) observe(); return total;
    }
    /** 输出 canonical little endian stereo；对浮点无穷/NaN 作有界静音，防止污染混音链。 */
    private byte[] convert(byte[] input, int offset, int length, AudioFormat current) {
        int sample = current.getSampleSizeInBits() / 8;
        int channels = current.getChannels();
        int frames = length / current.getFrameSize();
        byte[] output = new byte[frames * sample * 2];
        double volume = mute.getValue() ? 0 : Math.pow(10, gain.getValue() / 20.0);
        float balance = pan.getValue();
        double left = volume * (balance > 0 ? 1 - balance : 1);
        double right = volume * (balance < 0 ? 1 + balance : 1);
        for (int f = 0; f < frames; f++) for (int c = 0; c < 2; c++) {
            int source = offset + f * current.getFrameSize() + (channels == 1 ? 0 : c * sample);
            int raw = 0;
            for (int b = 0; b < sample; b++) raw |= (input[source + (current.isBigEndian() ? sample - 1 - b : b)] & 255) << (8 * b);
            double value = sample == 2 ? (short) raw / 32768.0 : Float.intBitsToFloat(raw);
            if (Double.isNaN(value) || Double.isInfinite(value)) value = 0;
            value = Math.max(-1, Math.min(1, value * (c == 0 ? left : right)));
            int bits = sample == 2 ? Math.max(-32768, Math.min(32767, (int) Math.round(value * 32768))) : Float.floatToIntBits((float) value);
            int target = (f * 2 + c) * sample;
            for (int b = 0; b < sample; b++) output[target + b] = (byte) (bits >>> (8 * b));
        }
        return output;
    }
}
