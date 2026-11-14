/* 真实四代Provider/Device与生产JNI的有界回归。系统服务由固定有状态libohmidi.so
 * 注入，传输数据完整经过SDK callback -> POD -> JNI -> 上游Transmitter/Receiver。
 * 这是宿主逻辑资格，不能代替商业OHOS的外设/CFI实际运行。
 */
package com.sun.media.sound;

import java.io.ByteArrayOutputStream;
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import javax.sound.midi.MidiDevice;
import javax.sound.midi.MidiMessage;
import javax.sound.midi.Receiver;
import javax.sound.midi.ShortMessage;
import javax.sound.midi.SysexMessage;
import javax.sound.midi.Transmitter;

public final class MidiJavaTest {
    private static native void bind();
    private static native long control(int mode);
    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    private static void await(CountDownLatch latch, String detail) throws Exception {
        require(latch.await(3, TimeUnit.SECONDS), "deadline: " + detail);
    }
    private static final class Capture implements Receiver {
        final CountDownLatch shortSeen = new CountDownLatch(1);
        final CountDownLatch sysexSeen = new CountDownLatch(1);
        final ByteArrayOutputStream sysex = new ByteArrayOutputStream();
        volatile Throwable error;
        volatile int shortCount;
        public synchronized void send(MidiMessage message, long time) {
            try {
                require(time == -1, "unknown native timestamp must remain -1");
                byte[] bytes = message.getMessage();
                if (message instanceof ShortMessage) {
                    require(Arrays.equals(bytes, new byte[]{(byte)0x90,60,100}), "short receive bytes");
                    ++shortCount; shortSeen.countDown();
                } else {
                    require(bytes.length > 0 && ((bytes[0]&255)==0xf0 || (bytes[0]&255)==0xf7), "SysEx continuation marker");
                    int skip = (bytes[0]&255)==0xf7 ? 1 : 0;
                    sysex.write(bytes,skip,bytes.length-skip);
                    if ((bytes[bytes.length-1]&255)==0xf7) sysexSeen.countDown();
                }
            } catch (Throwable problem) { error=problem; shortSeen.countDown();sysexSeen.countDown(); }
        }
        public void close() {}
    }
    public static void main(String[] args) throws Exception {
        System.load(args[0]); bind();
        String mode=args.length>1?args[1]:"positive";
        MidiInDeviceProvider inputs=new MidiInDeviceProvider();
        MidiOutDeviceProvider outputs=new MidiOutDeviceProvider();
        if ("no-provider".equals(mode)) {
            require(inputs.getDeviceInfo().length==0 && outputs.getDeviceInfo().length==0,"unavailable optional provider must report zero real devices");
            System.out.println("PASS unavailable optional OH_MIDI provider with real Java/JNI");return;
        }
        if ("reject-host".equals(mode) || "missing-send".equals(mode)) {
            try { inputs.getDeviceInfo();throw new AssertionError("invalid provider or typed host accepted"); }
            catch (IllegalStateException expected) {
                require(expected.getMessage().contains("status="),"actual native error missing");
                System.out.println("PASS rejected invalid provider/typed host: "+expected.getMessage());return;
            }
        }
        control(0);
        MidiDevice.Info[] in=inputs.getDeviceInfo(),out=outputs.getDeviceInfo();
        require(in.length==2 && out.length==2,"real SDK descriptors were suppressed or virtual ones invented");
        require(in[0].getName().contains("乐器-\uD83C\uDFB9") && in[0].getName().contains("real-port-9"),"full standard UTF-8/non-BMP metadata lost");
        require(out[0].getName().contains("real-port-27") && in[1].getDescription().startsWith("BLE"),"actual direction/port/type lost");
        final MidiDevice.Info original=in[0];
        AtomicReference<Throwable> concurrency=new AtomicReference<Throwable>();
        Thread[] readers=new Thread[4];
        for(int i=0;i<readers.length;++i) {
            readers[i]=new Thread(new Runnable(){ public void run(){
                try { for(int j=0;j<40;++j)require(new MidiInDeviceProvider().getDeviceInfo()[0]==original,"same identity cache lost across Provider instances"); }
                catch(Throwable problem){concurrency.compareAndSet(null,problem);}
            }});
            readers[i].start();
        }
        for(Thread reader:readers){reader.join(3000);require(!reader.isAlive(),"provider class-lock deadline");}
        if(concurrency.get()!=null)throw new AssertionError("concurrent provider transaction",concurrency.get());
        final MidiDevice input=inputs.getDevice(in[0]);
        MidiDevice output=outputs.getDevice(out[0]);
        try {
            input.open();output.open();require(control(7)==1,"same device must share one native OpenDevice");
            Receiver sender=output.getReceiver();ShortMessage note=new ShortMessage(0x90,60,100);
            sender.send(note,0);sender.send(note,4294967296L);
            require(control(10)==4294967296000L,"jlong microseconds truncated before actual SDK Send");
            byte[] data=new byte[3002];Arrays.fill(data,(byte)0x7d);data[0]=(byte)0xf0;data[data.length-1]=(byte)0xf7;
            SysexMessage message=new SysexMessage();message.setMessage(data,data.length);
            long before=control(9);sender.send(message,-1);require(control(9)-before==500,"long SysEx must reach all 500 packets");
            control(3);
            try {sender.send(note,-1);throw new AssertionError("platform Send error swallowed");}
            catch(IllegalStateException expected){require(expected.getMessage().contains("35500013"),"wrong actual platform error");}
            control(5);
            Capture capture=new Capture();Transmitter transmitter=input.getTransmitter();transmitter.setReceiver(capture);
            control(1);await(capture.shortSeen,"short message");
            control(2);await(capture.sysexSeen,"3000-byte SysEx");
            if(capture.error!=null)throw new AssertionError("Receiver validation",capture.error);
            require(capture.shortCount==1 && Arrays.equals(capture.sysex.toByteArray(),data),"received MIDI/SysEx bytes changed or truncated");
            // Receiver在JNI CallVoidMethod栈内主动关闭设备。native hold必须覆盖回调返回，
            // Java实现跳过join自身；旧native循环不能在close后继续访问已释放对象。
            final CountDownLatch closedInside=new CountDownLatch(1);
            transmitter.setReceiver(new Receiver(){public void send(MidiMessage m,long time){input.close();closedInside.countDown();}public void close(){}});
            control(1);await(closedInside,"Receiver closes its own device");require(!input.isOpen(),"self-close failed");
            input.open();Capture reopened=new Capture();input.getTransmitter().setReceiver(reopened);
            control(1);await(reopened.shortSeen,"fresh handle after old Receiver returns");
            if(reopened.error!=null)throw new AssertionError("reopened Receiver",reopened.error);
            input.close();output.close();
            control(4);
            try{inputs.getDeviceInfo();throw new AssertionError("IPC enumeration error became zero devices");}
            catch(IllegalStateException expected){require(expected.getMessage().contains("35500002"),"wrong enumeration error");}
            control(5);require(inputs.getDeviceInfo()[0]==original,"failed snapshot mutated prior cache");
            control(6);MidiDevice.Info replacement=inputs.getDeviceInfo()[0];
            require(replacement!=original,"same-count disconnect/reconnect reused stale Info");
            try{inputs.getDevice(original);throw new AssertionError("stale Info opened replacement endpoint");}
            catch(IllegalArgumentException expected){}
            // JNI不得带pending用户异常继续下一轮，也不得吞异常或留下运行中的输入端口。
            final RuntimeException userFailure=new RuntimeException("sentinel Receiver failure");
            final CountDownLatch uncaught=new CountDownLatch(1);final AtomicReference<Throwable> actualFailure=new AtomicReference<Throwable>();
            Thread.UncaughtExceptionHandler previous=Thread.getDefaultUncaughtExceptionHandler();
            Thread.setDefaultUncaughtExceptionHandler(new Thread.UncaughtExceptionHandler(){public void uncaughtException(Thread t,Throwable error){actualFailure.set(error);uncaught.countDown();}});
            MidiDevice failing=inputs.getDevice(replacement);
            try {
                failing.open();failing.getTransmitter().setReceiver(new Receiver(){public void send(MidiMessage m,long time){throw userFailure;}public void close(){}});
                control(1);await(uncaught,"Receiver exception");
                require(actualFailure.get()==userFailure && !failing.isOpen(),"original Receiver exception/lifecycle changed");
            } finally {failing.close();Thread.setDefaultUncaughtExceptionHandler(previous);}
            require(control(7)==control(8),"native devices remain open after lifecycle cases");
            control(11);
            try{inputs.getDeviceInfo();throw new AssertionError("service death hidden as empty enumeration");}
            catch(IllegalStateException expected){require(expected.getMessage().contains("35500014"),"wrong service error");}
            MidiDevice.Info[] recovered=inputs.getDeviceInfo();
            require(recovered.length==2 && recovered[0]!=replacement,"closed service client was not really recreated with fresh identities");
            MidiDevice recoveredInput=inputs.getDevice(recovered[0]);
            recoveredInput.open();recoveredInput.close();
        } finally {input.close();output.close();}
        System.out.println("PASS real MIDI Provider/Device Java+JNI: UTF16/non-BMP, concurrent shared cache, USB/BLE IDs, actual Send/receive/SysEx, 64-bit time, self-close/reopen, user exception, stale Info and platform failures");
    }
}
