// env_slot.h — 进程环境变量的“静态槽位”：线程出现前登记名字，之后只原位改值（I27-05）。
//
// 为什么需要它：musl 的 setenv 每次都 malloc 新的 "NAME=value"，替换 environ 槽位后
// free 旧串；新名字还会 realloc 整个 environ 数组；unsetenv 原地压缩数组。getenv 读
// 任何名字都要遍历 environ，所以只要游戏/渲染线程还在读（GLFW 各检查点读重启标记、
// JVM/libc 内部读 TZ 等），任何线程上的 setenv/unsetenv 都可能让读者碰到已释放内存。
//
// 本头提供的规则（其余调用点由 scripts/check-env-mutation.mjs 静态约束）：
//   1. 名字只在第一个 AMCL 游戏/JVM 线程出现之前登记：putenv 一块进程期静态、可写、定长
//      的 "NAME=VALUE\0" 缓冲区。POSIX putenv 只保存指针，不复制也不释放。
//   2. Seal() 之后（mc_launcher 在 JNI_CreateJavaVM 之前调用）拒绝新增名字，只返回错误码，
//      绝不退回到晚到的 setenv；已登记名字的重复登记仍幂等成功。
//   3. 之后的更新只在原缓冲区内改字节：名字部分永不变化，遍历 environ 找其他名字的读者
//      不受影响；数组既不增长也不压缩；没有任何字符串被释放。
//   4. 布尔值只用单字节 '0'/'1'；十进制用定宽零填充，长度永不变化；文本槽位只给“同一线程
//      先写后读”或另有 happens-before 的读者使用（写法见 Registry::WriteLocked）。
//   5. 其他 DSO / linker namespace 的写者经 AMCL_ENV_SLOT_REGISTRY_V1 找到 owner 映像的
//      只读函数表，由 owner 在同一把锁下原位写入；找不到登记表或槽位已被别人 setenv
//      替换时返回负状态，调用方负责大声记录，同样不 setenv。
//
// 仍然存在、不是本头能消除的边界：
//   - 与第三方纯读者之间仍是形式上的数据竞争。单字节写在 aarch64/x86 上单拷贝原子；
//     多字节十进制可能被并发读者读到新旧混合的数字，所以十进制槽位只适合参考值。
//   - 预编译 SDL（补丁 0022 起）在 C 侧按本头的 WireV1 布局解析登记表并调用 store 写重启
//     标记，自己不再 setenv；但任何第三方 setenv 同名变量仍会把槽位“摘走”（environ 改指向
//     它 malloc 的串），之后原位写入对该名字返回 kDetached，调用方必须记录。
//   - Windows CRT 会复制 putenv 的串，无法原位；该后端退化为每次重新 _putenv，只服务
//     功能等价的宿主回归，不代表 OHOS 语义。POSIX 语义由 tests/host/env_slot_test.cpp 在
//     可注入的“musl 式”environ 与真实进程 environ 上分别验证。
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#ifdef _WIN32
#include <process.h>
#else
#include <unistd.h>
#endif

// 进程单例与跨映像缓存必须“每个 DSO 一份”：默认可见性的 inline 函数局部静态量可能被
// 动态链接器跨 DSO 合并成同一个对象，让非 owner 映像误用 owner 的内部状态。
#if defined(__GNUC__) || defined(__clang__)
#define AMCL_ENV_SLOT_HIDDEN __attribute__((visibility("hidden")))
#else
#define AMCL_ENV_SLOT_HIDDEN
#endif

namespace amcl::envslot {

// ---- 线协议：跨 DSO 共享，只追加字段，不重排 ----
// 预编译 SDL 的 C 侧镜像（补丁 0022）按同一字节布局解析；改动这里的任何字段都要同步重建 SDL。
inline constexpr char kRegistryEnv[] = "AMCL_ENV_SLOT_REGISTRY_V1";
inline constexpr uint64_t kWireMagic = 0x31564E454C434D41ULL;  // 小端字节序 "AMCLENV1"
inline constexpr uint32_t kWireAbi = 1u;

// ---- 已知槽位名：登记方与写者共用同一拼写，门禁据此核对唯一发布点 ----
// 窗口前台位、窗口尺寸与光标模式占位已随 SDL 0022 / LWJGL2 重建退役：前台位与尺寸改由窗口
// 宿主 broker/快照提供，打包的原生库里不再有它们的读者或写者（门禁 RETIRED_NAMES 禁止复活）。
inline constexpr char kRendererRestartEnv[] = "AMCL_RENDERER_REQUIRES_PROCESS_RESTART";
inline constexpr char kSdlHostRuntimeEnv[] = "AMCL_SDL_HOST_RUNTIME";

// 十进制槽位固定 10 位，覆盖 int32 正值全域；按 atoi/strtol 读取时前导零不改变数值。
// 当前没有产品槽位使用十进制形状，保留它是为了登记表的通用契约与宿主回归。
inline constexpr uint32_t kDecimalWidth = 10u;
inline constexpr uint32_t kMaxSlots = 8u;
inline constexpr uint32_t kEntryBytes = 176u;  // 整个 "NAME=VALUE\0" 静态缓冲区

enum class Kind : uint32_t { kBoolean = 1u, kDecimal = 2u, kText = 3u };

// 非负表示已达到期望状态；负值都是“没有写入”，调用方必须按原因记录。
enum Status : int {
    kOk = 0,               // 值有变化并已原位写入
    kUnchanged = 1,        // 当前值已是期望值，未写
    kSealed = -1,          // 已封存，拒绝新增名字
    kFull = -2,            // 槽位表已满
    kInvalidArgument = -3, // 名字/值不合法或超出容量
    kConflict = -4,        // 同名已按不同形状登记，或本进程已有另一个 owner 登记表
    kUnavailable = -5,     // 进程中没有可用登记表（跨映像写者）
    kDetached = -6,        // environ 已不再指向本槽位（被第三方 setenv/unsetenv 替换）
    kWrongProcess = -7,    // fork 子进程继承到父进程的登记表
    kUnregistered = -8,    // 名字从未登记
    kPutenvFailed = -9,    // 系统 putenv 失败或登记后回读不一致
};

// owner 映像发布给其他映像的只读表。store 在 owner 映像内执行，取得 owner 的锁。
struct WireV1 {
    uint64_t magic;
    uint32_t abi;
    uint32_t structSize;
    uint64_t pid;
    const WireV1* self;
    int (*store)(const char* name, const char* value);
};

// 环境原语。POSIX 后端 put 必须是“保存指针”的 putenv 语义；inPlace=false 的后端
// （Windows CRT）每次写入后需要重新 put 整条 entry。
struct Backend {
    int (*put)(char* entry);
    const char* (*get)(const char* name);
    uint64_t (*pid)();
    bool inPlace;
};

inline uint64_t SystemPid() {
#ifdef _WIN32
    return static_cast<uint64_t>(_getpid());
#else
    return static_cast<uint64_t>(getpid());
#endif
}

inline int SystemPut(char* entry) {
#ifdef _WIN32
    return _putenv(entry);
#else
    return ::putenv(entry);
#endif
}

inline const char* SystemGet(const char* name) { return std::getenv(name); }

inline Backend SystemBackend() {
#ifdef _WIN32
    return Backend{SystemPut, SystemGet, SystemPid, false};
#else
    return Backend{SystemPut, SystemGet, SystemPid, true};
#endif
}

// 解析 "<十进制 pid>:<十六进制地址>" 并校验对端表。任何失败都返回 nullptr，调用方不缓存失败。
// 地址来自本进程第一方代码写入的环境描述符，信任模型与窗口宿主 owner 描述符相同。
inline const WireV1* ParseWire(const char* text, uint64_t currentPid, int* status) {
    if (status) *status = kUnavailable;
    if (!text || !*text) return nullptr;
    char* end = nullptr;
    const unsigned long long pid = std::strtoull(text, &end, 10);
    if (end == text || !end || *end != ':') { if (status) *status = kConflict; return nullptr; }
    const char* addressText = end + 1;
    char* addressEnd = nullptr;
    const unsigned long long address = std::strtoull(addressText, &addressEnd, 16);
    if (addressEnd == addressText || !addressEnd || *addressEnd || address == 0ULL) {
        if (status) *status = kConflict;
        return nullptr;
    }
    if (pid != currentPid) { if (status) *status = kWrongProcess; return nullptr; }
    const auto* wire = reinterpret_cast<const WireV1*>(static_cast<uintptr_t>(address));
    if (wire->magic != kWireMagic || wire->abi != kWireAbi || wire->structSize < sizeof(WireV1) ||
        wire->pid != currentPid || wire->self != wire || !wire->store) {
        if (status) *status = kConflict;
        return nullptr;
    }
    if (status) *status = kOk;
    return wire;
}

// 登记表 owner：只应在 libentry（mc_launcher/xcomponent/jni_registry 所在映像）通过
// ProcessRegistry() 使用。测试可用自带后端与 store 跳板构造独立实例。
// 线程约束：Register 只应在线程出现前调用（Seal 负责把越界调用变成错误）；
// Store 可在任意线程调用，由 mutex_ 串行化同一登记表的所有写入。
class Registry {
public:
    using StoreThunk = int (*)(const char* name, const char* value);

    Registry(const Backend& backend, StoreThunk thunk) : backend_(backend) {
        wire_.magic = kWireMagic;
        wire_.abi = kWireAbi;
        wire_.structSize = static_cast<uint32_t>(sizeof(WireV1));
        wire_.pid = backend_.pid();
        wire_.self = &wire_;
        wire_.store = thunk;
    }
    Registry(const Registry&) = delete;
    Registry& operator=(const Registry&) = delete;

    // 登记（或确认已登记）一个名字。capacity 是值部分最大字节数（不含 NUL）：布尔必须为 1，
    // 十进制为定宽位数，文本为上限。initial 按同一规则校验；十进制会左侧补 '0'。
    // 已有同形状槽位且仍挂在 environ 上时直接返回 kOk（即使已封存），不改变当前值。
    int Register(const char* name, Kind kind, uint32_t capacity, const char* initial) {
        std::lock_guard<std::mutex> lock(mutex_);
        const size_t nameLength = ValidName(name);
        if (!nameLength || !ValidShape(kind, capacity) || nameLength + 1u + capacity + 1u > kEntryBytes) {
            return kInvalidArgument;
        }
        char normalized[kEntryBytes];
        if (!Normalize(kind, capacity, initial ? initial : "", normalized, sizeof(normalized))) {
            return kInvalidArgument;
        }
        if (Slot* existing = FindLocked(name)) {
            if (existing->kind != kind || existing->capacity != capacity) return kConflict;
            return AttachedLocked(*existing) ? kOk : kDetached;
        }
        if (sealed_.load(std::memory_order_acquire)) return kSealed;
        if (count_ >= kMaxSlots) return kFull;
        const int wireStatus = PublishWireLocked();
        if (wireStatus < 0) return wireStatus;
        Slot& slot = slots_[count_];
        std::memset(slot.entry, 0, sizeof(slot.entry));
        std::memcpy(slot.entry, name, nameLength);
        slot.entry[nameLength] = '=';
        slot.value = slot.entry + nameLength + 1u;
        std::memcpy(slot.value, normalized, std::strlen(normalized));
        slot.name = slot.entry;     // 名字取自本缓冲区前缀，登记后永不改写
        slot.nameLength = nameLength;
        slot.kind = kind;
        slot.capacity = capacity;
        if (backend_.put(slot.entry) != 0 || !AttachedLocked(slot)) return kPutenvFailed;
        ++count_;
        return kOk;
    }

    // 原位写入已登记名字。value 规则同 Register；与当前值相同时返回 kUnchanged 且不写。
    int Store(const char* name, const char* value) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (backend_.pid() != wire_.pid) return kWrongProcess;
        Slot* slot = FindLocked(name);
        if (!slot) return kUnregistered;
        char normalized[kEntryBytes];
        if (!value || !Normalize(slot->kind, slot->capacity, value, normalized, sizeof(normalized))) {
            return kInvalidArgument;
        }
        if (!AttachedLocked(*slot)) return kDetached;
        if (std::strcmp(slot->value, normalized) == 0) return kUnchanged;
        WriteLocked(*slot, normalized);
        if (!backend_.inPlace && backend_.put(slot->entry) != 0) return kPutenvFailed;
        stores_.fetch_add(1u, std::memory_order_relaxed);
        return kOk;
    }

    // 十进制便捷入口：负数按 0 处理（尺寸“未知”），超宽数字拒绝。
    int StoreDecimal(const char* name, long long value) {
        char text[32];
        std::snprintf(text, sizeof(text), "%lld", value < 0 ? 0LL : value);
        return Store(name, text);
    }

    // 封存后只拒绝新增名字；已有槽位的原位写入不受影响。封存不可撤销。
    void Seal() { sealed_.store(true, std::memory_order_release); }
    bool Sealed() const { return sealed_.load(std::memory_order_acquire); }

    // 诊断/测试：返回登记缓冲区内的当前值（未登记为 nullptr）。与写者并发读取时只作参考。
    const char* Value(const char* name) {
        std::lock_guard<std::mutex> lock(mutex_);
        const Slot* slot = FindLocked(name);
        return slot ? slot->value : nullptr;
    }
    bool Attached(const char* name) {
        std::lock_guard<std::mutex> lock(mutex_);
        const Slot* slot = FindLocked(name);
        return slot && AttachedLocked(*slot);
    }
    uint32_t Count() {
        std::lock_guard<std::mutex> lock(mutex_);
        return count_;
    }
    uint64_t Stores() const { return stores_.load(std::memory_order_relaxed); }
    const WireV1* Wire() const { return &wire_; }

private:
    struct Slot {
        const char* name = nullptr;
        size_t nameLength = 0;
        Kind kind = Kind::kBoolean;
        uint32_t capacity = 0;
        char* value = nullptr;
        char entry[kEntryBytes] = {};
    };

    static size_t ValidName(const char* name) {
        if (!name || !*name) return 0;
        const size_t length = std::strlen(name);
        return std::strchr(name, '=') ? 0 : length;
    }
    static bool ValidShape(Kind kind, uint32_t capacity) {
        switch (kind) {
            case Kind::kBoolean: return capacity == 1u;
            case Kind::kDecimal: return capacity >= 1u && capacity <= 19u;
            case Kind::kText: return capacity >= 1u;
        }
        return false;
    }
    // 把输入规范化成槽位里的最终字节：布尔只接受 "0"/"1"；十进制只接受数字并左补 '0'；
    // 文本不得超过容量。out 至少 capacity+1 字节。
    static bool Normalize(Kind kind, uint32_t capacity, const char* value, char* out, size_t outSize) {
        const size_t length = std::strlen(value);
        if (outSize <= capacity) return false;
        if (kind == Kind::kBoolean) {
            if (length != 1u || (value[0] != '0' && value[0] != '1')) return false;
            out[0] = value[0];
            out[1] = '\0';
            return true;
        }
        if (kind == Kind::kDecimal) {
            if (!length || length > capacity) return false;
            for (size_t i = 0; i < length; ++i) if (value[i] < '0' || value[i] > '9') return false;
            const size_t pad = capacity - length;
            std::memset(out, '0', pad);
            std::memcpy(out + pad, value, length);
            out[capacity] = '\0';
            return true;
        }
        if (length > capacity) return false;
        std::memcpy(out, value, length);
        out[length] = '\0';
        return true;
    }
    Slot* FindLocked(const char* name) {
        if (!name) return nullptr;
        for (uint32_t i = 0; i < count_; ++i) {
            if (slots_[i].nameLength == std::strlen(name) &&
                std::strncmp(slots_[i].name, name, slots_[i].nameLength) == 0) return &slots_[i];
        }
        return nullptr;
    }
    // POSIX：environ 必须仍指向本缓冲区；复制型后端只能比较值（Windows 下空值即删除）。
    bool AttachedLocked(const Slot& slot) const {
        char name[kEntryBytes];
        std::memcpy(name, slot.entry, slot.nameLength);
        name[slot.nameLength] = '\0';
        const char* live = backend_.get(name);
        if (backend_.inPlace) return live == slot.value;
        return std::strcmp(live ? live : "", slot.value) == 0;
    }
    // 定长类型逐字节覆盖（长度不变，NUL 位置不动）。文本先把首字节清成 NUL，再写尾部与新 NUL，
    // 最后写首字节：写入开始后才读的读者只会看到空串或新串；已读过首字节的并发读者仍可能读到
    // 新旧拼接，所以文本槽位只给与写者有 happens-before 的读者（见文件头规则 4）。
    void WriteLocked(Slot& slot, const char* normalized) {
        volatile char* target = slot.value;
        const size_t length = std::strlen(normalized);
        if (slot.kind != Kind::kText) {
            for (size_t i = 0; i < length; ++i) target[i] = normalized[i];
        } else if (length == 0) {
            target[0] = '\0';
        } else {
            target[0] = '\0';
            std::atomic_thread_fence(std::memory_order_release);
            for (size_t i = 1; i < length; ++i) target[i] = normalized[i];
            target[length] = '\0';
            std::atomic_thread_fence(std::memory_order_release);
            target[0] = normalized[0];
        }
        std::atomic_thread_fence(std::memory_order_release);
    }
    // 首个槽位登记前发布本表：本进程已有另一 owner 的有效登记表时拒绝（kConflict），
    // 继承自父进程或畸形的旧描述符在封存前直接覆盖（putenv 同名替换，不扩容数组）。
    int PublishWireLocked() {
        if (wirePublished_) return kOk;
        int status = kUnavailable;
        const WireV1* existing = ParseWire(backend_.get(kRegistryEnv), wire_.pid, &status);
        if (existing && existing != &wire_) return kConflict;
        std::snprintf(wireEntry_, sizeof(wireEntry_), "%s=%llu:%llx", kRegistryEnv,
            static_cast<unsigned long long>(wire_.pid),
            static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(&wire_)));
        std::atomic_thread_fence(std::memory_order_release);
        if (backend_.put(wireEntry_) != 0) return kPutenvFailed;
        wirePublished_ = true;
        return kOk;
    }

    Backend backend_;
    std::mutex mutex_;
    std::atomic<bool> sealed_{false};
    std::atomic<uint64_t> stores_{0};
    uint32_t count_ = 0;
    Slot slots_[kMaxSlots];
    WireV1 wire_{};
    bool wirePublished_ = false;
    char wireEntry_[96] = {};
};

AMCL_ENV_SLOT_HIDDEN inline int ProcessStoreThunk(const char* name, const char* value);

// 本 DSO 的进程级登记表。只在 libentry 使用；对象故意泄漏，进程退出时 environ 仍指向其
// 缓冲区，析构会留下悬空 entry。fork 子进程继承的实例 pid 不符，写入返回 kWrongProcess。
AMCL_ENV_SLOT_HIDDEN inline Registry& ProcessRegistry() {
    static Registry* registry = new Registry(SystemBackend(), &ProcessStoreThunk);
    return *registry;
}

AMCL_ENV_SLOT_HIDDEN inline int ProcessStoreThunk(const char* name, const char* value) {
    return ProcessRegistry().Store(name, value);
}

// 任意映像的写者入口：解析已发布的登记表并委托 owner 原位写入。成功解析按 PID 缓存；
// 失败不缓存，登记表稍后出现时下一次调用即可生效。
AMCL_ENV_SLOT_HIDDEN inline int StorePublished(const char* name, const char* value) {
    static std::atomic<const WireV1*> cached{nullptr};
    const uint64_t pid = SystemPid();
    const WireV1* wire = cached.load(std::memory_order_acquire);
    if (!wire || wire->pid != pid) {
        int status = kUnavailable;
        wire = ParseWire(std::getenv(kRegistryEnv), pid, &status);
        if (!wire) return status;
        cached.store(wire, std::memory_order_release);
    }
    return wire->store(name, value);
}

// 进程级“需要重启”标记（只会从 0 变 1）。若第三方写者已把槽位摘走且值为 "1"，视为已满足；
// 其余失败原样返回，调用方记录后仍按本地终局处理，不 setenv。SDL 的 C 侧实现遵循同一规则。
AMCL_ENV_SLOT_HIDDEN inline int RequestRendererRestart() {
    const int status = StorePublished(kRendererRestartEnv, "1");
    if (status >= 0) return status;
    const char* current = std::getenv(kRendererRestartEnv);
    return current && std::strcmp(current, "1") == 0 ? static_cast<int>(kUnchanged) : status;
}

}  // namespace amcl::envslot
