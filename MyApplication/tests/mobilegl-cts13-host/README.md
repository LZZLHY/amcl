# 固定 CTS13 host 来源与资格入口

本目录归属主工程测试集成层；case 实现、原运行调度和 QPA 评分仍分别归属 Khronos 官方 CTS 与钉版 MobileGL fork。固定 13 项取自 `opengl-cts-4.6.8.1`，真实 commit 为 `067e8832315e79817ede1c4863804e440f5d1c80`。不扩大全套 CTS，不修改 FBO 代码，不添加 waiver/skip，也不把 host 软件驱动写成目标 OHOS 或完整 GL33/Core 资格。

原真实工具归属如下：`prepare.py` 接入 fork 原 `sync_to_cts.py`/platform，只追加不改函数地址的 provider 观察；`run-observed.py` 调用原 `run_cts_local.py`，保原 case/resume/timeout，额外收取真实 Popen/PID/argv/制品摘要；`qualify.py` 调用原 `cts_matrix_report.build_version_report`，另核固定分母、真实 case 开始、QPA 唯一终止、同 PID/runId、全部官方 GL33/EGL core OWN、映像和 driver maps。输入捕获和原 runner 的 exit 0 均不能单独授予资格。

所有路径显式传入。公开 CI 可在原生 Linux 执行这些入口；AMCL 本机执行时须沿现役 `amcl/qa` 固定服务、同一个 `project.py` OS 锁与不可变 image。既有本轮固定 QA stage recipe 的用途、真实 argv 和源/产物在外部施工收据保留；本候选不另建 Compose 项目、服务或 manager，也不把长期 CTS 编译塞入普通四产品门。需要本机正式自动调度时，由唯一集成人将下列 recipe 接入现有 QA 分支，而不是直接 `docker run`。

准备全新 CTS checkout（不可覆盖已含 port/targets 的旧实验）：

```sh
git clone https://github.com/KhronosGroup/VK-GL-CTS.git "$CTS_SOURCE"
git -C "$CTS_SOURCE" checkout --detach 067e8832315e79817ede1c4863804e440f5d1c80
# external-inputs.json 记录本轮真实官方 fetch_sources.py 的7项精确输入。
python3 -B tests/mobilegl-cts13-host/fetch-inputs.py --cts "$CTS_SOURCE" \
  --output "$NEW_EXTERNAL_RECEIPT"
python3 -B tests/mobilegl-cts13-host/prepare.py \
  --cts "$CTS_SOURCE" --source "$MOBILEGL_SOURCE" --output "$NEW_PREPARE_RECEIPT" \
  --expected-source "$FULL_FORK_COMMIT" --expected-port-sha "$INDEPENDENT_PORT_SHA"
cmake -S "$CTS_SOURCE" -B "$CTS_BUILD" -G Ninja -DDEQP_TARGET=mobilegl-desktop \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_DISABLE_FIND_PACKAGE_ZLIB=TRUE \
  -DCMAKE_DISABLE_FIND_PACKAGE_PNG=TRUE -DDEQP_DISABLE_VK_VIDEO_TESTS=ON
cmake --build "$CTS_BUILD" --target glcts --parallel 4
```

上述 CMake 使用官方 bundled 输入。JsonCpp stock `configure_file` 会写 `external/jsoncpp/src/include/json/config.h` 和 `external/jsoncpp/src/src/lib_json/json_valueiterator.inl`；原模板/原文及生成 SHA 必须分别保存。只给这两个生成目录明确写权限，其余源码只读。不能把生成后的实验 source status 冒称纯官方 067 clean。`prepare.py` 收据记录 port/observer delta，不在未构建时授予 glcts 身份。

每个 backend 用独立冷进程、独占仓外目录；运行之前独立冻结实际 glcts、MobileGL、fork runner/matrix、prepare 收据和 driver/image SHA。正常 host cache 的捕获工具见 `../mobilegl-cpu-host/capture-host-proof.py`，不得借 OHOS crosscache 或旧 dirty host DSO 冒充新 commit。

```sh
export AMCL_RUN_ID="$NEW_RUN_ID" MOBILEGL_BACKEND_TYPE=DirectGLES
export MOBILEGL_CTS_LIB="$ACTUAL_LIBRARY" AMCL_CTS_EXPECTED_PROVIDER="$ACTUAL_LIBRARY"
export AMCL_CTS_PROVIDER_LOG_PREFIX="$NEW_RAW_OUTPUT/provider"
export EGL_PLATFORM=surfaceless LIBGL_ALWAYS_SOFTWARE=1
python3 -B tests/mobilegl-cts13-host/run-observed.py \
  --source "$MOBILEGL_SOURCE" --observations "$NEW_RAW_OUTPUT/native-processes" \
  --expected-runner-sha "$INDEPENDENT_RUNNER_SHA" -- \
  --backend DirectGLES --glcts "$GLCTS" --lib "$ACTUAL_LIBRARY" \
  --caselist tests/mobilegl-cts13-host/cases13.txt --outdir "$NEW_RAW_OUTPUT/cases" \
  --surface fbo --surface-size 256 --gl-config-name rgba8888d24s8 \
  --max-rounds 20 --max-empty-streak 2 --chunk-timeout 120
```

DirectVulkan 另开新目录/runId，并设置明确的 `VK_ICD_FILENAMES` 指向实际 ICD 输入；独立 expectation 的 `mappedDriverPaths` 必须含该真实 ICD library 的进程内路径。仅设置环境值不足以授予映像资格。

独立 expectation 是调用方冻结的 JSON：`runId`、`backend`、`providerPath`、`librarySha256`、`glctsSha256`、`runnerSha256`、`matrixSha256`、`caselistSha256`、`coreGlSourceSha256`、`coreEglSourceSha256`、非空数组 `qpaMarkers`（含该实际源码 GIT marker 和 backend renderer）、数组 `mappedDriverPaths`。保 source/delta/image/driver 来源字段。不得从待验证 native report 自己生成这些预期来验证自己。实际文件可由 host 收取；`providerPath` 与 maps 路径是进程内 canonical 地址，不能用 host 拷贝路径替代。每个 OWN 地址须落在该 provider、同 dev/inode 和 load base 的可执行范围；共同 imageBase 必须绑定实际 offset0 映射。仅地址非零或 maps 出现路径不足以授予资格。

```sh
python3 -B tests/mobilegl-cts13-host/qualify.py --directory "$ACTUAL_RAW_OUTPUT" \
  --source "$MOBILEGL_SOURCE" --cts-source "$CTS_SOURCE" \
  --library "$ACTUAL_RETRIEVED_LIBRARY" --glcts "$ACTUAL_RETRIEVED_GLCTS" \
  --expectation "$INDEPENDENT_EXPECTATION" --output "$NEW_QUALIFICATION_JSON"
```

资格输出逐项保留 Pass/Fail/UNRUN/NOT_SUPPORTED 等原结果，`qualified` 仅在全部固定13为严格 Pass 且所有来源/进程/完成义务成立时为 true。14 个未解析扩展请求如实列名；本轮声明不一致另有独立修复，不能凭 13 Pass 将其删除或称扩展完成。损坏的 expected 参数也是输入错误而非资格绕过。

原 matrix 对重复观察采用后结果覆盖，并保留每次 history；这是广域恢复汇总策略。固定13资格另要求 case 实际唯一，任何重复或没有 Popen 绑定的 QPA 都拒绝，全部原 history 仍保存，不能把早先 Fail 变成资格 PASS。

`test-actual-evidence.py` 接受两份真实冷进程 raw 与独立 expected，先校准原件，再复制原件构造 21 个缺失/截断/旧 PID/runId/强停/错误 payload/地址归属/Fail/NotSupported/损坏预期控制。它只验证薄解析器，不能由这些污染文件产生新增 CPU/GPU 或设备 PASS；原始大证据留在工作区外部并用来源清单关联。
