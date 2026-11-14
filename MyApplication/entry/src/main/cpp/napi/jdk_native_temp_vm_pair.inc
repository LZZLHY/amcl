/**
 * 仅由jdk_java_qualification.cpp的TestHooks匿名namespace包含。
 * 同一个NAPI Job/active门负责固定两NCP；只注册一个SDK退出回调，client不重复安装target持SH的槽。
 * 超时只用已核provider的官方Kill。清理有界，正常迟到exit通过现有NAPI事件循环回收；
 * env已关闭时，仅在两个真实exit和worker交还都齐全后启动一次性native清理，不保留正常owner。
 * 不新增broker、后台轮询或任意命令入口；未收齐实际退出绝不授资格。
 */
struct NativeTempPairSession;
std::mutex pairCallbackMutex;
std::shared_ptr<NativeTempPairSession> pairCallbackOwner;
void nativeTempPairExit(int32_t pid, int32_t signal);
void closeNativeTempPairEnvironment(void* data) noexcept;
void scheduleClosedNativeTempPair(const std::shared_ptr<NativeTempPairSession>& self) noexcept;

struct NativeTempPairSession : std::enable_shared_from_this<NativeTempPairSession> {
    amcl::temppair::PairOwner exits;
    // 一个短临界区覆盖句柄读取、acquire、nonblocking call和release；env关闭不能插在读取/acquire之间。
    // 不持此锁调用SDK、等待子进程、释放base引用或注销hook；这些路径可能间接触发finalizer。
    std::mutex dispatchMutex;
    napi_threadsafe_function cleanup = nullptr;
    bool cleanupHookRegistered = false;
    std::atomic<bool> environmentClosed{false};
    std::atomic<bool> reclaimStarted{false};
    std::atomic<int> reclaimThreadError{0};
    std::atomic<bool> dispatchFailed{false};
    std::unique_ptr<ChildProcessProvider> provider;
    io::Fd pairDirectory;
    std::array<io::Fd, 2> readers;
    bool registered = false, timedOut = false, cleanupIncomplete = false, cleanupAttempted = false;
    std::array<int, 2> lastKill{{-999, -999}};
    std::string path, nonce;
    NativeTempPairSession() : exits(notify, this) {}
    static void notify(void* pointer) noexcept {
        auto* self = static_cast<NativeTempPairSession*>(pointer);
        if (self->environmentClosed.load(std::memory_order_acquire)) {
            scheduleClosedNativeTempPair(self->shared_from_this()); return;
        }
        std::lock_guard<std::mutex> guard(self->dispatchMutex);
        const auto function = self->cleanup;
        if (!function || napi_acquire_threadsafe_function(function) != napi_ok) {
            self->dispatchFailed.store(true, std::memory_order_release); return;
        }
        // 只使用SDK明确规定立即返回的nonblocking调用；JS回收可等待此短临界区，不等待JS执行。
        if (napi_call_threadsafe_function(function, nullptr, napi_tsfn_nonblocking) != napi_ok)
            self->dispatchFailed.store(true, std::memory_order_release);
        napi_release_threadsafe_function(function, napi_tsfn_release);
    }
    // 任一C++失败路径也只等有限清理预算；回调及provider由固定session继续持有，直到实际迟到退出。
    void stopBounded() noexcept {
        if (cleanupAttempted) return;
        cleanupAttempted = true;
        exits.seal();
        const auto limit = Clock::now() + std::chrono::seconds(8);
        auto next = Clock::now();
        while (!exits.allExited() && Clock::now() < limit) {
            if (provider && Clock::now() >= next) {
                const auto state = exits.snapshot();
                for (size_t i = 0; i < state.slots.size(); ++i)
                    if (state.slots[i].pid > 0 && !state.slots[i].observed)
                        lastKill[i] = provider->function()(state.slots[i].pid);
                next = Clock::now() + std::chrono::seconds(1);
            }
            poll(nullptr, 0, 25);
        }
        cleanupIncomplete = !exits.allExited();
    }
};

/** env可能先于两个NCP退出。先与投递互斥地撤掉句柄，再在锁外abort其base引用。
 * 关闭后绝不再进入NAPI；已排队但被abort丢弃的回收改交一次性native清理。尚未退出时，
 * 等PairOwner真实收齐事件后再发出同一动作，不等待env、不保留正常已退出的资源。 */
void closeNativeTempPairEnvironment(void* data) noexcept {
    auto self = static_cast<NativeTempPairSession*>(data)->shared_from_this();
    napi_threadsafe_function function = nullptr;
    {
        std::lock_guard<std::mutex> guard(self->dispatchMutex);
        self->environmentClosed.store(true, std::memory_order_release);
        self->dispatchFailed.store(true, std::memory_order_release);
        self->cleanupHookRegistered = false; // 当前hook由env消费，不能再次remove。
        function = self->cleanup;
        self->cleanup = nullptr;
    }
    if (function) napi_release_threadsafe_function(function, napi_tsfn_abort);
    scheduleClosedNativeTempPair(self);
}

/** 仅在创建/完成所在的有效env线程调用。先移除hook，再交换句柄，最后锁外释放base引用。
 * 函数失败时保持fixed owner与busy，不能把未确认的环境生命周期当成功回收。 */
bool detachNativeTempPairDispatch(napi_env env, NativeTempPairSession& self,
                                  napi_threadsafe_function_release_mode mode) noexcept {
    if (self.environmentClosed.load(std::memory_order_acquire)) return false;
    if (self.cleanupHookRegistered) {
        if (napi_remove_env_cleanup_hook(env, closeNativeTempPairEnvironment, &self) != napi_ok) {
            self.dispatchFailed.store(true, std::memory_order_release); return false;
        }
        self.cleanupHookRegistered = false;
    }
    napi_threadsafe_function function = nullptr;
    {
        std::lock_guard<std::mutex> guard(self.dispatchMutex);
        function = self.cleanup;
        self.cleanup = nullptr;
    }
    if (function && napi_release_threadsafe_function(function, mode) != napi_ok) {
        self.dispatchFailed.store(true, std::memory_order_release); return false;
    }
    return true;
}
void nativeTempPairExit(int32_t pid, int32_t signal) {
    std::shared_ptr<NativeTempPairSession> owned;
    { std::lock_guard<std::mutex> guard(pairCallbackMutex); owned = pairCallbackOwner; }
    if (owned) owned->exits.exited(pid, signal);
}

/** 只在JS回收或一次性native线程调用；绝不在SDK退出回调栈中卸载provider。
 * 两个exit和workerReleased已在排队前确认，故不会和worker读写FD/调用Kill发生竞争。 */
void reclaimNativeTempPairResources(const std::shared_ptr<NativeTempPairSession>& self, bool afterEnvironment) noexcept {
    int unregistered = 0;
    if (self->registered) {
        unregistered = OH_Ability_UnregisterNativeChildProcessExitCallback(nativeTempPairExit);
        if (unregistered != 0) self->dispatchFailed.store(true, std::memory_order_release);
        // 回调入口是本TU静态函数，只从global shared_ptr借session，不捕获被销毁对象。
        // 全部PID已退出时，即使SDK撤销失败也可清空global；残留回调安全忽略无owner事件。
        // 错误原值使本轮验收失败，资源归还后仍保持busy到重启，不尝试下一轮注册或假设去重。
        self->registered = false;
    }
    try {
        if (self->pairDirectory.get() >= 0) {
            const auto state = self->exits.snapshot();
            std::ostringstream text;
            text << "{\"schema\":1,\"stage\":\"pair-owner-reclaimed\",\"targetPid\":" << state.slots[0].pid
                 << ",\"clientPid\":" << state.slots[1].pid << ",\"targetExitObserved\":" << (state.slots[0].observed ? "true" : "false")
                 << ",\"clientExitObserved\":" << (state.slots[1].observed ? "true" : "false")
                 << ",\"lateCleanup\":" << (self->cleanupIncomplete ? "true" : "false")
                 << ",\"environmentClosed\":" << (afterEnvironment ? "true" : "false")
                 << ",\"reclaimExecutor\":\"" << (afterEnvironment ? "one-shot-native" : "napi-loop")
                 << "\",\"unregisterResult\":" << unregistered
                 << ",\"restartRequired\":" << (unregistered == 0 ? "false" : "true") << "}\n";
            writeNew(self->pairDirectory.get(), "owner-reclaimed.json", text.str());
        }
    } catch (...) { self->dispatchFailed.store(true, std::memory_order_release); }
    for (auto& reader : self->readers) reader = io::Fd();
    self->pairDirectory = io::Fd(); self->provider.reset();
    self->exits.reclaimed();
    { std::lock_guard<std::mutex> guard(pairCallbackMutex);
      if (pairCallbackOwner.get() == self.get()) pairCallbackOwner.reset(); }
    // 注销失败时原静态回调可能仍在SDK注册表；资源可释放，但不得接入新owner混淆事件世代。
    // 此明确API失败保持busy到父进程重启，不保留FD/provider，也不假定重复注册会去重。
    active.store(unregistered != 0, std::memory_order_release);
}

/** env关闭后仅创建一个已经detached的POSIX线程，立即注销/释放后返回，无等待、轮询或Kill。
 * 使用pthread属性在创建时确定detached，避免std::thread创建后detach抛异常的joinable析构边界。
 * 创建失败保留确切错误和fixed owner；不重试创建线程风暴，不把失败假装回收成功。 */
void scheduleClosedNativeTempPair(const std::shared_ptr<NativeTempPairSession>& self) noexcept {
    if (!self->environmentClosed.load(std::memory_order_acquire) ||
        !self->exits.snapshot().reclaimQueued || !self->exits.allExited()) return;
    bool expected = false;
    if (!self->reclaimStarted.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) return;
    auto* holder = new (std::nothrow) std::shared_ptr<NativeTempPairSession>(self);
    int code = holder ? 0 : ENOMEM;
    pthread_attr_t attributes;
    bool initialized = false;
    if (code == 0) { code = pthread_attr_init(&attributes); initialized = code == 0; }
    if (code == 0) code = pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    if (code == 0) {
        pthread_t thread;
        code = pthread_create(&thread, &attributes, [](void* data) noexcept -> void* {
            std::unique_ptr<std::shared_ptr<NativeTempPairSession>> owned(
                static_cast<std::shared_ptr<NativeTempPairSession>*>(data));
            reclaimNativeTempPairResources(*owned, true);
            return nullptr;
        }, holder);
    }
    if (initialized) pthread_attr_destroy(&attributes);
    if (code != 0) {
        delete holder;
        self->reclaimThreadError.store(code, std::memory_order_release);
        self->dispatchFailed.store(true, std::memory_order_release);
        // 失败发生在普通parent-report已落盘之后，必须另留可回读证据，不能只改内存中的标记。
        // 不在此处关闭provider或注销SDK；静态回调借用的owner仍完整，下一次Start仍被busy拒绝。
        try {
            const auto state = self->exits.snapshot();
            std::ostringstream report;
            report << "{\"schema\":1,\"stage\":\"pair-owner-cleanup-failed\",\"threadCreateResult\":" << code
                   << ",\"environmentClosed\":true,\"targetPid\":" << state.slots[0].pid
                   << ",\"clientPid\":" << state.slots[1].pid
                   << ",\"targetExitObserved\":" << (state.slots[0].observed ? "true" : "false")
                   << ",\"clientExitObserved\":" << (state.slots[1].observed ? "true" : "false")
                   << ",\"restartRequired\":true,\"osExitStatus\":null}\n";
            writeNew(self->pairDirectory.get(), "owner-cleanup-failed.json", report.str());
        } catch (...) {
            // 文件系统同时失败时保留固定、无路径/敏感正文的stderr错误；不能因此再尝试启动线程。
            fprintf(stderr, "AMCL_NATIVE_TEMP_PAIR_CLEANUP_FAILED threadCreateResult=%d evidenceWriteFailed=1\n", code);
        }
    }
}

/** 有效env走原事件循环；env=null是引擎清空队列的通知，必须在解引用context之前返回。
 * 官方实现先调用finalizer再清空剩余队列，context此时可能已失去最后一个owner。 */
void reclaimNativeTempPair(napi_env env, napi_value, void* context, void*) {
    if (!env) return;
    auto self = static_cast<NativeTempPairSession*>(context)->shared_from_this();
    if (self->environmentClosed.load(std::memory_order_acquire)) return;
    if (!self->exits.snapshot().reclaimQueued || !self->exits.allExited()) return;
    if (!detachNativeTempPairDispatch(env, *self, napi_tsfn_release)) return;
    bool expected = false;
    if (!self->reclaimStarted.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) return;
    reclaimNativeTempPairResources(self, false);
}
void finalizeNativeTempPair(napi_env, void* data, void*) {
    auto* holder = static_cast<std::shared_ptr<NativeTempPairSession>*>(data);
    // 所有release/abort路径均已同步撤销句柄；finalizer只归还TSFN自身持有的shared_ptr。
    // 不能在这里才清空一个可能被SDK线程刚读出的裸指针。
    delete holder;
}
napi_status prepareNativeTempPair(napi_env env, napi_value resource, Job& job) noexcept {
    try {
        job.pair = std::make_shared<NativeTempPairSession>();
        auto* holder = new std::shared_ptr<NativeTempPairSession>(job.pair);
        napi_threadsafe_function function{};
        const auto status = napi_create_threadsafe_function(env, nullptr, nullptr, resource, 1, 1, holder,
            finalizeNativeTempPair, job.pair.get(), reclaimNativeTempPair, &function);
        if (status != napi_ok) { delete holder; job.pair.reset(); return status; }
        job.pair->cleanup = function;
        // 在TSFN创建成功后注册，环境按逆序清理时先关闭我们向TSFN投递的入口。
        const auto hook = napi_add_env_cleanup_hook(env, closeNativeTempPairEnvironment, job.pair.get());
        if (hook != napi_ok) {
            job.pair->cleanup = nullptr;
            napi_release_threadsafe_function(function, napi_tsfn_abort);
            job.pair.reset(); return hook;
        }
        job.pair->cleanupHookRegistered = true;
        // 失败且无迟到exit时不让一个测试TSFN阻止整个父进程退出；owner保持busy直到回收/重启。
        const auto unref = napi_unref_threadsafe_function(env, function);
        if (unref != napi_ok) {
            detachNativeTempPairDispatch(env, *job.pair, napi_tsfn_abort);
            job.pair.reset(); return unref;
        }
        return napi_ok;
    } catch (...) { return napi_generic_failure; }
}
void cancelUnstartedNativeTempPair(napi_env env, Job& job) noexcept {
    if (!job.pair) return;
    detachNativeTempPairDispatch(env, *job.pair, napi_tsfn_abort);
    job.pair.reset();
}

/** Properties仅提取固定ASCII身份键；native临时路径也必须是生产已验证的绝对路径。 */
std::string nativeTempProperty(const std::string& text, const std::string& key) {
    const std::string prefix = key + "=";
    size_t from = 0;
    while (from < text.size()) {
        size_t end = text.find('\n', from); if (end == std::string::npos) end = text.size();
        std::string line = text.substr(from, end - from);
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.compare(0, prefix.size(), prefix) == 0) return line.substr(prefix.size());
        from = end + 1;
    }
    return {};
}
/** 退出后只观察原先已有的确切路径；每次lstat立即保存返回值和errno，避免短路丢掉哪一项残留。
 * 成功时记录实际dev/ino/mode/uid/gid；失败元数据为null。这里只读，不unlink或用HDC权限代证。 */
bool observeNativeTempFileGone(const std::string& path, const char* kind, const char* role,
                               std::ostringstream& observations) {
    struct stat value{};
    errno = 0;
    const int result = lstat(path.c_str(), &value);
    const int error = result == 0 ? 0 : errno;
    if (observations.tellp() > 0) observations << ",";
    observations << "{\"kind\":" << quoted(kind) << ",\"role\":" << quoted(role)
                 << ",\"path\":" << quoted(path) << ",\"lstatResult\":" << result
                 << ",\"errno\":" << error << ",\"metadata\":";
    if (result == 0) {
        observations << "{\"dev\":" << static_cast<uint64_t>(value.st_dev)
                     << ",\"ino\":" << static_cast<uint64_t>(value.st_ino)
                     << ",\"mode\":" << static_cast<uint64_t>(value.st_mode)
                     << ",\"uid\":" << static_cast<uint64_t>(value.st_uid)
                     << ",\"gid\":" << static_cast<uint64_t>(value.st_gid) << "}";
    } else observations << "null";
    observations << "}";
    return result != 0 && error == ENOENT;
}
bool exactNativeTempFileGone(const std::string& temporary, const std::string& path, int32_t pid,
                             const char* role, std::ostringstream& observations) {
    io::Require(!temporary.empty() && temporary.front() == '/' && temporary.find('\\') == std::string::npos,
                "native temporary root metadata is not a literal absolute path");
    const std::string prefix = temporary + "/hsperfdata_", suffix = "/" + std::to_string(pid);
    io::Require(path.compare(0, prefix.size(), prefix) == 0 && path.size() > prefix.size() + suffix.size() &&
        path.compare(path.size() - suffix.size(), suffix.size(), suffix) == 0 &&
        path.find('/', prefix.size()) == path.size() - suffix.size(), "PerfData path is not exact owned PID member");
    return observeNativeTempFileGone(path, "perfdata", role, observations);
}

std::string runNativeTempPair(const Job& job) {
    auto& session = *job.pair;
    struct ErrorCleanup { NativeTempPairSession& session; ~ErrorCleanup() { session.stopBounded(); } } cleanup{session};
    io::Require(!session.environmentClosed.load(std::memory_order_acquire), "pair environment closed before worker start");
    session.provider.reset(new ChildProcessProvider());
    char* resolved = realpath(job.files.c_str(), nullptr); io::Require(resolved, "filesDir不存在");
    std::unique_ptr<char, decltype(&free)> canonical(resolved, &free);
    const std::string files(resolved), rootPath = files + "/jdk-runtime-qualification/" + job.nonce;
    auto filesRoot = io::Directory(files);
    auto qualification = io::ChildDirectory(filesRoot.get(), "jdk-runtime-qualification");
    auto root = io::ChildDirectory(qualification.get(), job.nonce);
    io::Require(mkdirat(root.get(), "run-native-temp-vms", 0700) == 0, "pair证据目录已存在");
    session.pairDirectory = io::ChildDirectory(root.get(), "run-native-temp-vms");
    session.path = rootPath + "/run-native-temp-vms"; session.nonce = job.nonce;
    for (const char* role : {"target", "client"}) {
        io::Require(mkdirat(session.pairDirectory.get(), role, 0700) == 0, "pair role目录已存在");
        auto directory = io::ChildDirectory(session.pairDirectory.get(), role);
        writeNew(directory.get(), "qualification.jar", amcl::jdkqualification::FixtureJar, amcl::jdkqualification::FixtureJarSize);
    }
    { std::lock_guard<std::mutex> guard(pairCallbackMutex);
      io::Require(!pairCallbackOwner, "earlier pair owner is still pending"); pairCallbackOwner = job.pair; }
    const int registration = OH_Ability_RegisterNativeChildProcessExitCallback(nativeTempPairExit);
    io::Require(registration == 0, "pair SDK callback registration failed"); session.registered = true;
    std::ostringstream report;
    report << "{\"stage\":\"native-temp-pair-parent\",\"pid\":" << getpid() << ",\"major\":" << quoted(job.major)
           << ",\"fixtureSha256\":" << quoted(amcl::jdkqualification::FixtureJarSha256) << "}\n";
    auto start = [&](unsigned slot, int32_t targetPid) {
        io::Require(!session.environmentClosed.load(std::memory_order_acquire), "pair environment closed before child start");
        int descriptors[2]; if (pipe2(descriptors, O_CLOEXEC | O_NONBLOCK) != 0) io::Error("pair pipe");
        session.readers[slot] = io::Fd(descriptors[0]); io::Fd writeEnd(descriptors[1]);
        char reportName[] = "report", rootName[] = "root", filesName[] = "files";
        NativeChildProcess_Fd realFiles{filesName, filesRoot.get(), nullptr};
        NativeChildProcess_Fd rootFd{rootName, root.get(), &realFiles};
        NativeChildProcess_Fd reportFd{reportName, writeEnd.get(), &rootFd};
        const std::string parameters = rootPath + "\n" + job.major + "\n" + (slot ? "client" : "target") + "\n" + std::to_string(targetPid);
        NativeChildProcess_Args args{const_cast<char*>(parameters.c_str()), {&reportFd}};
        NativeChildProcess_Options options{NCP_ISOLATION_MODE_NORMAL, 0};
        const int result = session.exits.start(slot, [&](int32_t* pid) {
            return static_cast<int>(OH_Ability_StartNativeChildProcess("libentry.so:AmclJdkNativeTempVmMain", args, options, pid));
        });
        const auto startState = session.exits.snapshot();
        report << "{\"stage\":\"pair-child-start\",\"role\":" << quoted(slot ? "client" : "target")
               << ",\"result\":" << result << ",\"sdkResult\":" << startState.slots[slot].startResult
               << ",\"reportedPid\":" << startState.slots[slot].reportedStartPid
               << ",\"poisonedStart\":" << (startState.poisonedStart ? "true" : "false")
               << ",\"pid\":" << startState.slots[slot].pid << "}\n";
        io::Require(result == 0, "pair NativeChildProcess start failed: " + std::to_string(result));
    };
    std::string failure, ready;
    bool clientStarted = false, stopSent = false;
    size_t bytes = 0;
    std::array<std::string, 2> childReports;
    std::array<size_t, 2> childBytes{{0, 0}};
    auto drainPipes = [&] {
        for (size_t i = 0; i < session.readers.size(); ++i) {
            if (session.readers[i].get() < 0) continue;
            // 每次最多读取128KiB，异常生产者不能靠连续输出拖住deadline检查。
            for (unsigned attempt = 0; attempt < 32; ++attempt) {
                char buffer[4096]; const ssize_t count = read(session.readers[i].get(), buffer, sizeof(buffer));
                if (count <= 0) break;
                if (childBytes[i] + static_cast<size_t>(count) <= 128 * 1024) childReports[i].append(buffer, count);
                childBytes[i] += static_cast<size_t>(count); bytes += static_cast<size_t>(count);
            }
        }
    };
    try {
        start(0, 0);
        auto deadline = Clock::now() + Timeout;
        for (;;) {
            io::Require(!session.environmentClosed.load(std::memory_order_acquire), "pair environment closed during qualification");
            pollfd pending[2]{{session.readers[0].get(), POLLIN | POLLHUP, 0}, {session.readers[1].get(), POLLIN | POLLHUP, 0}};
            poll(pending, 2, 25);
            drainPipes();
            auto state = session.exits.snapshot();
            if (!clientStarted && io::Exists(session.pairDirectory.get(), "target-ready.properties")) {
                ready = io::SmallFile(session.pairDirectory.get(), "target-ready.properties", 65536);
                io::Require(nativeTempProperty(ready, "pid") == std::to_string(state.slots[0].pid) &&
                    nativeTempProperty(ready, "nonce") == job.nonce &&
                    nativeTempProperty(ready, "fixtureJarSha256") == amcl::jdkqualification::FixtureJarSha256,
                    "pair target readiness身份不符");
                io::Require(!state.slots[0].observed, "target exited before client start");
                start(1, state.slots[0].pid); clientStarted = true; session.exits.seal();
                deadline = Clock::now() + std::chrono::seconds(30);
            }
            state = session.exits.snapshot();
            if (!clientStarted && state.slots[0].observed) throw std::runtime_error("target exited without readiness");
            if (clientStarted && state.slots[1].observed && !stopSent) {
                writeNew(session.pairDirectory.get(), "stop-target.txt", job.nonce + "\n"); stopSent = true;
            }
            if (clientStarted && session.exits.allExited()) break;
            if (Clock::now() >= deadline) { session.timedOut = true; throw std::runtime_error("pair fixed deadline exceeded"); }
        }
    } catch (const std::exception& error) { failure = error.what(); }
    // client启动被平台拒绝等失败时，先给已ready的target一次有界正常退出机会。
    if (!failure.empty() && !ready.empty() && !stopSent) {
        try {writeNew(session.pairDirectory.get(), "stop-target.txt", job.nonce + "\n");stopSent = true;} catch (...) {}
        const auto grace = Clock::now() + std::chrono::seconds(2);
        while (!session.exits.allExited() && Clock::now() < grace) poll(nullptr, 0, 25);
    }
    session.stopBounded();
    drainPipes(); // 实际退出后补取管道尾部；两个流分开保存，不交错JSON分片。
    const auto state = session.exits.snapshot();
    bool cleanupFiles = false;
    std::ostringstream cleanupFileObservations;
    if (state.slots[0].observed && state.slots[1].observed && !ready.empty()) {
        try {
            auto client = io::ChildDirectory(session.pairDirectory.get(), "client");
            const auto text = io::SmallFile(client.get(), "java-result.properties", 65536);
            const auto temporary = nativeTempProperty(ready, "nativeTmpdir");
            // 三项均实际观察；不能因第一项存在而短路掉第二个VM的PerfData和Attach socket证据。
            const bool targetAbsent = exactNativeTempFileGone(temporary, nativeTempProperty(ready, "selfPerf.path"),
                state.slots[0].pid, "target", cleanupFileObservations);
            const bool clientAbsent = exactNativeTempFileGone(temporary, nativeTempProperty(text, "selfPerf.path"),
                state.slots[1].pid, "client", cleanupFileObservations);
            const std::string socket = temporary + "/.java_pid" + std::to_string(state.slots[0].pid);
            const bool socketAbsent = observeNativeTempFileGone(socket, "attach-socket", "target", cleanupFileObservations);
            cleanupFiles = targetAbsent && clientAbsent && socketAbsent;
        } catch (const std::exception& error) { if (failure.empty()) failure = error.what(); }
    }
    report << "{\"stage\":\"pair-parent-finished\",\"targetPid\":" << state.slots[0].pid << ",\"clientPid\":" << state.slots[1].pid
           << ",\"targetExitObserved\":" << (state.slots[0].observed ? "true" : "false")
           << ",\"clientExitObserved\":" << (state.slots[1].observed ? "true" : "false")
           << ",\"targetCallbackSignal\":" << state.slots[0].callbackSignal << ",\"clientCallbackSignal\":" << state.slots[1].callbackSignal
           << ",\"timedOut\":" << (session.timedOut ? "true" : "false")
           << ",\"cleanupIncomplete\":" << (session.cleanupIncomplete ? "true" : "false")
           << ",\"environmentClosed\":" << (session.environmentClosed.load(std::memory_order_acquire) ? "true" : "false")
           << ",\"poisonedStart\":" << (state.poisonedStart ? "true" : "false")
           << ",\"earlyEventOverflow\":" << (state.earlyOverflow ? "true" : "false")
           << ",\"restartRequiredIfExitMissing\":" << (session.cleanupIncomplete ? "true" : "false")
           << ",\"postExitFilesAbsent\":" << (cleanupFiles ? "true" : "false")
           << ",\"postExitFiles\":[" << cleanupFileObservations.str() << "]" << ",\"reportBytes\":" << bytes
           << ",\"error\":" << quoted(failure) << ",\"osExitStatus\":null}\n";
    for (size_t i = 0; i < childReports.size(); ++i) {
        auto directory = io::ChildDirectory(session.pairDirectory.get(), i ? "client" : "target");
        writeNew(directory.get(), "parent-pipe.txt", childReports[i]);
        report << "{\"stage\":\"pair-pipe\",\"role\":" << quoted(i ? "client" : "target")
               << ",\"bytes\":" << childBytes[i] << ",\"retainedBytes\":" << childReports[i].size()
               << ",\"sha256\":" << quoted(io::Digest(childReports[i])) << "}\n";
    }
    writeNew(session.pairDirectory.get(), "parent-report.txt", report.str());
    return report.str();
}

/** 独立NCP入口的实际VM路径。target独占安装一次，client只读复用，两个jvmInit各自取得SH。
 * files fd与root fd分别核同，第四参使用真实app filesDir而非nonce长路径；TMPDIR由生产helper唯一发布。 */
void runNativeTempPairChild(NativeChildProcess_Args args) {
    int reportFd = -1, rootFd = -1, filesFd = -1;
    for (auto* item = args.fdList.head; item; item = item->next) {
        if (!item->fdName) continue;
        if (!strcmp(item->fdName, "report")) reportFd = item->fd;
        if (!strcmp(item->fdName, "root")) rootFd = item->fd;
        if (!strcmp(item->fdName, "files")) filesFd = item->fd;
    }
    io::Fd reportOwner(reportFd), rootOwner(rootFd), filesOwner(filesFd), run;
    std::unique_ptr<Report> report;
    int init = -999, main = -999, destroy = -999;
    bool completion = false, installedHere = false;
    std::string rootPath, filesPath, major, role, nonce, archive, failure;
    try {
        io::Require(reportFd >= 0 && rootFd >= 0 && filesFd >= 0 && args.entryParams, "pair transferred descriptors missing");
        std::vector<std::string> parts;
        std::istringstream input(args.entryParams); std::string part;
        while (std::getline(input, part)) parts.push_back(part);
        io::Require(parts.size() == 4 && validMajor(parts[1]) && (parts[2] == "target" || parts[2] == "client"), "pair fixed entry parameters invalid");
        rootPath = parts[0]; major = parts[1]; role = parts[2];
        const std::string component = "/jdk-runtime-qualification/";
        const size_t offset = rootPath.rfind(component);
        io::Require(offset != std::string::npos && rootPath.front() == '/', "pair private root missing");
        filesPath = rootPath.substr(0, offset); nonce = rootPath.substr(offset + component.size());
        io::Require(amcl::nativetempprobe::ValidNonce(nonce), "pair nonce invalid");
        auto actualRoot = io::Directory(rootPath), actualFiles = io::Directory(filesPath);
        struct stat expected{}, actual{};
        for (const auto& pair : {std::pair<int,int>{rootFd, actualRoot.get()}, {filesFd, actualFiles.get()}}) {
            io::Require(fstat(pair.first, &expected) == 0 && fstat(pair.second, &actual) == 0 &&
                expected.st_dev == actual.st_dev && expected.st_ino == actual.st_ino && S_ISDIR(actual.st_mode),
                "pair fd/path object identity mismatch");
        }
        auto pairRoot = io::ChildDirectory(rootFd, "run-native-temp-vms");
        run = io::ChildDirectory(pairRoot.get(), role);
        report.reset(new Report(reportFd, run.get()));
        report->line("{\"stage\":\"pair-child\",\"role\":" + quoted(role) + ",\"pid\":" + std::to_string(getpid()) + "}");
        io::Require(jvmRuntimeState() == 0 && !jvmGetJavaVM(), "pair child JVM is not fresh");
        const std::string path = rootPath + "/run-native-temp-vms", own = path + "/" + role;
        io::Require(io::Digest(io::SmallFile(run.get(), "qualification.jar", amcl::jdkqualification::FixtureJarSize + 1)) == amcl::jdkqualification::FixtureJarSha256,
                    "pair JAR bytes differ from compiled TestHooks payload");
        amcl::jvm::PosixProcessorIo system;
        const auto setup = amcl::jvm::PrepareProcessorIo(own.c_str(), (own + "/stdout.log").c_str(), system);
        io::Require(setup.ok(), "pair child stdio/cwd preparation failed");
        if (role == "target") {
            archive = installCandidate(rootPath, rootFd, major, *report);
            writeNew(pairRoot.get(), "installed-sha256.txt", archive + "\n"); installedHere = true;
        } else {
            // 不申请writer/EX、不再次解压。target已经ready且持SH，client由生产jvmInit打开自己的SH。
            archive = archiveDigest(rootFd);
            io::Require(io::SmallFile(pairRoot.get(), "installed-sha256.txt", 66) == archive + "\n" &&
                !amcl::jdk::InstallRecoveryRequired(rootPath, major), "pair shared installed slot is not sealed");
        }
        const auto self = std::to_string(getpid());
        std::string target = role == "target" ? self : parts[3];
        io::Require(!target.empty() && target.size() <= 10 && target.find_first_not_of("0123456789") == std::string::npos &&
            (role == "target" || target != self), "pair target PID is not a distinct real parent-owned child");
        io::Require(setenv("AMCL_GAME_DIR", own.c_str(), 1) == 0, "pair tool directory unavailable");
        jvmSetForkChildMode(1); // 复用既有独立工具参数模式；本入口没有fork或继承VM。
        std::string classpath = own + "/qualification.jar";
        if (major == "8") {
            const std::string tools = rootPath + "/jdk/8/lib/tools.jar";
            struct stat info{}; io::Require(lstat(tools.c_str(), &info) == 0 && S_ISREG(info.st_mode), "classic tools.jar is absent");
            classpath += ":" + tools;
        }
        jvmSetClasspath(classpath.c_str()); jvmSetXmx(256);
        jvmSetCrashOutputPath((own + "/hs_err.log").c_str());
        std::vector<std::string> options{"-Xcheck:jni", "-Djava.awt.headless=true", "-Damcl.native.temp.nonce=" + nonce,
            "-Damcl.native.temp.role=" + role, "-Dsun.tools.attach.attachTimeout=2000", "-XX:ErrorFile=" + own + "/hs_err_pid%p.log"};
        if (major != "8") {
            const char* modern[] = {"--add-modules=jdk.attach,jdk.internal.jvmstat,jdk.management",
                "--add-exports=java.base/jdk.internal.perf=ALL-UNNAMED", "--add-exports=java.base/jdk.internal.vm=ALL-UNNAMED",
                "--add-exports=jdk.internal.jvmstat/sun.jvmstat.monitor=ALL-UNNAMED",
                "--add-exports=jdk.internal.jvmstat/sun.jvmstat=ALL-UNNAMED"};
            options.insert(options.end(), std::begin(modern), std::end(modern));
        }
        // 不加UsePerfData/DisableAttach强制覆盖：必须由新marker合同自然恢复默认，Java再读实际VM flag。
        jvmSetExtraArgsList(options);
        init = jvmInit(rootPath.c_str(), major.c_str(), nullptr, filesPath.c_str());
        io::Require(init == 0, "pair real JVM creation failed: " + std::string(jvmGetStatus()));
        const char* environment = getenv("TMPDIR"); io::Require(environment && environment[0] == '/', "production native TMPDIR missing");
        const std::string temporary(environment);
        const char* arguments[] = {role.c_str(), path.c_str(), major.c_str(), nonce.c_str(), self.c_str(), target.c_str(), temporary.c_str()};
        report->stage("pair-java-main");
        main = jvmCallMain("NativeTempVmQualification", 7, arguments);
        report->line("{\"stage\":\"pair-java-main-return\",\"role\":" + quoted(role) + ",\"result\":" + std::to_string(main) + "}");
        destroy = jvmFinishProcessor();
        if (main == 0 && destroy == 0) {
            completion = true;
            for (const char* name : {"main-completed.txt", "main-ended.txt", "worker.txt", "shutdown.txt"})
                completion = completion && io::SmallFile(run.get(), name, 128) == nonce + "\n";
            io::Require(completion, "pair main/worker/hook completion missing");
        }
        io::Require(main == 0 && destroy == 0, "pair Java or Destroy failed");
    } catch (const std::exception& error) { failure = error.what(); }
    catch (...) { failure = "unknown native pair failure"; }
    if (jvmGetJavaVM() && jvmRuntimeState() == 2 && destroy == -999) {
        try { destroy = jvmFinishProcessor(); } catch (...) { }
    }
    try {
        const bool passed = failure.empty() && init == 0 && main == 0 && destroy == 0 && completion && !jvmGetJavaVM();
        const std::string text = "{\"schema\":1,\"profile\":\"native-temp-vms\",\"role\":" + quoted(role) +
            ",\"major\":" + quoted(major) + ",\"pid\":" + std::to_string(getpid()) + ",\"archiveSha256\":" + quoted(archive) +
            ",\"fixtureSha256\":" + quoted(amcl::jdkqualification::FixtureJarSha256) +
            ",\"installedHere\":" + (installedHere ? "true" : "false") + ",\"initResult\":" + std::to_string(init) +
            ",\"mainResult\":" + std::to_string(main) + ",\"destroyResult\":" + std::to_string(destroy) +
            ",\"completionProof\":" + (completion ? "true" : "false") + ",\"passed\":" + (passed ? "true" : "false") +
            ",\"error\":" + quoted(failure) + "}\n";
        if (run.get() >= 0) writeNew(run.get(), "result.json", text);
        if (report) report->line(text);
    } catch (...) { }
    fflush(stdout); fflush(stderr);
    // 返回官方入口后真实结束；父侧只采SDK退出事件，不把这里的void返回当OS exitcode。
}
