#!/bin/bash
# planb_syntax_check.sh — syntax-only (-fsyntax-only) parse of the glfw native
# files touched by Plan B. Validates the C/C++ changes parse + type-check cleanly.
# NOTE: container lacks OHOS libc++; for C++ we borrow host libstdc++ headers
# (/usr/include/c++/11) purely so the parser can resolve <atomic> etc. This is a
# SYNTAX/TYPE check of our edits, not a real cross-compile (that's the HAP build).
set -u
SYSROOT=/ohos-sysroot-rw
INC="$SYSROOT/usr/include"
DIR=/build/planb/glfwcheck
GLFW="$DIR/glfw"
# host libstdc++ headers (for parser only)
HOSTCXX="-I/usr/include/c++/11 -I/usr/include/x86_64-linux-gnu/c++/11"
# jni.h lives at $DIR/jni.h; jni_reregister.c includes "../jvm/jni.h" -> shim that path
mkdir -p "$DIR/../jvm" 2>/dev/null; cp "$DIR/jni.h" "$DIR/../jvm/jni.h" 2>/dev/null; cp "$DIR/jni_md.h" "$DIR/../jvm/jni_md.h" 2>/dev/null
CXXFLAGS="--target=aarch64-linux-ohos --sysroot=$SYSROOT -std=c++20 -fsyntax-only -w $HOSTCXX -I$INC -I$DIR -I$GLFW"
CFLAGS="--target=aarch64-linux-ohos --sysroot=$SYSROOT -std=gnu99 -fsyntax-only -w -I$INC -I$DIR -I$GLFW"

rc=0
echo "=== C++ syntax/type checks (clang++ -fsyntax-only) ==="
for f in glfw_compat.cpp glfw_callbacks.cpp glfw_egl.cpp glfw_jni.cpp; do
  if /usr/bin/ohos-clang++ $CXXFLAGS "$GLFW/$f" 2>/tmp/err.txt; then
    echo "  OK   $f"
  else
    echo "  FAIL $f"; sed 's/^/       /' /tmp/err.txt | head -30; rc=1
  fi
done
echo "=== C syntax/type checks (clang -fsyntax-only) ==="
for f in input_bridge_ohos.c jni_reregister.c; do
  if /usr/bin/ohos-clang $CFLAGS "$GLFW/$f" 2>/tmp/err.txt; then
    echo "  OK   $f"
  else
    echo "  FAIL $f"; sed 's/^/       /' /tmp/err.txt | head -30; rc=1
  fi
done
echo "=== exit $rc ==="
exit $rc
