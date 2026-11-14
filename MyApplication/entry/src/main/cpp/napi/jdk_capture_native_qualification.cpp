/* 仅TestHooks固定48k原生对照，与JDK/JNI/Java环完全独立。正常HAP里的SDK精确typed
 * callback只统计固定前缀，不调用控制接口、不写文件。原两入口各200ms保持不变；
 * startup入口仅在另行授权后观察单流首1s；channels入口固定stereo后mono各200ms，
 * 仅统计两个通道及同帧算术平均，不生成可播放输出、不授平均后信号保真。生产FAST默认不变。
 * 全组10s；平台API本身若阻塞，由调用方同预算的独占NCP看门狗结束本进程。 */
#include "jdk_capture_native_qualification.h"
#ifdef MC_OHOS_BUILD_TESTS
#include "../platform/jdk_install_io.h"
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiocapturer.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <dlfcn.h>
#include <iomanip>
#include <limits>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <thread>
#include <vector>

namespace amcl::jdkqualification {
namespace {
namespace io = amcl::jdk::io;
using Clock = std::chrono::steady_clock;
constexpr uint64_t PrefixFrames = 9600;
constexpr uint64_t StartupFrames = 48000; // 新入口固定最多1s，不能由Want任意指定。
constexpr uint64_t WindowFrames = 1920; // 40ms窗口；原layout五段，新startup二十五段，均包含首帧。
constexpr unsigned MaxWindows = 25;
static_assert(StartupFrames == MaxWindows * WindowFrames && PrefixFrames == 5 * WindowFrames);
enum class ProbeMode { Latency, Layout, Startup, Channels };
static_assert(sizeof(float) == 4 && std::numeric_limits<float>::is_iec559, "F32 interpretation requires IEEE binary32");

std::string Quote(const std::string &value)
{
    std::string output = "\"";
    for (unsigned char c : value) {
        if (c == '"' || c == '\\') { output += '\\'; output += char(c); }
        else if (c < 32) { char text[7]; snprintf(text, sizeof(text), "\\u%04x", unsigned(c)); output += text; }
        else output += char(c);
    }
    return output + '"';
}

#define AMCL_CAPTURE_APIS(X) \
    X(OH_AudioStreamBuilder_Create) X(OH_AudioStreamBuilder_Destroy) \
    X(OH_AudioStreamBuilder_SetSamplingRate) X(OH_AudioStreamBuilder_SetChannelCount) \
    X(OH_AudioStreamBuilder_SetSampleFormat) X(OH_AudioStreamBuilder_SetEncodingType) X(OH_AudioStreamBuilder_SetChannelLayout) \
    X(OH_AudioStreamBuilder_SetCapturerInfo) X(OH_AudioStreamBuilder_SetLatencyMode) \
    X(OH_AudioStreamBuilder_SetCapturerReadDataCallback) X(OH_AudioStreamBuilder_SetCapturerErrorCallback) \
    X(OH_AudioStreamBuilder_SetCapturerInterruptCallback) X(OH_AudioStreamBuilder_GenerateCapturer) \
    X(OH_AudioCapturer_GetSamplingRate) X(OH_AudioCapturer_GetChannelCount) \
    X(OH_AudioCapturer_GetSampleFormat) X(OH_AudioCapturer_GetEncodingType) X(OH_AudioCapturer_GetCapturerInfo) \
    X(OH_AudioCapturer_GetLatencyMode) X(OH_AudioCapturer_GetFastStatus) X(OH_AudioCapturer_GetFrameSizeInCallback) \
    X(OH_AudioCapturer_GetCurrentState) X(OH_AudioCapturer_GetOverflowCount) X(OH_AudioCapturer_GetFramesRead) X(OH_AudioCapturer_GetStreamId) \
    X(OH_AudioCapturer_Start) X(OH_AudioCapturer_Stop) X(OH_AudioCapturer_Release)

/* 正常NDK命名空间装载；每个原型来自实际SDK，所有函数须属于同一实际provider映像。
 * Release/Destroy异常时持有provider租约，不能为了收据“无泄漏”释放仍可能回调的代码。 */
struct Api {
    void *handle = nullptr;
    bool retained = false;
    std::string owner;
#define AMCL_FIELD(name) decltype(&::name) name = nullptr;
    AMCL_CAPTURE_APIS(AMCL_FIELD)
#undef AMCL_FIELD
    void Load() {
        handle = dlopen("libohaudio.so", RTLD_NOW | RTLD_LOCAL);
        if (!handle) { const char *error = dlerror(); throw std::runtime_error(error ? error : "libohaudio dlopen failed"); }
        void *base = nullptr;
#define AMCL_RESOLVE(name) \
        name = reinterpret_cast<decltype(name)>(dlsym(handle, #name)); \
        if (!name) throw std::runtime_error("missing SDK entry " #name); \
        { Dl_info info{}; \
          if (!dladdr(reinterpret_cast<void *>(name), &info) || !info.dli_fname || !info.dli_fbase) \
              throw std::runtime_error("missing SDK owner " #name); \
          if (!base) { base = info.dli_fbase; owner = info.dli_fname; } \
          else if (base != info.dli_fbase) throw std::runtime_error("mixed SDK provider " #name); }
        AMCL_CAPTURE_APIS(AMCL_RESOLVE)
#undef AMCL_RESOLVE
    }
    ~Api() { if (handle && !retained) dlclose(handle); }
};
#undef AMCL_CAPTURE_APIS

struct Moments {
    uint64_t count = 0;
    double peak = 0, energy = 0;
    void Add(double value) { ++count; peak = std::max(peak, std::abs(value)); energy += value * value; }
    double Rms() const { return count ? std::sqrt(energy / double(count)) : 0; }
};

/* 普通统计只由一个callback写；Finish撤enabled并观察active归零后才读。
 * enabled/active采用seq_cst交接，迟到callback只返回；错误/事件仍用原子独立记录。
 * 不留PCM数组。F32负控最多保留前一S16的两字节以跨callback组成相同前缀的四字节。
 */
struct Context {
    std::atomic<unsigned> active{0};
    std::atomic<bool> enabled{false}, done{false};
    std::atomic_flag busy = ATOMIC_FLAG_INIT;
    std::atomic<unsigned> invalid{0}, interrupts{0};
    std::atomic<int> lastHint{0}, lastForce{0};
    std::atomic<uint64_t> error{0}; // 高32位为seen，低32位保留原始错误（包括意外的0）。
    uint64_t callbacks = 0, offeredFrames = 0, floatTotal = 0;
    int minimumBytes = 0, maximumBytes = 0;
    bool halfFloat = false;
    uint16_t firstHalf = 0;
    Moments little, big, floating;
    // Case构造时选择两个固定上限之一；Start后不改，callback只在范围内累计。
    const uint64_t prefixFrames;
    const bool windowStats;
    const unsigned windowCount;
    Moments windows[MaxWindows];
    // 新通道对照仍按整帧计数；固定最多两个S16通道。double平均保留0.5步长，不先量化成S16。
    const unsigned channels;
    const bool channelContrast;
    uint64_t countedFrames = 0;
    Moments channelMoments[2], channelWindows[2][5], mean, meanWindows[5];
    Context(uint64_t frames, bool windowsEnabled, unsigned channelCount, bool contrast)
        : prefixFrames(frames), windowStats(windowsEnabled),
          windowCount(windowsEnabled ? unsigned(frames / WindowFrames) : 0),
          channels(channelCount), channelContrast(contrast) {}
};

void Data(OH_AudioCapturer *, void *opaque, void *buffer, int32_t byteSize)
{
    auto *context = static_cast<Context *>(opaque);
    context->active.fetch_add(1, std::memory_order_seq_cst);
    if (context->enabled.load(std::memory_order_seq_cst) && !context->done.load(std::memory_order_acquire)) {
        if (context->busy.test_and_set(std::memory_order_acquire)) context->invalid.fetch_or(1U);
        else {
            const unsigned frameBytes = 2 * context->channels;
            if (!buffer || byteSize <= 0 || unsigned(byteSize) % frameBytes) context->invalid.fetch_or(2U);
            else {
                ++context->callbacks; context->offeredFrames += unsigned(byteSize) / frameBytes;
                if (!context->minimumBytes || byteSize < context->minimumBytes) context->minimumBytes = byteSize;
                context->maximumBytes = std::max(context->maximumBytes, byteSize);
                uint64_t count = unsigned(byteSize) / frameBytes;
                count = std::min(count, context->prefixFrames - context->countedFrames);
                const auto *bytes = static_cast<const unsigned char *>(buffer);
                for (uint64_t i = 0; i < count; ++i) {
                    if (context->channelContrast) {
                        const unsigned window = unsigned(context->countedFrames / WindowFrames);
                        double sum = 0;
                        for (unsigned channel = 0; channel < context->channels; ++channel) {
                            const size_t offset = size_t(i) * frameBytes + 2 * channel;
                            const unsigned raw = unsigned(bytes[offset]) | (unsigned(bytes[offset + 1]) << 8);
                            const int value = raw <= 32767 ? int(raw) : int(raw) - 65536;
                            context->channelMoments[channel].Add(value);
                            context->channelWindows[channel][window].Add(value); sum += value;
                        }
                        const double average = sum / context->channels;
                        context->mean.Add(average); context->meanWindows[window].Add(average);
                        ++context->countedFrames;
                        continue;
                    }
                    const uint16_t low = uint16_t(unsigned(bytes[2 * i]) | (unsigned(bytes[2 * i + 1]) << 8));
                    const uint16_t high = uint16_t((unsigned(bytes[2 * i]) << 8) | unsigned(bytes[2 * i + 1]));
                    // 在推进总帧数前定位窗口，首个样本属于window0；最后callback越界部分不统计。
                    if (context->windowStats) context->windows[context->little.count / WindowFrames].Add(int16_t(low));
                    context->little.Add(int16_t(low)); context->big.Add(int16_t(high));
                    if (!context->halfFloat) { context->firstHalf = low; context->halfFloat = true; }
                    else {
                        const uint32_t bits = uint32_t(context->firstHalf) | (uint32_t(low) << 16);
                        float value; std::memcpy(&value, &bits, sizeof(value)); ++context->floatTotal;
                        if (std::isfinite(value)) context->floating.Add(double(value));
                        context->halfFloat = false; context->firstHalf = 0;
                    }
                    ++context->countedFrames;
                }
                if (context->countedFrames == context->prefixFrames) context->done.store(true, std::memory_order_release);
            }
            context->busy.clear(std::memory_order_release);
        }
    }
    context->active.fetch_sub(1, std::memory_order_seq_cst);
}

void Error(OH_AudioCapturer *, void *opaque, OH_AudioStream_Result error)
{
    auto *context = static_cast<Context *>(opaque);
    context->active.fetch_add(1, std::memory_order_seq_cst);
    uint64_t expected = 0;
    context->error.compare_exchange_strong(expected, (UINT64_C(1) << 32) | uint32_t(error));
    context->active.fetch_sub(1, std::memory_order_seq_cst);
}

void Interrupt(OH_AudioCapturer *, void *opaque, OH_AudioInterrupt_ForceType force, OH_AudioInterrupt_Hint hint)
{
    auto *context = static_cast<Context *>(opaque);
    context->active.fetch_add(1, std::memory_order_seq_cst);
    context->interrupts.fetch_add(1); context->lastForce.store(int(force)); context->lastHint.store(int(hint));
    context->active.fetch_sub(1, std::memory_order_seq_cst);
}

struct Case {
    Api &api;
    Clock::time_point deadline;
    OH_AudioStream_LatencyMode requested;
    OH_AudioStreamBuilder *builder = nullptr;
    OH_AudioCapturer *capturer = nullptr;
    std::unique_ptr<Context> context;
    bool startAttempted = false, builderDestroyAttempted = false, retained = false, quiescent = false;
    int startedFastStatus = -1;
    bool explicitMono = false, layoutSetterCalled = false;
    bool hasStreamId = false;
    uint32_t streamId = 0;
    std::string failure;
    std::vector<std::string> calls, snapshots;
    Case(Api &value, Clock::time_point limit, OH_AudioStream_LatencyMode mode, bool mono, bool windows,
         uint64_t frames, unsigned channels, bool channelContrast)
        : api(value), deadline(limit), requested(mode), context(new Context(frames, windows, channels, channelContrast)), explicitMono(mono) {}
    ~Case() {
        /* 极端分配异常若中断记录/清理，也不能析构仍被SDK持有的userdata。 */
        if (context && (capturer || builder || !quiescent)) { api.retained = true; (void)context.release(); }
    }

    void Result(const char *name, OH_AudioStream_Result value, bool required = true) {
        calls.push_back("{\"api\":" + Quote(name) + ",\"result\":" + std::to_string(int(value)) + '}');
        if (value != AUDIOSTREAM_SUCCESS) {
            const std::string error = std::string(name) + " returned " + std::to_string(int(value));
            if (failure.empty()) failure = error;
            if (required) throw std::runtime_error(error);
        }
    }
    void Snapshot(const char *stage) {
        int32_t rate = 0, channels = 0, frames = 0;
        OH_AudioStream_SampleFormat format{}; OH_AudioStream_EncodingType encoding{};
        OH_AudioStream_SourceType source{}; OH_AudioStream_LatencyMode latency{};
        OH_AudioStream_FastStatus fast{}; OH_AudioStream_State state{};
        uint32_t overflow = 0;
        Result("GetSamplingRate", api.OH_AudioCapturer_GetSamplingRate(capturer, &rate));
        Result("GetChannelCount", api.OH_AudioCapturer_GetChannelCount(capturer, &channels));
        Result("GetSampleFormat", api.OH_AudioCapturer_GetSampleFormat(capturer, &format));
        Result("GetEncodingType", api.OH_AudioCapturer_GetEncodingType(capturer, &encoding));
        Result("GetCapturerInfo", api.OH_AudioCapturer_GetCapturerInfo(capturer, &source));
        Result("GetLatencyMode", api.OH_AudioCapturer_GetLatencyMode(capturer, &latency));
        Result("GetFastStatus", api.OH_AudioCapturer_GetFastStatus(capturer, &fast));
        Result("GetFrameSizeInCallback", api.OH_AudioCapturer_GetFrameSizeInCallback(capturer, &frames));
        Result("GetCurrentState", api.OH_AudioCapturer_GetCurrentState(capturer, &state));
        Result("GetOverflowCount", api.OH_AudioCapturer_GetOverflowCount(capturer, &overflow));
        std::string identity;
        bool identityStable = true;
        if (context->channelContrast) {
            uint32_t actualId = 0; Result("GetStreamId", api.OH_AudioCapturer_GetStreamId(capturer, &actualId));
            identity = ",\"streamId\":" + std::to_string(actualId);
            identityStable = !hasStreamId || streamId == actualId;
            if (!hasStreamId) { streamId = actualId; hasStreamId = true; }
        }
        if (std::strcmp(stage, "started") == 0) startedFastStatus = int(fast);
        snapshots.push_back("{\"stage\":" + Quote(stage) + ",\"rate\":" + std::to_string(rate) + ",\"channels\":" + std::to_string(channels) +
            ",\"format\":" + std::to_string(int(format)) + ",\"encoding\":" + std::to_string(int(encoding)) + ",\"source\":" + std::to_string(int(source)) +
            ",\"latencyMode\":" + std::to_string(int(latency)) + ",\"fastStatus\":" + std::to_string(int(fast)) + ",\"state\":" + std::to_string(int(state)) +
            ",\"frameSizeInCallback\":" + std::to_string(frames) + ",\"overflowCount\":" + std::to_string(overflow) + identity + '}');
        io::Require(rate == 48000 && channels == int(context->channels) && format == AUDIOSTREAM_SAMPLE_S16LE &&
                    encoding == AUDIOSTREAM_ENCODING_TYPE_RAW && source == AUDIOSTREAM_SOURCE_TYPE_MIC && frames > 0,
                    "actual capture format/source differs from fixed request");
        if (context->channelContrast) {
            io::Require(identityStable, "stream identity changed within fixed contrast arm");
            const auto expectedState = std::strcmp(stage, "prepared") == 0 ? AUDIOSTREAM_STATE_PREPARED :
                std::strcmp(stage, "started") == 0 ? AUDIOSTREAM_STATE_RUNNING : AUDIOSTREAM_STATE_STOPPED;
            io::Require(latency == AUDIOSTREAM_LATENCY_MODE_FAST && fast == AUDIOSTREAM_FASTSTATUS_FAST,
                        "channel contrast premise not met: actual stream is not FAST");
            io::Require(state == expectedState && overflow == 0, "channel contrast state/overflow mismatch");
        }
    }
    bool Quiet() {
        while (context->active.load(std::memory_order_seq_cst)) {
            if (Clock::now() >= deadline) return false;
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        return true;
    }
    void Run() {
        io::Require(Clock::now() < deadline, "native capture group exceeded 10-second deadline");
        Result("Create", api.OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_CAPTURER));
        io::Require(builder != nullptr, "Create returned null builder");
        Result("SetSamplingRate", api.OH_AudioStreamBuilder_SetSamplingRate(builder, 48000));
        Result("SetChannelCount", api.OH_AudioStreamBuilder_SetChannelCount(builder, int(context->channels)));
        // 新对照首臂显式MONO，次臂不调用Setter；避免把cold→warm的次序效应直接当修复。
        if (explicitMono) {
            layoutSetterCalled = true;
            Result("SetChannelLayout", api.OH_AudioStreamBuilder_SetChannelLayout(builder, CH_LAYOUT_MONO));
        }
        Result("SetSampleFormat", api.OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE));
        Result("SetEncodingType", api.OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW));
        Result("SetCapturerInfo", api.OH_AudioStreamBuilder_SetCapturerInfo(builder, AUDIOSTREAM_SOURCE_TYPE_MIC));
        Result("SetReadDataCallback", api.OH_AudioStreamBuilder_SetCapturerReadDataCallback(builder, Data, context.get()));
        Result("SetErrorCallback", api.OH_AudioStreamBuilder_SetCapturerErrorCallback(builder, Error, context.get()));
        Result("SetInterruptCallback", api.OH_AudioStreamBuilder_SetCapturerInterruptCallback(builder, Interrupt, context.get()));
        Result("SetLatencyMode", api.OH_AudioStreamBuilder_SetLatencyMode(builder, requested));
        Result("GenerateCapturer", api.OH_AudioStreamBuilder_GenerateCapturer(builder, &capturer));
        io::Require(capturer != nullptr, "Generate returned null capturer");
        builderDestroyAttempted = true;
        Result("DestroyBuilder", api.OH_AudioStreamBuilder_Destroy(builder)); builder = nullptr;
        Snapshot("prepared");
        io::Require(Clock::now() < deadline, "native capture group exceeded 10-second deadline");
        context->enabled.store(true, std::memory_order_seq_cst); startAttempted = true;
        Result("Start", api.OH_AudioCapturer_Start(capturer));
        Snapshot("started");
        while (!context->done.load(std::memory_order_acquire)) {
            io::Require(!context->invalid.load() && !context->error.load(), "capture callback failed");
            io::Require(!context->interrupts.load(), "capture interrupted; no matched observation");
            io::Require(Clock::now() < deadline, "native capture group exceeded 10-second deadline");
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }
    void Cleanup() {
        context->enabled.store(false, std::memory_order_seq_cst);
        if (capturer && startAttempted) Result("Stop", api.OH_AudioCapturer_Stop(capturer), false);
        quiescent = Quiet();
        if (capturer && startAttempted && failure.empty()) {
            try {
                Snapshot("stopped"); int64_t frames = 0;
                Result("GetFramesRead", api.OH_AudioCapturer_GetFramesRead(capturer, &frames));
                snapshots.push_back("{\"stage\":\"stopped-frames\",\"framesRead\":" + std::to_string(frames) + '}');
                if (context->channelContrast) io::Require(frames >= int64_t(context->prefixFrames), "platform frame count shorter than fixed prefix");
            } catch (const std::exception &error) { if (failure.empty()) failure = error.what(); }
        }
        if (capturer) {
            const auto value = api.OH_AudioCapturer_Release(capturer); Result("Release", value, false);
            retained = value != AUDIOSTREAM_SUCCESS; capturer = nullptr;
        }
        if (builder) {
            if (!builderDestroyAttempted) {
                const auto value = api.OH_AudioStreamBuilder_Destroy(builder); Result("CleanupBuilder", value, false);
                if (value == AUDIOSTREAM_SUCCESS) builder = nullptr;
            }
            retained = retained || builder != nullptr;
        }
        quiescent = Quiet() && quiescent;
        if (!quiescent) { retained = true; if (failure.empty()) failure = "callback statistics did not quiesce"; }
        if (context->error.load() || context->invalid.load() || context->interrupts.load())
            if (failure.empty()) failure = "callback error, invalid data or interruption observed";
        if (quiescent) {
            bool complete = context->countedFrames == context->prefixFrames;
            if (context->channelContrast) {
                complete = complete && context->mean.count == context->prefixFrames;
                for (unsigned channel = 0; channel < context->channels; ++channel)
                    complete = complete && context->channelMoments[channel].count == context->prefixFrames;
            } else complete = complete && context->little.count == context->prefixFrames && !context->halfFloat &&
                              context->floatTotal == context->prefixFrames / 2;
            if (!complete && failure.empty()) failure = "fixed prefix is incomplete";
        }
        api.retained = api.retained || retained;
    }
    std::string Json() {
        std::ostringstream out; out << std::setprecision(17);
        out << "{\"requestedLatencyMode\":" << int(requested) << ",\"status\":" << Quote(failure.empty() ? "OBSERVED" : "FAILED")
            << ",\"error\":" << Quote(failure) << ",\"quiescent\":" << (quiescent ? "true" : "false")
            << ",\"retainedForSafety\":" << (retained ? "true" : "false") << ",\"callbackErrorSeen\":" << (context->error.load() ? "true" : "false")
            << ",\"callbackErrorCode\":" << int32_t(uint32_t(context->error.load())) << ",\"invalidFlags\":" << context->invalid.load()
            << ",\"interruptEvents\":" << context->interrupts.load() << ",\"lastInterruptHint\":" << context->lastHint.load()
            << ",\"lastInterruptForce\":" << context->lastForce.load();
        if (context->channelContrast) out << ",\"requestedChannelCount\":" << context->channels;
        // SDK没有Capturer GetChannelLayout；只记录请求和真实Setter调用，不能伪造actual值。
        if (context->windowStats)
            out << ",\"layoutSetterCalled\":" << (layoutSetterCalled ? "true" : "false")
                << ",\"requestedChannelLayout\":" << (explicitMono ? std::to_string(uint64_t(CH_LAYOUT_MONO)) : "null");
        out << ",\"calls\":[";
        for (size_t i = 0; i < calls.size(); ++i) { if (i) out << ','; out << calls[i]; }
        out << "],\"snapshots\":[";
        for (size_t i = 0; i < snapshots.size(); ++i) { if (i) out << ','; out << snapshots[i]; }
        out << ']';
        if (quiescent) {
            out << ",\"callbackCount\":" << context->callbacks << ",\"offeredFrames\":" << context->offeredFrames
                << ",\"minimumCallbackBytes\":" << context->minimumBytes << ",\"maximumCallbackBytes\":" << context->maximumBytes;
            if (context->channelContrast) {
                // 只导出每个通道和同帧平均的聚合统计；没有PCM数组，平均不是生产转换输出。
                const auto stats = [&out](const Moments &whole, const Moments *windows) {
                    out << "{\"frames\":" << whole.count << ",\"peak\":" << whole.peak << ",\"rms\":" << whole.Rms()
                        << ",\"windows\":[";
                    for (unsigned index = 0; index < 5; ++index) {
                        if (index) out << ',';
                        out << "{\"index\":" << index << ",\"firstFrame\":" << index * WindowFrames
                            << ",\"frames\":" << windows[index].count << ",\"peak\":" << windows[index].peak
                            << ",\"rms\":" << windows[index].Rms() << '}';
                    }
                    out << "]}";
                };
                out << ",\"countedFrames\":" << context->countedFrames << ",\"channels\":[";
                for (unsigned channel = 0; channel < context->channels; ++channel) {
                    if (channel) out << ',';
                    out << "{\"index\":" << channel << ",\"statistics\":";
                    stats(context->channelMoments[channel], context->channelWindows[channel]); out << '}';
                }
                out << "],\"sameFrameArithmeticMean\":"; stats(context->mean, context->meanWindows);
            } else {
            const Moments *moments[] = {&context->little, &context->big, &context->floating};
            const char *names[] = {"s16le", "s16beInterpretation", "f32leInterpretation"};
            for (unsigned i = 0; i < 3; ++i)
                out << ",\"" << names[i] << "\":{\"" << (i == 2 ? "finiteSamples" : "frames") << "\":" << moments[i]->count
                    << ",\"peak\":" << moments[i]->peak << ",\"rms\":" << moments[i]->Rms() << '}';
            out << ",\"f32TotalSamples\":" << context->floatTotal;
            if (context->windowStats) {
                out << ",\"windows\":[";
                for (unsigned i = 0; i < context->windowCount; ++i) {
                    const auto &window = context->windows[i];
                    if (i) out << ',';
                    out << "{\"index\":" << i << ",\"firstFrame\":" << i * WindowFrames << ",\"frames\":" << window.count
                        << ",\"peak\":" << window.peak << ",\"rms\":" << window.Rms() << '}';
                }
                out << ']';
            }
            }
        }
        out << '}';
        if (retained) (void)context.release(); // 明确失败路径保活，不把未释放的SDK回调参数变成UAF。
        return out.str();
    }
};
} // namespace

/* 四个固定入口共用资源/SDK生命周期；没有任意Want时长参数。
 * 原Latency/Layout各两流×9600帧、Startup单流×48000帧保持。
 * Channels仅stereo-first/mono-second两条FAST，各首9600帧，实际运行须取得新授权。 */
static std::string RunCaptureGroup(int runFd, ProbeMode probe)
{
    const bool layoutContrast = probe == ProbeMode::Layout;
    const bool startup = probe == ProbeMode::Startup;
    const bool channelsContrast = probe == ProbeMode::Channels;
    const uint64_t frameLimit = startup ? StartupFrames : PrefixFrames;
    const unsigned armCount = startup ? 1 : 2;
    const auto began = Clock::now(); const auto deadline = began + std::chrono::seconds(10);
    Api api; std::string failure; std::vector<std::string> cases; std::vector<int> actualModes;
    std::vector<uint32_t> streamIds;
    try {
        api.Load();
        for (unsigned arm = 0; arm < armCount; ++arm) {
            const auto mode = layoutContrast || startup || channelsContrast || arm ? AUDIOSTREAM_LATENCY_MODE_FAST : AUDIOSTREAM_LATENCY_MODE_NORMAL;
            Case test(api, deadline, mode, layoutContrast && arm == 0, layoutContrast || startup || channelsContrast,
                      frameLimit, channelsContrast && arm == 0 ? 2 : 1, channelsContrast);
            try { test.Run(); } catch (const std::exception &error) { if (test.failure.empty()) test.failure = error.what(); }
            test.Cleanup(); cases.push_back(test.Json()); actualModes.push_back(test.startedFastStatus);
            if (channelsContrast && test.hasStreamId) streamIds.push_back(test.streamId);
            if (!test.failure.empty()) { failure = test.failure; break; }
        }
    } catch (const std::exception &error) { failure = error.what(); }
    std::ostringstream out;
    const bool contrast = actualModes.size() == 2 && actualModes[0] == AUDIOSTREAM_FASTSTATUS_NORMAL && actualModes[1] == AUDIOSTREAM_FASTSTATUS_FAST;
    const bool bothFast = actualModes.size() == 2 && actualModes[0] == AUDIOSTREAM_FASTSTATUS_FAST && actualModes[1] == AUDIOSTREAM_FASTSTATUS_FAST;
    const bool oneFast = actualModes.size() == 1 && actualModes[0] == AUDIOSTREAM_FASTSTATUS_FAST;
    if (channelsContrast && failure.empty() && (streamIds.size() != 2 || streamIds[0] == streamIds[1]))
        failure = "channel contrast stream identities missing or repeated";
    out << "{\"protocol\":" << Quote(channelsContrast ? "AMCL_CAPTURE_CHANNELS_V1" : startup ? "AMCL_CAPTURE_STARTUP_V1" :
        layoutContrast ? "AMCL_CAPTURE_LAYOUT_V1" : "AMCL_CAPTURE_NATIVE_V1")
        << ",\"status\":" << Quote(failure.empty() ? "OBSERVED" : "FAILED")
        << ",\"pid\":" << getpid() << ",\"provider\":" << Quote(api.owner) << ",\"error\":" << Quote(failure)
        << ",\"rawPcmSaved\":false,\"signalQualified\":false"
        << (startup ? ",\"actualFastObserved\":" : layoutContrast || channelsContrast ? ",\"bothFastObserved\":" : ",\"modeContrastObserved\":")
        << ((startup ? oneFast : layoutContrast || channelsContrast ? bothFast : contrast) ? "true" : "false")
        << ",\"deadlineMillis\":10000,\"elapsedMillis\":"
        << std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - began).count()
        << ",\"requested\":{\"rate\":48000," << (channelsContrast ? "\"channelCounts\":[2,1]," : "\"channels\":1,")
        << "\"format\":1,\"encoding\":0,\"source\":0,\"prefixFrames\":"
        << frameLimit << "},\"cases\":[";
    for (size_t i = 0; i < cases.size(); ++i) { if (i) out << ','; out << cases[i]; }
    out << "]}\n";
    const auto report = out.str();
    const char *filename = channelsContrast ? "capture-channels-report.json" : startup ? "capture-startup-report.json" :
        layoutContrast ? "capture-layout-report.json" : "capture-native-report.json";
    io::Fd output(openat(runFd, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
    if (output.get() < 0) io::Error("原生录音对照报告已存在或无法独占创建");
    io::Write(output.get(), report.data(), report.size()); io::Sync(output.get()); io::Sync(runFd);
    if (!failure.empty()) throw std::runtime_error("native capture observation failed: " + failure + "; see " + filename);
    return report;
}
std::string RunCaptureNativeQualification(int runFd) { return RunCaptureGroup(runFd, ProbeMode::Latency); }
std::string RunCaptureLayoutQualification(int runFd) { return RunCaptureGroup(runFd, ProbeMode::Layout); }
std::string RunCaptureStartupQualification(int runFd) { return RunCaptureGroup(runFd, ProbeMode::Startup); }
std::string RunCaptureChannelsQualification(int runFd) { return RunCaptureGroup(runFd, ProbeMode::Channels); }
} // namespace amcl::jdkqualification
#endif
