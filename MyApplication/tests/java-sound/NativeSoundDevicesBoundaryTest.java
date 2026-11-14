import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import javax.sound.sampled.BooleanControl;
import javax.sound.sampled.Control;
import javax.sound.sampled.Line;
import javax.sound.sampled.LineEvent;
import javax.sound.sampled.LineListener;
import javax.sound.sampled.LineUnavailableException;
import javax.sound.sampled.Port;

/** 只验证新夹具的资源/失败边界，不运行其main、ServiceLoader或任何真实设备API。
 * 原生SPI本体已有独立Java/JNI资格；这里不再搭建一套假MIDI/系统音频框架。 */
public final class NativeSoundDevicesBoundaryTest {
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static final class FakePort implements Port {
        final Port.Info declared = new Port.Info(Port.class, "输入&<>🚀\n", true);
        boolean open;
        int closes;
        boolean nonemptyControls;
        boolean badInfo;
        LineUnavailableException openFailure;
        RuntimeException queryFailure, closeFailure;
        public Line.Info getLineInfo() { return badInfo ? new Line.Info(Line.class) : declared; }
        public void open() throws LineUnavailableException {
            if (openFailure != null) throw openFailure;
            open = true;
        }
        public void close() {
            closes++; open = false;
            if (closeFailure != null) throw closeFailure;
        }
        public boolean isOpen() { return open; }
        public Control[] getControls() {
            if (queryFailure != null) throw queryFailure;
            return nonemptyControls ? new Control[] {new BooleanControl(BooleanControl.Type.MUTE, false) {}} : new Control[0];
        }
        public boolean isControlSupported(Control.Type type) { return false; }
        public Control getControl(Control.Type type) { throw new IllegalArgumentException("no controls"); }
        public void addLineListener(LineListener listener) {}
        public void removeLineListener(LineListener listener) {}
    }

    public static void main(String[] args) throws Exception {
        check(args.length == 1, "external output root required");
        Path root = Paths.get(args[0]);
        check(Files.isDirectory(root), "output root missing");
        try (NativeSoundDevicesQualification.Trace trace = new NativeSoundDevicesQualification.Trace(root.resolve("boundary-progress.jsonl"))) {
            FakePort normal = new FakePort();
            NativeSoundDevicesQualification.inspectPort(normal, normal.declared, 0, 0, trace);
            check(!normal.open && normal.closes == 1, "normal Port closes exactly once");

            FakePort controls = new FakePort(); controls.nonemptyControls = true;
            try { NativeSoundDevicesQualification.inspectPort(controls, controls.declared, 0, 1, trace); throw new AssertionError("fake controls accepted"); }
            catch (AssertionError expected) { check(expected.getMessage().startsWith("unexpected native Port controls"), "wrong controls failure"); }
            check(controls.closes == 1 && !controls.open, "controls failure still closes");

            FakePort failed = new FakePort();
            failed.queryFailure = new IllegalStateException("query-first"); failed.closeFailure = new IllegalStateException("close-second");
            try { NativeSoundDevicesQualification.inspectPort(failed, failed.declared, 0, 2, trace); throw new AssertionError("failure swallowed"); }
            catch (IllegalStateException expected) {
                check(expected == failed.queryFailure && expected.getSuppressed().length == 1 &&
                        expected.getSuppressed()[0] == failed.closeFailure, "first/suppressed identity");
            }
            check(failed.closes == 1, "failed Port closes exactly once");

            FakePort opening = new FakePort(); opening.openFailure = new LineUnavailableException("cannot open");
            try { NativeSoundDevicesQualification.inspectPort(opening, opening.declared, 0, 3, trace); throw new AssertionError("open failure swallowed"); }
            catch (LineUnavailableException expected) { check(expected == opening.openFailure, "original open error"); }
            check(opening.closes == 1, "open failure also closes acquired Line");

            FakePort wrong = new FakePort(); wrong.badInfo = true;
            try { NativeSoundDevicesQualification.inspectPort(wrong, wrong.declared, 0, 4, trace); throw new AssertionError("untyped info accepted"); }
            catch (AssertionError expected) { check(expected.getMessage().equals("opened Port lost typed Info"), "wrong typed failure"); }
            check(wrong.closes == 1, "typed failure closes");

            try { NativeSoundDevicesQualification.requirePorts(0, trace); throw new AssertionError("zero Ports accepted"); }
            catch (AssertionError expected) { check(expected.getMessage().startsWith("zero native Ports"), "wrong zero failure"); }
        }
        check(!Files.exists(root.resolve(NativeSoundDevicesQualification.COMPLETE)), "boundary tests must not fabricate target completion");
        System.out.println("PASS host fixture boundary: typed metadata, forbidden fake controls, exact close on open/query failures, first/suppressed exception, zero Ports rejection; no device/SPI calls");
    }
}
