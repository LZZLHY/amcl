/**
 * OHAudio API20真实系统适配。所有Builder/Start/Stop/Release由Runtime控制线程调用，
 * 回调仅访问预分配float环和原子计数，不进入Java/ArkTS，不做资源重建。
 */
#include "audio_core.h"
#include <algorithm>
#include <cstring>
#include <dlfcn.h>
#include <mutex>
#include <ohaudio/native_audiocapturer.h>
#include <ohaudio/native_audiorenderer.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <thread>
#include <time.h>
namespace amcl::audio {
namespace {
class Ohaudio final : public PlatformStream, public std::enable_shared_from_this<Ohaudio> {
    bool capture_, running_ = false, closed_ = false, quarantined_ = false;
    OH_AudioStreamBuilder *builder_ = nullptr;
    OH_AudioRenderer *renderer_ = nullptr;
    OH_AudioCapturer *capturer_ = nullptr;
    std::atomic<uint32_t> callbacks_{0};
    PresentationTimeline presentation_;
    bool started_ = false;
    std::chrono::steady_clock::time_point presentationChecked_{};
    void *codeLease_ = nullptr;
    /** 数据和代码共同保全；系统Release失败时宁可保留有限设备上下文，也不制造UAF。 */
    void quarantine() {
        if (quarantined_)
            return;
        quarantined_ = true;
        static auto *retained = new std::vector<std::shared_ptr<Ohaudio>>;
        retained->push_back(shared_from_this());
    }
    struct Scope {
        Ohaudio *self;
        explicit Scope(Ohaudio *s) : self(s) { self->callbacks_.fetch_add(1, std::memory_order_acq_rel); }
        ~Scope() { self->callbacks_.fetch_sub(1, std::memory_order_release); }
    };
    static OH_AudioData_Callback_Result write(OH_AudioRenderer *, void *user, void *buffer, int32_t size) {
        auto *self = static_cast<Ohaudio *>(user);
        Scope active(self);
        if (!buffer || size <= 0)
            return AUDIO_DATA_CALLBACK_RESULT_INVALID;
        std::memset(buffer, 0, static_cast<size_t>(size));
        const auto frameBytes = static_cast<size_t>(self->channels) * sizeof(float);
        if (static_cast<size_t>(size) % frameBytes) {
            self->event.store(1);
            return AUDIO_DATA_CALLBACK_RESULT_VALID;
        }
        const auto read =
            self->ring.pop(static_cast<float *>(buffer), static_cast<size_t>(size) / sizeof(float));
        self->dataActive.store(read != 0, std::memory_order_relaxed);
        // 系统将整个缓冲（含补零尾部）排入播放通路。这里只记录有效PCM所在区间，
        // 不把提交当作呈现；实际进度由worker查询硬件时间戳后发布。
        if (!self->presentation_.submit(static_cast<size_t>(size) / frameBytes,
                                        read / static_cast<size_t>(self->channels)))
            self->event.store(9);
        return AUDIO_DATA_CALLBACK_RESULT_VALID;
    }
    static void read(OH_AudioCapturer *, void *user, void *buffer, int32_t size) {
        auto *self = static_cast<Ohaudio *>(user);
        Scope active(self);
        if (!buffer || size <= 0)
            return;
        const auto frameBytes = static_cast<size_t>(self->channels) * sizeof(float);
        if (static_cast<size_t>(size) % frameBytes) {
            self->event.store(1);
            return;
        }
        const auto pushed =
            self->ring.push(static_cast<const float *>(buffer), static_cast<size_t>(size) / sizeof(float));
        self->dataActive.store(pushed != 0, std::memory_order_relaxed);
        self->transferred.fetch_add(pushed / static_cast<size_t>(self->channels), std::memory_order_relaxed);
    }
    static void captureInterrupt(OH_AudioCapturer *, void *user, OH_AudioInterrupt_ForceType,
                                 OH_AudioInterrupt_Hint hint) {
        auto *self = static_cast<Ohaudio *>(user);
        Scope active(self);
        if (hint == AUDIOSTREAM_INTERRUPT_HINT_STOP || hint == AUDIOSTREAM_INTERRUPT_HINT_PAUSE)
            self->event.store(2);
    }
    static void renderInterrupt(OH_AudioRenderer *, void *user, OH_AudioInterrupt_ForceType,
                                OH_AudioInterrupt_Hint hint) {
        auto *self = static_cast<Ohaudio *>(user);
        Scope active(self);
        if (hint == AUDIOSTREAM_INTERRUPT_HINT_STOP || hint == AUDIOSTREAM_INTERRUPT_HINT_PAUSE)
            self->event.store(2);
    }
    static void captureError(OH_AudioCapturer *, void *user, OH_AudioStream_Result) {
        auto *self = static_cast<Ohaudio *>(user);
        Scope active(self);
        self->event.store(3);
    }
    static void renderError(OH_AudioRenderer *, void *user, OH_AudioStream_Result) {
        auto *self = static_cast<Ohaudio *>(user);
        Scope active(self);
        self->event.store(3);
    }
    static void deviceChange(OH_AudioCapturer *, void *user, OH_AudioDeviceDescriptorArray *) {
        auto *self = static_cast<Ohaudio *>(user);
        Scope active(self);
        self->event.store(4);
    }

  public:
    explicit Ohaudio(bool capture) : capture_(capture) { channels = capture ? 1 : 2; }
    ~Ohaudio() override {
        if (codeLease_)
            dlclose(codeLease_);
    }
    bool open() {
        // 回调映像由真实地址认领；绝不按SONAME另加载一份音频owner。
        Dl_info owner{};
        if (!dladdr(reinterpret_cast<const void *>(&read), &owner) || !owner.dli_fname)
            return false;
        codeLease_ = dlopen(owner.dli_fname, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
        if (!codeLease_)
            return false;
        if (OH_AudioStreamBuilder_Create(&builder_,
                                         capture_ ? AUDIOSTREAM_TYPE_CAPTURER : AUDIOSTREAM_TYPE_RENDERER) !=
            AUDIOSTREAM_SUCCESS)
            return false;
        const auto ok = [this](OH_AudioStream_Result result) {
            if (result != AUDIOSTREAM_SUCCESS)
                event.store(5);
            return result == AUDIOSTREAM_SUCCESS;
        };
        if (!ok(OH_AudioStreamBuilder_SetSamplingRate(builder_, rate)) ||
            !ok(OH_AudioStreamBuilder_SetChannelCount(builder_, channels)) ||
            !ok(OH_AudioStreamBuilder_SetSampleFormat(builder_, AUDIOSTREAM_SAMPLE_F32LE)) ||
            !ok(OH_AudioStreamBuilder_SetEncodingType(builder_, AUDIOSTREAM_ENCODING_TYPE_RAW)) ||
            !ok(OH_AudioStreamBuilder_SetLatencyMode(builder_, AUDIOSTREAM_LATENCY_MODE_NORMAL)))
            return false;
        if (capture_) {
            if (!ok(OH_AudioStreamBuilder_SetCapturerInfo(builder_, AUDIOSTREAM_SOURCE_TYPE_MIC)) ||
                !ok(OH_AudioStreamBuilder_SetCapturerReadDataCallback(builder_, read, this)) ||
                !ok(OH_AudioStreamBuilder_SetCapturerInterruptCallback(builder_, captureInterrupt, this)) ||
                !ok(OH_AudioStreamBuilder_SetCapturerErrorCallback(builder_, captureError, this)) ||
                !ok(OH_AudioStreamBuilder_SetCapturerDeviceChangeCallback(builder_, deviceChange, this)) ||
                !ok(OH_AudioStreamBuilder_GenerateCapturer(builder_, &capturer_)))
                return false;
            OH_AudioStream_SampleFormat format{};
            return ok(OH_AudioCapturer_GetSamplingRate(capturer_, &rate)) &&
                   ok(OH_AudioCapturer_GetChannelCount(capturer_, &channels)) &&
                   ok(OH_AudioCapturer_GetSampleFormat(capturer_, &format)) &&
                   format == AUDIOSTREAM_SAMPLE_F32LE;
        }
        if (!ok(OH_AudioStreamBuilder_SetRendererInfo(builder_, AUDIOSTREAM_USAGE_GAME)) ||
            !ok(OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder_, write, this)) ||
            !ok(OH_AudioStreamBuilder_SetRendererInterruptCallback(builder_, renderInterrupt, this)) ||
            !ok(OH_AudioStreamBuilder_SetRendererErrorCallback(builder_, renderError, this)) ||
            !ok(OH_AudioStreamBuilder_GenerateRenderer(builder_, &renderer_)))
            return false;
        OH_AudioStream_SampleFormat format{};
        return ok(OH_AudioRenderer_GetSamplingRate(renderer_, &rate)) &&
               ok(OH_AudioRenderer_GetChannelCount(renderer_, &channels)) &&
               ok(OH_AudioRenderer_GetSampleFormat(renderer_, &format)) && format == AUDIOSTREAM_SAMPLE_F32LE;
    }
    bool start() override {
        if (closed_ || event.load())
            return false;
        if (running_)
            return true;
        const auto result = capture_ ? OH_AudioCapturer_Start(capturer_) : OH_AudioRenderer_Start(renderer_);
        running_ = result == AUDIOSTREAM_SUCCESS;
        started_ |= running_;
        return running_;
    }
    bool stop() override {
        if (closed_ || !running_)
            return true;
        dataActive = false;
        // Java Sound stop必须保留待播内容，renderer用Pause使平台队列及时间戳连续；
        // 真正丢弃数据只在flush明确执行。采集仍用Stop，因为新start会跳过旧采样。
        const auto result = capture_ ? OH_AudioCapturer_Stop(capturer_) : OH_AudioRenderer_Pause(renderer_);
        if (result != AUDIOSTREAM_SUCCESS) {
            event.store(6);
            return false;
        }
        running_ = false;
        while (callbacks_.load(std::memory_order_acquire))
            std::this_thread::yield();
        presentationChecked_ = {};
        refreshPresentation();
        return true;
    }
    void refreshPresentation() override {
        if (capture_ || closed_ || !started_ || !presentation_.pending())
            return;
        const auto now = std::chrono::steady_clock::now();
        // 有效PCM等待呈现时按20ms更新，避免每个2ms worker tick查询系统服务；
        // 停流时强制取得最后快照。此值只影响观察延迟，绝不按墙钟推算已播帧数。
        if (now - presentationChecked_ < std::chrono::milliseconds(20))
            return;
        presentationChecked_ = now;
        int64_t position = 0, timestamp = 0;
        if (OH_AudioRenderer_GetTimestamp(renderer_, CLOCK_MONOTONIC, &position, &timestamp) !=
                AUDIOSTREAM_SUCCESS ||
            position < 0 || timestamp < 0)
            return; // 首次起播/路由恢复时可暂时无时间戳，保留已证实位置，不能假装已播。
        transferred.store(presentation_.present(static_cast<uint64_t>(position)), std::memory_order_release);
    }
    bool flush() override {
        if (capture_ || closed_)
            return !closed_;
        // Runtime先stop并等回调静止。官方约定Flush清系统队列且GetTimestamp从0计数，
        // 所以映射必须同步重置；累计有效已播量保留，未呈现PCM绝不能算作已经播放。
        if (started_ && OH_AudioRenderer_Flush(renderer_) != AUDIOSTREAM_SUCCESS) {
            event.store(10);
            return false;
        }
        presentation_.reset();
        presentationChecked_ = {};
        return true;
    }
    bool close() override {
        if (closed_)
            return !quarantined_;
        stop();
        const auto result = capturer_   ? OH_AudioCapturer_Release(capturer_)
                            : renderer_ ? OH_AudioRenderer_Release(renderer_)
                                        : AUDIOSTREAM_SUCCESS;
        closed_ = true;
        if (result != AUDIOSTREAM_SUCCESS) {
            event.store(7);
            quarantine();
            return false;
        }
        while (callbacks_.load(std::memory_order_acquire))
            std::this_thread::yield();
        capturer_ = nullptr;
        renderer_ = nullptr;
        if (builder_) {
            const auto destroyed = OH_AudioStreamBuilder_Destroy(builder_);
            builder_ = nullptr;
            if (destroyed != AUDIOSTREAM_SUCCESS) {
                event.store(8);
                return false;
            }
        }
        return true;
    }
};
} // namespace
std::shared_ptr<PlatformStream> openOhaudio(bool capture) {
    auto stream = std::make_shared<Ohaudio>(capture);
    if (!stream->open()) {
        stream->close();
        return nullptr;
    }
    return stream;
}
} // namespace amcl::audio
