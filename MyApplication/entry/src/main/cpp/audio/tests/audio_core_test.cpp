/**
 * 生产音频核心的宿主回归。显式FakePlatform仅替换操作系统设备；测试断言真正Runtime的
 * 共享采集、权限、转换、阻塞/取消、队列与结束行为，不把宿主样本写成真机验证。
 */
#include "../audio_core.h"
#include "../../tests/host/test_check.h"
#include <chrono>
#include <cmath>
#include <cstdio>
#include <future>
#include <thread>
using namespace amcl::audio;
using namespace std::chrono_literals;
struct FakePlatform final : PlatformStream {
    std::atomic<bool> running{false};
    std::atomic<int> closes{0};
    PresentationTimeline presentation;
    std::atomic<uint64_t> hardwarePosition{0};
    uint64_t submitted = 0;
    std::atomic<bool> holdRefresh{false}, refreshEntered{false};
    bool start() override {
        running = true;
        return !event.load();
    }
    bool stop() override {
        running = false;
        return true;
    }
    bool close() override {
        running = false;
        ++closes;
        return true;
    }
    /** 显式模拟硬件呈现，与回调取走量分开；测试可冻结位置复现一缓冲提前完成。 */
    void refreshPresentation() override {
        if (holdRefresh.load()) {
            refreshEntered = true;
            while (holdRefresh.load())
                std::this_thread::yield();
        }
        transferred = presentation.present(hardwarePosition.load());
    }
    bool flush() override {
        refreshPresentation();
        presentation.reset();
        hardwarePosition = 0;
        submitted = 0;
        return true;
    }
    void feed(size_t frames, float value) {
        std::vector<float> data(frames * channels, value);
        ring.push(data.data(), data.size());
    }
    size_t consume(size_t totalFrames = 4096, bool present = true) {
        float data[8192];
        auto n = ring.pop(data, std::min<size_t>(8192, totalFrames * channels));
        AMCL_TEST_CHECK(presentation.submit(totalFrames, n / channels));
        submitted += totalFrames;
        if (present)
            hardwarePosition = submitted;
        return n;
    }
};
/** 有界等待只作为测试超时；生产读写不通过短超时伪造设备数据。 */
template <class F> void eventually(F predicate) {
    for (int i = 0; i < 1000; ++i) {
        if (predicate())
            return;
        std::this_thread::sleep_for(2ms);
    }
    AMCL_TEST_CHECK(false);
}
int main() {
    // 系统位置包含补零和有效PCM；呈现到有效前缀中途时只能计该前缀已到达的部分。
    {
        PresentationTimeline timeline;
        AMCL_TEST_CHECK(timeline.submit(480, 0));
        AMCL_TEST_CHECK(timeline.submit(480, 120));
        AMCL_TEST_CHECK(timeline.present(479) == 0);
        AMCL_TEST_CHECK(timeline.present(500) == 20);
        AMCL_TEST_CHECK(timeline.present(960) == 120);
        AMCL_TEST_CHECK(timeline.submit(480, 240));
        AMCL_TEST_CHECK(timeline.present(1000) == 160);
        AMCL_TEST_CHECK(timeline.present(990) == 160); // 路由恢复不能令业务位置倒退。
        timeline.reset(); // 未呈现部分丢弃，累计已播帧保留，新的系统时间轴从0开始。
        AMCL_TEST_CHECK(timeline.submit(200, 100));
        AMCL_TEST_CHECK(timeline.present(50) == 210);
        AMCL_TEST_CHECK(timeline.present(200) == 260);
    }
    // 同一输入全块与任意分块必须逐样本一致，覆盖非整数采样率和完整尾帧。
    for (auto rate : {8000, 16000, 22050, 24000, 32000, 44100, 48000}) {
        std::vector<float> source(4801);
        for (size_t i = 0; i < source.size(); ++i)
            source[i] = std::sin(float(i) * 0.01f);
        Converter whole(48000, rate, 1, 2), chunks(48000, rate, 1, 2);
        std::vector<float> a, b, tail, part;
        whole.convert(source.data(), source.size(), a);
        whole.finish(tail);
        a.insert(a.end(), tail.begin(), tail.end());
        for (size_t offset = 0; offset < source.size();) {
            size_t n = std::min<size_t>(137, source.size() - offset);
            chunks.convert(source.data() + offset, n, part);
            b.insert(b.end(), part.begin(), part.end());
            offset += n;
        }
        chunks.finish(tail);
        b.insert(b.end(), tail.begin(), tail.end());
        AMCL_TEST_CHECK(a == b);
        AMCL_TEST_CHECK(a.size() / 2 == (source.size() * rate + 47999) / 48000);
    }
    {
        Converter filtered(48000, 16000, 1, 1);
        std::vector<float> high(4800), out;
        for (size_t i = 0; i < high.size(); ++i)
            high[i] = std::sin(float(i) * 3.14159265358979323846f * 0.5f);
        filtered.convert(high.data(), high.size(), out);
        double energy = 0;
        for (size_t i = 20; i < out.size(); ++i)
            energy += out[i] * out[i];
        AMCL_TEST_CHECK(std::sqrt(energy / (out.size() - 20)) < 0.05);
    }
    {
        // worker正在另一个播放平台的poll中时，模拟系统采集回调把旧样本留在共享ring。
        // flush命令排队后才解除poll，使flush必定先于下次capture分发，而不是靠概率抢时序。
        std::shared_ptr<FakePlatform> shared, blocker;
        Runtime regression([&](bool input) {
            auto p = std::make_shared<FakePlatform>();
            p->channels = 1;
            if (input)
                shared = p;
            else {
                p->holdRefresh = true;
                blocker = p;
            }
            return p;
        });
        AMCL_TEST_CHECK(regression.begin(7, [](void *) { return 1; }, nullptr, true) == 0);
        uint64_t flushed = 0, untouched = 0, gate = 0;
        AMCL_TEST_CHECK(regression.open(1, 48000, 1, 2, 4096, &flushed) == 0);
        AMCL_TEST_CHECK(regression.open(1, 48000, 1, 2, 4096, &untouched) == 0);
        AMCL_TEST_CHECK(regression.start(flushed) == 0 && regression.start(untouched) == 0);
        AMCL_TEST_CHECK(regression.open(0, 48000, 1, 2, 4096, &gate) == 0);
        eventually([&] { return blocker->refreshEntered.load(); });
        shared->feed(48, 0.25f);
        auto flushing = std::async(std::launch::async, [&] { return regression.flush(flushed); });
        AMCL_TEST_CHECK(flushing.wait_for(20ms) == std::future_status::timeout);
        blocker->holdRefresh = false;
        AMCL_TEST_CHECK(flushing.get() == 0);
        eventually([&] { return regression.available(untouched) == 48 * 4; });
        AMCL_TEST_CHECK(regression.available(flushed) == 0);
        shared->feed(24, 0.75f);
        eventually([&] { return regression.available(flushed) == 24 * 4; });
        eventually([&] { return regression.available(untouched) == 72 * 4; });
        float after[24]{}, all[72]{};
        AMCL_TEST_CHECK(regression.read(flushed, after, sizeof(after), false) == sizeof(after));
        AMCL_TEST_CHECK(regression.read(untouched, all, sizeof(all), false) == sizeof(all));
        for (auto sample : after)
            AMCL_TEST_CHECK(sample == 0.75f);
        for (size_t i = 0; i < 72; ++i)
            AMCL_TEST_CHECK(all[i] == (i < 48 ? 0.25f : 0.75f));
        AMCL_TEST_CHECK(regression.end(7) == 0);
        std::puts("PASS capture flush: one subscription skips unpublished-to-worker PCM; peer preserves all PCM");
    }
    std::atomic<int> permission{0};
    int captures = 0;
    std::shared_ptr<FakePlatform> capture, play;
    Runtime runtime([&](bool input) {
        auto stream = std::make_shared<FakePlatform>();
        stream->channels = input ? 1 : 2;
        if (input) {
            ++captures;
            capture = stream;
        } else
            play = stream;
        return stream;
    });
    AMCL_TEST_CHECK(runtime.begin(
               99, [](void *p) { return static_cast<std::atomic<int> *>(p)->load(); }, &permission, true) ==
           0);
    uint64_t first = 0, second = 0, output = 0;
    AMCL_TEST_CHECK(runtime.open(1, 16000, 1, 1, 4096, &first) == AMCL_AUDIO_PERMISSION);
    permission = 1;
    AMCL_TEST_CHECK(runtime.open(1, 16000, 1, 1, 4096, &first) == 0);
    AMCL_TEST_CHECK(runtime.open(1, 22050, 2, 2, 8192, &second) == 0);
    AMCL_TEST_CHECK(captures == 1);
    AMCL_TEST_CHECK(runtime.start(first) == 0 && runtime.start(second) == 0);
    capture->feed(4800, 0.5f);
    eventually([&] { return runtime.available(first) >= 3200 && runtime.available(second) > 0; });
    std::vector<int16_t> recorded(1600);
    AMCL_TEST_CHECK(runtime.read(first, recorded.data(), 3200, false) == 3200);
    for (size_t i = 20; i < recorded.size(); ++i)
        AMCL_TEST_CHECK(std::abs(recorded[i] - 16384) <= 1);
    AMCL_TEST_CHECK(runtime.frames(first) == 1600);
    AMCL_TEST_CHECK(runtime.close(first) == 0 && capture->closes == 0);
    AMCL_TEST_CHECK(runtime.available(second) > 0);
    // 慢订阅者数据量受限，另一个消费者关闭不销毁共享capturer。
    for (int i = 0; i < 8; ++i) {
        capture->feed(4800, 0.25f);
        std::this_thread::sleep_for(4ms);
    }
    AMCL_TEST_CHECK(runtime.available(second) <= 8192);
    // 真实probe撤销后现有阻塞读退出，新open失败；前台恢复不偷偷重新开麦。
    runtime.flush(second);
    auto blocked = std::async(std::launch::async, [&] {
        float out[128];
        return runtime.read(second, out, sizeof(out), true);
    });
    permission = 0;
    AMCL_TEST_CHECK(runtime.refresh(99) == 0);
    AMCL_TEST_CHECK(blocked.wait_for(1s) == std::future_status::ready);
    AMCL_TEST_CHECK(runtime.state(second) & AMCL_AUDIO_FAILED);
    AMCL_TEST_CHECK(capture->closes == 1);
    permission = 1;
    AMCL_TEST_CHECK(runtime.foreground(99, false) == 0);
    uint64_t denied = 0;
    AMCL_TEST_CHECK(runtime.open(1, 16000, 1, 1, 4096, &denied) == AMCL_AUDIO_PERMISSION);
    AMCL_TEST_CHECK(runtime.foreground(99, true) == 0);
    // 不调用Refresh模拟另一个进程撤销用户开关：现有控制线程必须自己发现并释放设备。
    uint64_t remoteRevoked = 0;
    AMCL_TEST_CHECK(runtime.open(1, 16000, 1, 1, 4096, &remoteRevoked) == 0);
    AMCL_TEST_CHECK(runtime.start(remoteRevoked) == 0);
    const auto revokeStarted = std::chrono::steady_clock::now();
    permission = 0;
    eventually([&] { return (runtime.state(remoteRevoked) & AMCL_AUDIO_FAILED) != 0; });
    const auto revokeMillis = std::chrono::duration_cast<std::chrono::milliseconds>(
                                  std::chrono::steady_clock::now() - revokeStarted)
                                  .count();
    // 周期上限200ms，额外50ms仅是宿主线程调度/测试观察容差，不宣称硬实时墙钟保证。
    AMCL_TEST_CHECK(revokeMillis <= 250 && capture->closes == 1);
    std::printf("periodic permission revoke observed=%lldms (worker interval200ms)\\n",
                static_cast<long long>(revokeMillis));
    permission = 1;
    AMCL_TEST_CHECK(runtime.open(0, 22050, 2, 1, 4096, &output) == 0);
    std::vector<int16_t> pcm(2048, 8192);
    AMCL_TEST_CHECK(runtime.write(output, pcm.data(), 4096) == 4096);
    // stopped队列不被消耗；在stop后发起的drain等候，close则必须解除。
    auto drain = std::async(std::launch::async, [&] { return runtime.drain(output); });
    AMCL_TEST_CHECK(drain.wait_for(20ms) == std::future_status::timeout);
    AMCL_TEST_CHECK(runtime.stop(output) == 0);
    AMCL_TEST_CHECK(drain.wait_for(20ms) == std::future_status::timeout);
    AMCL_TEST_CHECK(runtime.start(output) == 0);
    eventually([&] { return play->ring.available() > 0; });
    AMCL_TEST_CHECK(play->consume(4096, false) > 0);
    // write回调已拿走的PCM仍在系统缓冲；硬件时间戳不动时不能报已播或解除drain。
    AMCL_TEST_CHECK(drain.wait_for(20ms) == std::future_status::timeout);
    AMCL_TEST_CHECK(runtime.frames(output) == 0);
    eventually([&] {
        play->consume();
        return drain.wait_for(0ms) == std::future_status::ready;
    });
    AMCL_TEST_CHECK(drain.get() == 0);
    AMCL_TEST_CHECK(runtime.frames(output) == 1024);
    AMCL_TEST_CHECK(runtime.available(output) == 4096);
    // 非阻塞尾帧请求可重复；它不能重复生成已经补过的尾帧。
    AMCL_TEST_CHECK(runtime.requestFinish(output) == 0 && runtime.requestFinish(output) == 0);
    runtime.stop(output);
    AMCL_TEST_CHECK(runtime.write(output, pcm.data(), 4096) == 4096);
    auto writer = std::async(std::launch::async, [&] { return runtime.write(output, pcm.data(), 4096); });
    AMCL_TEST_CHECK(writer.wait_for(20ms) == std::future_status::timeout);
    AMCL_TEST_CHECK(runtime.close(output) == 0);
    AMCL_TEST_CHECK(writer.wait_for(1s) == std::future_status::ready);
    AMCL_TEST_CHECK(writer.get() == 0);
    AMCL_TEST_CHECK(runtime.close(output) == 0);
    // flush只保留时间戳已证实的帧，丢弃回调已取走但未呈现的内容，并解除旧drain。
    uint64_t discardOutput = 0;
    AMCL_TEST_CHECK(runtime.open(0, 48000, 2, 1, 4096, &discardOutput) == 0);
    AMCL_TEST_CHECK(runtime.write(discardOutput, pcm.data(), 4096) == 4096);
    AMCL_TEST_CHECK(runtime.start(discardOutput) == 0);
    auto discardDrain = std::async(std::launch::async, [&] { return runtime.drain(discardOutput); });
    eventually([&] { return play->ring.available() > 0; });
    play->consume(4096, false);
    AMCL_TEST_CHECK(discardDrain.wait_for(20ms) == std::future_status::timeout);
    AMCL_TEST_CHECK(runtime.flush(discardOutput) == 0);
    AMCL_TEST_CHECK(discardDrain.wait_for(1s) == std::future_status::ready && discardDrain.get() == 0);
    AMCL_TEST_CHECK(runtime.frames(discardOutput) == 0 && runtime.available(discardOutput) == 4096);
    AMCL_TEST_CHECK(runtime.write(discardOutput, pcm.data(), 4096) == 4096);
    auto finalDrain = std::async(std::launch::async, [&] { return runtime.drain(discardOutput); });
    eventually([&] {
        play->consume();
        return finalDrain.wait_for(0ms) == std::future_status::ready;
    });
    AMCL_TEST_CHECK(finalDrain.get() == 0 && runtime.frames(discardOutput) == 1024);
    AMCL_TEST_CHECK(runtime.close(discardOutput) == 0);
    // 单个16000Hz输入帧首次convert只发一个48000Hz帧；非阻塞EOF请求必须补其余两帧。
    // 两次系统回调各填480帧，补零总计957帧都不能计入业务，只能报告这一个输入帧。
    uint64_t tailOutput = 0;
    AMCL_TEST_CHECK(runtime.open(0, 16000, 1, 1, 8, &tailOutput) == 0);
    AMCL_TEST_CHECK(runtime.write(tailOutput, pcm.data(), 2) == 2 && runtime.start(tailOutput) == 0);
    eventually([&] { return play->ring.available() == 2; });
    AMCL_TEST_CHECK(play->consume(480, false) == 2);
    AMCL_TEST_CHECK(runtime.requestFinish(tailOutput) == 0 && runtime.requestFinish(tailOutput) == 0);
    eventually([&] { return play->ring.available() == 4; });
    AMCL_TEST_CHECK(play->consume(480, false) == 4);
    AMCL_TEST_CHECK(runtime.frames(tailOutput) == 0);
    play->hardwarePosition = play->submitted;
    eventually([&] { return runtime.frames(tailOutput) == 1; });
    AMCL_TEST_CHECK(play->ring.available() == 0 && runtime.close(tailOutput) == 0);
    AMCL_TEST_CHECK(runtime.end(99) == 0);
    AMCL_TEST_CHECK(runtime.open(0, 48000, 2, 1, 4096, &output) == AMCL_AUDIO_UNAVAILABLE);
    AMCL_TEST_CHECK(runtime.begin(100, nullptr, nullptr, true) == AMCL_AUDIO_INVALID);
    std::puts("PASS production audio core: chunk conversion, shared capture, permission, bounded queues, "
              "hardware presentation mapping, nonblocking finish, drain, flush, close, session");
}
