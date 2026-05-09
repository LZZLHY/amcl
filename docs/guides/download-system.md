# AMCL 下载系统 — 权威总览

> **本文档地位**：当前下载子系统**唯一**的 ground truth。
> **取代**：`download-system-redesign-v2/v3/v4.1/v5/v5.1.md`、`download-system-v5.2.md`、`download-audit-v5.2.md`、`download-v4.5-impl.md`、`download-system-v6-analysis.md` —— 全部移至 `docs/archive/download-history/`，仅供考古。
> **最后更新**：2026-05-06（Phase 2 元数据 TTL+304 ETag 缓存 + Phase 3 元数据 NAPI + Phase 4 增量 SHA1 + Phase 5 下载历史页 + Phase 6 PhaseRunner 抽象 + Phase 7 测试覆盖 ~37% + Phase 8 源打分加权集成完成）
> **基线 commit**：Forge 沙箱化（`DownloadTask` Phase 5/6 改造）+ JDK SHA-256 校验（`JdkManager`）+ v5.2 BUG-1~4 全修
> **代码完成度**：**85 / 100**（C++ 引擎 8.5/10；ArkTS 编排 8/10；UI 8/10；扣分项见 §4 未完成清单）

---

## 目录

- [一、状态快照](#一状态快照)
- [二、架构总览](#二架构总览)
- [三、与其他功能的集成点](#三与其他功能的集成点)
- [四、未完成功能清单（待办）](#四未完成功能清单待办)
- [五、修改下载器的注意事项](#五修改下载器的注意事项)
- [六、关键代码索引](#六关键代码索引)
- [七、历史文档索引（已归档）](#七历史文档索引已归档)

---

## 一、状态快照

| 维度 | 状态 | 说明 |
|------|------|------|
| **C++ 引擎核心** | ✅ 生产可用 | libcurl + 64 multi 并发 + 8 worker 大文件分段 |
| **断点续传** | ✅ 完成 | `.download-meta.json` 持久化分段进度，重启 App 也能续 |
| **多源 fallback** | ✅ 完成 | NetFile 持多 NetSource，首源失败切次源；坏主机黑名单全局共享 |
| **完整性校验** | ✅ 完成 | 引擎层 SHA1 + size 预检 + 实时校验；ArkTS 层 SHA-256（JDK） + ZIP EOCD（Maven） |
| **断网重试** | ✅ 完成 | MultiDownloader 30 次 + NetFile Retried 1 次（已删除 ArkTS 层叠加重试） |
| **取消语义** | ✅ 完成 | `cancelAndAwait` 等 NAPI 真正收敛 + 可选清理磁盘残留 |
| **暂停 / 恢复** | ✅ 完成 | `pause()` 标记 PAUSED + `resume()` 走断点续传 |
| **重试按钮** | ✅ 完成 | retry 复用 tempDir 的 version.json，从失败阶段继续 |
| **字节级进度** | ✅ 完成 | 按 phase 权重（assets 45% / libraries 25% / client 15% / ...） |
| **UI 浮动圆 + Sheet** | ✅ 完成 | DownloadFab 拖动吸附 + bindSheet 半屏 + 阶段卡片展开 |
| **源探测** | ✅ 完成 | `SourceProber` 启动时测 BMCLAPI / Mojang RTT，缓存 30 分钟 |
| **JDK 下载统一走引擎** | ✅ 完成 | 2026-05-04 重构，`JdkManager` 调 `DownloadManager.createAndWait` |
| **Forge 沙箱化** | ✅ 完成 | 2026-05-05 落地，installer 在 `filesDir/forge-install-sandbox/<sid>/` 跑，patches O(1) 迁入 |
| **CA bundle** | ✅ 完成 | `EntryAbility.onCreate` 抽 `rawfile/cacert.pem` 给 libcurl |
| **Forge 依赖库走 NAPI 引擎** | ✅ 完成 | ARCH-1，2026-05-05：`MavenUtils.downloadMavenLibraries` 走 `DownloadManager.createAndWait`（代码完成，真机验证待批次跑） |
| **元数据走 NAPI 引擎** | ✅ 完成 | S2-2，2026-05-06：`McDownloader.httpGet` 委托 `DownloadManager.fetchText` (-> C++ `engine.fetchToBuffer`)，与文件下载共享 CA bundle / UA / 坏主机黑名单 |
| **ETag / 条件请求缓存** | ✅ 完成 | P2-2，2026-05-06：`MetadataCacheStore` TTL + 完整 ETag/If-None-Match 304 短路（C++ `fetchToBufferEx` 加 header_callback + curl_slist，NAPI/ArkTS 一路透传） |
| **下载历史页** | ✅ 完成 | P3-1 / S2-7，2026-05-06：`DownloadHistoryStore`（LRU 20 + Preferences）+ `pages/DownloadHistoryPage.ets`，设置页"下载历史"入口 |
| **增量 SHA1** | ✅ 完成 | S2-4，2026-05-06：`NetThread::onWrite` 同步 `sha1_hasher_.update`，`NetFile::onAllThreadsDone` 单段 + SHA1 走 `checkFast` 跳过 re-read（节省 fopen+fread+fclose 数千次） |
| **下载层自动化测试** | ⚠ 部分完成 | S3-4，2026-05-06：12 个 ArkTS 套件 + 4 个 C++ 套件 (~150+/45 case)，覆盖 ~37%，NAPI/文件 IO/curl 主循环留 ohosTest 集成，详见 `download-test-coverage.md` |

---

## 二、架构总览

### 2.1 三层架构

```
┌────────────────────────────────────── UI 层 (ArkTS) ─────────────────────────────────────┐
│ DownloadFab (浮动圆)   ⇄   DownloadSheet (半屏 Sheet)   ⇄   DownloadPhaseCard (阶段卡)    │
│              └────── 由 Index.ets 持有 currentDownloadTask + dlState (DownloadStateModel) │
└──────────────────────────────────────────┬───────────────────────────────────────────────┘
                                           │ onStateChange 回调（PhaseDetailModel @Observed）
┌──────────────────────────────────────────┴───────────────────────────────────────────────┐
│                                  ArkTS 服务层                                              │
│                                                                                            │
│   DownloadTask (6 阶段编排)                                                               │
│     └─ McDownloader (元数据 HTTP + 调引擎下载 client/libraries/assets)                     │
│          └─ DownloadManager (NAPI 单例)                                                   │
│              ├─ createAndWait(spec) → Promise<DownloadTaskView>                           │
│              ├─ cancel / pause / resume / deleteTaskFiles / retryFailed / purge            │
│              └─ initializeCaBundle (抽 rawfile/cacert.pem)                                │
│                                                                                            │
│   外部消费者：                                                                              │
│     ├─ JdkManager — 调 createAndWait 下载 JDK ZIP + ArkTS 层 SHA-256                       │
│     ├─ ModLoaderManager → ForgeService / FabricService                                     │
│     │    └─ MavenUtils.downloadMavenLibraries → DownloadManager.createAndWait （ARCH-1 ✅）        │
│     │    └─ ForgeInstallerUtils.preDownloadMappings（⚠ 仍走 ArkTS HTTP，待迁移）            │
│     └─ SourceProber — 启动期测 RTT，输出 buildSortedUrls()                                 │
└──────────────────────────────────────────┬───────────────────────────────────────────────┘
                                           │ NAPI bridge (uv_async_t + threadsafe_function)
┌──────────────────────────────────────────┴───────────────────────────────────────────────┐
│                       C++ Native 引擎  (entry/src/main/cpp/download/)                      │
│                                                                                            │
│   DownloadEngine (单例)                                                                    │
│     ├─ WorkerPool × 8 ────────────► NetThread.run()  (curl_easy_perform 阻塞，大文件分段)   │
│     ├─ MultiDownloader (1 事件循环线程) ──► curl_multi 64 并发 (小文件 < 1MB, HTTP/1.1)    │
│     ├─ Ticker (200ms progress / 2s meta flush)                                            │
│     ├─ curl share handle (DNS 缓存共享，SSL 不共享 — BMCLAPI 多节点 hostname mismatch)     │
│     └─ bad host 黑名单 (全局，跨任务保留)                                                   │
│                                                                                            │
│   LoaderDownload  (任务聚合，对应一个 DownloadTaskSpec)                                    │
│     └─ NetFile[] (多个文件并行)                                                            │
│           ├─ NetSource[] (多源 fallback)                                                  │
│           ├─ NetThread[] (动态分段，piece_min_bytes=1MB)                                  │
│           ├─ FileChecker (SHA1 + size 预检 + 实时校验)                                    │
│           └─ DownloadMeta (.download-meta.json 持久化)                                    │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 文件分布全表

**C++ 引擎** — `entry/src/main/cpp/download/`（30 个文件）

| 文件 | 职责 |
|------|------|
| `engine.{h,cpp}` | DownloadEngine 单例、WorkerPool、Ticker、curl share、bad host 黑名单 |
| `multi_downloader.{h,cpp}` | curl_multi 事件循环（小文件 64 并发，HTTP/1.1 多连接） |
| `loader_download.{h,cpp}` | 任务聚合：多 NetFile、onProgress（含 active files） |
| `net_file.{h,cpp}` | 单文件编排：分段、多源、预检、meta 持久化 |
| `net_thread.{h,cpp}` | 单段下载：curl_easy_perform + Range 请求 |
| `net_source.{h,cpp}` | 源结构：URL + fail_count + is_failed flag |
| `net_state.{h,cpp}` | 7 状态机（Waiting / Connecting / Reading / Downloading / Merging / Finished / Failed） |
| `download_meta.{h,cpp}` | `.download-meta.json` 序列化 / 反序列化 |
| `sha1.{h,cpp}` | 独立 SHA1 实现（不依赖 OpenSSL 公开头） |
| `file_checker.{h,cpp}` | SHA1 + size 校验框架 |
| `download_napi.{h,cpp}` | NAPI 入口（10+ 方法） |
| `napi_bridge.{h,cpp}` | uv_async + threadsafe_function 把回调扔回 JS 主线程 |
| `exception.{h,cpp}` | DownloadException + ErrorKind 分类 |
| `probe.{h,cpp}` | 网络可达性探测 |
| `config.{h,cpp}` | 全局配置常量 |

**ArkTS 服务层** — `entry/src/main/ets/services/` + `utils/`

| 文件 | 行数 | 职责 |
|------|------|------|
| `services/DownloadManager.ets` | 676 | NAPI 单例包装 + `createAndWait` + listener 扇出 |
| `services/DownloadTask.ets` | 900 | 6 阶段编排 + retry/pause/resume/cancel + Forge 沙箱化 |
| `services/SourceProber.ets` | 152 | 源 RTT 探测 + 缓存 |
| `services/VersionJsonMerger.ets` | - | PCL2 风格合并版本 JSON |
| `services/JdkManager.ets` | 700+ | JDK 下载（走引擎）+ SHA-256 + 解压 |
| `services/modloader/MavenUtils.ets` | 492 | **Maven 库下载（ArkTS HTTP，未走引擎）** |
| `services/modloader/ForgeService.ets` | 1464 | Forge installer 编排（含 fork JVM 跑 installer） |
| `services/modloader/ForgeInstallerUtils.ets` | 473 | install_profile.json 解析 + mappings 下载 |
| `services/modloader/FabricService.ets` | - | Fabric 安装 |
| `services/modloader/ModLoaderManager.ets` | - | Forge / Fabric 路由 |
| `utils/McDownloader.ets` | 561 | 元数据 HTTP + 委托引擎下载 MC 资产 |

**UI 层** — `entry/src/main/ets/components/`

| 文件 | 职责 |
|------|------|
| `DownloadFab.ets` | 56dp 浮动圆，Ring 进度 + 拖动吸附 + 入场动画 |
| `DownloadSheet.ets` | bindSheet 半屏弹层，承载阶段列表 |
| `DownloadPhaseCard.ets` | 单阶段卡片（pending / running / done / error） |
| `CancelDownloadDialog.ets` | 取消确认 + "保留文件" / "清理文件" 选项 |
| `VersionConfigPanel.ets` | 版本 + 加载器 + 命名 配置面板 |

---

## 三、与其他功能的集成点

> **改下载器前必读**：以下是下载器对外暴露的契约，任何变动都需评估这些消费者。

### 3.1 集成关系图

```
DownloadManager (NAPI 单例)
    │
    ├─[1]─► JdkManager.installJdk()                — JDK ZIP 下载 + SHA-256
    ├─[2]─► McDownloader.downloadClientJar()       — MC client.jar
    ├─[2]─► McDownloader.downloadLibraries()       — MC libraries
    ├─[2]─► McDownloader.downloadAssets()          — MC assets
    │
    └─[3]─► MavenUtils.downloadMavenLibraries — Forge/Fabric 依赖库（ARCH-1 ✅ 2026-05-05）

ArkTS HTTP（@ohos.net.http）—— 仅保留两处非下载用途（Phase 9 / 方案 C 闭环 2026-05-06）：
    ├─ SourceProber.probeSource()                 — RTT 探测 (Range:bytes=0-0)，必须主动测每源延时
    └─ MavenUtils.httpDownloadFile()              — Legacy fallback，仅在 CA bundle 未初始化时走

DownloadTask 沙箱协议：
    └─► filesDir/forge-install-sandbox/<sid>/    — Forge installer 工作目录
        ├─ EntryAbility.onCreate 启动时清孤儿
        └─ Phase 6 用 fs.renameSync 把 patches libraries 迁入真实 mcDir/libraries
```

### 3.2 消费者契约表

| 消费者 | 入口 | 依赖的下载器 API | 改动风险 |
|--------|------|------------------|----------|
| **JDK 安装** | `JdkManager.downloadJdkArchive()` | `DownloadManager.createAndWait(spec)`、`DownloadFileSpec.urls[]`、`DownloadCheck.size` | 改 spec 协议会同时影响 |
| **MC 原版** | `DownloadTask.start()` Phase 1-4 | 同上 + `DownloadProgressEvent` 字段 | 改 phase 字符串、字段都会影响 |
| **Forge 编排** | `DownloadTask.start()` Phase 5 | `installSandboxDir` 路径约定 | 改路径会破坏 EntryAbility 清理 |
| **Forge installer** | `ForgeService.install()` | `DownloadManager.fetchText()`（元数据）+ `createAndWait`（installer.jar）+ `MavenUtils.downloadMavenLibraries()` | Phase 9 / 方案 C 后全部走 NAPI 引擎；与下载引擎共享 CA bundle / 坏主机黑名单 |
| **Fabric installer** | `FabricService.install()` | `DownloadManager.fetchText()`（meta API）+ `MavenUtils.downloadMavenLibraries()` | 同上 |
| **MC 版本列表** | `McVersionService.getVersionList()` | `DownloadManager.fetchText()` 多源 | Phase 9 / 方案 C 后清理完毕，无 ArkTS HTTP 残留 |
| **UI 状态机** | `Index.ets` `mcDownloading`+`dlState`+`currentDownloadTask` | `DownloadPhase` 枚举值（字符串） | 改枚举值需同步 `PHASE_WEIGHTS_MC` 字典 |

### 3.3 关键不变量（修改时必须保持）

1. **`DownloadPhase` 枚举字符串**：`'prepare'` / `'client'` / `'libraries'` / `'assets'` / `'modloader'` / `'merge'` / `'done'` / `'error'` / `'aborted'` / `'paused'`。被 `DownloadTask.PHASE_WEIGHTS_MC`、`McDownloader.report()` 的 stage 字符串、UI 多处硬编码。
2. **`DownloadFileSpec` 多源协议**：`urls[]` 第一个为首选源，失败按顺序 fallback。`SourceProber.buildSortedUrls()` 输出此格式，JdkManager + McDownloader 都依赖。
3. **NAPI 事件字段**：`DownloadProgressEvent` / `DownloadCompleteEvent` 的字段（含 `aborted` / `triedUrls` / `failedFiles[]` / `etaSeconds` / `currentFiles[]` / `durationMs`）—— 改一处需同步 `napi_bridge.cpp` + `DownloadManager.ets` + `DownloadTaskView` + UI。
4. **沙箱路径约定**：`filesDir/forge-install-sandbox/<sid>/` —— DownloadTask 写入、EntryAbility 清孤儿、Phase 6 迁入逻辑都依赖。
5. **CA bundle 初始化时机**：必须在 `EntryAbility.onCreate` 调用 `DownloadManager.initializeCaBundle(context)`，否则所有 HTTPS 失败。`createAndWait` 内有兜底 reject，但 UI 层不应依赖它。
6. **tempDir 复用约定**：`mcDir/download-temp/` 在 retry 路径下保留（含 version.json），cleanup 路径下删除。
7. **小文件路由阈值**：C++ 引擎 `kSmallFileThreshold = 1MB`（`engine.cpp`），改这个值会影响 multi vs worker 的分流。

---

## 四、未完成功能清单（待办）

按优先级排序。每项含：现状、影响、方案概述、工作量。

### 4.1 P1 — Forge / Fabric 依赖库走 NAPI 引擎（ARCH-1）—✅ 已完成

> **来源**：`download-audit-v5.2.md`（ARCH-1）+ `download-system-v6-analysis.md`（P1-2）
> **状态**：✅ 2026-05-05 完成。详见 `download-system-implementation-plan.md` Phase 1。
> **取代方案**：`MavenSpecBuilder.ets` 纯函数转换 + `MavenUtils.downloadMavenLibraries` 委托 `DownloadManager.createAndWait`。原生产接口 100% 向后兼容。
> **遗留待办**：真机 Forge 1.20.4 安装回归（与后续 Phase 批次跑）。

#### 现状

`MavenUtils.downloadMavenLibraries()` 仍是 ArkTS `http.createHttp()` **顺序**下载（`@/.../MavenUtils.ets:265-298`）：
- 单线程，无并发
- 多源 fallback 是手动 for 循环（无坏主机黑名单 / 自动重试 / 断点续传）
- Forge 安装的 20-40 个依赖库串行下，弱网下耗时长
- mappings 文件走 `httpGetText()`（同样问题）

#### 影响

1. Forge 依赖库下载是 v5.2 BUG-1/2/3 的根因（已通过 PK magic + SHA1 + EOCD 三层校验缓解，但本质是用 ArkTS HTTP 自研代码补丁）
2. 用户安装 Forge 时间显著长于安装 Vanilla（同等大小数据）
3. 弱网/CDN 抽风时，单源失败需要手动重试整个流程

#### 方案

把 Maven 库构造成 `DownloadFileSpec[]` 走 `DownloadManager.createAndWait()`：

```typescript
// ForgeService.install() 内
let specs: DownloadFileSpec[] = libEntries.map(lib => ({
  localPath: libDir + '/' + mavenToRelativePath(lib.name),
  urls: buildMavenUrls(lib.name, lib.url),  // BMCLAPI + 默认仓库列表
  check: { sha1: lib.sha1, size: lib.size },
}));
await DownloadManager.instance().createAndWait({
  name: `Forge libraries (${specs.length})`,
  files: specs,
});
```

**预期收益**：
- 64 并发自动复用引擎（小文件走 MultiDownloader）
- 享受坏主机黑名单 + 断点续传
- 删除 `MavenUtils` 的 ~150 行 ArkTS HTTP 代码（保留 `parseMavenName` / `mavenToRelativePath`）
- mappings 也可同步迁过去（构造单文件 spec）

#### 工作量

1.5 天

---

### 4.2 ✅ ETag / 条件请求缓存（P2-2）— 2026-05-06 完成（TTL + 完整 304）

> **来源**：`download-system-v6-analysis.md` P2-2
> **实施**：Phase 2.1-2.3（含 304 短路 2.3b），见 `download-implementation-progress.txt`

#### 落地

**ArkTS 纯函数层**（`services/MetadataCache.ets`，Phase 2.2）：
- `urlHash(url)`：FNV-1a 64-bit 同步 hash（16 hex 位，文件名稳定）
- `parseConditionalHeaders(headers)` / `buildConditionalRequest(meta)` — case-insensitive header 查找
- `isCacheValid(meta, maxAgeMs, now)` — `-1=永不过期`
- `serializeMeta` / `deserializeMeta`，`CacheMeta` interface

**ArkTS 文件 IO 单例**（`services/MetadataCacheStore.ets`，Phase 2.3a + 2.3b）：
- 存储：`<filesDir>/metadata-cache/<urlHash>.{meta,body}`
- API：`init(context)` / `isReady()` / `get(url, maxAgeMs)` / **`getMeta(url)`** / **`getBody(url)`** / **`touch(url)`** / `put(url, body, headers?)` / `clear(url?)`
- `put` 调 `parseConditionalHeaders(responseHeaders)` 提取 `etag` / `lastModified` / `contentType` 写入 `.meta`
- LayoutStore / DownloadHistoryStore 同风格单例

**C++ 引擎层**（`engine.cpp`，Phase 2.3b）：
- `struct FetchResponse { status_code, body, headers, err_kind, err_msg }` — `headers` map key 自动小写
- `fetchHeaderCallback` 解析 `Name: value` 行，redirect 链每次新 HTTP/ 行 `clear()` 让最终响应胜出
- `fetchOnceEx` — 关 `CURLOPT_FAILONERROR`（304 不算错），`curl_slist_append` 拼接 `request_headers`，`CURLOPT_HEADERFUNCTION` 捕响应头；`200-299 || 304` 都返回 0
- `fetchToBufferEx(primary, mirrors, timeout, request_headers, FetchResponse&)` — 多源 fallback 包装
- 旧 `fetchToBuffer` 保留不变（向后兼容）

**NAPI 桥**（`download_napi.cpp`，Phase 2.3b）：
- `downloadFetchText` 加可选第 4 参 `requestHeaders: Record<string, string>`
- 返回对象新增 `statusCode`（始终填）和 `headers`（成功时填，含 304）
- `FetchTextData` 内部走 `fetchToBufferEx`

**ArkTS DownloadManager**（Phase 2.3b）：
- 新 `fetchTextEx(url, mirrors?, timeout?, requestHeaders?)` 返回 `FetchTextRichResult { statusCode, body, headers }`
- 旧 `fetchText(url, mirrors?, timeout?)` 完全保留

**McDownloader.httpGet 三段式**（Phase 2.3b）：
1. **TTL 内 cache hit** → 0 网络，直接返回 body
2. **TTL 过期但有 ETag/Last-Modified** → 构 `If-None-Match` / `If-Modified-Since` 头，调 `fetchTextEx`
   - `statusCode == 304` → `store.touch(url)` + 返回 `store.getBody(url)`（仅几百字节响应头往返）
   - `statusCode == 200` → `store.put(url, body, headers)` + 返回 body
3. **完全无 cache** → 直接 GET，`store.put`

#### TTL 策略

| URL 类型 | maxAgeMs | 说明 |
|---------|----------|------|
| `version_manifest_v2.json` | 6 小时 | "latest" 列表，随 MC 发布更新；TTL 内 step 1，过期后 step 2 走 304 |
| `version.json`（`piston-meta/<sha1>/...`、bmclapi mirror） | -1 永不过期 | sha1 寻址 → 内容不可变，永远 step 1 |
| `assetIndex.json` | -1 永不过期 | 同上 |

#### 行为对比

| 场景 | 旧（直接 http.createHttp） | 新（TTL + 304） |
|------|---------------------------|----------------|
| 6 小时内启动 | 全量重下 manifest（~1MB） | 0 网络 |
| 6 小时后启动 | 全量重下 manifest | 304 仅响应头（~200B），body 来自磁盘 |
| 第二次装相同版本 | 重下 version.json + assetIndex | 0 网络（永久 cache） |
| 服务端 manifest 真的更新了 | 重下 | 200 OK，覆盖 cache |

#### 未做（deferred）

- 集成测试 / 真机回归（Phase 2.4 / 2.5）：留 ohosTest 阶段（与 LayoutStore / DownloadHistoryStore 一致）。

---

### 4.3 ✅ 元数据走 NAPI 引擎（S2-2）— 2026-05-06 完成

> **来源**：`download-system-v5.2.md` S2-2
> **实施**：Phase 3.1-3.5，见 `download-implementation-progress.txt`

#### 落地

- C++ 层（Phase 3.2）：`engine.cpp::fetchToBuffer(urls, timeoutSec)` — 内存版 curl GET，与 `downloadFile` 共享 CA bundle / UA / bad-host 黑名单 / follow redirect / gzip。错误返回 `FetchResult { ok, body, errorKind, errorMessage }`。
- NAPI 桥（Phase 3.3）：`downloadFetchText(primaryUrl, mirrors, timeoutSeconds)` — async + Promise，成功返回 body 字符串，失败 reject `[errorKind] message`。
- ArkTS 包装（Phase 3.4）：`DownloadManager.fetchText(primaryUrl, mirrors?, timeoutSeconds?)` — 检查 CA bundle 初始化，调 testNapi.downloadFetchText。
- McDownloader 接入（Phase 3.5）：`McDownloader.httpGet` 丢掉 `http.createHttp` + `withTimeout` 辅助，委托 `mgr.fetchText`。处理三个点：
  - `fetchVersionInfo` · manifest：`primaryUrl + [fallbackUrl]` 一趟调用（取代原来手写 try/catch 的 BMCLAPI ↔ Mojang fallback）
  - `fetchVersionInfo` · version.json：BMCLAPI mirror primary + Mojang 原 URL fallback
  - `downloadAssets` · assetIndex：`buildSortedUrls(...)` 首 URL 为 primary + 其余为 mirrors

#### 收益

- 与文件下载共享坏主机黑名单 (`net_thread::onWrite`)，BMCLAPI 某个节点出问题时元数据与文件同步避让
- 单次调用内外多源 fallback，手写 try/catch 的三处减为一行在调用点补充 mirrors[]
- 删 `@kit.NetworkKit http` 依赖和 `withTimeout` 辅助 → McDownloader 代码净减 ~40 行

---

### 4.4 ✅ 增量 SHA1（S2-4）— 2026-05-06 完成

> **来源**：`download-system-v5.2.md` S2-4
> **实施**：Phase 4，见 `download-implementation-progress.txt`

#### 落地

- `NetThread::onWrite`（`net_thread.cpp:158-161`）每次 `pwrite` 成功后同步 `sha1_hasher_.update(ptr, written)`
- `NetThread::resetDone()`（`net_thread.h:101-106`）重试时同步重置 `sha1_hasher_ = Sha1()`
- `NetThread::finalSha1()` / `isSingleSegment()`：暴露下载结束时的预算 hash + 段数判定
- `NetFile::onAllThreadsDone()`（`net_file.cpp:594-612`）：仅单段 + 配置了 expected_sha1 时调 `FileChecker::checkFast`，跳过 fopen+fread+sha1+fclose
- `FileChecker::checkFast`（`file_checker.cpp:103-133`）：stat（1 syscall）+ strcmp，零文件 re-read

#### 收益

3805 个 asset 文件之前每个都要 fopen+fread_all+sha1+fclose，现在单段命中快路径，只剩 stat + strcmp（数千次阻塞 syscall → 零阻塞 syscall）。多段大文件（libraries / client.jar）保留传统 re-read 校验。

#### 测试

`download/tests/sha1_incremental_test.cpp`（CMakeLists.txt:237 已注册）覆盖 RFC 3174 标准向量、增量一致性、64 字节边界、随机 chunk size、零长度、单字节边界。NAPI 入口 `runDownloadSha1IncrementalTests` 挂在 DevToolsPage。

---

### 4.5 ✅ 下载历史页（P3-1 / S2-7）— 2026-05-06 完成

> **来源**：`download-system-v5.2.md` S2-7、`download-system-v6-analysis.md` P3-1
> **实施**：Phase 5.1-5.4，见 `download-implementation-progress.txt`

#### 落地

- `services/DownloadHistory.ets`：
  - 纯函数层：`DownloadHistoryRecord` interface + `DownloadHistoryLru` 类 + 序列化/反序列化辅助 + `formatRecordSummary`（Phase 5.2）
  - 持久化层（Phase 5.3）：`DownloadHistoryStore` 类 + `getDownloadHistoryStore()` 单例工厂；`@kit.ArkData` preferences 读写；`init(context)` / `waitReady()` / `add(record)` / `clear()` / `list()`，与 `LayoutStore` 风格一致
  - 容量常量 `HISTORY_CAPACITY = 20`
- `pages/Index.ets`：`aboutToAppear` 早期 `init`（fire-and-forget）；`beginDownload` 在 DONE/ERROR/ABORTED 任一终态调 `recordHistory(...)` 写一条；`historyRecorded` 闭包标志防重入；`maxBytesTotal` 跨 phase 跟踪用作 `totalBytes` 估算
- `pages/DownloadHistoryPage.ets`（Phase 5.4）：`@Entry` 页面，卡片式列表（状态徽章/版本名/加载器/时间/字节/文件/耗时/失败原因），顶栏"清空"按钮，空态文案，主题跟随 `PreferenceManager.themeMode`
- `pages/tabs/SettingsTab.ets`：在"自定义按键布局"与"开发者工具"之间插入"下载历史"入口 → `router.pushUrl('pages/DownloadHistoryPage')`
- `resources/base/profile/main_pages.json`：注册新页面

#### 数据契约

每条记录字段：`versionName / gameVersion / loaderType / loaderVersion?` / `startedAt(ms) / durationMs / totalBytes / fileCount` / `status('success'|'failed'|'aborted') / errorMessage?`。

#### 测试

`entry/src/test/DownloadHistory.test.ets`：在原 LRU + 序列化 + format 26 个 case 基础上新增 4 个 `DownloadHistoryStore` 契约 case（容量、单例、空 list、isReady 类型）。Preferences IO 路径 ohosTest 阶段验证（与 LayoutStore 处理方式一致）。

---

### 4.6 ✅ PhaseRunner 抽象（S3-2）— 2026-05-06 完成

> **来源**：`download-system-v5.2.md` S3-2
> **实施**：Phase 6.1-6.5，见 `download-implementation-progress.txt`

#### 落地

- `services/PhaseRunner.ets`：`IDownloadPhase` 接口、`PhaseProgress`/`PhaseContext`/`RunnerState`、顺序调度器（支持 cancel/pause/resume + 权重归一化）
- `services/phases/DownloadFlowState.ets`：跨 phase 共享可变状态容器
- `services/phases/{Prepare,Client,Libraries,Assets,Modloader,Merge}Phase.ets`：6 个 phase 类，每个实现 `IDownloadPhase`
- `services/DownloadTask.ets`：`doStart` 内层 try/catch 从 ~180 行硬编码 6 阶段重构为 PhaseRunner 调度循环（-194 行）
- `handlePhaseProgress` 把 `PhaseProgress` 翻译成现有 `phaseDetails` UI 模型 + 任务级 `bytesDone`/`bytesTotal`/`speed`/`etaSeconds`/`progress`
- 公开 API 零改动：`start`、`cancel`、`cancelAndAwait`、`retry`、`pause`、`resume`、`onStateChange`、`phaseDetails`、`progress`、`phase`、`errorMessage`、`failedFilePaths`、`failedFileDetails` —— Index.ets / 其他调用方完全无感

#### 收益

- 未来扩展整合包 / 资源包 / mod 安装流程时只需新写 `IDownloadPhase` 类，不改 DownloadTask
- Forge 沙箱设置 + libraries 迁移本地化到 `ModloaderPhase` / `MergePhase`，DownloadTask 只剩调度 + 错误聚合
- `PhaseRunner.test.ets`（11 个 case）+ `Phases.test.ets`（13 个 case）锁定行为契约

#### 测试

`entry/src/test/PhaseRunner.test.ets`（顺序/权重/cancel/pause/resume/状态机）+ `entry/src/test/Phases.test.ets`（6 个 phase 类的 name/weight/cancel sanity + DownloadFlowState 派生路径）。两套都注册在 `List.test.ets`。

---

### 4.7 ⚠ 测试覆盖（S3-4）— 2026-05-06 基础测试落地，覆盖率 ~37%

> **来源**：`download-system-v5.2.md` S3-4
> **详细报告**：`download-test-coverage.md`
> **实施**：Phase 7.1-7.7，见 `download-implementation-progress.txt`

#### 已落地

- **ArkTS 层**（12 个 `.test.ets`，~150+ case）：`MavenSpecBuilder` / `MetadataCache` / `DownloadHistory` / `PhaseRunner` / `Phases` / `VersionJsonMerger` / `DownloadManager`（纯函数）/ `McDownloader.filterLibraries` / `MavenUtils` / `PathUtils` / `VersionParser` / `FabricService`
- **C++ 层**（4 个 `.cpp`，~45 case）：
  - `sha1_incremental_test` — RFC 3174 标准向量 + 增量一致性
  - `source_scoring_test` — Phase 8 滑动窗口 + `pickBestSourceWeighted`
  - `error_and_source_lifecycle_test` — `errorKindToString` / `DownloadException::toString` / `NetSource::recordFailure` 阈值翻转 / `recordSuccess` 清零
  - `text_fetch_test` — `engine.fetchToBuffer`（**需网络**）
- NAPI 触发入口挂在 DevToolsPage，ArkTS 套件通过 `hvigorw test`（ohosTest HAP）跑

#### 未覆盖（deferred）

- **DownloadTask / JdkManager / LaunchProfileBuilder**：跨 NAPI 调用太多，纯单测成本 > 收益，留 ohosTest 集成跑
- **LayoutStore / PreferenceManager / RuntimeDeployer**：Preferences / 文件 IO 依赖 OHOS Context，需设备
- **C++ `net_thread::run` / `multi_downloader` / `net_file`（除 scoring 外）**：curl_multi 主循环，需 libcurl mock 子项目（`download-engine-gtest`）
- **`engine::downloadFile` 完整路径**：涉及真实文件 + curl + 线程，属 E2E 级别

#### 覆盖自评

- 按文件数算 ~45%（12/22 ArkTS + 4/14 C++）
- 按代码行算 ~37%（约 2300/6200 行）
- 未达 60% 目标 = 策略选择：把 NAPI 边界 / curl 引擎留给 ohosTest 集成 + 未来 libcurl mock

#### 运行方式

```bash
# ArkTS 单测（编译验证）
hvigorw test --mode module -p product=default --no-daemon

# C++ 单测（DevToolsPage → 按钮触发）
# - runDownloadSha1IncrementalTests
# - runDownloadSourceScoringTests
# - runDownloadErrorAndSourceLifecycleTests
# - runDownloadTextFetchTests (needs caBundlePath)
```

---

### 4.8 ✅ 源打分加权（S3-1）— 2026-05-06 完成

> **来源**：`download-system-v5.2.md` S3-1
> **实施**：Phase 8.1-8.3，见 `download-implementation-progress.txt`

#### 落地

**NetSource 层（`net_source.h/cpp`）**：
- 滑动窗口（容量 `kSampleWindowSize = 8`）：`recordSample(rtt_ms, throughput_bps)`（线程安全，`std::mutex sample_mu_`）
- `avgRttMs()` / `avgThroughputBps()` — 空窗口返回 -1 / 0.0
- `computeScore()` 公式：`avgRtt/100 + 1MB/avgThroughputBps + fail_count`（越低越优）
- 无数据回退："中性" RTT=200ms / throughput=512KB/s（让首次选源与旧版"按声明顺序"兼容）
- `pickBestSourceWeighted(sources)` 自由函数：跳过 `is_failed=true`，同分按 `id` 稳定

**NetThread 层（`net_thread.cpp:580-599`）**：
- 成功路径（`performOnce` 返回 `nullptr`）取 `CURLINFO_CONNECT_TIME_T` + `CURLINFO_SPEED_DOWNLOAD_T`，喂给 `src->recordSample(rtt_ms, throughput_bps)`

**NetFile 层（`net_file.cpp:177-209`）**：
- `pickBestSource` 改为 `computeScore()` 升序排序（替换旧 fail_count/success_count 双字段），保留 `needs_range` / `no_range_support` / `id` tie-break 语义

**测试（`download/tests/source_scoring_test.cpp`，13 case）**：
- 滑动窗口（空 / 单点 / 平均 / 容量溢出）
- score 单调性（低 RTT 胜、高 throughput 胜、fail 惩罚、无数据中性）
- `pickBestSourceWeighted` 多源排序 / 跳过 failed / 全 failed null / 空数组 / 饥饿保护
- NAPI 入口 `runDownloadSourceScoringTests` 挂 DevToolsPage

#### 行为变化

| 场景 | 旧 (fail/succ 排序) | 新 (computeScore) |
|------|---------------------|-------------------|
| 首次下载（无样本、无失败） | 按 fail 升序 → 平手按 succ 降序 → 平手按 id | 所有源同分 → **按 id** → 与旧版一致 |
| 某源 2 次 timeout | fail=2 → 跳到下个 | score += 2 → 下个源 score 低 → 切换（fail_count 仍生效） |
| 快镜像（50ms/10MB）vs 慢镜像（500ms/1MB） | 按 fail 相同 → succ 可能乱序 | score 1.1 vs 6.0 → **快镜像胜** |
| 某源 is_failed=true | 跳过 | 跳过（完全一致） |

#### 未做（deferred）

- Phase 8.4 真机 BMCLAPI vs Mojang 胜率对比（用户决定先上线再测）
- 跨任务持久化评分（IPReliability / Stage 1c，留给未来）

---

### 4.9 故意不做的事

> 这些项曾被讨论但最终决定**不实施**，避免反复重提。

| 项 | 决定不做的原因 | 历史出处 |
|----|----------------|----------|
| HTTP/2 Multiplexing | v4.5b 已显式回退到 HTTP/1.1。HTTP/2 多路复用把 N 流压在 4 条 TCP 上，flow control 限制每流带宽，**对 BMCLAPI 多镜像 302 场景反而更慢**。见 `multi_downloader.cpp:97-106` 注释 | `download-v4.5-impl.md` v4.5b 回退 |
| Forge 阶段取消（S1-8） | jvmCallMain 阻塞调用，DestroyJavaVM 不能跨线程，Thread.interrupt 对 installer I/O 不一定有效。技术成本高 + 用户场景少 | `download-system-v5.1.md` §1.2 |
| McDownloader 3 轮重试 | 引擎内已有 30 + 1 = 31 次重试足够。已在 v5.1 删除叠加层 | `download-system-v5.1.md` §1.3 |

---

## 五、修改下载器的注意事项

### 5.1 修改前的 checklist

- [ ] 我要改的是引擎、编排、UI，还是消费者侧？
- [ ] 改动是否影响 `DownloadFileSpec` / `DownloadProgressEvent` / `DownloadCompleteEvent` 的字段？如是，需同步 NAPI bridge + DownloadManager + UI
- [ ] 改动是否涉及 `DownloadPhase` 枚举？如是，需同步 `PHASE_WEIGHTS_MC` 字典 + UI 多处硬编码
- [ ] 改动是否涉及 Forge 沙箱路径？如是，需同步 EntryAbility 孤儿清理 + Phase 6 迁入
- [ ] 改动是否引入新的 JVM 参数？如是，**必读 `docs/ROADMAP.md` 的"踩坑记录"**

### 5.2 验证清单

每次改下载器，至少跑：

1. **真机 Vanilla 1.20.4 完整下载**（client + libraries + assets，~230MB）
2. **真机 Forge 1.20.4 完整安装**（含 installer fork JVM）
3. **断网恢复**：下载到 50% kill App，重启验证从断点继续
4. **取消保留 vs 取消清理**：两条路径都跑一遍
5. **重试**：让某个文件 fail（如断网），点重试，验证只重下失败文件
6. **JDK 下载**：清掉 `filesDir/jdk/17/` 重下，验证 SHA-256 校验通过

### 5.3 调试工具

- C++ 日志：`hilog` tag=`AMCL` / `Engine` / `NetFile` / `NetThread` / `MultiDownloader`
- ArkTS 日志：`hilog` tag=`DownloadManager` / `DownloadTask` / `McDownloader` / `MavenUtils`
- 持久化：`filesDir/.minecraft/<...>.download-meta.json` 查看分段进度
- AppLogger：`AppLogger.flush()` 把缓冲日志写入磁盘（在 onComplete 失败路径自动调）

---

## 六、关键代码索引

> 修下载器从这里入手。所有路径用绝对路径，可点击跳转。

### 6.1 入口与配置

- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\entryability\EntryAbility.ets` — 调 `initializeCaBundle()` + Forge 沙箱孤儿清理
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\common\Constants.ets` — `BMCLAPI_BASE` / `MOJANG_*` 常量
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\cpp\download\config.cpp` — C++ 引擎全局常量

### 6.2 ArkTS 服务层

- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\DownloadManager.ets:378-513` — `createAndWait()` 核心 API
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\DownloadTask.ets:430-706` — `start()` / `doStart()` 6 阶段编排（含 Forge 沙箱化）
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\DownloadTask.ets:259-321` — `retry / pause / resume / cancelAndAwait`
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\DownloadTask.ets:798-832` — Forge 沙箱 libraries 迁入（`fs.renameSync` O(1)）
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\SourceProber.ets:70-106` — `probeAllSources()` 源探测
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\utils\McDownloader.ets:244-294` — `downloadClientJar`
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\utils\McDownloader.ets:307-370` — `downloadLibraries`
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\utils\McDownloader.ets:382-481` — `downloadAssets`（含 P0-2 多源 fallback）
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\JdkManager.ets:358-414` — `downloadJdkArchive` 调引擎
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\JdkManager.ets:514-551` — `verifyArchiveIntegrity` SHA-256 校验

### 6.3 ArkTS 消费者侧（Forge / Fabric）

- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\modloader\MavenSpecBuilder.ets` — 纯函数转换（ARCH-1 Phase 1.2/1.4）
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\modloader\MavenUtils.ets:280-353` — `downloadMavenLibraries` 走 NAPI 引擎（ARCH-1 Phase 1.5）
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\modloader\MavenUtils.ets:154-260` — `downloadMavenLibrary`（单库 ArkTS HTTP，fallback 使用）
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\modloader\MavenUtils.ets:309-359` — `isValidJarFile` + `hasValidZipEocd`（PK + EOCD 三层校验）
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\modloader\ForgeInstallerUtils.ets:100-180` — `extractLibrariesFromInstallerJson`
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\modloader\ForgeInstallerUtils.ets:186-298` — `preDownloadMappings`（含 BUG-3 修复）

### 6.4 UI 层

- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\pages\Index.ets:422-486` — `beginDownload` 入口 + onStateChange 回调
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\pages\Index.ets:491-545` — 取消 / 重试 / 暂停 / 继续 4 个按钮逻辑
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\components\DownloadFab.ets` — 浮动圆
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\components\DownloadSheet.ets` — 半屏 Sheet
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\components\DownloadPhaseCard.ets` — 阶段卡片

### 6.5 C++ 引擎

- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\cpp\download\engine.cpp` — DownloadEngine 单例
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\cpp\download\engine.cpp:200-220` — startTask 路由（小文件→multi，大文件→worker）
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\cpp\download\multi_downloader.cpp:94-110` — HTTP/1.1 选择决策（v4.5b 回退）
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\cpp\download\net_file.cpp:231-254` — `determineFileSize`（含 P1-1 跳过 HEAD 优化）
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\cpp\download\loader_download.cpp:150-200` — `tickProgress` 收集 active files
- `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\cpp\download\napi_bridge.cpp` — uv_async_t / threadsafe_function 桥接

---

## 七、历史文档索引（已归档）

按时间倒序，所有文档已移至 `docs/archive/download-history/`，仅供考古：

| 文件 | 日期 | 价值 |
|------|------|------|
| `download-system-v6-analysis.md` | 2026-04-26 | 当前未完成项的优化方案设计稿（ARCH-1 / ETag / 增量 SHA1）原始方案 |
| `download-audit-v5.2.md` | 2026-04-23 | v5.2 自检报告，列出 4 个 P0 BUG（已全修）+ ARCH-1 |
| `download-system-v5.2.md` | 2026-04-23 | v5.2 backlog 全面评估（L1/L2/L3/S2-2/S2-4 等） |
| `download-system-v5.1.md` | 2026-04-22 | UI 重构（DownloadFab + DownloadSheet）设计稿 |
| `download-system-redesign-v5.md` | 2026-04-22 | S0/S1 修复（aborted 字段、deleteTaskFiles、字节级进度）设计稿 |
| `download-v4.5-impl.md` | 2026-04-21 | v4.5 / v4.5b 实施记录（HTTP/2 引入和回退） |
| `download-system-redesign-v4.1.md` | 2026-04-20 | PCL2 行为对齐（删 cascading abort、bad host 黑名单、Range 检测） |
| `download-system-redesign-v3.md` | 2026-04-19 | 第一版 C++ + libcurl 引擎设计稿（Stage 0-5） |
| `download-system-redesign-v2.md` | 2026-04 早期 | 编排层 + UI 骨架设计稿（VersionConfigPanel + DownloadTask + VersionJsonMerger） |

**何时回去翻历史文档**：
- 想了解某个设计决策为什么这样做（如"为什么 SSL session 不共享"→ v4.1）
- 复盘某次性能问题（如 HTTP/2 为什么不行 → v4.5-impl）
- 需要 PCL2 / HMCL / XMCL 竞品调研数据（→ v6-analysis）

**不要做的事**：
- ❌ 在历史文档中加新内容（应该改本文档）
- ❌ 把本文档拆回多份"v7 / v8 / v9"系列（这正是上次 7 份重叠文档的恶性循环）

---

## 文档维护约定

1. **本文档是唯一权威**。下载系统的方案 / 评估 / 路线图都写到这里（或在 `archive/` 写历史复盘）。
2. **完成一项就更新本文档**：把它从"未完成"挪到"状态快照"，并在 git commit message 提一笔。
3. **新设计提案直接改本文档的 §4 待办**，不要再开新 `.md` 文件。
4. **真机验证矩阵**（§5.2）必须在每次改动后跑一遍，结果记到 commit message。

> 文档版本：v1（2026-05-05）| 取代 9 份历史设计稿
