import com.k2fsa.sherpa.onnx.*;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Locale;
import javax.sound.sampled.*;

/**
 * 单次完整离线语音链。真实原Piper→Fake系统输入→生产JavaSound/JNI/PCM→原Whisper
 * →原Piper回复→生产SourceDataLine/JNI/PCM→Fake系统播放采样。唯一模拟部分为系统设备，
 * 不是拼接独立测试日志，不使用假识别器/合成器，也不声称麦克风/扬声器或云AI已通过。
 */
public final class VoiceChain {
    private static native int begin();
    private static native long feedPcm(float[] samples,int sampleRate);
    private static native void consume();
    private static native double[] playbackStats();
    private static native void end();
    private static void check(boolean value,String reason){if(!value)throw new AssertionError(reason);}
    /** 根据原Verity模型资源构造真实Piper配置，不替换模型/音色/词典。 */
    private static OfflineTts createTts(Path root){
        Path tts=root.resolve("tts");
        OfflineTtsVitsModelConfig vits=OfflineTtsVitsModelConfig.builder()
            .setModel(tts.resolve("en_US-ryan-medium.onnx").toString())
            .setTokens(tts.resolve("tokens.txt").toString())
            .setDataDir(tts.resolve("espeak-ng-data").toString()).build();
        return new OfflineTts(OfflineTtsConfig.builder().setModel(OfflineTtsModelConfig.builder()
            .setVits(vits).setNumThreads(2).setDebug(false).build()).build());
    }
    /** 保留真实回调计数/能量，生成后原生引擎完整释放。 */
    private static GeneratedAudio synthesize(Path root,String text,long[] callbacks){
        OfflineTts engine=createTts(root);
        try{GenerationConfig config=new GenerationConfig();config.setSid(0);config.setSpeed(1.0f);
            return engine.generateWithConfigAndCallback(text,config,(OfflineTtsCallback)samples->{callbacks[0]++;return 1;});
        }finally{engine.release();}
    }
    /** 识别输入只能来自上面真正TargetDataLine读取的PCM，不能绕回原Piper数组。 */
    private static String recognize(Path root,byte[] bytes){
        float[] samples=new float[bytes.length/2];for(int i=0;i<samples.length;i++)
            samples[i]=(short)((bytes[i*2]&255)|((bytes[i*2+1]&255)<<8))/32768.0f;
        Path asr=root.resolve("asr");OfflineWhisperModelConfig whisper=OfflineWhisperModelConfig.builder()
            .setEncoder(asr.resolve("tiny.en-encoder.int8.onnx").toString())
            .setDecoder(asr.resolve("tiny.en-decoder.int8.onnx").toString()).build();
        OfflineRecognizer recognizer=new OfflineRecognizer(OfflineRecognizerConfig.builder().setOfflineModelConfig(
            OfflineModelConfig.builder().setWhisper(whisper).setTokens(asr.resolve("tiny.en-tokens.txt").toString())
                .setNumThreads(2).setDebug(false).build()).build());
        OfflineStream stream=recognizer.createStream();
        try{stream.acceptWaveform(samples,16000);recognizer.decode(stream);return recognizer.getResult(stream).getText();}
        finally{stream.release();recognizer.release();}
    }
    public static void main(String[] args)throws Exception{
        Path modelRoot=Paths.get(args[0]),nativeRoot=Paths.get(args[1]);
        System.load(Paths.get(args[2]).toAbsolutePath().toString());check(begin()==0,"host begin");
        System.load(nativeRoot.resolve("libonnxruntime.so").toAbsolutePath().toString());
        // 原绑定仍负责JNI加载；显式ORT只防宿主错命中其他版本，不改原Java/JNI ABI。
        String initial="Hello world. This is a test.";long[] firstCallbacks={0};
        GeneratedAudio prompt=synthesize(modelRoot,initial,firstCallbacks);
        check(firstCallbacks[0]>0&&prompt.getSamples().length>prompt.getSampleRate(),"real Piper prompt");
        AudioFormat input=new AudioFormat(16000,16,1,true,false);
        TargetDataLine capture=AudioSystem.getTargetDataLine(input);
        int expectedFrames=(int)(((long)prompt.getSamples().length*16000+prompt.getSampleRate()-1)/prompt.getSampleRate());
        byte[] captured=new byte[expectedFrames*2];
        try{
            capture.open(input,captured.length+64);capture.start();
            long systemFrames=feedPcm(prompt.getSamples(),prompt.getSampleRate());check(systemFrames>0,"Fake input data");
            check(capture.read(captured,0,captured.length)==captured.length,"real TargetDataLine capture");
        }finally{capture.close();}
        String recognized=recognize(modelRoot,captured);String lower=recognized.toLowerCase(Locale.ROOT);
        check(lower.contains("test")&&lower.trim().split("\\s+").length>=4,"original Whisper result: "+recognized);
        long[] replyCallbacks={0};GeneratedAudio reply=synthesize(modelRoot,"I heard you say. "+recognized,replyCallbacks);
        float[] replySamples=reply.getSamples();byte[] replyBytes=new byte[replySamples.length*2];
        for(int i=0;i<replySamples.length;i++){
            check(Float.isFinite(replySamples[i]),"reply finite");
            int sample=Math.max(-32768,Math.min(32767,Math.round(replySamples[i]*32768)));
            replyBytes[i*2]=(byte)sample;replyBytes[i*2+1]=(byte)(sample>>8);
        }
        AudioFormat output=new AudioFormat(reply.getSampleRate(),16,1,true,false);
        SourceDataLine playback=AudioSystem.getSourceDataLine(output);
        Thread consumer=new Thread(()->{try{while(!Thread.currentThread().isInterrupted()){consume();Thread.sleep(2);}}
            catch(InterruptedException expected){}});
        long frames;
        try{playback.open(output,8192);playback.start();consumer.start();
            check(playback.write(replyBytes,0,replyBytes.length)==replyBytes.length,"real SourceDataLine write");
            playback.drain();frames=playback.getLongFramePosition();
            check(frames==replySamples.length,"playback actual source frames");
        }finally{playback.close();consumer.interrupt();consumer.join();end();}
        double[] stats=playbackStats();check(stats[0]>0&&stats[1]>0&&replyCallbacks[0]>0,"Fake playback samples");
        double rms=Math.sqrt(stats[1]/stats[0]);check(rms>0.005&&rms<0.8,"playback RMS");
        System.out.println("{\"state\":\"PASS\",\"system\":\"explicit-FakePlatform\",\"captureClass\":\""+
            capture.getClass().getName()+"\",\"playbackClass\":\""+playback.getClass().getName()+
            "\",\"promptRate\":"+prompt.getSampleRate()+",\"promptSamples\":"+prompt.getSamples().length+
            ",\"captured16000Frames\":"+expectedFrames+",\"recognized\":\""+recognized.replace("\"","'")+
            "\",\"replyRate\":"+reply.getSampleRate()+",\"replyFrames\":"+frames+
            ",\"actualSystemSamples\":"+(long)stats[0]+",\"rms\":"+rms+"}");
    }
}
