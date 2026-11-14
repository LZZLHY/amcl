/* 使用同一真实平台协议替身，先验录音再完整重跑播放，避免复用输出句柄伪装输入。 */
#define amcl_test_run amcl_playback_test_run
#include "daudio_backend_test.c"
#undef amcl_test_run

static void capture_clean(void)
{
    assert(!builders && !capturers && !currentCapture);
    failure = NULL; mismatch = 0; captureAllowed = 1;
}

static void *capture_open(void)
{ return DAUDIO_Open(0, 0, FALSE, DAUDIO_PCM, 48000, 16, 4, 2, TRUE, FALSE, 32); }

int amcl_test_run(void)
{
    static const char *steps[] = {"Create", "SetSamplingRate", "SetChannelCount", "SetSampleFormat", "SetEncodingType",
        "SetCapturerInfo", "SetCapturerReadDataCallback", "SetCapturerErrorCallback", "SetCapturerInterruptCallback",
        "GenerateCapturer", "CaptureRate", "CaptureChannels", "CaptureFormat", "CaptureEncoding", "CaptureCallbackFrames"};
    unsigned char input[256], out[128];
    void *line;
    captureRoutePresent = 1; routePresent = 0;
    assert(DAUDIO_GetDirectAudioDeviceCount() == 1); /* 只有真实输入路由也可枚举，不伪造输出。 */
    formats = 0; DAUDIO_GetFormats(0, 0, FALSE, &formats); assert(formats == 16); formats = 0;
    DAUDIO_GetFormats(0, 0, TRUE, &formats); assert(formats == 0);
    captureAllowed = 0; assert(!capture_open()); capture_clean(); /* 未授权确实不能打开。 */
    for (unsigned i = 0; i < sizeof(steps) / sizeof(steps[0]); ++i) {
        failure = steps[i]; assert(!capture_open()); capture_clean();
    }
    mismatch = 1; assert(!capture_open()); capture_clean();
    line = capture_open(); assert(line && DAUDIO_GetBufferSize(line, FALSE) == 32);
    for (unsigned i = 0; i < sizeof(input); ++i) input[i] = (unsigned char)i;
    currentCapture->config.captureData(currentCapture, currentCapture->config.opaque, input, 16);
    assert(DAUDIO_GetBytePosition(line, FALSE, 0) == 0 && DAUDIO_Read(line, (char *)out, 16) == 0);
    assert(DAUDIO_Start(line, FALSE));
    currentCapture->config.captureData(currentCapture, currentCapture->config.opaque, input, 16);
    memset(out, 0xAA, sizeof(out));
    assert(DAUDIO_GetAvailable(line, FALSE) == 16 && DAUDIO_Read(line, (char *)out, 32) == 16);
    assert(!memcmp(out, input, 16) && out[16] == 0xAA && DAUDIO_GetBytePosition(line, FALSE, 16) == 16);
    currentCapture->config.captureData(currentCapture, currentCapture->config.opaque, input, 128);
    assert(DAUDIO_GetAvailable(line, FALSE) == 32 && DAUDIO_Read(line, (char *)out, 32) == 32);
    assert(!memcmp(out, input + 96, 32) && DAUDIO_GetBytePosition(line, FALSE, 48) == 144);
    assert(DAUDIO_Stop(line, FALSE));
    currentCapture->config.captureData(currentCapture, currentCapture->config.opaque, input, 16);
    assert(DAUDIO_GetBytePosition(line, FALSE, 0) == 144);
    assert(DAUDIO_Start(line, FALSE));
    currentCapture->config.captureData(currentCapture, currentCapture->config.opaque, input, 16);
    assert(DAUDIO_Flush(line, FALSE) && DAUDIO_GetAvailable(line, FALSE) == 0);
    assert(DAUDIO_GetBytePosition(line, FALSE, 0) == 160 && currentCapture->state == AUDIOSTREAM_STATE_RUNNING);
    currentCapture->config.captureInterrupt(currentCapture, currentCapture->config.opaque,
        AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_MUTE);
    DAUDIO_Service(line, FALSE); assert(currentCapture->state == AUDIOSTREAM_STATE_PAUSED);
    currentCapture->config.captureData(currentCapture, currentCapture->config.opaque, input, 16);
    assert(DAUDIO_GetBytePosition(line, FALSE, 0) == 160);
    assert(DAUDIO_Stop(line, FALSE));
    currentCapture->config.captureInterrupt(currentCapture, currentCapture->config.opaque,
        AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_UNMUTE);
    DAUDIO_Service(line, FALSE); assert(currentCapture->state == AUDIOSTREAM_STATE_PAUSED);
    assert(DAUDIO_Start(line, FALSE));
    currentCapture->config.captureError(currentCapture, currentCapture->config.opaque, AUDIOSTREAM_ERROR_SYSTEM);
    assert(DAUDIO_Read(line, (char *)out, 16) == -1 && AMCL_DAudio_GetError(line) == AUDIOSTREAM_ERROR_SYSTEM);
    assert(AMCL_DAudio_Close(line) == 0); capture_clean();
    line = capture_open(); failure = "CaptureStart"; assert(!DAUDIO_Start(line, FALSE));
    failure = NULL; assert(AMCL_DAudio_Close(line) == 0); capture_clean();
    line = capture_open(); assert(DAUDIO_Start(line, FALSE)); failure = "CapturePause";
    assert(!DAUDIO_Stop(line, FALSE)); failure = NULL; assert(AMCL_DAudio_Close(line) == 0); capture_clean();
    line = capture_open(); assert(DAUDIO_Start(line, FALSE)); failure = "CaptureFlush";
    assert(!DAUDIO_Flush(line, FALSE)); failure = NULL; assert(AMCL_DAudio_Close(line) == 0); capture_clean();
    captureRoutePresent = 0; routePresent = 1;
    puts("PASS real DAUDIO Capture: input-only route, denied permission, 15 setup failures, actual bytes/partial/oldest-drop, pause/flush/mute, errors and close");
    return amcl_playback_test_run();
}
