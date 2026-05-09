# 下载子系统测试覆盖报告

> **对应 Phase 7（S3-4），2026-05-06 完成**
> **权威进度**：`docs/guides/download-implementation-progress.txt`
> **设计总览**：`docs/guides/download-system.md`

## 一、总览

| 层 | 测试类型 | 文件数 | 测试 case 数 | 执行方式 |
|----|---------|--------|-------------|---------|
| ArkTS 纯函数 | Hypium 单测 | 12 | 约 150+ | `hvigorw test`（ohosTest HAP，需设备跑） |
| C++ 纯内存 | 手写断言 + `OH_LOG_INFO` | 4 | 约 45 | DevToolsPage NAPI 按钮触发 |
| C++ 依赖真机/网络 | 手写断言 | 1 | 5 | DevToolsPage + 真实网络 |

**零真机依赖的测试**：ArkTS 全部 + C++ 3 个（`sha1_incremental_test` / `source_scoring_test` / `error_and_source_lifecycle_test`）。

**需要真机/网络的**：C++ 的 `text_fetch_test`（拉 httpbin.org / postman-echo）。

---

## 二、ArkTS 测试清单（`entry/src/test/`）

| 文件 | 被测模块 | 覆盖要点 | 新增阶段 |
|------|----------|----------|---------|
| `MavenUtils.test.ets` | `services/modloader/MavenUtils.ets` | Maven 坐标解析 / URL 构造 | 基线 |
| `MavenSpecBuilder.test.ets` | `services/modloader/MavenSpecBuilder.ets` | BMCLAPI 优先、多源 fallback、`DownloadFileSpec` 构造、`parseDoneEventToBatchResult` | Phase 1 |
| `MetadataCache.test.ets` | `services/MetadataCache.ets` | ETag 条件请求判定、缓存读写、过期逻辑 | Phase 2 |
| `PathUtils.test.ets` | `utils/PathUtils.ets` | 路径规范化、安全拼接 | 基线 |
| `VersionParser.test.ets` | `services/VersionParser.ets` | 版本号解析、inheritsFrom 链 | 基线 |
| `FabricService.test.ets` | `services/modloader/FabricService.ets` | Fabric meta 解析、profile JSON 构造 | 基线 |
| `DownloadHistory.test.ets` | `services/DownloadHistory.ets` | LRU（capacity 20）、序列化、`formatRecordSummary`、`DownloadHistoryStore` 契约 | Phase 5 |
| `PhaseRunner.test.ets` | `services/PhaseRunner.ets` | 顺序调度、权重归一化、暂停/恢复/取消信号、终态语义 | Phase 6 |
| `Phases.test.ets` | `services/phases/*.ets`（6 个 phase 类） | `DownloadFlowState` 派生、`name` / `weight` / `cancel` 契约 sanity | Phase 6.3 |
| **`VersionJsonMerger.test.ets`** | `services/VersionJsonMerger.ets` | **PCL2 merge 规则（mainClass 覆盖、libraries 前置、args 追加、字段清理）+ dedupeStringArray** | **Phase 7（新）** |
| **`DownloadManager.test.ets`** | `services/DownloadManager.ets` | **`formatBytes` / `formatSpeed` 边界、`DownloadTaskView` 默认字段** | **Phase 7（新）** |
| **`McDownloader.test.ets`** | `utils/McDownloader.ets` | **`filterLibraries` 规则筛选（AMCL 伪装 Linux）、java-objc-bridge 硬保留** | **Phase 7（新）** |

**测试的模块**（12 / 共 22 个 services + utils 文件）：
- ✅ MavenUtils / MavenSpecBuilder / MetadataCache / PathUtils / VersionParser / FabricService / DownloadHistory / PhaseRunner / Phases / VersionJsonMerger / DownloadManager (部分) / McDownloader (部分)

**未测试或部分覆盖**：
- ❌ `DownloadTask.ets` — 生命周期跨 NAPI 调用，集成测试留 ohosTest
- ❌ `JdkManager.ets` — 依赖 `jvmCheckJitAvailable` NAPI + 文件 IO
- ❌ `LaunchProfileBuilder.ets` — 大量 JSON 模板变量替换，留后续
- ❌ `LayoutStore.ets` / `PreferenceManager.ets` — Preferences IO，留 ohosTest
- ❌ `SourceProber.ets` — 真实 HTTP 探测
- ❌ `RuntimeDeployer.ets` — 文件 IO + 解压

---

## 三、C++ 测试清单（`entry/src/main/cpp/download/tests/`）

| 文件 | 被测模块 | 覆盖要点 | 触发入口（DevToolsPage） |
|------|----------|----------|--------------------------|
| `sha1_incremental_test.cpp` | `download/sha1.{h,cpp}` | RFC 3174 标准向量、增量一致性、64 字节边界、随机 chunk size、零长度 | `runDownloadSha1IncrementalTests()` |
| `text_fetch_test.cpp` | `download/engine.cpp::fetchToBuffer` | 单 URL 成功、多镜像回退、失败、超时、空响应 | `runDownloadTextFetchTests(caPath)` — **需真实网络** |
| `source_scoring_test.cpp` | `download/net_source.{h,cpp}` | 滑动窗口（空/单/平均/溢出）、score 单调性（RTT/throughput/fail）、多源排序、饥饿保护 | `runDownloadSourceScoringTests()` |
| **`error_and_source_lifecycle_test.cpp`** | `download/exception.{h,cpp}` + `download/net_source.{h,cpp}` | **`errorKindToString` 全值、`DownloadException::toString`、`recordFailure` 阈值翻转 + 去重、`recordSuccess` 重置 fail_count 但保留 `is_failed`** | **`runDownloadErrorAndSourceLifecycleTests()`（新）** |

**C++ 引擎模块覆盖情况**：

| 模块 | 覆盖状态 | 备注 |
|------|---------|------|
| `sha1.cpp` | ✅ 完整 | 增量 + 一次性结果一致性已验证 |
| `exception.cpp` | ✅ 完整 | Phase 7 新增 `errorKindToString` + `toString` 全覆盖 |
| `net_source.cpp` | ✅ 完整 | Phase 7（lifecycle）+ Phase 8（scoring） |
| `engine.cpp::fetchToBuffer` | ⚠ 部分 | 依赖网络，CI 跑不了 |
| `engine.cpp::downloadFile` | ❌ 未覆盖 | 需真机 + curl mock |
| `net_file.cpp` | ❌ 未覆盖 | `pickBestSource` 的 Range 过滤逻辑只在 `source_scoring_test` 间接验证 |
| `net_thread.cpp` | ❌ 未覆盖 | 主循环 + pwrite + sha1 写回调依赖文件系统和 curl |
| `file_checker.cpp` | ❌ 未覆盖 | 依赖文件 IO，留 ohosTest |
| `multi_downloader.cpp` | ❌ 未覆盖 | curl_multi 编排，单测成本高 |

---

## 四、覆盖率自评

### 4.1 按文件数算

- **ArkTS services + utils 模块**：12 / 约 22 个 ≈ **54%**
- **C++ download 目录**：4 / 约 14 个 .cpp 文件 ≈ **28%**（但覆盖的都是核心类型安全 + 算法）
- **总计**：约 **45%** 的关键文件有测试

### 4.2 按代码行算（粗估）

| 层 | 被测试代码行 / 总行数 |
|----|----------------------|
| ArkTS download 相关 | 约 **1500 / 3400** ≈ 44% |
| C++ download 相关 | 约 **800 / 2800** ≈ 29% |
| **综合** | 约 **2300 / 6200** ≈ **37%** |

### 4.3 未达 60% 的原因（不是代码问题，是策略选择）

1. **NAPI 边界**：`DownloadTask` / `JdkManager` / `LaunchProfileBuilder` 大量依赖 NAPI 调用，纯单测需 mock 整个 libentry.so，成本高于收益。这类放 ohosTest 集成阶段跑。
2. **文件 IO + Preferences**：`LayoutStore` / `PreferenceManager` / `RuntimeDeployer` / C++ `file_checker` 依赖 OHOS Context，离开设备跑不了。
3. **curl 引擎主循环**：`net_thread::run` / `multi_downloader` 的单元测试需要 curl_multi mock，非 GTest/Catch2 级别能轻松 cover，留给 Stage 2c 的 `download-engine-gtest` 子项目。

### 4.4 下一步建议（不列入 Phase 7 DoD）

- **集成层**：在 ohosTest 里写"跑一个真实 `createAndWait` → complete 事件 → 判断 success/failed" 的 E2E case
- **C++ mock**：引入 libcurl mocking（`curl_multi_perform` 注入 stub response）做 `net_file`/`net_thread` 测试
- **LaunchProfileBuilder**：把 JSON 模板替换的纯函数部分拆出来（类似 `VersionJsonMerger.mergeJsonObjects`），单测

---

## 五、如何跑测试

### 5.1 ArkTS 单测（需真机 / 模拟器）

```
hvigorw test --mode module -p product=default --no-daemon
```

`BUILD SUCCESSFUL` 只是编译通过。真正执行要把 `entry-ohosTest-signed.hap` 装到设备，在 DevEco 里 "Run → Test" 触发。

### 5.2 C++ 纯内存测试（不需网络）

打开 **设置 → 开发者工具（DevToolsPage）**，点按钮：
- **"运行 SHA1 增量测试"** → `runDownloadSha1IncrementalTests()`
- **"运行源打分测试"** → `runDownloadSourceScoringTests()`
- **"运行异常 + 源生命周期测试"** → `runDownloadErrorAndSourceLifecycleTests()` ← Phase 7 新加

结果会打印到 hilog 和 UI TextArea，格式：`test_name: PASS/FAIL (detail)`。

### 5.3 C++ 带网络的测试

DevToolsPage → **"运行文本抓取测试"**，需要设备已联网。

---

## 六、新增 Phase 7 测试的完整列表

### 6.1 ArkTS（3 个文件，32 个 case）

**`VersionJsonMerger.test.ets`（11 case）**：
1. `null loader → 透传原版 + 清理 inheritsFrom 等 + 设置 id`
2. `Forge loader → mainClass 被覆盖、libraries 前置、arguments 追加`
3. `minecraftArguments 旧格式 → 合并去重`
4. `loader 无 libraries → 保留原版 libraries`
5. `loader 无 mainClass → 保留原版 mainClass`
6. `type 字段：加载器优先`
7. `id 始终被覆盖为 outputName`
8. `dedupeStringArray 空数组 → 空`
9. `dedupeStringArray 无重复 → 原数组`
10. `dedupeStringArray 有重复 → 保留首次出现顺序`
11. `dedupeStringArray 全相同 → 单元素`

**`DownloadManager.test.ets`（13 case）**：
- `formatBytes`：负数 / 0 / < 1KB / 1 KB-1 MB / 1 MB-1 GB / ≥ 1 GB（6 case）
- `formatSpeed`：0 / 基于 formatBytes + /s / 负数（3 case）
- `DownloadTaskView` 默认字段 / `createdAt` 时间戳 / `finishedAt` 初值（3 case）
- `NewlyCreatedTaskView` 字段正确（1 case）

**`McDownloader.test.ets`（8 case）**：
1. 无 rules → 全部保留
2. `java-objc-bridge` 硬保留
3. allow 无 OS → 保留
4. allow linux → 保留
5. allow windows → 排除
6. disallow linux → 排除
7. allow osx + disallow linux → 排除（disallow 胜）
8. 混合数组 → 正确分类
9. 空数组 → 空

### 6.2 C++（1 个文件，11 case）

**`error_and_source_lifecycle_test.cpp`**：
1. `errorKindToString` 全部 12 个 ErrorKind
2. `DownloadException::toString` 最小格式
3. `DownloadException::toString` 完整（含 native_code / http_status / url / message）
4. `DownloadException::toString` 含 native_code 的 SSL 错误
5. `makeException` 工厂
6. `recordFailure` 低于阈值 → fail_count +1, is_failed=false
7. `recordFailure` 达到阈值 → 首次翻转返回 true
8. `recordFailure` 已翻转后再次调用 → 返回 false（日志去重）
9. `recordFailure` 自定义阈值 max_failures=1 → 一次就翻转
10. `recordSuccess` 清零 fail_count，递增 success_count
11. `recordSuccess` 已 is_failed=true 时不自动恢复（避免抖动）

---

## 七、维护规则

新增 download 相关代码时：
1. **纯函数 / 纯 ArkTS**：在 `entry/src/test/` 加 `.test.ets`，注册到 `List.test.ets`
2. **C++ 纯内存算法**：在 `download/tests/` 加 `.cpp`，注册到 CMake + `download_tests.h` + `napi_entry.cpp` + TS 类型声明
3. **需 NAPI / 真机**：留给 ohosTest 集成
4. **需网络**：学 `text_fetch_test.cpp` 的 pattern（签名含 caBundlePath）
