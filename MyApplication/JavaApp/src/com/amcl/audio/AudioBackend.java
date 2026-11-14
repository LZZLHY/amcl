package com.amcl.audio;

import javax.sound.sampled.LineUnavailableException;

/**
 * 平台流端口。生产只由 OhosAudioNative 实现；测试可在同包内向独立 Mixer 注入明确的宿主驱动。
 * 所有计数均使用调用者格式的字节或帧；阻塞调用必须允许 stop/flush/close 从其他线程解除等待。
 */
interface AudioBackend {
    long open(boolean capture, int rate, int channels, int encoding, int bytes) throws LineUnavailableException;
    void start(long id);
    void stop(long id);
    void flush(long id);
    /** 结束当前已提交的输入段并补齐重采样尾帧；仅发请求，不等待平台消费，flush 可撤销。 */
    void requestFinish(long id);
    void drain(long id);
    void close(long id);
    int read(long id, byte[] data, int offset, int length);
    int write(long id, byte[] data, int offset, int length);
    int available(long id);
    int bufferSize(long id);
    int state(long id);
    long framePosition(long id);
}
