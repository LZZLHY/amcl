#!/bin/bash
set -e

OHOS_SYSROOT_ORIG=${OHOS_SYSROOT:-/ohos-sysroot}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-/ohos-toolchain}

# 将只读的 sysroot 复制到可写位置 (只复制一次)
#
# 用「临时目录 + 原子改名」而不是直接 cp 到目标位置：
# 从 Windows bind mount 复制 73 MB / 上万个小文件很慢，中途被打断过一次，
# 留下一个 22 MB 的残缺副本；而下面的 `-d $OHOS_SYSROOT/usr/include` 判断
# 会认为「已经复制过」从而跳过，之后所有构建都在残缺 sysroot 上失败且原因难查。
# 改成先复制到 .tmp 再 mv：被打断时 $OHOS_SYSROOT 根本不存在，重跑即重新复制。
# 对已经存在的完整 sysroot 零影响（不会误删历史增补的 X11/cups/fontconfig/libdrm 头）。
OHOS_SYSROOT=/ohos-sysroot-rw
if [ ! -d "$OHOS_SYSROOT/usr/include" ]; then
    echo "Copying sysroot to writable location (one-time)..."
    rm -rf "${OHOS_SYSROOT}.tmp"
    cp -a "$OHOS_SYSROOT_ORIG" "${OHOS_SYSROOT}.tmp"
    rm -rf "$OHOS_SYSROOT"
    mv "${OHOS_SYSROOT}.tmp" "$OHOS_SYSROOT"
    echo "Done."
fi

OHOS_LIBDIR=$OHOS_SYSROOT/usr/lib/aarch64-linux-ohos

echo "=== Setting up OHOS cross-compilation toolchain ==="
echo "Sysroot: $OHOS_SYSROOT"
echo "Libdir:  $OHOS_LIBDIR"
echo "Host clang: $(ohos-clang --version 2>&1 | head -1)"

mkdir -p $TOOLCHAIN_DIR

# ============================================================
# 修复 CRT 文件搜索路径
# clang driver 在 sysroot/usr/lib/ 下搜索 CRT 文件
# OHOS 的 CRT 在 sysroot/usr/lib/aarch64-linux-ohos/ 下
# 创建符号链接让 clang 能找到
# ============================================================

SYSROOT_LIB=$OHOS_SYSROOT/usr/lib
SYSROOT_INC=$OHOS_SYSROOT/usr/include

# 修复 include 路径: OHOS 把 arch-specific headers 放在子目录
# 但 musl 的 limits.h 直接 #include <bits/alltypes.h>
# 需要在顶层 include 创建 bits -> aarch64-linux-ohos/bits 符号链接
if [ ! -e "$SYSROOT_INC/bits" ]; then
    ln -sf aarch64-linux-ohos/bits $SYSROOT_INC/bits
    echo "Linked: include/bits -> aarch64-linux-ohos/bits"
fi
if [ ! -e "$SYSROOT_INC/asm" ]; then
    ln -sf aarch64-linux-ohos/asm $SYSROOT_INC/asm
    echo "Linked: include/asm -> aarch64-linux-ohos/asm"
fi

# 在 sysroot/usr/lib/ 下创建 CRT 文件的符号链接
for f in Scrt1.o crt1.o crti.o crtn.o; do
    if [ -f "$OHOS_LIBDIR/$f" ] && [ ! -f "$SYSROOT_LIB/$f" ]; then
        ln -sf aarch64-linux-ohos/$f $SYSROOT_LIB/$f
        echo "Linked: $f"
    fi
done

# 创建 Scrt1.o (如果不存在，从 crt1.o 复制)
if [ ! -f "$OHOS_LIBDIR/Scrt1.o" ]; then
    cp $OHOS_LIBDIR/crt1.o $OHOS_LIBDIR/Scrt1.o
    echo "Created Scrt1.o from crt1.o"
fi
if [ ! -f "$SYSROOT_LIB/Scrt1.o" ]; then
    ln -sf aarch64-linux-ohos/Scrt1.o $SYSROOT_LIB/Scrt1.o
    echo "Linked: Scrt1.o"
fi

# clang 链接时会在 sysroot/usr/lib/ 下搜索 crtbeginS.o/crtendS.o
# OHOS sysroot 没有这些文件，创建空 stub
for f in crtbeginS.o crtendS.o; do
    if [ ! -f "$SYSROOT_LIB/$f" ]; then
        /usr/bin/ohos-ar rcs $SYSROOT_LIB/$f 2>/dev/null || true
        echo "Created CRT stub: $SYSROOT_LIB/$f"
    fi
done

# 空的 stub 库 (musl 内含 pthread/dl/rt)
for lib in libpthread.a libdl.a librt.a libresolv.a; do
    if [ ! -f "$OHOS_LIBDIR/$lib" ]; then
        /usr/bin/ohos-ar rcs $OHOS_LIBDIR/$lib
        echo "Created stub: $lib"
    fi
done

# libgcc/libgcc_s stub (OHOS 用 compiler-rt)
if [ ! -f "$OHOS_LIBDIR/libgcc.a" ]; then
    /usr/bin/ohos-ar rcs $OHOS_LIBDIR/libgcc.a
    echo "Created stub: libgcc.a"
fi
if [ ! -f "$OHOS_LIBDIR/libgcc_s.so" ]; then
    ln -sf libc.so $OHOS_LIBDIR/libgcc_s.so
    echo "Created stub: libgcc_s.so -> libc.so"
fi

# 也在 sysroot/usr/lib/ 下创建库的符号链接
for lib in libc.so libm.so libz.so libgcc.a libgcc_s.so; do
    if [ -f "$OHOS_LIBDIR/$lib" ] && [ ! -e "$SYSROOT_LIB/$lib" ]; then
        ln -sf aarch64-linux-ohos/$lib $SYSROOT_LIB/$lib
    fi
done

# ============================================================
# 工具链包装脚本
# ============================================================

cat > $TOOLCHAIN_DIR/aarch64-linux-ohos-gcc << WRAPPER
#!/bin/bash
ARGS=()
for arg in "\$@"; do
    case "\$arg" in
        -lpthread|-ldl|-lrt|-lresolv) ;;
        *) ARGS+=("\$arg") ;;
    esac
done
exec /usr/bin/ohos-clang \
    --target=aarch64-linux-ohos \
    --sysroot=$OHOS_SYSROOT \
    -L$OHOS_LIBDIR \
    "\${ARGS[@]}"
WRAPPER

cat > $TOOLCHAIN_DIR/aarch64-linux-ohos-g++ << WRAPPER
#!/bin/bash
ARGS=()
for arg in "\$@"; do
    case "\$arg" in
        -lpthread|-ldl|-lrt|-lresolv) ;;
        *) ARGS+=("\$arg") ;;
    esac
done
exec /usr/bin/ohos-clang++ \
    --target=aarch64-linux-ohos \
    --sysroot=$OHOS_SYSROOT \
    -stdlib=libc++ \
    -nostdlib++ \
    -L$OHOS_LIBDIR \
    "\${ARGS[@]}"
WRAPPER

for tool in ar:ohos-ar ranlib:ohos-ranlib strip:ohos-strip objcopy:ohos-objcopy nm:ohos-nm objdump:ohos-objdump readelf:ohos-readelf; do
    name="${tool%%:*}"
    bin="${tool##*:}"
    cat > $TOOLCHAIN_DIR/aarch64-linux-ohos-${name} << EOF
#!/bin/bash
exec /usr/bin/${bin} "\$@"
EOF
done

cat > $TOOLCHAIN_DIR/aarch64-linux-ohos-ld << EOF
#!/bin/bash
exec /usr/bin/ld.lld "\$@"
EOF

chmod +x $TOOLCHAIN_DIR/aarch64-linux-ohos-*

export PATH=$TOOLCHAIN_DIR:$PATH
# 导出给后续脚本使用
export OHOS_SYSROOT=$OHOS_SYSROOT

echo ""
echo "=== Toolchain ready ==="
aarch64-linux-ohos-gcc --version 2>&1 | head -1
echo ""