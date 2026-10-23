# shaderc 的普通链接只抽取其内部调用到的静态归档对象。glslang C interface、
# default resource limits、SPV version/fuzzer/reducer options 并不都被 shaderc 自身
# 调用，却全部属于当前 LWJGL 绑定的 required dlsym 接口。对每个锁定接口添加 -u，
# 使链接器从真实上游静态归档抽取对应对象；不会创建 stub，也不构建无关 fuzz 引擎。
target_link_libraries(shaderc_shared PRIVATE glslang-default-resource-limits)
# SDK CMake 工具链同时传 --target 与 --gcc-toolchain；后者在 clang 的纯编译步骤
# 不使用。shaderc 自带 -Werror，需只消除此类 driver 未用参数提示，仍保留源码告警门。
foreach(AMCL_SHADERC_TARGET shaderc shaderc_shared shaderc_util)
    target_compile_options(${AMCL_SHADERC_TARGET} PRIVATE -Qunused-arguments)
endforeach()
file(STRINGS "${CMAKE_CURRENT_LIST_DIR}/required-symbols.txt" AMCL_SHADERC_REQUIRED
     REGEX "^[A-Za-z_][A-Za-z_0-9]*$")
set(AMCL_SHADERC_KEEP_FLAGS "")
foreach(AMCL_SHADERC_SYMBOL IN LISTS AMCL_SHADERC_REQUIRED)
    string(APPEND AMCL_SHADERC_KEEP_FLAGS "--undefined=${AMCL_SHADERC_SYMBOL}\n")
endforeach()
# Windows 的 cmd.exe 命令行上限小于这组完整接口参数。直接给 lld 一个响应文件，
# 让每个保留项仍真实参与最终链接；响应文件只含从已锁定清单生成的 --undefined。
set(AMCL_SHADERC_KEEP_RESPONSE "${CMAKE_CURRENT_BINARY_DIR}/shaderc-required-link.rsp")
file(GENERATE OUTPUT "${AMCL_SHADERC_KEEP_RESPONSE}" CONTENT "${AMCL_SHADERC_KEEP_FLAGS}")
# 这里必须使用 -Wl,@，不能用 CMake LINKER:@（会变为 -Xlinker @）；后者的
# @file 先被 clang driver 展开，第二个及后续 --undefined 会误作 driver 参数。
target_link_options(shaderc_shared PRIVATE "-Wl,@${AMCL_SHADERC_KEEP_RESPONSE}")
# 只公开上述真实 C API，不把 glslang/SPIRV-Tools 的 C++ 内部符号扩散为应用 ABI。
# --no-undefined 保证新抽取的对象有真实依赖闭包，失败时停止而非生成半成品。
target_link_options(shaderc_shared PRIVATE
    "LINKER:--version-script=${CMAKE_CURRENT_LIST_DIR}/exports.map"
    "LINKER:--no-undefined" "LINKER:-z,noexecstack")
set_target_properties(shaderc_shared PROPERTIES OUTPUT_NAME shaderc)
# 上游默认输出 libshaderc.so.1，而现有应用契约使用无版本 libshaderc.so。
# 清除属性而非设为空串；空串在部分 CMake 版本会生成带尾部点号的 SONAME。
set_property(TARGET shaderc_shared PROPERTY SOVERSION)
set_property(TARGET shaderc_shared PROPERTY VERSION)
