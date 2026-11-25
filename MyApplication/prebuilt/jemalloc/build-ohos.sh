#!/usr/bin/env bash
# 从正式版归档重建现代 LWJGL 的私有分配器。所有中间文件和产物写入新的仓外目录。
# 用法：bash prebuilt/jemalloc/build-ohos.sh <新输出目录> <OHOS SDK native目录> [已缓存的发行tar.bz2]
# 在 Linux 或 WSL 使用 bash、Python 3、GNU make；WSL 可以直接调用 Windows 版 SDK。
set -euo pipefail
[[ $# -ge 2 && $# -le 3 ]] || { echo "用法：$0 OUT SDK_NATIVE [SOURCE_TARBALL]" >&2; exit 2; }
recipe=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$recipe/../.." && pwd -P)
out=$(realpath -m "$1")
sdk=$(cd "$2" && pwd -P)
tarball=${3:+$(realpath "$3")}
case "$out/" in "$repo/"*) echo "输出必须在仓库外" >&2; exit 2;; esac
mkdir -p "$(dirname "$out")"
mkdir "$out"
mkdir "$out/bin" "$out/tmp"
export TMPDIR="$out/tmp" LC_ALL=C
if [[ -z "$tarball" ]]; then
    tarball="$out/jemalloc-5.3.1.tar.bz2"
    curl --fail --location --retry 2 -o "$tarball" https://github.com/jemalloc/jemalloc/releases/download/5.3.1/jemalloc-5.3.1.tar.bz2
fi
expected=3826bc80232f22ed5c4662f3034f799ca316e819103bdc7bb99018a421706f92
[[ "$(sha256sum "$tarball" | cut -d' ' -f1)" == "$expected" ]] || { echo "源码 SHA-256 不符" >&2; exit 1; }
# 固定归档在校验后解包；Windows 版 LLVM 接收 Windows sysroot 路径，编译输入使用当前目录的相对路径。
python3 -m tarfile -e "$tarball" "$out"
cd "$out/jemalloc-5.3.1"
[[ "$(cat VERSION)" == "5.3.1-0-g81034ce1f1373e37dc865038e1bc8eeecf559ce8" ]]
cmp COPYING "$recipe/COPYING"
suffix=''
export AMCL_JE_SYSROOT="$sdk/sysroot"
if [[ ! -x "$sdk/llvm/bin/clang" && -f "$sdk/llvm/bin/clang.exe" ]]; then
    suffix=.exe
    AMCL_JE_SYSROOT=$(wslpath -w "$sdk/sysroot")
fi
export AMCL_JE_CC="$sdk/llvm/bin/clang$suffix"
"$AMCL_JE_CC" --version > "$out/compiler.txt"
cat > "$out/bin/amcl-je-clang" <<'CC'
#!/usr/bin/env bash
exec "$AMCL_JE_CC" --target=aarch64-linux-ohos "--sysroot=$AMCL_JE_SYSROOT" "$@"
CC
chmod +x "$out/bin/amcl-je-clang"
export PATH="$out/bin:$sdk/llvm/bin:$PATH"
export CC=amcl-je-clang AR="llvm-ar$suffix" NM="llvm-nm$suffix" RANLIB="llvm-ranlib$suffix"
# configure 识别 Linux/musl 功能；CC 实际生成 OHOS 目标。选择允许 4、16、64 KiB 内核页的上限，
# 动态 ELF TLS 支持启动后 dlopen。禁用 sbrk 和编译器 emutls，避免使用系统堆供给分配区或 TLS 存储。
./configure --build="$(sh build-aux/config.guess)" --host=aarch64-linux-musl \
    --with-jemalloc-prefix=je_ --with-lg-page=16 --with-lg-hugepage=21 \
    --disable-initial-exec-tls --disable-dss --disable-cxx --disable-static --disable-libdl \
    --disable-stats --disable-fill CFLAGS='-O2 -g0 -fno-emulated-tls' > "$out/configure.log" 2>&1
cp "$recipe/exports.map" amcl-exports.map
soname=libamcl_lwjgl_jemalloc.so
# 独立库名控制加载；-Bsymbolic 将库内函数和数据引用都绑定到本库，防止先加载的同名前缀提供方接管。
make -j"${AMCL_NATIVE_JOBS:-4}" build_lib_shared \
    DSO_LDFLAGS="-shared -Wl,-Bsymbolic,-soname,$soname,--build-id=sha1,--version-script=amcl-exports.map,--no-undefined,-z,relro,-z,now,-z,noexecstack,-z,max-page-size=65536" \
    > "$out/make.log" 2>&1
"llvm-strip$suffix" --strip-all -o "../$soname" lib/libjemalloc.so.2
"llvm-readelf$suffix" --file-header --dynamic --program-headers --dyn-syms --relocs --wide "../$soname" > "$out/elf.txt"
python3 "$recipe/check-elf.py" "$out" "$sdk" "$suffix" "$tarball"
sha256sum "$out/$soname"
