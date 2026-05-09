# 下载系统实施计划（TDD 驱动）

> **本文档地位**：`download-system.md` §4 中所有未完成项的**唯一**执行计划。
> **方法论**：严格 TDD（**红 → 绿 → 重构**）：每个步骤先写测试 → 跑测试看失败 → 实现 → 跑测试看通过 → 编译 → 真机回归。
> **禁止**：跳步、并行多 phase、为了赶工删测试。
> **进度跟踪**：`docs/guides/download-implementation-progress.txt`（每完成一步打钩 + 提交 git commit hash）。
> **创建日期**：2026-05-05
> **预计总工期**：12 工作日

---

## 目录

- [零、总则与约定](#零总则与约定)
- [一、环境准备（0.5 天）](#一环境准备05-天)
- [Phase 1 — ARCH-1：Maven 库走 NAPI 引擎（P1，1.5 天）](#phase-1--arch-1maven-库走-napi-引擎p115-天)
- [Phase 2 — ETag 条件请求缓存（P2，1 天）](#phase-2--etag-条件请求缓存p21-天)
- [Phase 3 — 元数据走 NAPI 引擎（S2-2，1 天）](#phase-3--元数据走-napi-引擎s2-21-天)
- [Phase 4 — 增量 SHA1（S2-4，0.5 天）](#phase-4--增量-sha1s2-405-天)
- [Phase 5 — 下载历史页（P3-1 / S2-7，0.5 天）](#phase-5--下载历史页p3-1--s2-705-天)
- [Phase 6 — PhaseRunner 抽象（S3-2，2 天）](#phase-6--phaserunner-抽象s3-22-天)
- [Phase 7 — 测试覆盖完善（S3-4，3 天）](#phase-7--测试覆盖完善s3-43-天)
- [Phase 8 — 源打分加权（S3-1，2 天）](#phase-8--源打分加权s3-12-天)
- [附录 A — 验证命令速查](#附录-a--验证命令速查)
- [附录 B — 风险与回滚](#附录-b--风险与回滚)

---

## 零、总则与约定

### 0.1 TDD 强制流程（每步必须）

每个**步骤**必须按这个顺序执行，**禁止跳步**：

```
┌─────────────────────────────────────────────────────────────────┐
│ Step Workflow (per step):                                       │
│                                                                 │
│  1. WRITE_TEST       — 先写测试文件（覆盖待实现的接口）           │
│  2. WRITE_STUB       — 写最小类型 stub（导出所有签名，返回假数据） │
│  3. COMPILE_TEST     — hvigorw 编译，确认测试编译通过             │
│  4. RUN_TEST_RED     — 跑测试，确认所有断言失败（运行时红灯）     │
│  5. IMPLEMENT        — 写真实逻辑，让测试变绿                    │
│  6. RUN_TEST_GREEN   — 跑测试，确认全部通过（绿灯）              │
│  7. COMPILE_HAP      — build-hap.ps1 完整编译 HAP                │
│  8. INTEGRATION_TEST — 真机或集成场景验证                        │
│  9. UPDATE_PROGRESS  — 在 progress.txt 打钩 + git commit         │
└─────────────────────────────────────────────────────────────────┘
```

**为什么需要类型 stub（区别于普通 TypeScript TDD）**：

ArkTS 严格模式（`arkts-no-any-unknown` 规则）不允许"模块缺失 → implicit any"
传播到测试代码。所以纯 TS 那种"测试 import 不存在的模块 → 编译失败 = 红灯"
的方式不可行。

**正确做法**：先写最小 stub（所有函数返回 `null` / 空数组 / dummy 值），
让 ArkTS 类型系统满意；测试运行时 hypium 的 `expect(...).assertXxx()` 全部
失败（assertion 红灯）。然后真正实现 → 全部转绿。

最小 stub 的特征：
- 导出所有 interface 和函数签名
- 函数体一行：`return null;` / `return [];` / `throw new Error('NOT_IMPLEMENTED')`
- **不构成"具体业务代码"**，仍符合"测试先于实现"的 TDD 原则

### 0.2 测试框架约定

| 层级 | 框架 | 路径 | 运行方式 |
|------|------|------|----------|
| ArkTS 纯函数 | `@ohos/hypium` | `entry/src/test/*.test.ets` | DevEco Run > Test 或 `hvigorw test` |
| ArkTS NAPI / 集成 | `@ohos/hypium` | `entry/src/ohosTest/ets/test/*.test.ets` | 需真机/模拟器 |
| C++ 引擎 | 自定义 `runXxxTests()` | `entry/src/main/cpp/download/tests/*.cpp` | 通过 `DevToolsPage` NAPI 触发 |
| 端到端真机 | 手动 + AppLogger | 真机 | `hdc install` + 抓 hilog |

### 0.3 文件命名约定

- ArkTS 测试：`<ModuleName>.test.ets`（与被测模块同名 + `.test`）
- C++ 测试：`<module>_test.cpp`（snake_case）
- 实现文件：紧贴 `services/` / `utils/` / `cpp/download/` 现有目录结构
- **不创建新顶层目录**

### 0.4 编码规范

- ArkTS 严格模式（不允许 `any`、内嵌 `object literal` 类型）
- 所有 `interface` 在文件顶部 `export`
- 日志统一走 `hilog` + `AppLogger`（生产代码）/ `console.info`（仅测试）
- 注释中文 OK，但**字符串字面量、symbol、文件名一律英文**（见现有 `MavenUtils.ets` 风格）
- 错误处理：所有 NAPI 调用 try/catch + AppLogger.error

### 0.5 Git 约定

- 每个 **步骤** 一个 commit（不要把多个 step 攒一起）
- commit message 格式：`[Phase N.M] <短描述>`（例：`[Phase 1.3] add MavenSpecBuilder pure tests`）
- 每个 **Phase** 完成后打 tag：`download-phase-N-done`
- 失败/回滚：`git revert` 而非 `git reset --hard`，保留历史

### 0.6 进度跟踪

实时更新 `docs/guides/download-implementation-progress.txt`，格式：

```
[2026-05-05 15:30] Phase 1.1 - test stub written         ✓ commit=abc1234
[2026-05-05 16:00] Phase 1.2 - red stage verified        ✓ commit=def5678
[2026-05-05 17:00] Phase 1.3 - implementation green      ✓ commit=ghi9012
...
```

---

## 一、环境准备（0.5 天）

### Step 0.1 — 创建测试目录骨架

**目标**：建立所有 Phase 的目录结构与 stub 文件。

**新建文件**（仅占位，内容稍后填）：
- `entry/src/test/MavenSpecBuilder.test.ets`
- `entry/src/test/MetadataCache.test.ets`
- `entry/src/test/DownloadHistory.test.ets`
- `entry/src/test/PhaseRunner.test.ets`
- `entry/src/main/cpp/download/tests/sha1_incremental_test.cpp`
- `entry/src/main/cpp/download/tests/text_fetch_test.cpp`
- `entry/src/main/cpp/download/tests/source_scoring_test.cpp`
- `entry/src/main/cpp/download/tests/download_tests.h`（共享头）

**验证**：`git status` 应显示 8 个新文件 untracked。

**Commit**：`[Phase 0.1] add test file stubs for download system implementation plan`

### Step 0.2 — 验证现有测试基线

**目标**：确认 `MavenUtils.test.ets` / `PathUtils.test.ets` / `VersionParser.test.ets` / `FabricService.test.ets` 当前全绿。

**操作**：
1. DevEco Studio → 右键 `entry/src/test/List.test.ets` → Run 'List Tests'
2. 或命令行：
   ```powershell
   cd d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication
   D:\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat test --mode module -p product=default
   ```

**预期**：5 个测试套件全绿（`localUnitTest` / `mavenUtilsTest` / `pathUtilsTest` / `versionParserTest` / `fabricServiceTest`）。

**红灯处理**：当前基线就绿，如果有红灯**先修复**再开始 Phase 1。

**Commit**：无（只是验证）

### Step 0.3 — 验证现有 HAP 编译

**目标**：确认基线代码能干净编译。

**操作**：
```powershell
cd d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication
.\build-hap.ps1
```

**预期**：`BUILD SUCCESS`，HAP 产出于 `entry\build\default\outputs\default\entry-default-signed.hap`。

**Commit**：无

---

## Phase 1 — ARCH-1：Maven 库走 NAPI 引擎（P1，1.5 天）

### 1.0 背景与目标

**当前问题**：`MavenUtils.downloadMavenLibraries()` 用 ArkTS `http.createHttp()` **顺序**下载 20-40 个 Forge 依赖库，无并发、无引擎级断点续传、无坏主机黑名单。这是 v5.2 BUG-1/2/3 的根因，且 Forge 安装时间显著长于 Vanilla。

**目标**：把 Maven 库下载从 ArkTS HTTP 迁移到 `DownloadManager.createAndWait()`，享受 64 并发 + 多源 fallback + 断点续传。

**接口契约不变**：`downloadMavenLibraries(libs, libDir, onProgress)` 返回 `LibBatchDownloadResult` 的签名保持不变，调用方（`ForgeService` / `FabricService`）零改动。

**架构**：
```
旧：MavenUtils.downloadMavenLibraries
       ↓
    for each lib:
       downloadMavenLibrary
          ↓
       httpDownloadFile (ArkTS HTTP, 顺序)

新：MavenUtils.downloadMavenLibraries
       ↓
    MavenSpecBuilder.buildSpecsForLibs(libs, libDir)  ← 纯函数（可测试）
       ↓
    DownloadManager.createAndWait(spec)
       ↓
    [C++ 引擎自动 64 并发 + 多源 + 断点续传]
       ↓
    parseDoneEventToBatchResult(view, libs)  ← 纯函数（可测试）
```

### 1.1 Step — 写 `MavenSpecBuilder` 纯函数测试（红）

**新建测试文件**：`entry/src/test/MavenSpecBuilder.test.ets`

**测试覆盖**（核心：把 Maven 库列表 + libDir 转换为 DownloadFileSpec[]）：
- `buildMavenUrls(coordinate, repoHint?)` — 构造多源 URL 列表
  - BMCLAPI 优先
  - repoHint 紧跟其后
  - 默认仓库列表追加
  - 去重
- `buildSpecForLib(lib, libDir)` — 单个 lib → DownloadFileSpec
  - localPath 正确
  - urls[0] 是 BMCLAPI
  - check.sha1 / check.size 透传
  - 非法 Maven 坐标返回 null
- `buildSpecsForLibs(libs, libDir)` — 批量
  - 跳过非法坐标，记录到 invalidNames
  - 返回 `{ specs: DownloadFileSpec[], invalidNames: string[] }`

**TDD 红阶段验证**：
```powershell
# 此时 MavenSpecBuilder.ets 还不存在，测试编译应失败
hvigorw test --mode module -p product=default
```
**预期**：编译错误 `Cannot find module '../main/ets/services/modloader/MavenSpecBuilder'`

**Commit**：`[Phase 1.1] write MavenSpecBuilder pure tests (TDD red)`

### 1.2 Step — 实现 `MavenSpecBuilder.ets`（绿）

**新建文件**：`entry/src/main/ets/services/modloader/MavenSpecBuilder.ets`

**设计要点**：
- 纯函数，零 I/O
- 复用 `MavenUtils.parseMavenName` / `mavenToRelativePath` / `mavenToUrl`
- 复用 `Constants.BMCLAPI_BASE` 构造 BMCLAPI Maven URL
- 默认仓库列表硬编码（与现有 `DEFAULT_MAVEN_REPOS` 一致；从 MavenUtils export 出来共享）

**接口**：
```typescript
export interface MavenSpecResult {
  specs: DownloadFileSpec[];
  invalidNames: string[];  // 非法坐标
  pathToName: Map<string, string>;  // localPath → 原 Maven 坐标，用于失败回查
}

export function buildMavenUrls(coordinate: string, repoHint: string | undefined): string[];
export function buildSpecForLib(lib: MavenLibEntry, libDir: string): DownloadFileSpec | null;
export function buildSpecsForLibs(libs: MavenLibEntry[], libDir: string): MavenSpecResult;
```

**先 export 必要的常量**：在 `MavenUtils.ets` 添加 `export { DEFAULT_MAVEN_REPOS, BMCLAPI_MAVEN }`。

**绿阶段验证**：
```powershell
hvigorw test --mode module -p product=default
```
**预期**：所有 `MavenSpecBuilder` 测试通过；其他 4 套不受影响。

**Commit**：`[Phase 1.2] implement MavenSpecBuilder pure module (TDD green)`

### 1.3 Step — 写 `parseDoneEventToBatchResult` 测试（红）

**修改测试文件**：`MavenSpecBuilder.test.ets`（追加 describe 块）

**测试覆盖**：
- 全部成功 → `{ ok: N, failed: 0, errors: [], failedNames: [] }`
- 有 failedFiles → 解析失败 path → 反查原 lib name
- localPath 不在 pathToName 中（不可能但要 defensive）→ skip 记录
- name 字段填充正确

**红阶段验证**：编译失败（函数还不存在）

**Commit**：`[Phase 1.3] write parseDoneEventToBatchResult tests (TDD red)`

### 1.4 Step — 实现 `parseDoneEventToBatchResult`（绿）

**修改文件**：`MavenSpecBuilder.ets`（同文件追加纯函数）

**接口**：
```typescript
export function parseDoneEventToBatchResult(
  view: DownloadTaskView,
  libs: MavenLibEntry[],
  pathToName: Map<string, string>
): LibBatchDownloadResult;
```

**绿阶段验证**：所有测试通过。

**Commit**：`[Phase 1.4] implement parseDoneEventToBatchResult (TDD green)`

### 1.5 Step — 改造 `MavenUtils.downloadMavenLibraries` 走引擎

**修改文件**：`entry/src/main/ets/services/modloader/MavenUtils.ets`

**实现策略**：
- 保留旧 `downloadMavenLibrary`（单库，ArkTS HTTP）作为 fallback（可选）
- 新增内部函数 `downloadMavenLibrariesViaEngine(libs, libDir, onProgress)`
- `downloadMavenLibraries` 主入口委托到引擎实现
- 进度回调适配：把引擎的 `view.filesDone / filesTotal` 映射到旧 `(done, total, name)` 签名
- name 字段：从 `view.currentFiles[]`（v5.2 L1 已落地）取首个

**关键代码骨架**：
```typescript
export async function downloadMavenLibraries(
  libs, libDir, onProgress
): Promise<LibBatchDownloadResult> {
  let { specs, invalidNames, pathToName } = buildSpecsForLibs(libs, libDir);
  
  if (specs.length === 0) {
    return { ok: 0, failed: invalidNames.length, errors: ..., failedNames: invalidNames };
  }
  
  let mgr = DownloadManager.instance();
  let view = await mgr.createAndWait({
    name: `Maven libraries (${specs.length})`,
    files: specs,
  }, (v) => {
    if (onProgress) {
      let name = v.currentFiles.length > 0 ? v.currentFiles[0] : '';
      onProgress(v.filesDone, v.filesTotal, name);
    }
  });
  
  let result = parseDoneEventToBatchResult(view, libs, pathToName);
  // 合并非法坐标的失败到 result
  for (let n of invalidNames) {
    result.failed++;
    result.failedNames.push(n);
    result.errors.push(`${n}: invalid maven coordinate`);
  }
  return result;
}
```

**关键约束**：
- ❌ 不要删除旧 `downloadMavenLibrary` —— 保留作为单库下载场景（如 mappings 文件）
- ✅ 保持 `LibBatchDownloadResult` 字段 100% 向后兼容
- ✅ `onProgress` 回调频率与旧实现匹配（每个文件完成时触发一次）

### 1.6 Step — 写集成测试（ohosTest，需真机）

**新建文件**：`entry/src/ohosTest/ets/test/MavenUtilsIntegration.test.ets`

**测试场景**：
1. **小批量真实下载**：3 个真实 Forge 依赖坐标 → 验证全部成功 + 文件存在 + size 合理
2. **混合非法坐标**：含 1 个非法坐标 → 验证 `failed === 1` + `failedNames` 正确
3. **空数组输入**：`libs = []` → 验证 `ok === 0, failed === 0`

**红阶段**：暂不跑（需要真机），但要编译通过。

**Commit**：`[Phase 1.6] add MavenUtils integration test (ohosTest)`

### 1.7 Step — 编译 + 单元测试 + 真机回归

**操作**：
```powershell
# 1. 单元测试
hvigorw test --mode module -p product=default

# 2. 完整 HAP 编译
.\build-hap.ps1

# 3. 装机 + 跑 ohosTest（DevEco Run > Test ohosTest）

# 4. 真机端到端：装新 HAP → 安装 Forge 1.20.4 → 看 hilog
hdc install entry\build\default\outputs\default\entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.example.myapplication
hdc hilog | Select-String "MavenUtils|DownloadManager"
```

**真机验证矩阵**：
| 场景 | 预期行为 |
|------|----------|
| Forge 1.20.4 全新安装 | libraries 阶段并发 64 下载，速度显著提升 |
| 中途断网 5 秒 | 引擎自动重试，不报错 |
| 已安装版本重装（meta 残留） | 引擎跳过已完成文件，秒过 libraries 阶段 |
| BMCLAPI 偶发 403 | 自动 fallback 到默认仓库 |

**Commit**：`[Phase 1.7] verify ARCH-1 on real device (Forge 1.20.4 install)`

### 1.8 Step — 文档更新

**修改**：
- `docs/guides/download-system.md` §1 状态快照：把 ARCH-1 从 ❌ 改为 ✅
- `docs/guides/download-system.md` §4.1 移到"已完成"区
- `progress.txt` 打钩 Phase 1

**Commit**：`[Phase 1 done] ARCH-1: Maven libraries via NAPI engine`

**Tag**：`git tag download-phase-1-done`

---

## Phase 2 — ETag 条件请求缓存（P2，1 天）

### 2.0 背景与目标

**当前问题**：每次 prepare 阶段都重下载 `version_manifest_v2.json`、`<version>.json`、`<asset_index>.json` —— 同版本反复装时浪费带宽。

**目标**：实现 HMCL 风格的 `MetadataCache`，用 ETag / If-Modified-Since 条件请求，命中缓存返回 304 时直接读本地。

**架构**：
```
filesDir/metadata-cache/
├── <url_hash>.body      实际响应体
└── <url_hash>.meta      JSON: { etag, lastModified, fetchedAt, contentType }
```

### 2.1 Step — 写 `MetadataCache` 纯函数测试（红）

**新建测试文件**：`entry/src/test/MetadataCache.test.ets`

**测试覆盖**（仅纯函数部分）：
- `urlHash(url)` — URL → 文件名 hash（SHA-256 hex 前 16 位）
- `parseConditionalHeaders(httpResponse)` — 解析 ETag / Last-Modified
- `buildConditionalRequest(meta)` — 已有缓存时构造 If-None-Match / If-Modified-Since headers
- `isCacheValid(meta, maxAgeMs)` — 缓存是否在有效期内（防止极老缓存）
- `serializeMeta(meta) / deserializeMeta(json)` — 元数据持久化

**注意**：I/O 操作（读写缓存文件）放到集成测试，纯函数测试不依赖文件系统。

**红阶段验证**：编译失败。

**Commit**：`[Phase 2.1] write MetadataCache pure tests (TDD red)`

### 2.2 Step — 实现 `MetadataCache.ets`

**新建文件**：`entry/src/main/ets/services/MetadataCache.ets`

**接口**：
```typescript
export interface CacheMeta {
  url: string;
  etag?: string;
  lastModified?: string;
  fetchedAt: number;       // ms
  contentType?: string;
}

export class MetadataCache {
  static instance(context: Context): MetadataCache;
  
  // 同步读取缓存（用于 prepare 前的可选预热）
  hasCached(url: string): boolean;
  
  // 主入口：带缓存的 fetch（返回 string body）
  async fetchTextWithCache(url: string, mirrors: string[], maxAgeMs: number): Promise<string>;
  
  // 主动失效
  invalidate(url: string): void;
  
  // 清空（用于"清缓存"按钮）
  clearAll(): void;
}
```

**实现要点**：
- 缓存目录：`context.filesDir + '/metadata-cache'`，aboutToAppear 自动创建
- 命中条件：本地有 .body + .meta，且 `Date.now() - meta.fetchedAt < maxAgeMs`
- 命中时仍发请求带 `If-None-Match` —— 304 响应直接 return 本地 body；非 304 重新写
- 网络失败 + 有本地缓存 → fallback 用本地（即使过期）
- 完全无缓存 + 网络失败 → throw

**绿阶段验证**：测试通过。

**Commit**：`[Phase 2.2] implement MetadataCache (TDD green)`

### 2.3 Step — 接入 `McDownloader` + `MavenUtils`

**修改**：
- `McDownloader.fetchVersionManifest` → 走 `MetadataCache.fetchTextWithCache(maxAgeMs=10min)`
- `McDownloader.fetchVersionJson` → 走缓存（maxAgeMs=24h）
- `McDownloader.fetchAssetIndex` → 走缓存（maxAgeMs=24h）
- `MavenUtils.fetchMavenMetadata` → 走缓存（maxAgeMs=10min）

**风险**：`asset_index` 和 `version.json` 的内容是稳定的（按 sha1 命名），缓存时间可以拉长到天级；`version_manifest_v2.json` 是滚动更新的，10 分钟合理。

### 2.4 Step — 集成测试（ohosTest）

**新建文件**：`entry/src/ohosTest/ets/test/MetadataCacheIntegration.test.ets`

**测试场景**：
1. 首次 fetch → 缓存被写入
2. 立即第二次 fetch → 304 → 用缓存（验证耗时 < 1s）
3. 关掉网络 → 仍能拿到缓存内容
4. 清缓存 → 强制重 fetch

### 2.5 Step — 真机回归 + 文档更新

**真机验证**：连续装 1.20.4 两次，第二次 prepare 阶段应在 5s 内完成（首次 ~30s）。

**Commit**：`[Phase 2 done] ETag conditional request cache for metadata`
**Tag**：`download-phase-2-done`

---

## Phase 3 — 元数据走 NAPI 引擎（S2-2，1 天）

### 3.0 背景与目标

**当前**：`McDownloader.httpGet()` 用 ArkTS `@ohos.net.http`，不享受坏主机黑名单 + 多源 fallback。当 `version_manifest_v2.json` 的 BMCLAPI 返回 503 时，必须手动重试或切换 URL。

**目标**：在 C++ 引擎新增"内存下载"模式（不写文件，只返回 buffer），ArkTS 通过 NAPI 拿到 string。所有元数据走这条路，复用引擎的稳定性。

**先决依赖**：Phase 2 的 MetadataCache 已落地（ETag 缓存层在 fetchTextWithCache 内部，引擎层只负责"网到 buffer"）。

### 3.1 Step — 写 C++ `text_fetch` 测试（红）

**新建文件**：`entry/src/main/cpp/download/tests/text_fetch_test.cpp`

**测试函数签名**（沿用现有 `runXxxTests` 模式）：
```cpp
extern "C" const char* runDownloadTextFetchTests(const char* caBundlePath);
```

**测试场景**（无需真网络，用 httpbin / postman-echo 等公开服务）：
1. `https://httpbin.org/get` 返回 200 + JSON
2. 多镜像首个失败 → fallback 第二个
3. 全部失败 → 错误码非 0
4. 大 buffer（> 1 MB）正确拼接（用 `https://httpbin.org/bytes/1048576`）
5. 超时（> 5s）正常 abort

**红阶段**：函数 `EngineFetchToBuffer` 还不存在，链接失败。

**Commit**：`[Phase 3.1] write C++ text fetch tests (TDD red)`

### 3.2 Step — 实现 C++ `EngineFetchToBuffer`

**修改**：
- `engine.h` — 添加 `int fetchToBuffer(const string& url, const vector<string>& mirrors, int timeout_s, std::string& out_body, std::string& out_error)` 方法
- `engine.cpp` — 实现：复用 `bad host 黑名单` + `curl share`，但用临时 `curl_easy` + `WRITEFUNCTION` 写 string 而非文件
- 不走 multi/worker pool（单次性请求，开销不值）

**接口设计**：
```cpp
// engine.h
namespace amcl::download {
  // 返回 0 成功，非 0 失败；body 在成功时填充
  int fetchToBuffer(
    const std::string& url,
    const std::vector<std::string>& mirrors,
    int timeout_s,
    std::string& out_body,
    std::string& out_error_kind,
    std::string& out_error_message
  );
}
```

**风险**：
- 不要在 `LoaderDownload` 里跑（那是文件级编排）；做成 engine 全局方法，独立资源
- CA bundle 用 `g_caBundlePath`（已有的全局）
- 写一份 `tryOneUrl` 静态函数复用代码

**绿阶段**：测试通过。

**Commit**：`[Phase 3.2] implement engine.fetchToBuffer in C++`

### 3.3 Step — NAPI 桥接

**修改**：
- `download_napi.cpp` — 添加 `napi_value DownloadFetchText(napi_env env, napi_callback_info info)`
- `download_napi.h` — export
- `napi_init.cpp`（或 entry 注册点）— 注册 `downloadFetchText` 方法
- `cpp/types/libentry/index.d.ts` — 添加 TypeScript 声明

**接口**：
```typescript
// index.d.ts
export const downloadFetchText: (
  url: string,
  mirrors: string[],
  timeoutSec: number
) => Promise<string>;
```

**Commit**：`[Phase 3.3] add downloadFetchText NAPI bridge`

### 3.4 Step — 写 ArkTS 测试（red）+ 实现 wrapper

**测试**：`entry/src/ohosTest/ets/test/DownloadFetchText.test.ets`

**修改 `DownloadManager.ets`**：
```typescript
async fetchText(url: string, mirrors: string[], timeoutSec: number): Promise<string> {
  return await testNapi.downloadFetchText(url, mirrors, timeoutSec);
}
```

### 3.5 Step — 替换 `McDownloader.httpGet` + `MavenUtils.httpGetText`

**修改**：所有 ArkTS 元数据 HTTP 调用替换为 `DownloadManager.fetchText`（Phase 2 的 `MetadataCache` 内部调它）。

**注意**：保留 `httpGetText` 的旧实现作为最后 fallback（如果 NAPI 抛异常）。

### 3.6 Step — 编译 + 真机回归 + 文档

**真机验证**：BMCLAPI 偶发 503 时，`fetchText` 应自动 fallback 到 Mojang。

**Commit**：`[Phase 3 done] metadata fetch via NAPI engine`
**Tag**：`download-phase-3-done`

---

## Phase 4 — 增量 SHA1（S2-4，0.5 天）

### 4.0 背景与目标

**当前**：`NetFile::finalize()` 全文件读取 + 计算 SHA1；assets 阶段 3805 文件累计 3-5 秒。

**目标**：在 `NetThread::onWrite` 增量更新 SHA1 上下文（仅单段下载即 piece_count == 1 的情况），完成时秒结。

**约束**：多段下载（大文件分片）保留全量逻辑（因为 pwrite 顺序不一定连续）。

### 4.1 Step — 写 C++ 测试（红）

**新建文件**：`entry/src/main/cpp/download/tests/sha1_incremental_test.cpp`

**测试函数**：`extern "C" const char* runSha1IncrementalTests();`

**测试场景**：
1. **基础正确性**：随机 1MB 数据 → 增量计算 SHA1 与一次性计算结果一致
2. **空数据**：0 字节 → SHA1 = `da39a3ee5e6b4b0d3255bfef95601890afd80709`
3. **分块大小**：用不同 chunk size（1 字节、64KB、1MB）调 update，结果一致
4. **重置**：computed 完后再调用 reset+update 应返回新值

**红阶段**：`Sha1IncrementalContext` 类不存在，编译失败。

**Commit**：`[Phase 4.1] write incremental SHA1 tests (TDD red)`

### 4.2 Step — 实现增量 SHA1

**修改 `sha1.h` / `sha1.cpp`**：
```cpp
class Sha1IncrementalContext {
public:
    Sha1IncrementalContext();
    void update(const uint8_t* data, size_t len);
    std::string finalize();  // 返回 hex lowercase 40 字符
    void reset();
};
```

**绿阶段**：测试通过。

### 4.3 Step — 接入 `NetThread`

**修改 `net_thread.h`**：
- 添加 `Sha1IncrementalContext sha1_ctx_`
- 添加 `bool sha1_active_`（仅 piece_count == 1 + cfg.check.sha1 非空时启用）

**修改 `net_thread.cpp`**：
- `onWrite()` 中如果 sha1_active_ → 调用 `sha1_ctx_.update(buf, len)`
- run 结束前如果 sha1_active_ → `auto computed = sha1_ctx_.finalize();` 存到 NetFile

**修改 `net_file.cpp`**：
- `finalize()` 时优先用线程的增量结果，回退全量计算（多段时）

### 4.4 Step — 编译 + 真机时序对比

**真机验证**：1.20.4 assets 阶段计时（before vs after），目标减少 2-4 秒。

**Commit**：`[Phase 4 done] incremental SHA1 in NetThread`
**Tag**：`download-phase-4-done`

---

## Phase 5 — 下载历史页（P3-1 / S2-7，0.5 天）

### 5.0 背景与目标

**当前**：`DownloadManager.purgeFinished()` 立即删完成任务，无任何记录。

**目标**：LRU 20 条历史记录，存 `@ohos.data.preferences`。设置页加"下载历史"入口。

### 5.1 Step — 写 `DownloadHistory` 纯测试（红）

**新建测试文件**：`entry/src/test/DownloadHistory.test.ets`

**测试覆盖**（纯逻辑，不写 Preferences）：
- `LRU.add(record)` — 添加新记录
- LRU 满 → 最老记录被驱逐
- `LRU.serialize() / deserialize()` — JSON 往返
- `formatRecordSummary(record)` — 格式化展示文本

**Commit**：`[Phase 5.1] write DownloadHistory pure tests (TDD red)`

### 5.2 Step — 实现 `DownloadHistory.ets`

**新建文件**：`entry/src/main/ets/services/DownloadHistory.ets`

**接口**：
```typescript
export interface DownloadHistoryRecord {
  versionName: string;
  gameVersion: string;
  loaderType: string;       // 'vanilla' | 'fabric' | 'forge'
  loaderVersion?: string;
  startedAt: number;
  durationMs: number;
  totalBytes: number;
  fileCount: number;
  status: 'success' | 'failed' | 'aborted';
  errorMessage?: string;
}

export class DownloadHistory {
  static instance(context: Context): Promise<DownloadHistory>;
  
  async add(record: DownloadHistoryRecord): Promise<void>;
  async list(): Promise<DownloadHistoryRecord[]>;
  async clear(): Promise<void>;
}
```

**约束**：
- LRU 最多 20 条
- 用 `@ohos.data.preferences` 存 JSON 数组（key="download_history"）

### 5.3 Step — 接入 `DownloadTask.onComplete`

**修改 `DownloadTask.ets`**：在 `notifyDone()` / `notifyError()` / `notifyAborted()` 各分支记录历史。

### 5.4 Step — UI（设置页加入口）

**修改 `Index.ets`** 或新建 `pages/DownloadHistoryPage.ets`：列表展示 + 删除按钮。

### 5.5 Step — 真机验证 + 文档

**Commit**：`[Phase 5 done] download history page (LRU 20)`
**Tag**：`download-phase-5-done`

---

## Phase 6 — PhaseRunner 抽象（S3-2，2 天）

### 6.0 背景与目标

**当前**：`DownloadTask.start()` 硬编码 6 阶段（prepare / client / libraries / assets / modloader / merge），不支持整合包 / 资源包扩展。

**目标**：抽 `IDownloadPhase` 接口 + `PhaseRunner` 调度器，6 个现有阶段拆成独立类。

### 6.1 Step — 写 `PhaseRunner` 测试（红）

**新建测试文件**：`entry/src/test/PhaseRunner.test.ets`

**测试覆盖**：
- 顺序执行 N 个 mock phase
- 任一 phase reject → runner reject 且后续 phase 不执行
- pause / resume / cancel 信号传递
- 字节级权重正确（PhaseConfig.weight）

**Commit**：`[Phase 6.1] write PhaseRunner tests (TDD red)`

### 6.2 Step — 定义接口

**新建文件**：`entry/src/main/ets/services/phases/IDownloadPhase.ets`

```typescript
export interface PhaseContext {
  taskId: string;
  versionName: string;
  gameVersion: string;
  loaderType: string;
  mcDir: string;
  filesDir: string;
  // ...
}

export interface PhaseProgress {
  phase: string;
  progress: number;     // 0-1
  speedBps: number;
  message: string;
}

export interface IDownloadPhase {
  readonly name: string;       // 'prepare' / 'client' / ...
  readonly weight: number;     // 字节级权重
  
  run(ctx: PhaseContext, onProgress: (p: PhaseProgress) => void): Promise<void>;
  pause?(): Promise<void>;
  resume?(): Promise<void>;
  cancel?(cleanup: boolean): Promise<void>;
}
```

### 6.3 Step — 拆出 6 个现有 phase

**新建文件**：
- `phases/PreparePhase.ets`
- `phases/ClientPhase.ets`
- `phases/LibrariesPhase.ets`
- `phases/AssetsPhase.ets`
- `phases/ModLoaderPhase.ets`
- `phases/MergePhase.ets`

**约束**：
- 接口签名 100% 兼容现有 `DownloadTask.doStart` 各分支
- 不改业务逻辑，只搬运
- `DownloadTask` 改为持有 `phases: IDownloadPhase[]` 数组

### 6.4 Step — 实现 `PhaseRunner`

**新建文件**：`entry/src/main/ets/services/PhaseRunner.ets`

**职责**：按数组顺序跑、累计加权进度、信号传递、错误处理。

### 6.5 Step — `DownloadTask` 重构

**关键约束**：
- 公开接口（`start / retry / pause / resume / cancelAndAwait`）签名零改动
- `onStateChange` 回调签名零改动
- `DownloadPhase` 枚举值不变（避免破坏 UI）

### 6.6 Step — 完整真机回归

**测试矩阵**：Vanilla 1.20.4 + Forge 1.20.4 + Fabric 1.21 全跑一遍，对比 Phase 0 之前的速度 / UI 行为应一致。

**Commit**：`[Phase 6 done] PhaseRunner abstraction`
**Tag**：`download-phase-6-done`

---

## Phase 7 — 测试覆盖完善（S3-4，3 天）

### 7.0 目标

把 ArkTS + C++ 下载相关代码覆盖率推到 60%+。当前几乎为零。

### 7.1 Step — DownloadManager 测试

**新建**：`entry/src/test/DownloadManager.test.ets`（pure logic 部分）

**覆盖**：
- `formatBytes / formatSpeed`（已部分有）
- `DownloadTaskView` 状态机
- `DownloadListener` add / remove / notify
- `isTaskActiveByName` 各种边界

### 7.2 Step — DownloadTask 测试（mock NAPI）

**新建**：`entry/src/test/DownloadTask.test.ets`

**覆盖**：
- 6 阶段编排顺序
- PHASE_WEIGHTS_MC 加权正确性
- retry / pause / resume 状态转换
- onStateChange 回调触发时机

**Mock 策略**：用依赖注入或函数替换 `DownloadManager.instance()`。

### 7.3 Step — McDownloader 测试

**覆盖**：URL 构造、buildSortedUrls 集成 SourceProber、asset_index 解析。

### 7.4 Step — C++ 引擎单元测试

**新建**：
- `download/tests/net_source_test.cpp` — fail_count / is_failed 状态
- `download/tests/net_file_test.cpp` — 段切分、restoreFromMeta
- `download/tests/download_meta_test.cpp` — 序列化往返

### 7.5 Step — Coverage 报告（可选）

**工具**：DevEco Studio 内置 coverage（菜单 Run > Run with Coverage）。
**目标**：下载相关核心模块 ≥ 60%。

### 7.6 Step — 文档化测试覆盖

**新建**：`docs/testing/download-test-coverage.md`，列出每个模块的覆盖路径与缺口。

**Commit**：`[Phase 7 done] download test coverage to 60%+`
**Tag**：`download-phase-7-done`

---

## Phase 8 — 源打分加权（S3-1，2 天）

### 8.0 背景

当前 `pickBestSource()` 只按 fail_count 升序；SourceProber 探了 RTT 但未入引擎评分。

### 8.1 Step — 写 C++ 测试（红）

**新建**：`download/tests/source_scoring_test.cpp`

**覆盖**：滑动窗口 RTT 平均、score 计算、tie-breaker。

### 8.2 Step — `NetSource` 加滑动窗口

**修改**：
- `net_source.h` — 添加 `RingBuffer<int> rtt_window_` + `RingBuffer<double> throughput_window_`
- `net_source.cpp` — `recordSuccess(rtt_ms, bytes_per_sec) / recordFailure()`

### 8.3 Step — 改 `pickBestSource`

**算法**：`score = (avg_rtt_ms / 1000) + (fail_count * 5) - (avg_throughput_mbps * 2)`，最低分胜出。

### 8.4 Step — 真机性能对比

**测试**：BMCLAPI vs Mojang 在不同网络下的胜率（采样 100 次下载，统计源分布）。

**Commit**：`[Phase 8 done] weighted source scoring`
**Tag**：`download-phase-8-done`

---

## 附录 A — 验证命令速查

### 跑所有 ArkTS 单元测试

```powershell
cd d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication
& "D:\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" test --mode module -p product=default
```

### 完整编译 HAP

```powershell
.\build-hap.ps1
```

### 装机 + 启动

```powershell
hdc install entry\build\default\outputs\default\entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.example.myapplication
```

### 抓 hilog（下载相关）

```powershell
hdc hilog | Select-String "DownloadManager|DownloadTask|MavenUtils|McDownloader|MetadataCache"
```

### 跑 C++ 引擎测试（通过 DevToolsPage NAPI）

DevEco Studio Run 后在 App 内进入 DevToolsPage → 点对应测试按钮。

---

## 附录 B — 风险与回滚

### B.1 通用回滚策略

每个 Phase 一个 git tag，回滚时：

```bash
git checkout download-phase-<N-1>-done
# 或
git revert <commit-hash>
```

### B.2 高风险变更点

| Phase | 风险点 | 缓解 |
|-------|--------|------|
| 1 | MavenUtils 改造可能改变错误回报格式 | LibBatchDownloadResult 字段不动 + 新增集成测试 |
| 3 | C++ 新增 NAPI 方法可能影响 libentry.so 体积 | 编译后 `Get-Item libentry.so` 监控大小变化 |
| 4 | 增量 SHA1 在多段下载下计算错误 | 仅 piece_count == 1 启用，多段保留全量逻辑 |
| 6 | PhaseRunner 重构改变阶段时序 | 单元测试 + 完整真机回归（Vanilla/Fabric/Forge 全跑） |
| 8 | 评分算法可能让某源永久饿死 | tie-breaker：fail_count 相等时按 createdAt 轮转 |

### B.3 各 Phase 退出标准（必须满足才能 close）

- ✅ 所有新测试绿
- ✅ 所有旧测试不退化
- ✅ build-hap.ps1 BUILD SUCCESS
- ✅ HAP 体积变化 < +5%
- ✅ 真机端到端验证场景通过（按各 Phase Step 列出的矩阵）
- ✅ progress.txt 打钩 + git tag 已推

### B.4 退化的判定

如果某 Phase 完成后发现：
- 真机下载速度比 Phase 0 慢 > 10% → 立即 git revert，重新设计
- HAP 体积膨胀 > 5MB → 检查是否引入新依赖
- 任何旧测试变红 → 立即回滚，**不允许"先合再修"**

---

## 文档维护约定

1. 每完成一个 Step，**实时**更新 `progress.txt` 对应行 + git commit
2. 每完成一个 Phase，**回到本文档**把对应 Phase 的 status 改为 ✅
3. 每完成一个 Phase，**回到 `download-system.md`** 把对应未完成项移到状态快照"已完成"
4. 实施过程中如发现新问题/优化点，写到本文档"待跟进"段（不要散在 commit message 里）

> 文档版本：v1（2026-05-05）| 配套：`download-implementation-progress.txt` 跟踪打钩
