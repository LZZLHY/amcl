# 解析本轮完整 HDC 静态库的绝对路径，并校验 Hvigor 显式传入的路径摘要。
# 完整路径经环境传递以支持空格；摘要作为 SDK 可见的 CMake 参数负责缓存失效。
# 独立 Native 调用保留 -DAMCL_HDC_CORE_ARCHIVE=<路径> 的原契约，可不提供摘要。
function(amcl_resolve_hdc_archive)
    if(DEFINED ENV{AMCL_HDC_CORE_ARCHIVE})
        set(AMCL_HDC_CORE_ARCHIVE "$ENV{AMCL_HDC_CORE_ARCHIVE}")
    endif()
    if(DEFINED AMCL_HDC_CORE_ARCHIVE_PATH_SHA256)
        string(SHA256 actual_path_sha256 "${AMCL_HDC_CORE_ARCHIVE}")
        if(NOT "${actual_path_sha256}" STREQUAL "${AMCL_HDC_CORE_ARCHIVE_PATH_SHA256}")
            message(FATAL_ERROR "HDC archive path identity mismatch; regenerate with the current Hvigor environment")
        endif()
    endif()
    if(NOT IS_ABSOLUTE "${AMCL_HDC_CORE_ARCHIVE}" OR
       NOT EXISTS "${AMCL_HDC_CORE_ARCHIVE}" OR IS_DIRECTORY "${AMCL_HDC_CORE_ARCHIVE}")
        message(FATAL_ERROR "Complete HDC archive missing or not an absolute file; use build-hdc-core.mjs")
    endif()
    # 只向调用层返回已核实的路径；不写全局环境、不改 SDK 或用户的构建目录。
    set(AMCL_HDC_CORE_ARCHIVE "${AMCL_HDC_CORE_ARCHIVE}" PARENT_SCOPE)
endfunction()
