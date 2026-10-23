/**
 * 直接编译生产 DownloadEngine 的宿主回归，不复制业务重试逻辑。
 * 静态夹具验证文件准入与路径所有权；真实回环 HTTP 验证授权、换源、错误保留和取消收敛。
 * 大小文件分别进入 worker 与 multi；所有网络都留在本机，不依赖公网或用户游戏数据。
 * 仅操作命令行指定的工作区构建夹具目录，绝不使用用户游戏目录。
 */
#include <cassert>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <thread>
#include <atomic>
#include <cstdlib>
#include <new>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <poll.h>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>
#include <curl/curl.h>
#include "engine.h"
#include "download_meta.h"
#include "sha1.h"
#include "../utils/amcl_log.h"

/**
 * 仅此宿主测试翻译单元替换普通分配：TLS 单次故障用于验证 acquireCurlUse 之后抛
 * bad_alloc 仍归还生命周期计数。默认完全使用 malloc/free；不进入应用源或 HAP，
 * 也不影响其他下载线程的分配。调用者须预构造参数，hook 后直接进入被测生产方法。
 */
namespace {
thread_local bool fail_next_host_allocation = false;
thread_local std::size_t host_allocations_before_failure = 0;
}
void amclNativeTestFailAllocationAfter(std::size_t successful_allocations) noexcept {
    host_allocations_before_failure = successful_allocations;
    fail_next_host_allocation = true;
}
void amclNativeTestFailNextAllocation() noexcept { amclNativeTestFailAllocationAfter(0); }
/** 返回是否仍有未消费故障；调用后解除，防止扫到函数末尾后误伤夹具的验证分配。 */
bool amclNativeTestClearAllocationFailure() noexcept {
    const bool armed = fail_next_host_allocation;
    fail_next_host_allocation = false;
    return armed;
}
void* operator new(std::size_t bytes) {
    if (fail_next_host_allocation) {
        if (host_allocations_before_failure == 0) {
            fail_next_host_allocation = false;
            throw std::bad_alloc();
        }
        --host_allocations_before_failure;
    }
    if (void* value = std::malloc(bytes == 0 ? 1 : bytes)) return value;
    throw std::bad_alloc();
}
void operator delete(void* value) noexcept { std::free(value); }
void operator delete(void* value, std::size_t) noexcept { std::free(value); }

extern "C" {
void amclLogPrint(AmclLogLevel, unsigned int, const char*, const char*, ...) {}
void amclLogWrite(AmclLogLevel, const char*, const char*, ...) {}
void amclLogWriteFor(long long, AmclLogLevel, const char*, const char*, ...) {}
void amclLogFlush() {}
long long amclLogGetThreadActivity() { return 0; }
void amclLogSetThreadActivity(long long) {}
long long amclLedgerActivityOfTask(unsigned long long) { return 0; }
}
namespace fs = std::filesystem;
/** 读取真实Linux线程自愿调度计数，不在生产下载器内加常驻探针。
 * 只有本fixture主线程在采样窗主动sleep；空闲下载线程不应按200ms定时醒来。
 * 调用点须无HTTP夹具线程且已结束所有下载，避免把合法socket/业务工作算成空转。 */
static std::map<std::string, unsigned long long> idleThreadSwitches() {
    std::map<std::string, unsigned long long> result;
    for (const auto& entry : fs::directory_iterator("/proc/self/task")) {
        const auto tid = entry.path().filename().string();
        if (tid == std::to_string(::getpid())) continue;
        std::ifstream file(entry.path() / "status");
        std::string line;
        bool found = false;
        while (std::getline(file, line)) {
            const std::string key = "voluntary_ctxt_switches:";
            if (line.compare(0, key.size(), key) == 0) {
                result[tid] = std::stoull(line.substr(key.size())); found = true; break;
            }
        }
        assert(found);
    }
    return result;
}

static void idleDownloadThreads(const char* phase) {
    // 先让上一次终态、安装租约与首次curl线程初始化收敛，再观测多个原200ms周期。
    std::this_thread::sleep_for(std::chrono::milliseconds(750));
    const auto before = idleThreadSwitches();
    assert(before.size() >= 2); // 必须实际创建multi和ticker，空进程不能冒充通过。
    std::this_thread::sleep_for(std::chrono::milliseconds(700));
    const auto after = idleThreadSwitches();
    assert(before.size() == after.size());
    for (const auto& thread : before) {
        assert(after.count(thread.first));
        if (after.at(thread.first) != thread.second)
            std::cerr << "idle wake tid=" << thread.first << " delta=" << after.at(thread.first)-thread.second << std::endl;
        assert(after.at(thread.first) == thread.second);
    }
    std::cout << "PASS " << phase << ": " << before.size() << " idle download threads, zero timed wakes in 700ms" << std::endl;
}

/** 空任务在onStart内即终态，仍必须唤醒收尾释放SH；验证原安装者可真实取得EX。 */
static void emptyTaskReleasesInstallLease(download::DownloadEngine& engine, const fs::path& root) {
    download::LoaderDownload::Config cfg; cfg.name = "empty synchronous terminal";
    auto task = engine.createTask(cfg);
    assert(engine.startTask(task->taskId()));
    assert(task->state() == download::LoadState::Finished);
    const int fd = ::open((root / ".sideload-install.lock").c_str(), O_RDWR | O_CLOEXEC);
    assert(fd >= 0);
    bool acquired = false;
    for (int i = 0; i < 300 && !acquired; ++i) {
        acquired = ::flock(fd, LOCK_EX | LOCK_NB) == 0;
        if (!acquired) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    assert(acquired); assert(::close(fd) == 0);
    std::cout << "PASS synchronous terminal wakes final install-lease release" << std::endl;
}

static void write(const fs::path& path, const std::string& value) {
    fs::create_directories(path.parent_path());
    std::ofstream file(path, std::ios::binary); file << value; file.close();
}
/** 读取夹具实际字节；保护测试不能仅凭相同长度判定用户内容未被覆盖。 */
static std::string readFixtureFile(const fs::path& path) {
    std::ifstream file(path, std::ios::binary);
    assert(file.good());
    return std::string(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
}
static download::LoaderDownload::Config config(const std::string& name, const fs::path& root, const fs::path& target) {
    download::NetFile::Config file;
    file.local_path = target.string(); file.allowed_root = root.string();
    file.urls = {"https://example.invalid/immutable-library.jar"}; file.check.expected_size = 4;
    download::LoaderDownload::Config task; task.name = name; task.files.push_back(file); return task;
}
/** 真实loopback HTTP故障夹具：第一次GET送成功头后截断；新令牌才允许完整正文。 */
class AuthorizedHttpFixture {
public:
    int listener = -1, port = 0;
    std::atomic<bool> stopped{false};
    std::atomic<int> oldRequests{0}, newRequests{0};
    std::thread worker;
    const std::string payload;
    bool slow;
    AuthorizedHttpFixture(size_t size, bool slowResponse = false) : payload(size, 'x'), slow(slowResponse) {
        listener = ::socket(AF_INET, SOCK_STREAM, 0); assert(listener >= 0);
        sockaddr_in address{}; address.sin_family=AF_INET; address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
        assert(::bind(listener,reinterpret_cast<sockaddr*>(&address),sizeof(address))==0);
        socklen_t length=sizeof(address);assert(::getsockname(listener,reinterpret_cast<sockaddr*>(&address),&length)==0);port=ntohs(address.sin_port);
        assert(::listen(listener,8)==0);
        worker=std::thread([this] {
            while(!stopped.load()) {
                pollfd ready{listener,POLLIN,0};if(::poll(&ready,1,100)<=0)continue;
                int client=::accept(listener,nullptr,nullptr);if(client<0)continue;
                std::string request;char buffer[2048];
                while(request.find("\r\n\r\n")==std::string::npos && request.size()<16384) {int size=::recv(client,buffer,sizeof(buffer),0);if(size<=0)break;request.append(buffer,size);}
                bool original=request.find("Bearer lease-one")!=std::string::npos;
                if(original)oldRequests++;else newRequests++;
                std::string header="HTTP/1.1 200 OK\r\nContent-Length: "+std::to_string(payload.size())+"\r\nConnection: close\r\n\r\n";
                ::send(client,header.data(),header.size(),MSG_NOSIGNAL);
                if(slow)std::this_thread::sleep_for(std::chrono::milliseconds(1200));
                size_t limit=original&&!slow?payload.size()/2:payload.size(), sent=0;
                while(sent<limit){auto size=::send(client,payload.data()+sent,limit-sent,MSG_NOSIGNAL);if(size<=0)break;sent+=size;}
                ::shutdown(client,SHUT_RDWR);::close(client);
            }
        });
    }
    ~AuthorizedHttpFixture(){stopped=true;if(worker.joinable())worker.join();::close(listener);}
};

/** 执行真实生产Engine而非复制重试逻辑；小文件走multi，大文件走worker，两者都不得旧token二次GET。 */
static void authorizedTransfer(download::DownloadEngine& engine, const fs::path& root, size_t size, bool slow=false, bool singleUse=true) {
    AuthorizedHttpFixture server(size,slow);
    auto make=[&](const char* token) {
        auto task=config("authorized HTTP",root,root/("lease-"+std::to_string(size)+(slow?"-slow":"")+(singleUse?"-single":"-budget")));
        auto& file=task.files[0];file.urls={"http://127.0.0.1:"+std::to_string(server.port)+"/asset"};
        file.check.expected_size=size;file.max_connections=1;file.bearer_token=token;
        file.authorized_policy=true;file.authorized_single_use=singleUse;file.authorized_max_http_attempts=singleUse?1:4;
        file.authorized_valid_for_ms=slow?1000:300000;file.authorized_max_bytes=size;return task;
    };
    auto wait=[&](download::LoaderDownloadPtr task) {
        for(int i=0;i<1000;i++){auto state=task->state();if(state!=download::LoadState::Loading&&state!=download::LoadState::Waiting&&engine.isTaskExecutionSettled(task->taskId()))return;std::this_thread::sleep_for(std::chrono::milliseconds(10));}
        assert(false && "authorized transfer did not settle");
    };
    auto first=engine.createTask(make("lease-one"));assert(engine.startTask(first->taskId()));wait(first);
    assert(server.oldRequests==(singleUse?1:2));
    if(slow){assert(first->state()==download::LoadState::Finished);std::cout<<"PASS healthy authorized GET survives new-request deadline"<<std::endl;return;}
    assert(first->state()==download::LoadState::Failed);
    assert(first->error()&&first->error()->needs_new_lease&&first->error()->http_attempts==(singleUse?1:2));
    assert(first->error()->successful_headers_seen&&first->error()->bytes_written>0);
    bool purged=false;for(int i=0;i<100&&!purged;i++){purged=engine.purgeTask(first->taskId());if(!purged)std::this_thread::sleep_for(std::chrono::milliseconds(10));}assert(purged);
    auto second=engine.createTask(make("lease-two"));assert(engine.startTask(second->taskId()));wait(second);
    assert(second->state()==download::LoadState::Finished&&server.oldRequests==(singleUse?1:2)&&server.newRequests==1);
    if(!singleUse)std::cout<<"PASS HTTP body budget forbids a third reused-lease request"<<std::endl;
    std::cout<<"PASS authorized truncation requires fresh lease bytes="<<size<<std::endl;
}

/**
 * HTTP 状态故障夹具：只监听回环 IPv4，不依赖公网、DNS 或手机环境。
 * /first 与 /last 返回无正文 404；/forbidden、/server、/rate 分别返回 403、500、503；
 * /ok 返回指定长度正文。故意不送错误正文，复现 FAILONERROR 下“有 HTTP、零字节”的证据。
 * 每个套件显式持有服务端线程，析构等待退出，避免监听 fd 和在途请求泄漏到下一用例。
 */
class StatusHttpFixture {
public:
    int listener = -1;
    int port = 0;
    std::atomic<bool> stopped{false};
    std::atomic<int> first_requests{0}, last_requests{0}, success_requests{0};
    std::atomic<int> last_failure_status{0};
    std::thread worker;
    const std::string payload;
    const std::string host;

    explicit StatusHttpFixture(size_t size, std::string bind_host = "127.0.0.1")
        : payload(size, 's'), host(std::move(bind_host)) {
        listener = ::socket(AF_INET, SOCK_STREAM, 0);
        assert(listener >= 0);
        sockaddr_in address{};
        address.sin_family = AF_INET;
        assert(::inet_pton(AF_INET, host.c_str(), &address.sin_addr) == 1);
        assert(::bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
        socklen_t length = sizeof(address);
        assert(::getsockname(listener, reinterpret_cast<sockaddr*>(&address), &length) == 0);
        port = ntohs(address.sin_port);
        assert(::listen(listener, 8) == 0);
        worker = std::thread([this] {
            while (!stopped.load()) {
                pollfd ready{listener, POLLIN, 0};
                if (::poll(&ready, 1, 100) <= 0) continue;
                int client = ::accept(listener, nullptr, nullptr);
                if (client < 0) continue;
                std::string request;
                char buffer[2048];
                while (request.find("\r\n\r\n") == std::string::npos && request.size() < 16384) {
                    ssize_t count = ::recv(client, buffer, sizeof(buffer), 0);
                    if (count <= 0) break;
                    request.append(buffer, static_cast<size_t>(count));
                }
                int status = 404;
                const bool head = request.compare(0, 5, "HEAD ") == 0;
                const bool oversized_head = head && request.find(" /oversize ") != std::string::npos;
                if (request.find(" /ok ") != std::string::npos || request.find(" /oversize ") != std::string::npos) { status = 200; ++success_requests; }
                else if (request.find(" /forbidden ") != std::string::npos) status = 403;
                else if (request.find(" /server ") != std::string::npos) status = 500;
                else if (request.find(" /rate ") != std::string::npos) status = 503;
                else if (request.find(" /first ") != std::string::npos) ++first_requests;
                else if (request.find(" /last ") != std::string::npos) ++last_requests;
                const size_t body_size = status == 200 ? payload.size() : 0;
                if (status >= 400) last_failure_status = status;
                const std::string declared_size = oversized_head ? "9223372036854775807" : std::to_string(body_size);
                std::string response = "HTTP/1.1 " + std::to_string(status) + " Fixture\r\nContent-Length: " +
                    declared_size + "\r\nConnection: close\r\n";
                if (status == 503) response += "Retry-After: 120\r\n";
                response += "\r\n";
                if (status == 200 && !head) response += payload;
                // send 允许部分写入；必须完整送出成功正文，防止夹具本身制造 SizeMismatch。
                size_t sent = 0;
                while (sent < response.size()) {
                    ssize_t count = ::send(client, response.data() + sent, response.size() - sent, MSG_NOSIGNAL);
                    if (count <= 0) break;
                    sent += static_cast<size_t>(count);
                }
                ::shutdown(client, SHUT_RDWR);
                ::close(client);
            }
        });
    }
    ~StatusHttpFixture() {
        stopped = true;
        if (worker.joinable()) worker.join();
        ::close(listener);
    }
    std::string url(const std::string& endpoint) const {
        return "http://" + host + ":" + std::to_string(port) + endpoint;
    }
};

/** 等待真实传输及文件 owner 收敛；状态失败本身不足以证明 callbacks 已全部退出。 */
static void waitForSettled(const download::LoaderDownloadPtr& task) {
    for (int i = 0; i < 3000; ++i) {
        auto state = task->state();
        if (state != download::LoadState::Loading && state != download::LoadState::Waiting &&
            download::DownloadEngine::instance().isTaskExecutionSettled(task->taskId())) return;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    assert(false && "status transfer did not settle");
}

/** 维护轮和最后一个回调允许短暂持有完整屏障；只接受真实 purge 成功后继续。 */
static void purgeSettled(download::DownloadEngine& engine, uint64_t task_id) {
    for (int i = 0; i < 300; ++i) {
        if (engine.purgeTask(task_id)) return;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    assert(false && "native owner did not become purgeable");
}

/** 自动回收与维护预占可并发；暂时冲突必须保持终态，稍后才可获得新 Waiting owner。 */
static download::LoaderDownloadPtr recreateSettled(download::DownloadEngine& engine,
                                                  const download::LoaderDownload::Config& cfg) {
    for (int i = 0; i < 300; ++i) {
        auto task = engine.createTask(cfg);
        if (task->state() == download::LoadState::Waiting) return task;
        assert(task->state() == download::LoadState::Failed);
        purgeSettled(engine, task->taskId());
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    assert(false && "terminal old owner never became reclaimable");
    return nullptr;
}

/** 真实 Engine 分配的批次身份必须传入每个 NetFile；调用者残留 ID 不能覆盖它。 */
static void fileTaskIdentity(download::DownloadEngine& engine, const fs::path& root) {
    auto cfg = config("identity propagation", root, root / "identity-a.jar");
    cfg.files[0].task_id = 999999;
    auto extra = cfg.files[0]; extra.local_path = (root / "identity-b.jar").string();
    cfg.files.push_back(extra);
    auto task = engine.createTask(cfg);
    assert(task->taskId() != 0 && task->files().size() == 2);
    for (const auto& file : task->files()) assert(file->taskId() == task->taskId());
    engine.cancelTask(task->taskId());
    assert(engine.purgeTask(task->taskId()));
    std::cout << "PASS Engine propagates real task identity to every file" << std::endl;
}

/**
 * onStart 回调是真实同步执行边界。把它停住后从另一线程取消/清理/重建同路径，
 * 证明“尚未登记 managed startup”也有预占保护；不依赖时间猜测或测试专用生产 hook。
 */
static void startupCallbackBarrier(download::DownloadEngine& engine, const fs::path& root) {
    const auto target = root / "callback-owner.jar";
    write(target, "USER-ORIGINAL");
    auto task = engine.createTask(config("held Loading callback", root, target));
    std::mutex mutex;
    std::condition_variable changed;
    bool entered = false, release = false;
    task->setOnStateChanged([&](download::LoadState, download::LoadState state) {
        if (state != download::LoadState::Loading) return;
        std::unique_lock<std::mutex> lock(mutex);
        entered = true; changed.notify_all();
        changed.wait(lock, [&] { return release; });
    });
    bool started = false;
    std::thread starter([&] { started = engine.startTask(task->taskId()); });
    {
        std::unique_lock<std::mutex> lock(mutex);
        assert(changed.wait_for(lock, std::chrono::seconds(5), [&] { return entered; }));
    }
    assert(engine.cancelTask(task->taskId()));
    assert(task->state() == download::LoadState::Aborted);
    assert(!engine.isTaskExecutionSettled(task->taskId()));
    assert(!engine.purgeTask(task->taskId()));
    assert(engine.deleteTaskFiles(task->taskId()) == 0);
    assert(!engine.resumeTask(task->taskId()));
    assert(!engine.retryFailedFiles(task->taskId(), {}));
    auto conflict = engine.createTask(config("must not steal callback owner", root, target));
    assert(conflict->state() == download::LoadState::Failed);
    assert(readFixtureFile(target) == "USER-ORIGINAL");
    {
        std::lock_guard<std::mutex> lock(mutex); release = true;
    }
    changed.notify_all(); starter.join(); assert(started);
    waitForSettled(task);
    auto next = recreateSettled(engine, config("reclaim after callback exits", root, target));
    assert(next->state() == download::LoadState::Waiting && !engine.getTask(task->taskId()));
    // 自动回收必须和 purge 一并归还更新 SH，不能留下 ticker 已无法遍历的无主租约。
    int fd = ::open((root / ".sideload-install.lock").c_str(), O_RDWR | O_CLOEXEC);
    assert(fd >= 0 && ::flock(fd, LOCK_EX | LOCK_NB) == 0 && ::close(fd) == 0);
    engine.cancelTask(next->taskId()); purgeSettled(engine, next->taskId());
    purgeSettled(engine, conflict->taskId());
    std::cout << "PASS callback startup reservation blocks reclaim cleanup reset and releases SH" << std::endl;
}

/** 停在真实生产 HEAD 的 startup：线程表尚为空时也不能删除或回收旧 owner。 */
static void startupHttpBarrier(download::DownloadEngine& engine, const fs::path& root) {
    int listener = ::socket(AF_INET, SOCK_STREAM, 0); assert(listener >= 0);
    sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(::bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
    socklen_t length = sizeof(address);
    assert(::getsockname(listener, reinterpret_cast<sockaddr*>(&address), &length) == 0);
    assert(::listen(listener, 1) == 0);
    std::mutex mutex; std::condition_variable changed; bool entered = false, release = false;
    std::thread server([&] {
        pollfd ready{listener, POLLIN, 0}; assert(::poll(&ready, 1, 5000) > 0);
        int client = ::accept(listener, nullptr, nullptr); assert(client >= 0);
        std::string request; char buffer[2048];
        while (request.find("\r\n\r\n") == std::string::npos) {
            ssize_t size = ::recv(client, buffer, sizeof(buffer), 0); assert(size > 0);
            request.append(buffer, static_cast<size_t>(size));
        }
        assert(request.find("HEAD ") == 0);
        {
            std::unique_lock<std::mutex> lock(mutex);
            entered = true; changed.notify_all();
            changed.wait(lock, [&] { return release; });
        }
        const std::string response = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nAccept-Ranges: none\r\nConnection: close\r\n\r\n";
        ::send(client, response.data(), response.size(), MSG_NOSIGNAL);
        ::close(client);
    });
    const auto target = root / "startup-head.jar"; write(target, "USER");
    auto cfg = config("held real HEAD startup", root, target);
    cfg.files[0].check.expected_size = -1;
    cfg.files[0].urls = {"http://127.0.0.1:" + std::to_string(ntohs(address.sin_port)) + "/head"};
    auto task = engine.createTask(cfg); assert(engine.startTask(task->taskId()));
    {
        std::unique_lock<std::mutex> lock(mutex);
        assert(changed.wait_for(lock, std::chrono::seconds(5), [&] { return entered; }));
    }
    assert(!engine.isTaskExecutionSettled(task->taskId()));
    assert(engine.cancelTask(task->taskId()));
    assert(engine.deleteTaskFiles(task->taskId()) == 0);
    // 取消令牌也可能已迅速中断 curl；此时允许回收。不得把“服务端还阻塞”当成客户端
    // 必然活跃的证据，具体 owner 事实由完整屏障与 create 的原子决议给出。
    auto conflict = engine.createTask(cfg);
    assert(conflict->state() == download::LoadState::Failed || conflict->state() == download::LoadState::Waiting);
    {
        std::lock_guard<std::mutex> lock(mutex); release = true;
    }
    changed.notify_all(); server.join(); assert(::close(listener) == 0);
    waitForSettled(task); assert(readFixtureFile(target) == "USER");
    if (conflict->state() == download::LoadState::Waiting) {
        engine.cancelTask(conflict->taskId()); purgeSettled(engine, conflict->taskId());
    } else purgeSettled(engine, conflict->taskId());
    auto next = recreateSettled(engine, cfg);
    assert(next->state() == download::LoadState::Waiting && !engine.getTask(task->taskId()));
    engine.cancelTask(next->taskId()); purgeSettled(engine, next->taskId());
    std::cout << "PASS real HEAD startup blocks reclaim and cleanup until native execution exits" << std::endl;
}

/** 失败清理只删除实际 staging 收据；旧 final 与后来替换的用户 part 都须保留。 */
static void cleanupPreservesForeignFiles(download::DownloadEngine& engine, const fs::path& root) {
    StatusHttpFixture server(4, "127.0.0.6");
    const auto target = root / "cleanup-original.jar";
    write(target, "USER");
    auto cfg = config("failed file cleanup", root, target);
    cfg.files[0].urls = {server.url("/first")};
    download::Sha1 sha; sha.update("GOOD", 4); cfg.files[0].check.expected_sha1 = sha.finalizeHex();
    auto task = engine.createTask(cfg); assert(engine.startTask(task->taskId())); waitForSettled(task);
    assert(task->state() == download::LoadState::Failed);
    const fs::path part(target.string() + ".amcl.part");
    assert(fs::exists(part));
    fs::rename(part, root / "retained-original-part");
    write(part, "USER-REPLACEMENT");
    assert(engine.deleteTaskFiles(task->taskId()) == 0);
    assert(readFixtureFile(target) == "USER" && readFixtureFile(part) == "USER-REPLACEMENT");
    purgeSettled(engine, task->taskId());

    const auto own_target = root / "cleanup-owned.jar";
    write(own_target, "USER"); cfg.files[0].local_path = own_target.string();
    auto own = engine.createTask(cfg); assert(engine.startTask(own->taskId())); waitForSettled(own);
    assert(own->state() == download::LoadState::Failed);
    const fs::path own_part(own_target.string() + ".amcl.part");
    assert(fs::exists(own_part));
    const auto size = fs::file_size(own_part);
    int64_t freed = 0;
    for (int i = 0; i < 300 && fs::exists(own_part); ++i) {
        freed += engine.deleteTaskFiles(own->taskId());
        if (fs::exists(own_part)) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    assert(freed == static_cast<int64_t>(size));
    assert(!fs::exists(own_part) && readFixtureFile(own_target) == "USER");
    purgeSettled(engine, own->taskId());
    std::cout << "PASS cleanup preserves final and foreign part, counts only successful owned unlink" << std::endl;
}

/** 同一 v1 codec 的生产 fd-at 入口必须跟随持有目录，不能重新跟随被换成 symlink 的名字。 */
static void metadataTrustedParent(const fs::path& root) {
    const auto dir = root / "meta-parent";
    const auto outside = root / "meta-outside";
    fs::create_directories(dir); fs::create_directories(outside);
    write(outside / "artifact.download-meta", "USER");
    const int parent_fd = ::open(dir.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    assert(parent_fd >= 0);
    fs::rename(dir, root / "meta-held"); fs::create_directory_symlink(outside, dir);
    download::DownloadMeta meta;
    meta.url_primary = "http://127.0.0.1/object"; meta.url_sources = {meta.url_primary};
    meta.file_size = 4; meta.check.expected_size = 4; meta.created_at = "2026-10-18T00:00:00Z";
    meta.segments.push_back({0, 3, 2});
    download::MetaFileIdentity written, read;
    assert(download::writeMetaFileAt(parent_fd, "artifact.download-meta", meta, &written));
    auto recovered = download::readMetaFileAt(parent_fd, "artifact.download-meta", &read);
    assert(recovered && recovered->segments[0].done == 2 && written.inode == read.inode && written.device == read.device);
    assert(readFixtureFile(outside / "artifact.download-meta") == "USER");
    assert(!download::writeMetaFileAt(parent_fd, "../escape", meta));
    assert(!download::readMetaFileAt(parent_fd, "../escape"));
    assert(::close(parent_fd) == 0);
    std::cout << "PASS v1 metadata fd-at remains inside held trusted parent" << std::endl;
}

/** 首个有效 size 即启动；未探测的候选保留作真实失败回退，不为它额外发串行 HEAD。 */
static void unknownSizeStartsAfterFirstSource(download::DownloadEngine& engine, const fs::path& root) {
    StatusHttpFixture server(4, "127.0.0.7");
    auto cfg = config("unknown size first valid source", root, root / "unknown-size.jar");
    cfg.files[0].check.expected_size = -1;
    download::Sha1 sha; sha.update("ssss", 4); cfg.files[0].check.expected_sha1 = sha.finalizeHex();
    cfg.files[0].urls = {server.url("/ok"), server.url("/last")};
    auto task = engine.createTask(cfg); assert(engine.startTask(task->taskId())); waitForSettled(task);
    assert(task->state() == download::LoadState::Finished);
    assert(readFixtureFile(cfg.files[0].local_path) == "ssss" && server.last_requests == 0);
    purgeSettled(engine, task->taskId());
    std::cout << "PASS unknown size starts after first valid source without probing fallbacks" << std::endl;
}

/** 超限/溢出的 HEAD 长度不进入分段或 ftruncate；仍可从后备探测取得真实大小。 */
static void oversizedHeadNeverReachesStorage(download::DownloadEngine& engine, const fs::path& root) {
    StatusHttpFixture server(4, "127.0.0.12");
    auto cfg = config("oversized HEAD boundary", root, root / "oversized-head.jar");
    cfg.files[0].check.expected_size = -1;
    download::Sha1 sha; sha.update("ssss", 4); cfg.files[0].check.expected_sha1 = sha.finalizeHex();
    cfg.files[0].urls = {server.url("/oversize"), server.url("/ok")};
    auto task = engine.createTask(cfg); assert(engine.startTask(task->taskId())); waitForSettled(task);
    assert(task->state() == download::LoadState::Finished && task->files()[0]->fileSize() == 4);
    assert(readFixtureFile(cfg.files[0].local_path) == "ssss"); purgeSettled(engine, task->taskId());
    auto invalid = cfg.files[0]; invalid.local_path = (root / "direct-oversized.jar").string();
    invalid.check.expected_size = download::kMaxDownloadFileBytes + 1;
    auto direct = std::make_shared<download::NetFile>(invalid);
    auto error = direct->start(); assert(error && error->kind == download::ErrorKind::InvalidConfig);
    assert(!fs::exists(direct->stagingPath()));
    std::cout << "PASS oversized HEAD and direct size never reach truncate/segment overflow" << std::endl;
}

/** 实际 NetFile 分段器的正反例：可补段的布局，取消后不得再缩边或增加新段。 */
static void cancelledFileCannotGrow(download::DownloadEngine& engine, const fs::path& root) {
    StatusHttpFixture server(4096, "127.0.0.13");
    for (bool cancel_first : {false, true}) {
        auto cfg = config("cancel adaptive growth", root, root / (cancel_first ? "grow-cancelled.jar" : "grow-control.jar"));
        cfg.files[0].urls = {server.url("/ok")}; cfg.files[0].check.expected_size = 32 * 1024 * 1024;
        cfg.files[0].max_connections = 4;
        auto file = std::make_shared<download::NetFile>(cfg.files[0]); assert(!file->start());
        auto original = file->threadsToLaunch(); assert(original.size() == 4);
        original[0]->setState(download::NetState::Downloading);
        const auto before = file->snapshotForMeta();
        if (cancel_first) file->abort();
        file->maybeGrowThreads();
        const auto after = file->snapshotForMeta();
        if (cancel_first) {
            assert(after.segments.size() == before.segments.size());
            for (size_t i = 0; i < before.segments.size(); ++i) {
                assert(after.segments[i].start == before.segments[i].start && after.segments[i].end == before.segments[i].end);
                assert(original[i]->isAborted());
            }
        } else assert(after.segments.size() == before.segments.size() + 1); // 正对照证明布局本可补段。
        file->abort();
        const size_t cancelled_count = file->snapshotForMeta().segments.size();
        std::thread grow_one([&] { file->maybeGrowThreads(); });
        std::thread grow_two([&] { file->maybeGrowThreads(); });
        grow_one.join(); grow_two.join();
        assert(file->snapshotForMeta().segments.size() == cancelled_count);
        // 原始段并未送入执行器，由本 fixture 按生产取消完成协议归还；正对照新段由
        // 实际 Engine worker 取消收尾。两者都通过同一 NetFile completion barrier。
        for (auto& thread : original) { thread->setState(download::NetState::Aborted); thread->markExecutionSettled(); }
        for (int i = 0; i < 500 && !file->isExecutionSettled(); ++i) std::this_thread::sleep_for(std::chrono::milliseconds(10));
        assert(file->isExecutionSettled() && file->state() == download::NetState::Aborted);
        file->deleteLocalAndMeta();
    }
    (void)engine; // 新段由生产单例 Engine 调度，不建立第二个执行器。
    std::cout << "PASS cancelled adaptive file cannot change segment boundaries or add HTTP work" << std::endl;
}

/** 扫描一次补段调用的分配点：失败只允许保留原布局，或完整发布并显式结算新段。 */
static void adaptiveAllocationFailureKeepsCoverage(const fs::path& root) {
    StatusHttpFixture server(4096, "127.0.0.14");
    bool exhausted_points = false;
    for (size_t allocation = 0; allocation < 40; ++allocation) {
        auto cfg = config("growth allocation transaction", root, root / ("growth-allocation-" + std::to_string(allocation)));
        cfg.files[0].urls = {server.url("/ok")}; cfg.files[0].check.expected_size = 32 * 1024 * 1024;
        cfg.files[0].max_connections = 4;
        auto file = std::make_shared<download::NetFile>(cfg.files[0]); assert(!file->start());
        auto original = file->threadsToLaunch(); assert(original.size() == 4);
        original[0]->setState(download::NetState::Downloading);
        amclNativeTestFailAllocationAfter(allocation);
        file->maybeGrowThreads();
        const bool not_consumed = amclNativeTestClearAllocationFailure();
        const auto layout = file->snapshotForMeta();
        int64_t next = 0;
        for (const auto& segment : layout.segments) {
            assert(segment.start == next && segment.end >= segment.start);
            next = segment.end + 1;
        }
        assert(next == cfg.files[0].check.expected_size); // 无间隙、不重叠、不丢旧尾部。
        assert(layout.segments.size() == 4 || layout.segments.size() == 5);
        file->abort();
        for (auto& thread : original) { thread->setState(download::NetState::Aborted); thread->markExecutionSettled(); }
        for (int i = 0; i < 500 && !file->isExecutionSettled(); ++i) std::this_thread::sleep_for(std::chrono::milliseconds(10));
        assert(file->isExecutionSettled() && file->state() != download::NetState::Finished);
        file->deleteLocalAndMeta();
        if (not_consumed) { exhausted_points = true; break; }
    }
    assert(exhausted_points);
    std::cout << "PASS growth allocation failures keep complete coverage and settle unpublished segments" << std::endl;
}

/** 文件都已完成但任务先被取消时，resume 保留成果并同步终态，不能永远 Loading。 */
static void resumeAllFinishedSettlesSynchronously(const fs::path& root) {
    const auto path = root / "resume-all-finished.jar"; write(path, "GOOD");
    auto cfg = config("resume preserved finished files", root, path);
    auto task = std::make_shared<download::LoaderDownload>(cfg);
    task->onStart(); assert(!task->files()[0]->start());
    assert(task->files()[0]->state() == download::NetState::Finished);
    task->abort(); // 模拟最后文件完成、聚合上报之前取消获胜的真实允许窗口。
    assert(task->resetToWaiting());
    task->onStart();
    assert(task->state() == download::LoadState::Finished && task->computeProgress().files_done == 1);
    std::cout << "PASS resume of all preserved finished files settles synchronously" << std::endl;
}

/** 实际 GET/提交/完成链逐点分配故障：已提交文件保留，未收到完成收据的 owner 必须退出。 */
static void completionAllocationFailureRetainsTerminalFacts(const fs::path& root) {
    StatusHttpFixture server(4096, "127.0.0.15");
    bool exhausted_points = false, committed_owner_failed = false;
    for (size_t allocation = 0; allocation < 60; ++allocation) {
        auto cfg = config("completion allocation transaction", root, root / ("completion-allocation-" + std::to_string(allocation)));
        cfg.files[0].urls = {server.url("/ok")}; cfg.files[0].check.expected_size = 4096;
        download::Sha1 sha; sha.update(server.payload.data(), server.payload.size());
        cfg.files[0].check.expected_sha1 = sha.finalizeHex();
        auto owner = std::make_shared<download::LoaderDownload>(cfg);
        owner->onStart(); auto file = owner->files()[0]; assert(!file->start());
        auto threads = file->threadsToLaunch(); assert(threads.size() == 1);
        threads[0]->run(); assert(threads[0]->state() == download::NetState::Finished);
        amclNativeTestFailAllocationAfter(allocation);
        threads[0]->markExecutionSettled();
        const bool not_consumed = amclNativeTestClearAllocationFailure();
        assert(threads[0]->executionSettled() && file->isExecutionSettled());
        assert(owner->state() == download::LoadState::Finished || owner->state() == download::LoadState::Failed);
        if (file->state() == download::NetState::Finished) {
            assert(readFixtureFile(file->localPath()) == server.payload);
            if (owner->state() == download::LoadState::Failed) committed_owner_failed = true;
        } else {
            assert(owner->state() == download::LoadState::Failed); file->deleteLocalAndMeta();
        }
        if (not_consumed) { exhausted_points = true; break; }
    }
    assert(exhausted_points && committed_owner_failed);
    std::cout << "PASS completion allocation failures retain committed files and settle owner terminal facts" << std::endl;
}

/**
 * 真实 Loader/NetFile 生产终态聚合：一份失败、一份缓存成功同时上报，永远只能 Failed。
 * 以 public start/report 协议构造实际文件终态，不复制聚合实现、不放宽 checker。
 */
static void concurrentFileResultsRemainFailed(const fs::path& root) {
    const auto good_path = root / "aggregate-cached.jar"; write(good_path, "GOOD");
    for (int round = 0; round < 128; ++round) {
        auto cfg = config("concurrent file results", root, good_path);
        auto failed = cfg.files[0]; failed.local_path = (root / "aggregate-failed.jar").string();
        failed.urls.clear(); // 生产 start 明确产生 InvalidConfig/Failed。
        cfg.files.push_back(failed);
        auto task = std::make_shared<download::LoaderDownload>(cfg);
        std::atomic<int> completed{0};
        task->setOnComplete([&](bool success, bool aborted, download::DownloadExceptionPtr error,
                                const download::TaskProgress& progress) {
            assert(!success && !aborted && error && error->kind == download::ErrorKind::InvalidConfig);
            assert(progress.files_done == 2); ++completed;
        });
        task->onStart();
        assert(!task->files()[0]->start() && task->files()[0]->state() == download::NetState::Finished);
        assert(task->files()[1]->start() && task->files()[1]->state() == download::NetState::Failed);
        std::atomic<bool> go{false};
        auto report = [&](size_t index) {
            while (!go.load(std::memory_order_acquire)) std::this_thread::yield();
            task->reportFileFinished(task->files()[index].get());
        };
        std::thread first(report, round % 2), second(report, 1 - round % 2);
        go.store(true, std::memory_order_release); first.join(); second.join();
        assert(task->state() == download::LoadState::Failed && completed == 1);
        // 重复报告也不能扩 done 或改变失败终态。
        task->reportFileFinished(task->files()[0].get());
        assert(task->computeProgress().files_done == 2 && completed == 1);
    }
    std::cout << "PASS concurrent success/failure aggregation is Failed exactly once" << std::endl;
}

/** 真实 worker/multi 的同步 onStart 和 onComplete 都不能关闭正在调用自己的引擎。 */
static void internalShutdownIsRejected(download::DownloadEngine& engine, const fs::path& root) {
    for (size_t size : {size_t(4096), size_t(3 * 1024 * 1024)}) {
        StatusHttpFixture server(size, "127.0.0.11");
        auto cfg = config("internal shutdown guard", root, root / ("callback-shutdown-" + std::to_string(size)));
        cfg.files[0].urls = {server.url("/ok")}; cfg.files[0].check.expected_size = size;
        cfg.files[0].max_connections = 1;
        auto task = engine.createTask(cfg);
        std::atomic<int> start_returns{0}, complete_returns{0};
        task->setOnStateChanged([&](download::LoadState, download::LoadState state) {
            if (state == download::LoadState::Loading) { engine.shutdown(); ++start_returns; }
        });
        task->setOnComplete([&](bool success, bool aborted, download::DownloadExceptionPtr,
                                const download::TaskProgress&) {
            assert(success && !aborted); engine.shutdown(); ++complete_returns;
        });
        assert(engine.startTask(task->taskId())); waitForSettled(task);
        assert(task->state() == download::LoadState::Finished && start_returns == 1 && complete_returns == 1);
        purgeSettled(engine, task->taskId());
    }
    auto probe = engine.createTask(config("engine still accepts external work", root, root / "after-internal-shutdown.jar"));
    assert(probe->state() == download::LoadState::Waiting);
    engine.cancelTask(probe->taskId()); purgeSettled(engine, probe->taskId());
    std::cout << "PASS synchronous startup and worker/multi callback shutdown is rejected without changing lifecycle" << std::endl;
}

/**
 * 先给回环 IPv4 一次成功证据，再执行真实两源 404。
 * 检查原下载错误的 HTTP/CURL/最后来源均传到任务终态，同时 IPv4 偏好不被 HTTP 错误扣分。
 * 4096 字节走 multi；3 MiB 走 worker，确保两个生产执行器都覆盖。
 */
static void missingSources(download::DownloadEngine& engine, const fs::path& root, size_t size) {
    StatusHttpFixture server(size);
    engine.noteFamilyOutcome("127.0.0.1", CURL_IPRESOLVE_V4, "127.0.0.1", true, false);
    auto cfg = config("all sources return 404", root, root / ("status-404-" + std::to_string(size)));
    cfg.files[0].urls = {server.url("/first"), server.url("/last")};
    cfg.files[0].check.expected_size = size;
    cfg.files[0].max_connections = 1;
    auto task = engine.createTask(cfg);
    assert(engine.startTask(task->taskId()));
    waitForSettled(task);
    auto error = task->error();
    assert(task->state() == download::LoadState::Failed && error);
    assert(error->kind == download::ErrorKind::ProtocolError && error->http_status == 404);
    assert(error->native_code == CURLE_HTTP_RETURNED_ERROR && error->url_context == server.url("/last"));
    assert(error->message.find("no available sources") != std::string::npos);
    assert(error->tried_urls.size() == 2 && server.first_requests == 1 && server.last_requests == 1);
    assert(engine.ipResolveFor("127.0.0.1") == CURL_IPRESOLVE_V4);
    std::cout << "PASS all-source 404 keeps protocol, curl and last URL bytes=" << size << std::endl;
}

/** HTTP 403/500 后换源成功仍应复用已经证实连通的 IPv4，而不是转向夹具不存在的 IPv6。 */
static void statusThenSuccess(download::DownloadEngine& engine, const fs::path& root, size_t size,
                              const std::string& endpoint) {
    StatusHttpFixture server(size);
    engine.noteFamilyOutcome("127.0.0.1", CURL_IPRESOLVE_V4, "127.0.0.1", true, false);
    auto cfg = config("HTTP error fallback", root,
                      root / ("status-fallback-" + std::to_string(size) + endpoint.substr(1)));
    cfg.files[0].urls = {server.url(endpoint), server.url("/ok")};
    cfg.files[0].check.expected_size = size;
    cfg.files[0].max_connections = 1;
    auto task = engine.createTask(cfg);
    assert(engine.startTask(task->taskId()));
    waitForSettled(task);
    assert(task->state() == download::LoadState::Finished && server.success_requests == 1);
    assert(!task->error() && !task->files()[0]->error() && task->failedFiles().empty());
    assert(fs::file_size(cfg.files[0].local_path) == size);
    assert(engine.ipResolveFor("127.0.0.1") == CURL_IPRESOLVE_V4);
    // 已结束任务再次取消时可能没有 pending；通知必须保持幂等，后续任务仍能正常入队。
    assert(engine.cancelTask(task->taskId()) && task->state() == download::LoadState::Finished);
    std::cout << "PASS HTTP " << endpoint << " fallback preserves IPv4 bytes=" << size << std::endl;
}

/** 真实授权 503 保留续领分类、来源、120 秒 Retry-After，不误报无源或连接故障。 */
static void authorizedRateLimit(download::DownloadEngine& engine, const fs::path& root, size_t size) {
    // 主机级 Retry-After 会影响后续任务；用各自回环 IP 隔离，不修改生产冷却状态。
    StatusHttpFixture server(size, size < 1024 * 1024 ? "127.0.0.2" : "127.0.0.3");
    auto cfg = config("authorized Retry-After", root, root / ("authorized-503-" + std::to_string(size)));
    auto& file = cfg.files[0];
    file.urls = {server.url("/rate")};
    file.check.expected_size = size;
    file.max_connections = 1;
    file.bearer_token = "fixture-only-token";
    file.authorized_policy = true;
    file.authorized_single_use = true;
    file.authorized_max_http_attempts = 1;
    file.authorized_valid_for_ms = 300000;
    file.authorized_max_bytes = size;
    auto task = engine.createTask(cfg);
    assert(engine.startTask(task->taskId()));
    waitForSettled(task);
    auto error = task->error();
    assert(task->state() == download::LoadState::Failed && error && error->needs_new_lease);
    assert(error->kind == download::ErrorKind::AuthorizationRenewalRequired && error->http_status == 503);
    assert(error->url_context == server.url("/rate") && error->retry_after_ms == 120000);
    assert(error->request_started && error->http_attempts == 1);
    std::cout << "PASS authorization 503 preserves Retry-After bytes=" << size << std::endl;
}

/**
 * 真实混合 403/500 所有源失败，跨文件级 retry epoch 后仍保留最近实际 HTTP 原因。
 * 主机只用于本用例；将最后状态与夹具实取最后请求对照，不假定加权选源固定哪条先结束。
 * worker 的 500 是短退避，整个回放仍受等待收敛上限约束。
 */
static void mixedHttpFailures(download::DownloadEngine& engine, const fs::path& root) {
    constexpr size_t size = 3 * 1024 * 1024;
    StatusHttpFixture server(size, "127.0.0.5");
    engine.noteFamilyOutcome(server.host, CURL_IPRESOLVE_V4, server.host, true, false);
    auto cfg = config("mixed HTTP failures", root, root / "status-mixed-403-500");
    cfg.files[0].urls = {server.url("/forbidden"), server.url("/server")};
    cfg.files[0].check.expected_size = size;
    cfg.files[0].max_connections = 1;
    auto task = engine.createTask(cfg);
    assert(engine.startTask(task->taskId()));
    waitForSettled(task);
    auto error = task->error();
    const int status = server.last_failure_status.load();
    assert(task->state() == download::LoadState::Failed && error);
    assert(error->kind == download::ErrorKind::ProtocolError && error->http_status == status);
    assert(status == 403 || status == 500);
    assert(error->native_code == CURLE_HTTP_RETURNED_ERROR);
    assert(error->url_context == server.url(status == 403 ? "/forbidden" : "/server"));
    assert(error->message.find("no available sources") != std::string::npos);
    assert(engine.ipResolveFor(server.host) == CURL_IPRESOLVE_V4);
    std::cout << "PASS mixed HTTP errors preserve latest response after file retries " << error->toString() << std::endl;
}

/** 未发请求时不得从源缓存拿旧 404 充当本轮失败原因；全部坏内容源应如实报告无可用源。 */
static void noRequestUsesGenericError(download::DownloadEngine& engine, const fs::path& root) {
    StatusHttpFixture server(4096, "127.0.0.6");
    auto cfg = config("unattempted excluded source", root, root / "status-unattempted");
    cfg.files[0].urls = {server.url("/first")};
    cfg.files[0].check.expected_size = 4096;
    auto task = engine.createTask(cfg);
    auto source = task->files()[0]->sources()[0];
    auto stale = download::makeException(download::ErrorKind::ProtocolError, "old unrelated 404");
    stale->http_status = 404;
    stale->url_context = server.url("/last");
    source->setLastError(stale);
    source->checksum_bad = true;
    assert(engine.startTask(task->taskId()));
    waitForSettled(task);
    auto error = task->error();
    assert(task->state() == download::LoadState::Failed && error);
    assert(error->kind == download::ErrorKind::ConnectionError && error->http_status == 0 && error->url_context.empty());
    assert(server.first_requests == 0 && server.last_requests == 0);
    assert(stale->message == "old unrelated 404");
    std::cout << "PASS no request does not reuse stale source error" << std::endl;
}

/**
 * 直接证明 producer 身份接入后的 Native 预检：目标已有正确字节且带真实 SHA1+size，
 * 即使全部 URL 都只会返回 404，也必须在任何 HTTP/HEAD 请求前判 Finished。
 * 最小夹具是 22 字节合法空 ZIP/JAR 容器（文件本身非空）；realistic_size=true 使用
 * 4096 字节固定输入，覆盖现实大小下的同一 exact size/SHA1 规格。Native checker
 * 没有 minSize 字段；来源普通文件、完整 JAR 与来源/目标一致性由 ArkTS 契约负责。
 * 两份固定摘要由独立 SHA1 工具实取，这里不把字节夹具当作可启动的 Forge 程序。
 * 同大小篡改和错误期望摘要两个反例必须进入实际 GET 并失败，不能仅凭存在/大小复用。
 */
static void verifiedExistingArtifact(download::DownloadEngine& engine, const fs::path& root,
                                     bool realistic_size = false) {
    const std::string producer_jar = realistic_size ? std::string(4096, 's')
        : std::string("PK\x05\x06", 4) + std::string(18, '\0');
    const std::string producer_sha1 = realistic_size ? "03f59c86d4f5f7f1b7f4cd2d3cd1891e8a3b6f02"
        : "b04f3ee8f5e43fa3b162981b50bb72fe1acabb33";
    download::Sha1 producer_digest;
    producer_digest.update(producer_jar.data(), producer_jar.size());
    assert(producer_digest.finalizeHex() == producer_sha1);

    for (int variant = 0; variant < 3; ++variant) {
        // 独占路径和服务器，避免正确预检任务仍持有路径所有权或上一反例404状态串组。
        StatusHttpFixture server(producer_jar.size(), "127.0.0." + std::to_string(10 + variant + (realistic_size ? 3 : 0)));
        const fs::path target = root / ("verified-bundled-" + std::to_string(producer_jar.size())
                                        + "-" + std::to_string(variant) + ".jar");
        std::string existing = producer_jar;
        if (variant == 1) existing.back() = 'x';
        write(target, existing);
        assert(fs::file_size(target) == producer_jar.size());

        auto cfg = config("verified producer artifact precheck", root, target);
        cfg.files[0].urls = {server.url("/first")};
        cfg.files[0].check.expected_size = producer_jar.size();
        cfg.files[0].check.expected_sha1 = variant == 2 ? std::string(40, 'f') : producer_sha1;
        auto task = engine.createTask(cfg);
        assert(engine.startTask(task->taskId()));
        waitForSettled(task);
        if (variant == 0) {
            assert(task->state() == download::LoadState::Finished && !task->error());
            assert(server.first_requests == 0 && task->computeProgress().files_done == 1);
            std::cout << "PASS verified producer SHA1+size precheck Finished with zero HTTP requests bytes="
                      << producer_jar.size() << std::endl;
        } else {
            auto error = task->error();
            assert(task->state() == download::LoadState::Failed && error);
            assert(error->kind == download::ErrorKind::ProtocolError && error->http_status == 404);
            assert(server.first_requests == 1);
            // 下载失败保留原目标，避免“预检不命中”被测试误解为允许先删用户已有内容。
            std::ifstream saved(target, std::ios::binary);
            const std::string after((std::istreambuf_iterator<char>(saved)), std::istreambuf_iterator<char>());
            assert(after == existing);
            std::cout << "PASS existing artifact " << (variant == 1 ? "same-size tamper" : "wrong SHA1")
                      << " is not reused and performs one actual GET bytes=" << producer_jar.size() << std::endl;
        }
    }
}

/**
 * 用已 bind、未 listen 的回环端口产生真实 CURLE_COULDNT_CONNECT，零 HTTP、零正文。
 * 一次性授权只限制后续 GET，地址族记账仍应把真实 IPv4 连接失败记为负分并选择 IPv6。
 * 因而无需等待公网超时或多轮熔断，也能证明 HTTP 修复没有禁掉实际连接失败的换族机制。
 */
static void connectionFailureStillChangesFamily(download::DownloadEngine& engine, const fs::path& root) {
    const std::string host = "127.0.0.9";
    int reserved = ::socket(AF_INET, SOCK_STREAM, 0);
    assert(reserved >= 0);
    sockaddr_in address{};
    address.sin_family = AF_INET;
    assert(::inet_pton(AF_INET, host.c_str(), &address.sin_addr) == 1);
    assert(::bind(reserved, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
    socklen_t length = sizeof(address);
    assert(::getsockname(reserved, reinterpret_cast<sockaddr*>(&address), &length) == 0);
    const std::string url = "http://" + host + ":" + std::to_string(ntohs(address.sin_port)) + "/refused";
    engine.noteFamilyOutcome(host, CURL_IPRESOLVE_V4, host, true, false);
    auto cfg = config("real refused connection", root, root / "status-refused-connection");
    auto& file = cfg.files[0];
    file.urls = {url};
    file.check.expected_size = 3 * 1024 * 1024;
    file.max_connections = 1;
    file.bearer_token = "fixture-only-token";
    file.authorized_policy = true;
    file.authorized_single_use = true;
    file.authorized_max_http_attempts = 1;
    file.authorized_valid_for_ms = 300000;
    file.authorized_max_bytes = file.check.expected_size;
    auto task = engine.createTask(cfg);
    assert(engine.startTask(task->taskId()));
    waitForSettled(task);
    auto error = task->error();
    assert(task->state() == download::LoadState::Failed && error && error->needs_new_lease);
    assert(error->native_code == CURLE_COULDNT_CONNECT && error->http_status == 0 && error->url_context == url);
    assert(engine.ipResolveFor(host) == CURL_IPRESOLVE_V6);
    assert(::close(reserved) == 0);
    std::cout << "PASS real zero-HTTP connection failure still changes IP family" << std::endl;
}

/** 取消正在 HTTP 503 冷却的任务，验证此前 HTTP 失败不会变成取消结果里的旧 lastError。 */
static void cancelDuringHttpCooldown(download::DownloadEngine& engine, const fs::path& root) {
    StatusHttpFixture server(4096, "127.0.0.7");
    auto cfg = config("cancel HTTP cooldown", root, root / "status-cancelled");
    cfg.files[0].urls = {server.url("/rate")};
    cfg.files[0].check.expected_size = 4096;
    auto task = engine.createTask(cfg);
    assert(engine.startTask(task->taskId()));
    // 等到生产源冷却已发布，确保测到的是 pending 等待取消，而非碰巧取消在途 HTTP。
    auto source = task->files()[0]->sources()[0];
    for (int i = 0; i < 300 && source->cooldown_until_ms.load() <= download::netThreadSteadyNowMs(); ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    assert(server.last_failure_status == 503);
    assert(source->cooldown_until_ms.load() - download::netThreadSteadyNowMs() > 110000);
    const auto cancel_started = std::chrono::steady_clock::now();
    assert(engine.cancelTask(task->taskId()));
    waitForSettled(task);
    assert(task->state() == download::LoadState::Aborted && !task->error() && task->failedFiles().empty());
    const auto cancel_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - cancel_started).count();
    assert(cancel_ms < 2000 && task->isExecutionSettled());
    std::cout << "PASS cancellation during 120s HTTP cooldown settles owners in " << cancel_ms << "ms" << std::endl;
}

/** shutdown 同样必须中断长冷却并等待真实 owner 回收；随后重复 shutdown 验证空队列幂等。 */
static void shutdownDuringHttpCooldown(download::DownloadEngine& engine, const fs::path& root) {
    StatusHttpFixture server(4096, "127.0.0.8");
    auto cfg = config("shutdown HTTP cooldown", root, root / "status-shutdown");
    cfg.files[0].urls = {server.url("/rate")};
    cfg.files[0].check.expected_size = 4096;
    auto task = engine.createTask(cfg);
    std::mutex mutex; std::condition_variable changed; bool entered = false, release = false;
    std::atomic<int> nested_returns{0}, external_returns{0};
    task->setOnComplete([&](bool success, bool aborted, download::DownloadExceptionPtr,
                            const download::TaskProgress&) {
        assert(!success && aborted);
        // 外部 shutdown 自身发布的同步 callback 再反入，也必须在等 ShuttingDown 前拒绝。
        engine.shutdown(); ++nested_returns;
        std::unique_lock<std::mutex> lock(mutex); entered = true; changed.notify_all();
        changed.wait(lock, [&] { return release; });
    });
    assert(engine.startTask(task->taskId()));
    auto source = task->files()[0]->sources()[0];
    for (int i = 0; i < 300 && source->cooldown_until_ms.load() <= download::netThreadSteadyNowMs(); ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    assert(server.last_failure_status == 503);
    assert(source->cooldown_until_ms.load() - download::netThreadSteadyNowMs() > 110000);
    const auto stop_started = std::chrono::steady_clock::now();
    std::thread first([&] { engine.shutdown(); ++external_returns; });
    std::thread second([&] { engine.shutdown(); ++external_returns; });
    {
        std::unique_lock<std::mutex> lock(mutex);
        assert(changed.wait_for(lock, std::chrono::seconds(5), [&] { return entered; }));
        assert(nested_returns == 1 && external_returns == 0); release = true;
    }
    changed.notify_all(); first.join(); second.join();
    const auto stop_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - stop_started).count();
    assert(stop_ms < 2000 && external_returns == 2 && task->state() == download::LoadState::Aborted && task->isExecutionSettled());
    engine.shutdown();
    auto rejected = engine.createTask(config("rejected after shutdown", root, root / "after-shutdown.jar"));
    assert(rejected->state() == download::LoadState::Failed && rejected->error()->kind == download::ErrorKind::InternalError);
    std::cout << "PASS shutdown during 120s HTTP cooldown settles owners in " << stop_ms << "ms" << std::endl;
}

/** 调度说明写入独立副本；CURL/HTTP/URL 与授权结构化事实全部保持，不污染源持有的异常。 */
static void terminationErrorCopy() {
    auto source = download::makeException(download::ErrorKind::ProtocolError, "HTTP 500");
    source->native_code = CURLE_HTTP_RETURNED_ERROR;
    source->http_status = 500;
    source->url_context = "http://fixture/server";
    source->tried_urls = {source->url_context};
    source->needs_new_lease = true;
    source->request_started = true;
    source->successful_headers_seen = true;
    source->bytes_written = 123;
    source->http_attempts = 4;
    source->retry_after_ms = 120000;
    auto terminal = download::makeRetryTerminationException(source, "no available sources");
    assert(terminal != source && source->message == "HTTP 500");
    assert(terminal->kind == source->kind && terminal->native_code == source->native_code);
    assert(terminal->http_status == 500 && terminal->url_context == source->url_context);
    assert(terminal->tried_urls == source->tried_urls && terminal->needs_new_lease);
    assert(terminal->request_started && terminal->successful_headers_seen && terminal->bytes_written == 123);
    assert(terminal->http_attempts == 4 && terminal->retry_after_ms == 120000);
    auto empty = download::makeRetryTerminationException(nullptr, "no request attempted");
    assert(empty->kind == download::ErrorKind::ConnectionError && empty->http_status == 0 && empty->url_context.empty());
    std::cout << "PASS terminal error copies cause and preserves authorization facts" << std::endl;
}
#include "transport_policy_cases.h"
#include "source_contribution_cases.h"
#include "unknown_size_cases.h"
#include "metadata_fallback_cases.h"

int main(int argc, char** argv) {
    // 定向入口运行同一生产核心和正式用例，便于小修验证；默认仍运行完整既有回归。
    const bool unknown_size_only = argc == 3 && std::string(argv[2]) == "--unknown-size-only";
    const bool metadata_only = argc == 3 && std::string(argv[2]) == "--metadata-only";
    assert(argc == 2 || unknown_size_only || metadata_only);
    fs::path parent = fs::absolute(argv[1]).lexically_normal();
    assert(parent != parent.root_path());
    fs::path root = parent / ("native-" + std::to_string(std::chrono::system_clock::now().time_since_epoch().count()));
    fs::create_directories(root);
    // 宿主显式绑定合法应用files域；生产未知root/fence必须拒绝，不提供测试放行旁路。
    assert(amcl::ConfigureUpdateInstallFilesRoot(root.string()));
    // 借用 fd 的校验必须从零读取、不改变调用者偏移，且拒绝大小/哈希错误。
    write(root / "checked.jar", "GOOD");
    int checked_fd = ::open((root / "checked.jar").c_str(), O_RDONLY | O_CLOEXEC);
    assert(checked_fd >= 0);
    assert(::lseek(checked_fd, 2, SEEK_SET) == 2);
    download::Sha1 hasher;
    hasher.update("GOOD", 4);
    download::FileChecker checker;
    checker.expected_size = 4;
    checker.expected_sha1 = hasher.finalizeHex();
    assert(!checker.checkFd(checked_fd));
    assert(::lseek(checked_fd, 0, SEEK_CUR) == 2);
    checker.expected_size = 5;
    assert(checker.checkFd(checked_fd)->kind == download::ErrorKind::SizeMismatch);
    assert(::close(checked_fd) == 0);
    std::cout << "PASS checker borrows fd without changing offset" << std::endl;
    auto& engine = download::DownloadEngine::instance();
    if (metadata_only) {
        runMetadataFallbackCases(engine);
        engine.shutdown();
        return 0;
    }
    if (unknown_size_only) {
        runUnknownSizeCases(engine, root);
        engine.shutdown();
        return 0;
    }
    auto first = engine.createTask(config("version-a libraries", root, root / "shared.jar"));
    auto second = engine.createTask(config("version-b libraries", root, root / "shared.jar"));
    assert(first->state() == download::LoadState::Waiting);
    assert(second->state() == download::LoadState::Failed);
    std::cout << "{\"case\":\"native-rejects-uncoordinated-double-write\",\"firstWaiting\":true,\"secondFailed\":true}" << std::endl;
    idleDownloadThreads("initial waiting tasks");
    emptyTaskReleasesInstallLease(engine, root);
    idleDownloadThreads("after synchronous terminal");
    fileTaskIdentity(engine, root);
    startupCallbackBarrier(engine, root);
    startupHttpBarrier(engine, root);
    metadataTrustedParent(root);
    unknownSizeStartsAfterFirstSource(engine, root);
    oversizedHeadNeverReachesStorage(engine, root);
    cancelledFileCannotGrow(engine, root);
    adaptiveAllocationFailureKeepsCoverage(root);
    resumeAllFinishedSettlesSynchronously(root);
    completionAllocationFailureRetainsTerminalFacts(root);
    concurrentFileResultsRemainFailed(root);
    internalShutdownIsRejected(engine, root);

    // 用真实curl multi多次覆盖“刚启动即退出”和“已进入无限等待再退出”，join不得挂起。
    for (int i = 0; i < 20; ++i) {
        download::MultiDownloader idle(download::MultiDownloader::Config{});
        idle.start();
        if (i % 2) std::this_thread::sleep_for(std::chrono::milliseconds(5));
        idle.shutdown(); idle.shutdown();
    }

    fs::path allowed = root / "trusted";
    fs::path outside = root / "outside";
    fs::path target = allowed / "sub" / "victim.jar";
    write(target, "GOOD"); write(outside / "victim.jar", "USER-DATA");
    auto changedParent = engine.createTask(config("precheck parent replacement", allowed, target));
    assert(changedParent->state() == download::LoadState::Waiting);
    fs::rename(allowed / "sub", allowed / "original-sub");
    fs::create_directory_symlink(outside, allowed / "sub");
    assert(fs::exists(outside / "victim.jar"));
    engine.startTask(changedParent->taskId());
    for (int i = 0; i < 300 && changedParent->state() == download::LoadState::Loading; ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    assert(changedParent->state() == download::LoadState::Failed);
    bool preserved = fs::exists(outside / "victim.jar");
    assert(preserved);
    std::cout << "{\"case\":\"precheck-preserves-file-outside-replaced-parent\",\"rejected\":true,\"outsideFilePreserved\":true}" << std::endl;
    std::cout << "fixture=" << root.string() << std::endl;
    authorizedTransfer(engine,root,4096);
    authorizedTransfer(engine,root,3*1024*1024);
    authorizedTransfer(engine,root,4096,true);
    authorizedTransfer(engine,root,3*1024*1024,false,false);
    terminationErrorCopy();
    for (size_t size : {size_t(4096), size_t(3 * 1024 * 1024)}) {
        missingSources(engine, root, size);
        statusThenSuccess(engine, root, size, "/forbidden");
        statusThenSuccess(engine, root, size, "/server");
        authorizedRateLimit(engine, root, size);
    }
    mixedHttpFailures(engine, root);
    noRequestUsesGenericError(engine, root);
    verifiedExistingArtifact(engine, root);
    verifiedExistingArtifact(engine, root, true);
    connectionFailureStillChangesFamily(engine, root);
    cleanupPreservesForeignFiles(engine, root);
    runTransportPolicyCases(engine, root);
    runSourceContributionCases(engine, root);
    runUnknownSizeCases(engine, root);
    runMetadataFallbackCases(engine);
    cancelDuringHttpCooldown(engine, root);
    idleDownloadThreads("after real HTTP success failure and cancellation");
    shutdownDuringHttpCooldown(engine, root);
}
