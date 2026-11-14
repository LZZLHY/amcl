# 上游静态 espeak 通过 target_link_libraries 添加裸 -Wl,-rpath,$ORIGIN。
# Ninja 只为 CMake 的 RPATH 属性转义 $，裸项被当作 Ninja 变量展开成空值，
# 导致 clang 把后面的 libucd.a 吞作路径，最终缺 ucd_*。在所有子目标创建后
# 仅移除这条多余链接选项；Unicode 库及实际音素实现保持完整，不用 stub 掩盖。
function(amcl_finalize_sherpa_ohos)
  foreach(prop LINK_LIBRARIES INTERFACE_LINK_LIBRARIES)
    get_target_property(items espeak-ng ${prop})
    if(items)
      list(FILTER items EXCLUDE REGEX "-Wl,-rpath,")
      set_property(TARGET espeak-ng PROPERTY ${prop} "${items}")
    endif()
  endforeach()
  # 产物只通过自身目录定位 ORT，不把构建宿主 E: 路径写进设备运行时。
  set_target_properties(sherpa-onnx-jni PROPERTIES
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH "$ORIGIN"
    INSTALL_RPATH_USE_LINK_PATH FALSE)
endfunction()

cmake_language(DEFER CALL amcl_finalize_sherpa_ohos)
