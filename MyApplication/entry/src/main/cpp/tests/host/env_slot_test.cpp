// env_slot_test.cpp — platform/env_slot.h 的宿主回归（I27-05）。
//
// 分两层：
//   1. 可注入后端：用一个“musl 式”假 environ 模拟 putenv 只存指针、第三方 setenv 换指针、
//      unsetenv 删槽位的语义，逐条钉住登记/封存/原位写/摘走/跨进程/登记表协议。这一层在
//      任何宿主（含 MSVC）上都是真实 POSIX 语义的模型，不依赖本机 CRT。
//   2. 真实进程 environ：POSIX 上验证 getenv 返回的就是槽位缓冲区、原位写后指针不变、
//      environ 条目数不变、第三方 setenv 后返回 kDetached，以及 fork 子进程写入被拒；
//      Windows CRT 会复制 putenv 的串，只验证功能等价（值可见、摘走可测）。
// 负对照：每条“拒绝”都同时断言值没有被改写，避免“返回了错误码但其实已经写进去”的假通过。
#include "../../platform/env_slot.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>
#ifndef _WIN32
#include <sys/wait.h>
#include <unistd.h>
extern char** environ;
#endif

using namespace amcl::envslot;

namespace {

int failures = 0;

void check(bool value, const char* message) {
    if (!value) {
        ++failures;
        std::fprintf(stderr, "FAIL: %s\n", message);
    }
}

// ---- musl 式假 environ ----
// entries 保存的就是调用方给的指针（putenv 语义）；第三方 setenv 新分配一条 "NAME=value" 并替换
// 指针（旧串归调用方，这里不释放）；unsetenv 删除条目。growths 记录数组增长次数。
struct FakeEnviron {
    std::vector<char*> entries;
    std::vector<std::unique_ptr<char[]>> owned;
    uint64_t pid = 4242u;
    int putCalls = 0;
    int growths = 0;
};
FakeEnviron* g_fake = nullptr;

size_t NameLength(const char* entry) {
    const char* equals = std::strchr(entry, '=');
    return equals ? static_cast<size_t>(equals - entry) : std::strlen(entry);
}

int FindEntry(const char* name) {
    const size_t length = std::strlen(name);
    for (size_t i = 0; i < g_fake->entries.size(); ++i) {
        const char* entry = g_fake->entries[i];
        if (NameLength(entry) == length && std::strncmp(entry, name, length) == 0) {
            return static_cast<int>(i);
        }
    }
    return -1;
}

int FakePut(char* entry) {
    ++g_fake->putCalls;
    if (!std::strchr(entry, '=')) return -1;
    std::string name(entry, NameLength(entry));
    const int index = FindEntry(name.c_str());
    if (index >= 0) {
        g_fake->entries[static_cast<size_t>(index)] = entry;
    } else {
        g_fake->entries.push_back(entry);
        ++g_fake->growths;
    }
    return 0;
}

const char* FakeGet(const char* name) {
    const int index = FindEntry(name);
    return index < 0 ? nullptr : g_fake->entries[static_cast<size_t>(index)] + std::strlen(name) + 1u;
}

uint64_t FakePid() { return g_fake->pid; }

// 模拟预编译库的 setenv：新串替换槽位指针，登记表的缓冲区从此不再挂在 environ 上。
void ThirdPartySetenv(const char* name, const char* value) {
    std::string text = std::string(name) + "=" + value;
    std::unique_ptr<char[]> buffer(new char[text.size() + 1u]);
    std::memcpy(buffer.get(), text.c_str(), text.size() + 1u);
    char* raw = buffer.get();
    g_fake->owned.push_back(std::move(buffer));
    const int index = FindEntry(name);
    if (index >= 0) {
        g_fake->entries[static_cast<size_t>(index)] = raw;
    } else {
        g_fake->entries.push_back(raw);
    }
}

void ThirdPartyUnsetenv(const char* name) {
    const int index = FindEntry(name);
    if (index >= 0) g_fake->entries.erase(g_fake->entries.begin() + index);
}

Backend FakeBackend() { return Backend{FakePut, FakeGet, FakePid, true}; }

// 线协议的 store 跳板：只能是普通函数指针，所以经全局指针转发到当前被测实例。
Registry* g_wireTarget = nullptr;
int WireThunk(const char* name, const char* value) {
    return g_wireTarget ? g_wireTarget->Store(name, value) : static_cast<int>(kUnavailable);
}

bool Equal(const char* actual, const char* expected) {
    return actual && std::strcmp(actual, expected) == 0;
}

// 登记、原位写、值不变跳过、布尔校验、其他名字不受影响、数组不增长。
void BooleanAndInPlaceSemantics() {
    FakeEnviron fake;
    g_fake = &fake;
    static char other[] = "OTHER_NAME=keep";
    FakePut(other);
    const char* otherBefore = FakeGet("OTHER_NAME");
    Registry registry(FakeBackend(), WireThunk);
    check(registry.Register("AMCL_TEST_FLAG", Kind::kBoolean, 1u, "0") == kOk, "boolean register succeeds");
    const char* live = FakeGet("AMCL_TEST_FLAG");
    check(live == registry.Value("AMCL_TEST_FLAG"), "environ points at the registry buffer after register");
    check(Equal(live, "0"), "boolean initial value is published");
    const size_t entriesAfterRegister = fake.entries.size();
    const int putsAfterRegister = fake.putCalls;
    const int growthsAfterRegister = fake.growths;

    check(registry.Store("AMCL_TEST_FLAG", "1") == kOk, "boolean store succeeds");
    check(FakeGet("AMCL_TEST_FLAG") == live, "store keeps the exact environ pointer (in place)");
    check(Equal(live, "1"), "store rewrites the value byte");
    check(registry.Store("AMCL_TEST_FLAG", "1") == kUnchanged, "equal value is reported unchanged");
    check(registry.Stores() == 1u, "unchanged store does not count as a write");
    check(fake.entries.size() == entriesAfterRegister && fake.growths == growthsAfterRegister,
          "stores never grow or shrink the environ array");
    check(fake.putCalls == putsAfterRegister, "in-place backend never re-puts on store");

    check(registry.Store("AMCL_TEST_FLAG", "2") == kInvalidArgument, "boolean rejects '2'");
    check(registry.Store("AMCL_TEST_FLAG", "") == kInvalidArgument, "boolean rejects empty");
    check(registry.Store("AMCL_TEST_FLAG", "10") == kInvalidArgument, "boolean rejects multi-byte");
    check(registry.Store("AMCL_TEST_FLAG", nullptr) == kInvalidArgument, "store rejects null value");
    check(Equal(live, "1"), "rejected boolean stores leave the value untouched");
    check(FakeGet("OTHER_NAME") == otherBefore && Equal(otherBefore, "keep"),
          "unrelated environ entries keep pointer and value");
    check(registry.Store("AMCL_NOT_REGISTERED", "1") == kUnregistered, "unknown name is unregistered");
    check(FakeGet("AMCL_NOT_REGISTERED") == nullptr, "unregistered store does not create the name");
}

// 十进制定宽零填充：atoi / strtol(10) 读回原数；负数写 0；超宽和非数字拒绝且不改值。
void DecimalSemantics() {
    FakeEnviron fake;
    g_fake = &fake;
    Registry registry(FakeBackend(), WireThunk);
    check(registry.Register("AMCL_TEST_WIDTH", Kind::kDecimal, kDecimalWidth, "0") == kOk, "decimal register");
    const char* live = FakeGet("AMCL_TEST_WIDTH");
    check(Equal(live, "0000000000"), "decimal initial value is zero padded");
    check(std::atoi(live) == 0, "padded zero reads back as 0 (readers treat it as unknown)");
    check(registry.StoreDecimal("AMCL_TEST_WIDTH", 1920) == kOk, "decimal store");
    check(Equal(live, "0000001920"), "decimal value is zero padded in place");
    check(std::atoi(live) == 1920 && std::strtol(live, nullptr, 10) == 1920, "atoi/strtol read the padded value");
    check(FakeGet("AMCL_TEST_WIDTH") == live && std::strlen(live) == kDecimalWidth, "decimal length never changes");
    check(registry.StoreDecimal("AMCL_TEST_WIDTH", -5) == kOk && Equal(live, "0000000000"), "negative stores 0");
    check(registry.Store("AMCL_TEST_WIDTH", "12345678901") == kInvalidArgument, "decimal rejects over-width");
    check(registry.Store("AMCL_TEST_WIDTH", "12a") == kInvalidArgument, "decimal rejects non-digits");
    check(registry.Store("AMCL_TEST_WIDTH", "-1") == kInvalidArgument, "decimal text rejects sign");
    check(Equal(live, "0000000000"), "rejected decimal stores leave the value untouched");
    check(registry.StoreDecimal("AMCL_TEST_WIDTH", 2147483647LL) == kOk && Equal(live, "2147483647"),
          "int32 max fits the fixed width");
}

// 文本槽位：容量上限、变短/变长后 NUL 位置正确、空串可写。
void TextSemantics() {
    FakeEnviron fake;
    g_fake = &fake;
    Registry registry(FakeBackend(), WireThunk);
    check(registry.Register("AMCL_TEST_TEXT", Kind::kText, 16u, "") == kOk, "text register with empty value");
    const char* live = FakeGet("AMCL_TEST_TEXT");
    check(Equal(live, ""), "text initial empty value is visible as empty");
    check(registry.Store("AMCL_TEST_TEXT", "1:42:7:9") == kOk && Equal(live, "1:42:7:9"), "text store");
    check(registry.Store("AMCL_TEST_TEXT", "a") == kOk && Equal(live, "a"), "shorter text terminates correctly");
    check(registry.Store("AMCL_TEST_TEXT", "0123456789abcdef") == kOk && Equal(live, "0123456789abcdef"),
          "text at exact capacity");
    check(registry.Store("AMCL_TEST_TEXT", "0123456789abcdefX") == kInvalidArgument, "text over capacity rejected");
    check(Equal(live, "0123456789abcdef"), "rejected text store leaves the value untouched");
    check(registry.Store("AMCL_TEST_TEXT", "") == kOk && Equal(live, ""), "text can be cleared in place");
    check(FakeGet("AMCL_TEST_TEXT") == live, "text stores stay in place");
}

// 登记参数校验、容量表满、封存、重复登记与形状冲突。
void RegistrationRules() {
    FakeEnviron fake;
    g_fake = &fake;
    Registry registry(FakeBackend(), WireThunk);
    check(registry.Register(nullptr, Kind::kBoolean, 1u, "0") == kInvalidArgument, "null name rejected");
    check(registry.Register("", Kind::kBoolean, 1u, "0") == kInvalidArgument, "empty name rejected");
    check(registry.Register("A=B", Kind::kBoolean, 1u, "0") == kInvalidArgument, "name with '=' rejected");
    check(registry.Register("AMCL_BAD_BOOL", Kind::kBoolean, 2u, "0") == kInvalidArgument, "boolean capacity must be 1");
    check(registry.Register("AMCL_BAD_INIT", Kind::kBoolean, 1u, "x") == kInvalidArgument, "invalid initial rejected");
    const std::string longName(kEntryBytes, 'N');
    check(registry.Register(longName.c_str(), Kind::kBoolean, 1u, "0") == kInvalidArgument, "oversized entry rejected");
    check(registry.Count() == 0u && FakeGet("AMCL_BAD_BOOL") == nullptr, "rejected registrations publish nothing");

    char names[kMaxSlots][32];
    for (uint32_t i = 0; i < kMaxSlots; ++i) {
        std::snprintf(names[i], sizeof(names[i]), "AMCL_SLOT_%u", i);
        check(registry.Register(names[i], Kind::kBoolean, 1u, "0") == kOk, "slot within capacity registers");
    }
    check(registry.Register("AMCL_SLOT_OVERFLOW", Kind::kBoolean, 1u, "0") == kFull, "ninth slot is full");
    check(registry.Store(names[0], "1") == kOk, "store works with a full table");
    check(registry.Register(names[0], Kind::kBoolean, 1u, "0") == kOk, "re-register is idempotent");
    check(Equal(FakeGet(names[0]), "1"), "re-register keeps the current value instead of resetting it");
    check(registry.Register(names[0], Kind::kDecimal, 4u, "0") == kConflict, "shape mismatch conflicts");

    FakeEnviron sealedFake;
    g_fake = &sealedFake;
    Registry sealedRegistry(FakeBackend(), WireThunk);
    check(sealedRegistry.Register("AMCL_BEFORE_SEAL", Kind::kBoolean, 1u, "0") == kOk, "register before seal");
    sealedRegistry.Seal();
    check(sealedRegistry.Sealed(), "seal is observable");
    check(sealedRegistry.Register("AMCL_AFTER_SEAL", Kind::kBoolean, 1u, "0") == kSealed, "new name after seal rejected");
    check(FakeGet("AMCL_AFTER_SEAL") == nullptr, "sealed registration publishes nothing (no late setenv)");
    check(sealedRegistry.Register("AMCL_BEFORE_SEAL", Kind::kBoolean, 1u, "0") == kOk,
          "re-register of an existing name still succeeds after seal");
    check(sealedRegistry.Store("AMCL_BEFORE_SEAL", "1") == kOk, "stores keep working after seal");
}

// 第三方 setenv/unsetenv 把槽位摘走后，原位写必须拒绝（写进去也没人读得到，还会误报成功）。
void DetachAndProcessIdentity() {
    FakeEnviron fake;
    g_fake = &fake;
    Registry registry(FakeBackend(), WireThunk);
    check(registry.Register("AMCL_TEST_RESTART", Kind::kBoolean, 1u, "0") == kOk, "restart slot register");
    const char* slot = registry.Value("AMCL_TEST_RESTART");
    ThirdPartySetenv("AMCL_TEST_RESTART", "1");
    check(!registry.Attached("AMCL_TEST_RESTART"), "third-party setenv detaches the slot");
    check(registry.Store("AMCL_TEST_RESTART", "0") == kDetached, "store after detach is rejected");
    check(Equal(slot, "0") && Equal(FakeGet("AMCL_TEST_RESTART"), "1"), "detached store writes neither copy");
    check(registry.Register("AMCL_TEST_RESTART", Kind::kBoolean, 1u, "0") == kDetached, "re-register reports detach");

    check(registry.Register("AMCL_TEST_GONE", Kind::kBoolean, 1u, "0") == kOk, "second slot register");
    ThirdPartyUnsetenv("AMCL_TEST_GONE");
    check(registry.Store("AMCL_TEST_GONE", "1") == kDetached, "store after third-party unsetenv is rejected");
    check(FakeGet("AMCL_TEST_GONE") == nullptr, "rejected store does not resurrect the name");

    fake.pid = 5151u;
    check(registry.Store("AMCL_TEST_GONE", "1") == kWrongProcess, "fork child inheriting the registry is rejected");
    fake.pid = 4242u;
}

// 登记表线协议：首个登记发布描述符；解析得到同一张表；负例全部失败关闭。
void WireProtocol() {
    FakeEnviron fake;
    g_fake = &fake;
    Registry registry(FakeBackend(), WireThunk);
    g_wireTarget = &registry;
    check(FakeGet(kRegistryEnv) == nullptr, "registry descriptor is not published before the first slot");
    check(registry.Register("AMCL_WIRE_FLAG", Kind::kBoolean, 1u, "0") == kOk, "wire slot register");
    const char* descriptor = FakeGet(kRegistryEnv);
    int status = kOk;
    const WireV1* wire = ParseWire(descriptor, fake.pid, &status);
    check(wire == registry.Wire() && status == kOk, "descriptor parses back to the owner table");
    check(wire && wire->store("AMCL_WIRE_FLAG", "1") == kOk, "cross-image store goes through the owner");
    check(Equal(FakeGet("AMCL_WIRE_FLAG"), "1"), "cross-image store is visible in environ");
    check(ParseWire(descriptor, fake.pid + 1u, &status) == nullptr && status == kWrongProcess,
          "descriptor from another pid is rejected");

    const char* malformed[] = {"", "4242", "4242:", "4242:zz", "4242:0", "x:1", "4242:12g"};
    for (const char* text : malformed) {
        status = kOk;
        check(ParseWire(text, fake.pid, &status) == nullptr && status < 0, "malformed descriptor rejected");
    }
    check(ParseWire(nullptr, fake.pid, &status) == nullptr && status == kUnavailable, "absent descriptor unavailable");

    // 形似有效地址但表头不符：逐字段破坏一次，每次都必须拒绝。field == 5 是正对照：
    // 未破坏的副本必须能解析，证明前五次拒绝确实来自被破坏的那个字段。
    for (int field = 0; field <= 5; ++field) {
        WireV1 forged = *registry.Wire();
        forged.self = &forged;
        if (field == 0) forged.magic ^= 1u;
        if (field == 1) forged.abi = kWireAbi + 1u;
        if (field == 2) forged.structSize = 8u;
        if (field == 3) forged.self = registry.Wire();
        if (field == 4) forged.store = nullptr;
        char text[64];
        std::snprintf(text, sizeof(text), "%llu:%llx", static_cast<unsigned long long>(fake.pid),
                      static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(&forged)));
        status = kOk;
        const WireV1* parsed = ParseWire(text, fake.pid, &status);
        if (field == 5) {
            check(parsed == &forged && status == kOk, "intact wire copy parses (positive control)");
        } else {
            check(parsed == nullptr && status == kConflict, "forged wire header rejected");
        }
    }

    // 同进程第二个 owner 必须拒绝；继承自父进程（pid 不符）的旧描述符则被本表覆盖。
    Registry second(FakeBackend(), WireThunk);
    check(second.Register("AMCL_SECOND_OWNER", Kind::kBoolean, 1u, "0") == kConflict, "second owner conflicts");
    check(FakeGet("AMCL_SECOND_OWNER") == nullptr, "conflicting owner publishes nothing");
    fake.pid = 6000u;
    Registry child(FakeBackend(), WireThunk);
    check(child.Register("AMCL_CHILD_FLAG", Kind::kBoolean, 1u, "0") == kOk, "inherited descriptor is replaced");
    check(ParseWire(FakeGet(kRegistryEnv), fake.pid, &status) == child.Wire(), "descriptor now names the new owner");
    fake.pid = 4242u;
    g_wireTarget = nullptr;
}

// 复制型后端（Windows CRT 语义）：每次写入都重新 put 整条 entry，值仍然可见。
void CopyingBackend() {
    FakeEnviron fake;
    g_fake = &fake;
    Registry registry(Backend{FakePut, FakeGet, FakePid, false}, WireThunk);
    check(registry.Register("AMCL_COPY_FLAG", Kind::kBoolean, 1u, "0") == kOk, "copying backend register");
    const int puts = fake.putCalls;
    check(registry.Store("AMCL_COPY_FLAG", "1") == kOk && fake.putCalls == puts + 1, "copying backend re-puts");
    check(registry.Store("AMCL_COPY_FLAG", "1") == kUnchanged && fake.putCalls == puts + 1, "unchanged skips re-put");
}

#ifndef _WIN32
size_t EnvironCount() {
    size_t count = 0;
    for (char** entry = environ; entry && *entry; ++entry) ++count;
    return count;
}
#endif

// 真实进程 environ + 进程单例 + 跨映像入口 + 重启标记语义。
void RealEnvironment() {
    Registry& registry = ProcessRegistry();
    check(registry.Register(kRendererRestartEnv, Kind::kBoolean, 1u, "0") == kOk, "real restart slot register");
    check(registry.Register("AMCL_ENV_SLOT_TEST_WIDTH", Kind::kDecimal, kDecimalWidth, "0") == kOk,
          "real decimal register");
    check(Equal(std::getenv(kRendererRestartEnv), "0"), "real getenv sees the registered value");
    const char* descriptor = std::getenv(kRegistryEnv);
    check(descriptor && *descriptor && ParseWire(descriptor, SystemPid(), nullptr) == registry.Wire(),
          "real registry descriptor is published and names the process registry");
#ifndef _WIN32
    const char* before = std::getenv("AMCL_ENV_SLOT_TEST_WIDTH");
    check(before == registry.Value("AMCL_ENV_SLOT_TEST_WIDTH"), "real getenv returns the slot buffer itself");
    const size_t countBefore = EnvironCount();
#endif
    check(StorePublished("AMCL_ENV_SLOT_TEST_WIDTH", "1280") == kOk, "StorePublished reaches the owner");
    check(Equal(std::getenv("AMCL_ENV_SLOT_TEST_WIDTH"), "0000001280"), "real getenv sees the padded store");
#ifndef _WIN32
    check(std::getenv("AMCL_ENV_SLOT_TEST_WIDTH") == before, "real store keeps the environ pointer");
    check(EnvironCount() == countBefore, "real store keeps the environ entry count");
#endif
    check(RequestRendererRestart() == kOk && Equal(std::getenv(kRendererRestartEnv), "1"), "restart request sets 1");
    check(RequestRendererRestart() == kUnchanged, "second restart request is unchanged");
#ifndef _WIN32
    // SDL 等预编译写者 setenv 后槽位被摘走：值已是 "1" 视为满足；值不是 "1" 必须失败。
    ::setenv(kRendererRestartEnv, "1", 1);
    check(RequestRendererRestart() == kUnchanged, "detached slot already holding 1 counts as satisfied");
    ::setenv("AMCL_ENV_SLOT_TEST_WIDTH", "77", 1);
    check(StorePublished("AMCL_ENV_SLOT_TEST_WIDTH", "1") == kDetached, "real third-party setenv detaches");
    check(Equal(std::getenv("AMCL_ENV_SLOT_TEST_WIDTH"), "77"), "detached real store does not overwrite");

    const pid_t child = fork();
    if (child == 0) {
        // 子进程：继承的登记表与描述符都属于父进程，任何写入都必须拒绝且不改值。
        const bool rejected = ProcessRegistry().Store(kRendererRestartEnv, "0") == kWrongProcess &&
                              StorePublished(kRendererRestartEnv, "0") == kWrongProcess;
        _exit(rejected ? 0 : 1);
    }
    int childStatus = 0;
    check(child > 0 && waitpid(child, &childStatus, 0) == child && WIFEXITED(childStatus) &&
              WEXITSTATUS(childStatus) == 0,
          "fork child writes are rejected with kWrongProcess");
#endif
}

}  // namespace

int main() {
    BooleanAndInPlaceSemantics();
    DecimalSemantics();
    TextSemantics();
    RegistrationRules();
    DetachAndProcessIdentity();
    WireProtocol();
    CopyingBackend();
    RealEnvironment();
    if (failures) {
        std::fprintf(stderr, "env_slot_test: %d failure(s)\n", failures);
        return 1;
    }
    std::printf("env_slot_test: PASS\n");
    return 0;
}
