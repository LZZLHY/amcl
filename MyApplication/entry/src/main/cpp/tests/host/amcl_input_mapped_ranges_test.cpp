/**
 * 单次映射扫描的生产回归。沿用既有描述符夹具的完整 ABI、失败断言和真实发布锁，
 * 新增 parser/区间边界及实际 Resolve 调用计数；不复制 owner 或描述符裁决算法。
 * maps 模式仅替换内核文本来源，所有 prefix/tail/callback 判定仍执行生产实现。
 */
#include "amcl_input_mapped_ranges.h"
#define main ExistingDescriptorRegressionMain
#include "amcl_input_host_descriptor_test.cpp"
#undef main

#include <fstream>
#include <limits>
#include <string>

namespace {
using amcl::input::detail::MappedRange;
using amcl::input::detail::MappedRangeSnapshot;
using amcl::input::detail::ParseMappedRange;

/** 真实 FILE 读取 parser；独立相邻段不能拼成一份可读前缀，x 权限不能替代 r。 */
void TestMappedParserAndBounds() {
    MappedRange range{};
    CHECK(ParseMappedRange("1000-1100 rw-p 00000000 00:00 0 /table\n", &range));
    CHECK(range.begin == 0x1000u && range.end == 0x1100u && range.readable && !range.executable);
    CHECK(!ParseMappedRange("malformed row", &range));
    CHECK(!ParseMappedRange("2000-1000 r-xp", &range));
    FILE* text = std::tmpfile(); CHECK(text != nullptr);
    CHECK(std::fputs("1000-1100 rw-p\n1100-1200 r--p\n2000-2100 r-xp\n3000-3100 --xp\nmalformed\n", text) >= 0);
    std::rewind(text);
    MappedRangeSnapshot snapshot; CHECK(snapshot.LoadStream(text));
    CHECK(snapshot.Contains(0x1000u, 0x100u, false));
    CHECK(!snapshot.Contains(0x1000u, 1u, true));
    CHECK(!snapshot.Contains(0x1080u, 0x100u, false));
    CHECK(snapshot.Contains(0x2000u, 1u, true));
    CHECK(!snapshot.Contains(0x3000u, 1u, true));
    CHECK(!snapshot.Contains(0u, 1u, false)); CHECK(!snapshot.Contains(0x1000u, 0u, false));
    CHECK(!snapshot.Contains(UINTPTR_MAX, 1u, false));
    CHECK(!snapshot.Contains(UINTPTR_MAX - 1u, 2u, false));
    CHECK(std::fclose(text) == 0);
    // 不能读取的流不得留下可被查询的半份集合；后续完整调用使用新实例。
    MappedRangeSnapshot failed; CHECK(!failed.LoadStream(nullptr));
    CHECK(!failed.Contains(0x1000u, 1u, false));
}

/** 真实C读取错误使本轮失效并关闭移交句柄，不能把fgets失败解释为干净EOF后的可用集合。 */
void TestMappedReadError(const char* path) {
    FILE* writeOnly = std::fopen(path, "w"); CHECK(writeOnly != nullptr);
#ifdef AMCL_INPUT_DESCRIPTOR_MAPS_TESTING
    amcl::input::detail::mappedRangesTestCloses = 0u;
#endif
    {
        MappedRangeSnapshot snapshot; CHECK(snapshot.LoadStream(writeOnly, true));
        CHECK(!snapshot.Contains(0x1000u, 1u, false));
        // 真正读取错误后 ready=false；干净EOF会保留合法已读集合，不满足这一断言。
        CHECK(!snapshot.LoadStream(nullptr));
        CHECK(!snapshot.Contains(0x1000u, 1u, false));
    }
#ifdef AMCL_INPUT_DESCRIPTOR_MAPS_TESTING
    CHECK(amcl::input::detail::mappedRangesTestCloses == 1u);
#endif
}

#ifdef AMCL_INPUT_DESCRIPTOR_MAPS_TESTING
/** 只提供合法尾表的空实现，测试不调用 callback，仅验证其真实函数地址资格。 */
int32_t OrderedNext(AmclInputConsumerHandle, AmclInputEvent*, uint64_t, uint64_t*) { return AMCL_INPUT_OK; }
int32_t PeekOrder(AmclInputConsumerHandle, uint64_t*) { return AMCL_INPUT_OK; }
uint64_t OrderFence() { return 1u; }

/** 生产完整 capability/table；prefix-only 用例会明确撤销尾表能力而非伪造旧表长度。 */
AmclInputHostApiV1 OrderedApi() {
    auto api = ValidApi(AMCL_INPUT_HOST_API_GENERATION);
    api.capabilityBits |= AMCL_INPUT_CAP_INTERACTION_ORDER;
    api.nextOrderedEvent = OrderedNext; api.peekEventOrder = PeekOrder; api.interactionFence = OrderFence;
    return api;
}

/** 将稳定函数地址转换为整数，只为系统文本边界构造合法映射，不参与业务裁决。 */
template <typename T> uintptr_t AddressOf(T function) {
    uintptr_t result = 0u; static_assert(sizeof(function) <= sizeof(result), "pointer width");
    std::memcpy(&result, &function, sizeof(function)); return result;
}

/** 独立打印一条映射；不把多个权限段合并。输入 API 在本局夹具内保持存活。 */
void EmitRange(FILE* file, uintptr_t begin, size_t bytes, const char* permissions) {
    CHECK(begin <= UINTPTR_MAX - bytes);
    CHECK(std::fprintf(file, "%llx-%llx %s 00000000 00:00 0 fixture\n",
        static_cast<unsigned long long>(begin), static_cast<unsigned long long>(begin + bytes), permissions) > 0);
}

/** 每次重写系统边界的真实文本文件；表/函数仍由真实生产 Resolve 校验，旧实例不可复用新文本。 */
void WriteMappings(const char* path, const AmclInputHostApiV1& api, size_t tableBytes,
                   const char* tablePermissions = "rw-p", bool executableCallbacks = true, bool splitTable = false) {
    FILE* file = std::fopen(path, "w"); CHECK(file != nullptr);
    const uintptr_t table = reinterpret_cast<uintptr_t>(&api);
    if (splitTable) {
        EmitRange(file, table, tableBytes / 2u, tablePermissions);
        EmitRange(file, table + tableBytes / 2u, tableBytes - tableBytes / 2u, tablePermissions);
    } else EmitRange(file, table, tableBytes, tablePermissions);
#define EMIT_CALLBACK(name) EmitRange(file, AddressOf(api.name), 1u, executableCallbacks ? "r-xp" : "rw-p")
    EMIT_CALLBACK(beginSession); EMIT_CALLBACK(endSession); EMIT_CALLBACK(submitEvent); EMIT_CALLBACK(submitBatch);
    EMIT_CALLBACK(submitTextPacket); EMIT_CALLBACK(publishSurface); EMIT_CALLBACK(publishFocus);
    EMIT_CALLBACK(publishDeviceChange); EMIT_CALLBACK(requestReset); EMIT_CALLBACK(openConsumer);
    EMIT_CALLBACK(nextEvent); EMIT_CALLBACK(readPacketBlob); EMIT_CALLBACK(releasePacket);
    EMIT_CALLBACK(closeConsumer); EMIT_CALLBACK(getSnapshot);
    if ((api.capabilityBits & AMCL_INPUT_CAP_INTERACTION_ORDER) != 0u) {
        EMIT_CALLBACK(nextOrderedEvent); EMIT_CALLBACK(peekEventOrder); EMIT_CALLBACK(interactionFence);
    }
#undef EMIT_CALLBACK
    // 目标表与callback在早段；后面8192条无关映射不应因批内复用被提前读取。
    // 实际fgets计数才能识别1次open但读全长尾的退化，不能只按open次数判断优化。
    for (size_t index = 0u; index < 8192u; ++index) EmitRange(file, 0x1000u + index * 16u, 16u, "r--p");
    CHECK(std::fclose(file) == 0);
}

/** 只发布格式正确的 descriptor text；避免 Publish 预热 callback memo，首次18项全部经真实 Resolve。 */
void RawApi(const AmclInputHostApiV1& api, uint64_t generation = AMCL_INPUT_HOST_API_GENERATION) {
    char text[96]{};
    std::snprintf(text, sizeof(text), "AMCL_INPUT_HOST_V1:%016llx:%0*llx",
        static_cast<unsigned long long>(generation), static_cast<int>(sizeof(uintptr_t) * 2u),
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(&api)));
    SetRaw(text);
}

/** 真实调用的错误/输出/读取次数同时核验，任何负例都必须保留 outApi=null。 */
void ResolveIs(int32_t expected, const AmclInputHostApiV1* api, size_t reads,
               size_t maxLines = SIZE_MAX, size_t closes = SIZE_MAX) {
    amcl::input::detail::mappedRangesTestReads = 0u;
    amcl::input::detail::mappedRangesTestLines = 0u;
    amcl::input::detail::mappedRangesTestCloses = 0u;
    const AmclInputHostApiV1* actual = reinterpret_cast<const AmclInputHostApiV1*>(1u);
    CHECK(amclInputHostDescriptorResolveV1(&actual) == expected);
    CHECK(actual == api);
    CHECK(amcl::input::detail::mappedRangesTestReads == reads);
    CHECK(amcl::input::detail::mappedRangesTestLines <= maxLines);
    CHECK(amcl::input::detail::mappedRangesTestCloses == (closes == SIZE_MAX ? reads : closes));
}

/**
 * 冷 ordered 的prefix/tail/18callback从20次降为1；warm两份表范围从2次降为1。
 * --legacy-count 仅由编译了机械反控的旧逐查询代码使用，保证反控确实测到20/2而非任意失败。
 */
void TestResolveReadsAndPermissions(const char* path, bool legacyCount) {
    amcl::input::detail::mappedRangesTestPath = path;
    auto api = OrderedApi(); RawApi(api); WriteMappings(path, api, sizeof(api));
    ResolveIs(AMCL_INPUT_HOST_DESCRIPTOR_OK, &api, legacyCount ? 20u : 1u, legacyCount ? 191u : 19u);
    std::cout << "cold ordered maps opens=" << amcl::input::detail::mappedRangesTestReads
              << " lines=" << amcl::input::detail::mappedRangesTestLines
              << " closes=" << amcl::input::detail::mappedRangesTestCloses << '\n';
    ResolveIs(AMCL_INPUT_HOST_DESCRIPTOR_OK, &api, legacyCount ? 2u : 1u, legacyCount ? 2u : 1u);
    std::cout << "warm ordered maps opens=" << amcl::input::detail::mappedRangesTestReads
              << " lines=" << amcl::input::detail::mappedRangesTestLines
              << " closes=" << amcl::input::detail::mappedRangesTestCloses << '\n';
    // 同一 descriptor/表内容不变，仅撤销本轮可读权限，下次必须重读并在 memcpy 前拒绝。
    WriteMappings(path, api, sizeof(api), "---p");
    ResolveIs(AMCL_INPUT_HOST_DESCRIPTOR_ERROR_UNSAFE_POINTER, nullptr, 1u);
    WriteMappings(path, api, sizeof(api));
    ResolveIs(AMCL_INPUT_HOST_DESCRIPTOR_OK, &api, legacyCount ? 2u : 1u);
    // 宣告有序尾表但映射只有合法前缀，拒绝越界 memcpy；短 structSize 同样拒绝。
    WriteMappings(path, api, AMCL_INPUT_HOST_API_V1_PREFIX_SIZE);
    ResolveIs(AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ABI_MISMATCH, nullptr, legacyCount ? 2u : 1u);
    api.structSize = AMCL_INPUT_HOST_API_V1_PREFIX_SIZE;
    ResolveIs(AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ABI_MISMATCH, nullptr, 1u);
    api = OrderedApi(); WriteMappings(path, api, sizeof(api), "rw-p", false);
    // 改变表字节使旧 callback memo 失效，不能借既有memo接受数据页函数。
    api.capabilityBits &= ~AMCL_INPUT_CAP_INTERACTION_ORDER;
    RawApi(api); WriteMappings(path, api, sizeof(api), "rw-p", false);
    ResolveIs(AMCL_INPUT_HOST_DESCRIPTOR_ERROR_UNSAFE_POINTER, nullptr, legacyCount ? 2u : 1u);
    api = OrderedApi(); RawApi(api); WriteMappings(path, api, sizeof(api), "rw-p", true, true);
    ResolveIs(AMCL_INPUT_HOST_DESCRIPTOR_ERROR_UNSAFE_POINTER, nullptr, 1u);
    // 合法prefix-only旧宿主只读144字节，不要求未宣告的尾表映射。
    api = ValidApi(AMCL_INPUT_HOST_API_GENERATION); api.structSize = AMCL_INPUT_HOST_API_V1_PREFIX_SIZE;
    RawApi(api); WriteMappings(path, api, AMCL_INPUT_HOST_API_V1_PREFIX_SIZE);
    ResolveIs(AMCL_INPUT_HOST_DESCRIPTOR_OK, &api, legacyCount ? 16u : 1u);
    CHECK(amclInputHostDescriptorClearV1() == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    ResolveIs(AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MISSING, nullptr, 0u);
    SetRaw("bad descriptor"); ResolveIs(AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MALFORMED, nullptr, 0u);
    RawApi(api, AMCL_INPUT_HOST_API_GENERATION + 1u);
    ResolveIs(AMCL_INPUT_HOST_DESCRIPTOR_ERROR_GENERATION, nullptr, 0u);
    // 读源故障fail closed，修复后的新Resolve仍能成功，不能负缓存失败。
    RawApi(api); CHECK(std::remove(path) == 0);
    ResolveIs(AMCL_INPUT_HOST_DESCRIPTOR_ERROR_UNSAFE_POINTER, nullptr, 1u, SIZE_MAX, 0u);
    WriteMappings(path, api, AMCL_INPUT_HOST_API_V1_PREFIX_SIZE);
    ResolveIs(AMCL_INPUT_HOST_DESCRIPTOR_OK, &api, 1u);
    CHECK(amclInputHostDescriptorClearV1() == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    amcl::input::detail::mappedRangesTestPath = nullptr;
}
#endif
}  // namespace

/** 默认模式跑原真实平台/发布竞争回归；maps模式另跑同一生产POSIX分支的文本来源反控。 */
int main(int argc, char** argv) {
    TestMappedParserAndBounds();
    if (argc >= 2) TestMappedReadError(argv[1]);
#ifdef AMCL_INPUT_DESCRIPTOR_MAPS_TESTING
    CHECK(argc >= 2);
    TestResolveReadsAndPermissions(argv[1], argc >= 3 && std::strcmp(argv[2], "--legacy-count") == 0);
    std::cout << "PASS production maps parser/Resolve counts and per-call permission reload\n";
#else
    (void)argc; (void)argv;
    CHECK(ExistingDescriptorRegressionMain() == 0);
    std::cout << "PASS production maps parser and existing native descriptor owner/concurrency regressions\n";
#endif
    return 0;
}
