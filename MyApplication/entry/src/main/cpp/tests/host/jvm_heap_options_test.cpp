// 生产堆参数纯核心的正反例：不创建 JVM、不按“实现用了哪些字符串”代替行为断言。
#include "../../jvm/jvm_heap_options.h"
#include <cstdlib>
#include <iostream>

namespace {
constexpr uint64_t mib = 1024u * 1024u;
void Require(bool value, const char* message) {
    if (value) return;
    std::cerr << "jvm_heap_options_test: FAIL: " << message << '\n';
    std::exit(1);
}
amcl::jvm::HeapOptions Resolve(std::vector<std::string> args, int maximum = 4096, bool classic = false) {
    amcl::jvm::HeapOptions result;
    std::string error;
    Require(amcl::jvm::ResolveHeapOptions(maximum, args, classic, result, error), error.c_str());
    Require(error.empty(), "successful resolution clears errors");
    return result;
}
void Reject(std::vector<std::string> args, const char* expected) {
    amcl::jvm::HeapOptions result;
    result.maximumBytes = 42;
    std::string error;
    Require(!amcl::jvm::ResolveHeapOptions(4096, args, false, result, error), "bad input must be rejected");
    Require(error == expected, "wrong rejection identity");
    Require(result.maximumBytes == 42, "rejection must not partially mutate output");
}
}
int main() {
    // 格式层覆盖单位、十六进制、大小写、边界和乘加溢出；未省略单位时按字节解释。
    uint64_t bytes = 0;
    Require(amcl::jvm::ParseHeapBytes("000512m", bytes) && bytes == 512 * mib, "decimal leading zero");
    Require(amcl::jvm::ParseHeapBytes("0x100m", bytes) && bytes == 256 * mib, "hex with suffix");
    Require(amcl::jvm::ParseHeapBytes("0X20000000", bytes) && bytes == 512 * mib, "hex bytes");
    Require(amcl::jvm::ParseHeapBytes("1T", bytes) && bytes == 1024ULL * 1024 * mib, "terabyte unit");
    Require(amcl::jvm::ParseHeapBytes("128K", bytes) && bytes == 128 * 1024, "kilobyte unit");
    for (const auto& invalid : std::vector<std::string>{"", "0x", "-1m", "+1m", " 1m", "1m ", "1.5g", "1KB",
            "18446744073709551616", "18446744073709551615K", std::string("1m\0", 3)}) {
        bytes = 37;
        Require(!amcl::jvm::ParseHeapBytes(invalid, bytes) && bytes == 37, "invalid size accepted or mutated output");
    }
    auto plan = Resolve({});
    Require(plan.maximumBytes == 4096 * mib && plan.initialBytes == 1024 * mib, "default heap policy");
    plan = Resolve({}, 128);
    Require(plan.initialBytes == 128 * mib, "small default maximum caps automatic initial");
    plan = Resolve({}, 0);
    Require(plan.maximumBytes == 128 * mib, "legacy nonpositive default fallback");
    // 审计原始反例：降低最终 Xmx 时自动 Xms 必须联动，无需用户再手工写第二个参数。
    plan = Resolve({"-Xmx512m"});
    Require(plan.maximumBytes == 512 * mib && plan.initialBytes == 512 * mib &&
        plan.automaticInitialOption == "-Xms536870912", "custom maximum must drive automatic initial");
    plan = Resolve({"-Xmx64m", "-XX:MaxHeapSize=256M"});
    Require(plan.maximumBytes == 256 * mib && plan.initialBytes == 256 * mib, "last maximum alias wins");
    plan = Resolve({"-XX:MaxHeapSize=1g", "-Xmx128m"});
    Require(plan.maximumBytes == 128 * mib, "last Xmx wins over alias");
    plan = Resolve({"-Xms2g", "-Xmx512m", "-Xms128m"});
    Require(plan.initialExplicit && plan.initialBytes == 128 * mib && plan.automaticInitialOption.empty(), "last explicit initial wins");
    plan = Resolve({"-Xmx512m", "-XX:InitialHeapSize=128m"});
    Require(plan.initialExplicit && plan.initialBytes == 128 * mib && plan.minimumBytes == 0, "initial alias must not impose minimum");
    plan = Resolve({"-Xmx128m", "-Xms0"});
    Require(plan.initialExplicit && plan.initialBytes == 0 && plan.automaticInitialOption.empty(), "explicit zero preserves ergonomics");
    plan = Resolve({"-Xmx2g", "-XX:MinHeapSize=1536m"});
    Require(plan.initialBytes == 1536 * mib, "automatic initial must accommodate explicit minimum");
    plan = Resolve({"-Xmx128m", "-XX:MinHeapSize=2g"}, 4096, true);
    Require(plan.initialBytes == 128 * mib, "JDK8 has no MinHeapSize flag");
    Reject({"-Xmx0"}, "heap_size_zero:Xmx");
    Reject({"-Xmxwrong", "-Xmx512m"}, "heap_size_invalid:Xmx");
    Reject({"-Xmx18446744073709551616"}, "heap_size_invalid:Xmx");
    Reject({"-Xmx512m", "-Xms1g"}, "heap_minimum_exceeds_maximum");
    Reject({"-Xmx512m", "-XX:InitialHeapSize=1g"}, "heap_initial_exceeds_maximum");
    // JDK8/17 在 GC 对齐后检查 minimum/initial，以下相差一字节的组合能成功启动；
    // JDK21 的检查提前会拒绝。纯核心不替 JVM/GC 决定这条关系，保留原参数语义。
    plan = Resolve({"-Xmx512m", "-Xms134217730", "-XX:InitialHeapSize=134217729"});
    Require(plan.initialBytes == 134217729 && plan.minimumBytes == 134217730 &&
        plan.automaticInitialOption.empty(), "do not reject GC alignment dependent relation");
    std::cout << "jvm_heap_options_test: PASS\n";
}
