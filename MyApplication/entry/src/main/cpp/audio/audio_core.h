/** 平台无关的生产音频核心；测试仅替换 Platform，队列/重采样/并发逻辑仍使用本实现。 */
#pragma once
#include "audio_runtime.h"
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>
namespace amcl::audio {
/**
 * 系统回调与控制线程之间的定容 SPSC float 队列。每次 push/pop 单一生产/消费方；
 * 回调只原子访问及拷贝，满时丢弃新采集数据或填静音，永不阻塞系统实时线程。
 */
class SampleRing {
    std::vector<float> data_;
    std::atomic<uint64_t> read_{0}, write_{0};

  public:
    /** 在open阶段分配定容存储；此后实时回调不扩容。 */
    explicit SampleRing(size_t size) : data_(size) {}
    /** 原子快照；允许并发生产/消费，不声称获取两端同一时刻的全局锁快照。 */
    size_t available() const;
    /** 仅单生产方调用，返回当前可写样本数。 */
    size_t free() const { return data_.size() - available(); }
    /** 已发布/消费的单调样本序号，供共享采集订阅排除start之前的积压帧。 */
    uint64_t published() const { return write_.load(std::memory_order_acquire); }
    uint64_t consumed() const { return read_.load(std::memory_order_acquire); }
    /** 写入不超过剩余容量的样本，返回实际写入数，满时不等待。 */
    size_t push(const float *data, size_t size);
    /** 读出不超过已发布数量的样本，返回实际读取数，空时不等待。 */
    size_t pop(float *data, size_t size);
    /** 仅消费方可丢弃尚未消费的数据，不能回写生产方游标。 */
    void discard();
};
/**
 * 将系统呈现时间轴映射为有效PCM帧数。write回调交付的缓冲尾部可能补零，因此系统位置
 * 不能直接作为业务位置；每个非空回调只登记有效前缀，静音仅推进系统时间轴。
 * submit为唯一实时生产方，present为唯一worker消费方，定容SPSC元数据不分配/不加锁。
 */
class PresentationTimeline {
    struct Span { uint64_t begin = 0, frames = 0; };
    std::array<Span, 4096> spans_{};
    std::atomic<uint64_t> read_{0}, write_{0}, submitted_{0};
    uint64_t partial_ = 0, position_ = 0, presented_ = 0;

  public:
    /** 回调登记整块及其有效前缀，false表示元数据已满，调用者必须将流置失败。 */
    bool submit(uint64_t totalFrames, uint64_t validFrames);
    /** worker只接受真实系统位置；返回自创建以来已呈现的有效帧累计值，不按墙钟外推。 */
    uint64_t present(uint64_t systemPosition);
    /** worker可跳过纯静音时间戳查询；有效区间未全部呈现时返回true。 */
    bool pending() const { return read_.load(std::memory_order_acquire) != write_.load(std::memory_order_acquire); }
    /** 仅停止回调并清空系统缓冲后调用；系统位置重归零，有效累计值保持单调。 */
    void reset();
};
/** 系统音频固定使用 float 交错帧；rate/channels 必须由创建后真实回读确认。 */
struct PlatformStream {
    int rate = 48000, channels = 2;
    SampleRing ring{131072};
    std::atomic<int> event{0};
    /** 采集为已入ring帧数；播放仅为系统已实际呈现的有效PCM，不能在write回调推进。 */
    std::atomic<uint64_t> transferred{0};
    std::atomic<bool> dataActive{false};
    virtual ~PlatformStream() = default;
    virtual bool start() = 0;
    virtual bool stop() = 0;
    /** worker查询实际呈现进度，不能访问Java锁；采集实现无需更新。 */
    virtual void refreshPresentation() = 0;
    /** worker在stop保证回调静止后清系统缓冲；播放同时重置系统时间轴映射。 */
    virtual bool flush() = 0;
    /** 释放失败时实现必须保全回调数据和代码映像，禁止析构仍会被平台访问的上下文。 */
    virtual bool close() = 0;
};
using PlatformFactory = std::function<std::shared_ptr<PlatformStream>(bool capture)>;
std::shared_ptr<PlatformStream> openOhaudio(bool capture);
/** 连续分块线性重采样，保留相位及最后一帧，不在块边界重新取整。仅控制线程使用。 */
class Converter {
    uint64_t index_ = 0, next_ = 0;
    int inRate_, outRate_, inChannels_, outChannels_;
    float previous_[2]{0, 0};
    bool have_ = false;
    // 降采样先做31阶有界低通，避免把语音Nyquist以上频率直接折叠进识别输入。
    float taps_[31]{}, history_[2][31]{};
    size_t historyPosition_ = 0;
    bool lowpass_ = false;

  public:
    /** 冻结速率/声道；仅降采样构造低通，所有构造工作离开系统回调。 */
    Converter(int inRate, int outRate, int inChannels, int outChannels);
    /** 消费任意连续帧块，target被本次输出替换；输入与输出声道均限1/2。 */
    void convert(const float *source, size_t frames, std::vector<float> &target);
    /** drain时补足末帧时长；不重复推进index，不按每个write块补尾。 */
    void finish(std::vector<float> &target);
    /** flush或新流使用，清相位和滤波历史；普通write块之间绝不调用。 */
    void reset();
};
struct Stream {
    bool capture;
    int rate, channels, encoding, frameBytes, capacity;
    uint64_t session;
    std::mutex mutex;
    std::condition_variable changed;
    std::deque<uint8_t> bytes;
    bool running = false, closed = false, failed = false, draining = false, dataObserved = false;
    uint64_t generation = 0, frames = 0, accepted = 0;
    uint64_t runningPosition = 0;
    std::shared_ptr<PlatformStream> platform;
    std::unique_ptr<Converter> converter;
    std::vector<float> pending;
    size_t pendingOffset = 0;
    uint64_t platformOrigin = 0;
    Stream(bool c, int r, int ch, int e, int capacityBytes, uint64_t s);
};
/**
 * 一个宿主 owner。所有系统创建/启停/释放在 worker 串行执行；Java 阻塞数据调用仅持
 * stream 自身锁，不能与系统 Release 互锁。registry 锁不跨平台调用或条件变量等待。
 */
class Runtime {
    PlatformFactory factory_;
    std::mutex mutex_;
    std::condition_variable wake_;
    std::deque<std::function<void()>> commands_;
    std::unordered_map<uint64_t, std::shared_ptr<Stream>> streams_;
    std::shared_ptr<PlatformStream> capture_;
    std::thread worker_;
    bool quit_ = false;
    uint64_t nextHandle_ = 1, session_ = 0;
    bool foreground_ = false, ended_ = false;
    AmclAudioRecordPermissionV1 permission_ = nullptr;
    void *permissionContext_ = nullptr;
    std::chrono::steady_clock::time_point permissionChecked_{};
    int invoke(std::function<int()> fn);
    void loop();
    void pump();
    bool canRecord();
    std::shared_ptr<Stream> lookup(uint64_t handle);
    void failCaptures();
    int closeOnWorker(uint64_t handle);
    void releaseCaptureIfUnused();

  public:
    /** factory为真实OHAudio适配器；仅测试传显式FakePlatform，不设生产假设备fallback。 */
    explicit Runtime(PlatformFactory factory);
    ~Runtime();
    /** 首次冻结会话/真实权限probe和初始前台；本对象不可切会话复用。 */
    int begin(uint64_t session, AmclAudioRecordPermissionV1 permission, void *context, bool foreground);
    /** 前后台、权限变化、结束均串行到控制线程；返回时对应撤销/关闭已经处理。 */
    int foreground(uint64_t session, bool foreground);
    int refresh(uint64_t session);
    int end(uint64_t session);
    /** 校验格式与容量后真实预留平台资源，成功才公布handle；采集每次核权限。 */
    int open(int capture, int rate, int channels, int encoding, int bytes, uint64_t *handle);
    /** start真实启流；stop保队列并解除既有IO；flush丢队列；drain等实际消费；close幂等。 */
    int start(uint64_t);
    int stop(uint64_t);
    int flush(uint64_t);
    int drain(uint64_t);
    /** 幂等请求补转换尾帧但不等待硬件呈现，供Clip在自己的pump线程安全轮询末尾。 */
    int requestFinish(uint64_t);
    int close(uint64_t);
    /** 字节IO只在完整帧边界推进；读可选非阻塞，stop/flush/close代次变化返回已完成部分。 */
    int read(uint64_t, void *, int, bool block);
    int write(uint64_t, const void *, int);
    /** 可用字节、有效容量、状态、帧大小和实际帧位置；未知handle返回负码或终态零。 */
    int available(uint64_t);
    int bufferSize(uint64_t);
    int state(uint64_t);
    int frameBytes(uint64_t);
    int64_t frames(uint64_t);
};
} // namespace amcl::audio
