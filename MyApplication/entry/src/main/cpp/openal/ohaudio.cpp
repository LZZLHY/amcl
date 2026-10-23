/**
 * OHAudio 播放后端：配置回读、控制线程与回调生命周期分离。
 * OpenAL 的设备状态锁负责串行调用 open/reset/start/stop；系统回调只记录事件。
 * 工作线程用 try_lock 获取同一设备锁，关闭时不会等待一个持锁调用者而形成死锁。
 * 当前最低 API20；播放、录音和 Java Sound 是不同能力，本后端只声明 Playback。
 */
#include "config.h"
#include "ohaudio.h"
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <vector>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <dlfcn.h>
#include <unistd.h>
#endif
#include "alc/device.h"
#include "core/device.h"
#include "core/logging.h"
#include "alsem.h"
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiorenderer.h>

namespace {
using namespace std::string_view_literals;
constexpr auto DeviceName = "OHAudio Default"sv;
struct OHAudioPlayback;

/**
 * 每个已发布回调的代码映像引用，与数据上下文同归属。仅持有包含本回调的OpenAL
 * 映像，不按固定SONAME另选provider、不永久pin无关库。创建调用方仍须持有其ABI
 * 句柄跨本次调用；正常Release确认且active归零后释放额外引用，原调用栈返回后
 * LWJGL的nDestroy才可卸载。Release失败则本引用随detached上下文保留到进程结束。
 */
struct CallbackCodeLease {
    CallbackCodeLease() = default;
    CallbackCodeLease(const CallbackCodeLease&) = delete;
    auto operator=(const CallbackCodeLease&) -> CallbackCodeLease& = delete;
#ifdef _WIN32
    HMODULE image{nullptr};
    ~CallbackCodeLease() { if(image) FreeLibrary(image); }
    bool acquire(const void* callback) noexcept {
        HMODULE selected{nullptr};
        if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
            reinterpret_cast<LPCWSTR>(callback), &selected)) return false;
        // FROM_ADDRESS真实增加引用；只核出口的借用句柄不能再FreeLibrary一次。
        const auto exported = GetProcAddress(selected, "alcOpenDevice");
        HMODULE exportedOwner{nullptr};
        if(!exported || !GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
            GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCWSTR>(exported), &exportedOwner) || exportedOwner != selected) {
            FreeLibrary(selected);
            return false;
        }
        image = selected;
        return true;
    }
#else
    void* image{nullptr};
    ~CallbackCodeLease() { if(image) dlclose(image); }
    bool acquire(const void* callback) noexcept {
        Dl_info owner{};
        if(!dladdr(callback, &owner) || !owner.dli_fname || !owner.dli_fbase) return false;
        // NOLOAD限定当前已装载映像；非空句柄不足以证明归属，出口地址须与回调同base。
        void* selected = dlopen(owner.dli_fname, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
        if(!selected) return false;
        const auto exported = dlsym(selected, "alcOpenDevice");
        Dl_info exportedOwner{};
        if(!exported || !dladdr(exported, &exportedOwner) || exportedOwner.dli_fbase != owner.dli_fbase) {
            dlclose(selected);
            return false;
        }
        image = selected;
        return true;
    }
#endif
};


#ifdef AMCL_OHAUDIO_CONTROL_MAPS
#if AMCL_OHAUDIO_CONTROL_MAPS
/** 仅default TestHooks且本renderer显式开启音频诊断时取证：hex块保留maps原字节，抵抗逐行stdout/hilog传输截断。
 * 完整性只消费本局owned原始流，不能借hilog转述或标记单行自证。字节/次数有硬上限，
 * dladdr与stdio仍可能阻塞；下面的预算仅能在调用前后观测，不是实时墙钟保证。 */
void controlMapsSnapshot(const char* stage, unsigned long long pid, unsigned long long tid,
    unsigned long long bindingEpoch, unsigned long long generation, bool generationBound,
    const void* owner, const void* device, const void* builder, const void* renderer,
    const void* callback) noexcept {
    const int savedErrno = errno;
    constexpr std::size_t maxBytes = 1024u * 1024u;
    constexpr std::size_t chunkBytes = 1024u;
    constexpr auto readBudget = std::chrono::milliseconds{250};
    const auto started = std::chrono::steady_clock::now();
    const auto snapshotEpoch = static_cast<unsigned long long>(std::chrono::duration_cast<
        std::chrono::nanoseconds>(started.time_since_epoch()).count());
    char generationText[32]{};
    if(generationBound) std::snprintf(generationText, sizeof(generationText), "%llu", generation);
    else std::strcpy(generationText, "UNBOUND");
    const void* callbackBase = nullptr;
    const void* generateBase = nullptr;
#ifndef _WIN32
    Dl_info callbackImage{}, generateImage{};
    if(dladdr(callback, &callbackImage)) callbackBase = callbackImage.dli_fbase;
    if(dladdr(reinterpret_cast<const void*>(&OH_AudioStreamBuilder_GenerateRenderer), &generateImage))
        generateBase = generateImage.dli_fbase;
#endif
    FILE* const sink = gLogFile ? gLogFile : stderr;
    const bool priorSinkError = std::ferror(sink) != 0;
    bool writeError = priorSinkError;
    int openError = 0, readError = 0, closeError = 0;
    bool eof = false, truncated = false, budgetStopped = false;
    std::size_t bytes = 0, chunks = 0;
    const int begin = std::fprintf(sink,
        "AMCL_OHAUDIO_MAPS_BEGIN pid=%llu tid=%llu snapshot_epoch_ns=%llu binding_epoch_ns=%llu generation=%s stage=%s owner=%p device=%p builder=%p renderer=%p callback_addr=%p callback_base=%p generate_addr=%p generate_base=%p byte_limit=%zu chunk_bytes=%zu data_record_limit=%zu read_loop_budget_ms=250 encoding=hex path=proc-self-maps\n",
        pid, tid, snapshotEpoch, bindingEpoch, generationText, stage, owner, device, builder,
        renderer, callback, callbackBase,
        reinterpret_cast<const void*>(&OH_AudioStreamBuilder_GenerateRenderer), generateBase,
        maxBytes, chunkBytes, maxBytes / chunkBytes);
    writeError = writeError || begin < 0 || std::ferror(sink) != 0;
    FILE* maps = nullptr;
    if(!writeError) {
        errno = 0;
        maps = std::fopen("/proc/self/maps", "r");
        if(!maps) openError = errno ? errno : EIO;
    }
    unsigned char buffer[chunkBytes]{};
    char encoded[chunkBytes * 2u + 1u]{};
    constexpr char hex[] = "0123456789abcdef";
    while(maps && !writeError && bytes < maxBytes) {
        if(std::chrono::steady_clock::now() - started >= readBudget) { budgetStopped = true; break; }
        errno = 0;
        const auto count = std::fread(buffer, 1, chunkBytes, maps);
        const int readErrno = errno;
        if(std::ferror(maps)) readError = readErrno ? readErrno : EIO;
        if(std::feof(maps)) eof = true;
        if(count) {
            for(std::size_t i = 0; i < count; ++i) {
                encoded[i * 2u] = hex[buffer[i] >> 4u];
                encoded[i * 2u + 1u] = hex[buffer[i] & 15u];
            }
            encoded[count * 2u] = '\0';
            const int written = std::fprintf(sink,
                "AMCL_OHAUDIO_MAPS_DATA pid=%llu tid=%llu snapshot_epoch_ns=%llu offset=%zu bytes=%zu hex=%s\n",
                pid, tid, snapshotEpoch, bytes, count, encoded);
            writeError = written < 0 || std::ferror(sink) != 0;
            if(!writeError) { bytes += count; ++chunks; }
        }
        if(readError || eof || !count) break;
    }
    // 最多额外读1字节，区分恰到上限的完整EOF与仅取得前缀；不会把额外字节写入正文。
    if(maps && bytes == maxBytes && !readError && !writeError && !eof) {
        errno = 0;
        const int extra = std::fgetc(maps);
        if(extra == EOF) {
            if(std::ferror(maps)) readError = errno ? errno : EIO;
            else eof = true;
        } else truncated = true;
    }
    if(maps && std::fclose(maps) != 0) closeError = errno ? errno : EIO;
    const auto elapsed = std::chrono::steady_clock::now() - started;
    const auto elapsedNs = static_cast<unsigned long long>(std::chrono::duration_cast<
        std::chrono::nanoseconds>(elapsed).count());
    const bool elapsedOverBudget = elapsed >= readBudget;
    const bool complete = eof && !truncated && !budgetStopped && !elapsedOverBudget &&
        !openError && !readError && !closeError && !writeError;
    const int end = std::fprintf(sink,
        "AMCL_OHAUDIO_MAPS_END pid=%llu tid=%llu snapshot_epoch_ns=%llu binding_epoch_ns=%llu generation=%s stage=%s bytes=%zu chunks=%zu eof=%d truncated=%d budget_stopped=%d elapsed_ns=%llu elapsed_over_budget=%d open_errno=%d read_errno=%d close_errno=%d write_error=%d prior_sink_error=%d status=%s\n",
        pid, tid, snapshotEpoch, bindingEpoch, generationText, stage, bytes, chunks, eof ? 1 : 0,
        truncated ? 1 : 0, budgetStopped ? 1 : 0, elapsedNs, elapsedOverBudget ? 1 : 0,
        openError, readError, closeError, writeError ? 1 : 0,
        priorSinkError ? 1 : 0, complete ? "READ_COMPLETE" : "INCOMPLETE");
    // END不能自证自己的最终fflush成功，elapsed也尚未覆盖这个footer/flush。宿主须在本局
    // owned原件找到全部DATA并核IO健康；任何缺块、超预算或截断都不能给完整maps资格。
    (void)end;
    (void)std::fflush(sink);
    errno = savedErrno;
}
#endif
#endif

/** 独立于后端对象的回调门。Release失败时数据及代码引用一起保留，避免迟到回调UAF。 */
struct CallbackContext {
    CallbackCodeLease code;
    std::atomic<OHAudioPlayback*> owner{nullptr};
    std::atomic<unsigned> active{0};
};

/** 回调先登记再读 owner；关闭先清 owner 再等 active 归零，覆盖交错进入的回调。 */
struct CallbackGuard {
    CallbackContext* context;
    OHAudioPlayback* owner;
    explicit CallbackGuard(void* opaque) : context{static_cast<CallbackContext*>(opaque)}, owner{nullptr} {
        if(context) { context->active.fetch_add(1); owner = context->owner.load(); }
    }
    ~CallbackGuard() { if(context) context->active.fetch_sub(1); }
};

/** 必需操作不能仅输出日志后继续；交给 OpenAL 正常设备异常路径处理。 */
void requireOk(OH_AudioStream_Result result, const char* operation) {
    if(result != AUDIOSTREAM_SUCCESS)
        throw al::backend_exception{al::backend_error::DeviceError,
            "OHAudio {} failed ({})", operation, static_cast<int>(result)};
}

/** 所请求格式先归一化到 OpenAL 与 OHAudio 都支持的明确表示。 */
auto sampleFormat(DevFmtType type) -> OH_AudioStream_SampleFormat {
    if(type == DevFmtFloat) return AUDIOSTREAM_SAMPLE_F32LE;
    if(type == DevFmtInt) return AUDIOSTREAM_SAMPLE_S32LE;
    return AUDIOSTREAM_SAMPLE_S16LE;
}

/** relaxed 最大值统计仅供诊断，不参与音频数据同步或生命周期决策。 */
void updateMaximum(std::atomic<std::uint64_t>& value, std::uint64_t sample) {
    auto old = value.load(std::memory_order_relaxed);
    while(old < sample && !value.compare_exchange_weak(old, sample, std::memory_order_relaxed)) { }
}

struct OHAudioPlayback final : BackendBase {
    // 计数信号量创建失败允许沿后端构造异常返回，不能以noexcept把资源不足变成进程终止。
    explicit OHAudioPlayback(DeviceBase* device) : BackendBase{device} { }
    ~OHAudioPlayback() override;
    void open(std::string_view name) override;
    bool reset() override;
    void start() override;
    void stop() override;
    bool defaultOutputLimiter() const noexcept override { return true; }

    // 原生句柄只由 OpenAL 控制入口或持设备状态锁的工作线程访问。
    OH_AudioStreamBuilder* mBuilder{nullptr};
    OH_AudioRenderer* mRenderer{nullptr};
    std::unique_ptr<CallbackContext> mContext;
    unsigned mFrameSize{0};
    bool mUserRunning{false};
    bool mDisconnected{false};
    bool mReleaseFailed{false}; // 未确认释放的实例不得在同一后端继续创建新流。
    float mAppliedVolume{1.0f};
    std::thread mWorker;
    // 计数信号量保留先通知后等待的事件；系统回调不获取OpenAL设备锁或wake互斥量。
    al::semaphore mWake;
    std::atomic<bool> mExit{false};
    std::atomic<bool> mDirty{false};
    std::atomic<bool> mPaused{false};
    std::atomic<bool> mStopRequested{false};
    std::atomic<bool> mDuck{false};
    std::atomic<int> mError{0};
    std::atomic<std::uint64_t> mCallbacks{0}, mFrames{0}, mInvalidBuffers{0};
    std::atomic<std::uint64_t> mMaxCallbackNs{0}, mDeadlineOverruns{0}, mNonFinite{0};
    std::uint32_t mLastUnderflows{0};
    bool mDiagnostics{false}; // reset在发布回调前冻结，整个renderer寿命只读。

    void stopWorker();
    void wakeControl();
    void releaseRenderer() noexcept;
    void controlLoop();
    void applyControl();
    void reportCounters(bool final);
    bool pauseOrStop(bool pause);
    void disconnect(int result);
    static OH_AudioData_Callback_Result write(OH_AudioRenderer*, void*, void*, int32_t);
    static void interrupt(OH_AudioRenderer*, void*, OH_AudioInterrupt_ForceType, OH_AudioInterrupt_Hint);
    static void error(OH_AudioRenderer*, void*, OH_AudioStream_Result);
};

/** 析构先停止控制任务，再撤销回调所有权，最后释放平台资源。 */
OHAudioPlayback::~OHAudioPlayback() {
    stopWorker();
    releaseRenderer();
}

/** 只唤醒/等待自有控制线程，不持 wake 锁跨 join；线程不会阻塞获取设备锁。 */
void OHAudioPlayback::stopWorker() {
    mExit.store(true);
    if(mWorker.joinable()) mWake.post();
    if(mWorker.joinable()) mWorker.join();
}

/** 多个系统事件合并到同一原子意图；最多一个待处理dirty令牌，加上单个退出令牌。
 * 信号量不会随回调数累积；即使事件先于wait，控制线程仍能消费，不依赖100ms兜底。 */
void OHAudioPlayback::wakeControl() {
    if(!mDirty.exchange(true)) mWake.post();
}

/**
 * Release 成功后平台不应继续回调；失败时保留 detached context 到进程结束。
 * 上下文不再引用Backend/Device；其真实代码lease防止L2逻辑destroy卸载尚被平台借用
 * 的OpenAL回调。正常成功不保留映像，失败不把数据尚存误写成代码也必然存活。
 */
void OHAudioPlayback::releaseRenderer() noexcept {
    if(mContext) mContext->owner.store(nullptr);
    OH_AudioStream_Result released = AUDIOSTREAM_SUCCESS;
    if(mRenderer) {
        const auto stopped = OH_AudioRenderer_Stop(mRenderer);
        if(stopped != AUDIOSTREAM_SUCCESS && stopped != AUDIOSTREAM_ERROR_ILLEGAL_STATE)
            WARN("OHAudio stop during release failed ({})", static_cast<int>(stopped));
        // 只记录这个真实Release控制调用；旧renderer必须在mRenderer清空前保存，日志不解引用。
        // generation/reset_epoch属于reset局部事务，此处明确UNBOUND；由旧reset的同owner/handle绑定。
        OH_AudioRenderer* const phaseReleasedRenderer = mRenderer;
        // 诊断许可沿旧renderer冻结到Release结束；关闭时不计时、不取线程身份、不转储maps。
        const auto phaseReleaseEpochNs = mDiagnostics ? static_cast<unsigned long long>(std::chrono::duration_cast<
            std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count()) : 0;
#ifdef _WIN32
        const auto phaseReleasePid = mDiagnostics ? static_cast<unsigned long long>(GetCurrentProcessId()) : 0;
        const auto phaseReleaseTid = mDiagnostics ? static_cast<unsigned long long>(GetCurrentThreadId()) : 0;
#else
        const auto phaseReleasePid = mDiagnostics ? static_cast<unsigned long long>(getpid()) : 0;
        const auto phaseReleaseTid = mDiagnostics ? static_cast<unsigned long long>(gettid()) : 0;
#endif
        // 仅显式诊断才在控制侧输出一对fprintf/flush，沿gLogFile保存/恢复errno。
        // stop_result来自已发生的原Stop；Release SUCCESS只证该CAPI返回，不宣称active/lease/Builder收尾完成。
        const auto phaseReleaseMarker = [&](const char* phase, bool returned = false, int result = 0) noexcept {
            if(!mDiagnostics) return; // 真实Release及失败处置不依赖纯诊断formatter。
            const int savedErrno = errno;
            char resultText[32]{};
            if(returned) std::snprintf(resultText, sizeof(resultText), "%d", result);
            else std::strcpy(resultText, "NOT_RETURNED");
            FILE* const sink = gLogFile ? gLogFile : stderr;
            std::fprintf(sink, "AMCL_OHAUDIO_RELEASE_PHASE pid=%llu tid=%llu release_epoch_ns=%llu generation=UNBOUND reset_epoch_ns=UNBOUND owner=%p device=%p builder=%p renderer=%p operation=ReleaseRenderer phase=%s stop_result=%d result=%s\n",
                phaseReleasePid, phaseReleaseTid, phaseReleaseEpochNs, static_cast<void*>(this),
                static_cast<void*>(mDevice), static_cast<void*>(mBuilder), static_cast<void*>(phaseReleasedRenderer),
                phase, static_cast<int>(stopped), resultText);
            std::fflush(sink);
            errno = savedErrno;
        };
#ifdef AMCL_OHAUDIO_CONTROL_MAPS
#if AMCL_OHAUDIO_CONTROL_MAPS
        if(mDiagnostics) controlMapsSnapshot("before_release_capi", phaseReleasePid, phaseReleaseTid, phaseReleaseEpochNs,
            0, false, this, mDevice, mBuilder, phaseReleasedRenderer, reinterpret_cast<const void*>(&OHAudioPlayback::write));
#endif
#endif
        phaseReleaseMarker("enter");
        released = OH_AudioRenderer_Release(mRenderer);
        phaseReleaseMarker("return", true, static_cast<int>(released));
#ifdef AMCL_OHAUDIO_CONTROL_MAPS
#if AMCL_OHAUDIO_CONTROL_MAPS
        if(mDiagnostics) controlMapsSnapshot("after_release_capi", phaseReleasePid, phaseReleaseTid, phaseReleaseEpochNs,
            0, false, this, mDevice, mBuilder, phaseReleasedRenderer, reinterpret_cast<const void*>(&OHAudioPlayback::write));
#endif
#endif
        if(released != AUDIOSTREAM_SUCCESS) {
            mReleaseFailed = true;
            ERR("OHAudio release failed ({}); detached callback context retained", static_cast<int>(released));
        }
        mRenderer = nullptr;
    }
    if(mContext) {
        while(mContext->active.load() != 0) std::this_thread::yield();
        if(released == AUDIOSTREAM_SUCCESS) mContext.reset();
        else static_cast<void>(mContext.release());
    }
    if(mBuilder) {
        const auto result = OH_AudioStreamBuilder_Destroy(mBuilder);
        if(result != AUDIOSTREAM_SUCCESS) WARN("OHAudio builder destroy failed ({})", static_cast<int>(result));
        mBuilder = nullptr;
    }
    mUserRunning = false;
    mFrameSize = 0;
}

/** 验证回调参数后按实际协商帧大小混音；余字节归零，非有限浮点样本不进入系统。 */
OH_AudioData_Callback_Result OHAudioPlayback::write(OH_AudioRenderer*, void* opaque,
    void* data, int32_t bytes) {
    CallbackGuard guard{opaque};
    auto* self = guard.owner;
    if(!data || bytes <= 0) {
        if(self) self->mInvalidBuffers.fetch_add(1, std::memory_order_relaxed);
        return AUDIO_DATA_CALLBACK_RESULT_INVALID;
    }
    if(!self || self->mFrameSize == 0) {
        std::memset(data, 0, static_cast<std::size_t>(bytes));
        return AUDIO_DATA_CALLBACK_RESULT_VALID;
    }
    const auto start = self->mDiagnostics ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{};
    const auto count = static_cast<unsigned>(bytes) / self->mFrameSize;
    const auto used = count * self->mFrameSize;
    if(used != static_cast<unsigned>(bytes)) {
        std::memset(static_cast<unsigned char*>(data) + used, 0, static_cast<unsigned>(bytes) - used);
        self->mInvalidBuffers.fetch_add(1, std::memory_order_relaxed);
    }
    if(count) self->mDevice->renderSamples(data, count, self->mDevice->channelsFromFmt());
    if(self->mDevice->FmtType == DevFmtFloat) {
        auto* samples = static_cast<float*>(data);
        for(unsigned i = 0; i < used / sizeof(float); ++i) {
            if(!std::isfinite(samples[i])) { samples[i] = 0; self->mNonFinite.fetch_add(1, std::memory_order_relaxed); }
        }
    }
    // 默认回调只混音并处理无效样本；耗时、帧数及overrun统计须本局显式开启。
    if(self->mDiagnostics) {
        self->mCallbacks.fetch_add(1, std::memory_order_relaxed);
        self->mFrames.fetch_add(count, std::memory_order_relaxed);
        const auto elapsed = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now() - start).count());
        updateMaximum(self->mMaxCallbackNs, elapsed);
        if(count && elapsed > static_cast<std::uint64_t>(count) * 1000000000ULL / self->mDevice->mSampleRate)
            self->mDeadlineOverruns.fetch_add(1, std::memory_order_relaxed);
    }
    return AUDIO_DATA_CALLBACK_RESULT_VALID;
}

/** 系统线程只写原子意图。STOP 单独锁存，不能被随后的 RESUME 合并掉。 */
void OHAudioPlayback::interrupt(OH_AudioRenderer*, void* opaque,
    OH_AudioInterrupt_ForceType type, OH_AudioInterrupt_Hint hint) {
    CallbackGuard guard{opaque};
    if(!guard.owner) return;
    auto* self = guard.owner;
    switch(hint) {
    case AUDIOSTREAM_INTERRUPT_HINT_PAUSE: self->mPaused.store(true); break;
    case AUDIOSTREAM_INTERRUPT_HINT_RESUME: self->mPaused.store(false); break;
    case AUDIOSTREAM_INTERRUPT_HINT_STOP: self->mStopRequested.store(true); break;
    case AUDIOSTREAM_INTERRUPT_HINT_DUCK:
        if(type == AUDIOSTREAM_INTERRUPT_SHARE) self->mDuck.store(true);
        break;
    case AUDIOSTREAM_INTERRUPT_HINT_UNDUCK: self->mDuck.store(false); break;
    default: break;
    }
    self->wakeControl();
}

/** 错误只保留首个非成功码；实际停止/断连由控制线程处理。 */
void OHAudioPlayback::error(OH_AudioRenderer*, void* opaque, OH_AudioStream_Result result) {
    CallbackGuard guard{opaque};
    if(!guard.owner || result == AUDIOSTREAM_SUCCESS) return;
    int none = 0;
    guard.owner->mError.compare_exchange_strong(none, static_cast<int>(result));
    guard.owner->wakeControl();
}

/** 只接受当前真实后端枚举出的设备名。 */
void OHAudioPlayback::open(std::string_view name) {
    if(name.empty()) name = DeviceName;
    if(name != DeviceName) throw al::backend_exception{al::backend_error::NoDevice, "Unknown OHAudio device {}", name};
    mDeviceName = name;
}

/** 创建、配置和回读构成一个事务；任意失败均关闭本次对象，不留下半可用 renderer。 */
bool OHAudioPlayback::reset() {
    stopWorker();
    releaseRenderer();
    if(mReleaseFailed)
        throw al::backend_exception{al::backend_error::DeviceError, "Previous OHAudio renderer release was not acknowledged"};
    // 旧renderer已按自己的诊断许可完成释放，才冻结新renderer许可；默认和显式0均无采样/转储。
    const char* diagnostics = std::getenv("AMCL_AUDIO_DIAGNOSTICS");
    mDiagnostics = diagnostics && std::strcmp(diagnostics, "1") == 0;
    // 只标识本映像内的reset诊断事务；序号和单调起点不参与对象/回调寿命。
    // reset_epoch_ns是事务起点，不是每点采样时间；映像重载结合PID/TID/owner识别。
    static std::atomic<unsigned long long> phaseSequence{0};
    const auto phaseGeneration = mDiagnostics ? phaseSequence.fetch_add(1, std::memory_order_relaxed) + 1 : 0;
    const auto phaseResetEpochNs = mDiagnostics ? static_cast<unsigned long long>(std::chrono::duration_cast<
        std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count()) : 0;
#ifdef _WIN32
    const auto phasePid = mDiagnostics ? static_cast<unsigned long long>(GetCurrentProcessId()) : 0;
    const auto phaseTid = mDiagnostics ? static_cast<unsigned long long>(GetCurrentThreadId()) : 0;
#else
    const auto phasePid = mDiagnostics ? static_cast<unsigned long long>(getpid()) : 0;
    const auto phaseTid = mDiagnostics ? static_cast<unsigned long long>(gettid()) : 0;
#endif
    // 非_DEBUG默认Error，WARN/TRACE不可靠。显式诊断许可后的formatter直接写既有gLogFile
    // （默认stderr，仍遵守ALSOFT_LOGFILE），不改级别，不把正常阶段伪装成ERR。
    // 仅控制调用侧输出/flush且保errno；实时回调内没有新增I/O。
    const auto phaseMarker = [&](const char* operation, const char* phase, unsigned attempt,
        OH_AudioStream_LatencyMode request, bool returned = false, int result = 0,
        const char* valueName = "none", int value = 0) noexcept {
        if(!mDiagnostics) return; // 仅省去formatter和stdio；真实创建、回退、回读及错误门继续执行。
        const int savedErrno = errno;
        char resultText[32]{};
        if(returned) std::snprintf(resultText, sizeof(resultText), "%d", result);
        else std::strcpy(resultText, "NOT_RETURNED");
        FILE* const sink = gLogFile ? gLogFile : stderr;
        // requested_latency是实际Generate调用请求（第二次为NORMAL）；回读字段独立，
        // actual_latency只在GetLatencyMode返回SUCCESS时value_valid=1，不推断为请求值。
        const bool valueValid = returned && result == AUDIOSTREAM_SUCCESS && std::strcmp(valueName, "none") != 0;
        std::fprintf(sink, "AMCL_OHAUDIO_PHASE pid=%llu tid=%llu generation=%llu reset_epoch_ns=%llu owner=%p device=%p builder=%p renderer=%p operation=%s phase=%s attempt=%u requested_latency=%d result=%s value_name=%s value_valid=%d value=%d\n",
            phasePid, phaseTid, phaseGeneration, phaseResetEpochNs, static_cast<void*>(this),
            static_cast<void*>(mDevice), static_cast<void*>(mBuilder), static_cast<void*>(mRenderer),
            operation, phase, attempt, static_cast<int>(request), resultText, valueName, valueValid ? 1 : 0, value);
        std::fflush(sink);
        errno = savedErrno;
    };
    mDisconnected = false;
    mPaused.store(false); mStopRequested.store(false); mDuck.store(false); mError.store(0);
    // 上一renderer已停止、回调已撤销；在这个静止边界清掉退出令牌。
    while(mWake.try_wait()) { }
    // 新renderer的采样从零开始；关闭诊断不能把上一renderer的样本当成本轮统计。
    mCallbacks.store(0); mFrames.store(0); mMaxCallbackNs.store(0); mDeadlineOverruns.store(0);
    mDirty.store(false); mExit.store(false); mAppliedVolume = 1.0f; mLastUnderflows = 0;
    if(mDevice->FmtType != DevFmtFloat && mDevice->FmtType != DevFmtInt) mDevice->FmtType = DevFmtShort;
    if(mDevice->FmtChans != DevFmtMono) mDevice->FmtChans = DevFmtStereo;
    try {
        requireOk(OH_AudioStreamBuilder_Create(&mBuilder, AUDIOSTREAM_TYPE_RENDERER), "create builder");
        if(!mBuilder) throw al::backend_exception{al::backend_error::DeviceError, "OHAudio returned null builder"};
        requireOk(OH_AudioStreamBuilder_SetSamplingRate(mBuilder, static_cast<int32_t>(mDevice->mSampleRate)), "sample rate");
        requireOk(OH_AudioStreamBuilder_SetChannelCount(mBuilder, static_cast<int32_t>(mDevice->channelsFromFmt())), "channels");
        requireOk(OH_AudioStreamBuilder_SetSampleFormat(mBuilder, sampleFormat(mDevice->FmtType)), "sample format");
        requireOk(OH_AudioStreamBuilder_SetEncodingType(mBuilder, AUDIOSTREAM_ENCODING_TYPE_RAW), "encoding");
        requireOk(OH_AudioStreamBuilder_SetRendererInfo(mBuilder, AUDIOSTREAM_USAGE_GAME), "usage");
        auto requestedLatency = mDevice->mSampleRate == 48000 ? AUDIOSTREAM_LATENCY_MODE_FAST : AUDIOSTREAM_LATENCY_MODE_NORMAL;
        auto latencyResult = OH_AudioStreamBuilder_SetLatencyMode(mBuilder, requestedLatency);
        if(latencyResult != AUDIOSTREAM_SUCCESS && requestedLatency == AUDIOSTREAM_LATENCY_MODE_FAST) {
            requestedLatency = AUDIOSTREAM_LATENCY_MODE_NORMAL;
            latencyResult = OH_AudioStreamBuilder_SetLatencyMode(mBuilder, requestedLatency);
            TRACE("OHAudio low-latency request unavailable; using normal mode");
        }
        requireOk(latencyResult, "latency mode");
        mContext = std::make_unique<CallbackContext>();
        // 先取得真实同映像引用再暴露任何回调；获取或owner核验失败走既有配置异常清理。
        if(!mContext->code.acquire(reinterpret_cast<const void*>(&OHAudioPlayback::write)))
            throw al::backend_exception{al::backend_error::DeviceError,
                "OHAudio callback code image lease unavailable"};
        mContext->owner.store(this);
        requireOk(OH_AudioStreamBuilder_SetRendererWriteDataCallback(mBuilder, write, mContext.get()), "write callback");
        requireOk(OH_AudioStreamBuilder_SetRendererInterruptCallback(mBuilder, interrupt, mContext.get()), "interrupt callback");
        requireOk(OH_AudioStreamBuilder_SetRendererErrorCallback(mBuilder, error, mContext.get()), "error callback");
        // 纯诊断镜像，FAST回退后更新为本次实际请求；不改生产requestedLatency。
        auto phaseEffectiveRequest = requestedLatency;
#ifdef AMCL_OHAUDIO_CONTROL_MAPS
#if AMCL_OHAUDIO_CONTROL_MAPS
        if(mDiagnostics) controlMapsSnapshot("before_generate_attempt1", phasePid, phaseTid, phaseResetEpochNs,
            phaseGeneration, true, this, mDevice, mBuilder, mRenderer, reinterpret_cast<const void*>(&OHAudioPlayback::write));
#endif
#endif
        phaseMarker("GenerateRenderer", "enter", 1, phaseEffectiveRequest);
        auto generated = OH_AudioStreamBuilder_GenerateRenderer(mBuilder, &mRenderer);
        phaseMarker("GenerateRenderer", "return", 1, phaseEffectiveRequest, true, static_cast<int>(generated));
        // FAST 是优化而不是必需能力；仅在没有返回句柄时允许一次 NORMAL 创建回退。
        if(generated != AUDIOSTREAM_SUCCESS && !mRenderer && requestedLatency == AUDIOSTREAM_LATENCY_MODE_FAST) {
            requireOk(OH_AudioStreamBuilder_SetLatencyMode(mBuilder, AUDIOSTREAM_LATENCY_MODE_NORMAL), "normal latency fallback");
            phaseEffectiveRequest = AUDIOSTREAM_LATENCY_MODE_NORMAL;
            phaseMarker("GenerateRenderer", "enter", 2, phaseEffectiveRequest);
            generated = OH_AudioStreamBuilder_GenerateRenderer(mBuilder, &mRenderer);
            phaseMarker("GenerateRenderer", "return", 2, phaseEffectiveRequest, true, static_cast<int>(generated));
        }
        requireOk(generated, "generate renderer");
        if(!mRenderer) throw al::backend_exception{al::backend_error::DeviceError, "OHAudio returned null renderer"};
        int32_t rate = 0, channels = 0;
        OH_AudioStream_SampleFormat format{};
        OH_AudioStream_LatencyMode latency{};
        phaseMarker("GetSamplingRate", "enter", 0, phaseEffectiveRequest);
        const auto phaseRateResult = OH_AudioRenderer_GetSamplingRate(mRenderer, &rate);
        phaseMarker("GetSamplingRate", "return", 0, phaseEffectiveRequest, true,
            static_cast<int>(phaseRateResult), "sample_rate", static_cast<int>(rate));
        requireOk(phaseRateResult, "read sample rate");
        phaseMarker("GetChannelCount", "enter", 0, phaseEffectiveRequest);
        const auto phaseChannelsResult = OH_AudioRenderer_GetChannelCount(mRenderer, &channels);
        phaseMarker("GetChannelCount", "return", 0, phaseEffectiveRequest, true,
            static_cast<int>(phaseChannelsResult), "channels", static_cast<int>(channels));
        requireOk(phaseChannelsResult, "read channels");
        phaseMarker("GetSampleFormat", "enter", 0, phaseEffectiveRequest);
        const auto phaseFormatResult = OH_AudioRenderer_GetSampleFormat(mRenderer, &format);
        phaseMarker("GetSampleFormat", "return", 0, phaseEffectiveRequest, true,
            static_cast<int>(phaseFormatResult), "sample_format", static_cast<int>(format));
        requireOk(phaseFormatResult, "read format");
        phaseMarker("GetLatencyMode", "enter", 0, phaseEffectiveRequest);
        const auto phaseLatencyResult = OH_AudioRenderer_GetLatencyMode(mRenderer, &latency);
        phaseMarker("GetLatencyMode", "return", 0, phaseEffectiveRequest, true,
            static_cast<int>(phaseLatencyResult), "actual_latency", static_cast<int>(latency));
        requireOk(phaseLatencyResult, "read latency mode");
        if(rate <= 0 || (channels != 1 && channels != 2))
            throw al::backend_exception{al::backend_error::DeviceError, "Unsupported actual OHAudio stream {}Hz/{}ch", rate, channels};
        switch(format) {
        case AUDIOSTREAM_SAMPLE_U8: mDevice->FmtType = DevFmtUByte; break;
        case AUDIOSTREAM_SAMPLE_S16LE: mDevice->FmtType = DevFmtShort; break;
        case AUDIOSTREAM_SAMPLE_S32LE: mDevice->FmtType = DevFmtInt; break;
        case AUDIOSTREAM_SAMPLE_F32LE: mDevice->FmtType = DevFmtFloat; break;
        default: throw al::backend_exception{al::backend_error::DeviceError, "Unsupported actual OHAudio format {}", static_cast<int>(format)};
        }
        mDevice->mSampleRate = static_cast<unsigned>(rate);
        mDevice->FmtChans = channels == 1 ? DevFmtMono : DevFmtStereo;
        mFrameSize = mDevice->frameSizeFromFmt();
        setDefaultChannelOrder();
        TRACE("OHAudio actual: {}Hz {}ch format={} frameBytes={} latency={}", rate, channels,
            static_cast<int>(format), mFrameSize, static_cast<int>(latency));
        mWorker = std::thread{&OHAudioPlayback::controlLoop, this};
        return true;
    } catch(...) {
        stopWorker();
        releaseRenderer();
        throw;
    }
}

/** 用户启动意图与系统暂停独立；处于暂停时保留意图，由后续 RESUME 恢复。 */
void OHAudioPlayback::start() {
    if(!mRenderer || mDisconnected) throw al::backend_exception{al::backend_error::DeviceError, "No usable OHAudio renderer"};
    mStopRequested.store(false); // 显式新启动可以覆盖此前已收到的 STOP 意图。
    if(!mPaused.load()) requireOk(OH_AudioRenderer_Start(mRenderer), "start");
    mUserRunning = true;
    wakeControl();
}

/** 对系统已经暂停/停止的竞态读取状态；仅确认不再 RUNNING 才接受非法状态返回。 */
bool OHAudioPlayback::pauseOrStop(bool pause) {
    const auto result = pause ? OH_AudioRenderer_Pause(mRenderer) : OH_AudioRenderer_Stop(mRenderer);
    if(result == AUDIOSTREAM_SUCCESS) return true;
    OH_AudioStream_State state{};
    if(result == AUDIOSTREAM_ERROR_ILLEGAL_STATE &&
        OH_AudioRenderer_GetCurrentState(mRenderer, &state) == AUDIOSTREAM_SUCCESS && state != AUDIOSTREAM_STATE_RUNNING)
        return true;
    ERR("OHAudio {} failed ({})", pause ? "pause" : "stop", static_cast<int>(result));
    mError.store(static_cast<int>(result));
    return false;
}

/** 显式停止撤销用户意图，后续系统 RESUME 不得自行重启声音。 */
void OHAudioPlayback::stop() {
    mUserRunning = false;
    if(mRenderer) pauseOrStop(false);
    reportCounters(true);
    wakeControl();
}

/** 持有 OpenAL 设备状态锁且先撤销混音所有权，才调用其断连实现。 */
void OHAudioPlayback::disconnect(int result) {
    if(mDisconnected) return;
    mDisconnected = true;
    mUserRunning = false;
    if(mContext) mContext->owner.store(nullptr);
    if(mRenderer) static_cast<void>(OH_AudioRenderer_Stop(mRenderer));
    if(mContext) while(mContext->active.load() != 0) std::this_thread::yield();
    ERR("OHAudio runtime failure ({})", result);
    mDevice->handleDisconnect("OHAudio runtime failure ({})", result);
}

/** 仅控制线程调用；设备状态锁已经获得，系统强制暂停与应用请求在此收敛。 */
void OHAudioPlayback::applyControl() {
    if(!mRenderer || mDisconnected) return;
    if(mStopRequested.exchange(false)) mUserRunning = false;
    if(const int result = mError.load()) { disconnect(result); return; }
    OH_AudioStream_State state{};
    const auto result = OH_AudioRenderer_GetCurrentState(mRenderer, &state);
    if(result != AUDIOSTREAM_SUCCESS) { disconnect(static_cast<int>(result)); return; }
    const bool wanted = mUserRunning && !mPaused.load();
    if(wanted && state != AUDIOSTREAM_STATE_RUNNING) {
        const auto started = OH_AudioRenderer_Start(mRenderer);
        if(started != AUDIOSTREAM_SUCCESS) { disconnect(static_cast<int>(started)); return; }
    } else if(!wanted && state == AUDIOSTREAM_STATE_RUNNING) {
        if(!pauseOrStop(mUserRunning)) { disconnect(mError.load()); return; }
    }
    const float volume = mDuck.load() ? 0.2f : 1.0f;
    if(volume != mAppliedVolume) {
        const auto changed = OH_AudioRenderer_SetVolume(mRenderer, volume);
        if(changed != AUDIOSTREAM_SUCCESS) { disconnect(static_cast<int>(changed)); return; }
        mAppliedVolume = volume;
    }
}

/** 控制事件及停止时读平台累计欠载；不为观察单独唤醒线程。异常保留WARN，采样统计用TRACE。 */
void OHAudioPlayback::reportCounters(bool final) {
    std::uint32_t underflows = mLastUnderflows;
    if(mRenderer && OH_AudioRenderer_GetUnderflowCount(mRenderer, &underflows) == AUDIOSTREAM_SUCCESS) {
        if(underflows != mLastUnderflows) WARN("OHAudio underflows={} sampledCallbacks={} sampledFrames={} maxCallbackNs={} overruns={}",
            underflows, mCallbacks.load(), mFrames.load(), mMaxCallbackNs.load(), mDeadlineOverruns.load());
        mLastUnderflows = underflows;
    }
    if(mDiagnostics && (final || mInvalidBuffers.load() || mNonFinite.load()))
        TRACE("OHAudio counters: sampledCallbacks={} sampledFrames={} invalidBuffers={} nonFinite={} maxCallbackNs={} overruns={} underflows={}",
            mCallbacks.load(), mFrames.load(), mInvalidBuffers.load(), mNonFinite.load(), mMaxCallbackNs.load(),
            mDeadlineOverruns.load(), underflows);
}

/** 无控制待办就事件等待；只有已收到事件且设备锁忙时才短暂重试。
 * 不阻塞获取设备锁，确保持锁的reset/析构可唤醒并join；平台操作不在系统回调内。 */
void OHAudioPlayback::controlLoop() {
    while(!mExit.load()) {
        mWake.wait();
        if(mExit.load()) break;
        auto* device = static_cast<al::Device*>(mDevice);
        while(!mExit.load()) {
            std::unique_lock<std::mutex> state{device->StateLock, std::try_to_lock};
            if(!state.owns_lock()) { std::this_thread::sleep_for(std::chrono::milliseconds{1}); continue; }
            if(mDirty.exchange(false)) applyControl();
            reportCounters(false);
            break;
        }
    }
}
} // namespace

/** 工厂仅声明已实现的系统播放后端，录音保持明确的不可用能力。 */
auto OHAudioBackendFactory::init() -> bool { return true; }
auto OHAudioBackendFactory::querySupport(BackendType type) -> bool { return type == BackendType::Playback; }
auto OHAudioBackendFactory::enumerate(BackendType type) -> std::vector<std::string> {
    return type == BackendType::Playback ? std::vector{std::string{DeviceName}} : std::vector<std::string>{};
}
auto OHAudioBackendFactory::createBackend(DeviceBase* device, BackendType type) -> BackendPtr {
    if(type == BackendType::Playback) return BackendPtr{new OHAudioPlayback{device}};
    return nullptr;
}
auto OHAudioBackendFactory::getFactory() -> BackendFactory& {
    static OHAudioBackendFactory factory;
    return factory;
}
