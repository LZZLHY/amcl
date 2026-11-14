/** 命名模块中的真实调用方声明 SPI uses；同一探针 JAR 也可交给 Knot 作为普通游戏侧 JAR。 */
module amcl.audio.loader.probe {
    requires java.desktop;
    uses javax.sound.sampled.spi.MixerProvider;
    exports com.amcl.audioprobe;
}
