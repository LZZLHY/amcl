import java.lang.management.ManagementFactory;
import java.lang.reflect.Field;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import javax.sound.sampled.AudioFormat;
import javax.sound.sampled.AudioSystem;
import javax.sound.sampled.DataLine;
import javax.sound.sampled.LineUnavailableException;
import javax.sound.sampled.TargetDataLine;

/**
 * 独立的真实 JavaSound Capture 资格，class52。denied 从不调用 start；capture 仅由
 * 宿主在用户明确同意短录音且完成 OS 授权后选择，两个格式各读取200ms真实输入。
 * diagnostic为独立固定profile：仍各read200ms，仅用400ms逻辑缓冲证明前缀未覆盖，
 * 与已显式arm的正常HAP typed回调首200ms统计对照。原capture/denied流程不启用该诊断。
 * 不保存/传输原始 PCM，仅保留计数、峰值与RMS；外层进程 watchdog 负责 native 卡住。
 * 本夹具不能用一个自报 token 代替用户授权证据，也不会自动请求或更改麦克风权限。
 */
public final class JavaSoundCaptureQualification {
    private static FileChannel output;
    private JavaSoundCaptureQualification() {}

    private static void require(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    /** 阻塞操作之前即落阶段记录，异常/超时保留真实最后进度；没有PCM正文。 */
    private static void record(String key, Object value) throws Exception {
        String text = "CAPTURE " + key + "=" + String.valueOf(value).replace("\r", "\\r").replace("\n", "\\n") + "\n";
        ByteBuffer bytes = ByteBuffer.wrap(text.getBytes(StandardCharsets.UTF_8));
        while (bytes.hasRemaining()) output.write(bytes);
        output.force(false);
        System.out.print(text); System.out.flush();
    }

    private static void loaded(int major) throws Exception {
        Class<?> type = Class.forName("com.sun.media.sound.Platform");
        Field field = type.getDeclaredField(major == 8 ? "loadedLibs" : "isNativeLibLoaded");
        field.setAccessible(true);
        boolean available = major == 8 ? (field.getInt(null) & 1) != 0 : field.getBoolean(null);
        record("nativeLibraryLoaded", available);
        require(available, "native JavaSound did not load");
    }

    /** 先证明目标格式已由实际输入后端声明；零设备/未实现不冒充“预期权限拒绝”。 */
    private static TargetDataLine select(AudioFormat format) throws Exception {
        DataLine.Info wanted = new DataLine.Info(TargetDataLine.class, format);
        require(AudioSystem.isLineSupported(wanted), "UNAVAILABLE:NO_TARGET_LINE_FOR_" + format);
        TargetDataLine line = (TargetDataLine)AudioSystem.getLine(wanted);
        record("lineClass", line.getClass().getName());
        return line;
    }

    private static void denied(AudioFormat format) throws Exception {
        TargetDataLine line = select(format);
        boolean rejected = false;
        try {
            record("stage", "DENIED_OPEN_ATTEMPT_NO_START");
            try { line.open(format, 4096 * format.getFrameSize()); }
            catch (LineUnavailableException | SecurityException error) {
                rejected = true;
                record("openFailureClass", error.getClass().getName());
                record("openFailureMessage", error.getMessage());
            }
        } finally { line.close(); }
        require(rejected && !line.isOpen(), "expected open rejection; no recording was started");
        record("deniedObservation", "OPEN_REJECTED;BIND_TO_HOST_FRESH_PERMISSION_EVIDENCE");
    }

    /** 逐代核实的DirectDL私有字段只用于诊断，反射失败明确失败，不按猜测填写转换状态。 */
    private static Object directField(TargetDataLine line, String name) throws Exception {
        for (Class<?> type = line.getClass(); type != null; type = type.getSuperclass()) {
            try { Field field = type.getDeclaredField(name); field.setAccessible(true); return field.get(line); }
            catch (NoSuchFieldException absent) { /* 只沿已取得对象的父类找声明，不忽略其他异常。 */ }
        }
        throw new NoSuchFieldException(name);
    }

    private static void capture(AudioFormat format, int pass, boolean diagnostic) throws Exception {
        TargetDataLine line = select(format);
        try {
            record("stage", "OPEN_" + pass);
            int frames = (int)format.getSampleRate() / 5;
            // 诊断容量为固定400ms；读取量仍为200ms。只在总捕获帧数没有超过容量时
            // 与callback首200ms比较，避免读取有race的Native consumed/overwritten字段。
            line.open(format, (diagnostic ? frames * 2 : 4096) * format.getFrameSize());
            require(line.getFormat().matches(format) && line.getBufferSize() > 0 &&
                    line.getBufferSize() % format.getFrameSize() == 0, "actual capture format/buffer differs");
            if (diagnostic) {
                record("diagnostic." + pass + ".hardwareFormat", directField(line, "hardwareFormat"));
                record("diagnostic." + pass + ".softwareConversionSize", directField(line, "softwareConversionSize"));
                record("diagnostic." + pass + ".bufferBytes", line.getBufferSize());
            }
            byte[] pcm = new byte[frames * format.getFrameSize()];
            long before = line.getLongFramePosition();
            record("stage", "START_AND_READ_" + pass);
            line.start();
            int read = 0;
            while (read < pcm.length) {
                int count = line.read(pcm, read, Math.min(pcm.length - read, 1024 * format.getFrameSize()));
                require(count > 0 && count % format.getFrameSize() == 0, "capture stalled or split a frame");
                read += count;
            }
            long after = line.getLongFramePosition();
            require(after - before >= frames, "actual capture callbacks did not advance frame position");
            line.stop();
            long stopped = line.getLongFramePosition();
            if (diagnostic) {
                record("diagnostic." + pass + ".positionBefore", before);
                record("diagnostic." + pass + ".positionAfterRead", after);
                record("diagnostic." + pass + ".positionAfterStop", stopped);
                record("diagnostic." + pass + ".prefixCapacityProven", before == 0 && stopped >= 0 &&
                        stopped <= line.getBufferSize() / format.getFrameSize());
            }
            line.flush();
            require(line.available() == 0 && line.getLongFramePosition() == stopped, "capture flush fabricated frames or retained data");
            int peak = 0, nonZero = 0;
            long energy = 0;
            for (int offset = 0; offset < pcm.length; offset += 2) {
                int value = (short)((pcm[offset] & 255) | (pcm[offset + 1] << 8));
                int absolute = Math.abs(value);
                if (absolute > peak) peak = absolute;
                if (value != 0) nonZero++;
                energy += (long)value * value;
            }
            record("pass." + pass + ".format", format);
            record("pass." + pass + ".bytesRead", read);
            record("pass." + pass + ".framesAdvanced", after - before);
            record("pass." + pass + ".peak", peak);
            record("pass." + pass + ".rms", Math.sqrt((double)energy / (pcm.length / 2)));
            record("pass." + pass + ".nonZeroSamples", nonZero);
            record("pass." + pass + ".signalObservation", nonZero == 0 ?
                    "SILENCE_OR_PLATFORM_MUTE;NOT_A_PHYSICAL_SIGNAL_PROOF" : "NONZERO_INPUT_OBSERVED");
            // 数据已用于本次计数，覆盖工作数组；没有写 PCM 文件、上传或自动回放。
            java.util.Arrays.fill(pcm, (byte)0);
        } finally {
            line.close();
            require(!line.isOpen(), "capture did not close");
        }
    }

    public static void main(String[] arguments) throws Exception {
        require(arguments.length == 3, "expected root major denied|capture|diagnostic");
        Path root = Paths.get(arguments[0]).toAbsolutePath();
        require(Files.isDirectory(root), "evidence root missing");
        int major = Integer.parseInt(arguments[1]);
        String specification = System.getProperty("java.specification.version");
        int actual = Integer.parseInt(specification.startsWith("1.") ? specification.substring(2) : specification);
        require(actual == major, "wrong runtime major");
        String mode = arguments[2];
        require(mode.equals("denied") || mode.equals("capture") || mode.equals("diagnostic"), "unknown mode");
        try (FileChannel channel = FileChannel.open(root.resolve("java-sound-capture-progress.txt"),
                StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)) {
            output = channel;
            try {
                record("pid", ManagementFactory.getRuntimeMXBean().getName());
                record("javaVersion", System.getProperty("java.runtime.version"));
                record("mode", mode); record("rawPcmSaved", false);
                loaded(major);
                AudioFormat low = new AudioFormat(16000, 16, 1, true, false);
                if (mode.equals("denied")) denied(low);
                else {
                    capture(low, 0, mode.equals("diagnostic"));
                    capture(new AudioFormat(48000, 16, 1, true, false), 1, mode.equals("diagnostic"));
                }
                Files.write(root.resolve("java-sound-capture-complete.txt"),
                        ("JAVA-SOUND-CAPTURE:" + major + ":" + mode + "\n").getBytes(StandardCharsets.UTF_8),
                        StandardOpenOption.CREATE_NEW);
                record("completedScope", mode);
            } catch (Exception | Error error) { record("failure", error.toString()); throw error; }
            finally { output = null; }
        }
    }
}
