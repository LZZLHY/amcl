#include "backend_input_bridge_host_stub.h"
#include "../../input/text_utf8_codec.h"

#include <cstring>
#include <deque>
#include <map>
#include <utility>
#include <vector>

namespace {

std::deque<AmclBackendInputEvent> g_queue;
bool g_unavailable = false;
unsigned long long g_activeCalls = 0;
std::map<uint64_t, std::vector<uint8_t>> g_textPackets;

}  // namespace

extern "C" void amclBackendInputHostStubReset(void) {
    g_queue.clear();
    g_unavailable = false;
    g_activeCalls = 0;
    g_textPackets.clear();
}

extern "C" void amclBackendInputHostStubSetUnavailable(int unavailable) {
    g_unavailable = unavailable != 0;
}

extern "C" void amclBackendInputHostStubPush(const AmclBackendInputEvent* event) {
    if (!event) return;
    g_queue.push_back(*event);
}

extern "C" void amclBackendInputHostStubSetTextPacket(
        uint64_t packetId, const uint8_t* bytes, uint32_t byteCount) {
    if (packetId == 0u || (!bytes && byteCount != 0u)) return;
    std::vector<uint8_t> value;
    if (byteCount != 0u) value.assign(bytes, bytes + byteCount);
    g_textPackets[packetId] = std::move(value);
}

extern "C" unsigned long long amclBackendInputHostStubActiveCalls(void) {
    return g_activeCalls;
}

extern "C" int amclBackendInputNext(uint32_t backend, AmclBackendInputEvent* out) {
    if (!out) return AMCL_BACKEND_INPUT_ERROR_ARGUMENT;
    if (backend != AMCL_BACKEND_INPUT_LWJGL2 &&
        backend != AMCL_BACKEND_INPUT_SDL3) {
        return AMCL_BACKEND_INPUT_ERROR_ARGUMENT;
    }
    if (g_unavailable) return AMCL_BACKEND_INPUT_ERROR_UNAVAILABLE;
    if (g_queue.empty()) return AMCL_BACKEND_INPUT_EMPTY;
    *out = g_queue.front();
    g_queue.pop_front();
    out->abiVersion = static_cast<uint16_t>(AMCL_BACKEND_INPUT_ABI_VERSION);
    out->structSize = static_cast<uint16_t>(sizeof(*out));
    return AMCL_BACKEND_INPUT_EVENT;
}

extern "C" void amclBackendInputSetActive(uint32_t backend, int active) {
    (void)backend;
    (void)active;
    ++g_activeCalls;
}

extern "C" int amclBackendInputReadText(
        uint32_t backend, uint64_t packetId, uint8_t* outBytes,
        uint32_t capacity, uint32_t* outByteCount) {
    if ((backend != AMCL_BACKEND_INPUT_LWJGL2 &&
         backend != AMCL_BACKEND_INPUT_SDL3) || !outByteCount ||
        (!outBytes && capacity != 0u)) {
        return AMCL_BACKEND_INPUT_ERROR_ARGUMENT;
    }
    const auto found = g_textPackets.find(packetId);
    if (found == g_textPackets.end()) return AMCL_BACKEND_INPUT_ERROR_NOT_FOUND;
    *outByteCount = static_cast<uint32_t>(found->second.size());
    if (capacity < found->second.size() ||
        (!outBytes && !found->second.empty())) {
        return AMCL_BACKEND_INPUT_ERROR_BUFFER_TOO_SMALL;
    }
    if (!found->second.empty()) {
        std::memcpy(outBytes, found->second.data(), found->second.size());
    }
    return AMCL_BACKEND_INPUT_EVENT;
}

extern "C" int amclBackendInputReadTextScalars(
        uint32_t backend, uint64_t packetId, uint32_t* outScalars,
        uint32_t capacity, uint32_t* outScalarCount) {
    if ((backend != AMCL_BACKEND_INPUT_LWJGL2 &&
         backend != AMCL_BACKEND_INPUT_SDL3) || !outScalarCount ||
        (!outScalars && capacity != 0u)) {
        return AMCL_BACKEND_INPUT_ERROR_ARGUMENT;
    }
    const auto found = g_textPackets.find(packetId);
    if (found == g_textPackets.end()) return AMCL_BACKEND_INPUT_ERROR_NOT_FOUND;
    size_t count = 0u;
    const auto status = amcl::input::DecodeTextUtf8Scalars(
        found->second.data(), found->second.size(), outScalars, capacity,
        &count);
    *outScalarCount = static_cast<uint32_t>(count);
    if (status == amcl::input::TextUtf8CodecStatus::kOutputTooSmall) {
        return AMCL_BACKEND_INPUT_ERROR_BUFFER_TOO_SMALL;
    }
    return status == amcl::input::TextUtf8CodecStatus::kOk
        ? AMCL_BACKEND_INPUT_EVENT : AMCL_BACKEND_INPUT_ERROR_MALFORMED;
}

extern "C" int amclBackendInputReleaseText(
        uint32_t backend, uint64_t packetId) {
    if (backend != AMCL_BACKEND_INPUT_LWJGL2 &&
        backend != AMCL_BACKEND_INPUT_SDL3) {
        return AMCL_BACKEND_INPUT_ERROR_ARGUMENT;
    }
    return g_textPackets.erase(packetId) == 1u
        ? AMCL_BACKEND_INPUT_EVENT : AMCL_BACKEND_INPUT_ERROR_NOT_FOUND;
}

extern "C" void amclBackendInputPublishAddress(void) {}
