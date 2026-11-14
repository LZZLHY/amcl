/**
 * 手动重定向 URL 的真实 libcurl 回归，复用 transport_policy_cases 的回环服务器。
 * 三条入口都执行生产代码：小正文走 CURLM、大正文走 worker、metadata 走公开 fetch；
 * 服务端只接受精确编码的 request-target，最终正文同时接受 size/SHA1 与逐字节检查。
 * 所有输出位于 native.cpp 本轮创建的外置 fixture root，成功由其统一回收，失败留证。
 */
#pragma once

namespace redirect_url_cases {
using Server = transport_policy_cases::HttpFixture;

struct Case {
    enum class Shape { Path, Absolute, NetworkPath };
    const char* name;
    const char* location;       // 响应头原文；相对地址由真正的 libcurl 解析。
    const char* request_target; // 服务端应实际收到的 path/query，不含 fragment。
    Shape shape = Shape::Path;
};

/** 真实下载前使用固定原文/期望值，绝不在测试服务器调用被测规范化函数产生期望。 */
static const Case cases[] = {
    {"raw-modpack", "/objects/Cobblemon Official Modpack [Fabric] 1.8.4.mrpack",
        "/objects/Cobblemon%20Official%20Modpack%20%5BFabric%5D%201.8.4.mrpack", Case::Shape::Absolute},
    {"encoded", "/objects/name%20%5BFabric%5D%2f%25.jar?sig=a%2Bb+c%2F&sig=second&empty=",
        "/objects/name%20%5BFabric%5D%2f%25.jar?sig=a%2Bb+c%2F&sig=second&empty="},
    {"relative-query-fragment", "../objects/name [Fabric].jar?sig=a%2Bb+c%2F&sig=two#client%20fragment+%2f",
        "/objects/name%20%5BFabric%5D.jar?sig=a%2Bb+c%2F&sig=two"},
    {"mixed-percent", "objects/raw [X]%20done%.jar?part=1&signature=%2B+%25",
        "/objects/raw%20%5BX%5D%20done%25.jar?part=1&signature=%2B+%25"},
    {"path-delimiters", "/objects/a:b@c!$&'()*+,;=~_-/file [X].jar?keep=%2f%2F+%2B",
        "/objects/a:b@c!$&'()*+,;=~_-/file%20%5BX%5D.jar?keep=%2f%2F+%2B"},
    {"network-path", "/objects/raw [X].jar?keep=%2B+%2f",
        "/objects/raw%20%5BX%5D.jar?keep=%2B+%2f", Case::Shape::NetworkPath}
};

/** 监听端口分配后、发出任何请求前补齐动态 authority；期望 path/query 仍来自固定常量。 */
inline void configureLocation(Server& server, const Case& test) {
    if (test.shape == Case::Shape::Path) return;
    const std::string origin = "http://" + server.host + ":" + std::to_string(server.port);
    server.redirect_target = (test.shape == Case::Shape::Absolute ? origin : origin.substr(5)) + test.location;
}

/** 每个用例占独立回环 host，避免其他用例合法留下的熔断/地址族证据改变测试前提。 */
inline std::string nextHost() {
    static int ordinal = 200;
    assert(ordinal < 250);
    return "127.0.0." + std::to_string(ordinal++);
}

/**
 * 大小驱动真实生产分流；断流版本先写一半，再从同一逻辑源经 302 接力 206。
 * 校验准确请求数、Range 起点及最终文件，证明已写前缀未被清零、重复或混入 3xx 正文。
 */
inline void body(download::DownloadEngine& engine, const fs::path& root, const Case& test,
                 bool small, bool resumed) {
    const size_t size = small ? 4096 : 3 * 1024 * 1024;
    Server server(size, resumed ? Server::Mode::ResumedRedirect : Server::Mode::Redirect,
                  nextHost(), test.location, test.request_target, true);
    configureLocation(server, test);
    download::NetFile::Config file;
    file.local_path = (root / (std::string("redirect-") + test.name + (small ? "-multi" : "-worker") +
                        (resumed ? "-resume" : "-fresh"))).string();
    file.allowed_root = root.string(); file.urls = {server.url()}; file.max_connections = 1;
    file.check.expected_size = size;
    download::Sha1 hash; hash.update(server.payload.data(), server.payload.size());
    file.check.expected_sha1 = hash.finalizeHex();
    download::LoaderDownload::Config cfg; cfg.name = "redirect URL compatibility"; cfg.files.push_back(file);
    auto task = engine.createTask(cfg); assert(engine.startTask(task->taskId())); waitForSettled(task);
    if (task->state() != download::LoadState::Finished) {
        const auto error = task->error();
        std::cerr << "redirect case failed path=" << (small ? "multi" : "worker") << " case=" << test.name
                  << " error=" << (error ? error->message : "no error") << std::endl;
    }
    assert(task->state() == download::LoadState::Finished);
    assert(server.head_requests == 0 && server.origin_requests == (resumed ? 2 : 1) && server.target_requests == 1);
    assert(server.target_offset == static_cast<int64_t>(resumed ? size / 2 : 0));
    assert(readFixtureFile(file.local_path) == server.payload);
    purgeSettled(engine, task->taskId());
    std::cout << "PASS redirect URL path=" << (small ? "multi" : "worker") << " case=" << test.name
              << " resumed=" << resumed << " bytes=" << size << std::endl;
}

/** 两个公开 metadata API 都须拿到最终正文与最终头，query/fragment 在真实 HTTP 中核对。 */
inline void metadata(download::DownloadEngine& engine, const Case& test, bool extended) {
    Server server(127, Server::Mode::Redirect, nextHost(), test.location, test.request_target);
    configureLocation(server, test);
    download::FetchResponse response; std::string body, kind, message;
    const int result = extended ? engine.fetchToBufferEx(server.url(), {}, 5, {}, 128, response) :
        engine.fetchToBuffer(server.url(), {}, 5, body, kind, message);
    if (result != 0) std::cerr << "metadata redirect case=" << test.name << " error=" <<
        (extended ? response.err_msg : message) << std::endl;
    assert(result == 0 && (extended ? response.body : body) == server.payload);
    assert(server.head_requests == 0 && server.origin_requests == 1 && server.target_requests == 1);
    if (extended) assert(response.status_code == 200 && response.headers.count("retry-after") == 0);
    std::cout << "PASS redirect URL path=" << (extended ? "metadata-ex" : "metadata")
              << " case=" << test.name << std::endl;
}

/** 授权节点仍禁止接力：编码兼容不能让 Bearer 或一次权限跨跳转继续发请求。 */
inline void authorizedRedirectRejected(download::DownloadEngine& engine, const fs::path& root, bool small) {
    const size_t size = small ? 4096 : 3 * 1024 * 1024;
    Server server(size, Server::Mode::Redirect, nextHost(), cases[0].location, cases[0].request_target);
    download::NetFile::Config file;
    file.local_path = (root / (small ? "redirect-auth-multi" : "redirect-auth-worker")).string();
    file.allowed_root = root.string(); file.urls = {server.url()}; file.max_connections = 1;
    file.check.expected_size = size; file.bearer_token = "fixture-not-a-real-credential";
    file.authorized_policy = true; file.authorized_single_use = true;
    file.authorized_max_http_attempts = 1; file.authorized_valid_for_ms = 30000;
    file.authorized_max_bytes = size;
    download::LoaderDownload::Config cfg; cfg.name = "authorized redirect still denied"; cfg.files.push_back(file);
    auto task = engine.createTask(cfg); assert(engine.startTask(task->taskId())); waitForSettled(task);
    assert(task->state() == download::LoadState::Failed && server.origin_requests == 1 && server.target_requests == 0);
    assert(task->error() && task->error()->needs_new_lease);
    assert(!fs::exists(file.local_path)); purgeSettled(engine, task->taskId());
    std::cout << "PASS redirect URL preserves authorized node denial path=" << (small ? "multi" : "worker") << std::endl;
}

/**
 * 补充无网络边界：HTTP 本身不能可靠传递 CR/LF/NUL 作为同一 Location，故直接断言
 * 纯函数拒绝控制字节；authority/query/fragment 的完整字节和百分号大小写必须保持。
 */
inline void valueBoundaries() {
    const std::string prefix = "https://user:pass@[2001:db8::1]:443";
    const std::string suffix = "?sig=%2B+%2f&x=1&x=2#fragment%20+%2F";
    assert(download::normalizeTransportRedirectUrl(prefix + "/raw [X]%20%.jar" + suffix) ==
           prefix + "/raw%20%5BX%5D%20%25.jar" + suffix);
    assert(download::normalizeTransportRedirectUrl("https://example.invalid?sig=%2B+%2f#keep") ==
           "https://example.invalid?sig=%2B+%2f#keep");
    assert(download::normalizeTransportRedirectUrl("https://example.invalid/\xe4\xb8\xad.jar") ==
           "https://example.invalid/%E4%B8%AD.jar");
    for (char control : {'\0', '\t', '\r', '\n', '\x7f'}) {
        assert(download::normalizeTransportRedirectUrl("https://example.invalid/a" + std::string(1, control) + ".jar").empty());
        assert(download::normalizeTransportRedirectUrl("https://example.invalid/a?sig=" + std::string(1, control)).empty());
    }
    assert(!download::isTransportHttpUrl(download::normalizeTransportRedirectUrl("file:///raw [X].jar")));
    std::cout << "PASS redirect URL value boundaries preserve authority signature fragment and reject control bytes" << std::endl;
}
} // namespace redirect_url_cases

/**
 * 可按路径定向执行同一正式测试，用于将修复撤回后分别证明三条生产链会失败。
 * 环境变量只影响宿主测试选择，不进入产品；默认运行全部新用例与旧跨 origin 头隔离回归。
 */
static void runRedirectUrlCases(download::DownloadEngine& engine, const fs::path& root) {
    const char* selected = std::getenv("AMCL_DOWNLOAD_REDIRECT_PATH");
    const std::string path = selected ? selected : "";
    assert(path.empty() || path == "multi" || path == "worker" || path == "metadata");
    for (bool small : {true, false}) {
        if (!path.empty() && path != (small ? "multi" : "worker")) continue;
        for (const auto& test : redirect_url_cases::cases) redirect_url_cases::body(engine, root, test, small, false);
        redirect_url_cases::body(engine, root, redirect_url_cases::cases[0], small, true);
        redirect_url_cases::body(engine, root, redirect_url_cases::cases[2], small, true);
        redirect_url_cases::authorizedRedirectRejected(engine, root, small);
    }
    if (path.empty() || path == "metadata") {
        for (const auto& test : redirect_url_cases::cases) {
            redirect_url_cases::metadata(engine, test, false);
            redirect_url_cases::metadata(engine, test, true);
        }
        transport_policy_cases::metadataAdmission(engine);
    }
    redirect_url_cases::valueBoundaries();
}
