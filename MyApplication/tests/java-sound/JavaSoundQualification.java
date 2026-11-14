import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.lang.management.ManagementFactory;
import java.lang.reflect.Field;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import javax.sound.midi.MetaMessage;
import javax.sound.midi.MidiDevice;
import javax.sound.midi.MidiEvent;
import javax.sound.midi.MidiMessage;
import javax.sound.midi.MidiSystem;
import javax.sound.midi.Receiver;
import javax.sound.midi.Sequence;
import javax.sound.midi.Sequencer;
import javax.sound.midi.ShortMessage;
import javax.sound.midi.Synthesizer;
import javax.sound.midi.Track;
import javax.sound.sampled.AudioFileFormat;
import javax.sound.sampled.AudioFormat;
import javax.sound.sampled.AudioInputStream;
import javax.sound.sampled.AudioSystem;
import javax.sound.sampled.DataLine;
import javax.sound.sampled.Line;
import javax.sound.sampled.Mixer;
import javax.sound.sampled.Port;
import javax.sound.sampled.SourceDataLine;
import javax.sound.sampled.TargetDataLine;

/**
 * 四代真实目标JavaSound资格夹具，class52。software只验证软件链并记录真实设备能力，
 * playback另外要求真实SourceDataLine的打开/写入/drain/位置推进/停止/重开，零设备绝不PASS。
 * 不打开麦克风或MIDI外设，不更改全局音量；播放只写短暂低幅度合成PCM。硬期限由进程外负责。
 */
public final class JavaSoundQualification {
    private static FileChannel log;
    private JavaSoundQualification() {}

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    /** 每阶段立即落盘，native加载/音频调用卡住时仍保留已完成的真实进度。 */
    private static void record(String key, Object value) throws IOException {
        String line = "SOUND " + key + "=" + String.valueOf(value).replace("\r", "\\r").replace("\n", "\\n") + "\n";
        ByteBuffer bytes = ByteBuffer.wrap(line.getBytes(StandardCharsets.UTF_8));
        while (bytes.hasRemaining()) log.write(bytes);
        log.force(false);
        System.out.print(line); System.out.flush();
    }

    /** 验证由JDK自身加载的native，避免应用ClassLoader主动load同一库导致重复装载污染。 */
    private static void nativeLibrary(int major) throws Exception {
        Class<?> platform = Class.forName("com.sun.media.sound.Platform");
        Field loaded = platform.getDeclaredField(major == 8 ? "loadedLibs" : "isNativeLibLoaded");
        loaded.setAccessible(true);
        boolean ready;
        if (major == 8) {
            int mask = loaded.getInt(null); ready = (mask & 1) != 0; record("nativeLibraryMask", mask);
            // class闭合与打开设备分开：此处不调用play，也不把类存在当作听到声音。
            Class.forName("sun.applet.AppletAudioClip");
            record("classicAppletAudioClass", "PRESENT");
        } else ready = loaded.getBoolean(null);
        record("nativeLibraryLoaded", ready);
        require(ready, "JavaSound native did not load");
    }

    /** 枚举只是能力观察，不把0个设备改称完整硬件实现。 */
    private static void devices() throws Exception {
        Mixer.Info[] mixers = AudioSystem.getMixerInfo();
        record("mixerCount", mixers.length);
        int outputs = 0, inputs = 0, ports = 0;
        for (int index = 0; index < mixers.length; ++index) {
            Mixer mixer = AudioSystem.getMixer(mixers[index]);
            record("mixer." + index + ".class", mixer.getClass().getName());
            record("mixer." + index + ".name", mixers[index].getName());
            for (Line.Info line : mixer.getSourceLineInfo()) {
                record("mixer." + index + ".source", line);
                if (SourceDataLine.class.isAssignableFrom(line.getLineClass())) ++outputs;
                if (Port.class.isAssignableFrom(line.getLineClass())) ++ports;
            }
            for (Line.Info line : mixer.getTargetLineInfo()) {
                record("mixer." + index + ".target", line);
                if (TargetDataLine.class.isAssignableFrom(line.getLineClass())) ++inputs;
                if (Port.class.isAssignableFrom(line.getLineClass())) ++ports;
            }
        }
        record("sourceLineDeclarations", outputs);
        record("targetLineDeclarations", inputs);
        record("portDeclarations", ports);
        record("nativePcmObservation", outputs == 0 ? "FEATURE-GAP:NO_SOURCE_LINE" : "ADVERTISED:REQUIRES_PLAYBACK");
        record("captureObservation", inputs == 0 ? "FEATURE-GAP:NO_TARGET_LINE" : "NOT-RUN:MICROPHONE_PERMISSION_AND_DEVICE_TEST_REQUIRED");
        record("portsObservation", ports == 0 ? "NO_PORT_PROVIDER:PLATFORM_MAPPING_REQUIRES_REVIEW" : "ADVERTISED:NOT-EXERCISED");
        MidiDevice.Info[] midi = MidiSystem.getMidiDeviceInfo();
        record("midiDeviceCount", midi.length);
        for (int index = 0; index < midi.length; ++index) {
            MidiDevice device = MidiSystem.getMidiDevice(midi[index]);
            record("midi." + index + ".class", device.getClass().getName());
            record("midi." + index + ".name", midi[index].getName());
            record("midi." + index + ".kind", device instanceof Sequencer ? "SOFTWARE_SEQUENCER" :
                device instanceof Synthesizer ? "SYNTHESIZER_PROVIDER" : "EXTERNAL_OR_OTHER_PROVIDER:NOT-OPENED");
        }
    }

    /** MIDI写/读走内存与真实Unicode文件URL，序列器不自动连接合成器或物理输出。 */
    private static void midi(Path root) throws Exception {
        Sequence source = new Sequence(Sequence.PPQ, 480);
        Track track = source.createTrack();
        track.add(new MidiEvent(new ShortMessage(ShortMessage.NOTE_ON, 0, 60, 64), 0));
        track.add(new MidiEvent(new ShortMessage(ShortMessage.NOTE_OFF, 0, 60, 0), 240));
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        require(MidiSystem.write(source, 1, bytes) > 0, "MIDI writer failed");
        Path file = root.resolve("测试 曲目.mid");
        Files.write(file, bytes.toByteArray(), StandardOpenOption.CREATE_NEW);
        Sequence parsed = MidiSystem.getSequence(file.toUri().toURL());
        require(parsed.getTracks().length == 1 && parsed.getTickLength() == 240 && parsed.getResolution() == 480,
            "MIDI roundtrip changed sequence");
        final AtomicInteger on = new AtomicInteger(), off = new AtomicInteger();
        final CountDownLatch ended = new CountDownLatch(1);
        Sequencer sequencer = MidiSystem.getSequencer(false);
        require(sequencer != null, "software sequencer missing");
        Receiver receiver = new Receiver() {
            @Override public void send(MidiMessage message, long timestamp) {
                if (!(message instanceof ShortMessage)) return;
                ShortMessage shortMessage = (ShortMessage) message;
                if (shortMessage.getCommand() == ShortMessage.NOTE_ON && shortMessage.getData2() != 0) on.incrementAndGet();
                if (shortMessage.getCommand() == ShortMessage.NOTE_OFF) off.incrementAndGet();
            }
            @Override public void close() {}
        };
        long finalTick;
        try {
            sequencer.open();
            sequencer.getTransmitter().setReceiver(receiver);
            sequencer.addMetaEventListener((MetaMessage message) -> { if (message.getType() == 47) ended.countDown(); });
            sequencer.setSequence(parsed); sequencer.setTempoInBPM(120); sequencer.start();
            require(ended.await(5, TimeUnit.SECONDS), "software sequencer made no terminal progress");
            finalTick = sequencer.getTickPosition();
            require(on.get() == 1 && off.get() >= 1 && finalTick >= 240, "software MIDI delivery incomplete");
        } finally { sequencer.stop(); sequencer.close(); receiver.close(); }
        record("midiBytes", bytes.size()); record("midiNoteOn", on.get()); record("midiNoteOff", off.get());
        record("midiFinalTick", finalTick); record("softwareMidi", "PASS");
    }

    private static byte[] readAll(AudioInputStream stream) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        byte[] buffer = new byte[4096]; int empty = 0;
        for (;;) {
            int count = stream.read(buffer);
            if (count < 0) return bytes.toByteArray();
            if (count == 0) { require(++empty < 16, "audio decoder stalled"); continue; }
            empty = 0; bytes.write(buffer, 0, count);
            require(bytes.size() <= 1048576, "unexpected unbounded decoded stream");
        }
    }

    /** PCM文件解析与符号/端序转换均比较真实字节，不用全零样本掩盖损坏。 */
    private static void files(Path root) throws Exception {
        AudioFormat format = new AudioFormat(8000, 16, 1, true, false);
        byte[] pcm = new byte[512];
        for (int index = 0; index < pcm.length; ++index) pcm[index] = (byte) (index * 37 + 11);
        for (AudioFileFormat.Type type : new AudioFileFormat.Type[]{AudioFileFormat.Type.WAVE, AudioFileFormat.Type.AIFF, AudioFileFormat.Type.AU}) {
            ByteArrayOutputStream encoded = new ByteArrayOutputStream();
            try (AudioInputStream input = new AudioInputStream(new ByteArrayInputStream(pcm), format, pcm.length / 2)) {
                require(AudioSystem.write(input, type, encoded) > 0, "audio writer missing: " + type);
            }
            Path file = root.resolve("测试 音频." + type.getExtension());
            Files.write(file, encoded.toByteArray(), StandardOpenOption.CREATE_NEW);
            try (AudioInputStream parsed = AudioSystem.getAudioInputStream(file.toUri().toURL());
                 AudioInputStream restored = AudioSystem.getAudioInputStream(format, parsed)) {
                require(restored.getFormat().matches(format) && Arrays.equals(pcm, readAll(restored)), "audio file roundtrip mismatch: " + type);
            }
            record("file." + type.getExtension() + ".bytes", encoded.size());
        }
        AudioFormat big = new AudioFormat(8000, 16, 1, true, true);
        try (AudioInputStream input = new AudioInputStream(new ByteArrayInputStream(pcm), format, pcm.length / 2);
             AudioInputStream swapped = AudioSystem.getAudioInputStream(big, input)) {
            byte[] result = readAll(swapped);
            require(result.length == pcm.length, "PCM conversion length changed");
            for (int index = 0; index < pcm.length; index += 2)
                require(result[index] == pcm[index + 1] && result[index + 1] == pcm[index], "PCM byte order conversion failed");
        }
        record("softwareAudioFiles", "PASS"); record("pcmEndianConversion", "PASS");
    }

    /** 写入有限低幅度PCM并要求drain后的帧位置推进；不把open成功当作消费了音频。 */
    private static void playback() throws Exception {
        AudioFormat[] formats = {new AudioFormat(44100, 16, 2, true, false), new AudioFormat(48000, 16, 1, true, false)};
        for (int pass = 0; pass < formats.length; ++pass) {
            AudioFormat format = formats[pass];
            DataLine.Info wanted = new DataLine.Info(SourceDataLine.class, format);
            if (!AudioSystem.isLineSupported(wanted)) {
                record("playback", "FEATURE-GAP:REQUIRED_PCM_FORMAT_UNAVAILABLE:" + format);
                throw new AssertionError("real JavaSound PCM backend/format is unavailable");
            }
            SourceDataLine line = (SourceDataLine) AudioSystem.getLine(wanted);
            try {
                line.open(format, 4096 * format.getFrameSize());
                require(line.getFormat().matches(format) && line.getBufferSize() > 0 && line.getBufferSize() % format.getFrameSize() == 0,
                    "opened PCM format/frame size differs");
                int frames = (int) (format.getSampleRate() / 4); // 250ms，两个格式总计500ms；不更改系统音量。
                byte[] pcm = new byte[frames * format.getFrameSize()];
                for (int frame = 0; frame < frames; ++frame) {
                    short sample = (short) (Math.sin(2 * Math.PI * 440 * frame / format.getSampleRate()) * 1000);
                    for (int channel = 0; channel < format.getChannels(); ++channel) {
                        int offset = frame * format.getFrameSize() + channel * 2;
                        pcm[offset] = (byte) sample; pcm[offset + 1] = (byte) (sample >> 8);
                    }
                }
                long before = line.getLongFramePosition();
                line.start(); int written = 0;
                while (written < pcm.length) {
                    int count = line.write(pcm, written, Math.min(pcm.length - written, 1024 * format.getFrameSize()));
                    require(count > 0 && count % format.getFrameSize() == 0, "PCM write stalled or split a frame"); written += count;
                }
                line.drain(); long after = line.getLongFramePosition();
                require(after - before >= frames, "drain did not advance consumed frame count");
                line.stop(); line.flush();
                record("playback." + pass + ".format", line.getFormat());
                record("playback." + pass + ".bytesWritten", written);
                record("playback." + pass + ".framesAdvanced", after - before);
                record("playback." + pass + ".availableAfterFlush", line.available());
            } finally { line.close(); }
        }
        record("playback", "PASS:JAVA_LINE_CONSUMPTION;PHYSICAL_AUDIBILITY_REQUIRES_DEVICE_EVIDENCE");
    }

    /** root、期望major与固定mode；由调用方保留native/退出/产物身份，失败不生成完成文件。 */
    public static void main(String[] arguments) throws Exception {
        require(arguments.length == 3, "expected root major software|playback");
        Path root = Paths.get(arguments[0]).toAbsolutePath();
        require(Files.isDirectory(root), "evidence directory must exist");
        int expectedMajor = Integer.parseInt(arguments[1]);
        String specification = System.getProperty("java.specification.version");
        int actualMajor = Integer.parseInt(specification.startsWith("1.") ? specification.substring(2) : specification);
        require(expectedMajor == actualMajor, "wrong runtime major");
        String mode = arguments[2]; require(mode.equals("software") || mode.equals("playback"), "unknown sound mode");
        try (FileChannel output = FileChannel.open(root.resolve("java-sound-progress.txt"), StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)) {
            log = output;
            record("pid", ManagementFactory.getRuntimeMXBean().getName()); record("javaVersion", System.getProperty("java.runtime.version"));
            record("osName", System.getProperty("os.name")); record("mode", mode);
            try {
                nativeLibrary(actualMajor); devices(); midi(root); files(root);
                record("software", "PASS");
                if (mode.equals("playback")) playback();
                else record("playback", "NOT-RUN:SOFTWARE_SCOPE_ONLY");
                Files.write(root.resolve("java-sound-complete.txt"), ("JAVA-SOUND:" + actualMajor + ":" + mode + "\n").getBytes(StandardCharsets.UTF_8),
                    StandardOpenOption.CREATE_NEW);
                record("completedScope", mode);
            } catch (Exception | Error error) { record("failure", error.toString()); throw error; }
            finally { log = null; }
        }
    }
}
