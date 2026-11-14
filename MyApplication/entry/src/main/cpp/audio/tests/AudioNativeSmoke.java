import com.amcl.audio.OhosAudioNative;

/**
 * 实际JNI宿主链回归。host-fixture只替换系统设备，调用真实Java声明/薄桥/函数表/PCM核心。
 * 测试不进入AudioSystem、不访问宿主麦克风，也不把结果称为OHOS设备录放音通过。
 */
public final class AudioNativeSmoke {
    private static native int begin();
    private static native void feed(int frames);
    private static native void consume();
    private static native void deny();
    private static native void end();
    private static void check(boolean condition,String message){if(!condition)throw new AssertionError(message);}
    public static void main(String[] args)throws Exception{
        System.load(args[0]);check(begin()==0,"host begin");System.load(args[1]);
        long capture=OhosAudioNative.nOpen(true,16000,1,1,4096);OhosAudioNative.nStart(capture);feed(4800);
        long deadline=System.nanoTime()+2_000_000_000L;
        while(OhosAudioNative.nAvailable(capture)<3200&&System.nanoTime()<deadline)Thread.sleep(2);
        byte[] captured=new byte[3208];check(OhosAudioNative.nRead(capture,captured,4,3200)==3200,"capture JNI bytes");
        for(int i=44;i<3204;i+=2)check((captured[i]&255)==0&&(captured[i+1]&255)==64,"PCM identity");
        check(OhosAudioNative.nFramePosition(capture)==1600,"capture actual frames");
        try{OhosAudioNative.nRead(capture,captured,-1,2);throw new AssertionError("range accepted");}
        catch(IndexOutOfBoundsException expected){}
        long output=OhosAudioNative.nOpen(false,22050,2,2,8192);
        byte[] data=new byte[8192];for(int i=0;i<data.length;i+=4){data[i+2]=0;data[i+3]=63;}
        check(OhosAudioNative.nWrite(output,data,0,data.length)==data.length,"float write JNI");
        OhosAudioNative.nStart(output);
        Thread consumer=new Thread(()->{try{while(!Thread.currentThread().isInterrupted()){consume();Thread.sleep(2);}}
            catch(InterruptedException expected){}});consumer.start();
        OhosAudioNative.nDrain(output);check(OhosAudioNative.nFramePosition(output)==1024,"play actual frames");
        byte[] large=new byte[131072];check(OhosAudioNative.nWrite(output,large,0,large.length)==large.length,"bounded JNI chunks");
        OhosAudioNative.nDrain(output);check(OhosAudioNative.nFramePosition(output)==17408,"large write actual frames");
        consumer.interrupt();consumer.join();OhosAudioNative.nStop(output);OhosAudioNative.nClose(output);
        deny();check((OhosAudioNative.nState(capture)&8)!=0,"capture revoked");
        try{OhosAudioNative.nOpen(true,16000,1,1,4096);throw new AssertionError("permission accepted");}
        catch(SecurityException expected){}
        OhosAudioNative.nClose(capture);end();OhosAudioNative.nClose(capture);
        check(OhosAudioNative.nState(capture)==8,"ended state");
        System.out.println("PASS actual Java JNI: canonical class, PCM read/write, real frames, array bounds, permission exception, end");
    }
}
