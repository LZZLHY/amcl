/* 仅验证独立timing探针第二段的字节账目与上限，绝不调用RunAudioTimingQualification
 * 或任何OHAudio设备API。第一段原用户返回保持，静音不增长用户read/帧计数。 */
#define MC_OHOS_BUILD_TESTS 1
#include "../../entry/src/main/cpp/napi/jdk_audio_timing_qualification.cpp"
#include <cassert>

int main() {
    using namespace amcl::jdkqualification;
    Context context;
    AmclLine line{};
    unsigned char ring[16384], output[32];
    memset(ring, 0x21, sizeof(ring));
    line.ring = ring; line.capacity = sizeof(ring); line.frameSize = 4; line.isSource = 1;
    line.copyEnabled = 1; line.read = 44100 - 8; line.written = 44100;
    context.callback.owner = &line;
    memset(output, 0xAA, sizeof(output));
    assert(TimingData(nullptr, &context, output, sizeof(output)) == 8);
    assert(context.userReturned == 8 && context.silenceReturned == 0 && output[8] == 0xAA);

    line.read = 44100 - 8; context.paddingRemaining = 16;
    memset(output, 0xAA, sizeof(output));
    assert(TimingData(nullptr, &context, output, 16) == 16);
    for (int i = 0; i < 8; ++i) assert(output[i] == 0x21);
    for (int i = 8; i < 16; ++i) assert(output[i] == 0);
    assert(line.read == 44100 && context.userReturned == 16 && context.silenceReturned == 8);
    memset(output, 0xAA, sizeof(output));
    assert(TimingData(nullptr, &context, output, sizeof(output)) == 8);
    assert(context.paddingRemaining == 0 && context.silenceReturned == 16 && line.read == 44100);
    assert(output[7] == 0 && output[8] == 0xAA);
    memset(output, 0xAA, sizeof(output));
    assert(TimingData(nullptr, &context, output, sizeof(output)) == 0 && output[0] == 0xAA);
    context.paddingRemaining = 16; line.copyEnabled = 0;
    assert(TimingData(nullptr, &context, output, sizeof(output)) == 0 && context.paddingRemaining == 16);
    line.copyEnabled = 1; line.error = AUDIOSTREAM_ERROR_SYSTEM;
    assert(TimingData(nullptr, &context, output, sizeof(output)) == 0 && context.paddingRemaining == 16);
    context.callback.owner = nullptr;
    assert(TimingData(nullptr, &context, output, sizeof(output)) == 0 && context.callback.active == 0);
    assert(context.returned == context.userReturned + context.silenceReturned);
    puts("PASS timing baseline bytes, partial tail silence, exact budget, user/platform separation, stopped/error/detached owner");
}
