/**
 * ohaudio.cpp — OHAudio backend for OpenAL Soft 1.24.3
 *
 * Implements audio playback on HarmonyOS NEXT using the OHAudio C API (API 12+).
 * Uses the individual callback setter API (OH_AudioStreamBuilder_SetRendererWriteDataCallback),
 * not the deprecated OH_AudioRenderer_Callbacks struct.
 *
 * OHAudio uses a callback-based pull model: the system calls our write-data
 * callback when it needs more audio samples. We call mDevice->renderSamples()
 * directly in the callback to mix audio from OpenAL Soft into the output buffer.
 *
 * Requires: API 12+, link against libohaudio.so
 */

#include "config.h"

#include "ohaudio.h"

#include <cstring>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

#include "alc/alconfig.h"
#include "core/device.h"
#include "core/logging.h"

#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiorenderer.h>

namespace {

using namespace std::string_view_literals;

constexpr auto OHAudioDeviceName = "OHAudio Default"sv;

OH_AudioStream_SampleFormat MapSampleFormat(DevFmtType type)
{
    switch(type)
    {
    case DevFmtByte:
    case DevFmtUByte:
        return AUDIOSTREAM_SAMPLE_U8;
    case DevFmtShort:
    case DevFmtUShort:
        return AUDIOSTREAM_SAMPLE_S16LE;
    case DevFmtInt:
    case DevFmtUInt:
        return AUDIOSTREAM_SAMPLE_S32LE;
    case DevFmtFloat:
        return AUDIOSTREAM_SAMPLE_F32LE;
    }
    return AUDIOSTREAM_SAMPLE_S16LE;
}

struct OHAudioPlayback final : public BackendBase {
    OHAudioPlayback(DeviceBase *device) noexcept : BackendBase{device} { }
    ~OHAudioPlayback() override;

    void open(std::string_view name) override;
    auto reset() -> bool override;
    void start() override;
    void stop() override;

    OH_AudioStreamBuilder *mBuilder{nullptr};
    OH_AudioRenderer *mRenderer{nullptr};
    unsigned mFrameSize{0};

    static OH_AudioData_Callback_Result OnWriteData(
        OH_AudioRenderer *renderer, void *userData,
        void *audioData, int32_t audioDataSize);
};

OHAudioPlayback::~OHAudioPlayback()
{
    if(mRenderer)
    {
        OH_AudioRenderer_Release(mRenderer);
        mRenderer = nullptr;
    }
    if(mBuilder)
    {
        OH_AudioStreamBuilder_Destroy(mBuilder);
        mBuilder = nullptr;
    }
}

OH_AudioData_Callback_Result OHAudioPlayback::OnWriteData(
    OH_AudioRenderer*, void *userData,
    void *audioData, int32_t audioDataSize)
{
    auto *self = static_cast<OHAudioPlayback*>(userData);

    if(self->mFrameSize == 0)
    {
        std::memset(audioData, 0, static_cast<size_t>(audioDataSize));
        return AUDIO_DATA_CALLBACK_RESULT_VALID;
    }

    const auto numFrames = static_cast<unsigned>(
        static_cast<size_t>(audioDataSize) / self->mFrameSize);
    const auto channelStep = static_cast<unsigned>(
        self->mDevice->channelsFromFmt());

    self->mDevice->renderSamples(audioData, numFrames, channelStep);

    return AUDIO_DATA_CALLBACK_RESULT_VALID;
}

void OHAudioPlayback::open(std::string_view name)
{
    if(name.empty())
        name = OHAudioDeviceName;
    else if(name != OHAudioDeviceName)
        throw al::backend_exception{al::backend_error::NoDevice,
            "Device name \"{}\" not found", name};

    mDeviceName = name;
}

auto OHAudioPlayback::reset() -> bool
{
    if(mRenderer)
    {
        OH_AudioRenderer_Release(mRenderer);
        mRenderer = nullptr;
    }
    if(mBuilder)
    {
        OH_AudioStreamBuilder_Destroy(mBuilder);
        mBuilder = nullptr;
    }

    switch(mDevice->FmtType)
    {
    case DevFmtByte:
    case DevFmtUByte:
    case DevFmtShort:
    case DevFmtUShort:
        mDevice->FmtType = DevFmtShort;
        break;
    case DevFmtInt:
    case DevFmtUInt:
        mDevice->FmtType = DevFmtInt;
        break;
    case DevFmtFloat:
        mDevice->FmtType = DevFmtFloat;
        break;
    }

    if(mDevice->FmtChans != DevFmtMono)
        mDevice->FmtChans = DevFmtStereo;

    setDefaultChannelOrder();

    mFrameSize = mDevice->frameSizeFromFmt();

    OH_AudioStream_Result result = OH_AudioStreamBuilder_Create(
        &mBuilder, AUDIOSTREAM_TYPE_RENDERER);
    if(result != AUDIOSTREAM_SUCCESS || !mBuilder)
    {
        ERR("OHAudio: Failed to create stream builder: %d\n",
            static_cast<int>(result));
        throw al::backend_exception{al::backend_error::DeviceError,
            "Failed to create OHAudio stream builder"};
    }

    OH_AudioStreamBuilder_SetSamplingRate(mBuilder,
        static_cast<int32_t>(mDevice->mSampleRate));
    OH_AudioStreamBuilder_SetChannelCount(mBuilder,
        static_cast<int32_t>(mDevice->channelsFromFmt()));
    OH_AudioStreamBuilder_SetSampleFormat(mBuilder,
        MapSampleFormat(mDevice->FmtType));
    OH_AudioStreamBuilder_SetEncodingType(mBuilder,
        AUDIOSTREAM_ENCODING_TYPE_RAW);
    OH_AudioStreamBuilder_SetRendererInfo(mBuilder,
        AUDIOSTREAM_USAGE_GAME);
    OH_AudioStreamBuilder_SetLatencyMode(mBuilder,
        AUDIOSTREAM_LATENCY_MODE_FAST);

    OH_AudioStreamBuilder_SetRendererWriteDataCallback(mBuilder,
        OHAudioPlayback::OnWriteData, this);

    result = OH_AudioStreamBuilder_GenerateRenderer(mBuilder, &mRenderer);
    if(result != AUDIOSTREAM_SUCCESS || !mRenderer)
    {
        OH_AudioStreamBuilder_Destroy(mBuilder);
        mBuilder = nullptr;
        ERR("OHAudio: Failed to generate renderer: %d\n",
            static_cast<int>(result));
        throw al::backend_exception{al::backend_error::DeviceError,
            "Failed to create OHAudio renderer"};
    }

    TRACE("OHAudio: reset OK — %uHz %uch %s, frameSize=%u\n",
          mDevice->mSampleRate, mDevice->channelsFromFmt(),
          DevFmtTypeString(mDevice->FmtType), mFrameSize);

    return true;
}

void OHAudioPlayback::start()
{
    if(!mRenderer)
        throw al::backend_exception{al::backend_error::DeviceError,
            "No OHAudio renderer"};

    OH_AudioStream_Result result = OH_AudioRenderer_Start(mRenderer);
    if(result != AUDIOSTREAM_SUCCESS)
    {
        ERR("OHAudio: Failed to start renderer: %d\n",
            static_cast<int>(result));
        throw al::backend_exception{al::backend_error::DeviceError,
            "Failed to start OHAudio renderer"};
    }
    TRACE("OHAudio: playback started\n");
}

void OHAudioPlayback::stop()
{
    if(!mRenderer)
        return;

    OH_AudioRenderer_Stop(mRenderer);
    TRACE("OHAudio: playback stopped\n");
}

} /* anonymous namespace */


auto OHAudioBackendFactory::init() -> bool
{
    return true;
}

auto OHAudioBackendFactory::querySupport(BackendType type) -> bool
{
    return type == BackendType::Playback;
}

auto OHAudioBackendFactory::enumerate(BackendType type)
    -> std::vector<std::string>
{
    switch(type)
    {
    case BackendType::Playback:
        return std::vector{std::string{OHAudioDeviceName}};
    case BackendType::Capture:
        break;
    }
    return {};
}

auto OHAudioBackendFactory::createBackend(DeviceBase *device,
    BackendType type) -> BackendPtr
{
    if(type == BackendType::Playback)
        return BackendPtr{new OHAudioPlayback{device}};
    return nullptr;
}

auto OHAudioBackendFactory::getFactory() -> BackendFactory&
{
    static OHAudioBackendFactory factory{};
    return factory;
}
