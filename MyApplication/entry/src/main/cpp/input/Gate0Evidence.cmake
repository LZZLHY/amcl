# ============================================================
# Gate0Evidence.cmake — Gate 0 证据清单的 configure 期失败关闭门禁
# ============================================================
#
# 为什么存在：AMCL_GLFW_*_VERIFIED 三个选项断言的是**真机事实**，不是编译开关。
# 它们默认 OFF、运行时不可绕过，但在本文件出现之前，任何人（或一份旧的 CMake
# cache、一条误加的 externalNativeOptions.arguments）只要写 -D...=ON 就能让产物
# 宣称一个从未验证过的平台能力。这类错误不会崩溃，只会在真机上表现为"视角双转"
# 或"点到旧坐标"，且没有任何构建期信号。
#
# 因此这里把"允许打开"绑定到 gate0-evidence.lock 里一条可追溯的书面批准上：
#   - 选项 OFF：不读清单、不做校验（默认路径零成本）。
#   - 选项 ON ：必须能读到清单、条目 approved=true、证据文档存在且 sha256 匹配、
#               设备矩阵非空、批准人/日期/独立复核人齐备、依赖能力同时打开。
#               任何一条不满足即 FATAL_ERROR，构建停在 configure 期。
#
# 失败关闭的边界（重要）：CMake 低于 3.19 时没有 string(JSON)，本模块**无法**校验
# 清单。此时不是"跳过校验放行"，而是拒绝打开该选项 —— 不能验证就不能启用，否则门禁
# 在旧工具链上等于不存在。
#
# 本模块只读文件、只设变量，不生成任何目标，也不改变默认构建行为。
#
# 前置：调用方必须已定义 AMCL_REPO_ROOT。

set(AMCL_GATE0_EVIDENCE_LOCK "${AMCL_REPO_ROOT}/gate0-evidence.lock")

# 所有受管能力。新增证据位时必须同时加到这里和 gate0-evidence.lock，否则新选项会
# 绕过门禁。scripts/check-gate0-evidence.mjs 会交叉核对这两处的键集合是否一致。
set(AMCL_GATE0_MANAGED_CAPABILITIES
    AMCL_GLFW_RAW_RELATIVE_VERIFIED
    AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED
    AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED
)

# 汇总所有被批准并实际启用的 evidenceId，编进 libglfw。产物因此能自证"是哪份证据
# 授权了这个能力"，而不是只留下一个匿名的 =1。
#
# ⚠️ 这条"能自证"成立的前提是**有人在运行期读它** —— 只被编译期 constexpr 读的字符串
# 字面量不会进产物（2026-08-24 实测：在 glfwInit 打出它之前，llvm-strings 在 libglfw.so
# 里找不到这个字符串，也就是说本注释那两年一直是假的）。唯一的运行期读者是
# glfw_compat.cpp 的 glfwInit 那行 AMCL_GATE0 日志；删掉它，本段就重新变成假话。
set(AMCL_GATE0_EVIDENCE_IDS "")

# ------------------------------------------------------------
# 真值归一：门禁判定与宏发布必须是**同一次求值**
# ------------------------------------------------------------
# 这一步不是洁癖。CMake 的 `if(<value>)` 会先查名字常量、再用 strtod 按数值判零，而
# 生成器表达式 `$<BOOL:value>` 用的是另一套规则（只把 0/N/NO/OFF/FALSE/IGNORE/
# NOTFOUND/空/*-NOTFOUND 当假）。两者不等价：`-DXXX=00`、`=0.0`、`=-0` 会让
# `if()` 判假（门禁认为"没开"，直接跳过校验）而 `$<BOOL:>` 判真（宏被定义成 1）。
# 那样产物会同时携带"能力已启用"和"没有任何证据授权"，恰好是本门禁要防的事，而且
# 因为自证字段写着 none，事后反查也查不出来。
#
# 因此这里按 $<BOOL:> 的语义（更宽，只有明确的假值才算关）算出唯一的 0/1 结果，
# 判定和发布都只消费它。归一化取宽而不取窄：宁可多要求一次证据，也不能少要求一次。
function(amcl_gate0_normalize_enabled capability outputVariable)
    set(value "${${capability}}")
    string(TOUPPER "${value}" upper)
    set(enabled 1)
    if(value STREQUAL "")
        set(enabled 0)
    elseif(upper STREQUAL "0" OR upper STREQUAL "N" OR upper STREQUAL "NO" OR
           upper STREQUAL "OFF" OR upper STREQUAL "FALSE" OR
           upper STREQUAL "IGNORE" OR upper STREQUAL "NOTFOUND")
        set(enabled 0)
    elseif(upper MATCHES "-NOTFOUND$")
        set(enabled 0)
    endif()
    set(${outputVariable} ${enabled} PARENT_SCOPE)
endfunction()

# 只有存在已启用的受管选项时才读清单：清单缺失本身只在需要授权时才是错误。
set(AMCL_GATE0_ANY_ENABLED FALSE)
foreach(amcl_gate0_capability IN LISTS AMCL_GATE0_MANAGED_CAPABILITIES)
    amcl_gate0_normalize_enabled(${amcl_gate0_capability}
                                 AMCL_GATE0_DEF_${amcl_gate0_capability})
    if(AMCL_GATE0_DEF_${amcl_gate0_capability})
        set(AMCL_GATE0_ANY_ENABLED TRUE)
    endif()
endforeach()

if(AMCL_GATE0_ANY_ENABLED)
    if(CMAKE_VERSION VERSION_LESS "3.19")
        message(FATAL_ERROR
            "Gate 0 evidence gate requires CMake >= 3.19 to parse "
            "gate0-evidence.lock (found ${CMAKE_VERSION}). Refusing to enable a "
            "verified-capability option that cannot be validated. Either upgrade "
            "CMake or keep every AMCL_GLFW_*_VERIFIED option OFF.")
    endif()
    if(NOT EXISTS "${AMCL_GATE0_EVIDENCE_LOCK}")
        message(FATAL_ERROR
            "Gate 0 evidence manifest not found: ${AMCL_GATE0_EVIDENCE_LOCK}. A "
            "verified-capability option is ON, so an approved manifest entry is "
            "mandatory.")
    endif()

    file(READ "${AMCL_GATE0_EVIDENCE_LOCK}" AMCL_GATE0_MANIFEST)

    string(JSON amcl_gate0_schema ERROR_VARIABLE amcl_gate0_schema_error
           GET "${AMCL_GATE0_MANIFEST}" schemaVersion)
    if(amcl_gate0_schema_error OR NOT amcl_gate0_schema STREQUAL "1")
        message(FATAL_ERROR
            "Gate 0 evidence manifest schemaVersion must be 1; got "
            "'${amcl_gate0_schema}' (${amcl_gate0_schema_error}). Refusing to "
            "interpret an unknown schema as approval.")
    endif()
endif()

# 逐能力校验。函数化是为了让每个能力的失败信息都能指名道姓，而不是一条笼统错误。
# 成功时通过 gate0_approved_id 把 evidenceId 回传给调用方。
function(amcl_gate0_require_approval capability)
    string(JSON entry ERROR_VARIABLE entryError
           GET "${AMCL_GATE0_MANIFEST}" capabilities "${capability}")
    if(entryError)
        message(FATAL_ERROR
            "${capability}=ON but gate0-evidence.lock has no capabilities entry "
            "for it (${entryError}).")
    endif()

    # 必须是 JSON 布尔 true，不接受字符串 "ON"/"true" 或数字 1。
    # 理由：string(JSON GET) 会把 JSON true **和** 字符串 "ON" 都返回成 ON，仅比较
    # 取值就无法区分"真的批准了"与"清单里写了个像布尔的字符串"。Node 侧门禁要求严格
    # boolean，两侧必须同口径，否则单侧放行就是一条绕过路径。
    string(JSON approvedType ERROR_VARIABLE approvedTypeError
           TYPE "${entry}" approved)
    if(approvedTypeError OR NOT approvedType STREQUAL "BOOLEAN")
        message(FATAL_ERROR
            "${capability} is enabled but gate0-evidence.lock 'approved' must be a "
            "JSON boolean (got type '${approvedType}'). A string or number is not "
            "an approval.")
    endif()
    string(JSON approved ERROR_VARIABLE approvedError GET "${entry}" approved)
    if(approvedError OR NOT approved STREQUAL "ON")
        message(FATAL_ERROR
            "${capability} is enabled but gate0-evidence.lock marks it "
            "approved=false. Record identity-bound target-device evidence and "
            "obtain independent review before enabling this capability.")
    endif()

    foreach(field evidenceId evidenceDocument evidenceSha256 sdkVersion
                  approvedBy approvedOn independentReviewer)
        string(JSON value ERROR_VARIABLE valueError GET "${entry}" ${field})
        if(valueError OR value STREQUAL "")
            message(FATAL_ERROR
                "${capability}=ON but gate0-evidence.lock field '${field}' is "
                "missing or empty. An approval without a traceable owner is not "
                "an approval.")
        endif()
        set(field_${field} "${value}")
    endforeach()

    # evidenceId 是写进产物的追溯键，必须是真实标识而不是占位符。
    # CMake 正则不支持 {n,} 量词，长度用 string(LENGTH) 判。
    string(LENGTH "${field_evidenceId}" idLength)
    if(idLength LESS 8 OR NOT field_evidenceId MATCHES "^[A-Za-z0-9._-]+$")
        message(FATAL_ERROR
            "${capability}=ON but evidenceId '${field_evidenceId}' is not a usable "
            "identifier (expected >= 8 chars of [A-Za-z0-9._-]).")
    endif()
    string(TOUPPER "${field_evidenceId}" idUpper)
    foreach(forbidden TODO PLACEHOLDER XXX FIXME SAMPLE EXAMPLE CHANGEME)
        if(idUpper MATCHES "${forbidden}")
            message(FATAL_ERROR
                "${capability}=ON but evidenceId '${field_evidenceId}' looks like a "
                "placeholder (contains ${forbidden}).")
        endif()
    endforeach()

    if(NOT field_approvedOn MATCHES "^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$")
        message(FATAL_ERROR
            "${capability}=ON but approvedOn '${field_approvedOn}' is not "
            "YYYY-MM-DD.")
    endif()

    # 证据文档必须真实存在，且内容哈希与批准时一致。否则"先批准空文档、之后再改内容"
    # 就能绕过整条门禁。
    set(document "${AMCL_REPO_ROOT}/${field_evidenceDocument}")
    if(NOT EXISTS "${document}")
        message(FATAL_ERROR
            "${capability}=ON but evidenceDocument does not exist: ${document}")
    endif()
    file(SHA256 "${document}" documentSha)
    string(TOLOWER "${field_evidenceSha256}" expectedSha)
    if(NOT documentSha STREQUAL expectedSha)
        message(FATAL_ERROR
            "${capability}=ON but evidenceDocument sha256 mismatch.\n"
            "  document: ${document}\n"
            "  recorded: ${expectedSha}\n"
            "  actual  : ${documentSha}\n"
            "Re-approve the evidence after changing the document.")
    endif()

    # 设备矩阵非空：没有设备标识就无法追溯这份证据来自哪台机器。
    string(JSON matrixLength ERROR_VARIABLE matrixError
           LENGTH "${entry}" deviceMatrix)
    if(matrixError OR matrixLength EQUAL 0)
        message(FATAL_ERROR
            "${capability}=ON but deviceMatrix is empty. Record the exact target "
            "devices the evidence was captured on.")
    endif()

    # 依赖能力必须同时打开。native absolute 的 C++ 侧本来就是 AND，只开一半会得到一个
    # "看起来开了其实没开"的配置；这里把它变成显式失败而不是静默无效。
    #
    # ⚠️ 2026-08-20 修：`requires` 曾是本函数里**唯一"读不到就跳过"**的字段
    # （旧写法 `if(NOT requiresError AND requiresLength GREATER 0)`），而其余每一项
    # —— schemaVersion、approved 的类型、七个必填字段、deviceMatrix —— 都是
    # `if(<x>Error OR ...)` → FATAL_ERROR。于是 `requires` 键缺失或写成非数组时，
    # 整个依赖检查被**静默跳过**。
    #
    # 为什么这不只是风格不一致：计划文档 §3.3-C 的三层强度表把"依赖能力只开一半"记为
    # **configure 层**的保证，而在旧写法下那条保证实际依赖 **source gate 那一层**
    # （`check-gate0-evidence.mjs` 强制 `Array.isArray(entry.requires)`）。
    # 一层声称的保证依赖另一层，正是那张表要避免的事 —— 它的全部价值在于
    # "每一层各自挡住什么"可以被单独信任。
    #
    # 现在：读不到 `requires`（键缺失 / 非数组 / JSON 结构错）一律 FATAL_ERROR。
    # `requires: []`（显式无依赖）仍然合法 —— 空数组的 LENGTH 是 0 且不产生 error。
    string(JSON requiresLength ERROR_VARIABLE requiresError
           LENGTH "${entry}" requires)
    if(requiresError)
        message(FATAL_ERROR
            "${capability}=ON but gate0-evidence.lock 'requires' is missing or is "
            "not an array (${requiresError}). Write 'requires': [] to declare "
            "explicitly that this capability has no dependency; an unreadable "
            "field must not silently disable the dependency check.")
    endif()
    if(requiresLength GREATER 0)
        math(EXPR lastRequire "${requiresLength} - 1")
        foreach(index RANGE ${lastRequire})
            string(JSON required GET "${entry}" requires ${index})
            # 用归一化结果判断，与本模块其余判定保持同一次求值语义（见文件上方
            # amcl_gate0_normalize_enabled 的理由）。直接 if(NOT ${required}) 会
            # 重新引入 `if()` 与 `$<BOOL:>` 的真值分歧。
            if(NOT AMCL_GATE0_DEF_${required})
                message(FATAL_ERROR
                    "${capability} is enabled and requires ${required}=ON as well; "
                    "enabling only one half publishes no capability and hides the "
                    "misconfiguration.")
            endif()
        endforeach()
    endif()

    set(gate0_approved_id "${field_evidenceId}" PARENT_SCOPE)
endfunction()

foreach(amcl_gate0_capability IN LISTS AMCL_GATE0_MANAGED_CAPABILITIES)
    if(AMCL_GATE0_DEF_${amcl_gate0_capability})
        amcl_gate0_require_approval(${amcl_gate0_capability})
        list(APPEND AMCL_GATE0_EVIDENCE_IDS
             "${amcl_gate0_capability}=${gate0_approved_id}")
        message(STATUS
            "AMCL Gate 0 capability ${amcl_gate0_capability} authorized by "
            "evidence ${gate0_approved_id}")
    endif()
endforeach()

if(AMCL_GATE0_EVIDENCE_IDS)
    string(REPLACE ";" "," AMCL_GATE0_EVIDENCE_IDS_STRING
           "${AMCL_GATE0_EVIDENCE_IDS}")
else()
    # 默认路径：产物显式记录"没有任何 Gate 0 能力被授权"，而不是留一个空定义让人
    # 无法区分"未授权"与"忘记注入"。
    set(AMCL_GATE0_EVIDENCE_IDS_STRING "none")
endif()
message(STATUS "AMCL Gate 0 evidence: ${AMCL_GATE0_EVIDENCE_IDS_STRING}")
