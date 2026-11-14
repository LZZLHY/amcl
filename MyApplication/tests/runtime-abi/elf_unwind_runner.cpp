/**
 * 生产 mapper + 同一真实应用 provider 的 AArch64 集成资格。此阶段显式登记已知夹具
 * 的构建期节边界，用于验证索引桥与真实展开；不替代产品侧任意输入的有界 EH 校验。
 */
#include "../../entry/src/main/cpp/jvm/elf_loader.cpp"
#include "../../entry/src/main/cpp/jvm/elf_unwind_validation.h"
#include "../../prebuilt/abi/amcl_unwind_image.h"
#include "fixture_sections.h"
#include "libunwind.h"
#include <cassert>
#include <stdexcept>
#include <cstdio>
#include <cstring>
#include <ctime>

extern "C" void amclLogPrint(AmclLogLevel, unsigned int, const char*, const char*, ...) {}
extern "C" void amclLogWrite(AmclLogLevel, const char*, const char*, ...) {}
FILE* amclIfInet6ShimOpen(const char*, const char*) { return nullptr; }
static int cleanupCount = 0;
static int constructorCount = 0;
extern "C" void unwind_mark(int value) { cleanupCount += value; }
extern "C" void unwind_initialized() { ++constructorCount; }
using FrameCall = void (*)(void (*)());
static FrameCall nestedFrame = nullptr;
static void throw_from_host() { throw std::runtime_error("unwind-image-ok"); }
static void nested_callback() { nestedFrame(throw_from_host); }

/** standard libunwind 查询必须给出实际覆盖区间，不能只检查“register 返回成功”。 */
static bool hasFrame(void* address) {
    unw_context_t context{};
    unw_cursor_t cursor{};
    unw_proc_info_t info{};
    assert(unw_getcontext(&context) == 0 && unw_init_local(&cursor, &context) == 0);
    // 使用函数首条指令之后的真实代码位置，匹配 LLVM 无索引扫描的返回 PC 语义。
    // 本固定夹具长度大于一条 AArch64 指令；不把函数边界查询差异误判成未登记。
    assert(unw_set_reg(&cursor, UNW_REG_IP, reinterpret_cast<unw_word_t>(address) + 4) == 0);
    return unw_get_proc_info(&cursor, &info) == 0 && info.start_ip <= reinterpret_cast<unw_word_t>(address) &&
        reinterpret_cast<unw_word_t>(address) < info.end_ip;
}

static decltype(g_registerUnwindImage) realRegister = nullptr;
static unsigned registrationCalls = 0;
static uintptr_t firstRegisteredBase = 0;
/** 只令第二次 provider 调用返回资源失败；第一次仍真正登记，用来检验整批撤销。 */
static int fail_second_registration(const amcl_unwind_image_v1* image) {
    if (++registrationCalls == 2) return AMCL_UNWIND_NOMEM;
    firstRegisteredBase = image->image_base;
    return realRegister(image);
}

/** 真实重定位后的 CIE/GOT/personality 与 PC，使用当前映像及明确的 SDK personality 身份。 */
static void validateFixture(elf_handle_t* handle) {
    using namespace amcl::unwindinput;
    auto read = [](void* context, Address address, size_t bytes) {
        auto* image = static_cast<elf_handle_t*>(context);
        const auto base = reinterpret_cast<Address>(image->base);
        return address >= base && span_contains(image->fileSpans, address - base + image->loadBias, bytes);
    };
    auto ownCode = [](void* context, Address address, size_t bytes) {
        auto* image = static_cast<elf_handle_t*>(context);
        const auto base = reinterpret_cast<Address>(image->base);
        return address >= base && span_contains(image->executableSpans, address - base + image->loadBias, bytes);
    };
    auto personality = [](void*, Address address, size_t bytes) {
        return bytes == 1 && address == reinterpret_cast<Address>(dlsym(RTLD_DEFAULT, "__gxx_personality_v0"));
    };
    Memory memory{handle, read, personality, ownCode};
    std::vector<Frame> frames;
    const char* error = nullptr;
    if (!validate(memory, reinterpret_cast<Address>(vaddr2ptr(handle, fixture_eh_frame)),
                  fixture_eh_frame_size, frames, error)) {
        std::fprintf(stderr, "Actual relocated EH rejected: %s\n", error ? error : "unknown");
        std::abort();
    }
    assert(!frames.empty());
}

/** 每次独立进程只装载一个 major 的真实 libjvm；不创建 JavaVM，不宣称 Java/游戏已运行。 */
static int loadActualJvm(const char* major) {
    const char* fixtureRoot = std::getenv("AMCL_ELF_FIXTURES");
    assert(fixtureRoot && (std::strcmp(major, "8") == 0 || std::strcmp(major, "17") == 0 ||
                          std::strcmp(major, "21") == 0 || std::strcmp(major, "25") == 0));
    const std::string directory = std::string(fixtureRoot) + "/" + major +
        (std::strcmp(major, "8") == 0 ? "/jre/lib/aarch64" : "/lib");
    elf_set_search_path((directory + ":" + directory + "/server").c_str());
    timespec begin{}, end{};
    clock_gettime(CLOCK_MONOTONIC, &begin);
    auto* handle = elf_open((directory + "/server/libjvm.so").c_str());
    clock_gettime(CLOCK_MONOTONIC, &end);
    if (!handle) { std::fprintf(stderr, "Actual JDK%s load failed: %s\n", major, elf_error()); return 7; }
    void* createVm = elf_sym(handle, "JNI_CreateJavaVM");
    assert(createVm && handle->unwindRegistered && hasFrame(createVm));
    const long long milliseconds = (end.tv_sec - begin.tv_sec) * 1000LL + (end.tv_nsec - begin.tv_nsec) / 1000000;
    std::printf("PASS actual JDK%s libjvm mapping/relocation/EH/constructors: %lld ms (QEMU); JavaVM not created\n", major, milliseconds);
    std::fflush(stdout);
    elf_close(handle);
    assert(!hasFrame(createVm));
    return 0;
}

int main(int argc, char** argv) {
    assert(argc >= 2);
    if (argc == 4 && std::strcmp(argv[2], "--jdk-load") == 0) return loadActualJvm(argv[3]);
    const std::string root = argv[1];
    elf_set_search_path(root.c_str());
    assert(prepare_unwind_provider());
    realRegister = g_registerUnwindImage;
    g_registerUnwindImage = fail_second_registration;
    assert(!elf_open((root + "/libelf_unwind_parent.so").c_str()));
    g_registerUnwindImage = realRegister;
    assert(registrationCalls == 2 && constructorCount == 0 && g_loaded.empty());
    assert(amcl_unwind_unregister_image(firstRegisteredBase) == UNW_ENOINFO);
    for (const char* name : {"badheader", "badcie"}) {
        assert(!elf_open((root + "/libelf_unwind_" + name + ".so").c_str()));
        assert(constructorCount == 0 && g_loaded.empty());
    }
    auto* first = elf_open((root + "/libelf_unwind_subject.so").c_str());
    if (!first) { std::fprintf(stderr, "loader rejected fixture: %s\n", elf_error()); return 3; }
    auto call = reinterpret_cast<FrameCall>(elf_sym(first, "frame_call"));
    assert(call && first->unwindRegistered && hasFrame(reinterpret_cast<void*>(call)) && constructorCount == 1);
    if (argc == 3 && std::strcmp(argv[2], "--no-register") == 0) {
        assert(amcl_unwind_unregister_image(reinterpret_cast<uintptr_t>(first->base)) == 0);
        first->unwindRegistered = false; // 负控制故意撤销本库，正例始终使用生产自动登记。
        std::puts("NEGATIVE crossing an unregistered custom frame"); std::fflush(stdout);
        try { call(throw_from_host); } catch (...) { return 4; }
        return 5;
    }
    validateFixture(first);
    try { call(throw_from_host); assert(false); }
    catch (const std::runtime_error& error) { assert(std::strcmp(error.what(), "unwind-image-ok") == 0); }
    assert(cleanupCount == 1);
    auto* second = elf_open((root + "/libelf_unwind_second.so").c_str());
    assert(second);
    nestedFrame = reinterpret_cast<FrameCall>(elf_sym(second, "frame_call"));
    validateFixture(second);
    assert(second->unwindRegistered);
    try { call(nested_callback); assert(false); }
    catch (const std::runtime_error&) {}
    assert(cleanupCount == 3);
    elf_close(second);
    assert(!hasFrame(reinterpret_cast<void*>(nestedFrame)));
    elf_close(first);
    assert(!hasFrame(reinterpret_cast<void*>(call)));
    // 含/不含 EH header 的合法路径都反复卸载，索引与普通 FDE cache 均不能遗留陈旧条目。
    for (int iteration = 0; iteration < 64; ++iteration) {
        const char* variant = iteration % 3 == 0 ? "subject" : iteration % 3 == 1 ? "noheader" : "stripped";
        auto* handle = elf_open((root + "/libelf_unwind_" + variant + ".so").c_str());
        assert(handle);
        auto function = reinterpret_cast<FrameCall>(elf_sym(handle, "frame_call"));
        validateFixture(handle);
        assert(handle->unwindRegistered);
        assert(hasFrame(reinterpret_cast<void*>(function)));
        try { function(throw_from_host); assert(false); } catch (const std::runtime_error&) {}
        elf_close(handle);
        assert(!hasFrame(reinterpret_cast<void*>(function)));
    }
    assert(cleanupCount == 67);
    assert(constructorCount == 66);
    std::printf("PASS automatic custom unwind: cleanup=%d, constructors=%d, partial-register rollback, indexed/unindexed/stripped reopen=64\n", cleanupCount, constructorCount);
}
