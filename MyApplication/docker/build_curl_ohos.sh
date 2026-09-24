#!/bin/bash
# ============================================================
#  build_curl_ohos.sh — POC: 交叉编译 libcurl + OpenSSL for OHOS aarch64
#
#  目标：产出 /output/libcurl.so（OpenSSL 静态内联到 libcurl.so 里，
#        不依赖单独的 libssl.so / libcrypto.so），验证"方案 B 原教旨"
#        （Native C++ + libcurl multi 真多线程）在鸿蒙上是否可行。
#
#  预期难点：
#    - OpenSSL 的 Configure 是 perl 脚本，依赖大量 env vars
#    - curl 的 autotools 对交叉编译的 host triplet 敏感
#    - OHOS compiler-rt 不导出 __clear_cache 符号，可能需要 icache shim
#
#  运行方式：主机 docker/build_curl_ohos.ps1 -Sysroot <原始SDK的sysroot目录>
#  当前配方通过 /recipes 只读挂载；工作树和输出由统一启动器隔离。
# ============================================================
set -e

WORK=/build/curl-build
OUTPUT=/output
SYSROOT=/ohos-sysroot-rw
TARGET=aarch64-linux-ohos

OPENSSL_VER="3.3.2"
CURL_VER="8.10.1"
NGHTTP2_VER="1.64.0"

echo "=== Build libcurl + OpenSSL for OHOS aarch64 (POC) ==="
echo "OpenSSL: ${OPENSSL_VER}  curl: ${CURL_VER}"
echo ""

# 新入口提供新工作卷；重复执行时不擦除上次源码和日志，要求改开新任务。
[ ! -e "$WORK" ] || { echo "ERROR: use a new build task: $WORK"; exit 1; }
mkdir -p $WORK $OUTPUT

# 用 setup_toolchain.sh 创建的 aarch64-linux-ohos-gcc 包装器，而不是直接调
# "ohos-clang --target=..."。autoconf 对带空格的 CC 非常不友好（build test 会失败）。
# wrapper 内部已经做了 --target/--sysroot 处理 + 过滤 musl 不需要的库（-lpthread/-ldl/-lrt）
export PATH=/ohos-toolchain:$PATH
CC_WRAP=aarch64-linux-ohos-gcc
AR_WRAP=aarch64-linux-ohos-ar
RANLIB_WRAP=aarch64-linux-ohos-ranlib

# 验证包装器存在
which $CC_WRAP || { echo "ERROR: $CC_WRAP not in PATH. Did setup_toolchain.sh run?"; exit 1; }
echo "CC wrapper: $(which $CC_WRAP)"

# ============================================================
# Step 1: 编译 OpenSSL (静态库 only)
# ============================================================
echo "[1/3] Building OpenSSL ${OPENSSL_VER} (static)..."

OPENSSL_INSTALL=$WORK/openssl-install
cd $WORK
wget -q "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz"
tar xzf openssl-${OPENSSL_VER}.tar.gz
cd openssl-${OPENSSL_VER}

mkdir -p $OPENSSL_INSTALL

# OpenSSL 的 Configure：
#   no-shared         只产出 .a 静态库，我们要的
#   no-module no-dso  关键：禁用可加载模块（legacy.so / fips.so），这些在 OHOS
#                     下编不过（需要 dlopen 机制和特殊链接），且我们根本不用
#   no-asm            避免 aarch64 汇编可能的兼容性问题（性能略损，但 POC 目标是先跑通）
#   no-tests/no-docs  加速构建
#   no-engine         不要老 engine 框架
#   -fPIC             作为静态库被静态链进 libcurl.so，需要 PIC
CROSS_COMPILE="" \
CC="$CC_WRAP" \
AR="$AR_WRAP" \
RANLIB="$RANLIB_WRAP" \
./Configure linux-aarch64 \
    --prefix=$OPENSSL_INSTALL \
    --openssldir=$OPENSSL_INSTALL/ssl \
    no-shared no-asm no-tests no-docs no-apps no-engine \
    no-module no-dso \
    no-comp no-dtls no-weak-ssl-ciphers \
    -fPIC \
    2>&1 | tail -10

make -j$(nproc) build_libs 2>&1 | tail -5

# 不跑 install_sw（会尝试 build_modules 导致 legacy.so 编译挂）
# 手动 cp libs + headers 过去即可
mkdir -p $OPENSSL_INSTALL/lib $OPENSSL_INSTALL/include
cp libssl.a libcrypto.a $OPENSSL_INSTALL/lib/
cp -r include/openssl $OPENSSL_INSTALL/include/
cp -r include/crypto $OPENSSL_INSTALL/include/ 2>/dev/null || true

echo "  ✅ OpenSSL static libs:"
ls -lh $OPENSSL_INSTALL/lib/libssl.a $OPENSSL_INSTALL/lib/libcrypto.a

# ============================================================
# Step 2: 编译 nghttp2 (静态库，用于 HTTP/2 支持)
# ============================================================
echo ""
echo "[2/4] Building nghttp2 ${NGHTTP2_VER} (static, for HTTP/2 support)..."

NGHTTP2_INSTALL=$WORK/nghttp2-install
cd $WORK
wget -q "https://github.com/nghttp2/nghttp2/releases/download/v${NGHTTP2_VER}/nghttp2-${NGHTTP2_VER}.tar.gz"
tar xzf nghttp2-${NGHTTP2_VER}.tar.gz
cd nghttp2-${NGHTTP2_VER}

mkdir -p $NGHTTP2_INSTALL

# 用 autotools (configure) 编译，和 OpenSSL/curl 一致
# --enable-lib-only: 只编译 libnghttp2，不要 apps/examples/tests
# --enable-static / --disable-shared: 只产 .a 静态库
CC="$CC_WRAP" \
AR="$AR_WRAP" \
RANLIB="$RANLIB_WRAP" \
CFLAGS="-fPIC -O2" \
LDFLAGS="-fuse-ld=lld" \
./configure \
    --host=aarch64-linux \
    --prefix=$NGHTTP2_INSTALL \
    --enable-lib-only \
    --enable-static --disable-shared \
    2>&1 | tail -10

make -j$(nproc) 2>&1 | tail -5
make install 2>&1 | tail -5

# nghttp2 的 pkg-config 文件路径（curl configure 需要）
export PKG_CONFIG_PATH="$NGHTTP2_INSTALL/lib/pkgconfig:$PKG_CONFIG_PATH"

echo "  ✅ nghttp2 static lib:"
ls -lh $NGHTTP2_INSTALL/lib/libnghttp2.a

# ============================================================
# Step 3: 编译 curl (动态库，静态链 OpenSSL + nghttp2)
# ============================================================
echo ""
echo "[3/4] Building curl ${CURL_VER} (shared, with static OpenSSL + nghttp2)..."

CURL_INSTALL=$WORK/curl-install
cd $WORK
wget -q "https://curl.se/download/curl-${CURL_VER}.tar.gz"
tar xzf curl-${CURL_VER}.tar.gz
cd curl-${CURL_VER}

mkdir -p $CURL_INSTALL

# --disable-static / --enable-shared: 只产 .so
# --with-openssl=PATH: 指向刚编译的 OpenSSL
# --without-libpsl / --without-librtmp / --without-libssh2 / --without-zstd / --without-brotli:
#    不依赖这些可选库（简化依赖链）
# --disable-<protocol>: 禁用不需要的协议，减小 .so 体积 + 加速构建
# --enable-threaded-resolver: 用 pthread DNS 解析（不依赖 c-ares）
# LIBS="-lpthread -ldl": 链接时需要 pthread（线程解析器）和 dl（动态加载插件）
# 关键：用 aarch64-linux-ohos-gcc 这个 wrapper（不要直接 "ohos-clang --target=..."）
# autoconf 在 "C compiler cannot create executables" 阶段会用默认 CFLAGS+LDFLAGS
# 编译一个 test binary。wrapper 内部已经配好了 --target / --sysroot / -L$OHOS_LIBDIR，
# 还过滤了 musl 不需要的 -lpthread/-ldl/-lrt，避免链接器找不到这些 stub。
#
# LIBS 不再需要加 -lpthread -ldl（wrapper 会过滤掉这些，因为 OHOS musl 内置了）
# ⚠️ 2026-08-04：必须显式打开 poll，否则 libcurl 会退化成 select()，见下。
#
# curl 的 configure 用**运行时**测试判断 poll 是否可用（CURL_CHECK_FUNC_POLL →
# CURL_RUN_IFELSE）。交叉编译时那个测试程序跑不起来，于是 HAVE_POLL_FINE 不被定义，
# lib/select.c 里的 Curl_poll() 就编进了 select() 分支。curl 自己在该函数上方写明：
#     Return values: -1 = system call error or fd >= FD_SETSIZE
# 也就是说**进程内只要出现 fd >= 1024，libcurl 就整体瘫痪且永不自愈**：
#   · curl_multi_poll   → CURLM_UNRECOVERABLE_POLL
#   · curl_easy_perform → CURLE_BAD_FUNCTION_ARGUMENT（easy_transfer 把任何非 OOM 的
#                         CURLMcode 都映射成它）
# 2026-08-04 真机就是这样炸的：一个 4750 对象的 assets 任务把 fd 推过 1024 之后，
# 所有下载和所有元数据请求（版本清单 / version.json / 源探测）全部秒失败，
# 用户点多少次重试都一样，必须杀进程。诊断记录见
# docs/self-inspection/2026-08-04_AMCL_下载器全线瘫痪根因.md
#
# 修法：把 HAVE_POLL_FINE 强行定义进 CFLAGS。configure 已经会正确探测到 poll.h
# （AC_CHECK_HEADERS 是编译期检查，交叉编译下有效），缺的只是这个运行时结论。
# 校验产物是否修好（应看到 poll@plt 而不是 select@plt）：
#   llvm-objdump -d --start-address=<Curl_poll> libcurl.so | grep plt
CC="$CC_WRAP" \
AR="$AR_WRAP" \
RANLIB="$RANLIB_WRAP" \
CFLAGS="-fPIC -O2 -DHAVE_POLL_FINE=1" \
LDFLAGS="-fuse-ld=lld" \
./configure \
    --host=aarch64-linux \
    --prefix=$CURL_INSTALL \
    --with-openssl=$OPENSSL_INSTALL \
    --enable-shared --disable-static \
    --enable-threaded-resolver \
    --without-libpsl --without-librtmp --without-libssh2 \
    --without-zstd --without-brotli --without-libidn2 \
    --with-nghttp2=$NGHTTP2_INSTALL \
    --disable-manual --disable-libcurl-option \
    --disable-ldap --disable-ldaps --disable-rtsp --disable-dict \
    --disable-telnet --disable-tftp --disable-pop3 --disable-imap \
    --disable-smb --disable-smtp --disable-gopher --disable-mqtt \
    --disable-file --disable-ftp --disable-ipfs --disable-docs \
    2>&1 | tail -20

# 如果 configure 失败，打印 config.log 最后部分用于诊断
if [ ! -f Makefile ]; then
    echo ""
    echo "=== configure FAILED - config.log tail ==="
    tail -80 config.log
    exit 1
fi

echo ""
echo "  === configure summary ==="
grep -E "^  (SSL|HTTP|HTTPS|Host|Features)" config.status 2>/dev/null | head -20 || true

# 只编 lib，不编 src/docs/tests（进一步加速）
make -C lib -j$(nproc) 2>&1 | tail -5
make -C include -j$(nproc) install 2>&1 | tail -3
make -C lib install 2>&1 | tail -3

echo "  ✅ libcurl shared lib:"
ls -lh $CURL_INSTALL/lib/libcurl.so*

# ============================================================
# Step 3: 验证产物
# ============================================================
echo ""
echo "[4/4] Verification..."

# 复制实际文件（解引用符号链接）
LIBCURL_REAL=$(ls $CURL_INSTALL/lib/libcurl.so.4.* 2>/dev/null | head -1)
if [ -z "$LIBCURL_REAL" ]; then
    LIBCURL_REAL=$CURL_INSTALL/lib/libcurl.so.4
fi
cp -L $LIBCURL_REAL $OUTPUT/libcurl.so

# ========================================================================
# 关键：把 SONAME 从 "libcurl.so.4" 改成 "libcurl.so"，和文件名一致
#
# 原因：
#   curl 默认 soname 带版本号（libcurl.so.4）。当 libentry.so 链接它时，
#   会记录 NEEDED=libcurl.so.4（因为链接器读 soname）。但 HAP 里打包的
#   prebuilt 文件名是 libcurl.so（无版本），OHOS ELF loader 找不到
#   libcurl.so.4 → dlopen 失败 → libentry 无法加载。
#
# 修复：patchelf 把 soname 改成 libcurl.so，和文件名匹配。
#       之后 libentry.so 相邻这个 libcurl.so 链接，NEEDED 就是 libcurl.so。
#
# 备选方案（未采用）：
#   - 重命名文件为 libcurl.so.4：OHOS HAP 的 libs/arm64-v8a/ 能打包任意名称
#     .so 文件，但我们已有一批 libxxx.so 命名的 prebuilt（liblwjgl.so 等），
#     保持一致更好
#   - LDFLAGS 里 -Wl,-soname,libcurl.so：libtool 会忽略或冲突
# ========================================================================
command -v patchelf >/dev/null 2>&1 || {
    echo "ERROR: patchelf 未安装。请在 Dockerfile.openjdk-ohos 里加 patchelf 到 apt-get install"
    exit 1
}
patchelf --set-soname libcurl.so $OUTPUT/libcurl.so
echo "  Patched SONAME to 'libcurl.so'"

# 同时复制 include
rm -rf $OUTPUT/curl-headers
cp -r $CURL_INSTALL/include $OUTPUT/curl-headers

echo ""
echo "=== libcurl.so ==="
file $OUTPUT/libcurl.so
ls -lh $OUTPUT/libcurl.so
echo ""
echo "=== Dynamic dependencies (NEEDED) ==="
readelf -d $OUTPUT/libcurl.so | grep NEEDED

echo ""
echo "=== Exported curl symbols (sample) ==="
ohos-nm -D $OUTPUT/libcurl.so | grep -E " T curl_(easy_init|multi_init|easy_setopt|multi_add_handle|easy_perform)" | head -8

echo ""
echo "=== OpenSSL symbols INSIDE libcurl (should be many - proves static link) ==="
OPENSSL_SYM_COUNT=$(ohos-nm -D $OUTPUT/libcurl.so 2>/dev/null | grep -cE " [TB] (SSL_|TLS_|OPENSSL_|EVP_)" || echo 0)
echo "  OpenSSL symbol count: $OPENSSL_SYM_COUNT (expected: > 100 for full static link)"

echo ""
echo "=== nghttp2 symbols INSIDE libcurl (proves HTTP/2 static link) ==="
NGHTTP2_SYM_COUNT=$(ohos-nm -D $OUTPUT/libcurl.so 2>/dev/null | grep -cE " [TB] nghttp2_" || echo 0)
echo "  nghttp2 symbol count: $NGHTTP2_SYM_COUNT (expected: > 10 for HTTP/2 support)"

echo ""
echo "=== Done ==="
echo "Output: $OUTPUT/libcurl.so"
echo "Headers: $OUTPUT/curl-headers/curl/*.h"
echo ""
echo "Next step (on host):"
echo "  Copy to entry/libs/arm64-v8a/libcurl.so"
echo "  Copy headers to entry/src/main/cpp/third_party/curl/"
