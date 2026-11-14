package com.amcl.audio;

import java.io.File;
import javax.sound.sampled.LineUnavailableException;

/**
 * 启动器父加载域唯一的 JNI 声明。仅打开真实流时加载签名 HAP 中的薄桥，不在服务发现期间占设备。
 * 薄桥还会核验当前 PID/session 的原生 owner；此类不创建第二份 PCM 服务，也不提供生产假设备。
 */
public final class OhosAudioNative {
    private static boolean loaded;
    static final AudioBackend BACKEND = new NativeBackend();
    private OhosAudioNative() { }

    /** 路径由 JVM 创建前的宿主冻结；缺失或相对路径不能回退到任意系统同名库。 */
    private static synchronized void ensureLoaded() throws LineUnavailableException {
        if (loaded) return;
        String path = System.getProperty("amcl.audio.jni.path", "");
        if (path.length() == 0 || !new File(path).isAbsolute())
            throw new LineUnavailableException("AMCL audio JNI absolute path is not configured");
        try {
            // 系统加载域中的桥是唯一合法 owner。child-first 重新定义同名类不能另装一份 JNI，
            // 也不能通过本类的一份新静态 loaded 标记绕过原加载域所有权。
            Class<?> canonical = Class.forName(OhosAudioNative.class.getName(), false, ClassLoader.getSystemClassLoader());
            if (canonical != OhosAudioNative.class)
                throw new LineUnavailableException("AMCL audio JNI bridge was redefined by a child ClassLoader");
        } catch (ClassNotFoundException failure) {
            throw new LineUnavailableException("AMCL audio JNI bridge is absent from launcher loading domain");
        }
        try { System.load(path); loaded = true; }
        catch (LinkageError error) {
            LineUnavailableException failure = new LineUnavailableException("AMCL audio JNI unavailable: " + error);
            failure.initCause(error); throw failure;
        }
    }

    /** 编码 1=S16LE、2=F32LE；native 保证系统协商/重采样不改变 Java 端声明格式。 */
    public static native long nOpen(boolean capture, int rate, int channels, int encoding, int bufferBytes)
        throws LineUnavailableException;
    public static native void nStart(long id);
    public static native void nStop(long id);
    public static native void nFlush(long id);
    /** 非阻塞补齐当前输入段的转换尾帧；Clip 仍依据真实呈现帧确认完成。 */
    public static native void nRequestFinish(long id);
    public static native void nDrain(long id);
    public static native void nClose(long id);
    public static native int nRead(long id, byte[] data, int offset, int length);
    public static native int nWrite(long id, byte[] data, int offset, int length);
    public static native int nAvailable(long id);
    public static native int nBufferSize(long id);
    /** OPEN=1、RUNNING=2、ACTIVE=4、FAILED=8；ACTIVE 表示实际数据流转，不表示仅收到 start。 */
    public static native int nState(long id);
    public static native long nFramePosition(long id);

    /** 纯转发实现；native 阻塞期间不持有 Java 监视器或数组 critical pin。 */
    private static final class NativeBackend implements AudioBackend {
        public long open(boolean capture, int rate, int channels, int encoding, int bytes) throws LineUnavailableException {
            ensureLoaded(); return nOpen(capture, rate, channels, encoding, bytes);
        }
        public void start(long id) { nStart(id); }
        public void stop(long id) { nStop(id); }
        public void flush(long id) { nFlush(id); }
        public void requestFinish(long id) { nRequestFinish(id); }
        public void drain(long id) { nDrain(id); }
        public void close(long id) { nClose(id); }
        public int read(long id, byte[] b, int o, int n) { return nRead(id, b, o, n); }
        public int write(long id, byte[] b, int o, int n) { return nWrite(id, b, o, n); }
        public int available(long id) { return nAvailable(id); }
        public int bufferSize(long id) { return nBufferSize(id); }
        public int state(long id) { return nState(id); }
        public long framePosition(long id) { return nFramePosition(id); }
    }
}
