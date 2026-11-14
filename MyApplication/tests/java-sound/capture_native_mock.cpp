/* 只在独立宿主测试加载的SDK精确类型替身。固定合成数据/错误，不访问系统音频。
 * 每条setter都核对正式请求，输入payload变换仅用于验证解释负控能识别已知反例。 */
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiocapturer.h>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>

struct OH_AudioStreamBuilderStruct {
    int rate = -1, channels = -1, format = -1, encoding = -1, source = -1, latency = -1;
    OH_AudioChannelLayout layout = CH_LAYOUT_UNKNOWN;
    OH_AudioCapturer_OnReadDataCallback data = nullptr;
    OH_AudioCapturer_OnErrorCallback error = nullptr;
    OH_AudioCapturer_OnInterruptCallback interrupt = nullptr;
    void *opaque = nullptr;
};
struct OH_AudioCapturerStruct {
    OH_AudioStreamBuilderStruct config;
    uint32_t id = 0;
    std::atomic<bool> running{false};
    std::atomic<int> state{AUDIOSTREAM_STATE_PREPARED};
    std::atomic<int64_t> offered{0};
    std::thread worker;
};
static OH_AudioCapturer *retained;
static unsigned generatedCount, channelSetterCount;
static bool scenario(const char *name) { const char *value = std::getenv("AMCL_CAPTURE_NATIVE_CASE"); return value && !std::strcmp(value, name); }
static bool channelsCase() { const char *value = std::getenv("AMCL_CAPTURE_NATIVE_CASE"); return value && !std::strncmp(value, "channels-", 9); }
static bool noData() { return scenario("no-data") || scenario("startup-no-data") || scenario("channels-no-data"); }
static bool releaseFailure() { return scenario("release-failure") || scenario("startup-release-failure") || scenario("channels-release-failure"); }
static int16_t sample(uint64_t i) { return int16_t(int((i * 157) % 511) - 255); }
/* 不同声道保留相关性，验证平均必须逐帧计算，不能平均两个RMS；包含半整数及S16两端值。 */
static int16_t channelSample(uint64_t frame, unsigned channel)
{
    if (scenario("channels-extremes")) return channel ? 32767 : -32768;
    if (scenario("channels-first-window") && frame < 1920) return channel ? -120 : 32767;
    return channel ? int16_t(int((frame * 73) % 701) - 350) : sample(frame);
}

extern "C" {
OH_AudioStream_Result OH_AudioStreamBuilder_Create(OH_AudioStreamBuilder **out, OH_AudioStream_Type type)
{ assert(type == AUDIOSTREAM_TYPE_CAPTURER); *out = new OH_AudioStreamBuilderStruct; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioStreamBuilder_Destroy(OH_AudioStreamBuilder *builder)
{ delete builder; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioStreamBuilder_SetSamplingRate(OH_AudioStreamBuilder *builder, int32_t value)
{ assert(value == 48000); builder->rate = value; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioStreamBuilder_SetChannelCount(OH_AudioStreamBuilder *builder, int32_t value)
{ assert(value == (channelsCase() && channelSetterCount == 0 ? 2 : 1));
  ++channelSetterCount; builder->channels = value; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioStreamBuilder_SetChannelLayout(OH_AudioStreamBuilder *builder, OH_AudioChannelLayout layout)
{ assert(layout == CH_LAYOUT_MONO); if (scenario("layout-setter-failure")) return AUDIOSTREAM_ERROR_INVALID_PARAM;
  builder->layout = layout; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioStreamBuilder_SetSampleFormat(OH_AudioStreamBuilder *builder, OH_AudioStream_SampleFormat value)
{ assert(value == AUDIOSTREAM_SAMPLE_S16LE); builder->format = value; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioStreamBuilder_SetEncodingType(OH_AudioStreamBuilder *builder, OH_AudioStream_EncodingType value)
{ assert(value == AUDIOSTREAM_ENCODING_TYPE_RAW); builder->encoding = value; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioStreamBuilder_SetCapturerInfo(OH_AudioStreamBuilder *builder, OH_AudioStream_SourceType value)
{ assert(value == AUDIOSTREAM_SOURCE_TYPE_MIC); builder->source = value; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioStreamBuilder_SetLatencyMode(OH_AudioStreamBuilder *builder, OH_AudioStream_LatencyMode value)
{ assert(value == AUDIOSTREAM_LATENCY_MODE_NORMAL || value == AUDIOSTREAM_LATENCY_MODE_FAST); builder->latency = value; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioStreamBuilder_SetCapturerReadDataCallback(OH_AudioStreamBuilder *builder, OH_AudioCapturer_OnReadDataCallback callback, void *opaque)
{ assert(callback && opaque); builder->data = callback; builder->opaque = opaque; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioStreamBuilder_SetCapturerErrorCallback(OH_AudioStreamBuilder *builder, OH_AudioCapturer_OnErrorCallback callback, void *opaque)
{ assert(callback && opaque == builder->opaque); builder->error = callback; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioStreamBuilder_SetCapturerInterruptCallback(OH_AudioStreamBuilder *builder, OH_AudioCapturer_OnInterruptCallback callback, void *opaque)
{ assert(callback && opaque == builder->opaque); builder->interrupt = callback; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioStreamBuilder_GenerateCapturer(OH_AudioStreamBuilder *builder, OH_AudioCapturer **out)
{
    assert(builder->rate == 48000 && (builder->channels == 1 || (channelsCase() && builder->channels == 2)) && builder->format == 1 && !builder->encoding &&
           !builder->source && builder->latency >= 0 && builder->data && builder->error && builder->interrupt);
    if (scenario("channels-generate-failure")) { *out = nullptr; return AUDIOSTREAM_ERROR_SYSTEM; }
    *out = new OH_AudioCapturerStruct; (*out)->config = *builder; (*out)->id = 100 + generatedCount++;
    return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioCapturer_GetSamplingRate(OH_AudioCapturer *stream, int32_t *out)
{ *out = stream->config.rate; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_GetChannelCount(OH_AudioCapturer *stream, int32_t *out)
{ *out = scenario("channels-wrong-count") ? 1 : stream->config.channels; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_GetSampleFormat(OH_AudioCapturer *stream, OH_AudioStream_SampleFormat *out)
{ *out = OH_AudioStream_SampleFormat(scenario("wrong-format") ? 2 : stream->config.format); return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_GetEncodingType(OH_AudioCapturer *stream, OH_AudioStream_EncodingType *out)
{ *out = OH_AudioStream_EncodingType(stream->config.encoding); return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_GetCapturerInfo(OH_AudioCapturer *stream, OH_AudioStream_SourceType *out)
{ *out = OH_AudioStream_SourceType(stream->config.source); return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_GetLatencyMode(OH_AudioCapturer *stream, OH_AudioStream_LatencyMode *out)
{ *out = OH_AudioStream_LatencyMode(scenario("fast-fallback") || scenario("channels-fallback") ? 0 : stream->config.latency); return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_GetFastStatus(OH_AudioCapturer *stream, OH_AudioStream_FastStatus *out)
{ *out = OH_AudioStream_FastStatus(scenario("fast-fallback") || scenario("channels-fallback") ? 0 : stream->config.latency); return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_GetFrameSizeInCallback(OH_AudioCapturer *stream, int32_t *out)
{ *out = scenario("startup-split") || scenario("channels-split") ? 347 : stream->config.latency ? 240 : 960; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_GetCurrentState(OH_AudioCapturer *stream, OH_AudioStream_State *out)
{ *out = OH_AudioStream_State(stream->state.load()); return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_GetOverflowCount(OH_AudioCapturer *, uint32_t *out)
{ *out = scenario("channels-overflow") ? 1 : 0; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_GetFramesRead(OH_AudioCapturer *stream, int64_t *out)
{ *out = scenario("channels-short-platform-count") ? 9599 : stream->offered.load(); return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_GetStreamId(OH_AudioCapturer *stream, uint32_t *out)
{ *out = stream->id + (scenario("channels-id-change") && stream->state == AUDIOSTREAM_STATE_RUNNING ? 1 : 0);
  return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_Start(OH_AudioCapturer *stream)
{
    stream->running = true; stream->state = AUDIOSTREAM_STATE_RUNNING;
    stream->worker = std::thread([stream] {
        uint64_t first = 0;
        while (stream->running) {
            if (!noData()) {
                const unsigned frames = scenario("startup-split") || scenario("channels-split") ? 347 : stream->config.latency ? 240 : 960;
                unsigned char bytes[3840];
                for (unsigned i = 0; i < frames; ++i) {
                    if (channelsCase()) {
                        for (unsigned channel = 0; channel < unsigned(stream->config.channels); ++channel) {
                            const uint16_t value = uint16_t(channelSample(first + i, channel));
                            const size_t offset = (size_t(i) * stream->config.channels + channel) * 2;
                            bytes[offset] = uint8_t(value); bytes[offset + 1] = uint8_t(value >> 8);
                        }
                        continue;
                    }
                    uint16_t value = uint16_t(sample(first + i));
                    if (scenario("layout-response") && stream->config.layout == CH_LAYOUT_UNKNOWN) value = 30000;
                    // 固定首窗满幅；后续回到已知合成低幅，验证不会丢首段或扩错窗口。
                    if ((scenario("layout-windows") || scenario("startup-windows") || scenario("startup-split")) &&
                        first + i < 1920) value = 32767;
                    bytes[i * 2] = uint8_t(value); bytes[i * 2 + 1] = uint8_t(value >> 8);
                    if (scenario("swapped") && stream->config.latency) std::swap(bytes[i * 2], bytes[i * 2 + 1]);
                }
                if (scenario("float-payload") && stream->config.latency) {
                    for (unsigned i = 0; i < frames / 2; ++i) {
                        float value = float(int((first / 2 + i) % 201) - 100) / 200;
                        uint32_t bits; std::memcpy(&bits, &value, 4);
                        for (unsigned b = 0; b < 4; ++b) bytes[i * 4 + b] = uint8_t(bits >> (b * 8));
                    }
                }
                const int incomplete = scenario("odd-length") ? 1 : scenario("channels-half-frame") ? 2 : 0;
                stream->config.data(stream, stream->config.opaque, bytes, int(frames * 2 * stream->config.channels) - incomplete);
                stream->offered += frames; first += frames;
                if (scenario("callback-error") || scenario("startup-error") || scenario("channels-error")) stream->config.error(stream, stream->config.opaque, AUDIOSTREAM_ERROR_SYSTEM);
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    });
    return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioCapturer_Stop(OH_AudioCapturer *stream)
{ stream->running = false; if (stream->worker.joinable()) stream->worker.join(); stream->state = AUDIOSTREAM_STATE_STOPPED;
  return scenario("channels-stop-failure") ? AUDIOSTREAM_ERROR_SYSTEM : AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_Release(OH_AudioCapturer *stream)
{
    assert(!stream->worker.joinable());
    if (releaseFailure()) { retained = stream; return AUDIOSTREAM_ERROR_SYSTEM; }
    delete stream; return AUDIOSTREAM_SUCCESS;
}
/* 已返回失败收据后再调用原userdata，ASan证明探针没有为了假“回收”而提前释放它。 */
void amcl_capture_native_test_late_callback(void)
{
    assert(retained); unsigned char bytes[2] = {1, 2};
    retained->config.data(retained, retained->config.opaque, bytes, sizeof(bytes));
    retained->config.error(retained, retained->config.opaque, AUDIOSTREAM_ERROR_SYSTEM);
    delete retained; retained = nullptr;
}
}
