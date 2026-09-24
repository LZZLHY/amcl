// 在真实 POSIX 文件系统上执行生产发布器，覆盖跨进程 flock、目录原子提交与安全回收。
// 临时目录由 mkdtemp 创建；测试结束只清理自己的根，符号链接外的哨兵必须保持原值。
#include "../../platform/runtime_slot_store.h"
#include "../../platform/graphics_fault_injection.h"
#include "host_test_check.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <signal.h>
#include <ctime>
namespace fs = std::filesystem;
using namespace amcl::runtime;
// 链接器只在测试二进制拦截系统renameat：真正完成旧代退休后杀死发布进程。
// 生产代码没有测试开关，父进程随后用真实维护器恢复这份实际的中断文件系统状态。
static bool killAfterRetirement = false;
extern "C" int __real_renameat(int, const char*, int, const char*);
extern "C" int __wrap_renameat(int a, const char* from, int b, const char* to) {
    const int result = __real_renameat(a, from, b, to);
    if (result == 0 && killAfterRetirement && std::string(to).rfind(".retired-", 0) == 0) kill(getpid(), SIGKILL);
    return result;
}
namespace {
void write(const std::string& file, const std::string& bytes) {
    std::ofstream output(file, std::ios::binary); output << bytes; output.close(); CHECK(output.good());
}
std::string read(const std::string& file) {
    std::ifstream input(file, std::ios::binary); return {std::istreambuf_iterator<char>(input), {}};
}
std::string stage(const std::string& destination, const std::string& hash, const std::string& bytes) {
    std::string error, value = CreateSlotStage(destination, error); CHECK(!value.empty());
    write(value + "/lwjgl.jar", bytes);
    write(value + "/.installed", "amcl.lwjgl.fixture\nmanifest=" + hash + "\n"); return value;
}
void publish(const std::string& destination, const std::string& hash, const std::string& bytes) {
    std::string error, value = stage(destination, hash, bytes);
    CHECK(PublishSlotGeneration(value, destination, error)); CHECK(DiscardSlotStage(value, error));
}
}
int main() {
    char pattern[] = "/tmp/amcl-slot-store-XXXXXX";
    const char* directory = mkdtemp(pattern); CHECK(directory);
    const std::string base(directory), root = base + "/.amcl-runtime";
    fs::create_directory(root);
    // 注入开关必须同时满足开发诊断、指定 profile、短 TTL，且消费一次后不可再次触发。
    write(base + "/graphics-admission-fail-once", "v1\nmobilegl\n1200\n0123456789abcdef\n");
    CHECK(!amcl::graphics::ConsumeGraphicsAdmissionFault(base, "mobilegl", 1000, false));
    CHECK(!amcl::graphics::ConsumeGraphicsAdmissionFault(base, "mobileglues", 1000, true));
    CHECK(!amcl::graphics::ConsumeGraphicsAdmissionFault(base, "mobilegl", 1201, true));
    CHECK(amcl::graphics::ConsumeGraphicsAdmissionFault(base, "mobilegl", 1000, true));
    CHECK(!amcl::graphics::ConsumeGraphicsAdmissionFault(base, "mobilegl", 1000, true));
    const std::string aHash(64, 'a'), bHash(64, 'b'), cHash(64, 'c');
    const std::string a = root + '/' + aHash + "/lwjgl-ohos", b = root + '/' + bHash + "/lwjgl-ohos";
    const std::string c = root + '/' + cHash + "/lwjgl-ohos";
    std::string error;
    CHECK(CreateSlotStage(base + "/lwjgl-ohos", error).empty());
    CHECK(CreateSlotStage(root + "/../" + aHash + "/lwjgl-ohos", error).empty());
    auto incomplete = CreateSlotStage(a, error); CHECK(!incomplete.empty());
    CHECK(!PublishSlotGeneration(incomplete, a, error)); CHECK(!fs::exists(a));
    CHECK(DiscardSlotStage(incomplete, error));
    publish(a, aHash, "original-a");
    CHECK(read(root + "/.active-lwjgl-ohos") == aHash);
    CHECK(!RetireSlotGeneration(a, error));
    auto lease = AcquireSlotGeneration(a, error); CHECK(!lease.empty());
    CHECK(!ReleaseSlotGeneration("999999:1"));
    // 相同内容的重复发布可以复用；不同字节的修复必须等待全部读者退出。
    auto same = stage(a, aHash, "original-a");
    CHECK(PublishSlotGeneration(same, a, error)); CHECK(DiscardSlotStage(same, error));
    auto repair = stage(a, aHash, "repaired-a");
    CHECK(!PublishSlotGeneration(repair, a, error)); CHECK(read(a + "/lwjgl.jar") == "original-a");
    publish(b, bHash, "new-b");
    CHECK(!RetireSlotGeneration(a, error));
    CHECK(ReleaseSlotGeneration(lease)); CHECK(!ReleaseSlotGeneration(lease));
    CHECK(PublishSlotGeneration(repair, a, error)); CHECK(DiscardSlotStage(repair, error));
    CHECK(read(a + "/lwjgl.jar") == "repaired-a");

    // 子进程持有独立租约；父进程不能凭页面退出或本地句柄表为空来删除它。
    int ready[2], resume[2]; CHECK(pipe(ready) == 0 && pipe(resume) == 0);
    const pid_t child = fork(); CHECK(child >= 0);
    if (child == 0) {
        close(ready[0]); close(resume[1]);
        auto childLease = AcquireSlotGeneration(a, error); CHECK(!childLease.empty());
        CHECK(!ReleaseSlotGeneration(lease));
        CHECK(::write(ready[1], "1", 1) == 1); char signal;
        CHECK(::read(resume[0], &signal, 1) == 1);
        // 故意不调用 release，验证进程死亡由内核释放 flock。
        _exit(0);
    }
    close(ready[1]); close(resume[0]); char signal; CHECK(::read(ready[0], &signal, 1) == 1);
    CHECK(PublishSlotGeneration("", b, error));
    CHECK(!RetireSlotGeneration(a, error)); CHECK(fs::exists(a + "/lwjgl.jar"));
    CHECK(::write(resume[1], "1", 1) == 1); int status = 0;
    CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    close(ready[0]); close(resume[1]);
    CHECK(RetireSlotGeneration(a, error)); CHECK(!fs::exists(fs::path(a).parent_path()));
    CHECK(!RetireSlotGeneration(b, error));

    // 未提交目录/跨根发布/非法 marker 不改变已有 active；残留链接不触及根外数据。
    const std::string outside = base + "/outside"; fs::create_directory(outside);
    write(outside + "/sentinel", "keep-me");
    fs::create_directory_symlink(outside, root + '/' + cHash);
    CHECK(AcquireSlotGeneration(c, error).empty()); CHECK(!RetireSlotGeneration(c, error));
    fs::remove(root + '/' + cHash);
    auto bad = stage(c, bHash, "wrong-manifest");
    CHECK(!PublishSlotGeneration(bad, c, error)); CHECK(DiscardSlotStage(bad, error));
    publish(c, cHash, "good-c");
    fs::create_directory_symlink(outside, c + "/nested-link");
    CHECK(PublishSlotGeneration("", b, error)); CHECK(RetireSlotGeneration(c, error));
    CHECK(read(outside + "/sentinel") == "keep-me");
    // 创建端持有独立owner锁；维护端不能删除活stage。真实杀死另一个写入进程后，
    // 内核释放锁，分批GC才能认领孤儿，且一次扫描/尝试/文件操作都服从传入预算。
    const auto liveStage = stage(c, cHash, "still-writing");
    int stageReady[2]; CHECK(pipe(stageReady) == 0);
    const pid_t writer = fork(); CHECK(writer >= 0);
    if (!writer) {
        close(stageReady[0]); const auto orphan = stage(c, cHash, "interrupted-write");
        write(base + "/writer-stage", orphan); CHECK(::write(stageReady[1], "1", 1) == 1);
        for (;;) pause();
    }
    close(stageReady[1]); CHECK(::read(stageReady[0], &signal, 1) == 1); close(stageReady[0]);
    const auto orphan = read(base + "/writer-stage");
    MaintenanceLimits budget; budget.entries = 3; budget.attempts = 1; budget.removals = 1; budget.fileOperations = 2; budget.milliseconds = 1000;
    for (int i = 0; i < 20; ++i) {
        const auto result = CollectSlotGarbage(c, budget);
        CHECK(result.scanned <= 3 && result.attempted <= 1 && result.removed <= 1 && result.fileOperations <= 2);
    }
    CHECK(fs::exists(liveStage) && fs::exists(orphan));
    CHECK(kill(writer, SIGKILL) == 0 && waitpid(writer, &status, 0) == writer && WIFSIGNALED(status));
    for (int i = 0; i < 80 && fs::exists(fs::path(orphan).parent_path()); ++i) CollectSlotGarbage(c, budget);
    CHECK(!fs::exists(fs::path(orphan).parent_path()) && fs::exists(liveStage));
    CHECK(DiscardSlotStage(liveStage, error));
    // 老版本无owner证据的残留和任意目录都不能被清理器猜测为自有缓存。
    fs::create_directories(root + "/.stage-999-999/lwjgl-ohos");
    write(root + "/.stage-999-999/lwjgl-ohos/unowned", "preserve");
    for (int i = 0; i < 20; ++i) CollectSlotGarbage(c, budget);
    CHECK(read(root + "/.stage-999-999/lwjgl-ohos/unowned") == "preserve");
    MaintenanceLimits zero; zero.milliseconds = 0;
    CHECK(CollectSlotGarbage(c, zero).scanned == 0);
    // 恢复票据只删除严格UUID/已知后缀/普通文件/超过24小时的记录；当前身份、未来时间
    // 与符号链接都保留。这里调用同一个生产POSIX维护入口，墙钟是显式边界输入。
    const std::string tickets = base + "/graphics-recovery"; fs::create_directory(tickets);
    const std::string firstId = "01234567-89ab-cdef-0123-456789abcdef", keepId = "11234567-89ab-cdef-0123-456789abcdef";
    write(tickets + '/' + firstId + ".request.json", "{}"); write(tickets + '/' + keepId + ".request.json", "{}");
    write(tickets + "/unknown.json", "keep");
    fs::create_symlink(outside + "/sentinel", tickets + '/' + firstId + ".failure.json");
    const auto now = static_cast<int64_t>(time(nullptr));
    CHECK(CollectGraphicsTickets(tickets, keepId, now - 90000).removed == 0);
    CHECK(CollectGraphicsTickets(tickets, keepId, now + 90000).removed == 1);
    CHECK(fs::exists(tickets + '/' + keepId + ".request.json") && fs::is_symlink(tickets + '/' + firstId + ".failure.json"));
    CHECK(read(outside + "/sentinel") == "keep-me");
    fs::remove(b + "/.installed"); CHECK(mkfifo((b + "/.installed").c_str(), 0600) == 0);
    CHECK(AcquireSlotGeneration(b, error).empty());
    fs::remove(b + "/.installed"); publish(b, bHash, "new-b");
    fs::create_directory(fs::path(b).parent_path() / "unowned");
    publish(c, cHash, "good-c"); CHECK(!RetireSlotGeneration(b, error));
    CHECK(read(outside + "/sentinel") == "keep-me");
    // 只删除系统返回的专属临时根，生产代码的删除范围另由上述对抗场景验证。
    const std::string crashRoot = base + "/publication-crash/.amcl-runtime";
    fs::create_directories(crashRoot);
    const std::string dHash(64, 'd'), eHash(64, 'e');
    const std::string original = crashRoot + '/' + dHash + "/lwjgl-ohos", next = crashRoot + '/' + eHash + "/lwjgl-ohos";
    publish(original, dHash, "old-readable");
    const pid_t publisher = fork(); CHECK(publisher >= 0);
    if (!publisher) { killAfterRetirement = true; publish(original, dHash, "new-repair"); _exit(9); }
    CHECK(waitpid(publisher, &status, 0) == publisher && WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL);
    CHECK(!fs::exists(original) && read(crashRoot + "/.active-lwjgl-ohos") == dHash);
    for (int i = 0; i < 16 && !fs::exists(original); ++i) CollectSlotGarbage(original);
    CHECK(read(original + "/lwjgl.jar") == "old-readable");
    publish(next, eHash, "next-readable");
    write(crashRoot + "/.active-lwjgl-ohos", "corrupted-pointer");
    CHECK(!RetireSlotGeneration(original, error) && fs::exists(original + "/lwjgl.jar"));
    CHECK(fs::canonical(base).parent_path() == fs::canonical("/tmp"));
    CHECK(fs::path(base).filename().string().rfind("amcl-slot-store-", 0) == 0);
    fs::remove_all(base);
    std::cout << "runtime-slot-store PASS: atomic publication, reuse, repair, process leases, death, GC, symlink/FIFO guards\n";
}
