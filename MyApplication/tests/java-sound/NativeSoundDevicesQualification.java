import java.lang.management.ManagementFactory;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.util.ServiceLoader;
import javax.sound.midi.MidiDevice;
import javax.sound.midi.spi.MidiDeviceProvider;
import javax.sound.sampled.Control;
import javax.sound.sampled.Line;
import javax.sound.sampled.Mixer;
import javax.sound.sampled.Port;
import javax.sound.sampled.spi.MixerProvider;

/**
 * class52固定只读资格：main(runPath, major)。MIDI只经标准SPI枚举Info，绝不getDevice/
 * open端口/收发数据。0027的PortMixer.open仅创建设备描述符快照，已按实际Native源核实，
 * 不创建PCM流或Capture。成功只表示枚举/快照合同成立，不能授予MIDI硬件IO或录音资格。
 */
public final class NativeSoundDevicesQualification {
    static final String PROGRESS = "native-sound-devices-progress.jsonl";
    static final String COMPLETE = "native-sound-devices-complete.json";
    private static final String MIDI_IN = "com.sun.media.sound.MidiInDeviceProvider";
    private static final String MIDI_OUT = "com.sun.media.sound.MidiOutDeviceProvider";
    private static final String PORT_PROVIDER = "com.sun.media.sound.PortMixerProvider";
    private static final int MAX_ITEMS = 4096; // 与已验证Native异常供应者上限一致，不静默截断。
    private NativeSoundDevicesQualification() {}

    static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    /** 控制字符及surrogate按JSON转义；保留中文/非BMP名称，不把标准UTF-8误当modified UTF-8。 */
    static String quote(String text) {
        if (text == null) return "null";
        StringBuilder result = new StringBuilder("\"");
        for (int index = 0; index < text.length(); ++index) {
            char value = text.charAt(index);
            if (value == '"' || value == '\\') result.append('\\').append(value);
            else if (value < 32 || Character.isSurrogate(value)) {
                String hex = Integer.toHexString(value);
                result.append("\\u");
                for (int pad = hex.length(); pad < 4; ++pad) result.append('0');
                result.append(hex);
            } else result.append(value);
        }
        return result.append('"').toString();
    }

    static String hex(byte[] data) {
        StringBuilder result = new StringBuilder(data.length * 2);
        for (byte value : data) {
            result.append(Character.forDigit((value >>> 4) & 15, 16));
            result.append(Character.forDigit(value & 15, 16));
        }
        return result.toString();
    }

    /** 独占JSONL进度，先记阶段再做可能失败的SPI调用；最终complete绑定全部已落盘正文。 */
    static final class Trace implements AutoCloseable {
        private final FileChannel channel;
        private final MessageDigest digest = MessageDigest.getInstance("SHA-256");
        private int sequence;
        Trace(Path path) throws Exception {
            channel = FileChannel.open(path, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE);
        }
        void event(String event, String fields) throws Exception {
            String text = "{\"sequence\":" + sequence++ + ",\"event\":" + quote(event) +
                    (fields.isEmpty() ? "" : "," + fields) + "}\n";
            byte[] encoded = text.getBytes(StandardCharsets.UTF_8);
            ByteBuffer bytes = ByteBuffer.wrap(encoded);
            while (bytes.hasRemaining()) channel.write(bytes);
            channel.force(false); digest.update(encoded);
            System.out.print("NATIVE_SOUND " + text); System.out.flush();
        }
        String digest() { return hex(digest.digest()); }
        public void close() throws Exception { channel.close(); }
    }

    /** 名称逐代对照锁定Platform.java：8为loadedLibs/LIB_MAIN；17/21/25为isNativeLibLoaded。
     * 四代均有两个平台门及AbstractMidiDeviceProvider.enabled，缺失或反射失败不能跳过。
     */
    private static void platform(int major, Trace trace) throws Exception {
        Class<?> type = Class.forName("com.sun.media.sound.Platform");
        boolean loaded;
        if (major == 8) {
            Field libs = type.getDeclaredField("loadedLibs"), main = type.getDeclaredField("LIB_MAIN");
            libs.setAccessible(true); main.setAccessible(true);
            int bits = libs.getInt(null), mask = main.getInt(null);
            loaded = mask != 0 && (bits & mask) == mask;
            trace.event("native-load-mask", "\"loadedLibs\":" + bits + ",\"mainMask\":" + mask);
        } else {
            Field field = type.getDeclaredField("isNativeLibLoaded"); field.setAccessible(true);
            loaded = field.getBoolean(null);
        }
        Method midi = type.getDeclaredMethod("isMidiIOEnabled"), ports = type.getDeclaredMethod("isPortsEnabled");
        midi.setAccessible(true); ports.setAccessible(true);
        boolean midiEnabled = (Boolean)midi.invoke(null), portsEnabled = (Boolean)ports.invoke(null);
        Class<?> base = Class.forName("com.sun.media.sound.AbstractMidiDeviceProvider");
        Field enabled = base.getDeclaredField("enabled"); enabled.setAccessible(true);
        boolean providerEnabled = enabled.getBoolean(null);
        trace.event("platform-gates", "\"nativeLibraryLoaded\":" + loaded + ",\"midiIOEnabled\":" + midiEnabled +
                ",\"midiProviderEnabled\":" + providerEnabled + ",\"portsEnabled\":" + portsEnabled);
        require(loaded && midiEnabled && providerEnabled && portsEnabled, "native library or actual provider gate disabled");
    }

    /** 只调用两个标准原生Provider的getDeviceInfo；不把软件合成器/Sequencer计为硬件端点。 */
    private static void midi(Trace trace) throws Exception {
        int foundIn = 0, foundOut = 0;
        for (MidiDeviceProvider provider : ServiceLoader.load(MidiDeviceProvider.class)) {
            String type = provider.getClass().getName();
            if (!type.equals(MIDI_IN) && !type.equals(MIDI_OUT)) continue;
            require(provider.getClass().getClassLoader() == MidiDeviceProvider.class.getClassLoader(), "native MIDI provider loader differs");
            if (type.equals(MIDI_IN)) foundIn++; else foundOut++;
            trace.event("midi-enumeration-start", "\"provider\":" + quote(type));
            MidiDevice.Info[] infos = provider.getDeviceInfo();
            require(infos != null && infos.length <= MAX_ITEMS, "invalid native MIDI info array");
            trace.event("midi-provider", "\"provider\":" + quote(type) + ",\"endpointCount\":" + infos.length +
                    ",\"observation\":" + quote(infos.length == 0 ? "NO_ENDPOINTS_OR_OPTIONAL_API_UNAVAILABLE" : "ENDPOINTS_ENUMERATED") +
                    ",\"midiIoQualified\":false,\"requiresNativeProviderEvidence\":true");
            for (int index = 0; index < infos.length; ++index) {
                MidiDevice.Info info = infos[index]; require(info != null, "null MIDI endpoint");
                trace.event("midi-endpoint", "\"provider\":" + quote(type) + ",\"index\":" + index +
                        ",\"name\":" + quote(info.getName()) + ",\"vendor\":" + quote(info.getVendor()) +
                        ",\"description\":" + quote(info.getDescription()) + ",\"version\":" + quote(info.getVersion()));
            }
        }
        require(foundIn == 1 && foundOut == 1, "expected exactly one native input and output MIDI provider");
    }

    /** 控制数组必须来自真实getControls调用；没有公开硬件setter时不能发布假的可写控件。 */
    private static void noControls(Control[] controls, String context) {
        require(controls != null && controls.length == 0, "unexpected native Port controls: " + context);
    }

    /** 单端口资源边界供小型宿主假Port验证；生产只在已核标准PortMixer分支调用。
     * try-with-resources保留首异常并把close失败作为suppressed，open失败也会执行close。
     */
    static void inspectPort(Line candidate, Port.Info declared, int mixer, int index, Trace trace) throws Exception {
        try (Line line = candidate) {
            require(line instanceof Port, "PortMixer returned a non-Port line");
            trace.event("port-open-start", "\"mixer\":" + mixer + ",\"index\":" + index);
            line.open(); require(line.isOpen(), "Port did not become open");
            Line.Info actual = line.getLineInfo(); require(actual instanceof Port.Info, "opened Port lost typed Info");
            Port.Info info = (Port.Info)actual;
            require(info.isSource() == declared.isSource() && Port.class.isAssignableFrom(info.getLineClass()), "Port direction/type changed");
            noControls(line.getControls(), info.getName());
            trace.event("port-opened", "\"mixer\":" + mixer + ",\"index\":" + index +
                    ",\"name\":" + quote(info.getName()) + ",\"isSource\":" + info.isSource() +
                    ",\"lineClass\":" + quote(line.getClass().getName()) + ",\"controls\":[],\"snapshotOnly\":true");
        }
        require(!candidate.isOpen(), "Port remained open after close");
        trace.event("port-closed", "\"mixer\":" + mixer + ",\"index\":" + index);
    }

    static void requirePorts(int count, Trace trace) throws Exception {
        if (count == 0) trace.event("ports-unavailable", "\"observation\":\"NO_PORTS_AVAILABLE_UNSUPPORTED_FOR_THIS_RUN\",\"qualified\":false");
        require(count > 0, "zero native Ports cannot qualify device snapshots");
    }

    private static int ports(Trace trace) throws Exception {
        int providers = 0, count = 0, mixerIndex = 0;
        for (MixerProvider provider : ServiceLoader.load(MixerProvider.class)) {
            if (!provider.getClass().getName().equals(PORT_PROVIDER)) continue;
            providers++;
            require(provider.getClass().getClassLoader() == MixerProvider.class.getClassLoader(), "native Port provider loader differs");
            Mixer.Info[] infos = provider.getMixerInfo();
            require(infos != null && infos.length <= MAX_ITEMS, "invalid PortMixer info array");
            trace.event("port-provider", "\"mixerCount\":" + infos.length);
            for (Mixer.Info info : infos) {
                require(info != null, "null PortMixer info");
                Mixer selected = provider.getMixer(info);
                try (Mixer mixer = selected) {
                    require(mixer.getClass().getName().equals("com.sun.media.sound.PortMixer") &&
                            mixer.getClass().getClassLoader() == MixerProvider.class.getClassLoader(), "unexpected mixer implementation");
                    trace.event("mixer-open-start", "\"mixer\":" + mixerIndex + ",\"name\":" + quote(info.getName()));
                    mixer.open(); require(mixer.isOpen(), "PortMixer did not become open");
                    noControls(mixer.getControls(), "mixer");
                    Line.Info[][] directions = {mixer.getSourceLineInfo(), mixer.getTargetLineInfo()};
                    int lineIndex = 0;
                    for (int direction = 0; direction < directions.length; ++direction) {
                        Line.Info[] lines = directions[direction];
                        require(lines != null && lines.length <= MAX_ITEMS, "invalid Port line array");
                        for (Line.Info line : lines) {
                            require(line instanceof Port.Info, "PortMixer advertised a non-Port line");
                            Port.Info declared = (Port.Info)line;
                            require(declared.isSource() == (direction == 0), "Port source/target list mismatch");
                            inspectPort(mixer.getLine(declared), declared, mixerIndex, lineIndex++, trace); count++;
                        }
                    }
                    require(lineIndex > 0, "PortMixer has no typed ports");
                }
                require(!selected.isOpen(), "PortMixer remained open after close");
                trace.event("mixer-closed", "\"mixer\":" + mixerIndex++);
            }
        }
        require(providers == 1, "expected exactly one native PortMixerProvider"); requirePorts(count, trace);
        return count;
    }

    public static void main(String[] args) throws Exception {
        require(args.length == 2, "expected runPath and major");
        Path root = Paths.get(args[0]).toAbsolutePath().normalize();
        require(Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS), "qualification root is not a directory");
        int major = Integer.parseInt(args[1]);
        String version = System.getProperty("java.specification.version");
        int actual = Integer.parseInt(version.startsWith("1.") ? version.substring(2) : version);
        require((major == 8 || major == 17 || major == 21 || major == 25) && actual == major, "wrong runtime major");
        String progressSha; int portCount;
        try (Trace trace = new Trace(root.resolve(PROGRESS))) {
            try {
                trace.event("start", "\"major\":" + major + ",\"pid\":" + quote(ManagementFactory.getRuntimeMXBean().getName()) +
                        ",\"midiPortsOpened\":false,\"midiEventsSent\":false,\"captureOpened\":false,\"pcmStreamsRequested\":false");
                platform(major, trace); midi(trace); portCount = ports(trace);
                trace.event("complete", "\"portsQualified\":true,\"portCount\":" + portCount + ",\"midiIoQualified\":false");
                progressSha = trace.digest();
            } catch (Exception | Error error) {
                try { trace.event("failure", "\"class\":" + quote(error.getClass().getName()) + ",\"message\":" + quote(error.getMessage())); }
                catch (Exception logging) { error.addSuppressed(logging); }
                throw error;
            }
        }
        // 只有全部Port/mixer已关闭且进度文件成功关闭后才创建完成记录；父层还须绑定SHA及Native provider ready证据。
        String complete = "{\"protocol\":\"AMCL_NATIVE_SOUND_DEVICES_V1\",\"major\":" + major +
                ",\"passed\":true,\"midiIoQualified\":false,\"portCount\":" + portCount +
                ",\"progressSha256\":\"" + progressSha + "\"}\n";
        try (FileChannel file = FileChannel.open(root.resolve(COMPLETE), StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)) {
            ByteBuffer bytes = ByteBuffer.wrap(complete.getBytes(StandardCharsets.UTF_8));
            while (bytes.hasRemaining()) file.write(bytes);
            file.force(true);
        }
    }
}
