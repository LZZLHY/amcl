package com.amcl.audio;

import javax.sound.sampled.*;

/**
 * 标准 TargetDataLine 的麦克风 PCM 读取边界，采集实例、状态与监听器由 OhosDataLine 管理。
 * 采集保持调用方的声道数；native 负责系统格式转换并交付 little endian 的 S16/F32 PCM，
 * 本类只在必要时原地翻转样本字节序，不生成虚假录音或在阻塞 read 中发起 UI 授权。
 * 实际权限、前后台与采集意图由宿主/native 核验；stop/flush/close 的取消由同一流句柄传递。
 */
final class OhosTargetDataLine extends OhosDataLine implements TargetDataLine {
    /** 标记为采集流；枚举或创建 Java 对象不申请设备，真实资源在 open 时才取得。 */
    OhosTargetDataLine(OhosMixer mixer, AudioFormat format) { super(mixer, format, true); }
    /** 返回调用者可见的采集格式，SPI 的能力查询不会因此打开麦克风。 */
    public Line.Info getLineInfo() { return new DataLine.Info(TargetDataLine.class, format); }
    /** 使用该格式约 200ms 的默认队列；仍由共享 openFormat 校验支持表和完整帧。 */
    public void open(AudioFormat format) throws LineUnavailableException { open(format, AudioFormats.defaultBuffer(format)); }
    /** bytes 是调用方格式的缓冲字节数；共享入口负责上限、权限、native 失败及句柄发布事务。 */
    public void open(AudioFormat format, int bytes) throws LineUnavailableException { openFormat(format, bytes); }
    /**
     * 将真实采集 PCM 写入指定数组片段；length 必须包含完整帧，offset 可指向任意有效数组位置。
     * 正常等待数据或按 native 的取消结果返回短读；关闭竞争已退休句柄时返回零，其他故障保持可见。
     * 仅转换实际返回的字节，不改写片段之外的内容；只有当前句柄仍相同时才观察和派发流状态。
     */
    public int read(byte[] data, int offset, int length) {
        AudioFormats.range(data, offset, length, format.getFrameSize());
        long value = requireHandle(); if (length == 0) return 0;
        int read;
        try { read = backend.read(value, data, offset, length); }
        catch (RuntimeException failure) { if (handle == 0) return 0; throw failure; }
        if (read < 0 || read > length || read % format.getFrameSize() != 0)
            throw new IllegalStateException("Platform returned invalid PCM read count");
        // 平台桥统一返回 little endian；每个样本独立翻转，不能整帧反转而交换左右声道。
        if (format.isBigEndian()) {
            int sample = format.getSampleSizeInBits() / 8;
            for (int i = offset; i < offset + read; i += sample)
                for (int b = 0; b < sample / 2; b++) { byte tmp = data[i + b]; data[i + b] = data[i + sample - 1 - b]; data[i + sample - 1 - b] = tmp; }
        }
        if (handle == value) observe(); return read;
    }
}
