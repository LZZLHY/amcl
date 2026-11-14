/** 真实目录操作验证：幂等准备、原数据保留、符号链接/文件拒绝；不使用OS调用替身。 */
#include "../../entry/src/main/cpp/jvm/game_java_temp_directory.h"
#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>
int main(int argc, char** argv) {
    assert(argc == 2);
    const std::string root = argv[1];
    assert(std::filesystem::create_directory(root));
    std::string error;
    assert(!amcl::jvm::PrepareGameJavaTempDirectory(root + "/missing", error));
    assert(!amcl::jvm::PrepareGameJavaTempDirectory("relative", error));
    assert(amcl::jvm::PrepareGameJavaTempDirectory(root, error));
    const std::string saved = root + "/.amcl/java-tmp/existing";
    std::ofstream(saved) << "keep-shutdown-data";
    assert(amcl::jvm::PrepareGameJavaTempDirectory(root, error));
    std::ifstream input(saved); std::string text; input >> text; assert(text == "keep-shutdown-data"); input.close();
    assert(std::filesystem::remove(saved));
    assert(std::filesystem::remove(root + "/.amcl/java-tmp"));
    std::ofstream(root + "/.amcl/java-tmp") << "user-owned-file";
    assert(!amcl::jvm::PrepareGameJavaTempDirectory(root, error));
    assert(std::filesystem::is_regular_file(root + "/.amcl/java-tmp"));
    assert(std::filesystem::remove(root + "/.amcl/java-tmp"));
    assert(symlink(root.c_str(), (root + "/.amcl/java-tmp").c_str()) == 0);
    assert(!amcl::jvm::PrepareGameJavaTempDirectory(root, error));
    assert(std::filesystem::is_symlink(root + "/.amcl/java-tmp"));
    assert(std::filesystem::remove(root + "/.amcl/java-tmp"));
    assert(std::filesystem::remove(root + "/.amcl"));
    assert(std::filesystem::remove(root));
    std::cout << "PASS actual instance Java temp prepare, retained bytes and invalid child rejection\n";
}
