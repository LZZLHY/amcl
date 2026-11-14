/** 宿主/显式测试入口：只测传入的自有根；JSON写出成功不代表目标设备能力通过。 */
#include "native_time_probe.h"
#include <fstream>
#include <iostream>
int main(int argc, char** argv) {
    if (argc != 4) return 2;
    try {
        const std::string report = amcl::nativetimeprobe::Run(argv[1], argv[2]);
        std::ofstream output(argv[3], std::ios::binary | std::ios::out);
        if (!output) return 3;
        output << report << '\n'; output.flush();
        if (!output) return 4;
        std::cout << "Native time observation complete; inspect per-operation errno and attributes\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n'; return 1;
    }
}
