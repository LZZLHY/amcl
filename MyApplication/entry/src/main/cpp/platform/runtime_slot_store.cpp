// 不可变 LWJGL 槽的 POSIX 发布/占用/回收边界。所有删除从已验证的目录 fd 相对执行，
// 不跟随 managed 子树中的符号链接；游戏持共享 lease，发布/GC 用目录锁和独占 lease。
#include "runtime_slot_store.h"
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <map>
#include <mutex>
#include <set>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>
#include <chrono>
#include <vector>

namespace amcl::runtime {
namespace {
struct File {
    int fd = -1;
    explicit File(int value = -1) : fd(value) {}
    ~File() { if (fd >= 0) close(fd); }
    File(const File&) = delete; File& operator=(const File&) = delete;
    File(File&& other) noexcept : fd(std::exchange(other.fd, -1)) {}
    explicit operator bool() const { return fd >= 0; }
    int take() { return std::exchange(fd, -1); }
};
struct Path {
    std::string base, root, generation, slot;
};
bool component(const std::string& value) {
    if (value.empty() || value.size() > 96) return false;
    for (char c : value) if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_')) return false;
    return true;
}
bool parse(const std::string& directory, bool stage, Path& result, std::string& error) {
    const std::string marker = "/.amcl-runtime/";
    const auto at = directory.rfind(marker);
    if (directory.size() > 4096 || directory.find('\0') != std::string::npos || directory.empty() || directory[0] != '/' ||
        directory.find("/../") != std::string::npos || directory.find("/./") != std::string::npos || at == std::string::npos || at == 0) {
        error = "invalid_runtime_slot_path"; return false;
    }
    const auto slash = directory.find('/', at + marker.size());
    if (slash == std::string::npos || directory.find('/', slash + 1) != std::string::npos) {
        error = "invalid_runtime_slot_components"; return false;
    }
    result.base = directory.substr(0, at); result.root = result.base + "/.amcl-runtime";
    result.generation = directory.substr(at + marker.size(), slash - at - marker.size());
    result.slot = directory.substr(slash + 1);
    bool identity = result.generation.size() == 64;
    for (char c : result.generation) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) identity = false;
    if (stage) identity = result.generation.rfind(".stage-" + std::to_string(getpid()) + "-", 0) == 0 && component(result.generation.substr(7));
    if (!identity || !component(result.slot)) { error = "invalid_runtime_slot_identity"; return false; }
    return true;
}
File openRoot(const Path& path) {
    File base(open(path.base.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
    return File(base ? openat(base.fd, ".amcl-runtime", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) : -1);
}
File openDirectory(int parent, const std::string& name) { return File(openat(parent, name.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)); }
File lockFile(int directory, const char* name, int operation) {
    File file(openat(directory, name, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600));
    if (!file) return File();
    int result; do { result = flock(file.fd, operation | LOCK_NB); } while (result < 0 && errno == EINTR);
    if (result != 0) return File();
    return file;
}
bool failed(std::string& error, const char* stage) { error = std::string(stage) + ":" + std::strerror(errno); return false; }
bool readSmall(int directory, const std::string& name, std::string& result) {
    // 非阻塞打开再核验 regular 类型，损坏缓存里的 FIFO 不能让启动线程无限等待。
    File file(openat(directory, name.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW));
    if (!file) return false;
    struct stat info{};
    if (fstat(file.fd, &info) != 0 || !S_ISREG(info.st_mode)) return false;
    char bytes[4097]; const ssize_t length = read(file.fd, bytes, sizeof(bytes));
    if (length < 0 || length >= static_cast<ssize_t>(sizeof(bytes))) return false;
    result.assign(bytes, static_cast<std::size_t>(length)); return true;
}
bool markerMatches(int directory, const std::string& generation) {
    std::string marker;
    return readSmall(directory, ".installed", marker) && marker.rfind("amcl.lwjgl.", 0) == 0 &&
        marker.find("manifest=" + generation + "\n") != std::string::npos;
}
// 只比较 regular JAR 与提交 marker；.lease 是控制文件，不属于运行字节。无需另引入一套 SHA 实现。
bool sameFiles(int a, int b) {
    auto names = [](int directory) {
        std::set<std::string> result;
        File iteration(openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC));
        DIR* stream = iteration ? fdopendir(iteration.fd) : nullptr; if (!stream) return result;
        iteration.take();
        while (const auto* entry = readdir(stream)) {
            std::string name = entry->d_name;
            if (name == ".installed" || (name.size() > 4 && name.substr(name.size() - 4) == ".jar")) result.insert(name);
        }
        closedir(stream); return result;
    };
    const auto entries = names(a);
    if (entries.empty() || entries != names(b)) return false;
    for (const auto& name : entries) {
        File left(openat(a, name.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW));
        File right(openat(b, name.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW));
        if (!left || !right) return false;
        struct stat leftInfo{}, rightInfo{};
        if (fstat(left.fd, &leftInfo) || fstat(right.fd, &rightInfo) ||
            !S_ISREG(leftInfo.st_mode) || !S_ISREG(rightInfo.st_mode)) return false;
        char x[65536], y[65536];
        while (true) {
            const auto lx = read(left.fd, x, sizeof(x)), ly = read(right.fd, y, sizeof(y));
            if (lx < 0 || ly != lx || (lx && std::memcmp(x, y, static_cast<std::size_t>(lx)))) return false;
            if (!lx) break;
        }
    }
    return true;
}
struct MaintenanceBudget {
    MaintenanceLimits limits;
    MaintenanceResult result;
    const std::chrono::steady_clock::time_point start = std::chrono::steady_clock::now();
    explicit MaintenanceBudget(const MaintenanceLimits& value = {}) : limits(value) {}
    bool timeAvailable() {
        if (std::chrono::steady_clock::now() - start >= std::chrono::milliseconds(limits.milliseconds)) result.exhausted = true;
        return !result.exhausted;
    }
    bool fileOperation() {
        if (!timeAvailable() || result.fileOperations >= limits.fileOperations) { result.exhausted = true; return false; }
        ++result.fileOperations; return true;
    }
};
bool removeContents(int directory, MaintenanceBudget& budget, unsigned depth = 0) {
    if (depth > 8 || !budget.timeAvailable()) return false;
    // openat(".") 建立独立目录游标；dup 会共享 readdir 偏移，复查后可能错误跳过全部内容。
    File iteration(openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    DIR* stream = iteration ? fdopendir(iteration.fd) : nullptr; if (!stream) return false;
    iteration.take();
    bool success = true;
    while (const auto* entry = readdir(stream)) {
        const std::string name = entry->d_name;
        if (name == "." || name == "..") continue;
        // 所有权证据最后删。预算中止或进程被杀时，下一次仍能验证剩余目录属于本协议。
        if (name == ".lease" || (depth == 0 && (name == ".owner" || name == ".retired-owner"))) continue;
        if (!budget.fileOperation()) { success = false; break; }
        struct stat info{};
        if (fstatat(directory, name.c_str(), &info, AT_SYMLINK_NOFOLLOW) != 0) { success = false; break; }
        if (S_ISDIR(info.st_mode)) {
            File nested = openDirectory(directory, name);
            if (!nested || !removeContents(nested.fd, budget, depth + 1) || unlinkat(directory, name.c_str(), AT_REMOVEDIR) != 0) { success = false; break; }
        } else if (unlinkat(directory, name.c_str(), 0) != 0) { success = false; break; }
    }
    closedir(stream);
    if (success && unlinkat(directory, ".lease", 0) != 0 && errno != ENOENT) success = false;
    if (success && depth == 0) {
        for (const char* marker : {".owner", ".retired-owner"})
            if (unlinkat(directory, marker, 0) != 0 && errno != ENOENT) success = false;
    }
    return success;
}
bool removeContents(int directory) { MaintenanceBudget budget; return removeContents(directory, budget); }
bool onlySlot(int directory, const std::string& slot) {
    File iteration(openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    DIR* stream = iteration ? fdopendir(iteration.fd) : nullptr; if (!stream) return false;
    iteration.take(); bool valid = true;
    while (const auto* entry = readdir(stream)) {
        const std::string name = entry->d_name;
        if (name != "." && name != ".." && name != slot && name != ".owner" && name != ".retired-owner") { valid = false; break; }
    }
    closedir(stream); return valid;
}
std::atomic<uint64_t> nonce{0};
std::string unique(const char* prefix) { return std::string(prefix) + std::to_string(getpid()) + "-" + std::to_string(++nonce); }
bool activate(int root, const Path& path) {
    const std::string name = ".active-" + path.slot;
    std::string previous;
    if (readSmall(root, name, previous) && previous == path.generation) return fsync(root) == 0;
    const std::string temporary = unique(".active-tmp-");
    File file(openat(root, temporary.c_str(), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0600));
    if (!file) return false;
    const bool written = write(file.fd, path.generation.data(), path.generation.size()) == static_cast<ssize_t>(path.generation.size()) && fsync(file.fd) == 0;
    if (!written || renameat(root, temporary.c_str(), root, name.c_str()) != 0) { unlinkat(root, temporary.c_str(), 0); return false; }
    return fsync(root) == 0;
}
struct Leases {
    const int pid = getpid(); std::mutex mutex; uint64_t next = 0; std::map<uint64_t, int> files;
    std::map<std::string, int> stages;
    // 同一目录的有界维护在后续调用接着走；不反复从前128个未知条目开始造成永久饥饿。
    std::map<std::string, DIR*> cursors;
};
Leases& leases() {
    static std::atomic<Leases*> value{new Leases}; auto* current = value.load();
    if (current->pid != getpid()) {
        auto* next = new Leases;
        if (value.compare_exchange_strong(current, next)) current = next; else delete next;
    }
    return *current;
}
bool stageOwned(const std::string& path) {
    auto& state = leases(); std::lock_guard<std::mutex> lock(state.mutex);
    return state.stages.count(path) != 0;
}
void releaseStage(const std::string& path) {
    auto& state = leases(); std::lock_guard<std::mutex> lock(state.mutex);
    const auto item = state.stages.find(path);
    if (item != state.stages.end()) { close(item->second); state.stages.erase(item); }
}
bool ownerMarker(int directory, const char* name, const Path& path) {
    File owner(openat(directory, name, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0600));
    if (!owner) return false;
    const std::string body = "amcl-slot-owner-v1\n" + path.generation + '\n' + path.slot + '\n';
    return write(owner.fd, body.data(), body.size()) == static_cast<ssize_t>(body.size()) && fsync(owner.fd) == 0 && fsync(directory) == 0;
}
}

std::string CreateSlotStage(const std::string& destination, std::string& error) {
    Path path; if (!parse(destination, false, path, error)) return {};
    File root = openRoot(path); if (!root) { failed(error, "slot_root_open"); return {}; }
    // 创建目录到发布owner锁之间必须持全局发布锁，GC才能安全地区分正在初始化与异常残留。
    File publication = lockFile(root.fd, ".publication.lock", LOCK_EX);
    if (!publication) { failed(error, "slot_stage_publication_busy"); return {}; }
    for (int attempt = 0; attempt < 32; ++attempt) {
        const std::string name = unique(".stage-");
        if (mkdirat(root.fd, name.c_str(), 0700) != 0) { if (errno == EEXIST) continue; failed(error, "slot_stage_create"); return {}; }
        File staged = openDirectory(root.fd, name);
        if (!staged || mkdirat(staged.fd, path.slot.c_str(), 0700) != 0) { failed(error, "slot_stage_leaf"); return {}; }
        if (!ownerMarker(staged.fd, ".owner", path)) { failed(error, "slot_stage_owner_write"); return {}; }
        File owner = lockFile(staged.fd, ".owner", LOCK_EX);
        if (!owner) { failed(error, "slot_stage_owner_lock"); return {}; }
        const std::string stage = path.root + '/' + name + '/' + path.slot;
        auto& state = leases(); std::lock_guard<std::mutex> lock(state.mutex);
        if (state.stages.size() >= 32) { error = "slot_stage_owner_limit"; return {}; }
        state.stages.emplace(stage, owner.take());
        return stage;
    }
    error = "slot_stage_collision_limit"; return {};
}
bool DiscardSlotStage(const std::string& stage, std::string& error) {
    Path path; if (!parse(stage, true, path, error)) return false;
    if (!stageOwned(stage)) { error = "slot_stage_not_owned"; return false; }
    File root = openRoot(path); if (!root) return failed(error, "slot_root_open");
    File directory = openDirectory(root.fd, path.generation);
    const bool result = (!directory && errno == ENOENT) ||
        (directory && removeContents(directory.fd) && unlinkat(root.fd, path.generation.c_str(), AT_REMOVEDIR) == 0);
    // 失败残留转为可证明无活跃owner的孤儿，下次有界维护继续退休。
    releaseStage(stage); return result;
}
bool PublishSlotGeneration(const std::string& stage, const std::string& destination, std::string& error) {
    Path path, stagedPath;
    if (!parse(destination, false, path, error) || (!stage.empty() && (!parse(stage, true, stagedPath, error) ||
        path.root != stagedPath.root || path.slot != stagedPath.slot))) return false;
    if (!stage.empty() && !stageOwned(stage)) { error = "slot_stage_not_owned"; return false; }
    File root = openRoot(path); if (!root) return failed(error, "slot_root_open");
    File publication = lockFile(root.fd, ".publication.lock", LOCK_EX);
    if (!publication) return failed(error, "slot_publication_busy");
    File existingGeneration = openDirectory(root.fd, path.generation);
    File existing(existingGeneration ? openat(existingGeneration.fd, path.slot.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) : -1);
    if (stage.empty()) return existing && markerMatches(existing.fd, path.generation) && activate(root.fd, path);
    File stagedGeneration = openDirectory(root.fd, stagedPath.generation);
    File staged(stagedGeneration ? openat(stagedGeneration.fd, path.slot.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) : -1);
    if (!staged || !onlySlot(stagedGeneration.fd, path.slot) || !markerMatches(staged.fd, path.generation)) {
        error = "slot_stage_not_committed"; return false;
    }
    if (fsync(staged.fd) != 0 || fsync(stagedGeneration.fd) != 0) return failed(error, "slot_stage_sync");
    if (existingGeneration && !onlySlot(existingGeneration.fd, path.slot)) { error = "slot_generation_has_unowned_entries"; return false; }
    if (existing && sameFiles(staged.fd, existing.fd)) return activate(root.fd, path);
    std::string retired;
    File retirement(existing ? lockFile(existing.fd, ".lease", LOCK_EX) : File());
    if (existingGeneration) {
        if (!existing || !retirement) return failed(error, "slot_existing_generation_in_use");
        // 写证据再原子移动；即使随后崩溃，维护端也能验证旧代归属，不按目录名字猜所有权。
        if (!ownerMarker(existingGeneration.fd, ".retired-owner", path) && errno != EEXIST) return failed(error, "slot_retired_owner");
        retired = unique(".retired-");
        if (renameat(root.fd, path.generation.c_str(), root.fd, retired.c_str()) != 0) return failed(error, "slot_retire_for_repair");
    }
    if (renameat(root.fd, stagedPath.generation.c_str(), root.fd, path.generation.c_str()) != 0) {
        const int saved = errno;
        if (!retired.empty()) renameat(root.fd, retired.c_str(), root.fd, path.generation.c_str());
        errno = saved; return failed(error, "slot_atomic_publish");
    }
    if (!activate(root.fd, path)) return failed(error, "slot_active_commit");
    // 已发布新代后才回收无读者的旧损坏代；删除失败保留 retired 目录，不能回滚可用新代。
    if (!retired.empty() && removeContents(existingGeneration.fd)) unlinkat(root.fd, retired.c_str(), AT_REMOVEDIR);
    return true;
}
std::string AcquireSlotGeneration(const std::string& directory, std::string& error) {
    Path path; if (!parse(directory, false, path, error)) return {};
    File root = openRoot(path); if (!root) { failed(error, "slot_root_open"); return {}; }
    File publication = lockFile(root.fd, ".publication.lock", LOCK_SH);
    File generation = openDirectory(root.fd, path.generation);
    File slot(generation ? openat(generation.fd, path.slot.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) : -1);
    if (!publication || !slot || !markerMatches(slot.fd, path.generation)) { failed(error, "slot_generation_unavailable"); return {}; }
    File lease = lockFile(slot.fd, ".lease", LOCK_SH);
    if (!lease) { failed(error, "slot_lease_busy"); return {}; }
    auto& state = leases(); std::lock_guard<std::mutex> lock(state.mutex);
    if (state.files.size() >= 4096 || state.next == UINT64_MAX) { error = "slot_lease_limit"; return {}; }
    const uint64_t id = ++state.next; state.files.emplace(id, lease.take());
    return std::to_string(state.pid) + ':' + std::to_string(id);
}
bool ReleaseSlotGeneration(const std::string& handle) {
    unsigned long long pid = 0, id = 0; int consumed = 0;
    if (std::sscanf(handle.c_str(), "%llu:%llu%n", &pid, &id, &consumed) != 2 || handle[consumed] || pid != static_cast<uint64_t>(getpid())) return false;
    auto& state = leases(); std::lock_guard<std::mutex> lock(state.mutex);
    const auto entry = state.files.find(id); if (entry == state.files.end()) return false;
    close(entry->second); state.files.erase(entry); return true;
}
static bool RetireSlotWithBudget(const std::string& directory, std::string& error, MaintenanceBudget& budget) {
    Path path; if (!parse(directory, false, path, error)) return false;
    File root = openRoot(path); if (!root) return failed(error, "slot_root_open");
    File publication = lockFile(root.fd, ".publication.lock", LOCK_EX);
    if (!publication) return false;
    std::string current;
    if (!readSmall(root.fd, ".active-" + path.slot, current) || current == path.generation) return false;
    Path activePath;
    if (!parse(path.root + '/' + current + '/' + path.slot, false, activePath, error)) return false;
    File generation = openDirectory(root.fd, path.generation);
    File slot(generation ? openat(generation.fd, path.slot.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) : -1);
    if (!slot || !onlySlot(generation.fd, path.slot) || !markerMatches(slot.fd, path.generation)) return false;
    File lease = lockFile(slot.fd, ".lease", LOCK_EX); if (!lease) return false;
    if (!ownerMarker(generation.fd, ".retired-owner", path) && errno != EEXIST) return failed(error, "slot_retired_owner");
    const std::string retired = unique(".retired-");
    if (renameat(root.fd, path.generation.c_str(), root.fd, retired.c_str()) != 0) return failed(error, "slot_retirement_rename");
    return removeContents(generation.fd, budget) && unlinkat(root.fd, retired.c_str(), AT_REMOVEDIR) == 0;
}
bool RetireSlotGeneration(const std::string& directory, std::string& error) {
    MaintenanceBudget budget; return RetireSlotWithBudget(directory, error, budget);
}

namespace {
/** 游标只活在当前PID，且复用前比对inode，避免目录被替换后继续扫描旧目标。调用者持state锁。 */
DIR* cursor(Leases& state, const std::string& key, int directory) {
    auto item = state.cursors.find(key);
    if (item != state.cursors.end()) {
        struct stat old{}, current{};
        if (!fstat(dirfd(item->second), &old) && !fstat(directory, &current) && old.st_dev == current.st_dev && old.st_ino == current.st_ino)
            return item->second;
        closedir(item->second); state.cursors.erase(item);
    }
    if (state.cursors.size() >= 8) { closedir(state.cursors.begin()->second); state.cursors.erase(state.cursors.begin()); }
    File scan(openat(directory, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    DIR* stream = scan ? fdopendir(scan.fd) : nullptr;
    if (stream) { scan.take(); state.cursors.emplace(key, stream); }
    return stream;
}
bool transientName(const std::string& name, const char* prefix) {
    const std::string head(prefix); if (name.rfind(head, 0) != 0) return false;
    bool dash = false, digit = false;
    for (char c : name.substr(head.size())) {
        if (c == '-' && digit && !dash) { dash = true; digit = false; }
        else if (c >= '0' && c <= '9') digit = true;
        else return false;
    }
    return dash && digit;
}
bool readOwner(int directory, const char* name, const Path& scope, Path& owner) {
    std::string body; if (!readSmall(directory, name, body)) return false;
    const std::string prefix = "amcl-slot-owner-v1\n";
    if (body.rfind(prefix, 0) != 0) return false;
    const auto split = body.find('\n', prefix.size());
    if (split == std::string::npos || body.empty() || body.back() != '\n') return false;
    const std::string hash = body.substr(prefix.size(), split - prefix.size());
    const std::string slot = body.substr(split + 1, body.size() - split - 2);
    std::string error;
    return slot == scope.slot && parse(scope.root + '/' + hash + '/' + slot, false, owner, error);
}
File existingLock(int directory, const char* name) {
    File file(openat(directory, name, O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW));
    struct stat info{};
    if (!file || fstat(file.fd, &info) || !S_ISREG(info.st_mode) || flock(file.fd, LOCK_EX | LOCK_NB)) return File();
    return file;
}
bool emptyDirectory(int directory, MaintenanceBudget& budget) {
    File scan(openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    DIR* stream = scan ? fdopendir(scan.fd) : nullptr; if (!stream) return false;
    scan.take(); bool empty = true;
    while (const auto* entry = readdir(stream)) {
        if (!budget.fileOperation()) { empty = false; break; }
        const std::string name = entry->d_name;
        if (name != "." && name != "..") { empty = false; break; }
    }
    closedir(stream); return empty;
}
bool removeOrphan(int root, const std::string& name, const Path& scope, MaintenanceBudget& budget) {
    File publication = lockFile(root, ".publication.lock", LOCK_EX); if (!publication) return false;
    File directory = openDirectory(root, name); if (!directory) return false;
    const bool staging = transientName(name, ".stage-");
    Path owner;
    if (!readOwner(directory.fd, staging ? ".owner" : ".retired-owner", scope, owner) || !onlySlot(directory.fd, owner.slot)) return false;
    File slot = openDirectory(directory.fd, owner.slot);
    File lease = staging ? existingLock(directory.fd, ".owner") : (slot ? existingLock(slot.fd, ".lease") : File());
    if ((staging || slot) && !lease && (staging || !emptyDirectory(slot.fd, budget))) return false;
    if (!staging) {
        std::string active;
        if (!readSmall(root, ".active-" + owner.slot, active)) return false;
        Path activePath; std::string error;
        if (!parse(scope.root + '/' + active + '/' + owner.slot, false, activePath, error)) return false;
        File replacement = openDirectory(root, owner.generation);
        if (active == owner.generation && !replacement) {
            // publication在“旧代移走、新代未落位”间被杀：恢复可证明的旧代，而非删掉最后副本。
            return renameat(root, name.c_str(), root, owner.generation.c_str()) == 0 && fsync(root) == 0;
        }
        if (active == owner.generation) {
            File replacementSlot = openDirectory(replacement.fd, owner.slot);
            if (!replacementSlot || !markerMatches(replacementSlot.fd, owner.generation)) return false;
        }
    }
    return removeContents(directory.fd, budget) && unlinkat(root, name.c_str(), AT_REMOVEDIR) == 0;
}
bool ticketName(const std::string& name, std::string& id) {
    if (name.size() < 36) return false;
    for (size_t i = 0; i < 36; ++i) {
        const bool dash = i == 8 || i == 13 || i == 18 || i == 23;
        if (dash ? name[i] != '-' : !((name[i] >= '0' && name[i] <= '9') || (name[i] >= 'a' && name[i] <= 'f'))) return false;
    }
    id = name.substr(0, 36);
    const auto tail = name.substr(36);
    for (const char* suffix : {".request.json", ".failure.json", ".claimed.json", ".outcome.json"}) {
        if (tail == suffix) return true;
        const std::string prefix = std::string(suffix) + ".tmp-";
        if (transientName(tail, prefix.c_str())) return true;
    }
    return false;
}
}

MaintenanceResult CollectSlotGarbage(const std::string& activeDirectory, const MaintenanceLimits& limits) {
    MaintenanceBudget budget(limits); Path scope; std::string error;
    if (!parse(activeDirectory, false, scope, error)) return budget.result;
    File root = openRoot(scope); if (!root) return budget.result;
    auto& state = leases(); std::lock_guard<std::mutex> lock(state.mutex);
    const std::string key = scope.root + ':' + scope.slot;
    DIR* stream = cursor(state, key, root.fd); if (!stream) return budget.result;
    while (budget.timeAvailable() && budget.result.scanned < limits.entries && budget.result.attempted < limits.attempts && budget.result.removed < limits.removals) {
        const auto* entry = readdir(stream);
        if (!entry) { closedir(stream); state.cursors.erase(key); return budget.result; }
        ++budget.result.scanned; const std::string name = entry->d_name;
        bool removed = false;
        if (transientName(name, ".stage-") || transientName(name, ".retired-")) {
            ++budget.result.attempted; removed = removeOrphan(root.fd, name, scope, budget);
        } else if (name.size() == 64 && name != scope.generation) {
            ++budget.result.attempted; removed = RetireSlotWithBudget(scope.root + '/' + name + '/' + scope.slot, error, budget);
        }
        if (removed) ++budget.result.removed;
    }
    budget.result.exhausted = true; return budget.result;
}
MaintenanceResult CollectGraphicsTickets(const std::string& directory, const std::string& keepId, int64_t now, const MaintenanceLimits& limits) {
    MaintenanceBudget budget(limits);
    const std::string suffix = "/graphics-recovery";
    if (directory.size() < suffix.size() + 1 || directory[0] != '/' || directory.find("/../") != std::string::npos ||
        directory.find('\0') != std::string::npos || directory.substr(directory.size() - suffix.size()) != suffix || now <= 0) return budget.result;
    File root(open(directory.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)); if (!root) return budget.result;
    auto& state = leases(); std::lock_guard<std::mutex> lock(state.mutex);
    DIR* stream = cursor(state, directory, root.fd); if (!stream) return budget.result;
    while (budget.timeAvailable() && budget.result.scanned < limits.entries && budget.result.attempted < limits.attempts && budget.result.removed < limits.removals) {
        const auto* entry = readdir(stream);
        if (!entry) { closedir(stream); state.cursors.erase(directory); return budget.result; }
        ++budget.result.scanned; const std::string name = entry->d_name; std::string id;
        if (!ticketName(name, id) || id == keepId) continue;
        ++budget.result.attempted; struct stat info{};
        if (!budget.fileOperation()) break;
        if (fstatat(root.fd, name.c_str(), &info, AT_SYMLINK_NOFOLLOW) || !S_ISREG(info.st_mode)
            || info.st_uid != getuid() || info.st_mtime < 0 || now < info.st_mtime || now - info.st_mtime < 86400) continue;
        if (!unlinkat(root.fd, name.c_str(), 0)) ++budget.result.removed;
    }
    budget.result.exhausted = true; return budget.result;
}
}
