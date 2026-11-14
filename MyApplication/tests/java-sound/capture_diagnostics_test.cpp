/* 固定诊断表/采样预算/关闭快照的纯宿主回归；合成输入不是录音，不申请设备。
 * 正负例在独立进程调用一次Begin，精确交错覆盖Finish撤arm及并发callback的拒绝。 */
#include "ohos_capture_diagnostics.h"
#include "jdk_capture_diagnostics.h"
#include <cassert>
#include <cmath>
#include <condition_variable>
#include <fcntl.h>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>

static std::mutex gateMutex;
static std::condition_variable gateCondition;
static unsigned gatePhase;
static bool gateReached, gateReleased;

extern "C" void amcl_capture_diagnostic_test_hook(unsigned phase, unsigned index)
{
    std::unique_lock<std::mutex> lock(gateMutex);
    if (index || phase != gatePhase || gateReached) return;
    gateReached = true; gateCondition.notify_all();
    gateCondition.wait(lock, [] { return gateReleased; });
}

struct Stream {
    AmclLine line{}; AmclCallback context{};
    Stream(int capacity, int frame, int callbackBytes) {
        assert(amcl_capture_init(&line.capture, capacity, frame, callbackBytes));
        line.copyEnabled = 1; line.frameSize = frame; line.capacity = line.capture.capacity; context.owner = &line;
    }
    ~Stream() { context.owner = nullptr; assert(!context.active); amcl_capture_destroy(&line.capture); }
};

static int16_t sample(uint64_t index) { return int16_t(int((index * 157) % 511) - 255); }
static void fill(unsigned char *buffer, uint64_t first, unsigned frames) {
    for (unsigned index = 0; index < frames; ++index) {
        auto value = uint16_t(sample(first + index));
        buffer[index * 2] = uint8_t(value); buffer[index * 2 + 1] = uint8_t(value >> 8);
    }
}

static void feed(const AmclDAudioCallbackAbiV2 *table, Stream &stream, unsigned target, unsigned callbackFrames) {
    unsigned char buffer[640]; unsigned produced = 0;
    while (produced < target) {
        unsigned count = target - produced < callbackFrames ? target - produced : callbackFrames;
        fill(buffer, produced, count); table->captureData(nullptr, &stream.context, buffer, int32_t(count * 2)); produced += count;
    }
    /* 预算之后的满幅数据不得改变prefix peak/RMS；也证明callback仍正常复制后续PCM。 */
    for (unsigned i = 0; i < callbackFrames; ++i) { buffer[2 * i] = 0xff; buffer[2 * i + 1] = 0x7f; }
    table->captureData(nullptr, &stream.context, buffer, int32_t(callbackFrames * 2));
    assert(amcl_capture_position(&stream.line.capture) == (target + callbackFrames) * 2);
    if (stream.line.capacity >= int((target + callbackFrames) * 2)) {
        unsigned char readback[2048]; unsigned read = 0;
        while (read < target) {
            int request = int((target - read) * 2); if (request > 2048) request = 2048;
            int count = amcl_capture_read(&stream.line.capture, readback, request); assert(count == request);
            for (int i = 0; i < count / 2; ++i)
                assert(int16_t(unsigned(readback[i * 2]) | (unsigned(readback[i * 2 + 1]) << 8)) == sample(read + unsigned(i)));
            read += unsigned(count) / 2;
        }
    }
}

int main(int argc, char **argv)
{
    assert(argc == 3); std::string mode = argv[1];
    const auto *normal = amcl_javasound_callbacks_v2(); assert(amcl_daudio_callbacks_valid_v2(normal));
    amcl::jdkqualification::BeginCaptureDiagnostic(); assert(!amcl_capture_diagnostics_begin());
    const auto *first = amcl_javasound_callbacks_v2(), *second = amcl_javasound_callbacks_v2();
    assert(amcl_daudio_callbacks_valid_v2(first) && amcl_daudio_callbacks_valid_v2(second));
    assert(first->captureData != normal->captureData && second->captureData != first->captureData);
    if (mode == "extra-open") assert(amcl_javasound_callbacks_v2() == nullptr);
    if (mode == "inflight" || mode == "concurrent") {
        Stream stream(12800, 2, 640); unsigned char buffer[640]; fill(buffer, 0, 320);
        gatePhase = mode == "inflight" ? 1 : 2;
        std::thread worker([&] { first->captureData(nullptr, &stream.context, buffer, sizeof(buffer)); });
        { std::unique_lock<std::mutex> lock(gateMutex); gateCondition.wait(lock, [] { return gateReached; }); }
        AmclCaptureDiagnosticReport failed{};
        if (mode == "inflight") { assert(!amcl_capture_diagnostics_finish(&failed)); assert(!failed.quiescent && !failed.passes[0].measuredFrames); }
        else first->captureData(nullptr, &stream.context, buffer, sizeof(buffer));
        { std::lock_guard<std::mutex> lock(gateMutex); gateReleased = true; } gateCondition.notify_all(); worker.join();
        if (mode == "inflight") {
            assert(!amcl_capture_diagnostics_finish(&failed));
            assert(amcl_javasound_callbacks_v2() == normal && amcl_capture_position(&stream.line.capture) == 640);
            std::cout << "PASS inflight rejected without reading stats; original callback still copied after disarm\n"; return 0;
        }
    } else {
        {
            Stream low(mode == "prefix-overwrite" ? 512 : 12800, mode == "wrong-frame" ? 4 : 2, 640);
            if (mode == "bad-order") { unsigned char data[640]; fill(data, 0, 320); assert(amcl_capture_push(&low.line.capture, data, 640) == 1); }
            if (mode == "wrong-frame") { unsigned char data[640]; fill(data, 0, 320); first->captureData(nullptr, &low.context, data, 640); }
            else if (mode != "bad-order") feed(first, low, 3200, 320);
            else { unsigned char data[640]; fill(data, 320, 320); first->captureData(nullptr, &low.context, data, 640); }
        }
        { Stream high(38400, 2, 480); feed(second, high, 9600, 240); }
    }
    int fd = open(argv[2], O_RDONLY | O_DIRECTORY | O_CLOEXEC); assert(fd >= 0);
    std::string report = amcl::jdkqualification::FinishCaptureDiagnostic(fd); close(fd);
    assert(amcl_javasound_callbacks_v2() == normal);
    std::cout << report;
    return 0;
}
