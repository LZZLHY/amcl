/*
 * 使用真实 Verity 绑定与原模型执行宿主离线合成→识别，不模拟引擎。
 * 只消费调用者给出的外置目录；采样验证、回调计数、非空识别均为运行后的实际值。
 */
import com.k2fsa.sherpa.onnx.*;
import java.nio.file.Path;

public final class VeritySherpaProbe {
    /** 创建原 Piper 模型并回收原生对象，再用同包 Whisper 识别实际生成的声音。 */
    public static void main(String[] args) throws Exception {
        Path root = Path.of(args[0]);
        // Windows 的依赖搜索可能先命中 System32 自带的旧 ORT，先按原资源加载器的
        // 顺序加载同一真实模组内的 ORT，再让原 Sherpa 类加载它自己的 JNI。此操作
        // 只属于宿主夹具；OHOS 的依赖闭包由正式加载路径及 ELF NEEDED 另行验证。
        Path nativePath = args.length > 1 ? Path.of(args[1]) : root.resolve("native");
        System.load(nativePath.resolve("onnxruntime.dll").toAbsolutePath().toString());
        Path tts = root.resolve("tts");
        Path asr = root.resolve("asr");
        OfflineTtsVitsModelConfig vits = OfflineTtsVitsModelConfig.builder()
            .setModel(tts.resolve("en_US-ryan-medium.onnx").toString())
            .setTokens(tts.resolve("tokens.txt").toString())
            .setDataDir(tts.resolve("espeak-ng-data").toString()).build();
        OfflineTtsConfig ttsConfig = OfflineTtsConfig.builder().setModel(
            OfflineTtsModelConfig.builder().setVits(vits).setNumThreads(2).setDebug(false).build()).build();
        OfflineTts engine = new OfflineTts(ttsConfig);
        final long[] callbacks = {0};
        GeneratedAudio generated;
        try {
            GenerationConfig generation = new GenerationConfig();
            generation.setSid(0);
            generation.setSpeed(1.0f);
            generated = engine.generateWithConfigAndCallback("Hello world. This is a test.", generation,
                (OfflineTtsCallback) samples -> { callbacks[0]++; return 1; });
        } finally {
            engine.release();
        }
        float[] samples = generated.getSamples();
        int sampleRate = generated.getSampleRate();
        double energy = 0;
        for (float sample : samples) {
            if (!Float.isFinite(sample)) throw new AssertionError("合成包含非有限样本");
            energy += sample * sample;
        }
        if (samples.length < sampleRate || energy <= 0 || callbacks[0] == 0)
            throw new AssertionError("合成未产生有效的实际声音/回调");
        OfflineWhisperModelConfig whisper = OfflineWhisperModelConfig.builder()
            .setEncoder(asr.resolve("tiny.en-encoder.int8.onnx").toString())
            .setDecoder(asr.resolve("tiny.en-decoder.int8.onnx").toString()).build();
        OfflineRecognizerConfig recognizerConfig = OfflineRecognizerConfig.builder()
            .setOfflineModelConfig(OfflineModelConfig.builder().setWhisper(whisper)
                .setTokens(asr.resolve("tiny.en-tokens.txt").toString()).setNumThreads(2).setDebug(false).build()).build();
        OfflineRecognizer recognizer = new OfflineRecognizer(recognizerConfig);
        String text;
        OfflineStream stream = recognizer.createStream();
        try {
            stream.acceptWaveform(samples, sampleRate);
            recognizer.decode(stream);
            text = recognizer.getResult(stream).getText();
        } finally {
            stream.release();
            recognizer.release();
        }
        String lower = text.toLowerCase(java.util.Locale.ROOT);
        // 此项是原模型推理链的烟测而非识别质量基准。Piper 含随机噪声，Whisper
        // tiny 对短句存在 hello/a low、this/these 的正常误识别；保留完整原文，
        // 仅要求固定句的 test 锚点及至少四个词，不能把误识别率冒称为零。
        if (!lower.contains("test") || lower.trim().split("\\s+").length < 4)
            throw new AssertionError("真实识别结果不符合固定样本：" + text);
        System.out.println("{\"state\":\"PASS\",\"sampleRate\":" + sampleRate +
            ",\"samples\":" + samples.length + ",\"callbacks\":" + callbacks[0] +
            ",\"rms\":" + Math.sqrt(energy / samples.length) + ",\"recognized\":\"" + text + "\"}");
    }
}
