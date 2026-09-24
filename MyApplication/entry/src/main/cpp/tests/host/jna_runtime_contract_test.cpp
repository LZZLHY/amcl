// 真实生产 ZIP/class/冻结实现的命令行探针。仅由宿主测试提供固定本地输入，不启动 JVM。
#include "../../jvm/jna_runtime_contract.h"
#include "../../jvm/runtime_bootstrap_contract.h"
#include <iostream>

int main(int argc, char** argv) {
    if (argc == 3 && std::string(argv[1]) == "read") {
        std::string protocol, reason;
        const bool ok = amcl::jvm::ReadJnaVersionFromJar(argv[2], protocol, reason);
        std::cout << ok << '|' << protocol << '|' << reason;
        return 0;
    }
    if (argc == 4 && std::string(argv[1]) == "resolve") {
        const auto selected = amcl::jvm::ResolveJnaBootstrap(argv[2], argv[3]);
        auto properties = amcl::jvm::RuntimeBootstrapProperties(argv[3], "/game", "mobileglues", "libhost.so", false, selected);
        std::vector<std::string> arguments;
        std::string error;
        if (!amcl::jvm::FreezeBootstrapProperties(arguments, properties, error)) return 2;
        // 无论 selected/deferred，真正冻结到 JVM 的都必须是同一计划，不借旧固定库覆盖。
        const auto has = [&](const std::string& value) { return std::find(arguments.begin(), arguments.end(), value) != arguments.end(); };
        if (!has("-Djna.boot.library.name=" + selected.bootLibraryName) ||
            !has("-Djna.boot.library.path=" + selected.bootLibraryPath) || !has("-Djna.nosys=true")) return 3;
        arguments.push_back("-Djna.boot.library.name=unsafe-other");
        if (amcl::jvm::FreezeBootstrapProperties(arguments, properties, error)) return 4;
        std::cout << selected.ok << '|' << selected.mode << '|' << selected.bootLibraryName << '|'
                  << selected.protocol << '|' << selected.reason << '|' << selected.bootLibraryPath;
        return 0;
    }
    return 1;
}
