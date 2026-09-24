/** 使用真实 fd 验证会话原件、初始化窗口与失败状态，不访问设备或用户游戏目录。 */
#include "../../utils/session_log_io.h"
#include <filesystem>
#include <fstream>
#include <sstream>
#include <cstdlib>

static std::string readFile(const std::string& path) {
    std::ifstream file(path, std::ios::binary); std::ostringstream out; out << file.rdbuf(); return out.str();
}
static void require(bool ok, const char* why) { if (!ok) { std::fprintf(stderr, "FAIL %s\n", why); std::exit(1); } }
int main(int argc, char** argv) {
    if (argc != 3) return 2;
    using namespace amcl::sessionlog;
    const std::string root = argv[1], mode = argv[2];
    std::filesystem::create_directories(root);
    if (mode == "failed-open") {
        { std::ofstream file(root + "/logs"); file << "not a directory"; }
        require(!prepare(root.c_str(), 101), "blocked directory must not report ready");
        require(state.consoleFd < 0 && state.error.load() != 0, "failed open must retain failure");
    } else {
        const int savedOut = duplicate(1), savedErr = duplicate(2);
        require(prepare(root.c_str(), 101), "prepare");
        require(prepare(root.c_str(), 101), "same attempt is idempotent");
        require(!prepare(root.c_str(), 102), "different attempt cannot reuse owned output");
        writeAll(1, "BEFORE_JVM\n", 11);
        const int console = duplicate(1);
        const int init = openFile(jvmPath());
        require(init >= 0 && redirect(init, 1) && redirect(init, 2), "init redirect");
        writeAll(1, "JNI_WINDOW\n", 11); syncFd(init);
        require(redirect(console, 1) && redirect(console, 2), "restore console");
        closeFd(init); closeFd(console);
        javaReady(); gameReady();
        for (int i = 0; i < 3000; ++i) {
            const std::string line = "SEQ=" + std::to_string(i) + "\n";
            require(writeAll(1, line.c_str(), line.size()), "write sequence");
        }
        if (mode == "normal") finish();
        require(redirect(savedOut, 1) && redirect(savedErr, 2), "restore test output");
        closeFd(savedOut); closeFd(savedErr);
        const std::string body = readFile(state.console);
        require(body.find("BEFORE_JVM") != std::string::npos && body.find("SEQ=2999\n") != std::string::npos, "full console boundaries");
        for (int i = 0; i < 3000; ++i) require(body.find("SEQ=" + std::to_string(i) + "\n") != std::string::npos, "sequence missing");
        require(body.find("JNI_WINDOW") == std::string::npos, "init output must retain its own source");
        require(readFile(state.jvm) == "JNI_WINDOW\n", "initialization window preserved");
        require(readFile(state.status).find(mode == "normal" ? "\"ended\":true" : "\"ended\":false") != std::string::npos, "close evidence");
    }
    std::printf("PASS session raw IO %s\n", mode.c_str());
    return 0;
}
