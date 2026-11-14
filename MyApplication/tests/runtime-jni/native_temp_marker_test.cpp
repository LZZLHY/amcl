/**
 * 对现场链接的小型AArch64 ELF及单点损坏副本运行真实生产marker解析器。
 * 输入是已保存的文件与明确预期分类；可选第四参数要求拒绝诊断包含准确原因。
 * 不装载/执行目标代码，合法旧样本仅证明无marker兼容路径，不冒称完整旧JDK资格。
 */
#include "../../entry/src/main/cpp/jvm/jdk_native_temp_contract.h"
#include <fstream>
#include <iterator>
#include <iostream>
#include <vector>
#include <string>

int main(int argc, char** argv) {
    if (argc != 3 && argc != 4) return 2;
    std::ifstream input(argv[1], std::ios::binary);
    if (!input) return 3;
    std::vector<unsigned char> data((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    const char* error = nullptr;
    const auto contract = amcl::jvm::ReadNativeTempContract(data.data(), data.size(), error);
    std::cout << "contract=" << static_cast<int>(contract) << " error=" << (error ? error : "none") << '\n';
    const int expected = std::stoi(argv[2]);
    if (static_cast<int>(contract) != expected) return 4;
    if (contract == amcl::jvm::NativeTempContract::Invalid && !error) return 7;
    if (argc == 4 && (!error || std::string(error).find(argv[3]) == std::string::npos)) return 8;
    const bool repaired = contract == amcl::jvm::NativeTempContract::StartupTmpdirV1;
    if (amcl::jvm::OmitLegacyTempDefault(contract, "-XX:-UsePerfData") != repaired ||
        amcl::jvm::OmitLegacyTempDefault(contract, "-XX:+DisableAttachMechanism") != repaired ||
        amcl::jvm::OmitLegacyTempDefault(contract, "-XX:+UsePerfData") ||
        amcl::jvm::OmitLegacyTempDefault(contract, "-XX:-DisableAttachMechanism") ||
        amcl::jvm::OmitLegacyTempDefault(contract, "-Xmx128m")) return 5;
    // 调用边界只过滤common默认值；用户显式两项即使与旧默认同字节也照常最后追加。
    const std::vector<std::string> common{"-Xmx128m", "-XX:-UsePerfData", "-XX:+DisableAttachMechanism"};
    const std::vector<std::string> user{"-XX:-UsePerfData", "-XX:+DisableAttachMechanism"};
    std::vector<std::string> assembled;
    for (const auto& value : common)
        if (!amcl::jvm::OmitLegacyTempDefault(contract, value.c_str())) assembled.push_back(value);
    assembled.insert(assembled.end(), user.begin(), user.end());
    if (assembled.size() != (repaired ? 3u : 5u) ||
        assembled[assembled.size() - 2] != user[0] || assembled.back() != user[1]) return 6;
    return 0;
}
