/**
 * 直接运行生产原生临时根准备/环境对象，不复制其实现。
 * 标准QA提供独占且较短的绝对输出根，所有目录/文件均留在该根内；不写系统/tmp。
 * 环境只影响本测试子进程。setenv/unsetenv故障由链接器包装真实libc，恢复失败也须报告。
 * 本例不创建VM：retainAfterVmEntry只验证生命周期合同，真实目标Attach/PerfData另行验收。
 */
#include "../../entry/src/main/cpp/jvm/jdk_native_temp_preparation.h"
#include <cstdio>
#include <cstdlib>
#include <dirent.h>
#include <thread>
#include <vector>
extern "C" int __real_setenv(const char*, const char*, int);
extern "C" int __real_unsetenv(const char*);
static bool failSet, failUnset;
extern "C" int __wrap_setenv(const char* name, const char* value, int overwrite) {
    if (failSet) { errno = ENOMEM; return -1; }
    return __real_setenv(name, value, overwrite);
}
extern "C" int __wrap_unsetenv(const char* name) {
    if (failUnset) { errno = ENOMEM; return -1; }
    return __real_unsetenv(name);
}
// 故障开关仅由主测试线程使用，8线程目录竞争已全部join后才开始环境用例。
static int rollbackError;
static void report(int error) { rollbackError = error; }
static void check(bool value, const char* reason) {
    if (!value) { std::fprintf(stderr, "FAIL %s\n", reason); std::exit(1); }
}
// /proc/self/fd只读计数用来核查成功/失败prepare后的RAII关闭，不依赖私有fd字段。
static int descriptors() {
    DIR* list = opendir("/proc/self/fd"); check(list != nullptr, "fd list");
    int count = 0;
    while (dirent* item = readdir(list)) if (item->d_name[0] != '.') ++count;
    check(closedir(list) == 0, "fd list close");
    return count;
}
int main(int argc, char** argv) {
    using namespace amcl::jvm;
    check(argc == 4 && argv[1][0] == '/', "output root, repaired ELF and legacy ELF required");
    std::string pattern = std::string(argv[1]) + "/root-XXXXXX";
    std::vector<char> storage(pattern.begin(), pattern.end()); storage.push_back(0);
    char* work = mkdtemp(storage.data());
    check(work != nullptr, "unique output-owned POSIX root");
    const std::string root = work;
    const int initialDescriptors = descriptors();
    chmod(work, 0770); // OHOS现有appFilesDir为同UID/GID的0770，不能误要求父目录0700。
    {
        PreparedNativeTempRoot prepared;
        check(prepared.prepare(work, nullptr) == 0 && prepared.path() == root + "/tmp", "trusted short root");
        struct stat info{};
        check(stat(prepared.path().c_str(), &info) == 0 && (info.st_mode & 0777) == 0700, "new private child mode");
    }
    {
        PreparedNativeTempRoot prepared;
        check(prepared.prepare("/unused-parent", (root + "/tmp/").c_str()) == 0, "explicit non-AMCL owned directory accepted");
    }
    // 真机系统TMPDIR为0777缓存根；嵌入策略必须选可信filesDir/tmp，不能放宽私有子目录权限。
    // 同时覆盖不存在和相对继承值，证明策略不靠硬编码系统路径；prepare阶段不修改环境。
    const std::string cache = root + "/cache";
    check(mkdir(cache.c_str(), 0777) == 0 && chmod(cache.c_str(), 0777) == 0, "ambient cache fixture");
    for (const auto& ambient : {cache, root + "/missing-ambient", std::string("relative-ambient")}) {
        check(__real_setenv("TMPDIR", ambient.c_str(), 1) == 0, "set inherited environment");
        PreparedNativeTempRoot prepared;
        NativeTempPreparationTrace trace;
        check(prepared.prepareEmbedded(work, &trace) == 0 && prepared.path() == root + "/tmp",
              "embedded root independent of inherited system environment");
        check(!trace.requestedPresent && !trace.explicitRoot && std::string(trace.stage) == "ready",
              "trace describes selected input instead of claiming ambient is user supplied");
        check(std::string(getenv("TMPDIR")) == ambient, "prepare must preserve inherited environment");
        { NativeTempEnvironment env(report); check(env.publish(prepared.path()) == 0, "publish embedded root"); }
        check(std::string(getenv("TMPDIR")) == ambient, "pre-VM failure restores exact inherited environment");
    }
    check(__real_unsetenv("TMPDIR") == 0, "restore test environment");
    // 每个负例只变目录输入；普通文件/链接预先创建一次并核返回，避免EEXIST掩盖夹具错误。
    FILE* fixture = fopen((root + "/file").c_str(), "w");
    check(fixture != nullptr && fclose(fixture) == 0, "file fixture");
    check(symlink((root + "/tmp").c_str(), (root + "/link").c_str()) == 0, "directory link fixture");
    for (const auto& input : {std::string("relative"), root + "/missing", root + "/file", root + "/link/"}) {
        PreparedNativeTempRoot rejected;
        check(rejected.prepare(work, input.c_str()) != 0, "explicit invalid root must reject, never fallback");
    }
    chmod((root + "/tmp").c_str(), 0777);
    { PreparedNativeTempRoot rejected; check(rejected.prepare(work, nullptr) == EACCES, "writable by other users"); }
    chmod((root + "/tmp").c_str(), 0500);
    { PreparedNativeTempRoot rejected; check(rejected.prepare(work, nullptr) == EACCES, "owner cannot write"); }
    chmod((root + "/tmp").c_str(), 0700);
    // fd仍持有旧目录时，名字被替换必须ESTALE；不能仅因新目录权限相同就重新授资格。
    {
        PreparedNativeTempRoot prepared;
        check(prepared.prepare(work, nullptr) == 0 && prepared.revalidate() == 0, "initial final path identity");
        check(rename((root + "/tmp").c_str(), (root + "/old-tmp").c_str()) == 0, "rename fixture");
        check(mkdir((root + "/tmp").c_str(), 0700) == 0, "replacement fixture");
        check(prepared.revalidate() == ESTALE, "replacement must fail before environment publication");
    }
    // Linux/OHOS sockaddr_un为108字节，两个地址合同包含最大PID及结尾NUL。
    check(PreparedNativeTempRoot::addressBudget(std::string(66, 'x')) == 0, "maximum namespace byte budget");
    check(PreparedNativeTempRoot::addressBudget(std::string(67, 'x')) == ENAMETOOLONG, "namespace address includes NUL");
    { PreparedNativeTempRoot rejected; check(rejected.prepare(work, ("/" + std::string(83, 'x')).c_str()) == ENAMETOOLONG,
        "explicit listener temporary name overflow must reject before filesystem"); }
    // 同一父根的竞争初始化仍打开/验证同一子对象，不覆盖EEXIST对象或跟随链接。
    std::vector<int> outcomes(8, -1);
    std::vector<std::thread> workers;
    for (size_t i = 0; i < outcomes.size(); ++i) workers.emplace_back([&, i] {
        PreparedNativeTempRoot prepared; outcomes[i] = prepared.prepare(work, nullptr);
    });
    for (auto& worker : workers) worker.join();
    for (int result : outcomes) check(result == 0, "concurrent identity preparation");

    check(descriptors() == initialDescriptors, "prepare success/failure and worker descriptors all released");
    // 缺席、空串和正文是三种不同原状态，CreateVM前早退必须精确恢复，不能统一unset。
    __real_unsetenv("TMPDIR");
    { NativeTempEnvironment env(report); check(env.publish(root) == 0, "publish absent"); }
    check(getenv("TMPDIR") == nullptr, "restore original absence");
    __real_setenv("TMPDIR", "", 1);
    { NativeTempEnvironment env(report); check(env.publish(root) == 0, "publish from empty"); }
    check(getenv("TMPDIR") && !getenv("TMPDIR")[0], "restore original empty");
    __real_setenv("TMPDIR", "/original", 1);
    { NativeTempEnvironment env(report); check(env.publish(root) == 0, "publish existing"); }
    check(std::string(getenv("TMPDIR")) == "/original", "restore original value");
    { NativeTempEnvironment env(report); failSet = true; check(env.publish(root) == ENOMEM, "publication failure"); failSet = false; }
    check(std::string(getenv("TMPDIR")) == "/original", "failed publication preserves environment");
    // 一旦进入CreateJavaVM，即使其返回失败也可能已经有线程，不能再改回TMPDIR。
    { NativeTempEnvironment env(report); check(env.publish(root) == 0, "publish for VM"); env.retainAfterVmEntry(); }
    check(std::string(getenv("TMPDIR")) == root, "VM entry failure still retains root");
    __real_setenv("TMPDIR", "/original", 1);
    { NativeTempEnvironment env(report); check(env.publish(root) == 0, "rollback failure fixture"); failSet = true; }
    failSet = false;
    check(rollbackError == ENOMEM, "rollback error surfaced instead of claimed success");
    rollbackError = 0;
    __real_unsetenv("TMPDIR");
    { NativeTempEnvironment env(report); check(env.publish(root) == 0, "unset failure fixture"); failUnset = true; }
    failUnset = false;
    check(rollbackError == ENOMEM, "unset rollback error surfaced");
    __real_unsetenv("TMPDIR");
    // 冷路径实际open/mmap读取文件；正确marker和合法无marker映像分别走新旧合同。
    std::string error;
    check(ReadNativeTempContractFile(argv[2], error) == NativeTempContract::StartupTmpdirV1, "linked marker file");
    error.clear();
    check(ReadNativeTempContractFile(argv[3], error) == NativeTempContract::Legacy, "linked markerless file");
    const std::string alias = root + "/jvm-link";
    check(symlink(argv[2], alias.c_str()) == 0, "linked file symlink fixture");
    error.clear();
    check(ReadNativeTempContractFile(alias, error) == NativeTempContract::Invalid && !error.empty(), "contract file refuses final symlink");
    error.clear();
    check(ReadNativeTempContractFile(root, error) == NativeTempContract::Invalid && !error.empty(), "contract file refuses directory");
    error.clear();
    check(ReadNativeTempContractFile(root + "/file", error) == NativeTempContract::Invalid && !error.empty(), "contract file refuses empty file");
    check(descriptors() == initialDescriptors, "contract read success/failure closes fd and mapping");
    // 只含几个空目录/小文件，保留在独占输出，便于失败审查，不递归删除测试证据。
    std::puts("PASS host root/identity/races/explicit failure/absence-empty-value rollback/entry-retain/fault reports");
}
