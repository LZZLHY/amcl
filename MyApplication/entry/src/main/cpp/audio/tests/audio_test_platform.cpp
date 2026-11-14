/**
 * 仅宿主测试显式编入的系统适配器。生产CMake永不引用此文件；JNI/宿主表/Runtime均使用
 * 真实生产源码，只有系统设备由本文件替代，以测试Linux宿主上的实际JNI与namespace链路。
 */
#include "../../jvm/jni.h"
#include "../audio_core.h"
#include <atomic>
#include <chrono>
#include <cmath>
#include <mutex>
#include <thread>
namespace {
struct TestPlatform final : amcl::audio::PlatformStream {
    std::mutex callbackMutex;
    bool running = false;
    amcl::audio::PresentationTimeline presentation;
    std::atomic<uint64_t> hardwarePosition{0};
    uint64_t submitted = 0;
    /** Fake也遵守stop后回调静止契约，允许Java seek/flush与消费线程并发验收。 */
    bool start() override {
        std::lock_guard<std::mutex> lock(callbackMutex);
        running = true;
        return true;
    }
    bool stop() override {
        std::lock_guard<std::mutex> lock(callbackMutex);
        running = false;
        return true;
    }
    bool close() override { return stop(); }
    void refreshPresentation() override { transferred = presentation.present(hardwarePosition.load()); }
    bool flush() override {
        std::lock_guard<std::mutex> lock(callbackMutex);
        refreshPresentation();
        presentation.reset();
        hardwarePosition = 0;
        submitted = 0;
        return true;
    }
};
std::mutex selectedMutex;
std::shared_ptr<TestPlatform> capture, render;
std::atomic<int> permission{1};
uint64_t renderedSamples = 0;
double renderedEnergy = 0;
int checkPermission(void *) { return permission.load(); }
} // namespace
namespace amcl::audio {
std::shared_ptr<PlatformStream> openOhaudio(bool input) {
    auto p = std::make_shared<TestPlatform>();
    p->channels = input ? 1 : 2;
    std::lock_guard<std::mutex> lock(selectedMutex);
    if (input)
        capture = p;
    else
        render = p;
    return p;
}
} // namespace amcl::audio
extern "C" JNIEXPORT jint JNICALL Java_AudioNativeSmoke_begin(JNIEnv *, jclass) {
    if (amclAudioHostPublishEarlyV1() != 0)
        return -1;
    return amclAudioHostBeginV1(123, checkPermission, nullptr, 1);
}
extern "C" JNIEXPORT void JNICALL Java_AudioNativeSmoke_feed(JNIEnv *, jclass, jint frames) {
    std::lock_guard<std::mutex> lock(selectedMutex);
    if (!capture)
        return;
    std::vector<float> samples(static_cast<size_t>(frames), 0.5f);
    capture->ring.push(samples.data(), samples.size());
}
extern "C" JNIEXPORT void JNICALL Java_AudioNativeSmoke_consume(JNIEnv *, jclass) {
    std::lock_guard<std::mutex> lock(selectedMutex);
    if (!render)
        return;
    std::lock_guard<std::mutex> callback(render->callbackMutex);
    if (!render->running)
        return;
    float samples[8192];
    const auto count = render->ring.pop(samples, 8192);
    renderedSamples += count;
    for (size_t i = 0; i < count; ++i)
        renderedEnergy += samples[i] * samples[i];
    render->dataActive = count != 0;
    // 夹具显式使回调交付与呈现同步；生产OHAudio仍只通过真实GetTimestamp推进。
    const auto frames = count / render->channels;
    if (!render->presentation.submit(frames, frames))
        render->event = 9;
    render->submitted += frames;
    render->hardwarePosition = render->submitted;
}
extern "C" JNIEXPORT void JNICALL Java_AudioNativeSmoke_deny(JNIEnv *, jclass) {
    permission = 0;
    amclAudioHostRefreshPermissionV1(123);
}
extern "C" JNIEXPORT void JNICALL Java_AudioNativeSmoke_end(JNIEnv *, jclass) { amclAudioHostEndV1(123); }

/** 下列入口只属于完整离线语音链夹具，不加入生产函数表。 */
extern "C" JNIEXPORT jint JNICALL Java_VoiceChain_begin(JNIEnv *env, jclass type) {
    return Java_AudioNativeSmoke_begin(env, type);
}
extern "C" JNIEXPORT void JNICALL Java_VoiceChain_end(JNIEnv *env, jclass type) {
    Java_AudioNativeSmoke_end(env, type);
}
extern "C" JNIEXPORT void JNICALL Java_VoiceChain_consume(JNIEnv *env, jclass type) {
    Java_AudioNativeSmoke_consume(env, type);
}
/** 原Piper样本经生产Converter变为Fake系统48000Hz采集数据，分块有界投递到生产ring。 */
extern "C" JNIEXPORT jlong JNICALL Java_VoiceChain_feedPcm(JNIEnv *env, jclass, jfloatArray data, jint rate) {
    const auto length = env->GetArrayLength(data);
    if (length <= 0 || length > 10000000 || rate < 8000 || rate > 192000)
        return -1;
    std::vector<float> original(static_cast<size_t>(length));
    env->GetFloatArrayRegion(data, 0, length, original.data());
    if (env->ExceptionCheck())
        return -1;
    amcl::audio::Converter converter(rate, 48000, 1, 1);
    std::vector<float> converted, tail;
    converter.convert(original.data(), original.size(), converted);
    converter.finish(tail);
    converted.insert(converted.end(), tail.begin(), tail.end());
    std::shared_ptr<TestPlatform> stream;
    {
        std::lock_guard<std::mutex> lock(selectedMutex);
        stream = capture;
    }
    if (!stream)
        return -1;
    size_t offset = 0;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
    while (offset < converted.size()) {
        const auto count =
            stream->ring.push(converted.data() + offset, std::min<size_t>(4800, converted.size() - offset));
        offset += count;
        stream->transferred += count;
        stream->dataActive = count != 0;
        if (std::chrono::steady_clock::now() > deadline)
            return -1;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    return static_cast<jlong>(offset);
}
/** 读回实际Fake播放端消费的样本/能量，不能用Java写入长度自证已经出声。 */
extern "C" JNIEXPORT jdoubleArray JNICALL Java_VoiceChain_playbackStats(JNIEnv *env, jclass) {
    std::lock_guard<std::mutex> lock(selectedMutex);
    const jdouble values[]{static_cast<double>(renderedSamples), renderedEnergy};
    auto result = env->NewDoubleArray(2);
    if (result)
        env->SetDoubleArrayRegion(result, 0, 2, values);
    return result;
}
