/** 直接编译生产探针核心；执行真实宿主子程序，AArch64真实PIE只用于解析/摘要，不在宿主执行。 */
#include "jvm/processor_exec_probe.h"
#include <cassert>
#include <fstream>
#include <iterator>

namespace probe = amcl::jvm::execprobe;

int main(int argc, char** argv) {
    if (argc == 3 && !strcmp(argv[1], "--closed-stdio")) {
        // 在独立exec后的测试进程关闭stdio，验证管道FD不会覆盖/关闭自己的重定向目标。
        close(0); close(1); close(2);
        const auto got = probe::execute(argv[2], {argv[2], "marker"});
        return got.waited == got.pid && WIFEXITED(got.rawStatus) && WEXITSTATUS(got.rawStatus) == 7 &&
               probe::marker(got, getpid()) ? 0 : 96;
    }
    assert(argc == 4);
    const std::string child(argv[1]), armImage(argv[2]), output(argv[3]);
    const auto image = probe::inspect(armImage);
    assert(image.interpreter == "/lib/ld-musl-aarch64.so.1" && image.sha256.size() == 64 && image.bytes > 0);
    for (const auto& scenario : {"marker", "exit255", "sigbus", "flood", "hang", "infinite-flood"}) {
        const auto got = probe::execute(child, {child, scenario}, 100);
        assert(!got.spawnError && !got.waitError && got.pid > 0 && got.waited == got.pid);
        if (!strcmp(scenario, "sigbus")) assert(WIFSIGNALED(got.rawStatus) && WTERMSIG(got.rawStatus) == SIGBUS);
        else if (!strcmp(scenario, "hang") || !strcmp(scenario, "infinite-flood"))
            assert(got.timedOut && !got.killError && WIFSIGNALED(got.rawStatus) && WTERMSIG(got.rawStatus) == SIGKILL);
        else assert(WIFEXITED(got.rawStatus) && WEXITSTATUS(got.rawStatus) == (!strcmp(scenario, "exit255") ? 255 : 7));
        if (!strcmp(scenario, "marker")) assert(probe::marker(got, getpid()));
        if (!strcmp(scenario, "flood") || !strcmp(scenario, "infinite-flood")) assert(got.overflow && got.output.size() == 4096);
        std::ofstream report(output + "/" + scenario + ".json");
        report << probe::describe(scenario, child, {child, scenario}, got, getpid());
        assert(report.good());
    }
    const auto missing = probe::execute(output + "/missing", {output + "/missing"});
    assert(missing.spawnError == ENOENT && missing.waited == -1 && !missing.timedOut);
    const auto closed = probe::execute(argv[0], {argv[0], "--closed-stdio", child});
    assert(!closed.spawnError && closed.waited == closed.pid && WIFEXITED(closed.rawStatus) && WEXITSTATUS(closed.rawStatus) == 0);
    // 原件只读；坏样本独占落在仓外目录。格式或解释器不合格时不得尝试exec。
    std::ifstream original(armImage, std::ios::binary);
    const std::string bytes{std::istreambuf_iterator<char>(original), std::istreambuf_iterator<char>()};
    for (int kind = 0; kind < 4; ++kind) {
        std::string bad = bytes;
        if (kind == 0) bad.resize(8);
        else if (kind == 1) bad[EI_CLASS] = ELFCLASS32;
        else if (kind == 2) { Elf64_Ehdr header{}; memcpy(&header, bad.data(), sizeof(header)); header.e_phoff = ~uint64_t{0}; memcpy(bad.data(), &header, sizeof(header)); }
        else { const auto position = bad.find("/lib/ld-musl-aarch64.so.1"); assert(position != std::string::npos); bad[position + 1] = 'x'; }
        const std::string path = output + "/bad-" + std::to_string(kind);
        { std::ofstream file(path, std::ios::binary); file.write(bad.data(), bad.size()); assert(file.good()); }
        bool rejected = false; try { probe::inspect(path); } catch (const std::exception&) { rejected = true; }
        assert(rejected);
    }
    int status = 0; assert(waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD);
    puts("PASS fixed exec route: 6 real child outcomes, ENOENT, closed stdio, 4 rejected ELF inputs; no child left");
}
