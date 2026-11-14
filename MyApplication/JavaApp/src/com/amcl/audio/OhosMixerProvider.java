package com.amcl.audio;

import javax.sound.sampled.Mixer;
import javax.sound.sampled.spi.MixerProvider;

/** 标准 Java Sound 服务入口。枚举只创建轻量 Java 描述，权限检查和设备申请延迟到 line.open。 */
public final class OhosMixerProvider extends MixerProvider {
    private static final OhosMixer MIXER = new OhosMixer(OhosAudioNative.BACKEND);
    public OhosMixerProvider() { }
    public Mixer.Info[] getMixerInfo() { return new Mixer.Info[]{OhosMixer.INFO}; }
    public Mixer getMixer(Mixer.Info info) {
        if (info == null || info == OhosMixer.INFO) return MIXER;
        throw new IllegalArgumentException("Unknown AMCL mixer: " + info);
    }
}
