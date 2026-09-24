#include "amcl_input_host_descriptor.h"

#include <cstdint>

#ifdef _WIN32
#define AMCL_DSO_TEST_EXPORT extern "C" __declspec(dllexport)
#else
#define AMCL_DSO_TEST_EXPORT extern "C" __attribute__((visibility("default")))
#endif

namespace {
int32_t Begin(uint64_t*) { return AMCL_INPUT_OK; }
int32_t End(uint64_t) { return AMCL_INPUT_OK; }
int32_t Submit(const AmclInputEvent*) { return AMCL_INPUT_OK; }
int32_t SubmitBatch(const AmclInputEvent*, uint32_t) { return AMCL_INPUT_OK; }
int32_t SubmitText(const AmclInputEvent*, const uint8_t*, uint32_t) { return AMCL_INPUT_OK; }
int32_t Surface(const AmclInputSurfacePayload*) { return AMCL_INPUT_OK; }
int32_t Focus(uint32_t) { return AMCL_INPUT_OK; }
int32_t Device(uint64_t, uint32_t, uint32_t) { return AMCL_INPUT_OK; }
int32_t Reset(uint32_t) { return AMCL_INPUT_OK; }
int32_t Open(AmclInputConsumerHandle*) { return AMCL_INPUT_OK; }
int32_t Next(AmclInputConsumerHandle, AmclInputEvent*) { return AMCL_INPUT_OK; }
int32_t Read(AmclInputConsumerHandle, const AmclInputBlobRef*, uint8_t*, uint32_t, uint32_t*) { return AMCL_INPUT_OK; }
int32_t Release(AmclInputConsumerHandle, uint64_t) { return AMCL_INPUT_OK; }
int32_t Close(AmclInputConsumerHandle) { return AMCL_INPUT_OK; }
int32_t Snapshot(AmclInputSnapshotV1*) { return AMCL_INPUT_OK; }

const AmclInputHostApiV1 kApi = {
    AMCL_INPUT_HOST_API_MAGIC, AMCL_INPUT_HOST_API_VERSION,
    sizeof(AmclInputHostApiV1), AMCL_INPUT_HOST_REQUIRED_CAPABILITIES_V1,
    AMCL_INPUT_HOST_API_GENERATION, Begin, End, Submit, SubmitBatch,
    SubmitText, Surface, Focus, Device, Reset, Open, Next, Read, Release,
    Close, Snapshot};
}  // namespace

AMCL_DSO_TEST_EXPORT int32_t amclDescriptorFixturePublish() {
    return amclInputHostDescriptorPublishV1(&kApi);
}
AMCL_DSO_TEST_EXPORT int32_t amclDescriptorFixtureClear() {
    return amclInputHostDescriptorClearV1();
}
AMCL_DSO_TEST_EXPORT uintptr_t amclDescriptorFixtureApiAddress() {
    return reinterpret_cast<uintptr_t>(&kApi);
}
AMCL_DSO_TEST_EXPORT int32_t amclDescriptorFixtureResolve(
        uintptr_t* outAddress) {
    if (!outAddress) return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_INVALID_ARGUMENT;
    const AmclInputHostApiV1* api = nullptr;
    const int32_t result = amclInputHostDescriptorResolveV1(&api);
    *outAddress = reinterpret_cast<uintptr_t>(api);
    return result;
}
