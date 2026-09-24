# ============================================================
# CMakeLists.txt — MC-OHOS Native 构建配置
# ============================================================
cmake_minimum_required(VERSION 3.5.0)
project(mc_ohos_native)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

# 编译选项：是否包含验证测试代码（发布时可关闭）
option(MC_OHOS_BUILD_TESTS "Build feasibility test modules (default product only)" OFF)

# Typed-input shadow pipeline. Runtime AMCL_INPUT_SHADOW overrides this default.
option(AMCL_INPUT_SHADOW "Enable typed-input shadow ingress by default" ON)

# Startup selection for the GLFW physical source plane. This is an opt-in
# validation/release switch, not Gate 0 evidence: raw-relative and native
# absolute events remain independently blocked by their evidence options below.
# Ordinary products keep the legacy physical owner until the device matrix is
# approved; a validation HAP can select typed without relying on process env.
option(AMCL_GLFW_TYPED_PHYSICAL_DEFAULT
    "Select the typed GLFW physical input backend when no startup override is present" OFF)

# Gate 0 evidence assertion for platform pointer deltas. It asserts normalizable
# units, cursor decoupling and absence of pointer acceleration (R1/R2/R3) -- not
# raw-HID provenance, which telemetry cannot prove; see plan section 83.8. This
# must remain OFF until the supported physical-device/density matrix has been
# recorded and approved; runtime configuration cannot override it.
option(AMCL_GLFW_RAW_RELATIVE_VERIFIED
    "Assert Gate 0 verified normalizable, cursor-decoupled, unaccelerated deltas" OFF)

# Public GLFW Raw Input contract.  This is intentionally independent from the
# compatibility relative gate above: API 22-25 may provide usable relative
# movement. Universal builds also compile this route; the immutable host table
# admits it only on an API26+ 2in1 runtime. Formal-only linking is separate.
option(AMCL_GLFW_API26_RAW_MOUSE_MOTION
    "Declare API 26 complete hardware rawDelta for GLFW raw mouse motion" OFF)

# Gate 0 evidence assertion for XComponent-local physical-pixel coordinates.
# Keep OFF until the supported device/surface matrix has been approved.  The
# runtime environment cannot override this assertion.
option(AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED
    "Assert verified native surface-local absolute pointer semantics" OFF)

# Independent Gate 0 assertion for the XComponent MouseEvent timestamp. The
# public SDK header does not state its unit or clock domain, so native absolute
# routing must also prove it is CLOCK_MONOTONIC nanoseconds before bit14 can be
# published. Coordinate evidence alone is insufficient for stale-epoch safety.
option(AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED
    "Assert XComponent mouse timestamps use CLOCK_MONOTONIC nanoseconds" OFF)

# Diagnostic-only physical mouse telemetry for Gate 0 evidence capture. The
# source file and ArkUI mouse observer are absent from ordinary product builds.
# Enabling this option must never alter source-plane selection or input state.
option(AMCL_INPUT_GATE0_TELEMETRY
    "Build non-routing Gate 0 mouse coordinate/raw-delta telemetry" OFF)

# Compile-time identity assertion for the formal API 26 desktop product.  The
# runtime ProductInputProfile handshake remains necessary (it carries the
# actual runtime API), but a formal desktop native binary must not silently
# accept a mobile/compat profile before publishing its first surface.
option(AMCL_INPUT_COMPILED_FORMAL_DESKTOP
    "Require the runtime input profile to be formal desktop API 26+" OFF)

# 渲染线程 native 栈采样器（诊断设施，默认关闭）。
#   开启后：渲染线程停滞（黑屏空转）时周期性采样其 native 栈 + ASGCT Java 栈打到
#   hilog（tag AMCL_SMPL），用于定位"渲染线程 CPU 空转"类问题。正常游戏几乎零开销，
#   但会安装实时信号处理器并需要 -XX:+PreserveFramePointer，生产构建应保持关闭。
#   开启方式：entry/build-profile.json5 的 externalNativeOptions.arguments 加
#   "-DAMCL_STACK_SAMPLER=ON"（同时该宏会让 libentry 自动补 PreserveFramePointer）。
option(AMCL_STACK_SAMPLER "Build render-thread native stack sampler (diagnostic)" OFF)

# MobileGlues accounting, split along the axis that actually carries the cost.
#
# AMCL_MG_FRAME_STATS is the present-boundary ledger: one clock pair per frame,
# tens of events per second, and the only source of the fps / frame_ms / present_ms
# numbers every render investigation in docs/reports is written against.
#
# ⭐ TURNED OFF 2026-09-05 (1000591). The CPU cost was priced (see the A/B below)
# and it was fine. The LOG VOLUME cost was never priced, and that is what this
# switch actually ships:
#
#   Every emitted block is 6 lines / 2,322 bytes, once per second, and LOG_I in
#   MobileGlues has no DEBUG gate -- it writes printf (-> mc_output.log) AND
#   write_log (-> filesDir/MG/latest.log, fflush per line), and logTailThread
#   then forwards the mc_output.log copy into hilog. Three sinks, 6 lines/s.
#
# Measured on a real user-submitted mc_output.log (2026-09-03, 441 KB / 1642
# lines, see docs/reports/2026-09-05_LOGGING_SYSTEM_FULL_SURVEY.md §6):
#
#   - 1,092 of 1,642 lines (66.5%) were frame telemetry;
#   - 390,352 bytes sat between the last Minecraft line and EOF -- all telemetry;
#   - the 32 KB tail that SessionMarker.readMcLogTail actually feeds to the crash
#     classifier held 85 lines, of which exactly one was not [MG-FRAME-*] (and
#     that one was a byte-boundary fragment). All 14 diagnosis predicates false.
#   - 32768 / 2322 = 14 s. The crash-diagnosis window sees the last ~14 seconds
#     of a session, and telemetry alone more than fills it.
#   - 240 KB upload budget / 2322 = ~106 s, and sanitizeLogForExport keeps the
#     TAIL, so on any longer session the env header and the launcher log are the
#     parts that get truncated away.
#
# This is the same shape as 1000183/1000202, where [GLFW-DIAG] spam pushed
# "Stopping!" out of the tail and normal exits were misdiagnosed as crashes. That
# one was fixed by printing once; this producer runs at 6 lines/s and is not in
# LogNoiseFilter.
#
# WHAT WE GIVE UP, stated plainly: fps / frame_ms / present_ms / p50-p95-p99 are
# gone from shipping builds. Every render investigation in docs/reports is
# written against those numbers. ⇒ Re-enable this locally (-DAMCL_MG_FRAME_STATS=ON)
# for any render work; do not ship it back ON without also solving the volume
# problem (separate sink, or a LogNoiseFilter rule, or a sampling interval).
#
# AMCL_MG_FRAME_STATS_GL_SCOPES is the scope installed on GL wrappers, which is
# between three and five orders of magnitude more frequent. It is OFF, and the
# text that used to live here is why the two had to be separated:
#
#   "ordinary GL calls take only the causal-capture branch and are timed for two
#    frames after a terrain event ... without repeating the exhaustive A/B
#    observer that measurably halved frame rate"
#
# Both halves of that stopped holding once the selective observer grew:
#   - frame_stats_core.h arms the causal window on any frame at or over
#     kSlowFrameNs (25 ms). Below 40 fps that is every frame, so the window is
#     open for its bounded duty cycle continuously instead of around an event --
#     and the slower the frame rate, the more reliably it re-arms.
#   - BufferAllocation became always-selected, and glBufferData is the entire
#     per-frame buffer path on a pre-1.20 client. always-selected has no window:
#     it clocks every call, paying two clock_gettime plus the classify() strcmp
#     chain each time.
# The change that did both recorded its own effect: GL-attributed wall time went
# 0.68% -> 2.86% -> 4.55% across the two steps. Nothing checked that against the
# frame rate, which is the mistake 1000551 already paid for once (59.53 -> 27.59
# FPS from exhaustive timing) and which renderer-backend-governance.md turned into
# a rule this then broke.
#
# ⭐ MEASURED 2026-08-30 16:50, and the result does NOT say the observer was the
# frame-rate problem. Same device, same world, same options.txt, only these
# switches flipped; MC 1.18.2 active-world present rate, one yardstick over every
# session's raw mc_output.log:
#
#   session                obs_calls(max)   weighted   p50     max
#   08-29 22:22 obs-on                  2      24.48   23.39   44.26
#   08-30 11:19 obs+probe           81903      46.18   43.89   80.38
#   08-30 16:50 GL_SCOPES=0             0      42.38   39.54   87.91
#
# The session with essentially no instrumentation (obs_calls=2, before
# BufferAllocation became always-on) is the SLOWEST of the three, and turning
# everything off did not beat the fully instrumented run. There is no negative
# correlation between how much this observer measures and how fast the client
# renders. The self-perturbation hypothesis is rejected on evidence.
#
# Both halves of the note above still stand as facts -- the 25 ms arming does fire
# every frame below 40 fps, and always-selected really has no window -- but the
# conclusion drawn from them (that this was costing tens of ms per frame) does not
# follow, and is withdrawn. Per-call work being real is not the same as it being
# material at this scale.
#
# So why is the switch still OFF? Not as a fix. Because 1000551 priced observer
# self-perturbation once already (exhaustive timing: 59.53 -> 27.59 FPS) and the
# resulting rule is that a resident observer has to be selective; "selective" had
# quietly stopped being true here, and nothing had measured it. The switch is what
# makes it measurable, and the measurement above is what a default should rest on.
# Flipping it back ON is now a defensible change -- but do it with its own A/B on a
# fixed route and a sample larger than the ~46 one-second windows this verdict
# rests on, not by deleting the switch.
#
# The cost reduction remains worth doing on its own merits (classify() resolved at
# compile time instead of 15-20 strcmp per call, an arming threshold relative to the
# current frame time rather than an absolute 25 ms), just not as a frame-rate fix.
option(AMCL_MG_FRAME_STATS "Build MobileGlues present-boundary frame statistics" OFF)
option(AMCL_MG_FRAME_STATS_GL_SCOPES
    "Install per-GL-call timing scopes (self-perturbing; see comment above)" OFF)
option(AMCL_MG_FRAME_STATS_EXHAUSTIVE "Time every wrapped GL call (high-overhead diagnostic)" OFF)

# One-shot diagnostic: which (format, type) pairs a client passes to the texture
# upload path. The answer does not change while a client runs, but the call site is
# every glTexSubImage2D -- about 60 per frame on 1.18.2. OFF in shipping builds.
option(AMCL_MG_UPLOAD_PROBE "Count texture upload enum pairs (per-upload diagnostic)" OFF)

include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/ProductDiagnostics.cmake")

if(AMCL_MG_FRAME_STATS_EXHAUSTIVE AND NOT AMCL_MG_FRAME_STATS_GL_SCOPES)
    message(FATAL_ERROR
        "AMCL_MG_FRAME_STATS_EXHAUSTIVE times every wrapped call and requires "
        "AMCL_MG_FRAME_STATS_GL_SCOPES=ON")
endif()

# Lab-only terrain-upload scheduler. The option is OFF in every shipping build,
# which compiles all GL-entry/upload/present hooks away. A lab build may leave
# the override at -1 to exercise protected runtime config, or force 0/1/2 for a
# reproducible disabled/observe/coalesce HAP.
option(AMCL_MG_UPLOAD_SCHEDULER_LAB
    "Build the rejected MG terrain-upload scheduler laboratory path" OFF)
if(AMCL_MG_UPLOAD_SCHEDULER_LAB AND NOT AMCL_DEVELOPER_DIAGNOSTICS)
    message(FATAL_ERROR "AMCL_MG_UPLOAD_SCHEDULER_LAB is default-only")
endif()
set(AMCL_MG_BUFFER_UPLOAD_MODE_OVERRIDE "-1" CACHE STRING
    "MG upload lab override: -1=config, 0=off, 1=observe, 2=coalesce")
set_property(CACHE AMCL_MG_BUFFER_UPLOAD_MODE_OVERRIDE PROPERTY STRINGS -1 0 1 2)
if(NOT AMCL_MG_BUFFER_UPLOAD_MODE_OVERRIDE MATCHES "^-1$|^[012]$")
    message(FATAL_ERROR
        "AMCL_MG_BUFFER_UPLOAD_MODE_OVERRIDE must be -1, 0, 1 or 2")
endif()
if(NOT AMCL_MG_UPLOAD_SCHEDULER_LAB AND
   NOT AMCL_MG_BUFFER_UPLOAD_MODE_OVERRIDE STREQUAL "-1")
    message(FATAL_ERROR
        "AMCL_MG_BUFFER_UPLOAD_MODE_OVERRIDE requires AMCL_MG_UPLOAD_SCHEDULER_LAB=ON")
endif()

# ============================================================
# MobileGlues 源码路径（即时编译）
# ============================================================
# MG 是我们基于官方 2.0.0 的可上游化集成分支 git submodule，
# 位置 prebuilt/mobileglues/mg_src，与 prebuilt/lwjgl3/lwjgl3_src 同构：源码树里带 .git，
# 改完可直接 commit/push 回 fork。版本由 superproject 的 gitlink 钉住，
# deps.lock [mobileglues] 记 branch/base_commit。
#
# 基线策略（2026-08-10）：官方 2.0.0 source tree 是唯一功能基线。下游只保留
# 可上游化的 build/embed API 与 OHOS 必需的 exact-self GL resolver；旧 depth-format
# 补丁已由 2.0.0 更完整地上游实现，不再重放。
get_filename_component(AMCL_REPO_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../../.. ABSOLUTE)

# Gate 0 证据门禁必须在任何编译目标之前执行：AMCL_GLFW_*_VERIFIED 断言的是真机事实，
# 未经 gate0-evidence.lock 书面批准就置 ON 时，构建停在 configure 期而不是产出一个
# 宣称未验证能力的 .so。默认全部 OFF，此模块不读清单、零成本。
include(${CMAKE_CURRENT_SOURCE_DIR}/input/Gate0Evidence.cmake)

set(AMCL_GRAPHICS_ARTIFACT_SET "complete" CACHE STRING "Explicit packaged graphics artifact policy" FORCE)
# Compatibility macro for existing source/test seams. Every product ships the
# same providers; the immutable runtime plan selects EGL/GL ownership.
set(AMCL_NATIVE_DESKTOP_ONLY OFF CACHE BOOL "Retired product renderer exclusion" FORCE)
find_package(Git REQUIRED)
if(NOT AMCL_NATIVE_DESKTOP_ONLY)
set(MG_SRC_DIR ${AMCL_REPO_ROOT}/prebuilt/mobileglues/mg_src/MobileGlues-cpp)
if(NOT EXISTS ${MG_SRC_DIR}/CMakeLists.txt)
    message(FATAL_ERROR
        "MobileGlues source not found at ${MG_SRC_DIR}.\n"
        "Run: bash setup_deps.sh --mobileglues-only")
endif()

# MobileGlues owns its source manifest, dependency options, visibility and LTO
# contract. AMCL consumes the OBJECT core and supplies the final libglfw DSO.
set(MOBILEGLUES_BUILD_STANDALONE OFF)
set(MOBILEGLUES_AUTO_INIT OFF)
set(MOBILEGLUES_ENABLE_PROFILING OFF)
add_subdirectory(${MG_SRC_DIR} ${CMAKE_CURRENT_BINARY_DIR}/mobileglues)

# The upstream plugin benchmark is a developer tool, not a rendering backend.
# Keep all render sources; omit only the independently callable benchmark TU.
if(NOT AMCL_DEVELOPER_DIAGNOSTICS)
    get_target_property(AMCL_MG_PRODUCT_SOURCES mobileglues_core SOURCES)
    list(FILTER AMCL_MG_PRODUCT_SOURCES EXCLUDE REGEX "(^|/)bench/multidraw_bench\\.cpp$")
    set_property(TARGET mobileglues_core PROPERTY SOURCES ${AMCL_MG_PRODUCT_SOURCES})
endif()
if(NOT TARGET MobileGlues::Core)
    message(FATAL_ERROR "MobileGlues embedded core target was not created")
endif()
# Passed explicitly in both branches, same reason as GL_SCOPES below (1000545):
# a switch's declared default and the product's actual value are two facts, and
# only the compile command can assert the second one. frame_stats.h happens to
# default this to 0, so OFF would work by omission -- but then "is telemetry in
# this HAP" would be unanswerable from the build log, which is exactly how the
# volume cost went unpriced until 1000591.
if(AMCL_MG_FRAME_STATS OR AMCL_MG_FRAME_STATS_EXHAUSTIVE)
    target_compile_definitions(mobileglues_core PRIVATE AMCL_MG_FRAME_STATS=1)
else()
    target_compile_definitions(mobileglues_core PRIVATE AMCL_MG_FRAME_STATS=0)
endif()
# Always passed explicitly, both values. The header defaults this to 1, so relying
# on the default would make an OFF option silently mean ON -- the shape 1000545
# names: a switch's declared default and the product's actual value are two facts.
if(AMCL_MG_FRAME_STATS_GL_SCOPES OR AMCL_MG_FRAME_STATS_EXHAUSTIVE)
    target_compile_definitions(mobileglues_core PRIVATE AMCL_MG_FRAME_STATS_GL_SCOPES=1)
else()
    target_compile_definitions(mobileglues_core PRIVATE AMCL_MG_FRAME_STATS_GL_SCOPES=0)
endif()
if(AMCL_MG_FRAME_STATS_EXHAUSTIVE)
    target_compile_definitions(mobileglues_core PRIVATE AMCL_MG_FRAME_STATS_EXHAUSTIVE=1)
endif()
if(AMCL_MG_UPLOAD_PROBE)
    target_compile_definitions(mobileglues_core PRIVATE AMCL_MG_UPLOAD_PROBE=1)
else()
    target_compile_definitions(mobileglues_core PRIVATE AMCL_MG_UPLOAD_PROBE=0)
endif()
target_compile_definitions(mobileglues_core PRIVATE
    AMCL_MG_BUFFER_UPLOAD_MODE_OVERRIDE=${AMCL_MG_BUFFER_UPLOAD_MODE_OVERRIDE})
if(AMCL_MG_UPLOAD_SCHEDULER_LAB)
    target_compile_definitions(mobileglues_core PRIVATE AMCL_MG_UPLOAD_SCHEDULER_LAB=1)
else()
    target_compile_definitions(mobileglues_core PRIVATE AMCL_MG_UPLOAD_SCHEDULER_LAB=0)
endif()

# libentry owns runtime-config migration before libglfw/MG initialization. Reuse
# the exact cJSON source pinned by MG, but compile a hidden private copy so JSON
# helpers never become part of either DSO's public ABI.
add_library(amcl_mg_config_json OBJECT
    ${MG_SRC_DIR}/config/cJSON.c
)
set_target_properties(amcl_mg_config_json PROPERTIES
    C_STANDARD 99
    C_STANDARD_REQUIRED ON
    POSITION_INDEPENDENT_CODE ON
    C_VISIBILITY_PRESET hidden
)
target_include_directories(amcl_mg_config_json PRIVATE
    ${MG_SRC_DIR}/config
)

# Benchmark evidence must never cross-hit another MG build that happens to use
# the same semantic version. Resolve the exact embedded submodule commit at
# configure time and fail closed if the source tree cannot identify itself.
find_package(Git REQUIRED)
execute_process(
    COMMAND ${GIT_EXECUTABLE} rev-parse --verify HEAD
    WORKING_DIRECTORY ${MG_SRC_DIR}
    RESULT_VARIABLE AMCL_MG_GIT_RESULT
    OUTPUT_VARIABLE AMCL_MG_SOURCE_COMMIT
    ERROR_VARIABLE AMCL_MG_GIT_ERROR
    OUTPUT_STRIP_TRAILING_WHITESPACE
)
string(LENGTH "${AMCL_MG_SOURCE_COMMIT}" AMCL_MG_SOURCE_COMMIT_LENGTH)
if(NOT AMCL_MG_GIT_RESULT EQUAL 0 OR
   NOT AMCL_MG_SOURCE_COMMIT_LENGTH EQUAL 40 OR
   NOT AMCL_MG_SOURCE_COMMIT MATCHES "^[0-9a-f]+$")
    message(FATAL_ERROR
        "Cannot identify exact MobileGlues source commit: result=${AMCL_MG_GIT_RESULT} "
        "value='${AMCL_MG_SOURCE_COMMIT}' error='${AMCL_MG_GIT_ERROR}'")
endif()
message(STATUS "AMCL MobileGlues source commit: ${AMCL_MG_SOURCE_COMMIT}")

# A commit plus a dirty boolean is not a source identity: two local patches on
# the same HEAD would otherwise produce indistinguishable libglfw.so images and
# could cross-hit benchmark evidence. Generate this header on every build (the
# script writes only when content changes) from HEAD, binary diff, untracked
# bytes, recursive submodule state/content and all MG-affecting options. Because
# glfw includes the header, a content change forces recompilation and changes the
# ELF build-id even when Git restores source mtimes during a branch switch.
set(AMCL_MG_REPO_DIR "${AMCL_REPO_ROOT}/prebuilt/mobileglues/mg_src")
set(AMCL_MG_IDENTITY_SCRIPT "${AMCL_REPO_ROOT}/scripts/compute-mg-source-identity.mjs")
set(AMCL_MG_GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
set(AMCL_MG_IDENTITY_HEADER "${AMCL_MG_GENERATED_DIR}/amcl_mg_source_identity.h")
set(AMCL_MG_EMBED_BUILD_STANDALONE "${MOBILEGLUES_BUILD_STANDALONE}" CACHE INTERNAL
    "MobileGlues standalone mode included in the embedded source identity" FORCE)
set(AMCL_MG_EMBED_AUTO_INIT "${MOBILEGLUES_AUTO_INIT}" CACHE INTERNAL
    "MobileGlues auto-init mode included in the embedded source identity" FORCE)
set(AMCL_MG_EMBED_PROFILING "${MOBILEGLUES_ENABLE_PROFILING}" CACHE INTERNAL
    "MobileGlues profiling mode included in the embedded source identity" FORCE)
find_program(AMCL_NODE_EXECUTABLE NAMES node node.exe)
if(NOT AMCL_NODE_EXECUTABLE)
    message(FATAL_ERROR
        "Node.js is required to generate the MobileGlues source identity header")
endif()
mark_as_advanced(AMCL_NODE_EXECUTABLE)
set(AMCL_MG_IDENTITY_ALL ALL)
if(AMCL_NATIVE_DESKTOP_ONLY)
    set(AMCL_MG_IDENTITY_ALL)
endif()
add_custom_target(amcl_mg_source_identity ${AMCL_MG_IDENTITY_ALL}
    COMMAND "${AMCL_NODE_EXECUTABLE}" "${AMCL_MG_IDENTITY_SCRIPT}"
        --repo "${AMCL_MG_REPO_DIR}"
        --output "${AMCL_MG_IDENTITY_HEADER}"
        --option "AMCL_MG_FRAME_STATS=${AMCL_MG_FRAME_STATS}"
        --option "AMCL_MG_FRAME_STATS_EXHAUSTIVE=${AMCL_MG_FRAME_STATS_EXHAUSTIVE}"
        --option "AMCL_MG_UPLOAD_SCHEDULER_LAB=${AMCL_MG_UPLOAD_SCHEDULER_LAB}"
        --option "AMCL_MG_BUFFER_UPLOAD_MODE_OVERRIDE=${AMCL_MG_BUFFER_UPLOAD_MODE_OVERRIDE}"
        --option "AMCL_MG_EMBED_BUILD_STANDALONE=${AMCL_MG_EMBED_BUILD_STANDALONE}"
        --option "AMCL_MG_EMBED_AUTO_INIT=${AMCL_MG_EMBED_AUTO_INIT}"
        --option "AMCL_MG_EMBED_PROFILING=${AMCL_MG_EMBED_PROFILING}"
        --option "MOBILEGLUES_LTO_MODE=${MOBILEGLUES_LTO_MODE}"
        --option "CMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}"
    BYPRODUCTS "${AMCL_MG_IDENTITY_HEADER}"
    COMMENT "Computing content-addressed MobileGlues source identity"
    VERBATIM
)
set_source_files_properties("${AMCL_MG_IDENTITY_HEADER}" PROPERTIES GENERATED TRUE)
endif() # MobileGlues build/configuration is absent from formal desktop

execute_process(
    COMMAND ${GIT_EXECUTABLE} rev-parse --verify HEAD
    WORKING_DIRECTORY ${AMCL_REPO_ROOT}
    RESULT_VARIABLE AMCL_HOST_GIT_RESULT
    OUTPUT_VARIABLE AMCL_HOST_SOURCE_COMMIT
    ERROR_VARIABLE AMCL_HOST_GIT_ERROR
    OUTPUT_STRIP_TRAILING_WHITESPACE
)
string(LENGTH "${AMCL_HOST_SOURCE_COMMIT}" AMCL_HOST_SOURCE_COMMIT_LENGTH)
if(NOT AMCL_HOST_GIT_RESULT EQUAL 0 OR
   NOT AMCL_HOST_SOURCE_COMMIT_LENGTH EQUAL 40 OR
   NOT AMCL_HOST_SOURCE_COMMIT MATCHES "^[0-9a-f]+$")
    message(FATAL_ERROR
        "Cannot identify AMCL host source commit: result=${AMCL_HOST_GIT_RESULT} "
        "value='${AMCL_HOST_SOURCE_COMMIT}' error='${AMCL_HOST_GIT_ERROR}'")
endif()
execute_process(
    COMMAND ${GIT_EXECUTABLE} status --porcelain=v1 --untracked-files=no
    WORKING_DIRECTORY ${AMCL_REPO_ROOT}
    RESULT_VARIABLE AMCL_HOST_STATUS_RESULT
    OUTPUT_VARIABLE AMCL_HOST_STATUS
    ERROR_VARIABLE AMCL_HOST_STATUS_ERROR
    OUTPUT_STRIP_TRAILING_WHITESPACE
)
if(NOT AMCL_HOST_STATUS_RESULT EQUAL 0)
    message(FATAL_ERROR "Cannot inspect AMCL host source state: ${AMCL_HOST_STATUS_ERROR}")
endif()
if(AMCL_HOST_STATUS STREQUAL "")
    set(AMCL_HOST_SOURCE_STATE "clean")
else()
    set(AMCL_HOST_SOURCE_STATE "dirty")
endif()
string(CONCAT AMCL_HOST_BUILD_IDENTITY
    "source=" "${AMCL_HOST_SOURCE_COMMIT}"
    ":state=" "${AMCL_HOST_SOURCE_STATE}"
    ":compiler=" "${CMAKE_CXX_COMPILER_ID}-${CMAKE_CXX_COMPILER_VERSION}"
    ":system=" "${CMAKE_SYSTEM_NAME}-${CMAKE_SYSTEM_PROCESSOR}"
    ":mode=" "${CMAKE_BUILD_TYPE}")
message(STATUS "AMCL host build identity: ${AMCL_HOST_BUILD_IDENTITY}")

if(NOT AMCL_NATIVE_DESKTOP_ONLY)
set(AMCL_MG_VERSION_HEADER "${MG_SRC_DIR}/version.h")
foreach(AMCL_MG_VERSION_PART IN ITEMS MAJOR MINOR REVISION PATCH)
    file(STRINGS "${AMCL_MG_VERSION_HEADER}" AMCL_MG_VERSION_LINE
         REGEX "^#define ${AMCL_MG_VERSION_PART} [0-9]+$")
    if(NOT AMCL_MG_VERSION_LINE)
        message(FATAL_ERROR
            "Cannot resolve ${AMCL_MG_VERSION_PART} from ${AMCL_MG_VERSION_HEADER}")
    endif()
    string(REGEX REPLACE
        "^#define ${AMCL_MG_VERSION_PART} ([0-9]+)$" "\\1"
        AMCL_MG_VERSION_${AMCL_MG_VERSION_PART} "${AMCL_MG_VERSION_LINE}")
endforeach()
string(CONCAT AMCL_MG_SEMANTIC_VERSION
    "${AMCL_MG_VERSION_MAJOR}.${AMCL_MG_VERSION_MINOR}."
    "${AMCL_MG_VERSION_REVISION}.${AMCL_MG_VERSION_PATCH}")
message(STATUS "AMCL MobileGlues semantic version: ${AMCL_MG_SEMANTIC_VERSION}")
endif()

# ============================================================
# 测试辅助库（仅测试阶段使用）
# ============================================================
if(MC_OHOS_BUILD_TESTS)
    add_library(fakejvm SHARED
        tests/fake_jvm.cpp
    )
endif()

# ============================================================
# 源文件收集（按模块分组）
# ============================================================

# NAPI 入口层（按职责拆分，详见 docs/guides/napi-layer-refactor-plan.md）
option(AMCL_DESKTOP_NATIVE_GL_VALIDATE "Build a non-publishable desktop native GL validation variant" OFF)

set(NAPI_SOURCES
    napi/napi_entry.cpp     # Init() 调度器（顺序契约见文件顶部）
    napi/napi_helpers.cpp   # 共享类型转换工具（amcl::napi 命名空间）
    napi/napi_jvm.cpp       # JVM / GPU / 下载引擎 probe NAPI
    platform/native_gl.cpp
    platform/desktop_gamepad.cpp
    napi/napi_desktop.cpp
    napi/napi_mc.cpp        # Minecraft 启动器 NAPI（含 MakeIntResult 统一）
    napi/napi_log.cpp       # AMCL 持久化日志 NAPI
    napi/napi_input.cpp     # 输入事件 / 控件区域 / XComponent 尺寸 NAPI
    napi/napi_forge.cpp     # Forge 安装器（异步 fork+JVM）NAPI
    napi/napi_tests.cpp     # MC_OHOS_BUILD_TESTS 验证测试（条件编译）
)

# 平台模块（XComponent、触摸、GPU 信息、MG 配置、Vulkan 探针）
set(PLATFORM_SOURCES
    platform/xcomponent.cpp
    platform/cursor_lock.cpp    # grabbed 模式锁定系统光标（dlsym OH_WindowManager_LockCursor，无链接依赖）
    platform/window_event_filter.cpp  # 窗口级过滤鼠标派生的合成触摸包（dlsym oh_window_event_filter，无链接依赖）
    platform/input_source.cpp         # 输入端（触控虚拟按键 / 手柄 / 物理键鼠）：三端平级的一等概念
    platform/input_channel_policy.cpp # 端**内部**重复投递通道的单一所有者仲裁（与"端"正交）
    platform/external_held_registry.cpp # 经 NAPI 下来的持续按下态：按端隔离的 owner 配对（有 host test）
    platform/input_invariants.cpp      # 输入账目的不变量求值器（纯函数，有 host test）
    platform/joystick_sector.cpp       # 摇杆八向扇区判定（与 ArkTS 侧同一份规格，两侧各有测试）
    platform/ohos_frame_rate_hint.cpp
    platform/ohos_native_window_telemetry.cpp
    platform/touch_input.cpp
    platform/input_ledger.cpp
    platform/legacy_physical_edge_router.cpp
    platform/look_delta_math.cpp
    platform/look_pipeline_stats.cpp   # 视角管线观测面（纯计数/恒等式，有 host test）
    platform/mouse_synth_touch_source.cpp # "这个触摸包其实是鼠标吗"的分类器（原 tap 识别器已删）
    platform/native_mouse_route_policy.cpp
    platform/physical_wheel_quantizer.cpp
    platform/product_input_policy.cpp # product×runtime API 输入合同（desktop API26 / legacy fallback）
    platform/render_scale.cpp          # 渲染分辨率缩放：解析/取整/坐标映射（纯函数，有 host test）
    input/platform_input_ingress.cpp
    input/input_trace.cpp
    input/input_shadow_consumer.cpp
    platform/gpu_info.cpp
    platform/vulkan_probe.cpp   # Vulkan 能力探针（VULKAN_ADAPTATION_PLAN.md Phase 0；dlopen libvulkan，无链接依赖）
    platform/vulkan_requirement_policy.cpp # exact Minecraft 26.2/26.3 device requirement policy
    platform/mobilegl_capability.cpp
    platform/mobilegl_capability_driver.cpp
    platform/graphics_plan.cpp  # versioned graphics plan parser; no provider initialization or options mutation
    # ⚰️ 2026-08-27（渲染后端治理 §S6）：这里曾有 platform/osmesa_probe.cpp
    #   （OSMesa+Zink 自检，dlopen libOSMesa，无链接依赖）。zink 完全退役后一并摘除 ——
    #   一个回答"该不该找回 zink"的探针，在 zink 退役之后没人会据此行动。
    #   索引与恢复路径：prebuilt/mesa-zink/integration-archive/README.md
)

if(NOT AMCL_NATIVE_DESKTOP_ONLY)
    list(APPEND PLATFORM_SOURCES platform/mg_config.cpp platform/mg_config_migration.cpp)
endif()

# API22+ products resolve newer functions dynamically. This SDK-only probe
# must never be enabled in a distributable HAP with an API22 install floor.
option(AMCL_API26_LINK_PROBE "Build a non-distributable API26 strong-link SDK probe" OFF)
if(AMCL_API26_LINK_PROBE)
    if(NOT CMAKE_SYSTEM_NAME STREQUAL "OHOS")
        message(FATAL_ERROR
            "AMCL_GLFW_API26_RAW_MOUSE_MOTION requires the OHOS API26 native toolchain")
    endif()
    list(APPEND PLATFORM_SOURCES platform/api26_input_link_probe.cpp)
endif()

# 归一化后再判定：与 Gate 0 证据位同一个理由（见 input/Gate0Evidence.cmake）。
# 这里的分歧后果是链接失败而不是能力泄漏——`if()` 判假会让 TU 不参与编译，而
# `$<BOOL:>` 判真会让 touch_input/xcomponent/napi_input 里的 `#if` 块打开并引用
# 未定义符号。仍然要修：fail-loud 的失败原因会被误读成门禁问题。
amcl_gate0_normalize_enabled(AMCL_INPUT_GATE0_TELEMETRY
                             AMCL_GATE0_DEF_AMCL_INPUT_GATE0_TELEMETRY)
if(AMCL_GATE0_DEF_AMCL_INPUT_GATE0_TELEMETRY)
    list(APPEND PLATFORM_SOURCES platform/gate0_input_telemetry.cpp)
endif()

# OpenAL Soft（真正的 3D 音频实现，OHAudio 后端）
# 替代了之前的 openal_stub.c 空实现
# 构建配置和 OHAudio 后端代码在 openal/ 目录中
add_subdirectory(openal ${CMAKE_CURRENT_BINARY_DIR}/openal)

# libjcocoa.so — java-objc-bridge JNI 空实现
add_library(jcocoa SHARED
    stubs/jcocoa_stub.c
)

# libobjc.A.so — java-objc-bridge Runtime JNA 空实现
add_library(objc.A SHARED
    stubs/objc_stub.c
)

# ============================================================
# libamcl_gl_host.so — MobileGlues provider DSO
# ============================================================
# The translation core is linked exactly once, here. GLFW remains the window,
# input and session facade and resolves GL/EGL through this provider's C ABI.
# Raw resolver names are private so a second provider cannot satisfy an internal
# core call by ELF symbol interposition.
if(NOT AMCL_NATIVE_DESKTOP_ONLY)
    target_compile_definitions(mobileglues_core PRIVATE
        glXGetProcAddress=amclMgRawGlXGetProcAddress
        glXGetProcAddressARB=amclMgRawGlXGetProcAddressARB
        eglGetProcAddress=amclMgRawEglGetProcAddress)
    add_library(amcl_gl_host SHARED
        $<TARGET_OBJECTS:mobileglues_core>
        platform/gl_host.cpp)
    add_dependencies(amcl_gl_host amcl_mg_source_identity)
    target_include_directories(amcl_gl_host PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${MG_SRC_DIR}/include
        ${MG_SRC_DIR}
        ${AMCL_MG_GENERATED_DIR}
        ${CMAKE_CURRENT_BINARY_DIR})
    target_compile_options(amcl_gl_host PRIVATE -fvisibility=hidden)
    target_compile_definitions(amcl_gl_host PRIVATE
        AMCL_MG_BENCHMARK_ENABLED=$<BOOL:${AMCL_DEVELOPER_DIAGNOSTICS}>)
    target_link_libraries(amcl_gl_host PRIVATE
        glslang::glslang
        spirv-cross-c
        libhilog_ndk.z.so)
    target_link_options(amcl_gl_host PRIVATE
        -Wl,--no-undefined
        -Wl,-Bsymbolic-functions
        -Wl,--exclude-libs,ALL
        -Wl,--gc-sections)
    set(AMCL_GL_HOST_VERSION_SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/platform/gl_host.version")
    if(NOT AMCL_DEVELOPER_DIAGNOSTICS)
        file(READ "${AMCL_GL_HOST_VERSION_SCRIPT}" AMCL_GL_HOST_PRODUCT_EXPORTS)
        string(REGEX REPLACE "[ \t]*mg_multidraw_bench_(progress|run);\r?\n" ""
            AMCL_GL_HOST_PRODUCT_EXPORTS "${AMCL_GL_HOST_PRODUCT_EXPORTS}")
        set(AMCL_GL_HOST_VERSION_SCRIPT "${CMAKE_CURRENT_BINARY_DIR}/gl_host_product.version")
        file(WRITE "${AMCL_GL_HOST_VERSION_SCRIPT}" "${AMCL_GL_HOST_PRODUCT_EXPORTS}")
    endif()
    target_link_options(amcl_gl_host PRIVATE
        "-Wl,--version-script=${AMCL_GL_HOST_VERSION_SCRIPT}")
    set_target_properties(amcl_gl_host PROPERTIES
        CXX_STANDARD 20
        CXX_STANDARD_REQUIRED ON
        CXX_VISIBILITY_PRESET hidden
        VISIBILITY_INLINES_HIDDEN YES
        BUILD_WITH_INSTALL_RPATH TRUE
        INSTALL_RPATH "$ORIGIN"
        INSTALL_RPATH_USE_LINK_PATH FALSE)
endif()

# ============================================================
# libglfw.so — GLFW/window/input facade
# ============================================================
add_library(glfw SHARED
    # GLFW 兼容层（拆分为多个职责文件）
    glfw/glfw_compat.cpp       # 核心 API: init/createWindow/pollEvents/swap
    # ⚰️ 墓碑: glfw/glfw_osmesa.cpp（Zink/OSMesa 上屏，32 KB）已于 2026-08-27 删除
    #   —— zink 完全退役（产品决策 D1），`glfw_compat.cpp` 的 17 处分支同批摘除。
    #   施工记录 §S6（退役）/ §S7（摘除）；恢复索引与 git 取回命令见
    #   prebuilt/mesa-zink/integration-archive/README.md §四。
    #   ⭐ 它是 MobileGL DirectVulkan 的**参考实现**（一份已在真机出过图的"后端自己拿
    #   NativeWindow 租约上屏"：park buffer / 生命周期互斥 / 跨 libglfw 副本注入 /
    #   几何校验）⇒ 治理规范 §2.2、MOBILEGL_ADAPTATION_PLAN.md §4.5 仍指向它。
    platform/native_gl.cpp
    glfw/graphics_runtime_compat.cpp # 旧ABI仅无状态转发，公共实现归中立运行时
    platform/desktop_host_client.cpp
    glfw/glfw_callbacks.cpp    # 回调设置 + 窗口/监视器/输入 stub
    glfw/glfw_vulkan.cpp       # Vulkan surface 四件套（VK_OHOS_surface，Phase 2）
    glfw/ohos_render_scheduler.cpp # OHOS 渲染线程 QoS lease（只在 context-current 生命周期内生效）
    glfw/input_bridge_ohos.c   # 输入事件 ring buffer + CallbackBridge JNI
    input/input_state_core.cpp # backend-neutral typed input singleton（只归属 libglfw.so）
    input/amcl_input_host_descriptor.cpp # 单 table pointer 跨 linker namespace descriptor
    input/adapters/glfw_input_adapter.cpp # GLFW3 typed consumer；默认 legacy、启动 flag 二选一
    input/adapters/backend_keymaps.cpp # LWJGL2 / SDL3 后端各自的 raw OHOS → 自己那套编码（各只翻一次）
    input/adapters/backend_input_bridge.cpp # 非 GLFW 后端的 typed 拉取 ABI（各一个 core 消费者 + 独立队列）
    input/adapters/lwjgl2_event_translate.cpp # LWJGL2 出线翻译（纯函数 + C ABI，为了能进 host 构建被断言）
    input/adapters/glfw_typed_absolute_route.cpp # surfaceEpoch + NativeWindow generation cursor/button gate
    input/adapters/glfw_typed_runtime_dispatch.cpp # exact publication commit + deferred callback seam
    input/adapters/glfw_typed_look_route.cpp # typed 相对样本 → libentry 视角漏斗的反向 trampoline 接缝
    # ⚠️ 这个 TU 同时也在 PLATFORM_SOURCES（libentry）里，**两个 DSO 各编一份是刻意的**：
    # 它是纯函数 + 零状态（`kGlfwPhysicalWheelPolicy` 本来就是 inline constexpr，早已每
    # DSO 一份）。不这样做的后果实测过：`glfw_compat.cpp` 的 typedWheelSink 调
    # `GlfwScrollFromWheelPx`，而定义只在 libentry ⇒ libglfw 里留下一个 UND，而本目标的
    # link options 没有 `--no-undefined` ⇒ 链接静默通过、加载期才炸（计划 §86.1）。
    platform/physical_wheel_quantizer.cpp
    input/adapters/glfw_source_plane_aggregate.cpp # typed/legacy mapped control 最终聚合
    utils/stack_sampler.cpp    # 渲染线程 native 栈采样器（定位 GL 翻译层空转）
)

# Vulkan loader dispatch and surface lifetime have a real DSO boundary. This
# target must not link GLFW, EGL, GLES or MobileGlues. GLFW exports only forward
# through the C ABI; LWJGL/SDL resolve the same vkGetInstanceProcAddr wrapper.
add_library(amcl_vulkan_wsi SHARED platform/vulkan_wsi.cpp)
add_library(amcl_window_host SHARED platform/window_host.cpp platform/window_host_core.cpp)
target_include_directories(amcl_window_host PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_features(amcl_window_host PRIVATE cxx_std_17)
target_compile_options(amcl_window_host PRIVATE -fvisibility=hidden)
target_link_options(amcl_window_host PRIVATE -Wl,--no-undefined -Wl,-Bsymbolic-functions)
target_link_libraries(amcl_window_host PRIVATE libhilog_ndk.z.so libnative_window.so)
set_target_properties(amcl_window_host PROPERTIES
    BUILD_WITH_INSTALL_RPATH TRUE INSTALL_RPATH "$ORIGIN" INSTALL_RPATH_USE_LINK_PATH FALSE)
target_include_directories(amcl_vulkan_wsi PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_features(amcl_vulkan_wsi PRIVATE cxx_std_17)
target_compile_options(amcl_vulkan_wsi PRIVATE -fvisibility=hidden)
target_link_options(amcl_vulkan_wsi PRIVATE -Wl,--no-undefined -Wl,-Bsymbolic-functions)
target_link_libraries(amcl_vulkan_wsi PRIVATE libhilog_ndk.z.so)
# 中立图形运行时不依赖任何窗口前端/翻译器DSO。所有实际GL/EGL实现仍由冻结计划按需装载，
# 会话协调与只读观测可以被entry、GLFW、SDL消费，不能反向引用这些消费者的符号。
add_library(amcl_graphics_runtime SHARED
    platform/graphics_runtime_binding.cpp platform/graphics_observation.cpp platform/graphics_backend_session.cpp
    platform/graphics_egl_context.cpp platform/graphics_features.cpp platform/graphics_gl_lookup.cpp)
target_include_directories(amcl_graphics_runtime PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_features(amcl_graphics_runtime PRIVATE cxx_std_20)
target_compile_options(amcl_graphics_runtime PRIVATE -fvisibility=hidden -funwind-tables)
target_link_options(amcl_graphics_runtime PRIVATE -Wl,--no-undefined -Wl,-Bsymbolic-functions)
target_link_libraries(amcl_graphics_runtime PRIVATE amcl_window_host dl)
target_link_libraries(glfw PRIVATE amcl_vulkan_wsi amcl_window_host amcl_graphics_runtime)
add_custom_target(amcl_graphics_boundary_compile_gate DEPENDS glfw amcl_vulkan_wsi amcl_window_host amcl_graphics_runtime)
if(TARGET amcl_gl_host)
    add_dependencies(amcl_graphics_boundary_compile_gate amcl_gl_host)
    # 完整包仍构建/携带 MG，依赖只作用于构建顺序，不形成进程装载依赖。
    add_dependencies(glfw amcl_gl_host)
endif()

if(AMCL_NATIVE_DESKTOP_ONLY)
    target_sources(glfw PRIVATE glfw/desktop_egl.cpp)
else()
    target_sources(glfw PRIVATE glfw/glfw_egl.cpp glfw/mg_benchmark_cache.cpp)
endif()
set_target_properties(glfw PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
)

# AMCL 自己的 host 代码只需要本目录。MG 的 vendored 头文件不在这里 —— 那些是
# mg_translation 的 PRIVATE include，故 glfw_internal.h 的 <EGL/egl.h> 与
# <GLES3/gl3.h> 现在同为 SDK 提供，来源一致。
target_include_directories(glfw BEFORE PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
if(NOT AMCL_NATIVE_DESKTOP_ONLY)
    target_include_directories(glfw BEFORE PRIVATE ${MG_SRC_DIR}/include/MG ${MG_SRC_DIR}/config)
endif()

# 编译选项只作用于 AMCL host；MG core 自己拥有 hidden/LTO/O2 contract。
target_compile_options(glfw PRIVATE
    -funwind-tables -fPIC
    $<$<COMPILE_LANGUAGE:CXX>:-D_THREAD_SAFE>
    $<$<COMPILE_LANGUAGE:C>:-std=gnu99>
)

# GLFW 的 version script 只公开窗口/输入 facade 与显式宿主接口；GL/EGL/GLX
# 实现由独立 GL host 持有。EGL 调用经 egl_dispatch 按已锁存 profile 选定函数表，
# 不能依靠 ELF 全局符号的偶然加载顺序选择 provider。
# -Bsymbolic-functions 保持本 DSO 内部调用绑定自己的实现；GL host 同样使用该选项，
# 防止 MG 内部函数被系统 GLES/另一提供者插入。产物门禁检查两库导出面不重复。
set(AMCL_GLFW_VERSION_SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/glfw/glfw_mg.version")
if(AMCL_NATIVE_DESKTOP_ONLY)
    set(AMCL_GLFW_VERSION_SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/glfw/glfw_native.version")
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${AMCL_GLFW_VERSION_SCRIPT}")
if(NOT AMCL_DEVELOPER_DIAGNOSTICS)
    file(READ "${AMCL_GLFW_VERSION_SCRIPT}" AMCL_GLFW_PRODUCT_EXPORTS)
    string(REGEX REPLACE "[ \t]*mg_multidraw_bench_(progress|run);\r?\n" ""
        AMCL_GLFW_PRODUCT_EXPORTS "${AMCL_GLFW_PRODUCT_EXPORTS}")
    set(AMCL_GLFW_VERSION_SCRIPT "${CMAKE_CURRENT_BINARY_DIR}/glfw_mg_product.version")
    file(WRITE "${AMCL_GLFW_VERSION_SCRIPT}" "${AMCL_GLFW_PRODUCT_EXPORTS}")
endif()
target_link_options(glfw PRIVATE
    "-Wl,--version-script=${AMCL_GLFW_VERSION_SCRIPT}"
    "-Wl,-Bsymbolic-functions"
    "-Wl,--gc-sections"
)

# version script 不在编译器给出的依赖里，改它不会触发重链 —— 实测过一次：改完
# mg_* 导出后 ninja 报 "no work to do"，产物仍是旧的符号表，容易误判成"改动无效"。
# 显式声明它为链接依赖。
set_property(TARGET glfw APPEND PROPERTY LINK_DEPENDS
    ${CMAKE_CURRENT_SOURCE_DIR}/glfw/glfw_mg.version ${AMCL_GLFW_VERSION_SCRIPT})

# 栈采样器开关（默认 OFF）：关闭时 amcl_sampler_start 为空操作，不装信号处理器、不起线程
if(AMCL_STACK_SAMPLER)
    target_compile_definitions(glfw PRIVATE AMCL_STACK_SAMPLER)
endif()

# Linking the OBJECT target adds all MG objects and its shader/LTO/link usage
# requirements to the final DSO without a second libmobileglues.so.
if(NOT AMCL_NATIVE_DESKTOP_ONLY)
    add_dependencies(glfw amcl_mg_source_identity)
    # The benchmark facade still parses its own cache JSON. Keep its private
    # C helper in the facade DSO; this is not a second MobileGlues core copy.
    target_sources(glfw PRIVATE $<TARGET_OBJECTS:amcl_mg_config_json>)
endif()
target_include_directories(glfw PRIVATE "${AMCL_MG_GENERATED_DIR}")
target_compile_definitions(glfw PRIVATE
    AMCL_DESKTOP_EVENT_BRIDGE=1
    AMCL_MG_SEMANTIC_VERSION="${AMCL_MG_SEMANTIC_VERSION}"
    AMCL_HOST_BUILD_IDENTITY="${AMCL_HOST_BUILD_IDENTITY}"
    AMCL_GLFW_TYPED_PHYSICAL_DEFAULT=$<BOOL:${AMCL_GLFW_TYPED_PHYSICAL_DEFAULT}>
    # 三个 Gate 0 证据宏必须用 Gate0Evidence.cmake 归一化后的 0/1，不能再写
    # $<BOOL:${option}>：那是与门禁判定不同的一套真值规则，`-DXXX=00` 之类的取值会
    # 让门禁跳过校验却仍把宏定义成 1（详见 Gate0Evidence.cmake 里的说明）。
    AMCL_GLFW_RAW_RELATIVE_VERIFIED=${AMCL_GATE0_DEF_AMCL_GLFW_RAW_RELATIVE_VERIFIED}
    AMCL_GLFW_API26_RAW_MOUSE_MOTION=$<BOOL:${AMCL_GLFW_API26_RAW_MOUSE_MOTION}>
    AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED=${AMCL_GATE0_DEF_AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED}
    AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED=${AMCL_GATE0_DEF_AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED}
    # 哪份 Gate 0 证据授权了上面这些能力位。默认构建为 "none"，可直接从产物反查，
    # 不需要再去猜某个 =1 是谁批准的。空字符串会与"忘记注入"混淆，故用显式 none。
    # ⚠️ "可从产物反查"依赖 glfw_compat.cpp 的 glfwInit 里那行 AMCL_GATE0 日志 ——
    # 它是唯一的运行期读者，没有它这个字符串不会进 .rodata（详见 Gate0Evidence.cmake）。
    AMCL_GATE0_EVIDENCE_IDS="${AMCL_GATE0_EVIDENCE_IDS_STRING}"
)

# OHOS 系统库
target_link_libraries(glfw PRIVATE libdeviceinfo_ndk.z.so)

target_link_libraries(glfw PUBLIC
    libhilog_ndk.z.so
    libnative_window.so)
if(AMCL_NATIVE_DESKTOP_ONLY)
    target_link_libraries(glfw PUBLIC libEGL.so)
endif()

# HarmonyOS 专属调度库仅进入宿主 GLFW target。
if(CMAKE_SYSTEM_NAME STREQUAL "OHOS")
    target_link_libraries(glfw PRIVATE libqos.so)
endif()

# JVM 嵌入模块 + MC 启动器
set(JVM_SOURCES
    jvm/jna_runtime_contract.cpp # 只读实际 JNA 协议，选择独立 native ABI，不替换 Java 库
    jvm/jvm_launcher.cpp
    jvm/game_process_exit.cpp # 独立游戏进程的 JNI 退出记录与进程结束；不改变同进程/processor。
    jvm/mc_launcher.cpp
    jvm/jni_registry.cpp
    jvm/elf_loader.cpp
    jvm/fork_run_java.cpp
    jvm/jvm_common_args.cpp    # SSOT: 主/子 JVM 共享参数清单
    # /proc/net/if_inet6 垫片：沙箱拒读该文件会让 JDK 判 IPv6 不可用（真机 EACCES 实测），
    # 由 elf_loader 的 fopen 插桩接管。方案 docs/adaptation/JDK_IPV6_ADAPTATION_PLAN.md §四·五 R1
    jvm/if_inet6_shim.cpp
    utils/amcl_log.cpp
)

# ============================================================
# 下载引擎 (P1-3)
#   Stage 1a: probe.cpp — libcurl 加载验证 API
#   Stage 1b: 完整 C++ 引擎（多源 + 多线程分段 + 断点续传 + sha1 校验）
#             见 docs/guides/download-system-redesign-v3.md
# ============================================================
set(DOWNLOAD_SOURCES
    download/probe.cpp
    # Stage 1b 核心引擎
    download/net_state.cpp
    download/exception.cpp
    download/net_source.cpp
    download/sha1.cpp                    # 独立 SHA-1 实现（不依赖 OpenSSL 头）
    download/hmac_sha256.cpp             # 独立 SHA-256 / HMAC-SHA256（加速网关请求签名）
    download/relay.cpp                   # 加速网关客户端（URL 改写 + 持有证明 + 熔断）
    download/file_checker.cpp
    download/download_meta.cpp
    download/net_thread.cpp
    download/net_file.cpp
    download/loader_download.cpp
    download/engine.cpp
    download/multi_downloader.cpp        # v4.5: curl_multi HTTP/2 多路复用下载器
    download/config.cpp                  # 全局 CA bundle path（由 ArkTS 抽 rawfile 后设置）
    # Stage 2 NAPI 桥接
    download/napi_bridge.cpp             # Progress/Complete 线程安全回调
    download/download_napi.cpp           # createTask/start/cancel/onProgress/... NAPI 方法
)

# libcurl.so：Docker 交叉编译产出的 prebuilt shared library
# 详见 docker/build_curl_ohos.sh 和 docs/guides/download-system-redesign-v3.md
# 物理位置：entry/libs/arm64-v8a/libcurl.so
# 相对 CMAKE_CURRENT_SOURCE_DIR (entry/src/main/cpp) 的路径是 ../../../libs/arm64-v8a/libcurl.so
add_library(curl_imported SHARED IMPORTED)
set_target_properties(curl_imported PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/arm64-v8a/libcurl.so
    INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_CURRENT_SOURCE_DIR}/third_party/curl/include
)

# 验证测试模块（可选）
set(TEST_SOURCES "")
if(MC_OHOS_BUILD_TESTS)
    set(TEST_SOURCES
        tests/jit_test.cpp
        tests/jvm_test.cpp
        tests/glfw_test.cpp
        tests/gl4_test.cpp
        tests/mg_test.cpp
        tests/lwjgl_test.cpp
        # 2026-05-10: amcl_log 多生产者并发 stress test（验证 LOG-P0-1 reservation+ready flag 修复）
        tests/amcl_log_concurrent_test.cpp
        tests/input_ledger_test.cpp
        # SDL3 移植 C2 关卡真机探针（docs/adaptation/SDL3_MIGRATION_PLAN.md §四 C2）
        # 必须在应用进程内跑：HarmonyOS 的 linker namespace 按应用配置，
        # 且 hdc shell 域被 SELinux 禁止执行推送的 ELF（实测 exit 126）
        tests/sdl3_c2_test.cpp
        tests/sdl3_window_test.cpp
        # MobileGL DirectVulkan 出帧探针（MOBILEGL_ADAPTATION_PLAN.md §5.2 Phase 2a 收口判据；
        # libmobilegl.so 经 build-mobilegl.ps1 -DeployToLibs 部署后从 RenderPage 触发）
        tests/mobilegl_probe_test.cpp
        # JDK IPv6 能力探针（JDK_IPV6_ADAPTATION_PLAN.md §3 P0-a）：在应用进程内逐条复现
        # libnet 的 IPv6_supported() 四条判据（17 四条 / 21·25 三条）。
        # 同样必须在应用进程里跑：hdc shell 域与应用域是两套 SELinux 上下文。
        tests/ipv6_probe_test.cpp
        # Java 侧 IPv6 诊断驱动（同上 §3 P0-b）：fork 子进程建 JVM 跑
        # com.amcl.launcher.Ipv6Diagnostics，抓「连 IPv6 字面量时的第一条异常」。
        tests/ipv6_java_probe_test.cpp
        # 下载子系统测试（Phase 3 / 4 / 7 / 8 — TDD 计划见 docs/guides/download-system-implementation-plan.md）
        download/tests/sha1_incremental_test.cpp     # Phase 4: 增量 SHA1（Sha1 类已有 update/finalizeHex）
        download/tests/text_fetch_test.cpp           # Phase 3: engine.fetchToBuffer
        download/tests/source_scoring_test.cpp       # Phase 8: NetSource 评分 + pickBestSourceWeighted
        download/tests/error_and_source_lifecycle_test.cpp  # Phase 7: exception + NetSource recordFailure/recordSuccess
    )
endif()

# ============================================================
# 主模块（libentry.so）
# GL 翻译只在独立 GL host；entry 与 GLFW 通过物理 DSO 依赖共享该实现。
# ============================================================
add_library(entry SHARED
    ${NAPI_SOURCES}
    ${PLATFORM_SOURCES}
    ${JVM_SOURCES}
    ${DOWNLOAD_SOURCES}
    ${TEST_SOURCES}
)
# The JVM loads GLFW from a different linker namespace. HAP sibling DSOs must
# resolve relative to their installed image, never the Windows CMake output
# directory (which is otherwise embedded as an automatic build RUNPATH).
set_target_properties(entry glfw amcl_vulkan_wsi amcl_window_host amcl_graphics_runtime PROPERTIES
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH "$ORIGIN"
    INSTALL_RPATH_USE_LINK_PATH FALSE)
if(NOT AMCL_NATIVE_DESKTOP_ONLY)
    target_sources(entry PRIVATE $<TARGET_OBJECTS:amcl_mg_config_json>)
    target_include_directories(entry PRIVATE ${MG_SRC_DIR}/config)
endif()

# 下载引擎（download/ 模块）使用 std::optional / std::string_view / structured
# bindings 等 C++17 特性，给 entry 声明 CXX_STANDARD 17。
set_target_properties(entry PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
)

target_include_directories(entry PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

if(AMCL_INPUT_SHADOW)
    target_compile_definitions(entry PRIVATE AMCL_INPUT_SHADOW=1)
else()
    target_compile_definitions(entry PRIVATE AMCL_INPUT_SHADOW=0)
endif()

target_compile_definitions(entry PRIVATE
    # 与上面决定是否编译 gate0_input_telemetry.cpp 的判定必须是同一次求值，
    # 否则 `#if` 块会在 TU 缺席时打开并引用未定义符号。
    AMCL_INPUT_GATE0_TELEMETRY=${AMCL_GATE0_DEF_AMCL_INPUT_GATE0_TELEMETRY}
    AMCL_INPUT_COMPILED_FORMAL_DESKTOP=$<BOOL:${AMCL_INPUT_COMPILED_FORMAL_DESKTOP}>
)

target_compile_definitions(entry PRIVATE
    AMCL_GLFW_API26_RAW_MOUSE_MOTION=$<BOOL:${AMCL_GLFW_API26_RAW_MOUSE_MOTION}>)
if(AMCL_API26_LINK_PROBE)
    target_link_libraries(entry PRIVATE libohgame_controller.z.so)
endif()

if(MC_OHOS_BUILD_TESTS)
    target_compile_definitions(entry PRIVATE MC_OHOS_BUILD_TESTS)
endif()

# 栈采样器开关传递给 libentry（jvm_common_args.cpp 据此决定是否补 PreserveFramePointer）
if(AMCL_STACK_SAMPLER)
    target_compile_definitions(entry PRIVATE AMCL_STACK_SAMPLER)
endif()

target_compile_definitions(entry PRIVATE AMCL_NATIVE_DESKTOP_ONLY=$<BOOL:${AMCL_NATIVE_DESKTOP_ONLY}> AMCL_DESKTOP_NATIVE_GL_VALIDATE=$<BOOL:${AMCL_DESKTOP_NATIVE_GL_VALIDATE}>)
target_compile_definitions(glfw PRIVATE AMCL_NATIVE_DESKTOP_ONLY=$<BOOL:${AMCL_NATIVE_DESKTOP_ONLY}> AMCL_DESKTOP_NATIVE_GL_VALIDATE=$<BOOL:${AMCL_DESKTOP_NATIVE_GL_VALIDATE}>)
target_link_libraries(entry PRIVATE libpasteboard.so libudmf.so libdeviceinfo_ndk.z.so amcl_vulkan_wsi amcl_window_host amcl_graphics_runtime)
target_link_libraries(entry PRIVATE libz.so) # 有界 JNA ZIP 条目使用系统 raw-deflate/CRC 实现
target_sources(entry PRIVATE platform/runtime_slot_store.cpp)
# libentry 的GPU观察直连中立运行时，不经GLFW前端创建另一份MG默认图形域。

target_link_libraries(entry PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libace_ndk.z.so
    libnative_window.so
    libohhidebug.so  # 设备物理内存查询（OH_HiDebug_GetSystemMemInfo）
    glfw
    curl_imported    # P1-3 Stage 1a: libcurl (static-linked OpenSSL)
)
if(AMCL_NATIVE_DESKTOP_ONLY)
    target_link_libraries(entry PUBLIC libEGL.so)
endif()

# XComponent 帧率 hint 使用真实显示刷新率；不向其他 target 传播此 OHOS 依赖。
if(CMAKE_SYSTEM_NAME STREQUAL "OHOS")
    target_link_libraries(entry PRIVATE libnative_display_manager.so)
endif()

# ============================================================
# JNI 重新注册库（libjni_reregister.so）
# 解决 Fabric/Forge 等模组加载器的 ClassLoader 兼容性问题
# CallbackBridge 实际消费者的 static 块首次加载本库，JNI_OnLoad 对该 Class 绑定；
# 宿主只发布带 PID/session/ABI 的函数表，不提前 FindClass，不替换 LWJGL core 的 JNI 规则。
# JNI_OnLoad 找到实际 caller 的 CallbackBridge，再调用描述符中的显式 Class 绑定接口。
# ============================================================
add_library(jni_reregister SHARED
    glfw/jni_reregister.c
)
target_include_directories(jni_reregister PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_link_libraries(jni_reregister PUBLIC
    dl
    libhilog_ndk.z.so
)

amcl_apply_diagnostic_policy(entry)
amcl_apply_diagnostic_policy(glfw)
if(TARGET amcl_gl_host)
    amcl_apply_diagnostic_policy(amcl_gl_host)
endif()
amcl_apply_diagnostic_policy(amcl_vulkan_wsi)
amcl_apply_diagnostic_policy(amcl_graphics_runtime)
target_link_options(glfw PRIVATE "-Wl,--undefined=amclDiagnosticBuildIdentity")
if(NOT AMCL_NATIVE_DESKTOP_ONLY)
target_include_directories(mobileglues_core PRIVATE "${CMAKE_CURRENT_BINARY_DIR}" "${MG_SRC_DIR}")
target_compile_options(mobileglues_core PRIVATE
    "-include" "${CMAKE_CURRENT_SOURCE_DIR}/utils/product_mg_logging.h")


endif() # MobileGlues product logging
