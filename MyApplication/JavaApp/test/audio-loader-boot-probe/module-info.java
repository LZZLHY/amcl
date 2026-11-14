/** MC-BOOTSTRAP 与 GAME 使用不同模块名，确保两层都由各自的实际 Forge 加载器定义调用方。 */
module amcl.audio.loader.boot.probe {
    requires java.desktop;
    uses javax.sound.sampled.spi.MixerProvider;
    exports com.amcl.audioprobe;
}
