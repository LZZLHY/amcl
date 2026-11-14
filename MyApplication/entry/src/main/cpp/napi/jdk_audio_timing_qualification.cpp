/** 观察系统呈现时钟与实际提交的关系，不实现或替换产品的drain算法。
 * 两段44100Hz/S16/stereo、250ms固定低幅度PCM；每段最多1秒、20次采样，中间真实
 * Pause/Flush/Start。第一段保留原0返回，第二段用户PCM结束后最多再实际提交250ms
 * 静音，用户/静音/平台字节分开观察。代码正常编入签名HAP，不经自加载或CFI旁路。 */
#include "jdk_audio_timing_qualification.h"
#ifdef MC_OHOS_BUILD_TESTS
#include "../javasound/ohos_daudio_callbacks.h"
#include "../../../../../tests/java-sound/daudio_zero_return_reference.h"
#include "../platform/jdk_install_io.h"
#include <chrono>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <dlfcn.h>
#include <sstream>
#include <stdexcept>
#include <thread>
#include <vector>

namespace amcl::jdkqualification {
namespace {
namespace io = amcl::jdk::io;
using Clock = std::chrono::steady_clock;

/** 只转义诊断文本，固定字段和所有计数由本文件产生，不消费Want提供的任意脚本/路径。 */
std::string Quote(const std::string& text) {
    std::string result = "\"";
    for (unsigned char value : text) {
        if (value == '"' || value == '\\') { result += '\\'; result += char(value); }
        else if (value < 32) { char encoded[7]; snprintf(encoded, sizeof(encoded), "\\u%04x", value); result += encoded; }
        else result += char(value);
    }
    return result + '"';
}

#define AMCL_TIMING_APIS(X) \
    X(OH_AudioStreamBuilder_Create) X(OH_AudioStreamBuilder_Destroy) \
    X(OH_AudioStreamBuilder_SetSamplingRate) X(OH_AudioStreamBuilder_SetChannelCount) \
    X(OH_AudioStreamBuilder_SetSampleFormat) X(OH_AudioStreamBuilder_SetEncodingType) \
    X(OH_AudioStreamBuilder_SetLatencyMode) X(OH_AudioStreamBuilder_SetRendererInfo) \
    X(OH_AudioStreamBuilder_SetRendererWriteDataCallbackAdvanced) \
    X(OH_AudioStreamBuilder_SetRendererErrorCallback) X(OH_AudioStreamBuilder_SetRendererInterruptCallback) \
    X(OH_AudioStreamBuilder_GenerateRenderer) X(OH_AudioRenderer_SetVolume) \
    X(OH_AudioRenderer_GetSamplingRate) X(OH_AudioRenderer_GetChannelCount) \
    X(OH_AudioRenderer_GetSampleFormat) X(OH_AudioRenderer_GetEncodingType) \
    X(OH_AudioRenderer_GetFrameSizeInCallback) X(OH_AudioRenderer_Start) X(OH_AudioRenderer_Pause) \
    X(OH_AudioRenderer_Flush) X(OH_AudioRenderer_Release) X(OH_AudioRenderer_GetCurrentState) \
    X(OH_AudioRenderer_GetFramesWritten) X(OH_AudioRenderer_GetTimestamp) X(OH_AudioRenderer_GetAudioTimestampInfo)

/** 只按官方NDK basename正常系统装载。完整函数类型来自SDK，不让TestHooks添加生产强依赖。 */
struct Api {
    void* handle = nullptr;
    bool retained = false;
    std::string path;
#define AMCL_DECLARE(name) decltype(&::name) name = nullptr;
    AMCL_TIMING_APIS(AMCL_DECLARE)
#undef AMCL_DECLARE
    void Load() {
        handle = dlopen("libohaudio.so", RTLD_NOW | RTLD_LOCAL);
        if (!handle) { const char* error = dlerror(); throw std::runtime_error(error ? error : "dlopen libohaudio failed"); }
        void* base = nullptr;
#define AMCL_LOAD(name) \
        name = reinterpret_cast<decltype(name)>(dlsym(handle, #name)); \
        if (!name) throw std::runtime_error("missing SDK function " #name); \
        { Dl_info info{}; if (!dladdr(reinterpret_cast<const void*>(name), &info) || !info.dli_fbase || !info.dli_fname) \
              throw std::runtime_error("unresolved SDK owner " #name); \
          if (!base) { base = info.dli_fbase; path = info.dli_fname; } \
          else if (base != info.dli_fbase) throw std::runtime_error("mixed SDK owner " #name); }
        AMCL_TIMING_APIS(AMCL_LOAD)
#undef AMCL_LOAD
    }
    ~Api() { if (handle && !retained) dlclose(handle); }
};
#undef AMCL_TIMING_APIS

struct Context {
    AmclCallback callback{}; // 六个同源事件入口接受此首成员，实际布局在编译期核验。
    uint64_t calls = 0, requested = 0, returned = 0, zeros = 0;
    uint64_t userReturned = 0, silenceReturned = 0;
    int dataActive = 0;
    int paddingRemaining = 0; // 仅第二段Start前设定，callback递减；不是据墙钟伪造的播放进度。
};
static_assert(offsetof(Context, callback) == 0, "timing callback context prefix");

/** 第一段直接保留同源PCM结果；第二段只在11025帧用户数据全部消费后填有界真实静音。
 * read/userReturned只计原用户字节；平台返回长度另计，不能把静音算作Java播放完成。 */
int32_t TimingData(OH_AudioRenderer* renderer, void* opaque, void* data, int32_t bytes) {
    auto* context = static_cast<Context*>(opaque);
    // 外层观察也纳入active：inner返回后仍会写计数，不能让Cleanup在该窄窗口释放ctx。
    __atomic_add_fetch(&context->callback.active, 1U, __ATOMIC_SEQ_CST);
    __atomic_add_fetch(&context->calls, UINT64_C(1), __ATOMIC_RELAXED);
    if (bytes > 0) __atomic_add_fetch(&context->requested, uint64_t(bytes), __ATOMIC_RELAXED);
    int expected = 0;
    if (!__atomic_compare_exchange_n(&context->dataActive, &expected, 1, false, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
        __atomic_add_fetch(&context->zeros, UINT64_C(1), __ATOMIC_RELAXED);
        __atomic_sub_fetch(&context->callback.active, 1U, __ATOMIC_SEQ_CST);
        return 0;
    }
    const int32_t user = amcl_timing_zero_return_reference(renderer, &context->callback, data, bytes);
    int32_t count = user;
    auto* line = __atomic_load_n(&context->callback.owner, __ATOMIC_SEQ_CST);
    const int budget = __atomic_load_n(&context->paddingRemaining, __ATOMIC_RELAXED);
    if (line && data && bytes > 0 && budget > 0 &&
        __atomic_load_n(&line->copyEnabled, __ATOMIC_SEQ_CST) &&
        !__atomic_load_n(&line->error, __ATOMIC_SEQ_CST) &&
        __atomic_load_n(&line->interrupt, __ATOMIC_SEQ_CST) != AUDIOSTREAM_INTERRUPT_HINT_PAUSE &&
        __atomic_load_n(&line->read, __ATOMIC_ACQUIRE) == UINT64_C(44100)) {
        const int room = bytes - bytes % line->frameSize - user;
        const int padding = std::min(room, budget);
        if (padding > 0) {
            memset(static_cast<unsigned char*>(data) + user, 0, size_t(padding));
            count += padding;
            __atomic_store_n(&context->paddingRemaining, budget - padding, __ATOMIC_RELAXED);
            __atomic_add_fetch(&context->silenceReturned, uint64_t(padding), __ATOMIC_RELAXED);
        }
    }
    if (user > 0) __atomic_add_fetch(&context->userReturned, uint64_t(user), __ATOMIC_RELAXED);
    if (count > 0) __atomic_add_fetch(&context->returned, uint64_t(count), __ATOMIC_RELAXED);
    else __atomic_add_fetch(&context->zeros, UINT64_C(1), __ATOMIC_RELAXED);
    __atomic_store_n(&context->dataActive, 0, __ATOMIC_RELEASE);
    __atomic_sub_fetch(&context->callback.active, 1U, __ATOMIC_SEQ_CST);
    return count;
}

bool Quiescent(Context* context) {
    for (int count = 0; count < 1000; ++count) {
        if (!__atomic_load_n(&context->callback.active, __ATOMIC_SEQ_CST)) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return !__atomic_load_n(&context->callback.active, __ATOMIC_SEQ_CST);
}

/** 逐API保存原状态码；没有把非法暂停查询、空指针或系统错误改写成成功。 */
struct Probe {
    Api api;
    Context* context = nullptr;
    AmclLine* line = nullptr;
    OH_AudioStreamBuilder* builder = nullptr;
    std::ostringstream records;
    bool first = true;
    std::string stage = "load-sdk";
    const Clock::time_point started = Clock::now();
    void Item(const std::string& value) { if (!first) records << ','; first = false; records << value; }
    void Result(const char* name, OH_AudioStream_Result result, bool require = true) {
        Item("{\"call\":" + Quote(name) + ",\"result\":" + std::to_string(int(result)) + '}');
        if (require && result != AUDIOSTREAM_SUCCESS)
            throw std::runtime_error(std::string(name) + " result=" + std::to_string(int(result)));
    }
    void Snapshot(const char* phase, int index) {
        int64_t written = -1, oldFrame = -1, oldTime = -1, newFrame = -1, newTime = -1;
        OH_AudioStream_State state = AUDIOSTREAM_STATE_INVALID;
        const auto stateResult = api.OH_AudioRenderer_GetCurrentState(line->renderer, &state);
        const auto writtenResult = api.OH_AudioRenderer_GetFramesWritten(line->renderer, &written);
        const auto oldResult = api.OH_AudioRenderer_GetTimestamp(line->renderer, CLOCK_MONOTONIC, &oldFrame, &oldTime);
        const auto newResult = api.OH_AudioRenderer_GetAudioTimestampInfo(line->renderer, &newFrame, &newTime);
        std::ostringstream row;
        row << "{\"phase\":" << Quote(phase) << ",\"index\":" << index << ",\"elapsedUs\":"
            << std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - started).count()
            << ",\"stateResult\":" << int(stateResult) << ",\"state\":" << int(state)
            << ",\"writtenResult\":" << int(writtenResult) << ",\"framesWritten\":" << written
            << ",\"oldResult\":" << int(oldResult) << ",\"oldFrame\":" << oldFrame << ",\"oldTimestamp\":" << oldTime
            << ",\"newResult\":" << int(newResult) << ",\"newFrame\":" << newFrame << ",\"newTimestamp\":" << newTime
            << ",\"userWrittenBytes\":" << __atomic_load_n(&line->written, __ATOMIC_ACQUIRE)
            << ",\"userCallbackBytes\":" << __atomic_load_n(&line->read, __ATOMIC_ACQUIRE)
            << ",\"callbackCalls\":" << __atomic_load_n(&context->calls, __ATOMIC_RELAXED)
            << ",\"callbackRequestedBytes\":" << __atomic_load_n(&context->requested, __ATOMIC_RELAXED)
            << ",\"callbackReturnedBytes\":" << __atomic_load_n(&context->returned, __ATOMIC_RELAXED)
            << ",\"callbackUserBytes\":" << __atomic_load_n(&context->userReturned, __ATOMIC_RELAXED)
            << ",\"callbackSilenceBytes\":" << __atomic_load_n(&context->silenceReturned, __ATOMIC_RELAXED)
            << ",\"paddingRemainingBytes\":" << __atomic_load_n(&context->paddingRemaining, __ATOMIC_RELAXED)
            << ",\"callbackZeroReturns\":" << __atomic_load_n(&context->zeros, __ATOMIC_RELAXED)
            << ",\"platformError\":" << __atomic_load_n(&line->error, __ATOMIC_SEQ_CST)
            << ",\"interrupt\":" << __atomic_load_n(&line->interrupt, __ATOMIC_SEQ_CST) << '}';
        Item(row.str());
    }
    void Open() {
        api.Load();
        context = new Context();
        line = static_cast<AmclLine*>(calloc(1, sizeof(AmclLine)));
        if (!line) throw std::bad_alloc();
        line->capacity = 4096 * 4; line->frameSize = 4; line->isSource = 1;
        line->ring = static_cast<unsigned char*>(malloc(size_t(line->capacity)));
        if (!line->ring) throw std::bad_alloc();
        line->callback = &context->callback;
        __atomic_store_n(&context->callback.owner, line, __ATOMIC_SEQ_CST);
        stage = "configure";
        Result("Create", api.OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_RENDERER));
        io::Require(builder != nullptr, "Create returned null builder");
        Result("SetSamplingRate", api.OH_AudioStreamBuilder_SetSamplingRate(builder, 44100));
        Result("SetChannelCount", api.OH_AudioStreamBuilder_SetChannelCount(builder, 2));
        Result("SetSampleFormat", api.OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE));
        Result("SetEncodingType", api.OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW));
        Result("SetRendererInfo", api.OH_AudioStreamBuilder_SetRendererInfo(builder, AUDIOSTREAM_USAGE_MUSIC));
        Result("SetWriteCallback", api.OH_AudioStreamBuilder_SetRendererWriteDataCallbackAdvanced(builder, TimingData, context));
        Result("SetErrorCallback", api.OH_AudioStreamBuilder_SetRendererErrorCallback(builder, render_error, context));
        Result("SetInterruptCallback", api.OH_AudioStreamBuilder_SetRendererInterruptCallback(builder, render_interrupt, context));
        auto result = api.OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_FAST);
        Result("SetFast", result, false);
        if (result == AUDIOSTREAM_SUCCESS) {
            result = api.OH_AudioStreamBuilder_GenerateRenderer(builder, &line->renderer);
            Result("GenerateFast", result, false);
        }
        if (result != AUDIOSTREAM_SUCCESS && !line->renderer) {
            Result("SetNormal", api.OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_NORMAL));
            Result("GenerateNormal", api.OH_AudioStreamBuilder_GenerateRenderer(builder, &line->renderer));
        } else if (result != AUDIOSTREAM_SUCCESS) throw std::runtime_error("GenerateFast failed with partial renderer");
        io::Require(line->renderer != nullptr, "Generate returned null renderer");
        Result("SetVolume", api.OH_AudioRenderer_SetVolume(line->renderer, 1.0f));
        int32_t rate = 0, channels = 0, callbackFrames = 0;
        OH_AudioStream_SampleFormat format = AUDIOSTREAM_SAMPLE_U8;
        OH_AudioStream_EncodingType encoding = AUDIOSTREAM_ENCODING_TYPE_RAW;
        Result("GetSamplingRate", api.OH_AudioRenderer_GetSamplingRate(line->renderer, &rate));
        Result("GetChannelCount", api.OH_AudioRenderer_GetChannelCount(line->renderer, &channels));
        Result("GetSampleFormat", api.OH_AudioRenderer_GetSampleFormat(line->renderer, &format));
        Result("GetEncodingType", api.OH_AudioRenderer_GetEncodingType(line->renderer, &encoding));
        Result("GetCallbackFrames", api.OH_AudioRenderer_GetFrameSizeInCallback(line->renderer, &callbackFrames));
        Item("{\"rate\":" + std::to_string(rate) + ",\"channels\":" + std::to_string(channels) +
             ",\"format\":" + std::to_string(int(format)) + ",\"callbackFrames\":" + std::to_string(callbackFrames) + '}');
        io::Require(rate == 44100 && channels == 2 && format == AUDIOSTREAM_SAMPLE_S16LE &&
                    encoding == AUDIOSTREAM_ENCODING_TYPE_RAW && callbackFrames > 0, "actual format differs");
        result = api.OH_AudioStreamBuilder_Destroy(builder);
        if (result != AUDIOSTREAM_SUCCESS) {
            context->callback.retainedBuilder = builder;
            builder = nullptr; // 失败对象所有权未知，Cleanup不能再次调用Destroy冒险重复释放。
        }
        Result("DestroyBuilder", result);
        builder = nullptr;
    }
    /** 用户供数协议两段相同；第二段额外静音由callback真实返回并单独计数。 */
    void Window(const char* phase, bool padding) {
        stage = phase;
        std::vector<unsigned char> pcm(11025 * 4);
        for (int frame = 0; frame < 11025; ++frame) {
            // 固定441Hz低幅度方波，整型常量生成；探针只观察时钟，不改变系统音量。
            const int16_t sample = int16_t(frame % 100 < 50 ? 1000 : -1000);
            for (int channel = 0; channel < 2; ++channel) {
                pcm[size_t(frame * 4 + channel * 2)] = static_cast<unsigned char>(sample & 255);
                pcm[size_t(frame * 4 + channel * 2 + 1)] = static_cast<unsigned char>((uint16_t(sample) >> 8) & 255);
            }
        }
        __atomic_store_n(&context->paddingRemaining, padding ? 44100 : 0, __ATOMIC_RELAXED);
        Item("{\"phase\":" + Quote(phase) + ",\"paddingLimitBytes\":" + std::to_string(padding ? 44100 : 0) + '}');
        __atomic_store_n(&line->copyEnabled, 1, __ATOMIC_SEQ_CST);
        Result("Start", api.OH_AudioRenderer_Start(line->renderer));
        const auto end = Clock::now() + std::chrono::seconds(1);
        size_t produced = 0;
        for (int index = 0; index < 20 && Clock::now() < end; ++index) {
            const uint64_t written = __atomic_load_n(&line->written, __ATOMIC_RELAXED);
            const uint64_t read = __atomic_load_n(&line->read, __ATOMIC_ACQUIRE);
            const size_t count = std::min(pcm.size() - produced, size_t(line->capacity) - size_t(written - read));
            const size_t offset = size_t(written % uint64_t(line->capacity));
            const size_t firstBytes = std::min(count, size_t(line->capacity) - offset);
            memcpy(line->ring + offset, pcm.data() + produced, firstBytes);
            if (firstBytes < count) memcpy(line->ring, pcm.data() + produced + firstBytes, count - firstBytes);
            __atomic_store_n(&line->written, written + count, __ATOMIC_RELEASE);
            produced += count;
            Snapshot(phase, index);
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
        Item("{\"phaseProducedBytes\":" + std::to_string(produced) + ",\"expectedBytes\":44100}");
        __atomic_store_n(&line->copyEnabled, 0, __ATOMIC_SEQ_CST);
        Result("Pause", api.OH_AudioRenderer_Pause(line->renderer));
        io::Require(Quiescent(context), "timing callbacks did not quiesce after Pause");
        Snapshot("paused", 0);
    }
    /** 即使探针中途失败也先撤销owner；Release/Destroy失败保留实际仍可能访问的最小存储。 */
    void Cleanup() {
        bool released = true;
        if (line) __atomic_store_n(&line->copyEnabled, 0, __ATOMIC_SEQ_CST);
        if (context) __atomic_store_n(&context->callback.owner, nullptr, __ATOMIC_SEQ_CST);
        if (line && line->renderer) {
            const auto result = api.OH_AudioRenderer_Release(line->renderer);
            Result("Release", result, false); released = result == AUDIOSTREAM_SUCCESS;
        }
        if (builder) {
            const auto result = api.OH_AudioStreamBuilder_Destroy(builder);
            Result("CleanupBuilder", result, false); released = released && result == AUDIOSTREAM_SUCCESS;
        }
        if (context && context->callback.retainedBuilder) released = false;
        if (context && !Quiescent(context)) {
            api.retained = true; Item("{\"retained\":\"active-callback-storage-and-provider\"}"); return;
        }
        if (line) { free(line->ring); free(line); line = nullptr; }
        if (released) { delete context; context = nullptr; }
        else { api.retained = true; Item("{\"retained\":\"detached-context-and-provider\"}"); }
    }
};
} // namespace

std::string RunAudioTimingQualification(int runFd) {
    Probe probe;
    std::string failure;
    try {
        probe.Open();
        probe.Window("before-flush", false);
        probe.stage = "flush";
        probe.Result("Flush", probe.api.OH_AudioRenderer_Flush(probe.line->renderer));
        probe.Snapshot("after-flush-paused", 0);
        // 此处只归零探针自己的供数队列；系统两个时钟及FramesWritten保持实际SDK读回。
        __atomic_store_n(&probe.line->read, UINT64_C(0), __ATOMIC_RELEASE);
        __atomic_store_n(&probe.line->written, UINT64_C(0), __ATOMIC_RELEASE);
        probe.Window("after-flush-with-bounded-silence", true);
    } catch (const std::exception& error) { failure = error.what(); }
    probe.Cleanup();
    const std::string report = "{\"schema\":2,\"status\":" + Quote(failure.empty() ? "OBSERVED" : "FAILED") +
        ",\"pid\":" + std::to_string(getpid()) + ",\"provider\":" + Quote(probe.api.path) +
        ",\"stage\":" + Quote(probe.stage) + ",\"error\":" + Quote(failure) +
        ",\"scope\":\"fixed PCM timestamp observation; not playback PASS\",\"records\":[" + probe.records.str() + "]}";
    io::Fd output(openat(runFd, "audio-timing-report.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
    if (output.get() < 0) io::Error("音频时钟报告已存在或不可创建");
    io::Write(output.get(), report.data(), report.size()); io::Sync(output.get()); io::Sync(runFd);
    return report;
}
} // namespace amcl::jdkqualification
#endif
