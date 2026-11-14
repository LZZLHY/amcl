#!/bin/bash
# 字体发现 provider 的独立可复现构建。源码、Meson、完整目标 SDK 和配方由
# Compose 入口固定；只输出新候选，不替换 HAP、四份 JDK 或已发布的归档。
# FreeType 仅用于同版本头文件与真实链接检查；最终继续使用消费者已有的库。
# Expat 静态私有链接，避免与 HAP 中其他组件的 XML ABI/版本互相抢占。
set -euo pipefail
[[ "${AMCL_BUILDER_MANAGED:-}" == 1 && -n "${AMCL_JDK_NATIVE_ROOT:-}" ]] || {
    echo 'ERROR: fontconfig requires managed builder with frozen native SDK'; exit 1;
}
work=/build/font-provider
spec=/prebuilt/fontconfig/build-inputs.json
mkdir -p "$work" /output/sources /output/classic /output/modern /output/reference

# 每个源码目录只接受锁定仓库、提交和干净已跟踪内容；不 reset 或清理失败现场。
python3 /recipes/scripts/fontconfig_inputs.py "$spec" "$work" /output/sources
export PYTHONPATH="$work/meson"
export PYTHONDONTWRITEBYTECODE=1
meson=(python3 -m mesonbuild.mesonmain)
# Meson 的真实编译能力检查把 unused-command-line-argument 作为错误。通用 JDK
# wrapper 每次都附加链接选项，会把 sizeof/结构成员等检查误判为不支持。
# 此处专用 wrapper 按 -c/-E/-S 区分阶段；保留所有能力检查，不屏蔽 -Werror。
cc="$work/target-cc"
cat > "$cc" <<'EOF'
#!/bin/bash
set -euo pipefail
link=yes
executable=yes
for item in "$@"; do
    case "$item" in -c|-E|-S|-fsyntax-only) link=no ;; esac
    case "$item" in -shared|-r) executable=no ;; esac
done
native=${AMCL_JDK_NATIVE_ROOT:?}
resource=/ohos-toolchain/clang-resource
flags=(--target=aarch64-linux-ohos --sysroot=/ohos-sysroot-rw
       "-resource-dir=$resource" -D__OHOS__=1 -D__OHOS_FAMILY__=1 -D__OHOS_Major__=0)
if [[ "$link" == yes ]]; then
    flags+=(-B/ohos-sysroot-rw/usr/lib -rtlib=compiler-rt -unwindlib=none -fuse-ld=lld
            -L/ohos-sysroot-rw/usr/lib/aarch64-linux-ohos)
    if [[ "$executable" == yes ]]; then
        flags+=(-Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1)
    fi
fi
exec /usr/bin/ohos-clang "${flags[@]}" "$@"
EOF
chmod 0755 "$cc"

# 固定 gperf 在本次工作卷做宿主构建；不向镜像安装包，不污染全局工具目录。
gperf_version=$(python3 -c 'import json; print(json.load(open("/prebuilt/fontconfig/build-inputs.json"))["gperf"]["version"])')
mkdir -p "$work/gperf-build"
(
    cd "$work/gperf-build"
    if [[ ! -f Makefile ]]; then
        "$work/gperf-$gperf_version/configure" --prefix="$work/host"
    fi
    make -j"${JOBS:-4}"
    make install
)
export PATH="$work/host/bin:$PATH"
cat > "$work/target.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER "$cc")
set(CMAKE_AR /usr/bin/ohos-ar)
set(CMAKE_RANLIB /usr/bin/ohos-ranlib)
set(CMAKE_FIND_ROOT_PATH /ohos-sysroot-rw)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

# 保留 Expat 的 DTD、实体、命名空间和加固默认项；仅不编译宿主无法执行的
# 示例/测试程序。PIC 和归档隐藏在后面的最终共享链接中保证依赖不会泄漏。
cmake -S "$work/expat/expat" -B "$work/expat-build" \
    -DCMAKE_TOOLCHAIN_FILE="$work/target.cmake" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$work/stage" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DEXPAT_SHARED_LIBS=OFF \
    -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_TESTS=OFF \
    -DEXPAT_BUILD_DOCS=OFF
cmake --build "$work/expat-build" --parallel "${JOBS:-4}"
cmake --install "$work/expat-build"

# 参考库不交付，只用于确认 Fontconfig 所需的真实 FreeType C ABI。这里关闭的
# 可选依赖只影响这份参考构建，不能据此改动或删减消费者现有字体解码能力。
cmake -S "$work/freetype" -B "$work/freetype-build" \
    -DCMAKE_TOOLCHAIN_FILE="$work/target.cmake" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$work/stage" -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_SHARED_LIBS=ON -DFT_DISABLE_ZLIB=TRUE -DFT_DISABLE_BZIP2=TRUE \
    -DFT_DISABLE_PNG=TRUE -DFT_DISABLE_HARFBUZZ=TRUE -DFT_DISABLE_BROTLI=TRUE
cmake --build "$work/freetype-build" --parallel "${JOBS:-4}"
cmake --install "$work/freetype-build"

# pkg-config 的可见域仅有本次目标库，不从 /usr/lib 引入宿主 FreeType/Expat。
export PKG_CONFIG_LIBDIR="$work/stage/lib/pkgconfig"
unset PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR
cat > "$work/target.ini" <<EOF
[binaries]
c = '$cc'
ar = '/usr/bin/ohos-ar'
strip = '/usr/bin/ohos-strip'
pkg-config = '/usr/bin/pkg-config'
[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
[properties]
needs_exe_wrapper = true
[built-in options]
c_args = ['-O2', '-fPIC']
c_link_args = ['-Wl,--exclude-libs,libexpat.a', '-Wl,-z,defs']
EOF
if [[ ! -f "$work/fontconfig-build/build.ninja" ]]; then
    "${meson[@]}" setup "$work/fontconfig-build" "$work/fontconfig" \
        --cross-file "$work/target.ini" --prefix /usr --libdir lib \
        --buildtype release --default-library shared --wrap-mode nofallback \
        -Dxml-backend=expat -Ddoc=disabled -Dtests=disabled -Dtools=enabled \
        -Dcache-build=disabled -Ddefault-fonts-dirs=/system/fonts \
        -Dadditional-fonts-dirs=no -Dcache-dir=fontconfig-cache
fi
"${meson[@]}" compile -C "$work/fontconfig-build" -j "${JOBS:-4}"
# 使用上游安装步骤移除构建期 RPATH，DESTDIR 仍是本次工作卷；cache-build 已
# 显式禁用，交叉安装不会尝试执行目标 fc-cache，也不会扫描宿主字体目录。
"${meson[@]}" install -C "$work/fontconfig-build" --destdir "$work/install" --no-rebuild

# 两份 provider 的唯一 ABI 差别是已有 FreeType 的 SONAME；转换器解析真实 ELF
# 动态表，验证字符串不被其他表项共享并记录逐字节差异，拒绝不认识的输入。
python3 /recipes/scripts/package_fontconfig.py \
    --library "$work/install/usr/lib/libfontconfig.so.1.16.0" \
    --reference "$work/stage/lib/libfreetype.so" \
    --source-root "$work" --spec "$spec" --output /output
echo 'PASS: fontconfig candidates built; target font/cache/runtime execution still requires qualification'
