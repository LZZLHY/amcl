#include "amcl_input_host_descriptor.h"
#include "amcl_input_mapped_ranges.h"

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <limits>

#ifdef _WIN32
#include <windows.h>
#else
#include <cerrno>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace {

constexpr char kPrefix[] = "AMCL_INPUT_HOST_V1:";
constexpr size_t kGenerationHexDigits = 16u;
constexpr size_t kPointerHexDigits = sizeof(uintptr_t) * 2u;
constexpr size_t kDescriptorLength = sizeof(kPrefix) - 1u +
                                     kGenerationHexDigits + 1u +
                                     kPointerHexDigits;

static_assert(sizeof(uintptr_t) <= sizeof(unsigned long long),
              "descriptor formatting requires uintptr_t to fit uint64_t");

// Each linker namespace contains a private copy of this helper, so a C++ mutex
// cannot serialize owner claims. This RAII guard deliberately uses a named OS
// primitive shared by every DSO in the process. Failure is fail-closed: callers
// must not inspect or mutate the descriptor without owning the common lock.
class ProcessDescriptorLock {
public:
    ProcessDescriptorLock() {
#ifdef _WIN32
        wchar_t name[96]{};
        const int written = std::swprintf(
            name, sizeof(name) / sizeof(name[0]),
            L"Local\\AMCL.InputHostDescriptor.%lu",
            static_cast<unsigned long>(GetCurrentProcessId()));
        if (written <= 0 ||
            static_cast<size_t>(written) >= sizeof(name) / sizeof(name[0])) {
            return;
        }
        handle_ = CreateMutexW(nullptr, FALSE, name);
        if (!handle_) return;
        const DWORD wait = WaitForSingleObject(handle_, INFINITE);
        if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED) {
            acquired_ = true;
            return;
        }
        CloseHandle(handle_);
        handle_ = nullptr;
#else
#ifdef __OHOS__
        constexpr const char* kLockDirectory =
            "/data/storage/el2/base/files";
#else
        constexpr const char* kLockDirectory = "/tmp";
#endif
        // The lock identity is selected at compile time and never falls back to
        // another inode. If this one path is unavailable, fail closed: choosing
        // a second path could let another DSO continue holding the first lock.
        char path[192]{};
        const int written = std::snprintf(
            path, sizeof(path), "%s/.amcl_input_host_descriptor_%lld.lock",
            kLockDirectory, static_cast<long long>(getpid()));
        if (written <= 0 || static_cast<size_t>(written) >= sizeof(path)) {
            return;
        }
        int flags = O_CREAT | O_RDWR;
#ifdef O_CLOEXEC
        flags |= O_CLOEXEC;
#endif
#ifdef O_NOFOLLOW
        flags |= O_NOFOLLOW;
#endif
        int candidate = -1;
        do {
            candidate = open(path, flags, S_IRUSR | S_IWUSR);
        } while (candidate < 0 && errno == EINTR);
        if (candidate < 0) return;
        struct stat info {};
        int statResult = -1;
        do {
            statResult = fstat(candidate, &info);
        } while (statResult != 0 && errno == EINTR);
        if (statResult != 0 || !S_ISREG(info.st_mode) ||
            info.st_uid != geteuid()) {
            close(candidate);
            return;
        }
        for (;;) {
            if (flock(candidate, LOCK_EX) == 0) {
                fd_ = candidate;
                acquired_ = true;
                return;
            }
            if (errno != EINTR) {
                close(candidate);
                return;
            }
        }
#endif
    }

    ~ProcessDescriptorLock() {
#ifdef _WIN32
        if (handle_) {
            if (acquired_) ReleaseMutex(handle_);
            CloseHandle(handle_);
        }
#else
        if (fd_ >= 0) {
            if (acquired_) {
                while (flock(fd_, LOCK_UN) != 0 && errno == EINTR) {}
            }
            close(fd_);
        }
#endif
    }

    ProcessDescriptorLock(const ProcessDescriptorLock&) = delete;
    ProcessDescriptorLock& operator=(const ProcessDescriptorLock&) = delete;
    bool acquired() const { return acquired_; }
#ifndef _WIN32
    int descriptorFd() const { return fd_; }
#endif

private:
    bool acquired_ = false;
#ifdef _WIN32
    HANDLE handle_ = nullptr;
#else
    int fd_ = -1;
#endif
};

bool DecodeHex(const char* text, size_t count, uint64_t* out) {
    if (!text || !out || count == 0u || count > 16u) return false;
    uint64_t value = 0u;
    for (size_t index = 0; index < count; ++index) {
        const unsigned char c = static_cast<unsigned char>(text[index]);
        uint8_t digit = 0u;
        if (c >= '0' && c <= '9') digit = static_cast<uint8_t>(c - '0');
        else if (c >= 'a' && c <= 'f') digit = static_cast<uint8_t>(c - 'a' + 10u);
        else if (c >= 'A' && c <= 'F') digit = static_cast<uint8_t>(c - 'A' + 10u);
        else return false;
        value = (value << 4u) | digit;
    }
    *out = value;
    return true;
}

/**
 * 地址资格保持原平台语义。Resolve 传入本轮集合以合并 Linux maps 扫描；其他入口不借该集合。
 * Windows 正式产品仍逐范围 VirtualQuery；宿主专用宏只适配 procfs 文本源，不进入产品编译。
 */
bool IsMappedRange(uintptr_t address, size_t size, bool executable,
                   amcl::input::detail::MappedRangeSnapshot* mappingSnapshot = nullptr) {
    if (address == 0u || size == 0u || address > UINTPTR_MAX - size) {
        return false;
    }
#if defined(_WIN32) && !defined(AMCL_INPUT_DESCRIPTOR_MAPS_TESTING)
    (void)mappingSnapshot;
    const uintptr_t limit = address + size;
    uintptr_t cursor = address;
    while (cursor < limit) {
        MEMORY_BASIC_INFORMATION info{};
        if (VirtualQuery(reinterpret_cast<const void*>(cursor), &info,
                         sizeof(info)) != sizeof(info) ||
            info.State != MEM_COMMIT || (info.Protect & PAGE_GUARD) != 0u ||
            (info.Protect & PAGE_NOACCESS) != 0u) {
            return false;
        }
        const DWORD protection = info.Protect & 0xffu;
        const bool readable = protection == PAGE_READONLY ||
            protection == PAGE_READWRITE || protection == PAGE_WRITECOPY ||
            protection == PAGE_EXECUTE_READ ||
            protection == PAGE_EXECUTE_READWRITE ||
            protection == PAGE_EXECUTE_WRITECOPY;
        const bool canExecute = protection == PAGE_EXECUTE ||
            protection == PAGE_EXECUTE_READ ||
            protection == PAGE_EXECUTE_READWRITE ||
            protection == PAGE_EXECUTE_WRITECOPY;
        if ((!executable && !readable) || (executable && !canExecute)) {
            return false;
        }
        const uintptr_t base = reinterpret_cast<uintptr_t>(info.BaseAddress);
        if (base > UINTPTR_MAX - info.RegionSize) return false;
        const uintptr_t next = base + info.RegionSize;
        if (next <= cursor) return false;
        cursor = next;
    }
    return true;
#else
    // 表前缀和尾表仍在 memcpy 之前分别查询，首次 callback 校验复用已读段或继续本轮游标。
    // 集合只活在此次 Resolve 调用中；任何失败都拒绝解引用，下一次调用重新实读。
    if (mappingSnapshot) return mappingSnapshot->LoadFile("/proc/self/maps") && mappingSnapshot->Contains(address, size, executable);
#ifdef AMCL_INPUT_DESCRIPTOR_MAPS_TESTING
    // Publish 的原逐范围入口仍逐次读取；仅宿主把 procfs 来源替换为同语义文本边界。
    amcl::input::detail::MappedRangeSnapshot standalone;
    return standalone.LoadFile("/proc/self/maps") && standalone.Contains(address, size, executable);
#else
    const uintptr_t limit = address + size;
    // Descriptor text is an in-process deployment bridge, not a trust
    // boundary. Still, never dereference an arbitrary nonzero address: prove
    // the complete table/callback lies in a readable/executable mapping.
    // This check is only a precondition; safety still depends on the publisher
    // keeping its immutable table and callback DSO pinned for process lifetime.
    FILE* maps = std::fopen("/proc/self/maps", "r");
    if (!maps) return false;
    char line[2048]{};
    bool accepted = false;
    while (std::fgets(line, sizeof(line), maps)) {
        unsigned long long begin = 0u;
        unsigned long long end = 0u;
        char permissions[5]{};
        if (std::sscanf(line, "%llx-%llx %4s", &begin, &end,
                        permissions) != 3) {
            continue;
        }
        if (address >= begin && limit <= end && permissions[0] == 'r' &&
            (!executable || permissions[2] == 'x')) {
            accepted = true;
            break;
        }
    }
    std::fclose(maps);
    return accepted;
#endif
#endif
}

template <typename Function>
uintptr_t FunctionAddress(Function function) {
    static_assert(sizeof(Function) <= sizeof(uintptr_t),
                  "function pointer must fit descriptor address validation");
    uintptr_t address = 0u;
    std::memcpy(&address, &function, sizeof(function));
    return address;
}

/** 首次/表变化后的完整 callback 校验；可复用本轮映射，但不减少任何必需函数检查。 */
bool HasExecutableCallbacks(const AmclInputHostApiV1& api,
                             amcl::input::detail::MappedRangeSnapshot* maps = nullptr) {
#define AMCL_EXECUTABLE_CALLBACK(member) \
    IsMappedRange(FunctionAddress(api.member), 1u, true, maps)
    return AMCL_EXECUTABLE_CALLBACK(beginSession) &&
        AMCL_EXECUTABLE_CALLBACK(endSession) &&
        AMCL_EXECUTABLE_CALLBACK(submitEvent) &&
        AMCL_EXECUTABLE_CALLBACK(submitBatch) &&
        AMCL_EXECUTABLE_CALLBACK(submitTextPacket) &&
        AMCL_EXECUTABLE_CALLBACK(publishSurface) &&
        AMCL_EXECUTABLE_CALLBACK(publishFocus) &&
        AMCL_EXECUTABLE_CALLBACK(publishDeviceChange) &&
        AMCL_EXECUTABLE_CALLBACK(requestReset) &&
        AMCL_EXECUTABLE_CALLBACK(openConsumer) &&
        AMCL_EXECUTABLE_CALLBACK(nextEvent) &&
        AMCL_EXECUTABLE_CALLBACK(readPacketBlob) &&
        AMCL_EXECUTABLE_CALLBACK(releasePacket) &&
        AMCL_EXECUTABLE_CALLBACK(closeConsumer) &&
        AMCL_EXECUTABLE_CALLBACK(getSnapshot) &&
        ((api.capabilityBits & AMCL_INPUT_CAP_INTERACTION_ORDER) == 0u ||
         (AMCL_EXECUTABLE_CALLBACK(nextOrderedEvent) &&
          AMCL_EXECUTABLE_CALLBACK(peekEventOrder) &&
          AMCL_EXECUTABLE_CALLBACK(interactionFence)));
#undef AMCL_EXECUTABLE_CALLBACK
}

int32_t ValidateGeneration(uint64_t generation) {
    // generation names the complete function-table ABI, not a host instance.
    // Runtime replacement is fenced by session epochs and consumer handles;
    // accepting another generation here could call unknown callback offsets.
    return generation == AMCL_INPUT_HOST_API_GENERATION
               ? AMCL_INPUT_HOST_DESCRIPTOR_OK
               : AMCL_INPUT_HOST_DESCRIPTOR_ERROR_GENERATION;
}

/** ABI/能力/代次和函数资格校验不变；可选映射仅用于一次 Resolve 内共享读取结果。 */
int32_t ValidateApi(const AmclInputHostApiV1* api,
                    uint64_t descriptorGeneration,
                    amcl::input::detail::MappedRangeSnapshot* maps = nullptr) {
    if (!api) return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_INVALID_ARGUMENT;
    if (api->magic != AMCL_INPUT_HOST_API_MAGIC ||
        api->abiVersion != AMCL_INPUT_HOST_API_VERSION ||
        api->structSize < AMCL_INPUT_HOST_API_V1_PREFIX_SIZE) {
        // A larger table is forward-compatible, but the complete V1 prefix is
        // mandatory: consumers must never read callbacks beyond structSize.
        return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ABI_MISMATCH;
    }
    if ((api->capabilityBits & AMCL_INPUT_HOST_REQUIRED_CAPABILITIES_V1) !=
        AMCL_INPUT_HOST_REQUIRED_CAPABILITIES_V1) {
        return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_CAPABILITIES;
    }
    // Legacy/shadow hosts do not need the GLFW ready protocol. Once a host
    // selects the typed physical source plane, however, accepting the route bit
    // without the barrier bit would recreate the startup/reconnect event-loss
    // window this handshake exists to close.
    if ((api->capabilityBits & AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE) != 0u &&
        (api->capabilityBits & AMCL_INPUT_CAP_BACKEND_CONSUMER_READY) == 0u) {
        return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_CAPABILITIES;
    }
    if (ValidateGeneration(api->generation) !=
            AMCL_INPUT_HOST_DESCRIPTOR_OK ||
        api->generation != descriptorGeneration) {
        // The text and copied table must describe the same complete ABI layout.
        // This is format consistency, not a host-instance/update nonce; runtime
        // rollover is fenced by session epochs, handles and table identity.
        return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_GENERATION;
    }
    if (!api->beginSession || !api->endSession || !api->submitEvent ||
        !api->submitBatch || !api->submitTextPacket || !api->publishSurface ||
        !api->publishFocus || !api->publishDeviceChange ||
        !api->requestReset || !api->openConsumer || !api->nextEvent ||
        !api->readPacketBlob || !api->releasePacket || !api->closeConsumer ||
        !api->getSnapshot) {
        // Partial activation would make behavior depend on which callback was
        // reached first. Fail the handshake atomically and retry later instead.
        return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_INCOMPLETE;
    }
    // 宣告能力却未提供完整尾表属于协议错误，不能静默退回无序消费。
    if ((api->capabilityBits & AMCL_INPUT_CAP_INTERACTION_ORDER) != 0u &&
        !amclInputHasInteractionOrder(api)) {
        return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_INCOMPLETE;
    }
    if (!HasExecutableCallbacks(*api, maps)) {
        // Non-null is insufficient for a table reconstructed from text. Reject
        // data/guard/unmapped callback addresses before any adapter can call
        // them; a later valid publication remains recoverable.
        return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_UNSAFE_POINTER;
    }
    return AMCL_INPUT_HOST_DESCRIPTOR_OK;
}

#ifndef _WIN32
int32_t TruncateDescriptorFile(int fd, int64_t size) {
    int result = -1;
    do {
        result = ftruncate(fd, static_cast<off_t>(size));
    } while (result != 0 && errno == EINTR);
    return result == 0 ? AMCL_INPUT_HOST_DESCRIPTOR_OK
                       : AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ENVIRONMENT;
}
#endif

// Windows process-environment APIs copy into caller storage, so unrelated
// environment updates cannot invalidate a borrowed pointer. POSIX instead uses
// the already-locked file itself as descriptor storage: libc exposes no portable
// way to copy getenv data atomically against setenv calls made by other systems.
// Holding one flock across fstat/pread or truncate/pwrite makes text publication
// linearizable across DSO-private helper copies without a second lock identity.
int32_t ReadDescriptorTransport(const ProcessDescriptorLock& lock,
                                char* out, size_t capacity) {
    if (!out || capacity == 0u) {
        return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_INVALID_ARGUMENT;
    }
    out[0] = '\0';
#ifdef _WIN32
    (void)lock;
    SetLastError(ERROR_SUCCESS);
    const DWORD length = GetEnvironmentVariableA(
        AMCL_INPUT_HOST_DESCRIPTOR_ENV, out, static_cast<DWORD>(capacity));
    if (length == 0u) {
        const DWORD error = GetLastError();
        return error == ERROR_SUCCESS || error == ERROR_ENVVAR_NOT_FOUND
                   ? AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MISSING
                   : AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ENVIRONMENT;
    }
    return length < capacity
               ? AMCL_INPUT_HOST_DESCRIPTOR_OK
               : AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MALFORMED;
#else
    const int fd = lock.descriptorFd();
    if (fd < 0) return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_SYNCHRONIZATION;
    struct stat info {};
    int statResult = -1;
    do {
        statResult = fstat(fd, &info);
    } while (statResult != 0 && errno == EINTR);
    if (statResult != 0) return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ENVIRONMENT;
    if (info.st_size == 0) return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MISSING;
    if (info.st_size < 0 ||
        static_cast<uint64_t>(info.st_size) >= capacity) {
        return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MALFORMED;
    }
    const size_t expected = static_cast<size_t>(info.st_size);
    size_t total = 0u;
    while (total < expected) {
        const ssize_t count = pread(fd, out + total, expected - total,
                                    static_cast<off_t>(total));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ENVIRONMENT;
        total += static_cast<size_t>(count);
    }
    out[total] = '\0';
    return AMCL_INPUT_HOST_DESCRIPTOR_OK;
#endif
}

int32_t SetDescriptorTransport(const ProcessDescriptorLock& lock,
                               const char* value) {
    if (!value) return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_INVALID_ARGUMENT;
#ifdef _WIN32
    (void)lock;
    return SetEnvironmentVariableA(AMCL_INPUT_HOST_DESCRIPTOR_ENV, value) != FALSE
               ? AMCL_INPUT_HOST_DESCRIPTOR_OK
               : AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ENVIRONMENT;
#else
    const int fd = lock.descriptorFd();
    if (fd < 0) return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_SYNCHRONIZATION;
    const size_t length = std::strlen(value);
    int32_t result = TruncateDescriptorFile(fd, 0);
    if (result != AMCL_INPUT_HOST_DESCRIPTOR_OK) return result;
    size_t total = 0u;
    while (total < length) {
        const ssize_t count = pwrite(fd, value + total, length - total,
                                     static_cast<off_t>(total));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            (void)TruncateDescriptorFile(fd, 0);
            return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ENVIRONMENT;
        }
        total += static_cast<size_t>(count);
    }
    return AMCL_INPUT_HOST_DESCRIPTOR_OK;
#endif
}

int32_t ClearDescriptorTransport(const ProcessDescriptorLock& lock) {
#ifdef _WIN32
    (void)lock;
    if (SetEnvironmentVariableA(AMCL_INPUT_HOST_DESCRIPTOR_ENV, nullptr) != FALSE) {
        return AMCL_INPUT_HOST_DESCRIPTOR_OK;
    }
    return GetLastError() == ERROR_ENVVAR_NOT_FOUND
               ? AMCL_INPUT_HOST_DESCRIPTOR_OK
               : AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ENVIRONMENT;
#else
    const int fd = lock.descriptorFd();
    return fd >= 0 ? TruncateDescriptorFile(fd, 0)
                   : AMCL_INPUT_HOST_DESCRIPTOR_ERROR_SYNCHRONIZATION;
#endif
}

// Caller owns ProcessDescriptorLock. Keeping parsing separate prevents Publish
// from recursively acquiring a non-recursive POSIX flock while it atomically
// performs resolve-or-claim.
// 原 callback memo 仍以完整 descriptor 和逐字节相同的表为键；表变更重新核验全部函数。
// 本轮 maps 集合仅在 ResolveUnlocked 栈内共享 prefix/tail/callback 范围检查，退出即释放。
// 每次 Resolve 仍实读映射且先证明表可读再 memcpy，不跨调用缓存映射、缺失或错误。
struct ValidatedDescriptor {
    bool valid = false;
    char text[kDescriptorLength + 1u]{};
    AmclInputHostApiV1 snapshot{};
    const AmclInputHostApiV1* api = nullptr;
};
ValidatedDescriptor g_validatedDescriptor;  // guarded by ProcessDescriptorLock

int32_t ResolveUnlocked(const ProcessDescriptorLock& lock,
                        const AmclInputHostApiV1** outApi) {
    if (!outApi) return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_INVALID_ARGUMENT;
    *outApi = nullptr;

    // Do not cache misses or invalid text: the XComponent-owning host may load
    // later. A valid owner remains pinned; runtime state rollover is represented
    // by session epochs/consumer handles, not by changing ABI generation.
    char descriptor[kDescriptorLength + 2u]{};
    const int32_t transportResult =
        ReadDescriptorTransport(lock, descriptor, sizeof(descriptor));
    if (transportResult != AMCL_INPUT_HOST_DESCRIPTOR_OK) {
        return transportResult;
    }
    if (std::strlen(descriptor) != kDescriptorLength ||
        std::memcmp(descriptor, kPrefix, sizeof(kPrefix) - 1u) != 0) {
        return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MALFORMED;
    }

    const char* cursor = descriptor + sizeof(kPrefix) - 1u;
    uint64_t descriptorGeneration = 0u;
    if (!DecodeHex(cursor, kGenerationHexDigits, &descriptorGeneration) ||
        cursor[kGenerationHexDigits] != ':') {
        return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MALFORMED;
    }
    if (ValidateGeneration(descriptorGeneration) !=
        AMCL_INPUT_HOST_DESCRIPTOR_OK) {
        return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_GENERATION;
    }

    uint64_t encodedAddress = 0u;
    cursor += kGenerationHexDigits + 1u;
    if (!DecodeHex(cursor, kPointerHexDigits, &encodedAddress) ||
        encodedAddress == 0u || encodedAddress > UINTPTR_MAX) {
        return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MALFORMED;
    }

    const uintptr_t address = static_cast<uintptr_t>(encodedAddress);
    amcl::input::detail::MappedRangeSnapshot mappedRanges;
    if (address % alignof(AmclInputHostApiV1) != 0u ||
        !IsMappedRange(address, AMCL_INPUT_HOST_API_V1_PREFIX_SIZE, false, &mappedRanges)) {
        return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_UNSAFE_POINTER;
    }

    // Validate a local snapshot only after proving the complete source range is
    // readable. The original pointer is returned because callbacks borrow the
    // immutable process-lifetime table. Mapping checks do not replace that pin:
    // violating the owner contract would reopen an unload/mutation TOCTOU.
    AmclInputHostApiV1 snapshot{};
    std::memcpy(&snapshot, reinterpret_cast<const void*>(address),
                AMCL_INPUT_HOST_API_V1_PREFIX_SIZE);
    // 先证明前缀可读，再根据长度与能力证明尾表映射，不能提前越界 memcpy 旧宿主。
    if ((snapshot.capabilityBits & AMCL_INPUT_CAP_INTERACTION_ORDER) != 0u) {
        if (snapshot.structSize < sizeof(snapshot) ||
            !IsMappedRange(address, sizeof(snapshot), false, &mappedRanges)) {
            return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ABI_MISMATCH;
        }
        std::memcpy(&snapshot, reinterpret_cast<const void*>(address), sizeof(snapshot));
    }
    if (g_validatedDescriptor.valid &&
        std::strcmp(descriptor, g_validatedDescriptor.text) == 0 &&
        std::memcmp(&snapshot, &g_validatedDescriptor.snapshot,
                    sizeof(snapshot)) == 0) {
        // Same descriptor text and byte-identical table: the previous callback
        // mapping proof still applies, so skip the per-callback maps walks.
        *outApi = g_validatedDescriptor.api;
        return AMCL_INPUT_HOST_DESCRIPTOR_OK;
    }
    const int32_t validation = ValidateApi(&snapshot, descriptorGeneration, &mappedRanges);
    if (validation != AMCL_INPUT_HOST_DESCRIPTOR_OK) return validation;
    g_validatedDescriptor.valid = true;
    std::memcpy(g_validatedDescriptor.text, descriptor, kDescriptorLength + 1u);
    g_validatedDescriptor.snapshot = snapshot;
    g_validatedDescriptor.api =
        reinterpret_cast<const AmclInputHostApiV1*>(address);
    *outApi = g_validatedDescriptor.api;
    return AMCL_INPUT_HOST_DESCRIPTOR_OK;
}

}  // namespace

extern "C" int32_t amclInputHostDescriptorPublishV1(
    const AmclInputHostApiV1* api) {
    if (!api) return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_INVALID_ARGUMENT;
    const int32_t validation = ValidateApi(api, api->generation);
    if (validation != AMCL_INPUT_HOST_DESCRIPTOR_OK) return validation;

    char descriptor[kDescriptorLength + 1u]{};
    const int written = std::snprintf(
        descriptor, sizeof(descriptor), "%s%016llx:%0*llx", kPrefix,
        static_cast<unsigned long long>(api->generation),
        static_cast<int>(kPointerHexDigits),
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(api)));
    if (written != static_cast<int>(kDescriptorLength)) {
        return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ENVIRONMENT;
    }

    ProcessDescriptorLock lock;
    if (!lock.acquired()) {
        return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_SYNCHRONIZATION;
    }

    // Resolve and claim are one cross-DSO transaction. A duplicate image may
    // expose an equally shaped private core, but only the first valid table may
    // own producers; later distinct tables fail explicitly instead of splitting
    // DOWN and UP across two InputStateCore instances.
    const AmclInputHostApiV1* existing = nullptr;
    const int32_t existingResult = ResolveUnlocked(lock, &existing);
    if (existingResult == AMCL_INPUT_HOST_DESCRIPTOR_OK) {
        return existing == api ? AMCL_INPUT_HOST_DESCRIPTOR_OK
                               : AMCL_INPUT_HOST_DESCRIPTOR_ERROR_OWNER_CONFLICT;
    }
    if (existingResult == AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ENVIRONMENT) {
        return existingResult;
    }
    return SetDescriptorTransport(lock, descriptor);
}

extern "C" int32_t amclInputHostDescriptorResolveV1(
    const AmclInputHostApiV1** outApi) {
    if (!outApi) return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_INVALID_ARGUMENT;
    *outApi = nullptr;
    ProcessDescriptorLock lock;
    if (!lock.acquired()) {
        return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_SYNCHRONIZATION;
    }
    return ResolveUnlocked(lock, outApi);
}

extern "C" int32_t amclInputHostDescriptorClearV1(void) {
    ProcessDescriptorLock lock;
    if (!lock.acquired()) {
        return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_SYNCHRONIZATION;
    }
    // This only serializes test/quiescent teardown. It cannot revoke a pointer
    // already borrowed by a live consumer and therefore never authorizes unload.
    return ClearDescriptorTransport(lock);
}

#ifdef AMCL_INPUT_HOST_TESTING
extern "C" int32_t amclInputHostDescriptorTestSetRawV1(
        const char* value) {
    if (!value) return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_INVALID_ARGUMENT;
    ProcessDescriptorLock lock;
    if (!lock.acquired()) {
        return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_SYNCHRONIZATION;
    }
    return SetDescriptorTransport(lock, value);
}
#endif
