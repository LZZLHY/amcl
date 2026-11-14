/** 宿主真实libc验证：只在本测试mkdtemp创建的Linux目录与探针自己的/tmp nonce内操作。
 * 结果写调用方外置输出。全部合成固定字节，无设备、无VM、无网络端点、无用户文件读取。
 */
#include "native_temp_probe.h"
#include "../../entry/src/main/cpp/napi/jdk_native_temp_qualification.h"
#include <cassert>
#include <fstream>

namespace probe = amcl::nativetempprobe;
static void save(const std::string& folder, const char* name, const std::string& body) {
    std::ofstream output(folder + '/' + name, std::ios::binary); assert(output); output << body; assert(output.good());
}

int main(int argc, char** argv) {
    assert(argc == 2);
    const std::string output = argv[1];
    char pattern[] = "/tmp/amcl-native-temp-host-XXXXXX";
    char* made = mkdtemp(pattern); assert(made);
    const std::string path(made);
    probe::Fd root(open(path.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)); assert(root.value >= 0);
    save(output, "normal.json", probe::Run(root.value, path, "host-normal"));

    // 碰撞时必须拒绝，不检查或删除已有目录内容。sentinel由本测试自己创建/核对。
    const std::string collided = ".nt-host-collision-" + std::to_string(getpid());
    assert(mkdirat(root.value, collided.c_str(), 0700) == 0);
    probe::Fd collision(openat(root.value, collided.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)); assert(collision.value >= 0);
    probe::Fd marker(openat(collision.value, "keep", O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600)); assert(marker.value >= 0);
    const char kept[] = "kept"; assert(write(marker.value, kept, 4) == 4);
    save(output, "collision.json", probe::Root(root.value, path, "host-collision", true, probe::Clock::now() + std::chrono::seconds(5)));
    struct stat after{}; assert(fstatat(collision.value, "keep", &after, AT_SYMLINK_NOFOLLOW) == 0 && after.st_size == 4);
    assert(unlinkat(collision.value, "keep", 0) == 0); assert(unlinkat(root.value, collided.c_str(), AT_REMOVEDIR) == 0);

    // 保留正常文件/mmap观察，长Unix地址必须在bind前准确拒绝，不截成另一地址。
    const std::string component(100, 'x');
    assert(mkdirat(root.value, component.c_str(), 0700) == 0);
    probe::Fd deep(openat(root.value, component.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)); assert(deep.value >= 0);
    save(output, "long-socket.json", probe::Root(deep.value, path + '/' + component, "host-long", true,
                                                probe::Clock::now() + std::chrono::seconds(5)));
    assert(unlinkat(root.value, component.c_str(), AT_REMOVEDIR) == 0);
    bool rejected = false;
    try { (void)probe::Run(root.value, path, "../bad"); } catch (const std::runtime_error&) { rejected = true; }
    assert(rejected);
    save(output, "invalid-input.json", "{\"rejectedBeforeProbe\":true}\n");

    save(output, "expired-deadline.json", probe::Root(root.value, path, "host-expired", true,
        probe::Clock::now() - std::chrono::milliseconds(1)));
    int pipefd[2]; assert(pipe2(pipefd, O_CLOEXEC | O_NONBLOCK) == 0);
    probe::Fd reader(pipefd[0]), writer(pipefd[1]);
    probe::Calls waiting;
    const auto began = probe::Clock::now();
    const bool readable = probe::Wait(waiting, reader.value, POLLIN, began + std::chrono::milliseconds(10));
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(probe::Clock::now() - began).count();
    assert(!readable && elapsed < 1000);
    save(output, "bounded-poll.json", "{\"ready\":false,\"elapsedMillis\":" + std::to_string(elapsed) +
        ",\"calls\":" + waiting.Json() + "}\n");

    // 用当前桥的真实目录合同读根、写独占报告；再次调用必须在OS观察之前被O_EXCL挡住。
    assert(mkdirat(root.value, "jdk-runtime-qualification", 0700) == 0);
    probe::Fd group(openat(root.value, "jdk-runtime-qualification", O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    assert(group.value >= 0 && mkdirat(group.value, "native-temp-host", 0700) == 0);
    probe::Fd qualification(openat(group.value, "native-temp-host", O_RDONLY | O_DIRECTORY | O_CLOEXEC)); assert(qualification.value >= 0);
    assert(mkdirat(qualification.value, "run-25", 0700) == 0);
    probe::Fd run(openat(qualification.value, "run-25", O_RDONLY | O_DIRECTORY | O_CLOEXEC)); assert(run.value >= 0);
    const std::string roots = "AMCL-PERM-ROOTS-1\n" + path + "\n\nenvironment\n";
    probe::Fd record(openat(qualification.value, "permission-roots.txt", O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600));
    assert(record.value >= 0 && write(record.value, roots.data(), roots.size()) == ssize_t(roots.size()));
    const std::string rootPath = path + "/jdk-runtime-qualification/native-temp-host";
    save(output, "bridge.json", amcl::jdkqualification::RunNativeTempQualification(qualification.value, run.value, rootPath));
    rejected = false;
    try { (void)amcl::jdkqualification::RunNativeTempQualification(qualification.value, run.value, rootPath); }
    catch (const std::exception&) { rejected = true; }
    assert(rejected);
    save(output, "duplicate-report.json", "{\"duplicateRejected\":true}\n");
    assert(unlinkat(run.value, "native-temp-report.json", 0) == 0);
    // 同为真实存在的目录仍不能冒充本应用filesDir，先于报告创建和OS观察拒绝。
    const std::string wrongRoots = "AMCL-PERM-ROOTS-1\n/tmp\n\nenvironment\n";
    assert(ftruncate(record.value, 0) == 0 && pwrite(record.value, wrongRoots.data(), wrongRoots.size(), 0) == ssize_t(wrongRoots.size()));
    rejected = false;
    try { (void)amcl::jdkqualification::RunNativeTempQualification(qualification.value, run.value, rootPath); }
    catch (const std::exception&) { rejected = true; }
    assert(rejected && fstatat(run.value, "native-temp-report.json", &after, AT_SYMLINK_NOFOLLOW) < 0 && errno == ENOENT);
    save(output, "wrong-root.json", "{\"wrongRootRejectedBeforeProbe\":true}\n");
    assert(unlinkat(qualification.value, "permission-roots.txt", 0) == 0);
    assert(unlinkat(qualification.value, "run-25", AT_REMOVEDIR) == 0);
    assert(unlinkat(group.value, "native-temp-host", AT_REMOVEDIR) == 0);
    assert(unlinkat(root.value, "jdk-runtime-qualification", AT_REMOVEDIR) == 0);
    // Linux允许移除仍打开的空目录；Fd析构随后关闭。rmdir成功同时证明没有probe残留。
    assert(rmdir(path.c_str()) == 0);
    save(output, "host-complete.json", "{\"hostOnly\":true,\"ownedScratchRemoved\":true,\"vmStarted\":false}\n");
    return 0;
}
