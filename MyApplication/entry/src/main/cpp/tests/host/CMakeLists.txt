cmake_minimum_required(VERSION 3.16)
project(amcl_input_host_tests LANGUAGES C CXX)

enable_testing()

# 与生产 loader 共用的输入校验核心。此测试不装载/执行 ELF，不替代 AArch64 JVM 验收。
add_executable(amcl_elf_input_validation_test elf_input_validation_test.cpp)
target_compile_features(amcl_elf_input_validation_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_elf_input_validation_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_elf_input_validation_test PRIVATE -Wall -Wextra -Werror -pedantic)
endif()
add_test(NAME amcl_elf_input_validation_test COMMAND amcl_elf_input_validation_test)
set_tests_properties(amcl_elf_input_validation_test PROPERTIES LABELS "runtime;elf;input-validation")

add_executable(amcl_native_window_lease_ledger_test amcl_native_window_lease_ledger_test.cpp)
target_compile_features(amcl_native_window_lease_ledger_test PRIVATE cxx_std_17)
add_test(NAME amcl_native_window_lease_ledger_test COMMAND amcl_native_window_lease_ledger_test)
set_tests_properties(amcl_native_window_lease_ledger_test PROPERTIES LABELS "graphics;window")

add_executable(amcl_graphics_plan_test graphics_plan_host_test.cpp ../../platform/graphics_plan.cpp)
target_compile_features(amcl_graphics_plan_test PRIVATE cxx_std_17)
add_test(NAME amcl_graphics_plan_test COMMAND amcl_graphics_plan_test)
set_tests_properties(amcl_graphics_plan_test PROPERTIES LABELS "graphics;plan")

add_executable(amcl_vulkan_requirement_policy_test
    vulkan_requirement_policy_test.cpp ../../platform/vulkan_requirement_policy.cpp)
target_compile_features(amcl_vulkan_requirement_policy_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_vulkan_requirement_policy_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_vulkan_requirement_policy_test PRIVATE -Wall -Wextra -Werror -pedantic)
endif()
add_test(NAME amcl_vulkan_requirement_policy_test COMMAND amcl_vulkan_requirement_policy_test)
set_tests_properties(amcl_vulkan_requirement_policy_test PROPERTIES LABELS "graphics;vulkan;requirements")

add_executable(amcl_vulkan_surface_policy_test vulkan_surface_policy_test.cpp)
target_include_directories(amcl_vulkan_surface_policy_test PRIVATE ../../platform)
target_compile_features(amcl_vulkan_surface_policy_test PRIVATE cxx_std_17)
add_test(NAME amcl_vulkan_surface_policy_test COMMAND amcl_vulkan_surface_policy_test)
set_tests_properties(amcl_vulkan_surface_policy_test PROPERTIES LABELS "graphics;vulkan;surface")

add_executable(amcl_graphics_backend_session_test graphics_backend_session_host_test.cpp ../../platform/graphics_backend_session.cpp)
target_compile_features(amcl_graphics_backend_session_test PRIVATE cxx_std_17)
add_test(NAME amcl_graphics_backend_session_test COMMAND amcl_graphics_backend_session_test)
set_tests_properties(amcl_graphics_backend_session_test PROPERTIES LABELS "graphics;session")

add_executable(amcl_glfw_vulkan_wsi_policy_test
    glfw_vulkan_wsi_policy_test.cpp
)
target_include_directories(amcl_glfw_vulkan_wsi_policy_test PRIVATE
    ../../glfw
)
target_compile_features(amcl_glfw_vulkan_wsi_policy_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_glfw_vulkan_wsi_policy_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_glfw_vulkan_wsi_policy_test PRIVATE -Wall -Wextra -Werror -pedantic)
endif()
add_test(NAME amcl_glfw_vulkan_wsi_policy_test COMMAND amcl_glfw_vulkan_wsi_policy_test)
set_tests_properties(amcl_glfw_vulkan_wsi_policy_test PROPERTIES LABELS "graphics;window")

add_executable(amcl_vulkan_wsi_lifetime_test
    vulkan_wsi_lifetime_test.cpp ../../platform/vulkan_wsi.cpp)
target_include_directories(amcl_vulkan_wsi_lifetime_test PRIVATE
    stubs ../../../../../../prebuilt/mobilegl/src/3rdparty/Vulkan-Headers/include)
target_compile_features(amcl_vulkan_wsi_lifetime_test PRIVATE cxx_std_17)
target_compile_definitions(amcl_vulkan_wsi_lifetime_test PRIVATE
    $<$<CXX_COMPILER_ID:MSVC>:_CRT_SECURE_NO_WARNINGS>)
if(UNIX)
    target_link_libraries(amcl_vulkan_wsi_lifetime_test PRIVATE ${CMAKE_DL_LIBS})
endif()
add_test(NAME amcl_vulkan_wsi_lifetime_test COMMAND amcl_vulkan_wsi_lifetime_test)
set_tests_properties(amcl_vulkan_wsi_lifetime_test PROPERTIES LABELS "graphics;vulkan;lifetime")

add_executable(amcl_mobilegl_capability_test
    mobilegl_capability_host_test.cpp ../../platform/mobilegl_capability.cpp)
target_compile_features(amcl_mobilegl_capability_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_mobilegl_capability_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_mobilegl_capability_test PRIVATE -Wall -Wextra -Werror)
endif()
add_test(NAME amcl_mobilegl_capability_test COMMAND amcl_mobilegl_capability_test)
set_tests_properties(amcl_mobilegl_capability_test PROPERTIES LABELS "graphics;mobilegl;capability")

if(WIN32)
    foreach(_fixture IN ITEMS a b)
        add_library(amcl_vulkan_wsi_fixture_${_fixture} SHARED ../../platform/vulkan_wsi.cpp)
        target_compile_features(amcl_vulkan_wsi_fixture_${_fixture} PRIVATE cxx_std_17)
        target_compile_definitions(amcl_vulkan_wsi_fixture_${_fixture} PRIVATE AMCL_VK_BUILD_DLL _CRT_SECURE_NO_WARNINGS)
        target_include_directories(amcl_vulkan_wsi_fixture_${_fixture} PRIVATE
            stubs ../../../../../../prebuilt/mobilegl/src/3rdparty/Vulkan-Headers/include)
    endforeach()
    add_executable(amcl_vulkan_wsi_dso_test vulkan_wsi_dso_test.cpp)
    target_compile_features(amcl_vulkan_wsi_dso_test PRIVATE cxx_std_17)
    add_test(NAME amcl_vulkan_wsi_dso_test COMMAND amcl_vulkan_wsi_dso_test
        $<TARGET_FILE:amcl_vulkan_wsi_fixture_a> $<TARGET_FILE:amcl_vulkan_wsi_fixture_b>)
set_tests_properties(amcl_vulkan_wsi_dso_test PROPERTIES LABELS "graphics;vulkan;dso")
endif()

add_executable(amcl_window_host_core_test
    window_host_core_test.cpp ../../platform/window_host_core.cpp)
target_compile_features(amcl_window_host_core_test PRIVATE cxx_std_17)
target_compile_definitions(amcl_window_host_core_test PRIVATE AMCL_WINDOW_HOST_TESTING)
add_test(NAME amcl_window_host_core_test COMMAND amcl_window_host_core_test)
set_tests_properties(amcl_window_host_core_test PROPERTIES LABELS "graphics;window;lifetime")
if(WIN32)
    foreach(_fixture IN ITEMS a b)
        add_library(amcl_window_host_fixture_${_fixture} SHARED
            ../../platform/window_host.cpp ../../platform/window_host_core.cpp)
        target_compile_features(amcl_window_host_fixture_${_fixture} PRIVATE cxx_std_17)
        target_compile_definitions(amcl_window_host_fixture_${_fixture} PRIVATE
            AMCL_WINDOW_HOST_TESTING)
        target_include_directories(amcl_window_host_fixture_${_fixture} PRIVATE
            ../../platform ../../glfw)
    endforeach()
    add_executable(amcl_window_host_dso_test window_host_dso_test.cpp)
    target_compile_features(amcl_window_host_dso_test PRIVATE cxx_std_17)
    target_compile_definitions(amcl_window_host_dso_test PRIVATE AMCL_WINDOW_HOST_TESTING)
    add_test(NAME amcl_window_host_dso_test COMMAND amcl_window_host_dso_test
        $<TARGET_FILE:amcl_window_host_fixture_a> $<TARGET_FILE:amcl_window_host_fixture_b>)
    set_tests_properties(amcl_window_host_dso_test PROPERTIES LABELS "graphics;window;dso")
endif()

add_executable(amcl_glfw_size_notification_test glfw_size_notification_test.cpp)
target_compile_features(amcl_glfw_size_notification_test PRIVATE cxx_std_17)
add_test(NAME amcl_glfw_size_notification_test COMMAND amcl_glfw_size_notification_test)

add_executable(amcl_desktop_api22_policy_test desktop_api22_policy_test.cpp ../../platform/product_input_policy.cpp)
target_compile_features(amcl_desktop_api22_policy_test PRIVATE cxx_std_17)
target_compile_definitions(amcl_desktop_api22_policy_test PRIVATE AMCL_INPUT_COMPILED_FORMAL_DESKTOP=1 AMCL_GLFW_API26_RAW_MOUSE_MOTION=1)
add_test(NAME amcl_desktop_api22_policy_test COMMAND amcl_desktop_api22_policy_test)

add_executable(amcl_desktop_events_test desktop_events_test.cpp)
target_compile_features(amcl_desktop_events_test PRIVATE cxx_std_17)
add_test(NAME amcl_desktop_events_test COMMAND amcl_desktop_events_test)

add_executable(amcl_desktop_window_observation_test desktop_window_observation_test.cpp)
target_compile_features(amcl_desktop_window_observation_test PRIVATE cxx_std_17)
add_test(NAME amcl_desktop_window_observation_test COMMAND amcl_desktop_window_observation_test)

add_executable(amcl_egl_provider_dispatch_test egl_provider_dispatch_test.cpp)
target_compile_features(amcl_egl_provider_dispatch_test PRIVATE cxx_std_17)
add_test(NAME amcl_egl_provider_dispatch_test COMMAND amcl_egl_provider_dispatch_test)

add_executable(amcl_desktop_egl_core_test desktop_egl_core_test.cpp)
add_executable(amcl_mobilegl_egl_core_test mobilegl_egl_core_test.cpp)
target_compile_features(amcl_mobilegl_egl_core_test PRIVATE cxx_std_17)
target_include_directories(amcl_mobilegl_egl_core_test PRIVATE ../../../../../../prebuilt/khronos-egl-headers)
add_test(NAME amcl_mobilegl_egl_core_test COMMAND amcl_mobilegl_egl_core_test)
target_compile_features(amcl_desktop_egl_core_test PRIVATE cxx_std_17)
target_include_directories(amcl_desktop_egl_core_test PRIVATE ../../../../../../prebuilt/khronos-egl-headers)
add_test(NAME amcl_desktop_egl_core_test COMMAND amcl_desktop_egl_core_test)
set_tests_properties(amcl_desktop_egl_core_test PROPERTIES LABELS "desktop;egl")

# MG/GL4ES 共用的生产 EGL 核心：故障注入验证停车期间对象域、线程迁移和精确资源退休。
add_executable(amcl_gles_egl_core_test gles_egl_core_test.cpp)
target_compile_features(amcl_gles_egl_core_test PRIVATE cxx_std_17)
target_include_directories(amcl_gles_egl_core_test PRIVATE ../../../../../../prebuilt/khronos-egl-headers)
add_test(NAME amcl_gles_egl_core_test COMMAND amcl_gles_egl_core_test)
set_tests_properties(amcl_gles_egl_core_test PROPERTIES LABELS "graphics;egl;lifecycle")

find_package(Python3 3.10 REQUIRED COMPONENTS Interpreter)
get_filename_component(AMCL_REVIEW_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../.." ABSOLUTE)
set(AMCL_REVIEW_GENERATED "${CMAKE_CURRENT_BINARY_DIR}/desktop_review")
file(GLOB AMCL_REVIEW_PATCHES CONFIGURE_DEPENDS "${AMCL_REVIEW_ROOT}/prebuilt/sdl3/patches/*.patch")
file(GLOB AMCL_REVIEW_TEMPLATES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/desktop_review/*.cpp.in")
set(AMCL_REVIEW_SOURCES)
foreach(unit glfw_context glfw_monitor sdl_profile sdl_owner sdl_hide)
    list(APPEND AMCL_REVIEW_SOURCES "${AMCL_REVIEW_GENERATED}/${unit}.cpp")
endforeach()
add_custom_command(OUTPUT ${AMCL_REVIEW_SOURCES}
    COMMAND "${Python3_EXECUTABLE}" "${AMCL_REVIEW_ROOT}/scripts/generate-desktop-review-tests.py"
        --out "${AMCL_REVIEW_GENERATED}"
    DEPENDS "${AMCL_REVIEW_ROOT}/scripts/generate-desktop-review-tests.py"
        "${AMCL_REVIEW_ROOT}/prebuilt/sdl3/patches/series" ${AMCL_REVIEW_PATCHES} ${AMCL_REVIEW_TEMPLATES}
        ../../glfw/glfw_compat.cpp ../../glfw/glfw_callbacks.cpp
    VERBATIM)
foreach(unit glfw_monitor sdl_profile sdl_owner sdl_hide)
    add_executable(amcl_review_${unit}_test "${AMCL_REVIEW_GENERATED}/${unit}.cpp")
    target_compile_features(amcl_review_${unit}_test PRIVATE cxx_std_17)
    target_compile_definitions(amcl_review_${unit}_test PRIVATE AMCL_NATIVE_DESKTOP_ONLY=0)
    add_test(NAME amcl_review_${unit}_test COMMAND amcl_review_${unit}_test)
    set_tests_properties(amcl_review_${unit}_test PROPERTIES LABELS "desktop;review")
endforeach()
# GLFW current/parking 行为回归直接抽取生产函数；独立输出避免无关 SDL 补丁解析
# 阻断本测试。上方完整 SDL 目标、补丁校验和失败语义均保留，不把局部通过当作全量通过。
set(AMCL_GLFW_CONTEXT_GENERATED "${CMAKE_CURRENT_BINARY_DIR}/glfw_egl_review/glfw_context.cpp")
add_custom_command(OUTPUT "${AMCL_GLFW_CONTEXT_GENERATED}"
    COMMAND "${Python3_EXECUTABLE}" "${AMCL_REVIEW_ROOT}/scripts/generate-desktop-review-tests.py"
        --glfw-context-only --out "${CMAKE_CURRENT_BINARY_DIR}/glfw_egl_review"
    DEPENDS "${AMCL_REVIEW_ROOT}/scripts/generate-desktop-review-tests.py"
        desktop_review/glfw_context.cpp.in ../../glfw/glfw_compat.cpp
    VERBATIM)
add_executable(amcl_review_glfw_context_test "${AMCL_GLFW_CONTEXT_GENERATED}")
target_compile_features(amcl_review_glfw_context_test PRIVATE cxx_std_17)
target_compile_definitions(amcl_review_glfw_context_test PRIVATE AMCL_NATIVE_DESKTOP_ONLY=0)
add_test(NAME amcl_review_glfw_context_test COMMAND amcl_review_glfw_context_test)
add_executable(amcl_review_glfw_formal_context_test "${AMCL_GLFW_CONTEXT_GENERATED}")
target_compile_features(amcl_review_glfw_formal_context_test PRIVATE cxx_std_17)
target_compile_definitions(amcl_review_glfw_formal_context_test PRIVATE AMCL_NATIVE_DESKTOP_ONLY=1)
add_test(NAME amcl_review_glfw_formal_context_test COMMAND amcl_review_glfw_formal_context_test)

add_executable(amcl_desktop_command_queue_test desktop_command_queue_test.cpp)
target_compile_features(amcl_desktop_command_queue_test PRIVATE cxx_std_17)
add_test(NAME amcl_desktop_command_queue_test COMMAND amcl_desktop_command_queue_test)
set_tests_properties(amcl_desktop_command_queue_test PROPERTIES LABELS "desktop;input")

add_executable(amcl_mg_buffer_contract_core_test
    mg_buffer_contract_core_test.cpp
)
target_include_directories(amcl_mg_buffer_contract_core_test PRIVATE
    ../../../../../../prebuilt/mobileglues/mg_src/MobileGlues-cpp/gl
)
target_compile_features(amcl_mg_buffer_contract_core_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_mg_buffer_contract_core_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_mg_buffer_contract_core_test PRIVATE -Wall -Wextra -Werror -pedantic)
endif()
add_test(NAME amcl_mg_buffer_contract_core_test COMMAND amcl_mg_buffer_contract_core_test)

add_executable(amcl_mg_driver_profile_core_test
    mg_driver_profile_core_test.cpp
)
target_include_directories(amcl_mg_driver_profile_core_test PRIVATE
    ../../../../../../prebuilt/mobileglues/mg_src/MobileGlues-cpp/platform
)
target_compile_features(amcl_mg_driver_profile_core_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_mg_driver_profile_core_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_mg_driver_profile_core_test PRIVATE -Wall -Wextra -Werror -pedantic)
endif()
add_test(NAME amcl_mg_driver_profile_core_test COMMAND amcl_mg_driver_profile_core_test)

add_executable(amcl_mg_terrain_upload_core_test
    mg_terrain_upload_core_test.cpp
)
target_include_directories(amcl_mg_terrain_upload_core_test PRIVATE
    ../../../../../../prebuilt/mobileglues/mg_src/MobileGlues-cpp/gl
)
target_compile_features(amcl_mg_terrain_upload_core_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_mg_terrain_upload_core_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_mg_terrain_upload_core_test PRIVATE -Wall -Wextra -Werror -pedantic)
endif()
add_test(NAME amcl_mg_terrain_upload_core_test COMMAND amcl_mg_terrain_upload_core_test)

add_executable(amcl_mg_indirect_ring_core_test
    mg_indirect_ring_core_test.cpp
)
target_include_directories(amcl_mg_indirect_ring_core_test PRIVATE
    ../../../../../../prebuilt/mobileglues/mg_src/MobileGlues-cpp/gl
)
target_compile_features(amcl_mg_indirect_ring_core_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_mg_indirect_ring_core_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_mg_indirect_ring_core_test PRIVATE -Wall -Wextra -Werror -pedantic)
endif()
add_test(NAME amcl_mg_indirect_ring_core_test COMMAND amcl_mg_indirect_ring_core_test)

add_executable(amcl_mg_frame_stats_core_test
    mg_frame_stats_core_test.cpp
)
target_include_directories(amcl_mg_frame_stats_core_test PRIVATE
    ../../../../../../prebuilt/mobileglues/mg_src/MobileGlues-cpp/gl
)
target_compile_features(amcl_mg_frame_stats_core_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_mg_frame_stats_core_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_mg_frame_stats_core_test PRIVATE -Wall -Wextra -Werror -pedantic)
endif()
add_test(NAME amcl_mg_frame_stats_core_test COMMAND amcl_mg_frame_stats_core_test)

add_executable(amcl_mg_upload_scheduler_core_test
    mg_upload_scheduler_core_test.cpp
)
target_include_directories(amcl_mg_upload_scheduler_core_test PRIVATE
    ../../../../../../prebuilt/mobileglues/mg_src/MobileGlues-cpp/gl
)
target_compile_features(amcl_mg_upload_scheduler_core_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_mg_upload_scheduler_core_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_mg_upload_scheduler_core_test PRIVATE -Wall -Wextra -Werror -pedantic)
endif()
add_test(NAME amcl_mg_upload_scheduler_core_test COMMAND amcl_mg_upload_scheduler_core_test)

add_executable(amcl_mg_glsl_uniform_initializer_core_test
    mg_glsl_uniform_initializer_core_test.cpp
)
target_include_directories(amcl_mg_glsl_uniform_initializer_core_test PRIVATE
    ../../../../../../prebuilt/mobileglues/mg_src/MobileGlues-cpp/gl/glsl
)
target_compile_features(amcl_mg_glsl_uniform_initializer_core_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_mg_glsl_uniform_initializer_core_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_mg_glsl_uniform_initializer_core_test PRIVATE -Wall -Wextra -Werror -pedantic)
endif()
add_test(NAME amcl_mg_glsl_uniform_initializer_core_test COMMAND amcl_mg_glsl_uniform_initializer_core_test)

add_executable(amcl_jni_mutf8_test
    jni_mutf8_test.cpp
)
target_include_directories(amcl_jni_mutf8_test PRIVATE
    ../../jvm
)
target_compile_features(amcl_jni_mutf8_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_jni_mutf8_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_jni_mutf8_test PRIVATE -Wall -Wextra -Werror -pedantic)
endif()
add_test(NAME amcl_jni_mutf8_test COMMAND amcl_jni_mutf8_test)

# 公共 JVM 堆选项预检必须与最终装配使用同一纯核心；不需要真实 JDK 即可检验溢出及覆盖顺序。
add_executable(amcl_jvm_heap_options_test jvm_heap_options_test.cpp)
target_compile_features(amcl_jvm_heap_options_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_jvm_heap_options_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_jvm_heap_options_test PRIVATE -Wall -Wextra -Werror -pedantic)
endif()
add_test(NAME amcl_jvm_heap_options_test COMMAND amcl_jvm_heap_options_test)

add_executable(amcl_input_host_tests
    input_state_core_test.cpp
    input_reconciliation_test.cpp
    input_abi_c_smoke.c
    ../../input/input_state_core.cpp
)
target_include_directories(amcl_input_host_tests PRIVATE
    ../../input
    ../../platform
    # input_state_core.cpp emits the §11 observability block through hilog. The
    # stub makes OH_LOG_* a no-op so the counters stay assertable off-device;
    # note it also swallows format/arg mismatches, so a change to those log lines
    # is only validated by the on-device build.
    stubs
)
target_compile_features(amcl_input_host_tests PRIVATE cxx_std_17)
target_compile_definitions(amcl_input_host_tests PRIVATE
    AMCL_INPUT_HOST_EXPORTS
    AMCL_INPUT_HOST_TESTING
    AMCL_INPUT_QUEUE_CAPACITY=8
    AMCL_INPUT_BLOB_POOL_CAPACITY=256
)
if(MSVC)
    target_compile_options(amcl_input_host_tests PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_input_host_tests PRIVATE
        -Wall -Wextra -Werror -pedantic
    )
endif()

add_test(NAME amcl_input_host_tests COMMAND amcl_input_host_tests)

function(add_platform_ingress_host_test target source shadow_default)
    add_executable(${target}
        ${source}
        ../../input/platform_input_ingress.cpp
        ../../input/input_shadow_consumer.cpp
        ../../input/input_trace.cpp
        ../../input/input_state_core.cpp
    )
    target_include_directories(${target} PRIVATE
        ../../input
        stubs
    )
    target_compile_features(${target} PRIVATE cxx_std_17)
    target_compile_definitions(${target} PRIVATE
        AMCL_INPUT_HOST_EXPORTS
        AMCL_INPUT_HOST_TESTING
        AMCL_INPUT_SHADOW=${shadow_default}
        AMCL_INPUT_QUEUE_CAPACITY=8
        AMCL_INPUT_BLOB_POOL_CAPACITY=16
        $<$<CXX_COMPILER_ID:MSVC>:_CRT_SECURE_NO_WARNINGS>
    )
    if(MSVC)
        target_compile_options(${target} PRIVATE /W4 /WX)
    else()
        target_compile_options(${target} PRIVATE
            -Wall -Wextra -Werror -pedantic
        )
    endif()
    add_test(NAME ${target} COMMAND ${target})
endfunction()

add_platform_ingress_host_test(
    amcl_platform_input_ingress_integration_test
    platform_input_ingress_integration_test.cpp
    1
)
add_platform_ingress_host_test(
    amcl_platform_input_shadow_disabled_test
    platform_input_shadow_disabled_test.cpp
    0
)
add_platform_ingress_host_test(
    amcl_platform_input_typed_route_test
    platform_input_typed_route_test.cpp
    0
)
# Host targets assert Gate 0 capabilities without device evidence on purpose.
# glfw_input_mode.h requires every asserted capability to carry the evidence id
# that authorized it, so each such target declares an explicit fixture id rather
# than being exempted. That keeps the product requirement unconditional and makes
# every pretend-evidence build greppable.
target_compile_definitions(amcl_platform_input_typed_route_test PRIVATE
    AMCL_GLFW_RAW_RELATIVE_VERIFIED=1
    AMCL_GLFW_API26_RAW_MOUSE_MOTION=0
    AMCL_EXPECT_API26_RAW=0
    AMCL_GATE0_EVIDENCE_IDS="host-test-fixture"
)

# Same typed route, but with the independent API 26 hardware-raw declaration
# enabled.  Keeping this as a second executable proves that bit 13 (usable
# relative movement) does not accidentally imply the public GLFW raw contract.
add_platform_ingress_host_test(
    amcl_platform_input_api26_raw_route_test
    platform_input_typed_route_test.cpp
    0
)
target_compile_definitions(amcl_platform_input_api26_raw_route_test PRIVATE
    AMCL_GLFW_RAW_RELATIVE_VERIFIED=1
    AMCL_GLFW_API26_RAW_MOUSE_MOTION=1
    AMCL_EXPECT_API26_RAW=1
    AMCL_GATE0_EVIDENCE_IDS="host-test-fixture"
)

add_platform_ingress_host_test(
    amcl_platform_input_typed_relative_unverified_test
    platform_input_typed_relative_unverified_test.cpp
    0
)

# Exact shipping ingress/core transaction for Phase 3.3 native absolute. The
# evidence assertion is target-local; the product CMake option remains OFF.
add_platform_ingress_host_test(
    amcl_platform_input_typed_native_absolute_test
    platform_input_typed_native_absolute_test.cpp
    0
)
target_compile_definitions(amcl_platform_input_typed_native_absolute_test PRIVATE
    AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED=1
    AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED=1
    AMCL_GATE0_EVIDENCE_IDS="host-test-fixture"
)

# Coordinate provenance alone is intentionally insufficient: without an
# independently verified MouseEvent timestamp clock, bit14 and the native
# absolute route must remain fail-closed.
add_platform_ingress_host_test(
    amcl_native_absolute_no_timestamp_test
    platform_input_native_absolute_timestamp_unverified_test.cpp
    0
)
target_compile_definitions(
    amcl_native_absolute_no_timestamp_test PRIVATE
    AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED=1
    AMCL_GATE0_EVIDENCE_IDS="host-test-fixture"
)

# End-to-end typed route: shipping PlatformInputPhysical* ingress, core host,
# adapter and OHOS mapper. A second real consumer observes raw identities; no
# fake host or injected mapper is used by this target.
add_executable(amcl_platform_input_typed_glfw_e2e_test
    platform_input_typed_glfw_e2e_test.cpp
    ../../input/platform_input_ingress.cpp
    ../../input/input_shadow_consumer.cpp
    ../../input/input_trace.cpp
    ../../input/input_state_core.cpp
    ../../input/adapters/glfw_input_adapter.cpp
)
target_include_directories(amcl_platform_input_typed_glfw_e2e_test PRIVATE
    ../../input
    stubs
)
target_compile_features(amcl_platform_input_typed_glfw_e2e_test PRIVATE
    cxx_std_17
)
target_compile_definitions(amcl_platform_input_typed_glfw_e2e_test PRIVATE
    AMCL_INPUT_HOST_EXPORTS
    AMCL_INPUT_HOST_TESTING
    AMCL_INPUT_SHADOW=0
    AMCL_INPUT_QUEUE_CAPACITY=8
    AMCL_INPUT_BLOB_POOL_CAPACITY=16
    AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED=1
    AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED=1
    AMCL_GATE0_EVIDENCE_IDS="host-test-fixture"
    $<$<CXX_COMPILER_ID:MSVC>:_CRT_SECURE_NO_WARNINGS>
)
if(MSVC)
    target_compile_options(amcl_platform_input_typed_glfw_e2e_test PRIVATE
        /W4 /WX
    )
else()
    target_compile_options(amcl_platform_input_typed_glfw_e2e_test PRIVATE
        -Wall -Wextra -Werror -pedantic
    )
endif()
add_test(NAME amcl_platform_input_typed_glfw_e2e_test
         COMMAND amcl_platform_input_typed_glfw_e2e_test)

function(add_input_component_host_test target source implementation)
    add_executable(${target} ${source} ${implementation})
    target_include_directories(${target} PRIVATE ../../input)
    target_compile_features(${target} PRIVATE cxx_std_17)
    target_compile_definitions(${target} PRIVATE
        $<$<CXX_COMPILER_ID:MSVC>:_CRT_SECURE_NO_WARNINGS>
    )
    if(MSVC)
        target_compile_options(${target} PRIVATE /W4 /WX)
    else()
        target_compile_options(${target} PRIVATE
            -Wall -Wextra -Werror -pedantic
        )
    endif()
    add_test(NAME ${target} COMMAND ${target})
endfunction()

add_executable(amcl_cursor_capture_policy_test
    cursor_capture_policy_test.cpp
)
target_include_directories(amcl_cursor_capture_policy_test PRIVATE
    ../../input
    ../../platform
)
target_compile_features(amcl_cursor_capture_policy_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_cursor_capture_policy_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_cursor_capture_policy_test PRIVATE
        -Wall -Wextra -Werror -pedantic
    )
endif()
add_test(NAME amcl_cursor_capture_policy_test
         COMMAND amcl_cursor_capture_policy_test)

add_executable(amcl_backend_input_event_encode_test
    backend_input_event_encode_test.cpp
)
target_include_directories(amcl_backend_input_event_encode_test PRIVATE
    ../../input
    ../../platform
)
target_compile_features(amcl_backend_input_event_encode_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_backend_input_event_encode_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_backend_input_event_encode_test PRIVATE
        -Wall -Wextra -Werror -pedantic
    )
endif()
add_test(NAME amcl_backend_input_event_encode_test
         COMMAND amcl_backend_input_event_encode_test)

add_executable(amcl_product_input_policy_test
    product_input_policy_test.cpp
    ../../platform/product_input_policy.cpp
)
target_include_directories(amcl_product_input_policy_test PRIVATE
    ../../platform
)
target_compile_features(amcl_product_input_policy_test PRIVATE cxx_std_17)
target_compile_definitions(amcl_product_input_policy_test PRIVATE AMCL_GLFW_API26_RAW_MOUSE_MOTION=1)
if(MSVC)
    target_compile_options(amcl_product_input_policy_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_product_input_policy_test PRIVATE
        -Wall -Wextra -Werror -pedantic)
endif()
add_test(NAME amcl_product_input_policy_test
         COMMAND amcl_product_input_policy_test)

add_executable(amcl_product_input_formal_build_contract_test
    product_input_formal_build_contract_test.cpp
    ../../platform/product_input_policy.cpp
)
target_include_directories(amcl_product_input_formal_build_contract_test PRIVATE
    ../..
)
target_compile_features(amcl_product_input_formal_build_contract_test PRIVATE cxx_std_17)
target_compile_definitions(amcl_product_input_formal_build_contract_test PRIVATE
    AMCL_INPUT_COMPILED_FORMAL_DESKTOP=1
)
if(MSVC)
    target_compile_options(amcl_product_input_formal_build_contract_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_product_input_formal_build_contract_test PRIVATE
        -Wall -Wextra -Werror)
endif()
add_test(NAME amcl_product_input_formal_build_contract_test
         COMMAND amcl_product_input_formal_build_contract_test)

add_executable(amcl_product_input_legacy_ceiling_test
    product_input_legacy_ceiling_test.cpp
    ../../platform/product_input_policy.cpp)
target_compile_features(amcl_product_input_legacy_ceiling_test PRIVATE cxx_std_17)
target_compile_definitions(amcl_product_input_legacy_ceiling_test PRIVATE
    AMCL_GLFW_API26_RAW_MOUSE_MOTION=0 AMCL_INPUT_COMPILED_FORMAL_DESKTOP=0)
add_test(NAME amcl_product_input_legacy_ceiling_test COMMAND amcl_product_input_legacy_ceiling_test)

add_executable(amcl_unicode_scalar_test
    unicode_scalar_test.cpp
)
target_include_directories(amcl_unicode_scalar_test PRIVATE ../../platform)
target_compile_features(amcl_unicode_scalar_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_unicode_scalar_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_unicode_scalar_test PRIVATE
        -Wall -Wextra -Werror -pedantic)
endif()
add_test(NAME amcl_unicode_scalar_test COMMAND amcl_unicode_scalar_test)

add_executable(amcl_text_utf8_codec_test
    text_utf8_codec_test.cpp
)
target_include_directories(amcl_text_utf8_codec_test PRIVATE
    ../../input
)
target_compile_features(amcl_text_utf8_codec_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_text_utf8_codec_test PRIVATE /W4 /WX /permissive-)
else()
    target_compile_options(amcl_text_utf8_codec_test PRIVATE
        -Wall -Wextra -Werror -pedantic)
endif()
add_test(NAME amcl_text_utf8_codec_test COMMAND amcl_text_utf8_codec_test)

add_executable(amcl_glfw_backend_lifecycle_test
    glfw_backend_lifecycle_test.cpp
)
target_include_directories(amcl_glfw_backend_lifecycle_test PRIVATE
    ../../input
    ../../platform
)
target_compile_features(amcl_glfw_backend_lifecycle_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_glfw_backend_lifecycle_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_glfw_backend_lifecycle_test PRIVATE
        -Wall -Wextra -Werror -pedantic
    )
endif()
add_test(NAME amcl_glfw_backend_lifecycle_test
         COMMAND amcl_glfw_backend_lifecycle_test)

add_input_component_host_test(
    amcl_input_host_descriptor_test
    amcl_input_host_descriptor_test.cpp
    ../../input/amcl_input_host_descriptor.cpp
)
find_package(Threads REQUIRED)
target_link_libraries(amcl_input_host_descriptor_test PRIVATE Threads::Threads)
target_compile_definitions(amcl_input_host_descriptor_test PRIVATE
    AMCL_INPUT_HOST_TESTING
)

foreach(fixture IN ITEMS
        amcl_input_host_descriptor_fixture_a
        amcl_input_host_descriptor_fixture_b)
    add_library(${fixture} SHARED
        amcl_input_host_descriptor_dso_fixture.cpp
        ../../input/amcl_input_host_descriptor.cpp
    )
    target_include_directories(${fixture} PRIVATE ../../input)
    target_compile_features(${fixture} PRIVATE cxx_std_17)
    target_compile_definitions(${fixture} PRIVATE
        $<$<CXX_COMPILER_ID:MSVC>:_CRT_SECURE_NO_WARNINGS>
    )
    if(MSVC)
        target_compile_options(${fixture} PRIVATE /W4 /WX)
    else()
        target_compile_options(${fixture} PRIVATE
            -Wall -Wextra -Werror -pedantic
        )
    endif()
endforeach()

add_executable(amcl_input_host_descriptor_dso_test
    amcl_input_host_descriptor_dso_test.cpp
)
target_include_directories(amcl_input_host_descriptor_dso_test PRIVATE ../../input)
target_compile_features(amcl_input_host_descriptor_dso_test PRIVATE cxx_std_17)
target_link_libraries(amcl_input_host_descriptor_dso_test PRIVATE
    Threads::Threads ${CMAKE_DL_LIBS}
)
if(MSVC)
    target_compile_options(amcl_input_host_descriptor_dso_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_input_host_descriptor_dso_test PRIVATE
        -Wall -Wextra -Werror -pedantic
    )
endif()
add_test(NAME amcl_input_host_descriptor_dso_test COMMAND
    amcl_input_host_descriptor_dso_test
    $<TARGET_FILE:amcl_input_host_descriptor_fixture_a>
    $<TARGET_FILE:amcl_input_host_descriptor_fixture_b>
)

add_input_component_host_test(
    amcl_glfw_input_adapter_test
    glfw_input_adapter_test.cpp
    ../../input/adapters/glfw_input_adapter.cpp
)
target_compile_definitions(amcl_glfw_input_adapter_test PRIVATE
    AMCL_GLFW_INPUT_ADAPTER_TESTING
)

add_input_component_host_test(
    amcl_glfw_typed_absolute_route_test
    glfw_typed_absolute_route_test.cpp
    ../../input/adapters/glfw_typed_absolute_route.cpp
)

# 视角管线的观测面。它把 applyLookDelta 头注释承诺的那句"任意手势的总输出严格等于灵敏度/
# 加速后的总输入"变成一条可判定的恒等式（Σemit + backlog + discarded == Σscaled），
# 而在此之前那句话没有任何断言钉住。最后一个用例直接喂 ComputeLookDeltaMath 的真实输出，
# 所以恒等式钉的是**产品那份数学**，不是手写数字。
add_input_component_host_test(
    amcl_look_pipeline_stats_test
    look_pipeline_stats_test.cpp
    ../../platform/look_pipeline_stats.cpp
)
target_sources(amcl_look_pipeline_stats_test PRIVATE
    ../../platform/look_delta_math.cpp
)
target_include_directories(amcl_look_pipeline_stats_test PRIVATE ../../platform)

# 视角加工只有一份（libentry 的 applyLookDelta 漏斗），typed 平面是它的第二个生产者。
# 二者跨 DSO 且方向与依赖相反，所以中间必须有一条 env trampoline —— 而"静默解析出半个
# 地址"与"非有限值跨 DSO 污染持久 backlog"是它两个真实失败模式。产品胶水层
# （glfw_compat.cpp）host 构建拉不进来，因此把可判定的那部分抽成这个 TU 来断言。
add_input_component_host_test(
    amcl_glfw_typed_look_route_test
    glfw_typed_look_route_test.cpp
    ../../input/adapters/glfw_typed_look_route.cpp
)

# Shipping glfw_compat calls this callback-free seam while its exact window and
# NativeWindow publication guards are held, then invokes user callbacks only
# after both guards leave. This target exercises that same validation/commit TU.
add_input_component_host_test(
    amcl_glfw_typed_runtime_dispatch_test
    glfw_typed_runtime_dispatch_test.cpp
    ../../input/adapters/glfw_typed_runtime_dispatch.cpp
)
target_sources(amcl_glfw_typed_runtime_dispatch_test PRIVATE
    ../../input/adapters/glfw_typed_absolute_route.cpp
    ../../input/adapters/glfw_source_plane_aggregate.cpp
)

# Unlike the adapter unit test's deliberately adversarial fake host, this target
# links the shipping core, exported V1 table and adapter together. It proves
# ownerless/duplicate edge diagnostics survive the actual core→consumer path.
add_executable(amcl_input_core_glfw_adapter_integration_test
    input_core_glfw_adapter_integration_test.cpp
    ../../input/input_state_core.cpp
    ../../input/adapters/glfw_input_adapter.cpp
)
target_include_directories(amcl_input_core_glfw_adapter_integration_test PRIVATE
    ../../input
    stubs   # hilog no-op for the core's §11 observability block
)
target_compile_features(amcl_input_core_glfw_adapter_integration_test PRIVATE
    cxx_std_17
)
target_compile_definitions(amcl_input_core_glfw_adapter_integration_test PRIVATE
    AMCL_INPUT_HOST_EXPORTS
    $<$<CXX_COMPILER_ID:MSVC>:_CRT_SECURE_NO_WARNINGS>
)
if(MSVC)
    target_compile_options(amcl_input_core_glfw_adapter_integration_test PRIVATE
        /W4 /WX
    )
else()
    target_compile_options(amcl_input_core_glfw_adapter_integration_test PRIVATE
        -Wall -Wextra -Werror -pedantic
    )
endif()
add_test(NAME amcl_input_core_glfw_adapter_integration_test
         COMMAND amcl_input_core_glfw_adapter_integration_test)

add_input_component_host_test(
    amcl_glfw_source_plane_aggregate_test
    glfw_source_plane_aggregate_test.cpp
    ../../input/adapters/glfw_source_plane_aggregate.cpp
)

# Exact internal policy used by glfw_compat's descriptor gate. The fake retire
# callbacks prove resolver faults actively close an already-ready typed adapter,
# retain readable diagnostics, and cannot be confused with a valid legacy
# capability selection.
add_executable(amcl_glfw_typed_input_resolve_guard_test
    glfw_typed_input_resolve_guard_test.cpp
)
target_include_directories(amcl_glfw_typed_input_resolve_guard_test PRIVATE
    ../../input
)
target_compile_features(amcl_glfw_typed_input_resolve_guard_test PRIVATE
    cxx_std_17
)
target_link_libraries(amcl_glfw_typed_input_resolve_guard_test PRIVATE
    Threads::Threads
)
if(MSVC)
    target_compile_options(amcl_glfw_typed_input_resolve_guard_test PRIVATE
        /W4 /WX
    )
else()
    target_compile_options(amcl_glfw_typed_input_resolve_guard_test PRIVATE
        -Wall -Wextra -Werror -pedantic
    )
endif()
add_test(NAME amcl_glfw_typed_input_resolve_guard_test
         COMMAND amcl_glfw_typed_input_resolve_guard_test)

# Exact numeric gate and transactional remainder calculation used by the native
# physical AxisEvent path. Invalid input never mutates the caller's accumulator.
add_input_component_host_test(
    amcl_physical_wheel_quantizer_test
    physical_wheel_quantizer_test.cpp
    ../../platform/physical_wheel_quantizer.cpp
)

# 滚轮两条平面的**差分**断言（计划 §91）。命题：同一串样本喂给 legacy 与 typed 两条平面，
# 格数序列逐位相同。它抓的是"两条平面各写一遍、只是恰好等价"这一族 —— 修之前拒绝路径上
# legacy 清零而 typed 保留，一个非法样本之后两条平面永久错位，而两边各自的单测都是绿的。
# ⚠️ 刻意只在**加工段**做差分：路由位是启动期闭锁的，同一进程里两条平面不能同时活，
# 把差分写成"驱动整条 ingress 两次"会断言一个不可能发生的场景（文件头有完整边界说明）。
add_input_component_host_test(
    amcl_wheel_dual_plane_differential_test
    wheel_dual_plane_differential_test.cpp
    ../../platform/physical_wheel_quantizer.cpp
)
# 第 13/14 组把差分从"两条平面"扩到"三条消费端"，因此要拉进 LWJGL2 的出线翻译。
# ⚠️ SDL3 那一条**不需要**新增源文件：它拿到的就是宿主 pull 通道放进 ABI 的那个值，
# patch 里是直传。链 ② 与链 ③ 的分界正好在 `AmclBackendInputEvent` 上。
target_sources(amcl_wheel_dual_plane_differential_test PRIVATE
    ../../input/adapters/lwjgl2_event_translate.cpp
)
target_include_directories(amcl_wheel_dual_plane_differential_test PRIVATE
    ../../input
)

# LWJGL2 后端的**出线翻译**（计划 §102）。TASK 6 把三个后端都切到 typed 通道之后，两条新链
# 的正确性只有"读代码"一个依据，这个目标把 LWJGL2 那一条里可判定的部分变成机械判据：
# action 三态、按钮只有两态、滚轮分格必须调与两条 GLFW 平面同一个 StepPhysicalWheel、
# 拒绝时余量归零、复位清余量、未知类型丢弃且余量原样保留、两个出参在两种返回下都被写。
# ⚠️ 第一版自己手写了 trunc，于是丢掉 maxDetentsPerEvent 截断与 DropOnCrossing 两条通道
# 契约（快滚一次甩出上百格）；第 13、14 组就是钉这件事的。
add_input_component_host_test(
    amcl_lwjgl2_event_translate_test
    lwjgl2_event_translate_test.cpp
    ../../input/adapters/lwjgl2_event_translate.cpp
)
target_sources(amcl_lwjgl2_event_translate_test PRIVATE
    ../../platform/physical_wheel_quantizer.cpp
)

# 两份后端 mapper 里**门禁结构上做不到的那一半**（计划 §103.2）：
# check-backend-keymap-parity 自己写明不覆盖 scanCode fallback 链，而**按钮表一条都没进
# 门禁**（三个后端的按钮域各不相同，硬凑等式只会得到恒真断言）——
# 于是"把 SDL 那张按钮表抄成 LWJGL2 那张"不会有任何东西变红，后果是右键变中键。
# 这个目标补的就是这两块 + 未知键/按钮 fail closed 不写出参 + 105/106 差异的行为化断言。
add_input_component_host_test(
    amcl_backend_keymaps_test
    backend_keymaps_test.cpp
    ../../input/adapters/backend_keymaps.cpp
)

# Exact same-callback mode split used by native XComponent mouse ingress.
# Unknown/grabbed state must never enter the menu absolute source plane.
add_input_component_host_test(
    amcl_native_mouse_route_policy_test
    native_mouse_route_policy_test.cpp
    ../../platform/native_mouse_route_policy.cpp
)

# Gate 0 telemetry sampling policy. Header-only constexpr policy, so this target
# needs no implementation TU and pulls in neither hilog nor XComponent. A wrong
# window/stride does not crash: it silently removes part of the evidence the Gate
# 0 conclusion is built on, which is why the boundaries are pinned here.
add_executable(amcl_gate0_sample_throttle_test
    gate0_sample_throttle_test.cpp
)
target_include_directories(amcl_gate0_sample_throttle_test PRIVATE
    ../../platform
)
target_compile_features(amcl_gate0_sample_throttle_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_gate0_sample_throttle_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_gate0_sample_throttle_test PRIVATE
        -Wall -Wextra -Werror -pedantic
    )
endif()
add_test(NAME amcl_gate0_sample_throttle_test
         COMMAND amcl_gate0_sample_throttle_test)

# The one target that builds input_trace.cpp with its periodic §11 sample line
# disabled. Every other target uses the default interval, so without this the
# "sampling can be switched off" knob would only be verified by reading the
# source. It also pins that disabling it leaves every counter intact -- otherwise
# the knob would double as a way to suppress evidence.
add_executable(amcl_input_trace_sample_interval_test
    input_trace_sample_interval_test.cpp
    ../../input/input_trace.cpp
)
target_include_directories(amcl_input_trace_sample_interval_test PRIVATE
    ../../input
    stubs
)
target_compile_features(amcl_input_trace_sample_interval_test PRIVATE cxx_std_17)
target_compile_definitions(amcl_input_trace_sample_interval_test PRIVATE
    AMCL_INPUT_HOST_TESTING
    AMCL_INPUT_TRACE_SAMPLE_INTERVAL=0
)
if(MSVC)
    # /wd4702（无法访问的代码）：**这是本目标自己造成的,不是缺陷。**
    # 本目标是唯一定义 AMCL_INPUT_TRACE_SAMPLE_INTERVAL=0 的,而 MaybeSample() 用
    # `if constexpr (kSampleInterval == 0u) return;` 早退（那里用 if constexpr 而非 if
    # 的理由写在 input_trace.cpp 里：普通 if 会触发 C4127）。⇒ 在且仅在本目标的
    # 配置下,该函数尾部本来就应当不可达。
    # 不抑制的代价：把这个目标从套件里去掉,或者删掉那个刻意的 if constexpr。
    # 2026-08-23 第一次真正执行 host 断言（MSVC cl 14.51 + /W4 /WX）时暴露。
    target_compile_options(amcl_input_trace_sample_interval_test PRIVATE
        /W4 /WX /wd4702
    )
else()
    target_compile_options(amcl_input_trace_sample_interval_test PRIVATE
        -Wall -Wextra -Werror -pedantic
    )
endif()
add_test(NAME amcl_input_trace_sample_interval_test
         COMMAND amcl_input_trace_sample_interval_test)

# Pure transaction used by the shipping look processor. It proves non-finite
# values and finite-overflow intermediates cannot mutate backlog/timestamp.
add_input_component_host_test(
    amcl_look_delta_math_test
    look_delta_math_test.cpp
    ../../platform/look_delta_math.cpp
)

# 按端隔离的持有配对（经 NAPI 下来的持续按下态）。承载的是**静默**故障：抬起拿走别端的
# owner 之后聚合边沿仍然守恒、计数器也正常，只有归属互换，直到用户报告"卡键"才暴露。
# 该逻辑此前埋在 touch_input.cpp（3600+ 行）里，主机侧构建拉不进来 —— 抽成独立 TU 的
# 首要目的就是让它可测。
add_input_component_host_test(
    amcl_external_held_registry_test
    external_held_registry_test.cpp
    ../../platform/external_held_registry.cpp
)
target_include_directories(amcl_external_held_registry_test PRIVATE ../../platform)

# 输入账目的不变量求值器。它是**告警系统本身**，漏报等于没有这套机制，误报会让下一轮
# 判读直接把 AMCL_INVARIANT 当噪声忽略 —— 而"计数器不可信"已经让这个项目损失过整轮时间。
# 因此两个方向都测：健康快照必须干净通过，每条不变量都要能被单独触发。
add_input_component_host_test(
    amcl_input_invariants_test
    input_invariants_test.cpp
    ../../platform/input_invariants.cpp
)
target_include_directories(amcl_input_invariants_test PRIVATE ../../platform)

# 摇杆八向扇区判定。这套逻辑此前在 native 触控 / 手柄端 ArkTS / 触控端 ArkTS 兼容路径里
# 写了三遍且逐字相同，但没有任何机制保证它们不分叉 —— 谁改一份另两份不会有编译或测试提示，
# 表现为"同一个八向摇杆在三端手感不同"。本目标与 entry/src/test/JoystickSector.test.ets
# 断言**同一张规格表**，两侧偏离任一都会失败。
add_input_component_host_test(
    amcl_joystick_sector_test
    joystick_sector_test.cpp
    ../../platform/joystick_sector.cpp
)
target_include_directories(amcl_joystick_sector_test PRIVATE ../../platform)

# 单一所有者策略层。它是**专门为修"左键卡死"而建的**（docs/refactor 第三十五节），
# 却一直零测试覆盖。守的两条性质坏了都用户可感知：所有者与到达时序无关（坏了→菜单点不动）、
# 一对 press/release 由同一通道送完（坏了→左键永久卡在按下态）。
# 需要 stubs 让 hilog 变 no-op；模块的能力位图是进程级只增不减，所以测试内部顺序即前提。
add_input_component_host_test(
    amcl_input_channel_policy_test
    input_channel_policy_test.cpp
    ../../platform/input_channel_policy.cpp
)
target_sources(amcl_input_channel_policy_test PRIVATE stubs/amcl_log_stub.cpp)
target_include_directories(amcl_input_channel_policy_test PRIVATE
    ../../platform
    stubs
)

# 按端的两个系数表（视角量纲 + 平滑）。它们是"三端各自的手感"唯一的收口点，而失效
# **不报错、不崩溃、不改变任何计数器**，只是某一端手感变了 —— 日志里看不出来。
# 本轮的直接动因：KBM 端平滑一旦跟随全局值，物理鼠标就重新背上 τ≈18.2ms 相位滞后
# + idle worker 的 20ms 尾量（用户报的"视角延迟感"，计划 §77.1 / §78）。
# 同时钉住量纲系数当前仍一律 1.0，让将来的标定必须是刻意改动。
# 需要 stubs 让 hilog 变 no-op（该 TU 的普查日志用到它）。
add_input_component_host_test(
    amcl_input_source_test
    input_source_test.cpp
    ../../platform/input_source.cpp
)
target_include_directories(amcl_input_source_test PRIVATE
    ../../platform
    stubs
)

# ⚠️ 这里曾有 amcl_mouse_synth_tap_state_machine_test。被测子系统
# （MouseSynthTapStateMachine：把鼠标合成的触摸手势延迟 300ms 识别成左键点击）
# 已按真机证据整体删除 —— 它的候选起点要求 source==kMouseSynth，而触摸 ingress 在把包判为
# mirrorPacket 之后就 return 了，产品路径根本到不了识别器；左键早已改由
# input_channel_policy 在三条通道里选一条立即透传。
# 仍在使用的分类器 ClassifyMouseSynthTouchSource 已拆到 platform/mouse_synth_touch_source.cpp。
# ⚠️ 诚实记录：随着上面那个测试目标一起删除，该分类器**目前没有 host 测试覆盖**
# （它原先只被这个测试引用）。它是一个无状态纯函数、五个 bool 入参、真值表极小，
# 且被 touch_input 的常开 AMCL_TOUCHSRC 打点在真机上逐组合验证。
# 若要补测试，应新建独立目标而不是把它塞回一个以已删状态机命名的文件。

# Exact shipping legacy physical lifecycle helper plus the real owner-aware
# ledger. This exercises raw identity, immutable DOWN mapping, aggregate edges,
# reset re-entry fencing and schema/external owner-domain isolation.
add_executable(amcl_legacy_physical_edge_router_test
    legacy_physical_edge_router_test.cpp
    ../../platform/legacy_physical_edge_router.cpp
    ../../platform/input_ledger.cpp
)
target_include_directories(amcl_legacy_physical_edge_router_test PRIVATE
    ../../input
    ../../platform
)
target_compile_features(amcl_legacy_physical_edge_router_test PRIVATE
    cxx_std_17
)
if(MSVC)
    target_compile_options(amcl_legacy_physical_edge_router_test PRIVATE
        /W4 /WX
    )
else()
    target_compile_options(amcl_legacy_physical_edge_router_test PRIVATE
        -Wall -Wextra -Werror -pedantic
    )
endif()
add_test(NAME amcl_legacy_physical_edge_router_test
         COMMAND amcl_legacy_physical_edge_router_test)

# registry × ledger **复合**语义。为什么不能靠上面那两个单侧目标：
# amcl_external_held_registry_test 只断言 TakeSameSource 取回哪个 token，看不到"MC 收到了
# 什么"；而 input_ledger.cpp 唯一进 host 构建的路径是 amcl_legacy_physical_edge_router_test，
# 那是**物理端专用身份**的 owner 域，不经 external 表。于是"registry 全绿 + ledger 全绿 =
# 一个卡死的按键"这条组合缺陷落在两者之间的缝里，直到 2026-08-21 才被发现。
# 钉住的性质：堆叠 owner 在没有按端释放时永远回不到抬起态（缺陷本体）、按端释放正好补一条
# RELEASE（修法）、空表时释放是 no-op（它被放在禁止副作用的对账路径上的前提）、
# 不越端、不跨 owner 域（schema owner 必须完全不受影响）。
add_executable(amcl_external_held_pairing_composite_test
    external_held_pairing_composite_test.cpp
    ../../platform/external_held_registry.cpp
    ../../platform/input_ledger.cpp
)
target_include_directories(amcl_external_held_pairing_composite_test PRIVATE
    ../../input
    ../../platform
)
target_compile_features(amcl_external_held_pairing_composite_test PRIVATE
    cxx_std_17
)
if(MSVC)
    target_compile_options(amcl_external_held_pairing_composite_test PRIVATE
        /W4 /WX
    )
else()
    target_compile_options(amcl_external_held_pairing_composite_test PRIVATE
        -Wall -Wextra -Werror -pedantic
    )
endif()
add_test(NAME amcl_external_held_pairing_composite_test
         COMMAND amcl_external_held_pairing_composite_test)

# Compile the shipping C11/pthread bridge through its Windows host primitive
# shim. Only platform synchronization/environment wrappers differ; the actual
# ring, pump, overflow, menu and window-cancel implementation is shared.
set_source_files_properties(
    ../../glfw/input_bridge_ohos.c
    PROPERTIES LANGUAGE CXX
)
# ⚠️ 后两个源文件是 2026-08-24 typed 通道接进 `inputBridge_l2NextEvent` 之后必需的：
# 出线翻译用**真实实现**（它是纯函数，进 host 无阻碍），而 `amclBackendInputNext` 的实现 TU
# 带 hilog + core 单例进不来，用可编程替身。补替身而不是恒返回 EMPTY 的空壳是刻意的 ——
# 空壳等于承认 typed/ring 的合并逻辑没有断言，而那正是 f5dc4eb 犯过的真错误。
add_executable(amcl_glfw_runtime_input_bridge_test
    glfw_runtime_input_bridge_test.cpp
    ../../glfw/input_bridge_ohos.c
    ../../input/adapters/glfw_source_plane_aggregate.cpp
    ../../input/adapters/lwjgl2_event_translate.cpp
    ../../platform/physical_wheel_quantizer.cpp
    backend_input_bridge_host_stub.cpp
)
target_include_directories(amcl_glfw_runtime_input_bridge_test PRIVATE
    ../../input
    stubs
)
target_compile_features(amcl_glfw_runtime_input_bridge_test PRIVATE cxx_std_17)
target_compile_definitions(amcl_glfw_runtime_input_bridge_test PRIVATE
    AMCL_INPUT_BRIDGE_HOST_TESTING
    EVENT_WINDOW_SIZE=8
    $<$<CXX_COMPILER_ID:MSVC>:_CRT_SECURE_NO_WARNINGS>
)
if(MSVC)
    target_compile_options(amcl_glfw_runtime_input_bridge_test PRIVATE
        /W4 /WX /wd4100 /wd4101 /wd4189 /wd4244 /wd4267
    )
else()
    # `-Wno-unused-variable` 补的是一处**既有的不对称**，不是为某个工具让路：MSVC 分支上面
    # 已经带着等价的 /wd4101 /wd4189，而非 MSVC 分支只有 -Wno-unused-parameter。
    # 2026-08-23 在 GCC 13 上暴露：`g_invoke_WindowSize` / `g_invoke_FramebufferSize` 这两个
    # 文件作用域回调指针在 host 配置下没有读者（产品配置里有），GCC 按 -Wunused-variable 报错。
    target_compile_options(amcl_glfw_runtime_input_bridge_test PRIVATE
        -Wall -Wextra -Werror -pedantic -Wno-unused-parameter -Wno-unused-variable
    )
endif()
add_test(NAME amcl_glfw_runtime_input_bridge_test
         COMMAND amcl_glfw_runtime_input_bridge_test)

# legacy bridge 的跨 image 实例描述符。它是纯 env 编解码，所以整条能进 host 构建 ——
# 而它同时是 2026-09-03 那条"两份 libglfw / 两条 ring"回归的修复所依赖的唯一通道，
# 解析错一个字符的后果就是一份 image 静默留在自己的空 ring 上。
add_executable(amcl_legacy_bridge_instance_descriptor_test
    legacy_bridge_instance_descriptor_test.cpp
)
target_compile_features(amcl_legacy_bridge_instance_descriptor_test PRIVATE
    cxx_std_17
)
target_compile_definitions(amcl_legacy_bridge_instance_descriptor_test PRIVATE
    $<$<CXX_COMPILER_ID:MSVC>:_CRT_SECURE_NO_WARNINGS>
)
if(MSVC)
    target_compile_options(amcl_legacy_bridge_instance_descriptor_test PRIVATE
        /W4 /WX
    )
else()
    target_compile_options(amcl_legacy_bridge_instance_descriptor_test PRIVATE
        -Wall -Wextra -Werror -pedantic
    )
endif()
add_test(NAME amcl_legacy_bridge_instance_descriptor_test
         COMMAND amcl_legacy_bridge_instance_descriptor_test)

# 渲染分辨率缩放（-Damcl.render.scale）：解析域校验、round+偶数对齐取整、
# scale==1 恒等零开销、精确比值（scaled/real）映射与 launcher env 规范化 round-trip。
# 绝对坐标 real→MC(scaled) 的换算只发生在三个入口（touch 菜单、cursor_pos_checked、
# native mouse typed 绝对平面），本目标钉住的是它们共用的那份换算数学。
add_input_component_host_test(
    amcl_render_scale_test
    render_scale_test.cpp
    ../../platform/render_scale.cpp
)
target_include_directories(amcl_render_scale_test PRIVATE ../../platform)

# ============================================================
# 渲染后端镜像表（渲染后端治理 §S4）
# ============================================================
# 钉的是"缺件后端必须 fail closed 到默认"这条语义。
# ⚠️ 存在的直接原因：把 `else if (glBackend == "zink")` 改成表驱动时，第一版把
# fail-closed 整个弄丢了（zink 会让 opengl.libname 真指向拿不到 host hook 的 libOSMesa.so）。
# 那是一个真实回归，当时没有任何东西会拦住它。
add_executable(amcl_renderer_backend_ids_test
    renderer_backend_ids_test.cpp
)
target_include_directories(amcl_renderer_backend_ids_test PRIVATE
    ../../platform
)
target_compile_features(amcl_renderer_backend_ids_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_renderer_backend_ids_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_renderer_backend_ids_test PRIVATE -Wall -Wextra -Werror -pedantic)
endif()
add_test(NAME amcl_renderer_backend_ids_test COMMAND amcl_renderer_backend_ids_test)

# /proc/net/if_inet6 合成格式（JDK IPv6 适配方案 §4 路线 B 的前置判据）。
# 钉的是一个**静默**失败模式：IPv6_supported() 只要求"能读到一行"，所以合成一行垃圾
# 也能让 Net.isIPv6Available() 变 true；但 NetworkInterface.c 按固定 scanf 形状解析，
# 格式错一位就枚举不出 IPv6 地址且不报错。两个消费者的要求不同，只有格式测试能钉住。
# 纯头文件逻辑，无 OHOS 依赖，故不需要 stubs 也不需要实现 TU。
add_executable(amcl_if_inet6_synth_test
    if_inet6_synth_test.cpp
)
target_include_directories(amcl_if_inet6_synth_test PRIVATE
    ../../platform
)
target_compile_features(amcl_if_inet6_synth_test PRIVATE cxx_std_17)
target_compile_definitions(amcl_if_inet6_synth_test PRIVATE
    $<$<CXX_COMPILER_ID:MSVC>:_CRT_SECURE_NO_WARNINGS>
)
if(MSVC)
    target_compile_options(amcl_if_inet6_synth_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_if_inet6_synth_test PRIVATE -Wall -Wextra -Werror -pedantic)
endif()
add_test(NAME amcl_if_inet6_synth_test COMMAND amcl_if_inet6_synth_test)

# SDL host-presented input activation is a current-state composition, not a
# one-shot focus edge. This header-only truth table pins Unknown != Blurred and
# all surface/Ability fail-closed combinations without requiring OHOS headers.
add_executable(amcl_input_foreground_gate_test
    input_foreground_gate_test.cpp
)
target_include_directories(amcl_input_foreground_gate_test PRIVATE
    ../../platform
)
target_compile_features(amcl_input_foreground_gate_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_input_foreground_gate_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_input_foreground_gate_test PRIVATE
        -Wall -Wextra -Werror -pedantic
    )
endif()
add_test(NAME amcl_input_foreground_gate_test
         COMMAND amcl_input_foreground_gate_test)

# Formal desktop API26 symbol probe build policy.  This is intentionally a
# header-only host truth table: platform headers/libraries are verified by the
# conditionally compiled OHOS TU, while the host target proves that legacy is
# dependency-free and every disposition remains strictly non-routing.
add_executable(amcl_api26_input_probe_contract_test
    api26_input_probe_contract_test.cpp
)
target_include_directories(amcl_api26_input_probe_contract_test PRIVATE
    ../../platform
)
target_compile_features(amcl_api26_input_probe_contract_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_api26_input_probe_contract_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_api26_input_probe_contract_test PRIVATE
        -Wall -Wextra -Werror -pedantic
    )
endif()
add_test(NAME amcl_api26_input_probe_contract_test
         COMMAND amcl_api26_input_probe_contract_test)

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    add_executable(amcl_mobilegl_swapchain_geometry_test mobilegl_swapchain_geometry_test.cpp)
    target_compile_features(amcl_mobilegl_swapchain_geometry_test PRIVATE cxx_std_17)
    target_include_directories(amcl_mobilegl_swapchain_geometry_test PRIVATE
        ../../../../../../prebuilt/mobilegl/src/3rdparty/Vulkan-Headers/include)
    add_test(NAME amcl_mobilegl_swapchain_geometry_test COMMAND amcl_mobilegl_swapchain_geometry_test)
    set_tests_properties(amcl_mobilegl_swapchain_geometry_test PROPERTIES LABELS "mobilegl")
    add_executable(amcl_mobilegl_probe_failure_test mobilegl_probe_failure_test.cpp)
    target_include_directories(amcl_mobilegl_probe_failure_test PRIVATE mobilegl_stubs)
    target_compile_features(amcl_mobilegl_probe_failure_test PRIVATE cxx_std_17)
    target_compile_options(amcl_mobilegl_probe_failure_test PRIVATE -Wall -Wextra -Werror)
    foreach(fault none choose surface context current swap unbind destroy-context destroy-surface terminate identity gl-error symbol exception provider-split)
        add_test(NAME amcl_mobilegl_probe_${fault} COMMAND amcl_mobilegl_probe_failure_test ${fault})
        set_tests_properties(amcl_mobilegl_probe_${fault} PROPERTIES LABELS "mobilegl")
    endforeach()
endif()

# Keep the input ABI/adapter suite independently runnable.  The host project
# also carries MobileGlues/renderer/network/JNI smoke tests; those are useful
# in the aggregate build but must not hide a green input result behind an
# unrelated optional-backend failure.  Every test whose name is not explicitly
# outside the input scope receives the stable `input` label.
get_property(_amcl_host_test_names DIRECTORY PROPERTY TESTS)
foreach(_amcl_host_test IN LISTS _amcl_host_test_names)
    if(NOT _amcl_host_test MATCHES "^amcl_mg_" AND
       NOT _amcl_host_test MATCHES "^amcl_mobilegl_" AND
       NOT _amcl_host_test STREQUAL "amcl_renderer_backend_ids_test" AND
       NOT _amcl_host_test STREQUAL "amcl_native_window_lease_ledger_test" AND
       NOT _amcl_host_test STREQUAL "amcl_graphics_plan_test" AND
       NOT _amcl_host_test STREQUAL "amcl_vulkan_requirement_policy_test" AND
       NOT _amcl_host_test STREQUAL "amcl_graphics_backend_session_test" AND
       NOT _amcl_host_test STREQUAL "amcl_glfw_vulkan_wsi_policy_test" AND
       NOT _amcl_host_test STREQUAL "amcl_vulkan_wsi_lifetime_test" AND
       NOT _amcl_host_test STREQUAL "amcl_vulkan_wsi_dso_test" AND
       NOT _amcl_host_test STREQUAL "amcl_window_host_core_test" AND
       NOT _amcl_host_test STREQUAL "amcl_window_host_dso_test" AND
       NOT _amcl_host_test STREQUAL "amcl_if_inet6_synth_test" AND
       NOT _amcl_host_test STREQUAL "amcl_jni_mutf8_test")
        set_tests_properties(${_amcl_host_test} PROPERTIES LABELS "input")
    endif()
endforeach()
# Product logging boundary is independent from input routing and rendering.
add_executable(amcl_product_diagnostics_test product_diagnostics_test.cpp)
target_compile_features(amcl_product_diagnostics_test PRIVATE cxx_std_17)
add_test(NAME amcl_product_diagnostics_test COMMAND amcl_product_diagnostics_test)

# 日志系统重构 · P2：连续重复行合并的纯策略。
# 承重的是**无损性** —— 合并的失效形态是静默吞行，不报错、不告警。
add_executable(amcl_log_coalesce_test
    log_coalesce_test.cpp
)
target_include_directories(amcl_log_coalesce_test PRIVATE
    ../../utils
)
target_compile_features(amcl_log_coalesce_test PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(amcl_log_coalesce_test PRIVATE /W4 /WX /D_CRT_SECURE_NO_WARNINGS)
else()
    target_compile_options(amcl_log_coalesce_test PRIVATE -Wall -Wextra -Werror -pedantic)
endif()
add_test(NAME amcl_log_coalesce_test COMMAND amcl_log_coalesce_test)

add_executable(amcl_desktop_gamepad_mapping_test desktop_gamepad_mapping_test.cpp)
target_compile_features(amcl_desktop_gamepad_mapping_test PRIVATE cxx_std_17)
add_test(NAME amcl_desktop_gamepad_mapping_test COMMAND amcl_desktop_gamepad_mapping_test)
set_tests_properties(amcl_desktop_gamepad_mapping_test PROPERTIES LABELS "desktop;input")

# The tested presentation implementation is extracted from the shipped SDL
# patch recipe. Do not keep a second hand-copied production header in tests.
get_filename_component(AMCL_SDL_PROJECT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../.." ABSOLUTE)
find_program(AMCL_SDL_NODE_EXECUTABLE NAMES node node.exe)
if(NOT AMCL_SDL_NODE_EXECUTABLE)
    message(FATAL_ERROR "Node is required to extract the canonical SDL presentation helper")
endif()
set(AMCL_SDL_PRESENTATION_PATCH "${AMCL_SDL_PROJECT_ROOT}/prebuilt/sdl3/patches/0012-openharmony-presentation-session.patch")
set(AMCL_SDL_PRESENTATION_EXTRACTOR "${AMCL_SDL_PROJECT_ROOT}/scripts/extract-sdl3-presentation-header.mjs")
set(AMCL_SDL_PRESENTATION_INCLUDE "${CMAKE_CURRENT_BINARY_DIR}/sdl-presentation-generated")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${AMCL_SDL_PRESENTATION_PATCH}" "${AMCL_SDL_PRESENTATION_EXTRACTOR}")
# header 的后续修改来自完整补丁 series；修改任意后续 patch 都必须重新抽取，防止测旧头。
file(GLOB AMCL_SDL_PRESENTATION_SERIES_PATCHES CONFIGURE_DEPENDS "${AMCL_SDL_PROJECT_ROOT}/prebuilt/sdl3/patches/*.patch")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    ${AMCL_SDL_PRESENTATION_SERIES_PATCHES} "${AMCL_SDL_PROJECT_ROOT}/prebuilt/sdl3/patches/series")
execute_process(COMMAND "${AMCL_SDL_NODE_EXECUTABLE}" "${AMCL_SDL_PRESENTATION_EXTRACTOR}"
    --patch "${AMCL_SDL_PRESENTATION_PATCH}"
    --output "${AMCL_SDL_PRESENTATION_INCLUDE}/SDL_amclpresentation.h"
    RESULT_VARIABLE AMCL_SDL_PRESENTATION_EXTRACT_RESULT)
if(NOT AMCL_SDL_PRESENTATION_EXTRACT_RESULT EQUAL 0)
    message(FATAL_ERROR "Cannot extract the canonical SDL presentation helper")
endif()
add_executable(amcl_sdl_presentation_host_test sdl_presentation_host_test.cpp)
target_compile_features(amcl_sdl_presentation_host_test PRIVATE cxx_std_17)
target_include_directories(amcl_sdl_presentation_host_test PRIVATE "${AMCL_SDL_PRESENTATION_INCLUDE}" ../../glfw)
if(MSVC)
    target_compile_options(amcl_sdl_presentation_host_test PRIVATE /W4 /WX)
else()
    target_compile_options(amcl_sdl_presentation_host_test PRIVATE -Wall -Wextra -Werror -pedantic)
endif()
add_test(NAME amcl_sdl_presentation_host_test COMMAND amcl_sdl_presentation_host_test)
set_tests_properties(amcl_sdl_presentation_host_test PROPERTIES LABELS "graphics;sdl")
