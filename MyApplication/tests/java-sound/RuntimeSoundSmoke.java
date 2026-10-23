/**
 * Java Sound 能力回归：确认 native 真正加载、硬件 provider 为零设备，
 * 同时保留 MIDI 读写、软件 sequencer 和 WAV 解析。无外设、无物理播放。
 */
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.lang.reflect.Field;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import javax.sound.midi.*;
import javax.sound.midi.spi.MidiDeviceProvider;
import javax.sound.sampled.*;
import javax.sound.sampled.spi.MixerProvider;

public final class RuntimeSoundSmoke {
    /** 失败使用进程非零状态，不把 Platform 自动降级当成新 native 已工作。 */
    private static void require(boolean ok, String message) {
        if (!ok) throw new AssertionError(message);
    }

    public static void main(String[] arguments) throws Exception {
        Class<?> platform = Class.forName("com.sun.media.sound.Platform");
        if (System.getProperty("java.specification.version").equals("1.8")) {
            // 经典实现用库位掩码；MAIN 必须真实加载，ALSA 不得进入能力集合。
            Field loaded = platform.getDeclaredField("loadedLibs");
            loaded.setAccessible(true);
            require(loaded.getInt(null) == 1, "JDK8 must load only the main jsound library");
        } else {
            Field loaded = platform.getDeclaredField("isNativeLibLoaded");
            loaded.setAccessible(true);
            require(loaded.getBoolean(null), "jsound native did not load");
        }
        for (String name : new String[] {"MidiInDeviceProvider", "MidiOutDeviceProvider"}) {
            MidiDeviceProvider provider = (MidiDeviceProvider) Class.forName("com.sun.media.sound." + name)
                .getConstructor().newInstance();
            require(provider.getDeviceInfo().length == 0, "native MIDI must report no devices");
        }
        for (String name : new String[] {"DirectAudioDeviceProvider", "PortMixerProvider"}) {
            MixerProvider provider = (MixerProvider) Class.forName("com.sun.media.sound." + name)
                .getConstructor().newInstance();
            require(provider.getMixerInfo().length == 0, "native mixer must report no devices");
        }
        int softwareDevices = MidiSystem.getMidiDeviceInfo().length;
        require(softwareDevices > 0, "software MIDI providers were accidentally removed");
        Sequence sequence = new Sequence(Sequence.PPQ, 24);
        Track track = sequence.createTrack();
        track.add(new MidiEvent(new ShortMessage(ShortMessage.NOTE_ON, 0, 60, 100), 0));
        track.add(new MidiEvent(new ShortMessage(ShortMessage.NOTE_OFF, 0, 60, 0), 12));
        ByteArrayOutputStream midi = new ByteArrayOutputStream();
        require(MidiSystem.write(sequence, 1, midi) > 0, "MIDI write failed");
        require(MidiSystem.getSequence(new ByteArrayInputStream(midi.toByteArray())).getTracks().length == 1,
            "MIDI parse failed");
        CountDownLatch delivered = new CountDownLatch(1);
        Sequencer sequencer = MidiSystem.getSequencer(false);
        try {
            sequencer.open();
            sequencer.getTransmitter().setReceiver(new Receiver() {
                public void send(MidiMessage message, long timestamp) {
                    if (message instanceof ShortMessage && ((ShortMessage) message).getCommand() == ShortMessage.NOTE_ON)
                        delivered.countDown();
                }
                public void close() { }
            });
            sequencer.setSequence(sequence); sequencer.start();
            require(delivered.await(5, TimeUnit.SECONDS), "software sequencer did not deliver a note");
        } finally { sequencer.stop(); sequencer.close(); }
        AudioFormat format = new AudioFormat(8000, 16, 1, true, false);
        ByteArrayOutputStream wav = new ByteArrayOutputStream();
        AudioSystem.write(new AudioInputStream(new ByteArrayInputStream(new byte[16]), format, 8),
            AudioFileFormat.Type.WAVE, wav);
        try (AudioInputStream parsed = AudioSystem.getAudioInputStream(new ByteArrayInputStream(wav.toByteArray()))) {
            require(parsed.getFormat().getSampleRate() == 8000 && parsed.getFrameLength() == 8, "WAV parse failed");
        }
        System.out.println("PASS Java Sound: native loaded; hardware providers empty; softwareDevices="
            + softwareDevices + "; MIDI/WAV roundtrip and sequencer delivery verified");
    }
}
