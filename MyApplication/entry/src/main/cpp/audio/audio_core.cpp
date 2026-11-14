/**
 * 生产 PCM 队列和控制线程。系统回调完全不接触这里的 registry/Java 锁；控制线程负责
 * 系统操作及连续格式转换。每个流的缓冲、代次和条件变量使 stop/flush/close 可打断 IO。
 */
#include "audio_core.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
namespace amcl::audio {
size_t SampleRing::available() const {
    const auto r = read_.load(std::memory_order_acquire), w = write_.load(std::memory_order_acquire);
    return static_cast<size_t>(w - r);
}
size_t SampleRing::push(const float *source, size_t count) {
    const auto w = write_.load(std::memory_order_relaxed), r = read_.load(std::memory_order_acquire);
    count = std::min(count, data_.size() - static_cast<size_t>(w - r));
    for (size_t i = 0; i < count; ++i)
        data_[(w + i) % data_.size()] = source[i];
    write_.store(w + count, std::memory_order_release);
    return count;
}
size_t SampleRing::pop(float *target, size_t count) {
    const auto r = read_.load(std::memory_order_relaxed), w = write_.load(std::memory_order_acquire);
    count = std::min(count, static_cast<size_t>(w - r));
    for (size_t i = 0; i < count; ++i)
        target[i] = data_[(r + i) % data_.size()];
    read_.store(r + count, std::memory_order_release);
    return count;
}
void SampleRing::discard() { read_.store(write_.load(std::memory_order_acquire), std::memory_order_release); }

bool PresentationTimeline::submit(uint64_t total, uint64_t valid) {
    if (valid > total)
        return false;
    const auto begin = submitted_.load(std::memory_order_relaxed);
    if (valid) {
        const auto w = write_.load(std::memory_order_relaxed), r = read_.load(std::memory_order_acquire);
        if (w - r == spans_.size())
            return false;
        spans_[w % spans_.size()] = {begin, valid};
        write_.store(w + 1, std::memory_order_release);
    }
    submitted_.store(begin + total, std::memory_order_release);
    return true;
}
uint64_t PresentationTimeline::present(uint64_t position) {
    // 路由切换/暂停期间允许时间戳停滞；只使用已发布回调范围，防止异常超前计入未来PCM。
    position_ = std::max(position_, std::min(position, submitted_.load(std::memory_order_acquire)));
    auto r = read_.load(std::memory_order_relaxed);
    const auto w = write_.load(std::memory_order_acquire);
    while (r < w) {
        const auto &span = spans_[r % spans_.size()];
        if (position_ <= span.begin + partial_)
            break;
        const auto reached = std::min(span.frames, position_ - span.begin);
        presented_ += reached - partial_;
        partial_ = reached;
        if (partial_ != span.frames)
            break;
        partial_ = 0;
        read_.store(++r, std::memory_order_release);
    }
    return presented_;
}
void PresentationTimeline::reset() {
    // 调用者已经暂停并等回调退出，所以此处可同时重设生产方和消费方游标。
    read_.store(0, std::memory_order_relaxed);
    write_.store(0, std::memory_order_relaxed);
    submitted_.store(0, std::memory_order_relaxed);
    partial_ = position_ = 0;
}

Converter::Converter(int inRate, int outRate, int inChannels, int outChannels)
    : inRate_(inRate), outRate_(outRate), inChannels_(inChannels), outChannels_(outChannels),
      lowpass_(outRate < inRate) {
    if (lowpass_) {
        const double pi = 3.14159265358979323846, cutoff = 0.45 * double(outRate) / inRate;
        double sum = 0;
        for (int i = 0; i < 31; ++i) {
            const int offset = i - 15;
            const double sinc = offset ? std::sin(2 * pi * cutoff * offset) / (pi * offset) : 2 * cutoff;
            taps_[i] = static_cast<float>(sinc * (0.54 - 0.46 * std::cos(2 * pi * i / 30)));
            sum += taps_[i];
        }
        for (auto &tap : taps_)
            tap = static_cast<float>(tap / sum);
    }
}
void Converter::reset() {
    index_ = next_ = 0;
    have_ = false;
    historyPosition_ = 0;
    for (auto &channel : history_)
        std::fill(std::begin(channel), std::end(channel), 0.0f);
}
void Converter::convert(const float *source, size_t frames, std::vector<float> &out) {
    out.clear();
    for (size_t f = 0; f < frames; ++f) {
        float current[2]{source[f * inChannels_], source[f * inChannels_]};
        if (inChannels_ == 2)
            current[1] = source[f * 2 + 1];
        if (lowpass_) {
            for (int ch = 0; ch < 2; ++ch) {
                history_[ch][historyPosition_] = current[ch];
                float filtered = 0;
                for (size_t tap = 0; tap < 31; ++tap)
                    filtered += taps_[tap] * history_[ch][(historyPosition_ + 31 - tap) % 31];
                current[ch] = filtered;
            }
            historyPosition_ = (historyPosition_ + 1) % 31;
        }
        if (!have_) {
            previous_[0] = current[0];
            previous_[1] = current[1];
            have_ = true;
        }
        const uint64_t boundary = index_ * static_cast<uint64_t>(outRate_);
        while (next_ <= boundary) {
            const uint64_t previousBoundary = index_ ? boundary - static_cast<uint64_t>(outRate_) : 0;
            const float t = index_ ? static_cast<float>(next_ - previousBoundary) / outRate_ : 1.0f;
            const float l = previous_[0] + (current[0] - previous_[0]) * t;
            const float r = previous_[1] + (current[1] - previous_[1]) * t;
            if (outChannels_ == 1)
                out.push_back((l + r) * 0.5f);
            else {
                out.push_back(l);
                out.push_back(r);
            }
            next_ += static_cast<uint64_t>(inRate_);
        }
        previous_[0] = current[0];
        previous_[1] = current[1];
        ++index_;
    }
}
void Converter::finish(std::vector<float> &out) {
    out.clear();
    if (!have_)
        return;
    while (next_ < index_ * static_cast<uint64_t>(outRate_)) {
        if (outChannels_ == 1)
            out.push_back((previous_[0] + previous_[1]) * 0.5f);
        else {
            out.push_back(previous_[0]);
            out.push_back(previous_[1]);
        }
        next_ += static_cast<uint64_t>(inRate_);
    }
}
Stream::Stream(bool c, int r, int ch, int e, int cap, uint64_t s)
    : capture(c), rate(r), channels(ch), encoding(e), frameBytes(ch * (e == AMCL_AUDIO_S16LE ? 2 : 4)),
      capacity(cap), session(s) {}

/** 调用者持stream锁；平台仅发布已呈现的有效帧，补零和未呈现回调均不推进业务位置。 */
static uint64_t played(const Stream &s) {
    const auto transferred = s.platform->transferred.load(std::memory_order_acquire);
    return s.frames + (transferred - s.platformOrigin) * s.rate / s.platform->rate;
}

Runtime::Runtime(PlatformFactory factory) : factory_(std::move(factory)) {
    // 所有成员（尤其quit/session/probe）构造完成后才允许worker观察本对象。
    worker_ = std::thread([this] { loop(); });
}
Runtime::~Runtime() {
    invoke([this] {
        if (session_ && !ended_) {
            failCaptures();
            std::vector<uint64_t> ids;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                for (auto &entry : streams_)
                    ids.push_back(entry.first);
            }
            for (auto id : ids)
                closeOnWorker(id);
        }
        return 0;
    });
    {
        std::lock_guard<std::mutex> lock(mutex_);
        quit_ = true;
    }
    wake_.notify_all();
    worker_.join();
}
int Runtime::invoke(std::function<int()> fn) {
    auto task = std::make_shared<std::packaged_task<int()>>(std::move(fn));
    auto result = task->get_future();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        commands_.emplace_back([task] { (*task)(); });
    }
    wake_.notify_one();
    return result.get();
}
void Runtime::loop() {
    for (;;) {
        std::deque<std::function<void()>> commands;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            wake_.wait_for(lock, std::chrono::milliseconds(2),
                           [this] { return quit_ || !commands_.empty(); });
            if (quit_)
                break;
            commands.swap(commands_);
        }
        for (auto &command : commands)
            command();
        // 平台/分配异常不能杀死worker，让所有阻塞调用永远等不到关闭通知。
        try {
            pump();
        } catch (...) {
            failCaptures();
            std::lock_guard<std::mutex> registry(mutex_);
            for (auto &pair : streams_) {
                auto &s = pair.second;
                std::lock_guard<std::mutex> lock(s->mutex);
                s->failed = true;
                s->running = false;
                ++s->generation;
                s->changed.notify_all();
            }
        }
    }
}
std::shared_ptr<Stream> Runtime::lookup(uint64_t handle) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = streams_.find(handle);
    return it == streams_.end() ? nullptr : it->second;
}
bool Runtime::canRecord() {
    return session_ && !ended_ && foreground_ && permission_ && permission_(permissionContext_) == 1;
}
int Runtime::begin(uint64_t session, AmclAudioRecordPermissionV1 permission, void *context, bool foreground) {
    return invoke([=]() -> int {
        if (!session || session_ || ended_)
            return AMCL_AUDIO_INVALID;
        session_ = session;
        permission_ = permission;
        permissionContext_ = context;
        foreground_ = foreground;
        return 0;
    });
}
int Runtime::foreground(uint64_t session, bool value) {
    return invoke([=]() -> int {
        if (session != session_ || ended_)
            return AMCL_AUDIO_INVALID;
        foreground_ = value;
        if (!value)
            failCaptures();
        return 0;
    });
}
int Runtime::refresh(uint64_t session) {
    return invoke([=]() -> int {
        if (session != session_ || ended_)
            return AMCL_AUDIO_INVALID;
        if (!canRecord())
            failCaptures();
        return 0;
    });
}
int Runtime::end(uint64_t session) {
    return invoke([=]() -> int {
        if (!session || session != session_)
            return AMCL_AUDIO_INVALID;
        if (ended_)
            return 0;
        ended_ = true;
        foreground_ = false;
        failCaptures();
        std::vector<uint64_t> ids;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            for (auto &p : streams_)
                ids.push_back(p.first);
        }
        for (auto id : ids)
            closeOnWorker(id);
        permission_ = nullptr;
        permissionContext_ = nullptr;
        return 0;
    });
}
int Runtime::open(int capture, int rate, int channels, int encoding, int bytes, uint64_t *handle) {
    if (!handle || (capture != 0 && capture != 1) || rate < 8000 || rate > 192000 ||
        (channels != 1 && channels != 2) || (encoding != 1 && encoding != 2))
        return AMCL_AUDIO_INVALID;
    const int frame = channels * (encoding == 1 ? 2 : 4);
    if (bytes < frame || bytes > 8 * 1024 * 1024 || bytes % frame)
        return AMCL_AUDIO_LIMIT;
    return invoke([=]() -> int {
        if (!session_ || ended_)
            return AMCL_AUDIO_UNAVAILABLE;
        if (capture && !canRecord())
            return AMCL_AUDIO_PERMISSION;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (streams_.size() >= 64)
                return AMCL_AUDIO_LIMIT;
        }
        auto s = std::make_shared<Stream>(capture != 0, rate, channels, encoding, bytes, session_);
        std::shared_ptr<PlatformStream> platform = capture ? capture_ : nullptr;
        const bool newPlatform = !platform;
        if (!platform) {
            platform = factory_(capture != 0);
            if (!platform)
                return AMCL_AUDIO_PLATFORM;
        }
        if (platform->rate < 8000 || platform->rate > 192000 ||
            (platform->channels != 1 && platform->channels != 2)) {
            platform->close();
            return AMCL_AUDIO_PLATFORM;
        }
        s->platform = platform;
        try {
            s->converter = std::make_unique<Converter>(
                capture ? platform->rate : rate, capture ? rate : platform->rate,
                capture ? platform->channels : channels, capture ? channels : platform->channels);
            std::lock_guard<std::mutex> lock(mutex_);
            const auto selected = nextHandle_++;
            streams_.emplace(selected, s);
            *handle = selected;
            if (capture)
                capture_ = platform;
        } catch (...) {
            // 系统流已经生成，但Java句柄尚未发布；分配/registry失败也必须完整回滚。
            if (newPlatform)
                platform->close();
            return AMCL_AUDIO_LIMIT;
        }
        return 0;
    });
}
void Runtime::releaseCaptureIfUnused() {
    bool any = false, running = false;
    {
        std::lock_guard<std::mutex> registry(mutex_);
        for (auto &p : streams_) {
            std::lock_guard<std::mutex> lock(p.second->mutex);
            if (p.second->capture && !p.second->failed && !p.second->closed) {
                any = true;
                running |= p.second->running;
            }
        }
    }
    if (!any && capture_) {
        capture_->stop();
        capture_->close();
        capture_.reset();
    } else if (!running && capture_)
        capture_->stop();
}
void Runtime::failCaptures() {
    {
        std::lock_guard<std::mutex> registry(mutex_);
        for (auto &pair : streams_) {
            auto &s = pair.second;
            if (!s->capture)
                continue;
            std::lock_guard<std::mutex> lock(s->mutex);
            s->failed = true;
            s->running = false;
            s->bytes.clear();
            ++s->generation;
            s->changed.notify_all();
        }
    }
    releaseCaptureIfUnused();
}
int Runtime::start(uint64_t handle) {
    return invoke([=]() -> int {
        auto s = lookup(handle);
        if (!s)
            return AMCL_AUDIO_INVALID;
        if (s->capture && !canRecord()) {
            failCaptures();
            return AMCL_AUDIO_PERMISSION;
        }
        if (s->capture)
            permissionChecked_ = std::chrono::steady_clock::now();
        {
            std::lock_guard<std::mutex> lock(s->mutex);
            if (s->failed || s->closed)
                return AMCL_AUDIO_UNAVAILABLE;
            if (s->running)
                return 0;
        }
        if (s->capture) {
            // 共享设备可能已为另一个订阅运行；新start不能拿到其之前排队的录音。
            std::lock_guard<std::mutex> lock(s->mutex);
            s->platformOrigin = s->platform->ring.published();
            s->converter->reset();
        }
        if (!s->platform->start())
            return AMCL_AUDIO_PLATFORM;
        {
            std::lock_guard<std::mutex> lock(s->mutex);
            s->running = true;
            s->dataObserved = false;
            if (!s->capture)
                s->runningPosition = played(*s);
            s->changed.notify_all();
        }
        return 0;
    });
}
int Runtime::stop(uint64_t handle) {
    return invoke([=]() -> int {
        auto s = lookup(handle);
        if (!s)
            return AMCL_AUDIO_INVALID;
        {
            std::lock_guard<std::mutex> lock(s->mutex);
            s->running = false;
            ++s->generation;
            s->changed.notify_all();
        }
        bool other = false;
        if (s->capture) {
            std::lock_guard<std::mutex> registry(mutex_);
            for (auto &p : streams_) {
                std::lock_guard<std::mutex> lock(p.second->mutex);
                if (p.second->capture && p.second->running)
                    other = true;
            }
        }
        return (!s->capture || !other) ? (s->platform->stop() ? 0 : AMCL_AUDIO_PLATFORM) : 0;
    });
}
int Runtime::flush(uint64_t handle) {
    return invoke([=]() -> int {
        auto s = lookup(handle);
        if (!s)
            return AMCL_AUDIO_INVALID;
        bool running;
        {
            std::lock_guard<std::mutex> lock(s->mutex);
            running = s->running;
        }
        // 播放消费者游标只在真实系统停止并等回调退出后才能由控制线程重设。
        if (!s->capture && !s->platform->stop())
            return AMCL_AUDIO_PLATFORM;
        if (!s->capture && !s->platform->flush())
            return AMCL_AUDIO_PLATFORM;
        {
            std::lock_guard<std::mutex> lock(s->mutex);
            s->bytes.clear();
            s->pending.clear();
            s->pendingOffset = 0;
            if (!s->capture) {
                s->platform->ring.discard();
                s->frames = std::min(s->accepted, played(*s));
                s->platformOrigin = s->platform->transferred.load();
                s->accepted = s->frames;
            } else {
                // flush属于本订阅。回调可能已写共享ring而worker尚未分发，必须越过这些
                // 样本；不能discard共享ring，否则会吞掉其他正在录音的订阅所需的数据。
                s->platformOrigin = s->platform->ring.published();
            }
            s->converter->reset();
            s->draining = false;
            ++s->generation;
            s->changed.notify_all();
        }
        if (!s->capture && running && !s->platform->start())
            return AMCL_AUDIO_PLATFORM;
        return 0;
    });
}
int Runtime::closeOnWorker(uint64_t handle) {
    std::shared_ptr<Stream> s;
    {
        std::lock_guard<std::mutex> registry(mutex_);
        auto p = streams_.find(handle);
        if (p == streams_.end())
            return 0;
        s = p->second;
        streams_.erase(p);
    }
    {
        std::lock_guard<std::mutex> lock(s->mutex);
        s->closed = true;
        s->running = false;
        s->bytes.clear();
        ++s->generation;
        s->changed.notify_all();
    }
    if (s->capture) {
        releaseCaptureIfUnused();
        return 0;
    }
    s->platform->stop();
    return s->platform->close() ? 0 : AMCL_AUDIO_PLATFORM;
}
int Runtime::close(uint64_t handle) {
    return invoke([=]() -> int { return closeOnWorker(handle); });
}
int Runtime::read(uint64_t handle, void *target, int count, bool block) {
    auto s = lookup(handle);
    if (!s || !s->capture || !target || count < 0 || count % s->frameBytes)
        return AMCL_AUDIO_INVALID;
    std::unique_lock<std::mutex> lock(s->mutex);
    const auto generation = s->generation;
    int done = 0;
    while (done < count) {
        while (!s->bytes.empty() && done < count) {
            static_cast<uint8_t *>(target)[done++] = s->bytes.front();
            s->bytes.pop_front();
        }
        if (done == count || !block || s->closed || s->failed || s->generation != generation || !s->running)
            break;
        s->changed.wait(lock);
    }
    return done;
}
int Runtime::write(uint64_t handle, const void *source, int count) {
    auto s = lookup(handle);
    if (!s || s->capture || !source || count < 0 || count % s->frameBytes)
        return AMCL_AUDIO_INVALID;
    std::unique_lock<std::mutex> lock(s->mutex);
    const auto generation = s->generation;
    int done = 0;
    while (done < count && !s->closed && !s->failed && s->generation == generation) {
        const auto consumed = std::min(s->accepted, played(*s));
        const auto queued = s->accepted - consumed;
        const auto capacity = static_cast<uint64_t>(s->capacity / s->frameBytes);
        const auto frames = std::min(static_cast<uint64_t>((count - done) / s->frameBytes),
                                     capacity > queued ? capacity - queued : 0);
        const size_t amount = frames * s->frameBytes;
        const auto *data = static_cast<const uint8_t *>(source) + done;
        s->bytes.insert(s->bytes.end(), data, data + amount);
        s->accepted += frames;
        // 新write继续同一转换时间轴；旧的末尾请求不能把后续临时空队列反复当作EOF。
        if (frames)
            s->draining = false;
        done += static_cast<int>(amount);
        wake_.notify_one();
        if (done < count)
            s->changed.wait_for(lock, std::chrono::milliseconds(10));
    }
    return done;
}
int Runtime::requestFinish(uint64_t handle) {
    auto s = lookup(handle);
    if (!s || s->capture)
        return AMCL_AUDIO_INVALID;
    std::lock_guard<std::mutex> lock(s->mutex);
    if (s->closed || s->failed)
        return AMCL_AUDIO_UNAVAILABLE;
    s->draining = true;
    wake_.notify_one();
    return 0;
}
int Runtime::drain(uint64_t handle) {
    auto s = lookup(handle);
    if (!s || s->capture)
        return AMCL_AUDIO_INVALID;
    std::unique_lock<std::mutex> lock(s->mutex);
    s->draining = true;
    wake_.notify_one();
    // stop保留待播数据，因此不能仅因stop的IO取消代次改变就宣告drain完成。
    // flush会同步清accepted队列；close/失败则各有明确终态解除这里的等待。
    while (!s->closed && !s->failed && played(*s) < s->accepted) {
        s->changed.wait_for(lock, std::chrono::milliseconds(10));
    }
    s->draining = false;
    return s->failed ? AMCL_AUDIO_PLATFORM : 0;
}
int Runtime::available(uint64_t handle) {
    auto s = lookup(handle);
    if (!s)
        return AMCL_AUDIO_INVALID;
    std::lock_guard<std::mutex> lock(s->mutex);
    if (s->capture)
        return static_cast<int>(s->bytes.size());
    const auto pending = s->accepted - std::min(s->accepted, played(*s));
    return static_cast<int>(
        std::max<int64_t>(0, s->capacity - static_cast<int64_t>(pending) * s->frameBytes));
}
int Runtime::bufferSize(uint64_t h) {
    auto s = lookup(h);
    return s ? s->capacity : AMCL_AUDIO_INVALID;
}
int Runtime::frameBytes(uint64_t h) {
    auto s = lookup(h);
    return s ? s->frameBytes : AMCL_AUDIO_INVALID;
}
int Runtime::state(uint64_t h) {
    auto s = lookup(h);
    if (!s)
        return 0;
    std::lock_guard<std::mutex> lock(s->mutex);
    return (s->closed ? 0 : AMCL_AUDIO_OPEN) | (s->running ? AMCL_AUDIO_RUNNING : 0) |
           (s->failed ? AMCL_AUDIO_FAILED : 0) |
           ((s->running && !s->failed && s->platform->dataActive.load() &&
             (s->capture ? s->dataObserved : played(*s) > s->runningPosition))
                ? AMCL_AUDIO_ACTIVE
                : 0);
}
int64_t Runtime::frames(uint64_t h) {
    auto s = lookup(h);
    if (!s)
        return 0;
    std::lock_guard<std::mutex> lock(s->mutex);
    return static_cast<int64_t>(s->capture ? s->frames : std::min(s->accepted, played(*s)));
}
/** 编解码只在worker执行，按小端显式组装，避免未对齐指针与NaN污染系统混音。 */
static float decode(const uint8_t *p, int encoding) {
    if (encoding == 1) {
        const auto u = uint16_t(p[0]) | (uint16_t(p[1]) << 8);
        return static_cast<int16_t>(u) / 32768.0f;
    }
    uint32_t u = uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
    float f;
    std::memcpy(&f, &u, 4);
    return std::isfinite(f) ? std::clamp(f, -1.0f, 1.0f) : 0;
}
static void encode(float f, int encoding, std::deque<uint8_t> &out) {
    f = std::isfinite(f) ? std::clamp(f, -1.0f, 1.0f) : 0;
    if (encoding == 1) {
        int32_t v = std::clamp(static_cast<int32_t>(std::lrint(f * 32768.0f)), -32768, 32767);
        out.push_back(static_cast<uint8_t>(v));
        out.push_back(static_cast<uint8_t>(v >> 8));
    } else {
        uint32_t u;
        std::memcpy(&u, &f, 4);
        for (int i = 0; i < 4; ++i)
            out.push_back(static_cast<uint8_t>(u >> (i * 8)));
    }
}
void Runtime::pump() {
    if (!session_ || ended_)
        return;
    if (capture_ && capture_->event.load() != 0)
        failCaptures();
    std::vector<std::shared_ptr<Stream>> copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto &p : streams_)
            copy.push_back(p.second);
    }
    // 跨进程政策可能在本进程没有NAPI事件时改变。借已有worker的tick做有界轮询，
    // 只在真正运行的capture存在时查询，最多每200ms一次；RT回调从不读政策文件。
    bool activeCapture = false;
    for (auto &s : copy) {
        std::lock_guard<std::mutex> lock(s->mutex);
        activeCapture |= s->capture && s->running && !s->failed && !s->closed;
    }
    const auto now = std::chrono::steady_clock::now();
    if (activeCapture && now - permissionChecked_ >= std::chrono::milliseconds(200)) {
        permissionChecked_ = now;
        if (!canRecord())
            failCaptures();
    }
    float captured[8192];
    size_t input = 0;
    uint64_t captureBegin = 0;
    if (capture_) {
        captureBegin = capture_->ring.consumed();
        input = capture_->ring.pop(captured, 8192);
    }
    for (auto &s : copy) {
        std::lock_guard<std::mutex> lock(s->mutex);
        if (s->closed || s->failed)
            continue;
        if (!s->capture)
            s->platform->refreshPresentation();
        if (s->platform->event.load() != 0) {
            s->failed = true;
            s->running = false;
            ++s->generation;
            s->changed.notify_all();
            continue;
        }
        if (!s->running)
            continue;
        if (s->capture) {
            const size_t skip =
                s->platformOrigin > captureBegin
                    ? static_cast<size_t>(std::min<uint64_t>(input, s->platformOrigin - captureBegin))
                    : 0;
            if (input > skip) {
                std::vector<float> converted;
                s->converter->convert(captured + skip, (input - skip) / s->platform->channels, converted);
                s->frames += converted.size() / s->channels;
                s->dataObserved |= !converted.empty();
                for (size_t f = 0; f < converted.size(); f += s->channels) {
                    if (s->bytes.size() + s->frameBytes > static_cast<size_t>(s->capacity))
                        for (int i = 0; i < s->frameBytes; ++i)
                            s->bytes.pop_front();
                    for (int ch = 0; ch < s->channels; ++ch)
                        encode(converted[f + ch], s->encoding, s->bytes);
                }
                s->changed.notify_all();
            }
            continue;
        }
        if (s->pendingOffset >= s->pending.size() && !s->bytes.empty()) {
            const auto frames = std::min<size_t>(512, s->bytes.size() / s->frameBytes);
            std::vector<float> decoded;
            decoded.reserve(frames * s->channels);
            uint8_t sample[4];
            for (size_t i = 0; i < frames * s->channels; ++i) {
                for (int j = 0; j < (s->encoding == 1 ? 2 : 4); ++j) {
                    sample[j] = s->bytes.front();
                    s->bytes.pop_front();
                }
                decoded.push_back(decode(sample, s->encoding));
            }
            s->converter->convert(decoded.data(), frames, s->pending);
            s->pendingOffset = 0;
        }
        if (s->pendingOffset >= s->pending.size() && s->bytes.empty() && s->draining) {
            s->converter->finish(s->pending);
            s->pendingOffset = 0;
        }
        if (s->pendingOffset < s->pending.size())
            s->pendingOffset += s->platform->ring.push(s->pending.data() + s->pendingOffset,
                                                       s->pending.size() - s->pendingOffset);
        // 回调拿走数据仍可能排在系统缓冲中；帧位置只由refreshPresentation实际呈现推进。
        s->changed.notify_all();
    }
}
} // namespace amcl::audio
